--[[--
book_terms 表：作者 / 系列 / 分类的多值查询表。
一行一个值，origin 分 embedded（内嵌）和 user（用户追加）；
内嵌刷新只动 embedded 行，用户编辑只动 user 行，查询合并去重。

@module koplugin.book.book.terms_db
--]]

local DB = require("utils.db")
local Text = require("utils.text")

local TermsDB = {}

DB.schema("book_terms", function()
    return DB.exec([[
CREATE TABLE IF NOT EXISTS book_terms (
  source_id TEXT NOT NULL,
  stable_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  term TEXT NOT NULL,
  origin TEXT NOT NULL,
  PRIMARY KEY (source_id, stable_id, kind, term, origin)
);
CREATE INDEX IF NOT EXISTS idx_book_terms_kind ON book_terms(source_id, kind, term);
CREATE INDEX IF NOT EXISTS idx_book_terms_book ON book_terms(source_id, stable_id);
]]) ~= nil
end)

local COLUMN_KIND = { authors = "author", author = "author", series = "series", category = "category" }

---@param column string
---@return string|nil
local function kindOf(column)
    return COLUMN_KIND[column]
end

--- 把字符串拆成多值：换行 / 分号 / 逗号 / 顿号 / 制表 / 中点 都认。
---@param s string|nil
---@return string[]
local function splitTerms(s)
    if type(s) ~= "string" or s == "" then return {} end
    local normalized = s
        :gsub(";", "\n")
        :gsub(",", "\n")
        :gsub("\t", "\n")
        :gsub("\227\128\129", "\n")
        :gsub("\194\183", "\n")
    local out, seen = {}, {}
    for t in normalized:gmatch("[^\n]+") do
        t = Text.trim(t)
        if t ~= "" and not seen[t] then
            seen[t] = true
            out[#out + 1] = t
        end
    end
    return out
end
TermsDB.splitTerms = splitTerms

--- 写某书某维度的多值。只删同 origin 旧行，另一层不动。
---@param source_id string
---@param stable_id string
---@param kind "author"|"series"|"category"
---@param terms string[]|nil
---@param origin "embedded"|"user"
---@return boolean
function TermsDB.setTerms(source_id, stable_id, kind, terms, origin)
    return DB.transaction(function()
        if not DB.exec([[DELETE FROM book_terms
            WHERE source_id=? AND stable_id=? AND kind=? AND origin=?;]],
            source_id, stable_id, kind, origin) then
            return false
        end
        local seen = {}
        for _idx, term in ipairs(terms or {}) do
            term = Text.trim(term)
            if term ~= "" and not seen[term] then
                seen[term] = true
                if not DB.exec([[INSERT OR IGNORE INTO book_terms
                    (source_id, stable_id, kind, term, origin) VALUES (?,?,?,?,?);]],
                    source_id, stable_id, kind, term, origin) then
                    return false
                end
            end
        end
        return true
    end) == true
end

--- 从字符串写某维度某来源。
---@param source_id string
---@param stable_id string
---@param kind "author"|"series"|"category"
---@param raw string|nil
---@param origin "embedded"|"user"
---@return boolean
function TermsDB.setTermsFromString(source_id, stable_id, kind, raw, origin)
    return TermsDB.setTerms(source_id, stable_id, kind, splitTerms(raw), origin)
end

--- 某书某维度的合并值（embedded ∪ user，去重，按字母序）。
---@param source_id string
---@param stable_id string
---@param kind "author"|"series"|"category"
---@return string[]
function TermsDB.getTerms(source_id, stable_id, kind)
    local result, nrows = DB.query([[SELECT DISTINCT term FROM book_terms
        WHERE source_id=? AND stable_id=? AND kind=? AND term<>'' ORDER BY term;]],
        source_id, stable_id, kind)
    local out = {}
    for i = 1, nrows do out[i] = result[1][i] end
    return out
end

--- 某书某维度某来源的值（去重，按字母序）。
---@param source_id string
---@param stable_id string
---@param kind "author"|"series"|"category"
---@param origin "embedded"|"user"|"folder"
---@return string[]
function TermsDB.getTermsByOrigin(source_id, stable_id, kind, origin)
    local result, nrows = DB.query([[SELECT DISTINCT term FROM book_terms
        WHERE source_id=? AND stable_id=? AND kind=? AND origin=? AND term<>'' ORDER BY term;]],
        source_id, stable_id, kind, origin)
    local out = {}
    for i = 1, nrows do out[i] = result[1][i] end
    return out
end

--- 合并值拼成一行展示串；无值时返回 nil。
---@param source_id string
---@param stable_id string
---@param kind "author"|"series"|"category"
---@param sep string|nil 缺省「；」
---@return string|nil
function TermsDB.getTermsText(source_id, stable_id, kind, sep)
    local list = TermsDB.getTerms(source_id, stable_id, kind)
    if #list == 0 then return nil end
    return table.concat(list, sep or "；")
end

--- 分组计数；column 是 catalog 传的 authors / series / category。
---@param column string
---@param source_id string|string[]
---@return table[]|nil
function TermsDB.countsBy(column, source_id)
    local kind = kindOf(column)
    if not kind then return nil end
    local args = {}
    local where = DB.sourceClause("source_id", source_id, args)
    args[#args + 1] = kind
    local result, nrows = DB.query(
        "SELECT term, COUNT(DISTINCT stable_id) FROM book_terms WHERE " .. where
            .. " AND kind=? AND term<>'' GROUP BY term ORDER BY term;",
        unpack(args)
    )
    if not result then return nil end
    local rows = {}
    for i = 1, nrows do
        rows[i] = { [column] = result[1][i], count = tonumber(result[2][i]) or 0 }
    end
    -- 补空桶：没有任何该 kind 行的在架书（无标签 / 无系列 / 无作者）
    local empty_args = {}
    local empty_where = DB.sourceClause("b.source_id", source_id, empty_args)
    empty_args[#empty_args + 1] = kind
    local empty = tonumber(DB.rowexec(
        "SELECT COUNT(*) FROM books b WHERE " .. empty_where
            .. " AND b.deleted=0 AND b.hidden=0"
            .. " AND NOT EXISTS (SELECT 1 FROM book_terms t"
            .. " WHERE t.source_id=b.source_id AND t.stable_id=b.stable_id AND t.kind=?);",
        unpack(empty_args)
    )) or 0
    if empty > 0 then
        rows[#rows + 1] = { [column] = "", count = empty }
    end
    return rows
end

--- 按值筛选的 EXISTS 片段（追加 args）。
---@param kind "author"|"series"|"category"
---@param term string
---@param alias string books 表别名
---@param args table
---@return string
function TermsDB.existsClause(kind, term, alias, args)
    args[#args + 1] = kind
    args[#args + 1] = term
    return "EXISTS (SELECT 1 FROM book_terms t WHERE t.source_id=" .. alias .. ".source_id"
        .. " AND t.stable_id=" .. alias .. ".stable_id AND t.kind=? AND t.term=?)"
end

--- 没有该维度任何值的条件。
---@param kind "author"|"series"|"category"
---@param alias string
---@return string
function TermsDB.notExistsClause(kind, alias)
    return "NOT EXISTS (SELECT 1 FROM book_terms t WHERE t.source_id=" .. alias .. ".source_id"
        .. " AND t.stable_id=" .. alias .. ".stable_id AND t.kind='" .. kind .. "')"
end

---@param source_id string
---@param old_stable_id string
---@param new_stable_id string
---@param merge boolean|nil
---@return boolean
function TermsDB.moveIdentity(source_id, old_stable_id, new_stable_id, merge)
    return DB.moveIdentity("book_terms", source_id, old_stable_id, new_stable_id, merge)
end

---@param source_id string
---@param stable_id string
---@return boolean
function TermsDB.removeIdentity(source_id, stable_id)
    return DB.removeIdentity("book_terms", source_id, stable_id)
end

---@param source_id string
---@param stable_prefix string|nil
---@param exclude boolean|nil
---@return boolean
function TermsDB.removeSource(source_id, stable_prefix, exclude)
    return DB.removeSource("book_terms", source_id, stable_prefix, exclude)
end

--- 删某源某维度某来源的全部行。
---@param source_id string
---@param kind "author"|"series"|"category"
---@param origin "embedded"|"user"|"folder"
---@return boolean
function TermsDB.clearKind(source_id, kind, origin)
    return DB.exec([[DELETE FROM book_terms
        WHERE source_id=? AND kind=? AND origin=?;]],
        source_id, kind, origin) ~= nil
end

return TermsDB
