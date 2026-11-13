--[[--
微信读书 / 番茄书目的绑定入口与段评开关。

- review_book = { wechat = {...}, fanqie = {...} }，两个源可同时绑，互不覆盖。
- book_reviews_wechat 仍作全局段评开关。
- 兼容旧键 wechat_book（{ book_id, title, author }）。

@module koplugin.book.features.reviews.link
--]]

require("l10n").apply()

local UIManager = require("ui/uimanager")
local Toast = require("ui.themes.widgets.toast")
local T = require("ffi/util").template
local _ = require("gettext")

local Link = {}
local Bind = {}

local function normalize_title(text)
    text = tostring(text or ""):gsub("%s+", "")
    text = text:gsub("《", ""):gsub("》", "")
        :gsub("【", ""):gsub("】", "")
        :gsub("：", ""):gsub("，", ""):gsub("、", "")
        :gsub("。", ""):gsub("！", ""):gsub("？", "")
        :gsub("[%.%,!%?;:%-%_/%\\%(%)%[%]{}]", "")
    return text
end

---@param text string
local function toast(text)
    Toast:new{ text = text, timeout = 2 }:show()
end

--- 读 review_book（兼容旧 wechat_book）。
---@param ui table
---@return table|nil
function Bind.get(ui)
    if not ui.doc_settings then return nil end
    local book = ui.doc_settings:readSetting("review_book")
    if type(book) == "table" then return book end
    local old = ui.doc_settings:readSetting("wechat_book")
    if old then return { wechat = old } end
    return nil
end

-- ── 微信绑定 ───────────────────────────────────────────────

