--[[--
段评的阅读快捷面板：绑定、开关与拉取。
@module koplugin.book.features.reviews.panel
--]]

require("l10n").apply()
local _ = require("gettext")

local Panel = {}

---@return BookQuickPanelAction[]
function Panel.actions()
    return {
        {
            id = "review_bind",
            title = _("关联书源"),
            icon = "link",
            scope = "reader",
            available = function(ctx)
                local ui = ctx and ctx.ui
                if not ui then return true end
                local cur = require("reader.session").current()
                if cur and cur.identity and cur.identity.ephemeral then
                    return false
                end
                return true
            end,
            run = function(ctx)
                require("features.reviews.link").Bind.open(ctx.ui)
            end,
        },
        {
            id = "reviews_link_switch",
            title = _("拉取微信评论"), 
            icon = "forum",
            scope = "reader",
            available = function(ctx)
                local ui = ctx and ctx.ui
                return not ui or require("features.reviews.linked").supported(ui.document)
            end,
            keep_open = true,
            active = function(ctx)
                local ui = ctx and ctx.ui
                return ui ~= nil and require("features.reviews.linked").enabled(ui)
            end,
            run = function(ctx)
                require("features.reviews.link").openPull(ctx.ui)
            end,
        },
        {
            id = "fanqie_reviews_switch",
            title = _("拉取番茄段评"),
            icon = "forum",
            scope = "reader",
            keep_open = true,
            available = function(ctx)
                local ui = ctx and ctx.ui
                if not ui then return true end
                local book = require("features.reviews.linked").get(ui)
                return book ~= nil and book.fanqie ~= nil
            end,
            active = function(ctx)
                local ui = ctx and ctx.ui
                if not ui or not ui.doc_settings then return false end
                return ui.doc_settings:readSetting("fanqie_reviews_enabled") ~= false
            end,
            run = function(ctx)
                local ui = ctx.ui
                if not ui or not ui.doc_settings then return end
                local on = ui.doc_settings:readSetting("fanqie_reviews_enabled") ~= false
                ui.doc_settings:saveSetting("fanqie_reviews_enabled", not on)
                require("ui/uimanager"):setDirty(ui.dialog, "ui")
            end,
        },
        {
            id = "reviews_show",
            title = _("显示段评"), 
            icon = "forum",
            scope = "reader",
            keep_open = true,
            available = function(ctx)
                local ui = ctx and ctx.ui
                if not ui then return true end
                local cur = require("reader.session").current()
                local identity = cur and cur.identity
                if not identity or identity.ephemeral then return false end
                local source = identity.source
                if not source then return false end
                -- 只有支持段评能力的源才显示这个开关（如微信、番茄）
                return source.chapterReviewHotspotsAsync ~= nil or source.paragraphHotspotsAsync ~= nil
            end,
            active = function(ctx)
                local cur = require("reader.session").current()
                local identity = cur and cur.identity
                if not identity or not identity.source then return false end
                return identity.source:paragraphReviewsEnabled()
            end,
            run = function(ctx)
                local cur = require("reader.session").current()
                local identity = cur and cur.identity
                if not identity or not identity.source then return end
                local source = identity.source
                local enabled = source:paragraphReviewsEnabled()
                require("source.review_setting").set(source.id, not enabled)
                local ui = ctx.ui
                if ui and ui.dialog then
                    require("ui/uimanager"):setDirty(ui.dialog, "ui")
                end
            end,
        },
    }
end

return Panel
