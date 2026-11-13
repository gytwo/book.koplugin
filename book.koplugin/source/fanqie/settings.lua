--[[--
番茄源配置：落在 utils.settings.getSource("fanqie")。

@module koplugin.book.source.fanqie.settings
--]]

local SOURCE_ID = "fanqie"

---@class FanqieSettings
---@field cfg table
---@field get fun(self: FanqieSettings, key: string, default: any): any
---@field set fun(self: FanqieSettings, key: string, value: any)
---@field flush fun(self: FanqieSettings)
---@field is_cookie_configured fun(self: FanqieSettings): boolean

local Settings = {}
Settings.__index = Settings

-- 书源默认配置。只在缺失时补，不覆盖用户已改的值。
local DEFAULT_SOURCES = {
    official = {
        enabled = true,
        order = 1,
        rate_limit = { max_requests = 0, window_seconds = 0 },
    },
    zhiqiu = {
        enabled = false,
        order = 2,
        server_url = "https://fq.vv9v.cn",
        token = "",
        token_minted_at = "",
        android_id = "",
        source_author = "知秋",
        group_id = "755947375",
        temp_token_pass = "天一团队是倒狗(qq为1070240776和845646066和1484608559)请勿相信任何需要付费的说法欢迎来官方反馈群举报",
        rate_limit = { max_requests = 300, window_seconds = 60 },
    },
    shushan = {
        enabled = false,
        order = 3,
        server_url = "https://v2.vossc.com",
        email = "",
        password = "",
        api_key = "",
        api_key_at = "",
        android_id = "",
        device_type = "android",
        source = "番茄小说",
        tab = "novel",
        content_version = "12",
        rate_limit = { max_requests = 10, window_seconds = 30 },
    },
}

local function deepcopy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = deepcopy(x) end
    return out
end

--- 把默认配置补进 cfg.sources。只在缺失时补，不覆盖用户已改的。
---@param cfg table
---@return boolean changed
local function ensureSources(cfg)
    local changed = false
    if type(cfg.sources) ~= "table" then
        cfg.sources = {}
        changed = true
    end
    for id, def in pairs(DEFAULT_SOURCES) do
        if type(cfg.sources[id]) ~= "table" then
            cfg.sources[id] = deepcopy(def)
            changed = true
        else
            for k, v in pairs(def) do
                if cfg.sources[id][k] == nil then
                    cfg.sources[id][k] = deepcopy(v)
                    changed = true
                end
            end
            if type(cfg.sources[id].rate_limit) == "table"
                and type(def.rate_limit) == "table" then
                for k, v in pairs(def.rate_limit) do
                    if cfg.sources[id].rate_limit[k] == nil then
                        cfg.sources[id].rate_limit[k] = v
                        changed = true
                    end
                end
            end
        end
    end
    return changed
end

---@return FanqieSettings
function Settings:new()
    local MoonSettings = require("utils.settings")
    local cfg = MoonSettings.getSource(SOURCE_ID)
    if ensureSources(cfg) then
        MoonSettings.saveSource(SOURCE_ID, cfg)
    end
    return setmetatable({ cfg = cfg }, self)
end

---@param key string
function Settings:get(key, default)
    local value = self.cfg[key]
    if value == nil then return default end
    return value
end

---@param key string
function Settings:set(key, value)
    self.cfg[key] = value
end

function Settings:flush()
    require("utils.settings").saveSource(SOURCE_ID, self.cfg)
end

---@return boolean
function Settings:is_cookie_configured()
    local cookies = self.cfg.cookies
    return type(cookies) == "table"
        and type(cookies.sessionid) == "string"
        and cookies.sessionid ~= ""
end

return Settings
