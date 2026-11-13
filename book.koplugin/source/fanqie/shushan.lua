--[[--
书山聚合（ShuShan）书源。

服务器：https://v2.vossc.com（可配）
鉴权：X-Api-Key（api_key 的 base64）+ X-Device-Id（真实 Android ID）+ X-Novel-Token

@module koplugin.book.source.fanqie.shushan
--]]

local Request = require("http.request")
local JSON = require("json")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("l10n").get("source.fanqie")

local M = {}

local DEFAULT_BASE = "https://v2.vossc.com"
local X_NOVEL_TOKEN = "SHUSAN_READ_2025"
local DEFAULT_SOURCE = "番茄小说"
local CONTENT_VERSION = "12"
local USER_AGENT = "Mozilla/5.0 (Linux; Android 10; Pixel 3) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

-- ── base64 ─────────────────────────────────────────────────

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_REV = {}
for i = 1, #B64 do B64_REV[B64:sub(i, i)] = i - 1 end

local function base64Encode(s)
    s = tostring(s or "")
    local out, i = {}, 1
    while i <= #s do
        local b1 = s:byte(i)
        local b2 = s:byte(i + 1)
        local b3 = s:byte(i + 2)
        local c1 = math.floor(b1 / 4)
        local c2 = math.floor((b1 % 4) * 16 + (b2 and math.floor(b2 / 16) or 0))
        local c3 = b2 and math.floor((b2 % 16) * 4 + (b3 and math.floor(b3 / 64) or 0))
        local c4 = b3 and (b3 % 64)
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (c3 and B64:sub(c3 + 1, c3 + 1) or "=")
            .. (c4 and B64:sub(c4 + 1, c4 + 1) or "=")
        i = i + 3
    end
    return table.concat(out)
end

-- ── 工具 ───────────────────────────────────────────────────

local function trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$")
end

local function normalizeBase(url)
    url = trim(url)
    if url == "" then url = DEFAULT_BASE end
    if not url:match("^https?://") then url = "https://" .. url end
    if url:sub(-1) == "/" then url = url:sub(1, -2) end
    return url
end

local function getCfg(settings)
    return settings:get("sources", {}).shushan or {}
end

local function saveCfg(settings, cfg)
    local sources = settings:get("sources", {})
    sources.shushan = cfg
    settings:set("sources", sources)
    settings:flush()
end

local function resolveAndroidId(cfg)
    return trim(cfg.android_id)
end

local function validateAndroidId(aid)
    if aid == "" then return false end
    if not aid:match("^%x+$") then return false end
    return #aid == 16 or #aid == 32
end

--- 通用请求，cb(body, code) 或 cb(nil, err)
local function httpRequest(opts, cb)
    local h = { ["User-Agent"] = USER_AGENT }
    for k, v in pairs(opts.headers or {}) do h[k] = v end
    return Request.request({
        url = opts.url,
        method = opts.method or "GET",
        headers = h,
        body = opts.body,
        timeout = opts.timeout or require("http.timeout").net(1),
        allow_redirects = true,
    }, function(res, err)
        if err or not res then
            cb(nil, err and tostring(err) or _("网络请求失败"))
            return
        end
        cb(res.body, tonumber(res.code))
    end)
end

-- ── 登录 ───────────────────────────────────────────────────

--- 登录，cb(api_key, err)。
function M.login(settings, cb)
    local cfg = getCfg(settings)
    local email = trim(cfg.email)
    local password = trim(cfg.password)
    if email == "" or password == "" then
        require("ui/uimanager"):nextTick(function()
            cb(nil, _("书山未填写邮箱/密码"))
        end)
        return
    end
    local base = normalizeBase(cfg.server_url)
    local body_str = "email=" .. Text.urlEncode(email)
        .. "&password=" .. Text.urlEncode(password)
    return httpRequest({
        url = base .. "/login",
        method = "POST",
        body = body_str,
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["X-Novel-Token"] = X_NOVEL_TOKEN,
        },
        timeout = require("http.timeout").net(1),
    }, function(body, code)
        if not body then cb(nil, code); return end
        if code < 200 or code >= 300 then
            cb(nil, string.format("HTTP %d", code))
            return
        end
        local ok, obj = pcall(JSON.decode, body)
        if not ok or type(obj) ~= "table" then
            cb(nil, _("响应非 JSON"))
            return
        end
        if not (obj.success or tonumber(obj.code) == 200) then
            cb(nil, string.format("登录失败：%s",
                tostring(obj.message or obj.msg or obj.error or "")))
            return
        end
        local api_key = trim(((obj.data or {}).user or {}).api_key)
        if api_key == "" then
            cb(nil, _("登录成功但未返回 api_key"))
            return
        end
        cfg.api_key = api_key
        cfg.api_key_at = tostring(os.time())
        saveCfg(settings, cfg)
        cb(api_key)
    end)
end

--- 确保有 api_key；没有则登录。cb(api_key, err)。
local function ensureApiKey(settings, cb)
    local cfg = getCfg(settings)
    local key = trim(cfg.api_key)
    if key ~= "" then
        require("ui/uimanager"):nextTick(function() cb(key) end)
        return
    end
    M.login(settings, cb)
