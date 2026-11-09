--[[--
段评的阅读快捷面板：绑定、开关与显示段评。

@module koplugin.book.features.reviews.panel
--]]

require("l10n").apply()

local _ = require("gettext")

local Panel = {}

---@return BookQuickPanelAction[]
function Panel.actions()
    return {
        {
            id = "wechat_bind",
            title = _("关联微信读书"),
            icon = "link",
            scope = "reader",
            -- 👇 只要不是订阅文章（ephemeral），统统允许绑定（包括 PDF）
            available = function(ctx)
                local ui = ctx and ctx.ui
                if not ui then return false end
                local cur = require("reader.session").current()
                if not cur or not cur.identity then return false end
                return not cur.identity.ephemeral
            end,
            run = function(ctx)
                require("features.reviews.link").Bind.open(ctx.ui)
            end,
        },
        {
            id = "reviews_link_switch",
            title = _("拉取微信段评"),
            icon = "forum",
            scope = "reader",
            -- 👇 段评依然只对支持取字的排版文档（EPUB 等）开放，PDF 不显示
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
            id = "reviews_show",
            title = _("显示段评"),
            icon = "forum",
            scope = "reader",
            keep_open = true,
            available = function(ctx)
                local ui = ctx and ctx.ui
                return not ui or require("features.reviews.link").available(ui)
            end,
            active = function()
                local cur = require("reader.session").current()
                local identity = cur and cur.identity
                if not identity then return false end
                local source = identity.source --[[@as ParagraphReviewSource|nil]]
                local wechat = require("source.registry").resolve("wechat")
                return wechat and require("source.review_setting").enabled(wechat.id) or false
            end,
            run = function(ctx)
                local wechat = require("source.registry").resolve("wechat")
                if not wechat then return end
                local ReviewSetting = require("source.review_setting")
                ReviewSetting.set(wechat.id, not ReviewSetting.enabled(wechat.id))
                local ui = ctx.ui
                if ui and ui.dialog then
                    require("ui/uimanager"):setDirty(ui.dialog, "ui")
                end
            end,
        },
    }
end

return Panel
