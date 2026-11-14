--[[--
番茄源设置入口。

@module koplugin.book.source.fanqie.setting
--]]

local _ = require("l10n").get("source.fanqie")

local SOURCE_ID = "fanqie"
local M = {}

local SOURCE_NAMES = {
    official = _("官方源（App协议）"),
    zhiqiu = _("知秋四合一"),
    shushan = _("书山聚合"),
}
local SOURCE_ORDER = { "official", "zhiqiu", "shushan" }

function M.rowTitle()
    return _("番茄账号与登录")
end

function M.rowStatus()
    local ok = require("source.fanqie.settings"):new():is_cookie_configured()
    return ok and _("已登录") or _("未登录 · 点此扫码"), ok
end

function M.open()
    local settings = require("source.fanqie.settings"):new()
    local owner = {}
    function owner:closeBusy()
        if self.busy then self.busy:close(); self.busy = nil end
    end
    function owner:showBusy(text)
        self:closeBusy()
        self.busy = require("ui.themes.widgets.progress_dialog"):new{
            title = _("番茄扫码登录"), text = text, dismissable = false,
        }
        self.busy:show()
    end
    function owner:onLoginSuccess()
        require("source.auth").ok(SOURCE_ID)
        require("source.registry").reload()
    end
    require("ui/network/manager"):runWhenConnected(function()
        require("source.fanqie.qrlogin"):new(settings, owner):start()
    end)
end

-- ── 内部工具 ────────────────────────────────────────────────

local function saveSources(sources)
    local settings = require("source.fanqie.settings"):new()
    settings:set("sources", sources)
    settings:flush()
    require("source.registry").reload()
end

local function toast(text)
    require("ui.themes.widgets.toast"):new{ text = tostring(text), timeout = 2 }:show()
end

local function enabledCount(sources)
    local n = 0
    for _id, c in pairs(sources or {}) do
        if type(c) == "table" and c.enabled ~= false then n = n + 1 end
    end
    return n
end

--- 带 busy 的异步执行器：work(done)，done(result, err)。
--- 成功 → on_ok(result)；失败 → toast(err)。
---@param title string
---@param busy_text string
---@param work fun(done: fun(result: any, err: string|nil))
---@param on_ok fun(result: any)|nil
local function runWithBusy(title, busy_text, work, on_ok)
    local busy = require("ui/themes.widgets.progress_dialog"):new{
        title = title, text = busy_text, dismissable = false,
    }
    busy:show()
    work(function(result, err)
        busy:close()
        if err then
            toast(err)
        else
            if on_ok then on_ok(result) end
        end
    end)
end

-- ── 书源管理 ────────────────────────────────────────────────

