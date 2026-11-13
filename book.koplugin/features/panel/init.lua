--[[--
快捷面板：把桌面 / 阅读面板 Tab 注入 KOReader 原生顶部菜单。

实现在 `native.lua`；桌面其它模块（顶栏、夜间模式、设置页）直接 require 子模块，不经这里。

@module koplugin.book.features.panel
--]]

require("l10n").apply()
local _ = require("gettext")

local Panel = {}

--- Dispatcher 动作定义。
--- title 统一带「月读：」前缀；general / reader 二选一，按动作实际能力标定。
local DISPATCHER_ACTIONS = {
    { id = "remote",              title = _("月读：远程管理"),      general = true },
    { id = "toc",                 title = _("月读：目录"),          reader = true },
    { id = "push_progress",       title = _("月读：上传进度"),      reader = true },
    { id = "pull_progress",       title = _("月读：拉取进度"),      reader = true },
    { id = "reload_chapter",      title = _("月读：重载章节"),      reader = true },
    { id = "bookorbit",           title = _("月读：BookOrbit"),     general = true },
    { id = "xray",                title = _("月读：X-Ray"),         reader = true },
    { id = "settings",            title = _("月读：阅读设置"),      reader = true },
    { id = "reviews_show",        title = _("月读：显示段评"),      reader = true },
    { id = "wechat_bind",         title = _("月读：关联微信读书"),  reader = true },
    { id = "reviews_link_switch", title = _("月读：拉取微信评论"),  reader = true },
}

--- 注册所有月读快捷面板动作为系统动作。
local function registerDispatcherActions()
    local Dispatcher = require("dispatcher")
    for _idx, item in ipairs(DISPATCHER_ACTIONS) do
        local opts = {
            category = "none",
            event    = "BookQuickAction",
            arg      = item.id,
            title    = item.title,
        }
        if item.reader then
            opts.reader = true
        else
            opts.general = true
        end
        Dispatcher:registerAction("book_qp_" .. item.id, opts)
    end
end

--- 新增：判断动作是否要求阅读文档
local function requiresDocument(id)
    for _idx, item in ipairs(DISPATCHER_ACTIONS) do
        if item.id == id then return item.reader == true end
    end
    return false
end

---@param plugin BookPlugin
function Panel.onCreate(plugin)
    require("features.panel.native").onCreate(plugin.ui)
    registerDispatcherActions()

    require("dispatcher"):registerAction("book_close_to_desktop", {
        category = "none",
        event = "BookCloseToDesktop",
        title = _("退出阅读回到月读"),
        reader = true,
    })
    -- 新增：注册“关闭桌面”系统动作
    require("dispatcher"):registerAction("book_close_desktop", {
        category = "none",
        event = "BookCloseDesktop",
        title = _("月读：关闭桌面"),
        general = true,
    })
end

Panel.events = {
    ---@param plugin BookPlugin
    BookCloseToDesktop = function(plugin)
        if not plugin.ui.document then return false end
        require("desktop.reader_exit").closeToDesktop(plugin.ui)
        return true
    end,

    --- Dispatcher 统一入口：arg 为动作 id。
    ---@param plugin BookPlugin
    ---@param arg string|nil
    BookQuickAction = function(plugin, arg)
        if not arg then return false end
        local Registry = require("features.panel.actions.registry")
        local action = Registry.get(arg)
        if not action then return false end

        if requiresDocument(arg) and not (plugin.ui and plugin.ui.document) then
            return false
        end

        if action.scope == "reader" then
            require("features.panel.reader").executeAction(arg, plugin.ui, {})
        else
            require("features.panel.desktop").executeAction(arg, {})
        end
        return true
    end,
    BookCloseDesktop = function(plugin)
        -- 检查当前实例是否挂载了月读桌面
        if plugin.desktop then
            plugin.desktop:onClose()
            return true
        end
        return false
    end,
}

---@param plugin BookPlugin
function Panel.onReaderReady(plugin)
    require("features.panel.native").onCreate(plugin.ui, { reader = true })
end

-- 扩展点登记（features 加载器 require 本模块时执行一次；见 utils/extension.lua）。
local Ext = require("utils.extension")
Ext.add("quickpanel.show", function(scope) return require("features.panel.native").show(scope) end)
Ext.add("topbar.light_percent", function(kind) return require("features.panel.desktop").lightPercent(kind) end)

return Panel
