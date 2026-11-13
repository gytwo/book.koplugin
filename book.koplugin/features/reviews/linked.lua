--[[--
关联书段评：本地书关联微信读书 / 番茄书目，借用它们的段评。

review_book = { wechat = {...}, fanqie = {...} }，两个源可同时绑。
- wechat：按原句文字定位（squash + findText）。
- fanqie：按段落 pid 定位（linked_fanqie.lua）。
- 兼容旧键 wechat_book（无 source 字段，视为 wechat）。

@module koplugin.book.features.reviews.linked
--]]

local PageMarks = require("reader.page_marks")
local UIManager = require("ui/uimanager")
local logger = require("utils.log")

local Linked = {}

--- 一页最多去对的微信章数（每章要发 1 + 热点数/40 个请求）。
local MAX_CHAPTERS = 6
--- 比例对齐的余量（全书比例）。
local MARGIN = 0.05
--- 太短的原句（去标点后不足 4 个汉字）到处都能撞上，不标。
local MIN_BYTES = 12
--- 某章拉取失败后多久再试（秒）。
local RETRY = 60
--- 翻页后多久预扫（秒）。
local IDLE = 0.3
--- 往后预扫几页。
local AHEAD = 2

---@class ReviewLink
---@field source string "wechat" | "fanqie"
---@field book_id string
---@field title string|nil
---@field author string|nil

--- 读关联。
---@param ui table ReaderUI
---@param source_id string|nil 指定源；nil 返回 { wechat = {...}, fanqie = {...} }
---@return table|nil
function Linked.get(ui, source_id)
    if not ui.doc_settings then return nil end
    local book = ui.doc_settings:readSetting("review_book")
    if type(book) ~= "table" then book = {} end
    -- 兼容旧 wechat_book
    if not book.wechat then
        local old = ui.doc_settings:readSetting("wechat_book")
        if old then book.wechat = old end
    end
    if source_id then return book[source_id] end
    return book
end

---@param ui table ReaderUI
---@param source_id string
---@param link ReviewLink|nil nil = 解除该源关联
function Linked.set(ui, source_id, link)
    if not ui.doc_settings then return end
    local book = ui.doc_settings:readSetting("review_book")
    if type(book) ~= "table" then book = {} end
    book[source_id] = link
    ui.doc_settings:saveSetting("review_book", book)
end

--- 段评开关。传 source_id 只看该源；不传则看"任一源开启"（保留旧语义）。
--- 微信看 book_reviews_wechat，番茄看 fanqie_reviews_enabled，互不影响。
---@param ui table ReaderUI
---@param source_id "wechat"|"fanqie"|nil
---@return boolean
function Linked.enabled(ui, source_id)
    if not ui.doc_settings then return false end
    local book = ui.doc_settings:readSetting("review_book")
    if type(book) ~= "table" then
        -- 兼容旧 wechat_book
        local old = ui.doc_settings:readSetting("wechat_book")
        if old then book = { wechat = old } else book = {} end
    end
    local function on(id)
        if not book[id] then return false end
        if id == "fanqie" then
            return ui.doc_settings:readSetting("fanqie_reviews_enabled") ~= false
        end
        local val = ui.doc_settings:readSetting("book_reviews_wechat")
        if type(val) == "table" then return true end
        return val ~= false
    end
    if source_id then return on(source_id) end
    -- 不传：任一源开启即 true
    if on("wechat") or on("fanqie") then return true end
    -- 旧键 book_reviews_wechat 为表、且没有 wechat_book 时迁移（保留原逻辑）
    local val = ui.doc_settings:readSetting("book_reviews_wechat")
    if type(val) == "table" then
        if val.book_id and not ui.doc_settings:readSetting("wechat_book") then
            ui.doc_settings:saveSetting("wechat_book", {
                book_id = val.book_id, title = val.title, author = val.author,
            })
        end
        ui.doc_settings:saveSetting("book_reviews_wechat", true)
        return true
    end
    return val == true
end

--- 文档能按页取文字、找原句（排版引擎文档；PDF / 漫画没有这套接口）。
---@param document table
---@return boolean
function Linked.supported(document)
    return document.getPageXPointer ~= nil and document.findText ~= nil
end

---@return ReviewLinkCache
function Linked.newCache()
    return {
        hotspots = {}, loading = {}, pos = {}, pages = {}, scanned = {},
        logged = {}, chapter_text = {},
        fanqie_results = {},
        fanqie_prefetching = {},
        fanqie_prefetched = {},
        fanqie_queue = {},
        fanqie_queue_active = false,
        fanqie_current = nil,
        fanqie_local_current = nil,
        fanqie_failed = {},
        fanqie_job = nil,
        scan_key = nil,
        scan_done = nil,
    }
