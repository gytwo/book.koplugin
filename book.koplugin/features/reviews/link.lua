--[[--
微信读书书目绑定与段评开关。

- 新键 `wechat_book`：存 { book_id, title, author }。绑定即生效，用于时长上报。
- 旧键 `book_reviews_wechat`：布尔开关，控制是否拉取并渲染段评。
- 绑定和段评解耦：先绑定，再自由开关段评。

@module koplugin.book.features.reviews.link
--]]

require("l10n").apply()

local UIManager = require("ui/uimanager")
local Toast = require("ui.themes.widgets.toast")
local T = require("ffi/util").template
local _ = require("gettext")

local Link = {}
local Bind = {}

---@param text string
local function toast(text)
    Toast:new{ text = text, timeout = 2 }:show()
end

--- 读新键。
---@param ui table
---@return table|nil
function Bind.get(ui)
    return ui.doc_settings and ui.doc_settings:readSetting("wechat_book")
end

--- 输入书名 → 先查书架匹配 → 书架没有再去书城搜 → 选书。
---@param ui table
---@param source ParagraphReviewSource
local function search(ui, source)
    local props = ui.doc_props or {}
    local keyword = props.title or ""

    local function bind_book(book_id, title, author)
        ui.doc_settings:saveSetting("wechat_book", {
            book_id = book_id,
            title = title,
            author = author,
        })
        -- 清理历史积压：把这本书之前的本地阅读时长全部标记为已同步（不推送）
        local StatsDB = require("book.stats_db")
        local identity = require("reader.session").current()
        if identity and identity.identity then
            StatsDB.markSyncedByBook(identity.identity.source_id, identity.identity.stable_id)
        end
        toast(T(_("已关联「%1」，阅读时长将同步"), title))
        UIManager:setDirty(ui.dialog, "ui")
    end

    local function do_search(kw)
        source:searchBooksAsync(kw, function(books, err)
            if not books then
                toast(err or _("搜索失败"))
                return
            end
            if #books == 0 then
                toast(_("没有找到这本书"))
                return
            end
            local items = {}
            for i, book in ipairs(books) do
                items[i] = {
                    text = book.title,
                    mandatory = book.author,
                    callback = function() bind_book(book.book_id, book.title, book.author) end,
                }
            end
            require("ui.themes.widgets.list"):new{ title = _("选择书城书目"), items = items }:show()
        end)
    end

    -- 先查书架（通过 _client 拿 Client，调 shelfSyncAsync）
    local client = source._client
    if not client then
        -- 拿不到 client，直接走书城搜索
        do_search(keyword)
        return
    end

    client:shelfSyncAsync(function(wire, err)
        local shelf_books = wire and wire.books or {}
        local matched = {}
        local lower_kw = keyword:lower()
        for _, b in ipairs(shelf_books) do
            local info = b.bookInfo or b
            local title = info.title or b.title or ""
            local author = info.author or b.author or ""
            local book_id = b.bookId or info.bookId
            if book_id and (lower_kw == "" or title:lower():find(lower_kw, 1, true)) then
                matched[#matched + 1] = {
                    text = title,
                    mandatory = author,
                    callback = function() bind_book(book_id, title, author) end,
                }
            end
        end

        if #matched > 0 then
            -- 书架里有匹配的，优先展示
            require("ui.themes.widgets.list"):new{
                title = _("从书架选择书目"),
                items = matched,
            }:show()
            return
        end

        -- 书架里没匹配的，弹输入框让用户搜书城
        require("ui/themes/widgets/input"):new{
            title = _("书架中未找到，搜索微信读书书城"),
            fields = { { text = keyword, hint = _("书名") } },
            callback = do_search,
        }:show()
    end)
end

--- 绑定入口：已有绑定则弹出重绑/解绑菜单，否则直接搜索。
---@param ui table
function Bind.open(ui)
    local source = require("source.registry").resolve("wechat") --[[@as ParagraphReviewSource]]
    if not source:configured() then
        toast(_("请先扫码登录微信读书"))
        return
    end
    local link = Bind.get(ui)
    if not link then
        search(ui, source)
        return
    end
    require("ui.themes.widgets.list"):new{
        centered = true,
        title = T(_("已关联：%1"), link.title),
        items = {
            { text = _("重新绑定"), callback = function() search(ui, source) end },
            { text = _("解除关联"), callback = function()
                ui.doc_settings:delSetting("wechat_book")
                -- 解绑时顺手关闭段评开关（没书号了开着也没用）
                ui.doc_settings:saveSetting("book_reviews_wechat", false)
                UIManager:setDirty(ui.dialog, "ui")
                toast(_("已解除关联"))
            end },
        },
    }:show()
end

--- 段评开关入口：没绑定先走绑定；已绑定则切换开关。
---@param ui table
function Link.openPull(ui)
    local link = Bind.get(ui)
    if not link then
        toast(_("请先绑定微信读书书目"))
        Bind.open(ui)
        return
    end
    local Linked = require("features.reviews.linked")
    local on = Linked.enabled(ui)
    ui.doc_settings:saveSetting("book_reviews_wechat", not on)
    toast(on and _("已关闭微信段评") or _("已开启微信段评"))
    UIManager:setDirty(ui.dialog, "ui")
end

--- 原来 open 的兼容入口（给老调用方），现在等价于 Bind.open。
function Link.open(ui)
    Bind.open(ui)
end

--- 当前文档能否关联微信读书书目。
--- 只要求有身份且不是订阅文章，不再依赖排版引擎（PDF 等也能绑定上报时长）。
---@param ui table ReaderUI
---@return boolean
function Link.available(ui)
    local identity = identityOf()
    if not identity or identity.ephemeral then return false end
    return true
end

Link.Bind = Bind
return Link
