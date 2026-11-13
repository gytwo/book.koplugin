--[[--
知秋四合一（ZhiQiu）书源。

服务器：https://fq.vv9v.cn（可配）
鉴权：x-sec-token（共享 Token）+ x-android-id（设备 ID）

@module koplugin.book.source.fanqie.zhiqiu
--]]

local Request = require("http.request")
local JSON = require("json")
local Text = require("utils.text")
local logger = require("utils.log")
local _ = require("l10n").get("source.fanqie")

local M = {}

local DEFAULT_BASE = "https://fq.vv9v.cn"
local USER_AGENT = "Mozilla/5.0 (Linux; Android 10; Pixel 3) AppleWebKit/537.36 "
    .. "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"

-- ── 工具 ───────────────────────────────────────────────────

local function trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$")
end

local function generateAndroidId()
    local chars = "0123456789abcdef"
    local out = {}
    for _ = 1, 16 do
        local pos = math.random(1, #chars)
        out[#out + 1] = chars:sub(pos, pos)
    end
    return table.concat(out)
end

local function normalizeBase(url)
    url = trim(url)
    if url == "" then url = DEFAULT_BASE end
    if not url:match("^https?://") then url = "https://" .. url end
    if url:sub(-1) == "/" then url = url:sub(1, -2) end
    return url
end

local function getCfg(settings)
    return settings:get("sources", {}).zhiqiu or {}
end

local function saveCfg(settings, cfg)
    local sources = settings:get("sources", {})
    sources.zhiqiu = cfg
    settings:set("sources", sources)
    settings:flush()
end

local function resolveAndroidId(settings)
    local cfg = getCfg(settings)
    local aid = trim(cfg.android_id)
    if aid == "" then
        aid = generateAndroidId()
        cfg.android_id = aid
        saveCfg(settings, cfg)
    end
    return aid
end

--- GET 请求，回调 cb(body, code) 或 cb(nil, err)
local function httpGet(url, headers, timeout, cb)
    local h = { ["User-Agent"] = USER_AGENT }
    for k, v in pairs(headers or {}) do h[k] = v end
    return Request.request({
        url = url,
        method = "GET",
        headers = h,
        timeout = timeout or require("http.timeout").net(1),
        allow_redirects = true,
    }, function(res, err)
        if err or not res then
            cb(nil, err and tostring(err) or _("网络请求失败"))
            return
        end
        cb(res.body, tonumber(res.code))
    end)
end

--- 带 Token 的 GET，回调 cb(data, err)
local function apiGet(settings, path, extra_headers, timeout, cb)
    local cfg = getCfg(settings)
    local aid = resolveAndroidId(settings)
    local base = normalizeBase(cfg.server_url)
    local token = trim(cfg.token)
    if token == "" then
        M.ensureToken(settings, function(t, err)
            if not t then cb(nil, err); return end
            apiGet(settings, path, extra_headers, timeout, cb)
        end)
        return
    end
    local headers = {
        ["Accept"] = "application/json, text/plain, */*",
        ["x-sec-token"] = token,
        ["x-android-id"] = aid,
    }
    for k, v in pairs(extra_headers or {}) do headers[k] = v end
    return httpGet(base .. path, headers, timeout, function(body, code)
        if not body then cb(nil, code); return end
        if code < 200 or code >= 300 then
            cb(nil, string.format("HTTP %d", code))
            return
        end
        local ok, data = pcall(JSON.decode, body)
        if not ok or type(data) ~= "table" then
            cb(nil, _("响应非 JSON"))
            return
        end
        if data.code and tonumber(data.code) ~= 0 then
            cb(nil, string.format("code=%s %s",
                tostring(data.code), tostring(data.msg or data.error or "")))
            return
        end
        cb(data)
    end)
end

-- ── 铸币 ───────────────────────────────────────────────────

local function tryMint(base, aid, pw1, pw2, pw3, cb)
    local q = string.format("id=%s&pw1=%s&pw2=%s&pw3=%s",
        Text.urlEncode(aid), Text.urlEncode(pw1),
        Text.urlEncode(pw2), Text.urlEncode(pw3))
    return httpGet(base .. "/user/temp?" .. q, {
        ["x-sec-token"] = "",
        ["x-android-id"] = aid,
    }, require("http.timeout").net(1), function(body, code)
        if not body then cb(nil, code); return end
        if code < 200 or code >= 300 then
            cb(nil, string.format("HTTP %d", code))
            return
        end
        local ok, data = pcall(JSON.decode, body)
        if not ok or type(data) ~= "table" then
            cb(nil, _("响应非 JSON"))
            return
        end
        if data.code and tonumber(data.code) ~= 0 then
            cb(nil, string.format("code=%s %s",
                tostring(data.code), tostring(data.msg or data.error or "")))
            return
        end
        local token = trim((data.data or {}).token)
        if token == "" then cb(nil, _("服务端未返回 token")); return end
        cb(token)
    end)
end

--- 确保有可用 Token。cb(token, err)
function M.ensureToken(settings, cb)
    local cfg = getCfg(settings)
    local aid = resolveAndroidId(settings)
    local base = normalizeBase(cfg.server_url)
    local token = trim(cfg.token)
    local minted = tonumber(cfg.token_minted_at or 0) or 0
    if token ~= "" and (os.time() - minted) < 3 * 24 * 3600 then
        require("ui/uimanager"):nextTick(function() cb(token) end)
        return
    end
    local pw1 = trim(cfg.source_author)
    local pw2 = trim(cfg.group_id)
    local pw3 = trim(cfg.temp_token_pass)
    if pw1 == "" or pw2 == "" or pw3 == "" then
        cb(nil, _("知秋未填写 源作者/官方反馈群/临时Token口令"))
        return
    end
    tryMint(base, aid, pw1, pw2, pw3, function(t, err)
        if t then
            cfg.token = t
            cfg.token_minted_at = tostring(os.time())
            cfg.android_id = aid
            saveCfg(settings, cfg)
            cb(t)
            return
        end
        -- 用户已存在：换新 aid 再试
        if err and (err:find("用户已存在", 1, true) or err:find("HTTP 400", 1, true)) then
            local new_aid = generateAndroidId()
            tryMint(base, new_aid, pw1, pw2, pw3, function(t2, err2)
                if t2 then
                    cfg.token = t2
                    cfg.token_minted_at = tostring(os.time())
                    cfg.android_id = new_aid
                    saveCfg(settings, cfg)
                    cb(t2)
                else
                    cb(nil, _("换设备 ID 重试仍失败：") .. tostring(err2))
                end
            end)
            return
        end
        cb(nil, err)
    end)
end

-- ── 正文 ───────────────────────────────────────────────────

--- 拉单章正文。cb(result, err)。
---@return { cancel: fun() }
function M.getContentAsync(settings, book_id, item_id, cb)
    local cancelled = false
    local function fail(err)
        if not cancelled then cb(nil, err) end
    end
    local function doFetch()
        local cfg = getCfg(settings)
        local aid = resolveAndroidId(settings)
        local base = normalizeBase(cfg.server_url)
        local token = trim(cfg.token)
        local q = string.format("novelId=%s&chapId=%s",
            Text.urlEncode(tostring(book_id)), Text.urlEncode(tostring(item_id)))
        return httpGet(base .. "/novel/chap?" .. q, {
            ["x-sec-token"] = token,
            ["x-android-id"] = aid,
        }, require("http.timeout").net(1), function(body, code)
            if cancelled then return end
            if not body then fail(code); return end
            if code == 401 then
                local cfg2 = getCfg(settings)
                cfg2.token = ""
                saveCfg(settings, cfg2)
                M.ensureToken(settings, function(t2, err2)
                    if cancelled then return end
                    if not t2 then fail(err2); return end
                    doFetch()
                end)
                return
            end
            if code < 200 or code >= 300 then fail(string.format("HTTP %d", code)); return end
            local ok, obj = pcall(JSON.decode, body)
            if not ok or type(obj) ~= "table" then fail(_("响应非 JSON")); return end
            if obj.code and tonumber(obj.code) ~= 0 and obj.error then
                fail(tostring(obj.error)); return
            end
            local data = obj.data or obj
            local content = tostring(data.content or "")
            if #content < 10 then fail(_("正文过短")); return end
            cb({
                content = content,
                title = tostring(data.title or ""),
                author = tostring(data.author or ""),
                para_reviews = {},
            })
        end)
    end
    local cfg = getCfg(settings)
    if trim(cfg.token) == "" then
        M.ensureToken(settings, function(t, err)
            if cancelled then return end
            if not t then fail(err); return end
            doFetch()
        end)
    else
        doFetch()
    end
    return { cancel = function() cancelled = true end }
end

-- ── 段评 ───────────────────────────────────────────────────

--- 本章有段评的段落。cb(hotspots, err)。
---@return { cancel: fun() }
function M.hotspotsAsync(settings, book_id, item_id, cb)
    local cancelled = false
    local path = string.format("/novel/comment/paragraph_info?bid=%s&cid=%s",
        Text.urlEncode(tostring(book_id)), Text.urlEncode(tostring(item_id)))
    local job = apiGet(settings, path, nil, require("http.timeout").net(1), function(data, err)
        if cancelled then return end
        if not data then cb(nil, err); return end
        local pinfo = data.data or data
        local out = {}
        for pid, info in pairs(pinfo) do
            local n = tonumber(pid)
            local count = type(info) == "table" and tonumber(info.count) or 0
            if n and count and count > 0 then
                out[#out + 1] = {
                    range = string.format("zhiqiu:%s:%s:%d",
                        tostring(book_id), tostring(item_id), n),
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
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

--- 某段的一页评论。cb(page, err)。
---@return { cancel: fun() }
function M.pageAsync(settings, book_id, item_id, pid, max_idx, cb)
    local cancelled = false
    local size = 30
    local offset = tonumber(max_idx) or 0
    local page = math.floor(offset / size) + 1
    local path = string.format(
        "/novel/comment/paragraph_list?bid=%s&cid=%s&pid=%s&page=%d&size=%d",
        Text.urlEncode(tostring(book_id)), Text.urlEncode(tostring(item_id)),
        Text.urlEncode(tostring(pid)), page, size)
    local job = apiGet(settings, path, nil, require("http.timeout").net(1), function(data, err)
        if cancelled then return end
        if not data then cb(nil, err); return end
        local d = data.data or {}
        local list = d.data_list or {}
        local info = d.common_list_info or {}
        local items = {}
        for _, entry in ipairs(list) do
            local c = entry.comment or entry
            local common = c.common or {}
            local content = common.content or {}
            local user = common.user_info or {}
            local base_info = user.base_info or user
            local stat = c.stat or {}
            local created = tonumber(common.create_timestamp or common.create_time) or 0
            items[#items + 1] = {
                id = tostring(c.comment_id or ""),
                author = tostring(base_info.user_name or ""),
                content = tostring(content.text or common.text or ""),
                likes = tonumber(stat.digg_count) or 0,
                replies = tonumber(stat.reply_count) or 0,
                time = created > 1e11 and math.floor(created / 1000) or created,
                images = content.image_data_list,
            }
        end
        local next_offset = offset + #items
        local has_more = info.has_more
        if has_more == nil then has_more = (#items >= size) end
        cb({
            items = items,
            total = tonumber(info.total) or next_offset,
            max_idx = next_offset,
            more = has_more == true and #items > 0,
        })
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

--- 某条评论的回复。cb(page, err)。
---@return { cancel: fun() }
function M.repliesAsync(settings, book_id, comment_id, max_idx, cb)
    local cancelled = false
    local size = 20
    local offset = tonumber(max_idx) or 0
    local page = math.floor(offset / size) + 1
    local path = string.format("/novel/comment/reply?bid=%s&rid=%s&page=%d&size=%d",
        Text.urlEncode(tostring(book_id)), Text.urlEncode(tostring(comment_id)), page, size)
    local job = apiGet(settings, path, nil, require("http.timeout").net(1), function(data, err)
        if cancelled then return end
        if not data then cb(nil, err); return end
        local d = data.data or {}
        local list = d.reply_list or {}
        local info = d.comment_list_info or {}
        local items = {}
        for _, entry in ipairs(list) do
            local common = entry.Common or entry.common or {}
            local content = common.content or {}
            local user = common.user_info or {}
            local base_info = user.base_info or user
            local stat = entry.stat or {}
            local to_info = entry.reply_to_user_info or {}
            local to_base = to_info.base_info or to_info
            local created = tonumber(common.create_timestamp or common.create_time) or 0
            items[#items + 1] = {
                id = tostring(entry.reply_id or ""),
                author = tostring(base_info.user_name or ""),
                content = tostring(content.text or ""),
                likes = tonumber(stat.digg_count) or 0,
                replies = 0,
                reply_to = (type(to_base.user_name) == "string" and to_base.user_name ~= "")
                    and to_base.user_name or nil,
                time = created > 1e11 and math.floor(created / 1000) or created,
                images = content.image_data_list,
            }
        end
        local next_offset = offset + #items
        local has_more = info.has_more
        if has_more == nil then has_more = (#items >= size) end
        cb({
            items = items,
            total = tonumber(info.total) or next_offset,
            max_idx = next_offset,
            more = has_more == true and #items > 0,
        })
    end)
    return { cancel = function()
        cancelled = true
        if job and job.cancel then job.cancel() end
    end }
end

return M
