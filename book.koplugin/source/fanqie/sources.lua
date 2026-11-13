--[[--
番茄书源管理器：注册表 + 滑动窗口限流 + 按 order 排序启用源。

@module koplugin.book.source.fanqie.sources
--]]

local SourceManager = {}

SourceManager.REGISTRY = {
    official = { name = "官方源（App协议）", configurable = false },
    zhiqiu   = { name = "知秋四合一", configurable = true },
    shushan  = { name = "书山聚合", configurable = true },
}

-- 模块级限流状态：source_id -> { 时间戳数组 }
-- 子进程 fork 出的副本记录会丢，需经 merge_rate_limit_timestamps 回传父进程。
local RATE_LIMIT_TIMESTAMPS = {}

---@param source_id string
---@param max_requests number|nil 0/nil = 无限制
---@param window_seconds number|nil
---@return boolean ok, number wait_seconds, number|nil recorded_ts
function SourceManager.rate_limit_check(source_id, max_requests, window_seconds)
    if not max_requests or max_requests <= 0 then
        return true, 0, nil
    end
    window_seconds = window_seconds or 30
    local now = os.time()
    local stamps = RATE_LIMIT_TIMESTAMPS[source_id] or {}
    local valid = {}
    for _, ts in ipairs(stamps) do
        if now - ts < window_seconds then valid[#valid + 1] = ts end
    end
    if #valid >= max_requests then
        local wait = window_seconds - (now - valid[1])
        return false, (wait > 0 and wait or 0), nil
    end
    valid[#valid + 1] = now
    RATE_LIMIT_TIMESTAMPS[source_id] = valid
    return true, 0, now
end

---@param source_id string
---@param max_requests number|nil
---@param window_seconds number|nil
---@return boolean would_ok, number wait_seconds
function SourceManager.rate_limit_peek(source_id, max_requests, window_seconds)
    if not max_requests or max_requests <= 0 then
        return true, 0
    end
    window_seconds = window_seconds or 30
    local now = os.time()
    local valid = {}
    for _, ts in ipairs(RATE_LIMIT_TIMESTAMPS[source_id] or {}) do
        if now - ts < window_seconds then valid[#valid + 1] = ts end
    end
    if #valid >= max_requests then
        return false, math.max(0, window_seconds - (now - valid[1]))
    end
    return true, 0
end

--- 子进程记录的限流时间戳回传父进程后合并。
---@param recorded { source_id: string, ts: number }[]|nil
function SourceManager.merge_rate_limit_timestamps(recorded)
    if not recorded then return end
    for _, entry in ipairs(recorded) do
        if entry and entry.source_id and entry.ts then
            local stamps = RATE_LIMIT_TIMESTAMPS[entry.source_id] or {}
            local found = false
            for _, ts in ipairs(stamps) do
                if ts == entry.ts then found = true break end
            end
            if not found then
                stamps[#stamps + 1] = entry.ts
                RATE_LIMIT_TIMESTAMPS[entry.source_id] = stamps
            end
        end
    end
end

function SourceManager.rate_limit_reset(source_id)
    RATE_LIMIT_TIMESTAMPS[source_id] = nil
end

---@param source_id string
---@param cfg table
---@return boolean
function SourceManager.is_configured(source_id, cfg)
    cfg = cfg or {}
    if source_id == "official" then
        -- 官方源走 App reading 协议，只需设备身份（首次自动注册），不需登录。
        return true
    elseif source_id == "zhiqiu" then
        local token = tostring(cfg.token or ""):match("^%s*(.-)%s*$")
        if token ~= "" then return true end
        local pw1 = tostring(cfg.source_author or ""):match("^%s*(.-)%s*$")
        local pw2 = tostring(cfg.group_id or ""):match("^%s*(.-)%s*$")
        local pw3 = tostring(cfg.temp_token_pass or ""):match("^%s*(.-)%s*$")
        return pw1 ~= "" and pw2 ~= "" and pw3 ~= ""
    elseif source_id == "shushan" then
        local key = tostring(cfg.api_key or ""):match("^%s*(.-)%s*$")
        if key ~= "" then return true end
        local email = tostring(cfg.email or ""):match("^%s*(.-)%s*$")
        local password = tostring(cfg.password or ""):match("^%s*(.-)%s*$")
        return email ~= "" and password ~= ""
    end
    return false
end

--- 已启用 + 已配置的源，按 order 升序。
---@param settings FanqieSettings
---@return { id: string, config: table, meta: table }[]
function SourceManager.get_active_sources(settings)
    local sources_cfg = settings:get("sources", {})
    local list = {}
    for source_id, meta in pairs(SourceManager.REGISTRY) do
        local cfg = sources_cfg[source_id]
        if cfg and cfg.enabled ~= false
            and SourceManager.is_configured(source_id, cfg) then
            list[#list + 1] = { id = source_id, config = cfg, meta = meta }
        end
    end
    table.sort(list, function(a, b)
        return (a.config.order or 999) < (b.config.order or 999)
    end)
    return list
end

--- 所有注册源（含禁用/未配置），按 order 升序，供菜单显示。
---@param settings FanqieSettings
---@return { id: string, config: table, meta: table }[]
function SourceManager.get_all_sources(settings)
    local sources_cfg = settings:get("sources", {})
    local list = {}
    for source_id, meta in pairs(SourceManager.REGISTRY) do
        local cfg = sources_cfg[source_id] or {}
        list[#list + 1] = { id = source_id, config = cfg, meta = meta }
    end
    table.sort(list, function(a, b)
        return (a.config.order or 999) < (b.config.order or 999)
    end)
    return list
end

return SourceManager