end

--- 取消在飞拉取与预扫（已拉到的热点、已定位的原句保留）。
---@param cache ReviewLinkCache
function Linked.cancel(cache)
    if cache.timer then
        UIManager:unschedule(cache.timer)
        cache.timer = nil
    end
    if cache.job then
        if cache.job.job then cache.job.job:cancel() end
        cache.job = nil
    end
    -- 番茄源：取消在飞扫描 + 清预取队列
    if cache.fanqie_job then
        cache.fanqie_job:cancel()
        cache.fanqie_job = nil
    end
    cache.fanqie_queue = {}
    cache.fanqie_queue_active = false
    for key, job in pairs(cache.loading) do
        if type(job) == "table" then job.cancel() end
        cache.loading[key] = nil
    end
end

local CJK_PUNCT = {
    "　", "，", "。", "：", "；", "、", "！", "？", "“", "”", "‘", "’",
    "《", "》", "（", "）", "【", "】", "·", "—", "…", "「", "」", "『", "』", "～",
    "\226\128\139", "\239\187\191",
}
local PUNCT = {}
for _idx, p in ipairs(CJK_PUNCT) do PUNCT[p] = true end

local function squash(raw)
    local parts, from, to, n = {}, {}, {}, 0
    for s, ch, e in raw:gmatch("()(" .. require("utils.text").UTF8_CHAR .. ")()") do
        if not (PUNCT[ch] or ch:match("^[%s%p]$")) then
            parts[#parts + 1] = ch
            from[n + 1] = s
            n = n + #ch
            to[n] = e - 1
        end
    end
    return table.concat(parts), from, to
end
Linked.squash = squash

local DIGITS = { ["零"] = 0, ["〇"] = 0, ["一"] = 1, ["二"] = 2, ["两"] = 2, ["三"] = 3, ["四"] = 4,
    ["五"] = 5, ["六"] = 6, ["七"] = 7, ["八"] = 8, ["九"] = 9 }
local UNITS = { ["十"] = 10, ["百"] = 100, ["千"] = 1000 }

local function leadingNumber(s)
    local total, digit, pos = 0, nil, 1
    while true do
        local ch = s:sub(pos, pos + 2)
        if DIGITS[ch] then
            digit = (digit or 0) * 10 + DIGITS[ch]
        elseif UNITS[ch] then
            total = total + (digit or 1) * UNITS[ch]
            digit = nil
        else
            break
        end
        pos = pos + 3
    end
    if pos == 1 then return nil end
    return total + (digit or 0), s:sub(pos)
end

local function norm(title)
    local s = squash(tostring(title or "")):gsub("^第", "")
    local num, rest = s:match("^(%d+)(.*)$")
    if not num then num, rest = leadingNumber(s) end
    if not num then return s end
    rest = rest:gsub("^[章回节]", "")
    return tostring(tonumber(num)) .. rest
end

function Linked.titlesAt(toc, page)
    local by_depth = {}
    for _idx, item in ipairs(toc) do
        if item.page <= page then by_depth[item.depth or 1] = item.title end
    end
    local out = {}
    for depth = 1, table.maxn(by_depth) do
        if by_depth[depth] then out[#out + 1] = by_depth[depth] end
    end
    return out
end

local function find(chapters, test)
    local out = {}
    for _idx, chapter in ipairs(chapters) do
        local hit = test(norm(chapter.title))
        for _anchor_idx, anchor in ipairs(chapter.anchors or {}) do
            hit = hit or test(norm(anchor.title))
        end
        if hit then out[#out + 1] = chapter end
    end
    return out
end

local function startsWith(a, b)
    return #a > #b and a:sub(1, #b) == b and not (b:match("%d$") and a:sub(#b + 1, #b + 1):match("%d"))
end

function Linked.byTitle(chapters, titles)
    local out, seen = {}, {}
    for _idx, title in ipairs(titles) do
        local want = norm(title)
        if want ~= "" then
            local hits = find(chapters, function(name) return name == want end)
            if #hits == 0 then
                hits = find(chapters, function(name)
                    return name ~= "" and (startsWith(name, want) or startsWith(want, name))
                end)
            end
            local chapter = #hits == 1 and hits[1] or nil
            if chapter and not seen[chapter] then
                seen[chapter] = true
                out[#out + 1] = chapter
            end
        end
    end
    return out
end

function Linked.candidates(chapters, titles, at, limit)
    local out, seen = {}, {}
    for _idx, chapter in ipairs(Linked.byTitle(chapters, titles)) do
        seen[chapter] = true
        out[#out + 1] = chapter
    end
    local total = 0
    for _idx, chapter in ipairs(chapters) do total = total + (chapter.words or 0) end
    if total > 0 then
        local near, acc = {}, 0
        for _idx, chapter in ipairs(chapters) do
            local s = acc / total
            acc = acc + (chapter.words or 0)
            local e = acc / total
            if e > at - MARGIN and s < at + MARGIN and not seen[chapter] then
                near[#near + 1] = { chapter = chapter, distance = math.abs((s + e) / 2 - at) }
            end
        end
        table.sort(near, function(x, y) return x.distance < y.distance end)
        for _idx, item in ipairs(near) do out[#out + 1] = item.chapter end
    end
    for i = #out, (limit or MAX_CHAPTERS) + 1, -1 do out[i] = nil end
    return out
end

local function pageText(ui, p, page, count)
    local document = ui.document
    if p < 1 or p > count then return "" end
    if p < count then
        return document:getTextFromXPointers(document:getPageXPointer(p), document:getPageXPointer(p + 1), true) or ""
    end
    if p ~= page then return "" end
    local width, height = PageMarks.screenSize(ui)
    local range = document:getTextFromPositions({ x = 0, y = 0 }, { x = width, y = height }, true)
    return range and range.text or ""
end

local function scan(ui, entries, cache, p)
    local document = ui.document
    local page, count = PageMarks.currentPage(ui), document:getPageCount()
    local prev, cur = pageText(ui, p - 1, page, count), pageText(ui, p, page, count)
    local raw = prev .. cur .. pageText(ui, p + 1, page, count)
    local cur0, cur1 = #prev + 1, #prev + #cur
    local text, from, to = squash(raw)
    local result = { found = {}, why = {} }
    for i, entry in ipairs(entries) do
        local spot = entry.spot
        local needle = squash(spot.text or "")
        local s, e = nil, nil
        if not cache.pos[spot] and #needle >= MIN_BYTES then s, e = text:find(needle, 1, true) end
        if s and from[s] <= cur1 and to[e] >= cur0 then
            if text:find(needle, s + 1, true) then
                result.why[i] = "ambiguous"
            else
                for _match_idx, match in ipairs(document:findText(raw:sub(from[s], to[e]), 0, 0, false, nil, false, 10) or {}) do
                    if document:getPageFromXPointer(match.start) <= p and document:getPageFromXPointer(match["end"]) >= p then
                        result.found[i] = { match.start, match["end"] }
                        break
                    end
                end
                if not result.found[i] then result.why[i] = "findText miss" end
            end
        elseif not s and not cache.pos[spot] and #needle >= MIN_BYTES then
            local hs = text:find(needle:sub(1, MIN_BYTES), 1, true)
            if hs and from[hs] <= cur1 then result.why[i] = "differs" end
        end
    end
    return result
end

local function apply(entries, cache, p, hash, result)
    result = result or { found = {}, why = {} }
    local located = 0
    for key, pos in pairs(result.found) do
        if type(pos) == "table" then
            cache.pos[entries[tonumber(key)].spot] = pos
            located = located + 1
        end
    end
    for key, why in pairs(result.why) do
        local spot = entries[tonumber(key)].spot
        if not cache.logged[spot] then
            cache.logged[spot] = true
        end
    end
    if cache.hash == hash then cache.scanned[p] = #entries end
    return located
end

local function startScan(ui, entries, cache, p, page, redraw)
    if cache.job then
        if cache.job.page == p then return end
        if cache.job.job then cache.job.job:cancel() end
        cache.job = nil
    end
    local hash = cache.hash
    local function finish(result)
        cache.job = nil
        if not ui.document then return end
        if apply(entries, cache, p, hash, result) > 0 then redraw() end
        if PageMarks.currentPage(ui) == page then Linked.scheduleScan(ui, entries, cache, page, redraw) end
    end
    local job = require("workers.job").run(function() return scan(ui, entries, cache, p) end, {
        name = "reviews.scan",
        kind = "light",
        timeout = 30,
        on_done = finish,
        on_failed = function(err)
            logger.warn("book.reviews scan failed", err)
            finish(nil)
        end,
    })
    if not job.settled then cache.job = { job = job, page = p } end
end

function Linked.scheduleScan(ui, entries, cache, page, redraw)
    if cache.timer then UIManager:unschedule(cache.timer) end
    cache.timer = nil
    local last = math.min(page + AHEAD, ui.document:getPageCount())
    local p = page + 1
    while p <= last and cache.scanned[p] == #entries do p = p + 1 end
    if p > last then return end
    local key = PageMarks.viewKey(ui, 0)
    cache.timer = require("ui.guard").wrap("reviews scan", function()
        cache.timer = nil
        if not key or PageMarks.viewKey(ui, 0) ~= key then return end
        startScan(ui, entries, cache, p, page, redraw)
    end)
    UIManager:scheduleIn(IDLE, cache.timer)
end

function Linked.place(ui, entries, cache, redraw)
    local document = ui.document
    if not PageMarks.canMapXPointers(document) then
        return {}
    end
    local hash = PageMarks.renderingHash(document)
    if cache.hash ~= hash then
        cache.hash, cache.pages, cache.scanned = hash, {}, {}
    end
    local page = PageMarks.currentPage(ui)
    if cache.scanned[page] ~= #entries then
        startScan(ui, entries, cache, page, page, redraw)
    end
    local width, height = PageMarks.screenSize(ui)
    local out = {}
    for _idx, entry in ipairs(entries) do
        local pos = cache.pos[entry.spot]
        local span = pos and cache.pages[entry.spot]
        if pos and not span then
            span = { document:getPageFromXPointer(pos[1]), document:getPageFromXPointer(pos[2]) }
            cache.pages[entry.spot] = span
        end
        if span and span[1] <= page + 1 and span[2] >= page then
            local boxes = {}
            for _box_idx, box in ipairs(document:getScreenBoxesFromPositions(pos[1], pos[2], true) or {}) do
                if PageMarks.intersects(box, width, height) then boxes[#boxes + 1] = box end
            end
            if #boxes > 0 then out[#out + 1] = { entry = entry, boxes = boxes } end
        end
    end
    if not cache.job then Linked.scheduleScan(ui, entries, cache, page, redraw) end
    return out
end

function Linked.entries(ui, source, book_id, toc, cache, redraw)
    local document = ui.document
    local page = PageMarks.currentPage(ui)
    local at = (page - 1) / document:getPageCount()
    local entries = {}
    for _idx, chapter in ipairs(Linked.candidates(toc, Linked.titlesAt(document:getToc() or {}, page), at)) do
        local identity = { source_id = source.id, stable_id = book_id, chapter_idx = chapter.idx, source = source }
        local key = book_id .. "\0" .. tostring(chapter.uid)
        local hotspots, loading = cache.hotspots[key], cache.loading[key]
        if hotspots then
            for _spot_idx, spot in ipairs(hotspots) do entries[#entries + 1] = { identity = identity, spot = spot } end
        elseif not loading or (type(loading) == "number" and os.time() - loading >= RETRY) then
            local done = false
            local job = source:paragraphHotspotsAsync(identity, function(fetched, err)
                done = true
                if not fetched then
                    logger.warn("book.reviews chapter failed", chapter.idx, err)
                    cache.loading[key] = os.time()
                    return
                end
                cache.loading[key] = nil
                cache.hotspots[key] = fetched
                redraw()
            end)
            if not done then cache.loading[key] = job end
        end
    end
    return entries
end

function Linked.tocAsync(source, book_id, cb)
    local book = { source_id = source.id, stable_id = book_id }
    local job
    job = source:loadTocAsync(book, function(toc, err)
        if toc and not source:isTocCurrent(toc) then
            job = source:refreshTocAsync(book, cb)
            return
        end
        cb(toc, err)
    end)
    return { cancel = function()
        if job then job.cancel() end
    end }
end

--- 关联书的段评目标：两个源各自产出 placement，合并返回。
--- 微信看 book_reviews_wechat，番茄看 fanqie_reviews_enabled，互不影响。
---@param ui table ReaderUI
---@param cache ReviewLinkCache
---@param redraw fun()
---@return table|nil
function Linked.target(ui, cache, redraw)
    local book = Linked.get(ui)
    logger.info("book.reviews target", "fanqie=" .. tostring(book and book.fanqie ~= nil),
        "wechat=" .. tostring(book and book.wechat ~= nil))
    if not Linked.supported(ui.document) then return nil end
    if type(book) ~= "table" then return nil end

    local targets = {}

    -- 番茄：自己的开关
    if book.fanqie and Linked.enabled(ui, "fanqie") then
        local t = require("features.reviews.linked_fanqie").target(ui, book.fanqie, cache, redraw)
        if t then targets[#targets + 1] = t end
    end

    -- 微信：自己的开关（book_reviews_wechat）
    if book.wechat and Linked.enabled(ui, "wechat") then
        local source = require("source.registry").resolve("wechat")
        if source and source:configured() then
            targets[#targets + 1] = {
                key = "wechat\0" .. book.wechat.book_id,
                fetch = function(cb) return Linked.tocAsync(source, book.wechat.book_id, cb) end,
                place = function(toc)
                    return Linked.place(ui, Linked.entries(ui, source, book.wechat.book_id, toc, cache, redraw), cache, redraw)
                end,
            }
        end
    end

    if #targets == 0 then return nil end
    if #targets == 1 then return targets[1] end

    return {
        key = table.concat({ targets[1].key, targets[2].key }, "\0"),
        fetch = function(cb)
            local results, pending = {}, #targets
            local jobs, cancelled = {}, false
            for i, t in ipairs(targets) do
                jobs[i] = t.fetch(function(data, err)
                    if cancelled then return end
                    results[i] = data
                    pending = pending - 1
                    if pending == 0 then cb(results) end
                end)
            end
            return { cancel = function()
                cancelled = true
                for _, j in ipairs(jobs) do if j and j.cancel then j.cancel() end end
            end }
        end,
        place = function(data)
            local out = {}
            for i, t in ipairs(targets) do
                for _, p in ipairs(t.place(data[i])) do out[#out + 1] = p end
            end
            return out
        end,
    }
end

---@param identity BookIdentity
---@return string
local function linkKey(identity)
    return tostring(identity.source_id or "") .. "\0" .. tostring(identity.stable_id)
end

function Linked.getFor(identity)
    if not (identity and identity.stable_id) then return nil end
    local links = require("utils.settings").get("features.reviews").chapter_links or {}
    return links[linkKey(identity)]
end

function Linked.setFor(identity, link)
    if not (identity and identity.stable_id) then return end
    local MoonSettings = require("utils.settings")
    local data = MoonSettings.get("features.reviews")
    data.chapter_links = data.chapter_links or {}
    data.chapter_links[linkKey(identity)] = link
    MoonSettings.save("features.reviews", data)
end

function Linked.anchorOf(chapters, chapter_idx)
    chapters = chapters or {}
    local total, acc, title, pos = 0, 0, nil, nil
    for i, chapter in ipairs(chapters) do
        total = total + (chapter.words or 0)
        if chapter.idx == chapter_idx then pos, title = i, chapter.title end
    end
    if not pos then return 0, nil end
    if total <= 0 then return (pos - 0.5) / #chapters, title end
    for i = 1, pos - 1 do acc = acc + (chapters[i].words or 0) end
    return (acc + (chapters[pos].words or 0) / 2) / total, title
end

function Linked.chapterHotspotsAsync(source, identity, link, cb)
    local cancelled, jobs = false, {}
    local function cancel()
        cancelled = true
        for _idx, job in ipairs(jobs) do if job.cancel then job.cancel() end end
    end
    local owner = identity.source or source
    local own = { source_id = identity.source_id, stable_id = identity.stable_id, source = owner }
    local own_job = owner:loadTocAsync(own, function(toc)
        if cancelled then return end
        local at, title = Linked.anchorOf(toc, tonumber(identity.chapter_idx))
        jobs[#jobs + 1] = Linked.tocAsync(source, link.book_id, function(remote)
            if cancelled then return end
            if not remote then cb(nil); return end
            local chapters = Linked.candidates(remote, title and { title } or {}, at, 8)
            local collected, pending = {}, #chapters
            if pending == 0 then cb(collected); return end
            for _idx, chapter in ipairs(chapters) do
                jobs[#jobs + 1] = source:paragraphHotspotsAsync({
                    source_id = source.id, stable_id = link.book_id, chapter_idx = chapter.idx, source = source,
                }, function(hotspots)
                    if cancelled or pending <= 0 then return end
                    for _spot_idx, spot in ipairs(hotspots or {}) do
                        spot.chapter_idx = chapter.idx
                        collected[#collected + 1] = spot
                    end
                    pending = pending - 1
                    if pending == 0 then cb(collected) end
                end)
            end
        end)
    end)
    if own_job then jobs[#jobs + 1] = own_job end
    return { cancel = cancel }
end

return Linked
