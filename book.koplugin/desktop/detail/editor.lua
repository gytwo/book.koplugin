--[[-- 书籍详情元信息编辑。 @module desktop.detail.editor --]]

local Book = require("ui.widgets.book")
local Input = require("ui.themes.widgets.input")
local Toast = require("ui.themes.widgets.toast")
local Text = require("utils.text")
local Common = require("desktop.detail.common")
local bookSupportsEdit = Common.bookSupportsEdit
local _ = require("gettext")

return function(Detail)
--- 编辑元信息对话框（书名/作者/标签/系列）。
function Detail:openEditor()
    local book = self.book
    if not bookSupportsEdit(book, self.source) then
        Toast:new{ text = _("当前数据源不支持编辑"), timeout = 2 }:show()
        return
    end
    local TermsDB = require("book.terms_db")
    local function current_text(kind, fallback)
        return TermsDB.getTermsText(book.source_id, book.stable_id, kind) or fallback or ""
    end
    local initial = {
        title = book.title or "",
        author = current_text("author", Book.author(book)),
        category = current_text("category", book.category),
        series = current_text("series", book.series),
    }
    self._edit_initial = initial
    Input:new{
        title = _("编辑元信息"),
        fields = {
            { label = _("书名"), text = initial.title },
            { label = _("作者"), text = initial.author },
            { label = _("系列"), text = initial.series },
            { label = _("标签"), text = initial.category },
        },
        ok_text = _("保存"),
        callback = function(...) self:saveMeta({ ... }) end,
    }:show()
end

--- 保存编辑结果到 books 表（进度/简介/md5 保留），完成后 reload 重绘。
--- 本地源开启「按文件夹分类」时：分类/系列即目录层级，改动会移动文件、stable_id 跟着变；关闭时只改库
---（opens/reading_stats/pending_progress 由 moveBook 里的 renameStableId 迁移）。
---@param fields table 对话框字段值：书名/作者/分类/系列
function Detail:saveMeta(fields)
    local book = self.book
    if not bookSupportsEdit(book, self.source) then
        return
    end
    local function nonempty(s)
        s = Text.trim(s)
        return s ~= "" and s or nil
    end
    local title = nonempty(fields[1])
    local authors = nonempty(fields[2])
    local series = nonempty(fields[3])
    local category = nonempty(fields[4])
    local initial = self._edit_initial or {}
    self._edit_initial = nil
    local function changed(key, value)
        return (value or "") ~= (initial[key] or "")
    end
    local owner = Common.bookOwnerSource(book, self.source)
    local sid = book.stable_id
    local BookDB = require("book.books_db")
    local existing = BookDB.get(book.source_id, sid)
    -- books 列只写改了的字段，没改的保持原值
    local saved = BookDB.upsertLocal({
        source_id = book.source_id,
        stable_id = sid,
        title = changed("title", title) and title or book.title,
        authors = changed("author", authors) and authors or book.authors,
        category = changed("category", category) and category or book.category,
        series = changed("series", series) and series or book.series,
        intro = existing and existing.intro or nil,
        md5 = existing and existing.md5 or nil,
    })
    if saved then
        local TermsDB = require("book.terms_db")
        if changed("author", authors) then
            TermsDB.setTermsFromString(book.source_id, sid, "author", authors, "user")
        end
        if changed("series", series) then
            TermsDB.setTermsFromString(book.source_id, sid, "series", series, "user")
        end
        if changed("category", category) then
            TermsDB.setTermsFromString(book.source_id, sid, "category", category, "user")
        end
        owner:onEvent("book_meta_changed", {
            identity = { source_id = book.source_id, stable_id = sid },
            cover = false,
        })
    end
    if self.closed then return end
    book.stable_id = sid
    if not saved then
        Toast:new{ text = _("保存元信息失败"), timeout = 2 }:show()
        return
    end
    self:reload()
    Toast:new{ text = _("元数据已更新"), timeout = 1.5 }:show()
end
end
