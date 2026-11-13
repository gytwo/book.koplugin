--[[--
本地书匹配番茄段评。照独立插件 local_review.lua 的逻辑。

@module koplugin.book.features.reviews.linked_fanqie
--]]

local PageMarks = require("reader.page_marks")
local logger = require("utils.log")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local M = {}

local TITLE_THRESHOLD = 0.70
local PREFETCH_COUNT = 1

local function utf8_chars(s)
    local chars, i, len = {}, 1, #s
    while i <= len do
        local b = s:byte(i)
        local w = 1
        if b >= 0xF0 then w = 4
        elseif b >= 0xE0 then w = 3
        elseif b >= 0xC0 then w = 2 end
        chars[#chars + 1] = s:sub(i, i + w - 1)
        i = i + w
    end
    return chars
end

local function normalize_title(text)
    text = tostring(text or ""):gsub("%s+", "")
    text = text:gsub("《", ""):gsub("》", "")
        :gsub("【", ""):gsub("】", "")
        :gsub("：", ""):gsub("，", ""):gsub("、", "")
        :gsub("。", ""):gsub("！", ""):gsub("？", "")
        :gsub("[%.%,!%?;:%-%_/%\\%(%)%[%]{}]", "")
    return text
end

local function char_overlap(a, b)
    a, b = normalize_title(a), normalize_title(b)
    if a == "" or b == "" then return 0 end
    local aa, bb = utf8_chars(a), utf8_chars(b)
    local ca, cb = {}, {}
    for _, c in ipairs(aa) do ca[c] = (ca[c] or 0) + 1 end
    for _, c in ipairs(bb) do cb[c] = (cb[c] or 0) + 1 end
    local common = 0
    for c, n in pairs(ca) do common = common + math.min(n, cb[c] or 0) end
    local total = math.max(#aa, #bb)
    return total == 0 and 0 or common / total
end

local function currentTocIndex(ui)
    local doc = ui.document
    local toc = doc:getToc() or {}
    local pageno = doc.getCurrentPage and doc:getCurrentPage() or 1
    local cur = 1
    for i, item in ipairs(toc) do
        local p = tonumber(item.page) or 0
        if p <= pageno then cur = i else break end
    end
    return cur, toc
end

--- 本地章标识：chapter_map / fanqie_results / fanqie_prefetching 都用 toc_idx。
local function localKeyOf(toc, toc_idx)
    local item = toc and toc[toc_idx]
    local start_page = tonumber(item and item.page) or 1
    return tostring(toc_idx), start_page, item and item.title or ""
end

local function cleanForFind(text)
    if not text then return "" end
    text = text:gsub("\226\128\139", ""):gsub("\239\187\191", "")
        :gsub("\226\128\140", ""):gsub("\226\128\141", "")
        :gsub("\194\160", " "):gsub("\227\128\128", "")
        :gsub("[%z\1-\8\11\12\14-\31]", "")
    return text
end

local function htmlToParagraphs(html)
    local body = html:match("<body[^>]*>([%s%S]*)</body>") or html
    local lines = {}
    for pid, text in body:gmatch('<blk[^>]-p_idx="(%d+)"[^>]*>([%s%S]-)</blk>') do
        local t = cleanForFind(text:gsub("<[^>]+>", ""))
        if t ~= "" then lines[tonumber(pid)] = t end
    end
    if next(lines) == nil then
        for seg in body:gmatch("<p[^>]*>([%s%S]-)</p>") do
            local t = cleanForFind(seg:gsub("<[^>]+>", ""))
            if t ~= "" then lines[#lines + 1] = t end
        end
    end
    return lines
end

local function fetchChapterText(source, item_id, book_id, cache, cb)
    if cache.chapter_text[item_id] then
        cb(cache.chapter_text[item_id])
        return nil
    end
    local plugin = require("source.registry").resolve("fanqie")
    if not plugin then
        cb(nil, "番茄源未启用")
        return nil
    end
    return plugin:fetchChapterAsync(
        { source_id = "fanqie", stable_id = book_id },
        { uid = item_id },
        function(result, err)
            if not result then cb(nil, err); return end
            local html = result.html or ""
            if result.file then
                local f = io.open(result.file, "rb")
                if f then html = f:read("*a"); f:close() end
            end
            local lines = htmlToParagraphs(html)
            cache.chapter_text[item_id] = lines
            cb(lines)
        end)
end

local function locateInLocal(document, text, cursor_xp, view)
    if not text or text == "" then return nil end
    if cursor_xp then
        pcall(document.gotoXPointer, document, cursor_xp)
    end
    local ok, matches = pcall(document.findText, document, text, 0, 0, true, nil, false, 1, 0x00FF)
    if document.clearSelection then pcall(document.clearSelection, document) end
    if view then
        view.highlight_visible = false
    end
    if ok and type(matches) == "table" and #matches >= 1 then
        local m = matches[1]
        if m and m.start and m["end"] then
            return { m.start, m["end"] }
        end
    end
    return nil
end

local function startScan(ui, hotspots, lines, cache, redraw, page, scan_key, on_done)
    if cache.fanqie_job then
        if cache.fanqie_job.scan_key == scan_key then return end
        cache.fanqie_job:cancel()
        cache.fanqie_job = nil
    end
    local document = ui.document
    if not document then return end
    local view = ui.view
    local saved_highlight = view and view.highlight
    local saved_highlight_visible = view and view.highlight_visible
    if view then
        view.highlight_visible = false
    end

    local toc_idx, local_toc = currentTocIndex(ui)
    local key, chapter_start_page = localKeyOf(local_toc, toc_idx)
    local saved_xp = document.getXPointer and document:getXPointer() or nil
    local chapter_start_xp = document:getPageXPointer(chapter_start_page)
    local cursor_xp = chapter_start_xp

    local result = {}
    local total = #hotspots
    local scanned, located, skip_nil, fail_find, consecutive_fail = 0, 0, 0, 0, 0

    local handle
    local function finish(aborted)
        if cache.fanqie_job == handle then cache.fanqie_job = nil end
        if saved_xp then pcall(document.gotoXPointer, document, saved_xp) end
        if view then
            view.highlight_visible = saved_highlight_visible
            view.highlight = saved_highlight
            if view.setDirty then pcall(view.setDirty, view, "ui") end
        end
        if not aborted then
            local pos, pages = {}, {}
            for i, p in pairs(result) do
                local spot = hotspots[tonumber(i)]
                if spot and type(p) == "table" then
                    -- 从本章正文回填，与在线番茄源 locate 的行为一致（不截断）
                    if spot.text == "" then
                        local pid = tonumber(spot.range:match("(%d+)$"))
                        spot.text = (pid and lines[pid]) or spot.text
                    end
                    pos[spot.range] = p
                end
            end
            if located > 0 or #hotspots == 0 then
                cache.fanqie_results[scan_key] = { pos = pos, pages = pages }
                if cache.fanqie_local_current == scan_key then
                    cache.pos = pos
                    cache.pages = pages
                    cache.scan_done = true
                end
            else
                cache.fanqie_failed = cache.fanqie_failed or {}
                cache.fanqie_failed[scan_key] = os.time()
            end
        end
        if on_done then pcall(on_done, aborted == true, located) end
        if not aborted and located > 0 and cache.fanqie_local_current == scan_key then
            redraw()
        end
    end

    local function step()
        if cache.fanqie_job ~= handle then return end
        if not ui.document then finish(true); return end
        local i = scanned + 1
        if i > total then finish(false); return end

        local spot = hotspots[i]
        local pid = tonumber(spot.range:match("(%d+)$"))
        local para = pid and lines[pid]
        if not pid or not para or #para < 4 then
            skip_nil = skip_nil + 1
            consecutive_fail = consecutive_fail + 1
            scanned = i
            UIManager:scheduleIn(0.01, step)
            return
        end

        local pos = locateInLocal(document, para, cursor_xp, view)
        if pos then
            result[i] = pos
            cursor_xp = pos[2]
            located = located + 1
            consecutive_fail = 0
        else
            fail_find = fail_find + 1
            consecutive_fail = consecutive_fail + 1
        end
        scanned = i
        UIManager:scheduleIn(0.01, step)
    end

    handle = { cancel = function() finish(true) end, scan_key = scan_key }
    cache.fanqie_job = handle
    step()
end

local function showChapterPicker(ui, link, toc_idx, local_toc, redraw, override_key, override_title)
    local List = require("ui/themes/widgets/list")
    local T = require("ffi/util").template
    local key, start_page, title = localKeyOf(local_toc, toc_idx)
    local write_key = override_key or normalize_title(title)
    local display_title = override_title or title
    local source = require("source.registry").resolve("fanqie")
    source:loadTocAsync({ source_id = "fanqie", stable_id = link.book_id }, function(toc)
        local remote = toc or {}
        local items = {}
        for i, ch in ipairs(remote) do
            items[#items + 1] = {
                text = string.format("%d. %s", i, ch.title or ""),
                callback = function()
                    link.chapter_map = link.chapter_map or {}
                    link.chapter_map[write_key] = tostring(ch.uid or "")
                    require("features.reviews.linked").set(ui, "fanqie", link)
                    redraw()
                end,
            }
        end
        List:new{
            title = T(_("选择「%1」对应的番茄章节"), tostring(display_title)),
            items = items,
            item_per_page = 15,
        }:show()
    end)
end

--- 手动更改某本地章的番茄映射。弹 showChapterPicker，选中后写 chapter_map[write_key] = 番茄 uid。
function M.pickChapter(ui, link, redraw, local_key, local_title)
    if not ui or not ui.document or not ui.document.getToc then return end
    local toc_idx, local_toc = currentTocIndex(ui)
    showChapterPicker(ui, link, toc_idx, local_toc,
        redraw or function() require("ui/uimanager"):setDirty(ui.dialog, "ui") end,
        local_key, local_title)
end

local function uidOf(ch)
    if not ch then return "" end
    return tostring(ch.uid or "")
end

local function matchChapter(ui, link, remote_toc, local_title, toc_idx, redraw, cache)
    local title_key = normalize_title(local_title)
    local best
    local map = link.chapter_map or {}
    local mapped = map[title_key]
    if mapped then
        for _, ch in ipairs(remote_toc) do
            if uidOf(ch) == tostring(mapped) then best = ch; break end
        end
    end
    if not best then
        local best_score
        for _, ch in ipairs(remote_toc) do
            local s = char_overlap(local_title, ch.title)
            if s >= TITLE_THRESHOLD and (not best_score or s > best_score) then
                best, best_score = ch, s
            end
        end
        if best then
            link.chapter_map = map
            map[title_key] = uidOf(best)
            require("features.reviews.linked").set(ui, "fanqie", link)
        end
    end
    return best
end

local function schedulePrefetch(cache, ui, link, source, local_toc, remote_toc, current_toc_idx, redraw)
    if PREFETCH_COUNT <= 0 then return end
    if cache.fanqie_queue_active then return end

    local planned = {}
    local next_idx = current_toc_idx + 1
    local item = local_toc[next_idx]
    if item then
        local key, start_page, title = localKeyOf(local_toc, next_idx)
        if key ~= tostring(current_toc_idx)
            and not cache.fanqie_prefetched[key]
            and not cache.fanqie_prefetching[key] then
            planned[1] = { key = key, toc_idx = next_idx, start_page = start_page, title = title }
        end
    end
    if #planned == 0 then return end

    cache.fanqie_queue_active = true

    local function finish_current()
        cache.fanqie_queue_active = false
        local next_task = table.remove(cache.fanqie_queue, 1)
        if next_task then
            UIManager:scheduleIn(0.1, function()
                prefetchOne(next_task)
            end)
        end
    end

    local function prefetchOne(plan)
        local key = plan.key
        if cache.fanqie_prefetching[key] or cache.fanqie_prefetched[key] then
            finish_current(); return
        end
        cache.fanqie_prefetching[key] = true

        local best = matchChapter(ui, link, remote_toc, plan.title, plan.toc_idx, redraw, cache)
        if not best then
            cache.fanqie_prefetching[key] = nil
            finish_current(); return
        end
        local item_id = uidOf(best)
        local chapter_idx = tonumber(best.idx)
        if item_id == "" or not chapter_idx then
            cache.fanqie_prefetching[key] = nil
            finish_current(); return
        end

        if cache.fanqie_results[key] then
            cache.fanqie_prefetching[key] = nil
            cache.fanqie_prefetched[key] = true
            finish_current(); return
        end

        local function onScanDone(aborted, located)
            cache.fanqie_prefetching[key] = nil
            if not aborted and located > 0 then
                cache.fanqie_prefetched[key] = true
            end
            finish_current()
        end

        local function afterLines(lines)
            if not lines then
                cache.fanqie_prefetching[key] = nil
                finish_current(); return
            end
            local hotspots = cache.hotspots[item_id]
            if not hotspots then
                source:paragraphHotspotsAsync({
                    source_id = "fanqie", stable_id = link.book_id,
                    chapter_idx = chapter_idx, source = source,
                }, function(list)
                    if not list then
                        cache.fanqie_prefetching[key] = nil
                        finish_current(); return
                    end
                    cache.hotspots[item_id] = list
                    startScan(ui, list, lines, cache, redraw, plan.start_page, key, onScanDone)
                end)
            else
                startScan(ui, hotspots, lines, cache, redraw, plan.start_page, key, onScanDone)
            end
        end

        local lines = cache.chapter_text[item_id]
        if lines then
            afterLines(lines)
        else
            fetchChapterText(source, item_id, link.book_id, cache, afterLines)
        end
    end

    for _, plan in ipairs(planned) do
        table.insert(cache.fanqie_queue, plan)
    end
    local first = table.remove(cache.fanqie_queue, 1)
    if first then
        prefetchOne(first)
    else
        cache.fanqie_queue_active = false
    end
end

function M.target(ui, link, cache, redraw)
    if ui.doc_settings and ui.doc_settings:readSetting("fanqie_reviews_enabled") == false then
        return nil
    end
    local source = require("source.registry").resolve("fanqie")
    if not source or not source:configured() then return nil end
    if not ui.document or not ui.document.getToc then return nil end

    return {
        key = "fanqie\0" .. link.book_id,
        fetch = function(cb)
            source:loadTocAsync({ source_id = "fanqie", stable_id = link.book_id }, cb)
        end,
        place = function(remote_toc)
            if type(remote_toc) ~= "table" or #remote_toc == 0 then
                return {}
            end
            local toc_idx, local_toc = currentTocIndex(ui)
            local local_key, chapter_start_page, local_title = localKeyOf(local_toc, toc_idx)
            if local_title == "" then
                return {}
            end

            local best = matchChapter(ui, link, remote_toc, local_title, toc_idx, redraw, cache)
            if not best then
                if not cache.picker_shown then
                    cache.picker_shown = true
                    showChapterPicker(ui, link, toc_idx, local_toc, redraw)
                end
                return {}
            end

            local item_id = uidOf(best)
            local chapter_idx = tonumber(best.idx)
            if item_id == "" or not chapter_idx then
                return {}
            end

            if cache.fanqie_local_current ~= local_key then
                cache.fanqie_local_current = local_key
                cache.scan_key = local_key
                local cached = cache.fanqie_results[local_key]
                if cached then
                    cache.pos = cached.pos
                    cache.pages = cached.pages
                    cache.scan_done = true
                else
                    cache.pos = {}
                    cache.pages = {}
                    cache.scan_done = nil
                end
            end

            local document = ui.document
            local page = PageMarks.currentPage(ui)
            local width, height = PageMarks.screenSize(ui)

            if not cache.fanqie_results[local_key] then
                local failed_at = cache.fanqie_failed and cache.fanqie_failed[local_key]
                if failed_at and os.time() - failed_at < 60 then
                    return {}
                end

                local lines = cache.chapter_text[item_id]
                if not lines then
                    fetchChapterText(source, item_id, link.book_id, cache, function(list)
                        if list then redraw() end
                    end)
                    return {}
                end

                local hotspots = cache.hotspots[item_id]
                if not hotspots then
                    source:paragraphHotspotsAsync({
                        source_id = "fanqie", stable_id = link.book_id,
                        chapter_idx = chapter_idx, source = source,
                    }, function(list)
                        cache.hotspots[item_id] = list
                        redraw()
                    end)
                    return {}
                end

                if not cache.scan_done and not cache.fanqie_prefetching[local_key] then
                    startScan(ui, hotspots, lines, cache, redraw, page, local_key)
                end
            end

            -- 兜底回填：place 时按 item_id 从章节正文补 text，保证 entry.spot.text 有原文
            local lines = cache.chapter_text[item_id]
            local out = {}
            for _, spot in ipairs(cache.hotspots[item_id] or {}) do
                local pos = cache.pos[spot.range]
                if pos then
                    if (spot.text == nil or spot.text == "") and lines then
                        local pid = tonumber(spot.range:match("(%d+)$"))
                        if pid and lines[pid] then
                            spot.text = lines[pid]
                        end
                    end
                    local span = cache.pages[spot.range]
                    if not span then
                        span = {
                            document:getPageFromXPointer(pos[1]),
                            document:getPageFromXPointer(pos[2]),
                        }
                        cache.pages[spot.range] = span
                    end
                    if span[1] <= page + 1 and span[2] >= page then
                        local boxes = {}
                        for _, box in ipairs(document:getScreenBoxesFromPositions(
                            pos[1], pos[2], true) or {}) do
                            if PageMarks.intersects(box, width, height) then
                                boxes[#boxes + 1] = box
                            end
                        end
                        if #boxes > 0 then
                            out[#out + 1] = {
                                entry = {
                                    identity = {
                                        source_id = "fanqie", stable_id = link.book_id,
                                        chapter_idx = chapter_idx, source = source,
                                    },
                                    spot = spot,
                                },
                                boxes = boxes,
                            }
                        end
                    end
                end
            end

            if (cache.scan_done or #(cache.hotspots[item_id] or {}) == 0) and not cache.fanqie_queue_active then
                schedulePrefetch(cache, ui, link, source, local_toc, remote_toc, toc_idx, redraw)
            end

            return out
        end,
    }
end

return M
