--[[-- 书籍详情子模块。 @module desktop.detail --]]

local Book = require("ui.widgets.book")
local Confirm = require("ui.themes.widgets.confirm")
local Sheet = require("ui.themes.widgets.sheet")
local Toast = require("ui.themes.widgets.toast")
local Store = require("book.store")
local _ = require("gettext")
local T = require("ffi/util").template

local Common = require("desktop.detail.common")
local Cache = require("desktop.detail.cache")
local storeBackend = Common.storeBackend
local bookOwnerSource = Common.bookOwnerSource
local bookSupportsScrape = Common.bookSupportsScrape
local bookSupportsEdit = Common.bookSupportsEdit
local cacheKey = Cache.key

return function(Detail)
--- 书城详情：已在架可开读的书。
function Detail:storeReadableBook()
    if self._installed then return self._installed end
    local book = self.book
    if storeBackend(book) or not (book.source_id and book.stable_id) then return nil end
    local row = require("book.books_db").get(book.source_id, book.stable_id)
    if not row or tonumber(row.deleted) ~= 0 then return nil end
    if book.percent == nil then
        local prog = require("book.progress_db").get(book.source_id, book.stable_id)
        if prog then book.percent = math.floor((tonumber(prog.fraction) or 0) * 100 + 0.5) end
    end
    return book
end

--- 书城详情主按钮：未入库「加入书库」；已在架则「开始阅读」。仅在可导出时附带「导出 EPUB」。
function Detail:storePrimary()
    local readable = self:storeReadableBook()
    local tools = {}

    -- 只在当前书籍的属主源支持按章缓存时才加上导出按钮
    if Cache.supported(readable or self.book, self.source) then
        tools[#tools + 1] = {
            id = "export_epub",
            icon = "book",
            text = _("导出 EPUB"),
        }
    end

    if readable then
        local pct = Book.pct(readable)
        local primary = {
            id = "open",
            icon = "play_arrow",
            text = pct > 0 and pct < 100 and _("继续阅读") or _("开始阅读"),
            callback = function() self:openBook() end,
        }
        return primary, tools
    end

    local primary = {
        id = "install",
        icon = "add",
        text = _("加入书库"),
        callback = function() self:installStoreBook() end,
    }
    return primary, tools
end

--- 续读目标按详情页缓存
function Detail:readingTarget()
    if self._reading_target == nil then
        local owner = bookOwnerSource(self.book, self.source)
        local target = owner and owner.readingTarget and owner:readingTarget(self.book)
        self._reading_target = target or false
    end
    return self._reading_target or nil
end

--- 主按钮：源提供了阅读目标就直接开，否则保持原开书流程。
function Detail:openBook()
    local plugin = self.plugin
    local b = self:storeReadableBook() or self.book
    local target
    if b == self.book then
        target = self:readingTarget()
    else
        local owner = bookOwnerSource(b, self.source)
        target = owner and owner.readingTarget and owner:readingTarget(b)
    end
    self:close()
    if not plugin then return end
    require("desktop.open").book(plugin, target and target.book or b)
end

--- 「选择卷」
function Detail:chooseVolume()
    local plugin = self.plugin
    local b = self.book
    self:close()
    if plugin then require("desktop.open").book(plugin, b) end
end

--- 选择缓存范围
function Detail:chooseCacheRange(with_reviews)
    if self.closed then return end
    Cache.chooseRange(self.book, self.source, with_reviews)
end

--- 缓存章节正文（可带段评）
function Detail:cacheAllChapters(range, with_reviews)
    if self.closed then return end
    Cache.cacheAll(self.book, self.source, range, with_reviews)
end

