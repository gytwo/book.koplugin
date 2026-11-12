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
            id = "wechat_bind",
            title = _("关联微信读书"),
            icon = "link",
            scope = "reader",
            available = function(ctx)
                local ui = ctx and ctx.ui
                -- 没有 ui（设置页预览）→ 允许
                if not ui then return true end
                local cur = require("reader.session").current()
                -- 是订阅文章 → 不允许
                if cur and cur.identity and cur.identity.ephemeral then
                    return false
                end
                return true
            end,
            run = function(ctx)
                require("features/reviews.link").Bind.open(ctx.ui)
            end,
        },
        {
            id = "reviews_link_switch",
            title = _("拉取微信评论"), 
            icon = "forum",
            scope = "reader",
            -- ★ 拉取动作：保留原有对排版引擎的限制（PDF 不支持，所以灰掉）
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
    }
end

return Panel