local function bindWechatSearch(ui, source)
    local props = ui.doc_props or {}
    local keyword = props.title or ""

    local function bind_book(book_id, title, author)
        require("features.reviews.linked").set(ui, "wechat", {
            book_id = book_id, title = title, author = author,
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
            if not books then toast(err or _("搜索失败")); return end
            if #books == 0 then toast(_("没有找到这本书")); return end
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

    local client = source._client
    if not client then do_search(keyword); return end

    client:shelfSyncAsync(function(wire, err)
        local shelf_books = wire and wire.books or {}
        local matched = {}
        local lower_kw = keyword:lower()
        for i, b in ipairs(shelf_books) do
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
            require("ui.themes.widgets.list"):new{ title = _("从书架选择书目"), items = matched }:show()
            return
        end
        require("ui/themes/widgets/input"):new{
            title = _("书架中未找到，搜索微信读书书城"),
            fields = { { text = keyword, hint = _("书名") } },
            callback = do_search,
        }:show()
    end)
end

function Bind.bindWechat(ui)
    local source = require("source.registry").resolve("wechat") --[[@as ParagraphReviewSource]]
    if not source:configured() then
        toast(_("请先扫码登录微信读书"))
        return
    end
    local book = Bind.get(ui)
    if book and book.wechat then
        require("ui.themes.widgets.list"):new{
            centered = true,
            title = T(_("已关联：%1"), book.wechat.title or ""),
            items = {
                { text = _("重新绑定"), callback = function() bindWechatSearch(ui, source) end },
                { text = _("解除关联"), callback = function()
                    require("features.reviews.linked").set(ui, "wechat", nil)
                    ui.doc_settings:delSetting("wechat_book")
                    UIManager:setDirty(ui.dialog, "ui")
                    toast(_("已解除微信关联"))
                end },
            },
        }:show()
        return
    end
    bindWechatSearch(ui, source)
end

-- ── 番茄绑定 ───────────────────────────────────────────────

function Bind.bindFanqie(ui)
    local source = require("source.registry").resolve("fanqie")
    if not source then
        toast(_("番茄源未启用"))
        return
    end
    local book = Bind.get(ui)
    if book and book.fanqie then
        require("ui.themes.widgets.list"):new{
            centered = true,
            title = T(_("已关联：%1"), book.fanqie.title or ""),
            items = {
                { text = _("重新绑定"), callback = function() Bind._searchFanqie(ui, source) end },
                { text = _("已绑定章节"), callback = function() Bind._listChapterMap(ui, book.fanqie, source) end },
                { text = _("解除关联"), callback = function()
                    require("features.reviews.linked").set(ui, "fanqie", nil)
                    UIManager:setDirty(ui.dialog, "ui")
                    toast(_("已解除番茄关联"))
                end },
            },
        }:show()
        return
    end
    Bind._searchFanqie(ui, source)
end

--- 弹已持久化的 chapter_map：本地章标题 → 番茄章标题。
--- 点某一条调 linked_fanqie.pickChapter，弹番茄目录让用户重选。
---@param ui table ReaderUI
---@param link table review_book.fanqie
---@param source ParagraphReviewSource
function Bind._listChapterMap(ui, link, source)
    local map = link.chapter_map or {}
    local local_toc = (ui.document and ui.document:getToc()) or {}
    local List = require("ui/themes/widgets/list")

    source:loadTocAsync({ source_id = "fanqie", stable_id = link.book_id }, function(remote_toc)
        remote_toc = remote_toc or {}
        -- 番茄 uid → 标题
        local remote_by_uid = {}
        for i, ch in ipairs(remote_toc) do
            local uid = tostring(ch.uid or "")
            if uid ~= "" then remote_by_uid[uid] = tostring(ch.title or "") end
        end
        -- 本地标题归一化 → 原始标题
        local local_by_key = {}
        for i, item in ipairs(local_toc) do
            local title = tostring(item.title or "")
            if title ~= "" then local_by_key[normalize_title(title)] = title end
        end

        local entries = {}
        for key, uid in pairs(map) do
            if type(uid) == "string" and uid ~= "" then
                entries[#entries + 1] = {
                    key = key,
                    local_title = local_by_key[key] or key,
                    remote_title = remote_by_uid[uid] or uid,
                }
            end
        end
        table.sort(entries, function(a, b) return a.local_title < b.local_title end)

        if #entries == 0 then
            toast(_("尚未绑定任何章节"))
            return
        end

        local items = {}
        for i, entry in ipairs(entries) do
            items[#items + 1] = {
                text = entry.local_title,
                mandatory = _("→ ") .. entry.remote_title,
                callback = function()
                    if ui._chapter_map_list then
                        UIManager:close(ui._chapter_map_list)
                        ui._chapter_map_list = nil
                    end
                    require("features.reviews.linked_fanqie").pickChapter(ui, link, nil,
                        entry.key, entry.local_title)
                end,
            }
        end
        local list = List:new{
            centered = true,
            title = _("已绑定章节"),
            items = items,
            item_per_page = 15,
        }
        ui._chapter_map_list = list
        list:show()
    end)
end

function Bind._searchFanqie(ui, source)
    local props = ui.doc_props or {}
    local keyword = props.display_title or props.title or ""
    source:searchAsync(keyword, function(res, err)
        if not res or not res.data or #res.data == 0 then
            toast(err or _("没有找到这本书"))
            return
        end
        local items = {}
        for i, book in ipairs(res.data) do
            items[#items + 1] = {
                text = book.title,
                mandatory = book.authors,
                callback = function()
                    require("features.reviews.linked").set(ui, "fanqie", {
                        book_id = book.stable_id,
                        title = book.title,
                        author = book.authors,
                    })
                    toast(T(_("已关联「%1」"), book.title))
                    UIManager:setDirty(ui.dialog, "ui")
                end,
            }
        end
        require("ui.themes.widgets.list"):new{
            title = _("选择番茄书目"),
            items = items,
        }:show()
    end)
end

-- ── 绑定入口 ───────────────────────────────────────────────

--- 关联书源：两个源各一行，可只绑一个，也可两个都绑。
---@param ui table
function Bind.open(ui)
    local book = Bind.get(ui) or {}
    local items = {
        {
            text = _("关联微信读书"),
            mandatory = _("上报时长，评论来源"),
            callback = function() Bind.bindWechat(ui) end,
        },
        {
            text = _("关联番茄小说"),
            mandatory = _("段评来源"),
            callback = function() Bind.bindFanqie(ui) end,
        },
    }
    if book.wechat or book.fanqie then
        items[#items + 1] = {
            text = _("解除全部关联"),
            callback = function()
                require("features.reviews.linked").set(ui, "wechat", nil)
                require("features.reviews.linked").set(ui, "fanqie", nil)
                ui.doc_settings:delSetting("review_book")
                ui.doc_settings:delSetting("wechat_book")
                ui.doc_settings:saveSetting("book_reviews_wechat", false)
                UIManager:setDirty(ui.dialog, "ui")
                toast(_("已解除关联"))
            end,
        }
    end
    require("ui.themes.widgets.list"):new{
        centered = true,
        title = _("关联书源"),
        items = items,
    }:show()
end

-- ── 段评开关 ───────────────────────────────────────────────

--- 切换「拉取段评」开关（全局）。
---@param ui table
function Link.openPull(ui)
    local book = Bind.get(ui)
    if not book or (not book.wechat and not book.fanqie) then
        toast(_("请先关联书源"))
        Bind.open(ui)
        return
    end
    local Linked = require("features.reviews.linked")
    local on = Linked.enabled(ui)
    ui.doc_settings:saveSetting("book_reviews_wechat", not on)
    toast(on and _("已关闭段评") or _("已开启段评"))
    UIManager:setDirty(ui.dialog, "ui")
end

function Link.open(ui)
    Bind.open(ui)
end

--- 当前文档能否关联书源（有身份且非订阅文章）。
---@param ui table ReaderUI
---@return boolean
function Link.available(ui)
    local cur = require("reader.session").current()
    local identity = cur and cur.identity
    if not identity or identity.ephemeral then return false end
    return true
end

Link.Bind = Bind
return Link