--- 整本书源的未下载书
function Detail:downloadBook()
    if self.closed then return end
    if not require("ui/network/manager"):isConnected() then
        Toast:new{ text = _("网络不可用，请先连接 Wi-Fi"), timeout = 3 }:show()
        return
    end
    local book = self.book
    local source = bookOwnerSource(book, self.source)
    if not source then return end
    local identity = { source_id = book.source_id, stable_id = book.stable_id, source = source, book = book }
    require("workers.ui.task_dialog").start{
        key = cacheKey(book),
        kind = "cache",
        title = book.title or book.stable_id,
        on_done = function(result)
            Toast:new{ text = result.ok and _("下载完成") or (result.err or _("下载失败")), timeout = 3 }:show()
            if not result.ok then return end
            if self.desktop then self.desktop:onEvent("shelf_changed") end
            if not self.closed then self:reload() end
        end,
        run = function(_report, done)
            return source:openBookAsync(identity, nil, function(path, err)
                done({ ok = path ~= nil, err = err })
            end)
        end,
    }
end

--- 书城书（Z-Library / OPDS）
function Detail:installStoreBook()
    local book = self.book
    local store = storeBackend(book)
    if not store then
        self:addToShelf()
        return
    end
    if store.hasCredentials and not store.hasCredentials() then
        require("store." .. book.source_id .. ".setting").open(self.plugin)
        return
    end
    local local_src = require("source.registry").resolve("local")
    if local_src and not local_src:configured() then
        require("source.local.setting").open(function() self:installStoreBook() end)
        return
    end
    if not local_src or type(local_src.importBookAsync) ~= "function" then
        Toast:new{ text = _("当前数据源不支持导入书籍") }:show()
        return
    end
    local desk = self.desktop
    local total = tonumber(book.filesize)
    require("workers.ui.task_dialog").start{
        key = "install\0" .. tostring(book.source_id) .. "\0" .. tostring(book.stable_id),
        kind = "download",
        title = book.title,
        restartable = true,
        run = function(report, done)
            return store.installAsync(local_src, book, function(bytes)
                report(nil, bytes, total)
            end, function(ok, err, filename, path)
                done({ ok = ok, err = err, filename = filename, path = path })
            end)
        end,
        on_done = function(result)
            if not result.ok then
                Toast:new{ text = result.err or _("下载失败") }:show()
                return
            end
            Toast:new{
                text = _("已加入书库：") .. tostring(result.filename or book.title),
                timeout = 3,
            }:show()
            if desk and not desk.closed then
                desk:onEvent("shelf_changed")
                if desk.tab == "library" then desk:updateView() end
            end
            if not self.closed and result.path then
                self._installed = {
                    source_id = "local",
                    stable_id = result.path,
                    path = result.path,
                    title = book.title,
                }
                self:refresh()
            end
        end,
    }
end

--- 书源搜索结果：加入书库
function Detail:addToShelf()
    local book = self.book
    Store.rememberMany({ book })
    if not require("book.books_db").upsertLocal(book) then
        Toast:new{ text = _("加入书库失败") }:show()
        return
    end
    Toast:new{ text = T(_("已加入书库：%1"), Book.title(book)), timeout = 3 }:show()
    local source = bookOwnerSource(book, nil)
    if source and source:configured() and require("ui/network/manager"):isConnected() then
        source:pushDirty()
    end
    local desk = self.desktop
    if desk and not desk.closed then desk:onEvent("shelf_changed") end
    if not self.closed then self:refresh() end
end

--- 切换已读 / 未读
function Detail:toggleRead()
    local book = self.book
    local is_read = tonumber(book.read_state) == 1
    if not require("book.books_db").setRead(book.source_id, book.stable_id, not is_read) then
        Toast:new{ text = _("更新阅读状态失败"), timeout = 2 }:show()
        return
    end
    local source = bookOwnerSource(book, self.source)
    if source and require("ui/network/manager"):isConnected() then
        source:syncProgressAsync({
            identity = { source_id = book.source_id, stable_id = book.stable_id, book = book, source = source },
            dirty_only = true,
        }, function() end)
    end
    self:reload()
end

