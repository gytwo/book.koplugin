local Ext = require("utils.extension")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local _ = require("gettext")
local logger = require("logger")

-- 检测 QuickUI 是否被系统加载
local function isQuickUILoaded()
    local ok, loader = pcall(require, "pluginloader")
    if not ok or not loader then return false end
    return loader.loaded_plugins and loader.loaded_plugins["quickui"] ~= nil
end

Ext.add("desktop.tabs", {
    id = "quickui_vb",
    text = _("Qui-侧边栏"),
    icon = "hexagon",
    after = "insight",
    
    enabled = function()
        return isQuickUILoaded()
    end,
    
    tap = function()
        logger.info("QuickUI_VB: tap 触发，准备发送广播事件")
        
        -- ★ 使用广播形式触发 QuickUI 的事件
        local ok, err = pcall(function()
            UIManager:broadcastEvent(Event:new("QuickUI_VerticalBarToggle"))
        end)
        
    end,
})

return {}