end

-- ── 正文 ───────────────────────────────────────────────────

--- 拉单章正文。cb(result, err)。
---@return { cancel: fun() }
function M.getContentAsync(settings, book_id, item_id, cb)
    local cancelled = false
    ensureApiKey(settings, function(api_key, err)
        if cancelled then return end
        if not api_key then cb(nil, err); return end
        local cfg = getCfg(settings)
        local aid = resolveAndroidId(cfg)
        --if not validateAndroidId(aid) then
        --    cb(nil, _("书山正文需要真实 Android ID（16/32位hex）"))
        --    return
        --end
        local base = normalizeBase(cfg.server_url)
        local body_str = JSON.encode({
            cid = 0,
            source = trim(cfg.source) ~= "" and trim(cfg.source) or DEFAULT_SOURCE,
            book_id = tostring(book_id),
            item_id = tostring(item_id),
            version = trim(cfg.content_version) ~= "" and trim(cfg.content_version) or CONTENT_VERSION,
        })
        httpRequest({
            url = base .. "/content",
            method = "POST",
            body = body_str,
            headers = {
                ["Content-Type"] = "application/json",
                ["X-Api-Key"] = base64Encode(api_key),
                ["X-Novel-Token"] = X_NOVEL_TOKEN,
                ["X-Device-Id"] = aid,
                ["X-Device-Type"] = "android",
            },
            timeout = require("http.timeout").net(1),
        }, function(body, code)
            if cancelled then return end
            if not body then cb(nil, code); return end
            if code < 200 or code >= 300 then cb(nil, string.format("HTTP %d", code)); return end
            local ok, obj = pcall(JSON.decode, body)
            if not ok or type(obj) ~= "table" then cb(nil, _("响应非 JSON")); return end
            if tonumber(obj.status) == 429 or tonumber(obj.code) == 429 then
                cb(nil, _("书山设备码无效或被限流")); return
            end
            if obj.code and tonumber(obj.code) ~= 200 then
                cb(nil, string.format("code=%s %s", tostring(obj.code),
                    tostring(obj.msg or (obj.data and obj.data.content) or "")))
                return
            end
            local data = obj.data or {}
            local content = tostring(data.content or "")
            if content == "" then cb(nil, _("正文为空")); return end
            local html_lines = {}
            for line in (content .. "\n"):gmatch("(.-)\n") do
                local t = line:gsub("^%s+", ""):gsub("%s+$", "")
                if t ~= "" then html_lines[#html_lines + 1] = "<p>" .. t .. "</p>" end
            end
            cb({
                content = table.concat(html_lines, "\n"),
                title = tostring(data.title or ""),
                author = tostring(data.author or ""),
                para_reviews = {},
            })
        end)
    end)
    return { cancel = function() cancelled = true end }
end

-- ── 段评 ───────────────────────────────────────────────────

--- 本章有段评的段落。cb(hotspots, err)。
---@return { cancel: fun() }
function M.hotspotsAsync(settings, book_id, item_id, cb)
    local cancelled = false
    ensureApiKey(settings, function(api_key, err)
        if cancelled then return end
        if not api_key then cb(nil, err); return end
        local cfg = getCfg(settings)
        local aid = resolveAndroidId(cfg)
        --if not validateAndroidId(aid) then
        --    cb(nil, _("书山段评需要真实 Android ID（16/32位hex）")); return
        --end
        local base = normalizeBase(cfg.server_url)
        local q = string.format("/para?source=fq&book_id=%s&chapter_id=%s",
            Text.urlEncode(tostring(book_id)), Text.urlEncode(tostring(item_id)))
        httpRequest({
            url = base .. q,
            method = "GET",
            headers = {
                ["X-Api-Key"] = base64Encode(api_key),
                ["X-Novel-Token"] = X_NOVEL_TOKEN,
                ["X-Device-Id"] = aid,
                ["X-Device-Type"] = "android",
            },
            timeout = require("http.timeout").net(1),
        }, function(body, code)
            if cancelled then return end
            if not body then cb(nil, code); return end
            if code < 200 or code >= 300 then cb(nil, string.format("HTTP %d", code)); return end
            local ok, obj = pcall(JSON.decode, body)
            if not ok or type(obj) ~= "table" then cb(nil, _("响应非 JSON")); return end
            if obj.code and tonumber(obj.code) ~= 0 then
                cb(nil, string.format("code=%s %s",
                    tostring(obj.code), tostring(obj.message or obj.msg or "")))
                return
            end
            local list = (obj.data or {}).list or {}
            local out = {}
            for _, item in ipairs(list) do
                local pid = tonumber(item.paragraph_id)
                local count = tonumber(item.comment_count or 0)
                if pid and count and count > 0 then
                    out[#out + 1] = {
                        range = string.format("shushan:%s:%s:%d",
                            tostring(book_id), tostring(item_id), pid),
                        text = "",
                        total = count,
                    }
                end
            end
            table.sort(out, function(a, b)
                return tonumber(a.range:match("(%d+)$")) < tonumber(b.range:match("(%d+)$"))
            end)
            cb(out)
        end)
    end)
    return { cancel = function() cancelled = true end }
end

--- 某段的一页评论。cb(page, err)。
---@return { cancel: fun() }
function M.pageAsync(settings, book_id, item_id, pid, max_idx, cb)
    local cancelled = false
    ensureApiKey(settings, function(api_key, err)
        if cancelled then return end
        if not api_key then cb(nil, err); return end
        local cfg = getCfg(settings)
        local aid = resolveAndroidId(cfg)
        --if not validateAndroidId(aid) then
        --    cb(nil, _("书山段评需要真实 Android ID（16/32位hex）")); return
        --end
        local base = normalizeBase(cfg.server_url)
        local count = 20
        local cursor = tonumber(max_idx) or 0
        local q = string.format(
            "/idea_comment?api=1&book_id=%s&item_id=%s&para=%s&cursor=%d&count=%d&sort=1",
            Text.urlEncode(tostring(book_id)), Text.urlEncode(tostring(item_id)),
            Text.urlEncode(tostring(pid)), cursor, count)
        httpRequest({
            url = base .. q,
            method = "GET",
            headers = {
                ["X-Api-Key"] = base64Encode(api_key),
                ["X-Novel-Token"] = X_NOVEL_TOKEN,
                ["X-Device-Id"] = aid,
                ["X-Device-Type"] = "android",
            },
            timeout = require("http.timeout").net(1),
        }, function(body, code)
            if cancelled then return end
            if not body then cb(nil, code); return end
            if code < 200 or code >= 300 then cb(nil, string.format("HTTP %d", code)); return end
            local ok, obj = pcall(JSON.decode, body)
            if not ok or type(obj) ~= "table" then cb(nil, _("响应非 JSON")); return end
            if obj.code and tonumber(obj.code) ~= 0 then
                cb(nil, string.format("code=%s %s",
                    tostring(obj.code), tostring(obj.message or obj.msg or "")))
                return
            end
            local data = obj.data or {}
            local list = data.data_list or {}
            local info = data.common_list_info or {}
            local para_src = tostring(data.para_src_content or "")
            local items = {}
            for _, entry in ipairs(list) do
                local c = entry.comment or entry
                local common = c.common or {}
                local content = common.content or {}
                local user = common.user_info or {}
                local base_info = user.base_info or user
                local stat = c.stat or {}
                local created = tonumber(common.create_timestamp or common.create_time) or 0
                if para_src ~= "" and type(c.expand) ~= "table" then
                    c.expand = { para_src_content = para_src }
                end
                items[#items + 1] = {
                    id = tostring(c.comment_id or ""),
                    author = tostring(base_info.user_name or ""),
                    content = tostring(content.text or ""),
                    likes = tonumber(stat.digg_count) or 0,
                    replies = tonumber(stat.reply_count) or 0,
                    time = created > 1e11 and math.floor(created / 1000) or created,
                    images = content.image_data_list,
                }
            end
            local next_offset = cursor + #items
            local has_more = info.has_more
            if has_more == nil then has_more = (#items >= count) end
            cb({
                items = items,
                total = tonumber(info.total) or next_offset,
                max_idx = next_offset,
                more = has_more == true and #items > 0,
            })
        end)
    end)
    return { cancel = function() cancelled = true end }
end

--- 书山没有独立回复接口：cb 空页。
---@return { cancel: fun() }
function M.repliesAsync(_settings, _book_id, _comment_id, _max_idx, cb)
    require("ui/uimanager"):nextTick(function()
        cb({ items = {}, total = 0, max_idx = 0, more = false })
    end)
    return { cancel = function() end }
end

-- ── 测速 ───────────────────────────────────────────────────

--- 测速所有候选节点。cb({ best, results, err }, nil)。
function M.selectFastest(settings, cb)
    local cfg = getCfg(settings)
    local bases = {
        normalizeBase(cfg.server_url),
        "https://v1.vossc.com",
        "https://v2.vossc.com",
        "https://v3.vossc.com",
        "https://v4.vossc.com",
    }
    local seen, list = {}, {}
    for _, u in ipairs(bases) do
        if u ~= "" and not seen[u] then
            seen[u] = true
            list[#list + 1] = u
        end
    end
    local results, done_n, best, best_ms = {}, 0, nil, nil
    local total = #list
    local function finish()
        if not best then
            cb({ best = nil, results = results, err = _("全部节点不可达") })
            return
        end
        cfg.server_url = best
        saveCfg(settings, cfg)
        cb({ best = best, results = results })
    end
    for _, base in ipairs(list) do
        local started = os.time()
        httpRequest({
            url = base .. "/detection",
            method = "GET",
            timeout = require("http.timeout").net(0.5),
        }, function(body, code)
            local elapsed = (os.time() - started) * 1000
            if body and code and code >= 200 and code < 300 then
                results[#results + 1] = { base = base, ms = elapsed, ok = true }
                if not best_ms or elapsed < best_ms then
                    best, best_ms = base, elapsed
                end
            else
                results[#results + 1] = { base = base, ms = elapsed, ok = false }
            end
            done_n = done_n + 1
            if done_n >= total then finish() end
        end)
    end
end

return M