--- 单本重读内嵌元数据（有 sidecar 读 sidecar，没有开引擎）。
function Detail:refreshMeta()
    local book = self.book
    local owner = bookOwnerSource(book, self.source)
    if not owner or type(owner.refreshBookMetaAsync) ~= "function" then
        Toast:new{ text = _("当前数据源不支持") }:show()
        return
    end
    Toast:new{ text = _("正在读取内嵌元数据…"), timeout = 1 }:show()
    owner:refreshBookMetaAsync(book.stable_id, function(ok, err)
        if not ok then
            Toast:new{ text = err or _("读取失败") }:show()
            return
        end
        Toast:new{ text = _("元数据已刷新"), timeout = 1.5 }:show()
        self:reload()
    end)
end

--- 删除本书：软删除还是彻底删除
function Detail:deleteBook()
    Sheet:new{
        title = _("删除"),
        items = {
            { text = _("软删除（清本地正文，进度划线可恢复）"), callback = function() self:softDelete() end },
            { text = _("彻底删除（进度、划线与书架一并清除）"), callback = function() self:hardDelete() end },
        },
    }:show()
end

--- 彻底删除
function Detail:hardDelete()
    local book = self.book
    Confirm:new{
        text = T(_("彻底删除《%1》？\n\n会清理：本地文件与缓存、书架条目、阅读进度、划线与笔记、统计\n有云端时下次同步也会从远端删除，无法从「软删除」筛选恢复。"), Book.title(book)),
        ok_text = _("删除"),
        ok_callback = function()
            local source = bookOwnerSource(book, self.source)
            if not source then
                Toast:new{ text = _("当前数据源不支持删除本书") }:show()
                return
            end
            source:deleteBookAsync({
                source_id = book.source_id,
                stable_id = book.stable_id,
                book = book,
                source = source,
            }, function(ok, err)
                if not ok then
                    Toast:new{ text = err or _("删除本书失败") }:show()
                    return
                end
                if self.desktop then self.desktop:onEvent("shelf_changed") end
                if self.closed then return end
                self._dirty = true
                self:close()
            end)
        end,
    }:show()
end

local function purgeLocal(self, keep_cover, text, ok_text, done_text)
    local book = self.book
    Confirm:new{
        text = T(text, Book.title(book)),
        ok_text = ok_text,
        ok_callback = function()
            if require("workers.tasks").get(cacheKey(book)) then
                Toast:new{ text = _("本书正在后台缓存，请稍后再试"), timeout = 3 }:show()
                return
            end
            local ok, leftover = Store.clearCache(book.source_id, book.stable_id, keep_cover)
            local result = done_text
            if not ok then
                result = _("清理缓存失败")
            elseif leftover then
                result = _("部分缓存文件未能删除")
            end
            Toast:new{ text = result, timeout = 3 }:show()
            self:reload()
        end,
    }:show()
end

function Detail:clearCache()
    purgeLocal(self, false, _("清理《%1》的本地缓存？\n正文、章节与图片需重新下载。"), _("清理"), _("缓存已清理"))
end

function Detail:softDelete()
    local book = self.book
    Confirm:new{
        text = T(_("软删除《%1》？\n\n会清理：本地正文与章节缓存\n会保留：书目、封面、阅读进度、划线与笔记\n书从书架隐藏，筛选「软删除」可恢复；不影响云端。"), Book.title(book)),
        ok_text = _("软删除"),
        ok_callback = function()
            if require("workers.tasks").get(cacheKey(book)) then
                Toast:new{ text = _("本书正在后台缓存，请稍后再试"), timeout = 3 }:show()
                return
            end
            if not Store.softDelete(book.source_id, book.stable_id) then
                Toast:new{ text = _("软删除失败"), timeout = 3 }:show()
                return
            end
            Toast:new{ text = _("已软删除"), timeout = 2 }:show()
            if self.desktop then self.desktop:onEvent("shelf_changed") end
            if self.closed then return end
            self._dirty = true
            self:close()
        end,
    }:show()
end

function Detail:restore()
    if not require("book.books_db").setHidden(self.book.source_id, self.book.stable_id, false) then
        Toast:new{ text = _("恢复失败"), timeout = 2 }:show()
        return
    end
    Toast:new{ text = _("已恢复到书架"), timeout = 2 }:show()
    self:reload()