function M.openSourceMenu(plugin)
    local settings = require("source.fanqie.settings"):new()
    local sources = settings:get("sources", {})
    local List = require("ui.themes.widgets.list")
    local items = {}

    -- 按 cfg.order 排序（不写死 SOURCE_ORDER，否则上移/下移在列表里看不出来）
    local ordered = {}
    for id in pairs(SOURCE_NAMES) do
        local cfg = sources[id] or {}
        ordered[#ordered + 1] = { id = id, order = cfg.order or 999 }
    end
    table.sort(ordered, function(a, b) return a.order < b.order end)

    for _i, item in ipairs(ordered) do
        local id = item.id
        local cfg = sources[id] or {}
        local enabled = cfg.enabled ~= false
        local mark = enabled and "●" or "○"
        local status
        if id == "official" then
            status = _("无需配置")
        elseif id == "zhiqiu" then
            local ok = (cfg.token or "") ~= ""
                or ((cfg.source_author or "") ~= "" and (cfg.group_id or "") ~= ""
                    and (cfg.temp_token_pass or "") ~= "")
            status = ok and _("已配置") or _("未配置")
        elseif id == "shushan" then
            local ok = (cfg.api_key or "") ~= ""
                or ((cfg.email or "") ~= "" and (cfg.password or "") ~= "")
            status = ok and _("已配置") or _("未配置")
        end
        items[#items + 1] = {
            text = mark .. " " .. SOURCE_NAMES[id],
            mandatory = status,
            callback = function() M.openSourceDetail(plugin, id) end,
        }
    end
    List:new{
        title = _("书源管理"),
        items = items,
        item_per_page = 10,
    }:show()
end

function M.openSourceDetail(plugin, id)
    local settings = require("source.fanqie.settings"):new()
    local sources = settings:get("sources", {})
    local cfg = sources[id] or {}
    local List = require("ui.themes.widgets.list")
    local items = {}

    if id ~= "official" then
        local on = cfg.enabled ~= false
        items[#items + 1] = {
            text = on and _("禁用此源") or _("启用此源"),
            callback = function()
                cfg.enabled = not on
                sources[id] = cfg
                saveSources(sources)
                M.openSourceDetail(plugin, id)
            end,
        }
    end

    if id == "zhiqiu" then
        items[#items + 1] = {
            text = _("服务器地址"),
            mandatory = cfg.server_url or "https://fq.vv9v.cn",
            callback = function() M.editString(plugin, id, "server_url", _("服务器地址")) end,
        }
        items[#items + 1] = {
            text = _("共享 Token"),
            mandatory = (cfg.token or "") ~= "" and _("已配置") or _("未配置"),
            callback = function() M.editString(plugin, id, "token", _("共享 Token")) end,
        }
        items[#items + 1] = {
            text = _("源作者（pw1）"),
            mandatory = (cfg.source_author or "") ~= "" and _("已填") or _("未填"),
            callback = function() M.editString(plugin, id, "source_author", _("源作者")) end,
        }
        items[#items + 1] = {
            text = _("官方反馈群（pw2）"),
            mandatory = (cfg.group_id or "") ~= "" and _("已填") or _("未填"),
            callback = function() M.editString(plugin, id, "group_id", _("官方反馈群")) end,
        }
        items[#items + 1] = {
            text = _("临时 Token 口令（pw3）"),
            mandatory = (cfg.temp_token_pass or "") ~= "" and _("已填") or _("未填"),
            callback = function() M.editString(plugin, id, "temp_token_pass", _("临时 Token 口令")) end,
        }
        items[#items + 1] = {
            text = _("获取共享 Token"),
            callback = function() M.zhiqiuMintToken(plugin, id) end,
        }
    end

    if id == "shushan" then
        items[#items + 1] = {
            text = _("服务器地址"),
            mandatory = cfg.server_url or "https://v2.vossc.com",
            callback = function() M.editString(plugin, id, "server_url", _("服务器地址")) end,
        }
        items[#items + 1] = {
            text = _("邮箱"),
            mandatory = (cfg.email or "") ~= "" and _("已填") or _("未填"),
            callback = function() M.editString(plugin, id, "email", _("邮箱")) end,
        }
        items[#items + 1] = {
            text = _("密码"),
            mandatory = (cfg.password or "") ~= "" and _("已填") or _("未填"),
            callback = function() M.editString(plugin, id, "password", _("密码")) end,
        }
        items[#items + 1] = {
            text = _("Android ID"),
            mandatory = (cfg.android_id or "") ~= "" and _("已填") or _("未填（读正文必填）"),
            callback = function() M.editString(plugin, id, "android_id", _("Android ID（16/32位hex）")) end,
        }
        items[#items + 1] = {
            text = _("api_key 状态"),
            mandatory = (cfg.api_key or "") ~= "" and _("已获取") or _("未获取"),
        }
        items[#items + 1] = {
            text = _("登录测试"),
            callback = function() M.shushanLogin(plugin, id) end,
        }
        items[#items + 1] = {
            text = _("服务器测速"),
            callback = function() M.shushanSpeedTest(plugin, id) end,
        }
    end

    local rl = cfg.rate_limit or {}
    items[#items + 1] = {
        text = _("限流"),
        mandatory = string.format("%d 次 / %d 秒", rl.max_requests or 0, rl.window_seconds or 30),
        callback = function() M.editRateLimit(plugin, id) end,
    }
    items[#items + 1] = {
        text = _("上移"),
        callback = function() M.moveSource(plugin, id, -1) end,
    }
    items[#items + 1] = {
        text = _("下移"),
        callback = function() M.moveSource(plugin, id, 1) end,
    }

    List:new{
        title = SOURCE_NAMES[id] or id,
        items = items,
        item_per_page = 14,
    }:show()
end

function M.editString(plugin, id, key, label)
    local settings = require("source.fanqie.settings"):new()
    local sources = settings:get("sources", {})
    local cfg = sources[id] or {}
    require("ui/themes/widgets/input"):new{
        title = label,
        fields = { { text = cfg[key] or "", hint = label } },
        callback = function(value)
            cfg[key] = value
            sources[id] = cfg
            saveSources(sources)
            M.openSourceDetail(plugin, id)
        end,
    }:show()
end

function M.editRateLimit(plugin, id)
    local settings = require("source.fanqie.settings"):new()
    local sources = settings:get("sources", {})
    local cfg = sources[id] or {}
    local rl = cfg.rate_limit or { max_requests = 0, window_seconds = 30 }
    require("ui/themes/widgets/input"):new{
        title = _("限流：最大请求数 / 时间窗口（秒）"),
        fields = {
            { text = tostring(rl.max_requests or 0), hint = _("0 = 无限制") },
            { text = tostring(rl.window_seconds or 30), hint = _("秒") },
        },
        callback = function(a, b)
            cfg.rate_limit = {
                max_requests = tonumber(a) or 0,
                window_seconds = tonumber(b) or 30,
            }
            sources[id] = cfg
            saveSources(sources)
            M.openSourceDetail(plugin, id)
        end,
    }:show()
end

function M.moveSource(plugin, id, direction)
    local settings = require("source.fanqie.settings"):new()
    local sources = settings:get("sources", {})
    -- 先按当前 order 排，再重编号 1..n（旧配置全是 999 时交换无效）
    local ordered = {}
    for sid, c in pairs(sources) do
        if type(c) == "table" then
            ordered[#ordered + 1] = { id = sid, order = c.order or 999 }
        end
    end
    table.sort(ordered, function(a, b) return a.order < b.order end)
    for i, item in ipairs(ordered) do
        sources[item.id].order = i
    end
    -- 找当前 id 的位置
    local idx
    for i, item in ipairs(ordered) do
        if item.id == id then idx = i break end
    end
    if not idx then return end
    local target = idx + direction
    if target < 1 or target > #ordered then
        M.openSourceDetail(plugin, id)
        return
    end
    -- 交换相邻两项的 order
    local a, b = ordered[idx], ordered[target]
    sources[a.id].order, sources[b.id].order = sources[b.id].order, sources[a.id].order
    saveSources(sources)
    M.openSourceDetail(plugin, id)
end

function M.zhiqiuMintToken(plugin, id)
    local settings = require("source.fanqie.settings"):new()
    runWithBusy(_("知秋 Token"), _("正在获取共享 Token..."), function(done)
        require("source.fanqie.zhiqiu").ensureToken(settings, done)
    end, function()
        toast(_("Token 已就绪"))
        M.openSourceDetail(plugin, id)
    end)
end

function M.shushanLogin(plugin, id)
    local settings = require("source.fanqie.settings"):new()
    runWithBusy(_("书山登录"), _("正在登录书山..."), function(done)
        require("source.fanqie.shushan").login(settings, done)
    end, function()
        toast(_("书山登录成功"))
        M.openSourceDetail(plugin, id)
    end)
end

function M.shushanSpeedTest(plugin, id)
    local settings = require("source.fanqie.settings"):new()
    runWithBusy(_("书山测速"), _("正在测速所有线路..."), function(done)
        require("source.fanqie.shushan").selectFastest(settings, function(result, err)
            if err or not result or not result.best then
                done(nil, err or (result and result.err) or _("测速失败"))
            else
                done(result.best)
            end
        end)
    end, function(best)
        toast(_("已切换到最快线路：") .. tostring(best))
        M.openSourceDetail(plugin, id)
    end)
end

function M.rows(plugin)
    local Row = require("ui.themes.widgets.row")
    local rows = {
        function(iw)
            local status, status_on = M.rowStatus()
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "account_circle",
                title = M.rowTitle(), status = status, status_on = status_on,
                callback = function() M.open() end })
        end,
        function(iw)
            local settings = require("source.fanqie.settings"):new()
            local on = settings:get("show_paragraph_reviews", false) == true
            return Row.widget({ width = iw, chevron = false, kind = "toggle", icon = "forum",
                title = _("显示段评"), subtitle = _("阅读时给有他人段评的段落末尾画线，点按查看；需联网"),
                status = on and _("开") or _("关"), status_on = on,
                callback = function()
                    settings:set("show_paragraph_reviews", not on)
                    settings:flush()
                    if plugin and plugin.desktop then plugin.desktop:updateView() end
                end })
        end,
        function(iw)
            local settings = require("source.fanqie.settings"):new()
            local n = enabledCount(settings:get("sources", {}))
            return Row.widget({ width = iw, chevron = true, kind = "nav", icon = "dns",
                title = _("书源管理"),
                subtitle = _("官方 / 知秋 / 书山，按顺序回退"),
                status = string.format(_("%d 个启用"), n),
                callback = function() M.openSourceMenu(plugin) end })
        end,
        require("source.category_setting").row("fanqie", plugin),
    }
    local _status, logged_in = M.rowStatus()
    if logged_in then
        rows[#rows + 1] = require("source.logout").row("fanqie", _("确定退出番茄账号？"), function()
            local settings = require("source.fanqie.settings"):new()
            settings:set("cookies", nil)
            settings:flush()
        end)
    end
    return rows
end

return M
