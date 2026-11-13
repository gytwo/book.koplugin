--[[--
快捷面板配置键（settings/panel.lua）与设置：桌面 / 阅读两个面板编辑页，挂在根页对应分组。
编辑行与预览在 features.panel.settings。

@module koplugin.book.features.panel.setting
--]]

local _ = require("gettext")

local Setting = {}

Setting.defaults = {
    quick_panel_plugins = {},
    quick_panel_actions = {
        "night", "wifi", "tasks", "remote", "rotate", "refresh", "screenshot", "frontlight", "autolight", "suspend", "power",
    },
    quick_panel_brightness = true,
    quick_panel_warmth = true,
    quick_panel_reader_actions = { "toc", "auto_toc", "font", "reflow", "highlights", "cache", "bookorbit", "xray", "page_turn", "settings" },
    show_desktop_tab = true,
    show_reader_tab = true,
}

function Setting.entries(desktop)
    local QuickPanel = require("features.panel.settings")
    local T = require("ffi/util").template
    local MoonSettings = require("utils.settings")
    local Row = require("ui/themes/widgets/row")

    return {
        -- 桌面快捷面板（归属 desktop 组）
        {
            id = "panel_desktop", group = "desktop", order = 30,
            icon = "dashboard_customize",
            title = _("桌面快捷面板"),
            subtitle = _("面板开关与项目排序"),
            status = T(_("已启用 %1 项"), QuickPanel.enabledCount("desktop")),
            status_on = true,
            page = {
                title = _("桌面快捷面板"),
                docs = "/manual/desktop/actions",
                preview = function(width) return QuickPanel.preview("desktop", width) end,
                sections = function()
                    local rows = {}
                    -- 1. 桌面开关
                    table.insert(rows, function(iw)
                        local enabled = MoonSettings.get("features.panel").show_desktop_tab ~= false
                        return Row.widget({
                            width = iw, icon = "tab",
                            title = _("启用桌面快捷面板"),
                            toggle = enabled,
                            callback = function()
                                MoonSettings.get("features.panel").show_desktop_tab = not enabled
                                MoonSettings.save("features.panel")
                                desktop:updateView()
                            end,
                        })
                    end)
                    -- 2. 桌面动作列表
                    for _, row in ipairs(QuickPanel.rows("desktop", desktop)) do
                        rows[#rows + 1] = row
                    end
                    return { { title = _("桌面"), rows = rows } }
                end,
            },
        },
        -- 阅读快捷面板（归属 reader 组）
        {
            id = "panel_reader", group = "reader", order = 30,
            icon = "dashboard_customize",
            title = _("阅读快捷面板"),
            subtitle = _("面板开关与项目排序"),
            status = T(_("已启用 %1 项"), QuickPanel.enabledCount("reader")),
            status_on = true,
            page = {
                title = _("阅读快捷面板"),
                docs = "/manual/reader/ui/panel",
                preview = function(width) return QuickPanel.preview("reader", width) end,
                sections = function()
                    local rows = {}
                    -- 1. 阅读开关
                    table.insert(rows, function(iw)
                        local enabled = MoonSettings.get("features.panel").show_reader_tab ~= false
                        return Row.widget({
                            width = iw, icon = "tab",
                            title = _("启用阅读快捷面板"),
                            toggle = enabled,
                            callback = function()
                                MoonSettings.get("features.panel").show_reader_tab = not enabled
                                MoonSettings.save("features.panel")
                                desktop:updateView()
                            end,
                        })
                    end)
                    -- 2. 阅读动作列表
                    for _, row in ipairs(QuickPanel.rows("reader", desktop)) do
                        rows[#rows + 1] = row
                    end
                    return { { title = _("阅读"), rows = rows } }
                end,
            },
        },
    }
end

return Setting