end

--- 库内书底栏动作
function Detail.actionPlan(book, owner, target)
    local tools = {}
    if bookSupportsEdit(book, owner) then
        tools[#tools + 1] = { id = "edit", icon = "edit", text = _("编辑") }
    end
    if bookSupportsScrape(book, owner) then
        tools[#tools + 1] = { id = "scrape", icon = "search", text = _("刮削") }
    end
    local can_read = owner ~= nil and (owner.type == "book" or owner.type == "chapter")
    local cached = can_read and Store.isCached(book)
    if can_read and owner.type == "chapter" and type(owner.cacheAllChaptersAsync) == "function" then
        tools[#tools + 1] = { id = "download", icon = "download", text = _("下载") }
        -- 无条件提供导出选项
        tools[#tools + 1] = { id = "export_epub", icon = "book", text = _("导出 EPUB") }
    elseif can_read and not cached and owner.type == "book" and book.source_id and book.stable_id
        and not require("book.books_db").isDownloaded(book.source_id, book.stable_id, false) then
        tools[#tools + 1] = { id = "download_book", icon = "download", text = _("下载") }
    end
    if cached then
        tools[#tools + 1] = { id = "clear_cache", icon = "cleaning_services", text = _("清理缓存") }
    end
    if owner and type(owner.bookReviewsAsync) == "function" then
        tools[#tools + 1] = { id = "reviews", icon = "forum", text = _("书评") }
    end
    -- 本地目录书：单本重读内嵌元数据
    if owner and owner.type == "book" and book.source_id == "local" and book.stable_id
        and not require("source.local.client").isRemote(book.stable_id) then
        tools[#tools + 1] = { id = "refresh_meta", icon = "refresh", text = _("刷新元数据") }
    end
    if book.source_id and book.stable_id then
        if tonumber(book.read_state) == 1 then
            tools[#tools + 1] = { id = "unread", icon = "undo", text = _("未读") }
        else
            tools[#tools + 1] = { id = "read", icon = "done_all", text = _("已读") }
        end
        if tonumber(book.hidden) == 1 then
            tools[#tools + 1] = { id = "restore", icon = "restore_from_trash", text = _("恢复") }
        end
        tools[#tools + 1] = { id = "delete", icon = "delete", text = _("删除") }
    end
    local primary
    if target == nil and can_read and owner.readingTarget then
        target = owner:readingTarget(book)
    end
    if can_read then
        local text
        if target and target.text then
            text = target.text
        else
            local pct = Book.pct(book)
            text = pct > 0 and pct < 100 and _("继续阅读") or _("开始阅读")
        end
        primary = { id = "open", icon = "play_arrow", text = text,
            caption = target and target.caption or nil }
    end
    if target and target.select_text then
        tools[#tools + 1] = { id = "volumes", icon = "list", text = target.select_text }
    end
    return tools, primary
end

function Detail:showReviews()
    local owner = bookOwnerSource(self.book, self.source)
    if not owner or type(owner.bookReviewsAsync) ~= "function" then return end
    require("ui/network/manager"):runWhenConnected(function()
        local cancelled, job = false, nil
        local waiting = require("ui.themes.widgets.progress_dialog"):new{
            title = _("书评"), text = _("正在加载书评…"), dismissable = false,
            on_cancel = function()
                cancelled = true
                if job and job.cancel then job.cancel() end
            end,
        }
        job = waiting:showWhile(owner.bookReviewsAsync, owner, self.book, function(page, err)
            waiting:close()
            if cancelled or self.closed then return end
            if not page then
                Toast:new{ text = err or _("请求失败"), timeout = 3 }:show()
                return
            end
            local items = page.items or {}
            if #items == 0 then
                Toast:new{ text = _("暂无书评"), timeout = 2 }:show()
                return
            end
            local show = require("utils.extension").last("desktop.comments")
            if show then
                show(self.book, page)
                return
            end
            local lines = {}
            for _idx, item in ipairs(items) do
                local head = item.author or ""
                if item.time and item.time ~= "" then head = head .. "  " .. item.time end
                lines[#lines + 1] = head
                if item.grade and not item.reply_to then
                    lines[#lines + 1] = _("评分") .. " " .. tostring(item.grade)
                end
                local body = item.text or ""
                if item.reply_to and item.reply_to ~= "" then
                    body = T(_("回复 %1：%2"), item.reply_to, body)
                end
                lines[#lines + 1] = body
                lines[#lines + 1] = ""
            end
            if page.pages and page.pages > 1 then
                lines[#lines + 1] = _("还有更多书评")
            end
            require("ui.themes.widgets.text_viewer"):new{
                title = page.title or _("书评"), text = table.concat(lines, "\n"),
            }:show()
        end)
    end)
end

function Detail:startScrape()
    local book = self.book
    if not bookSupportsScrape(book, self.source) then
        Toast:new{ text = _("当前数据源不支持刮削"), timeout = 2 }:show()
        return
    end
    require("desktop.detail.scrape.ui").start(book, book.title, function()
        if not self.closed then self:reload() end
    end, self)
end

--- 导出为 EPUB：自动补全缺失章节，漏章时弹窗让用户选择。
function Detail:exportEpub()
    if self.closed then return end
    local book = self.book
    local source = bookOwnerSource(book, self.source)
    if not source or type(source.cacheAllChaptersAsync) ~= "function" then
        Toast:new{ text = _("当前数据源不支持导出"), timeout = 2 }:show()
        return
    end

    -- 如果目录没缓存过（未入库/未打开过），先拉一次目录
    local toc = require("source.toc").read(book.source_id, book.stable_id)
    if not toc or #toc == 0 then
        if type(source.loadTocAsync) ~= "function" then
            Toast:new{ text = _("目录为空，请先打开一次本书"), timeout = 2 }:show()
            return
        end
        local ProgressDialog = require("ui/themes/widgets/progress_dialog")
        local dlg = ProgressDialog:new{
            title = _("导出 EPUB"),
            text = _("正在获取目录..."),
            dismissable = false,
        }
        dlg:show()
        local identity = { source_id = book.source_id, stable_id = book.stable_id, book = book, source = source }
        source:loadTocAsync(identity, function(t, err)
            dlg:close()
            if not t or #t == 0 then
                Toast:new{ text = err or _("目录为空，无法导出"), timeout = 3 }:show()
                return
            end
            self:_do_export(book, source, t)
        end)
        return
    end
    self:_do_export(book, source, toc)
end

function Detail:_do_export(book, source, toc)
    local home_dir = G_reader_settings:readSetting("home_dir") or "/mnt/onboard"
    local safe_title = (book.title or book.stable_id):gsub("[/\\:%*%?\"<>|]", "_")
    local output_path = home_dir .. "/" .. safe_title .. ".epub"

    Confirm:new{
        text = T(_("导出前会自动检查并补全缺失的章节（已下载的会跳过）。\n\n导出位置：%1\n\n是否继续？"), output_path),
        ok_text = _("开始导出"),
        ok_callback = function()
            os.execute("mkdir -p " .. string.format("%q", home_dir))

            require("workers.ui.task_dialog").start{
                key = "export\0" .. book.source_id .. "\0" .. book.stable_id,
                kind = "cache",
                title = book.title or book.stable_id,
                restartable = true,
                run = function(report, done)
                    local identity = { source_id = book.source_id, stable_id = book.stable_id, book = book, source = source }

                    report(_("检查缺失章节..."), 0, #toc)
                    local cache_job = source:cacheAllChaptersAsync(identity, function(cached, total)
                        report(_("补全章节"), cached, total)
                    end, function(ok, cached, err, total, failed, failed_idx)
                        if failed > 0 then
                            local shown = {}
                            for i = 1, math.min(#(failed_idx or {}), 10) do shown[#shown + 1] = failed_idx[i] end
                            local failed_str = table.concat(shown, "、")
                                .. (#(failed_idx or {}) > 10 and "…" or "")
                            local text = T(
                                _("有 %1 章下载失败（章号：%2）。\n\n是重试补全，还是跳过并导出当前已有章节？"),
                                failed, failed_str
                            )
                            Confirm:new{
                                text = text,
                                ok_text = _("重试"),
                                ok_callback = function()
                                    local retry_job = source:cacheAllChaptersAsync(identity, function(c, t)
                                        report(_("重新补全章节"), c, t)
                                    end, function(_, _, _, _, _, _)
                                        report(_("准备打包..."), 0, 1)
                                        self:runEpubWorker(book, toc, output_path, report, done)
                                    end)
                                    if cache_job and cache_job.cancel then cache_job.cancel = retry_job.cancel end
                                end,
                                cancel_text = _("跳过并导出"),
                                cancel_callback = function()
                                    report(_("准备打包..."), 0, 1)
                                    self:runEpubWorker(book, toc, output_path, report, done)
                                end,
                            }:show()
                        else
                            report(_("准备打包..."), 0, 1)
                            self:runEpubWorker(book, toc, output_path, report, done)
                        end
                    end)
                    return {
                        cancel = function()
                            if cache_job and cache_job.cancel then cache_job.cancel() end
                        end,
                    }
                end,
                on_done = function(result)
                    if result.ok then
                        -- 加入对应书源的书单
                        pcall(function()
                            local ReadCollection = require("readcollection")
                            local COLLECTION_NAME = book.source_id or "导出"
                            if not ReadCollection.coll then ReadCollection:_read() end
                            if not ReadCollection.coll[COLLECTION_NAME] then
                                ReadCollection:addCollection(COLLECTION_NAME)
                            end
                            if not ReadCollection:isFileInCollection(result.path, COLLECTION_NAME) then
                                ReadCollection:addItem(result.path, COLLECTION_NAME)
                                ReadCollection:write({ [COLLECTION_NAME] = true })
                            end
                        end)
                        Confirm:new{
                            text = T(_("导出成功：\n%1\n\n是否立即打开阅读？"), result.path),
                            ok_text = _("立即阅读"),
                            ok_callback = function()
                                require("desktop.open").book(self.plugin, {
                                    source_id = "local",
                                    stable_id = result.path,
                                    path = result.path,
                                    title = book.title,
                                })
                            end,
                            cancel_text = _("关闭"),
                        }:show()
                    else
                        Toast:new{ text = _("导出失败: ") .. (result.error or "未知错误"), timeout = 4 }:show()
                    end
                end,
            }
        end,
    }:show()
end

function Detail:runEpubWorker(book, toc, output_path, report, done)
    local Paths = require("utils.paths")
    local Job = require("workers.job")

    local book_dir = Paths.bookWorkDir(book.stable_id, book.source_id)

    local BookDB = require("book.books_db")
    local full_row = BookDB.get(book.source_id, book.stable_id)
    local meta = (full_row and full_row.meta) or book.meta or {}

    local task = {
        book = {
            stable_id = book.stable_id,
            source_id = book.source_id,
            title = book.title or (full_row and full_row.title),
            authors = book.authors or (full_row and full_row.authors),
            intro = book.intro or (full_row and full_row.intro),
            category = book.category or (full_row and full_row.category),
            series = book.series or (full_row and full_row.series),
            tags = meta.tags,
            language = meta.language or "zh",
            publisher = meta.publisher,
            published = meta.published,
            isbn = meta.isbn,
        },
        toc = toc,
        output_path = output_path,
        book_dir = book_dir,
        container_xml = [[<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>]],
        css = "body{line-height:1.7;margin:5%;}p{text-indent:2em;margin:.45em 0;}img{max-width:100%;}",
    }

    Job.run(function()
        return require("book.epub_worker").run(task)
    end, {
        name = "export_epub",
        kind = "light",
        timeout = 300,
        on_done = done,
        on_failed = function(err)
            done({ ok = false, error = tostring(err) })
        end,
    })
end

end
