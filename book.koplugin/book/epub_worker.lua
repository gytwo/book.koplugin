--[[--
子进程：将月读缓存的章节和图片打包为 EPUB（带封面、完整元数据、图片完整性校验）。
@module koplugin.book.epub_worker
--]]

local Archiver = require("ffi/archiver")
local lfs = require("libs/libkoreader-lfs")
local Paths = require("utils.paths")
local Text = require("utils.text")

local Worker = {}

--- XML 转义，防止书名或简介里的特殊字符破坏 XML 结构
local function xml_escape(s)
    s = tostring(s or "")
    s = s:gsub("[%z\1-\8\11\12\14-\31]", "")
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub("\"", "&quot;")
    return s
end

--- 将月读生成的 HTML 规范化为严格的 XHTML（参考 weread 的克制风格）
local function to_xhtml(html, title)
    html = tostring(html or "")

    -- 1. 提取正文
    local bodies = {}
    local remaining = html
    while remaining ~= "" do
        local body_start = remaining:find("<body", 1, true)
        if not body_start then break end
        local body_open_end = remaining:find(">", body_start, true)
        if not body_open_end then break end
        local body_close = remaining:find("</body>", body_open_end, true)
        if not body_close then
            bodies[#bodies + 1] = remaining:sub(body_open_end + 1)
            break
        end
        bodies[#bodies + 1] = remaining:sub(body_open_end + 1, body_close - 1)
        remaining = remaining:sub(body_close + 7)
    end

    local content
    if #bodies > 0 then
        content = table.concat(bodies, "\n")
    else
        content = html:gsub("<%?xml.-%?>", "")
        content = content:gsub("<!DOCTYPE.-%>", "")
        content = content:gsub("<html[^>]*>", "")
        content = content:gsub("</html>", "")
        content = content:gsub("<head>.-</head>", "")
    end

    -- 2. XML 净化
    content = content:gsub("&nbsp;", "&#160;")
    content = content:gsub("&copy;", "&#169;")
    content = content:gsub("&ldquo;", "&#8220;")
    content = content:gsub("&rdquo;", "&#8221;")
    content = content:gsub("<img([^>]-)/?>", "<img%1/>")
    content = content:gsub("<br([^>]-)/?>", "<br%1/>")
    content = content:gsub("<hr([^>]-)/?>", "<hr%1/>")

    -- 3. 强制修正所有图片相对路径为 ../images/
    content = content:gsub('src=["\']images/', 'src="../images/')
    content = content:gsub("src=['\"]images/", "src='../images/")

    -- 4. 拼装外壳
    return string.format([[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>%s</title></head>
<body>%s</body>
</html>]], xml_escape(title), content)
end

--- 生成 content.opf（包含完整元数据）
local function make_opf(book, manifest, spine, cover_meta)
    local lang = "zh-CN"
    if book.language == "en" then lang = "en-US"
    elseif book.language == "ja" then lang = "ja-JP" end

    local meta_lines = {}

    if book.intro and book.intro ~= "" then
        meta_lines[#meta_lines + 1] = string.format("<dc:description>%s</dc:description>", xml_escape(book.intro))
    end
    if book.publisher and book.publisher ~= "" then
        meta_lines[#meta_lines + 1] = string.format("<dc:publisher>%s</dc:publisher>", xml_escape(book.publisher))
    end
    if book.published and book.published ~= "" then
        meta_lines[#meta_lines + 1] = string.format("<dc:date>%s</dc:date>", xml_escape(book.published))
    end
    if book.isbn and book.isbn ~= "" then
        meta_lines[#meta_lines + 1] = string.format("<dc:identifier>%s</dc:identifier>", xml_escape(book.isbn))
    end

    -- 分类、系列、标签
    local subjects = {}
    local seen = {}
    local function add_subject(s)
        if s and s ~= "" then
            s = s:match("^%s*(.-)%s*$")
            if s ~= "" and not seen[s] then
                seen[s] = true
                subjects[#subjects + 1] = s
            end
        end
    end
    add_subject(book.category)
    add_subject(book.series)
    if book.tags then
        for tag in tostring(book.tags):gmatch("[^,，;；%s]+") do add_subject(tag) end
    end
    for _, s in ipairs(subjects) do
        meta_lines[#meta_lines + 1] = string.format("<dc:subject>%s</dc:subject>", xml_escape(s))
    end

    if cover_meta and cover_meta ~= "" then
        meta_lines[#meta_lines + 1] = cover_meta
    end

    return string.format([[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">moon-%s</dc:identifier>
    <dc:title>%s</dc:title>
    <dc:creator>%s</dc:creator>
    <dc:language>%s</dc:language>
    <dc:source>月读</dc:source>
    %s
  </metadata>
  <manifest>
    %s
  </manifest>
  <spine toc="toc">
    %s
  </spine>
</package>]],
        xml_escape(book.stable_id),
        xml_escape(book.title or "未命名"),
        xml_escape(book.authors or "佚名"),
        lang,
        table.concat(meta_lines, "\n    "),
        table.concat(manifest, "\n    "),
        table.concat(spine, "\n    "))
end

--- 生成 toc.ncx（兼容旧版阅读器的目录）
local function make_ncx(book, valid)
    local points = {}
    for i, ch in ipairs(valid) do
        points[#points + 1] = string.format([[
    <navPoint id="navPoint-%d" playOrder="%d">
      <navLabel><text>%s</text></navLabel>
      <content src="text/chapter-%03d.xhtml"/>
    </navPoint>]], i, i, xml_escape(ch.title), ch.idx)
    end
    return string.format([[<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="moon-%s"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>%s</text></docTitle>
  <navMap>%s
  </navMap>
</ncx>]], xml_escape(book.stable_id), xml_escape(book.title or ""), table.concat(points))
end

--- 生成 nav.xhtml（EPUB3 目录）
local function make_nav(book, valid)
    local lis = {}
    for _, ch in ipairs(valid) do
        lis[#lis + 1] = string.format('<li><a href="text/chapter-%03d.xhtml">%s</a></li>',
            ch.idx, xml_escape(ch.title))
    end
    return string.format([[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>目录</title></head>
<body>
<nav epub:type="toc">
  <ol>
      %s
  </ol>
</nav>
</body>
</html>]], table.concat(lis, "\n      "))
end

--- 在书籍工作目录中寻找封面文件
local function find_cover(book)
    local Paths = require("utils.paths")
    local path = Paths.coverPath(book.stable_id, book.source_id)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return path, "png"
    end
    return nil, nil
end

--- 子进程入口
function Worker.run(task)
    local book = task.book
    local toc = task.toc
    local out = task.output_path
    local book_dir = task.book_dir
    local images_dir = book_dir .. "/images"

    -- 1. 寻找封面
    local cover_path, cover_ext = find_cover(book)

    -- 2. 过滤出实际存在的章节文件，并严格校验图片是否完全落地
    local valid = {}
    local failed = {}
    for i, ch in ipairs(toc) do
        local path = Paths.chapterPath(book.stable_id, i, book.source_id)
        local f = io.open(path, "rb")
        if f then
            local html = f:read("*a")
            f:close()

            local has_remote = false
            if Text.hasRemoteImageSrc then
                has_remote = Text.hasRemoteImageSrc(html)
            else
                has_remote = html:find('https?://[^"\']+%.(jpg|jpeg|png|gif|webp)') ~= nil
            end

            if not has_remote then
                valid[#valid + 1] = { idx = i, title = ch.title, path = path }
            else
                failed[#failed + 1] = i
            end
        else
            failed[#failed + 1] = i
        end
    end

    if #valid == 0 then
        return { ok = false, error = "本地没有任何完整的章节文件（正文或图片未下载完整），无法打包", failed = failed }
    end

    -- 3. 开始打包
    local part = out .. ".part"
    local writer = Archiver.Writer:new()
    if not writer:open(part, "epub") then
        return { ok = false, error = "无法创建压缩包" }
    end

    local ok, err = pcall(function()
        writer:setZipCompression("store")
        writer:addFileFromMemory("mimetype", "application/epub+zip")
        writer:setZipCompression("deflate")
        writer:addFileFromMemory("META-INF/container.xml", task.container_xml)

        local manifest, spine = {}, {}
        local cover_meta = ""

        manifest[#manifest + 1] = [[<item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>]]
        manifest[#manifest + 1] = [[<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>]]

        -- 3.1 写入封面
        if cover_path then
            local f = io.open(cover_path, "rb")
            local cover_data = f:read("*a")
            f:close()
            local mime = cover_ext == "jpg" and "jpeg" or cover_ext
            writer:addFileFromMemory("OEBPS/images/cover." .. mime, cover_data)
            manifest[#manifest + 1] = string.format(
                '<item id="cover-image" href="images/cover.%s" media-type="image/%s" properties="cover-image"/>',
                mime, mime)
            manifest[#manifest + 1] = [[<item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>]]
            spine[#spine + 1] = [[<itemref idref="cover"/>]]
            cover_meta = '<meta name="cover" content="cover-image"/>'

            local cover_xhtml = [[<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Cover</title>
<style>
html, body { margin:0; padding:0; width:100%; height:100%; overflow:hidden; }
img { display:block; width:100%; height:100%; object-fit:contain; }
</style>
</head>
<body><img src="../images/cover.]] .. mime .. [[" alt="Cover"/></body>
</html>]]
            writer:addFileFromMemory("OEBPS/text/cover.xhtml", cover_xhtml)
        end

        -- 3.2 写入章节
        for _, ch in ipairs(valid) do
            local f = io.open(ch.path, "rb")
            local html = f:read("*a")
            f:close()
            local xhtml = to_xhtml(html, ch.title)
            local filename = string.format("text/chapter-%03d.xhtml", ch.idx)
            writer:addFileFromMemory("OEBPS/" .. filename, xhtml)
            manifest[#manifest + 1] = string.format(
                '<item id="c%d" href="%s" media-type="application/xhtml+xml"/>', ch.idx, filename)
            spine[#spine + 1] = string.format('<itemref idref="c%d"/>', ch.idx)
        end

        -- 3.3 写入内嵌图片（全量打包）
        if lfs.attributes(images_dir, "mode") == "directory" then
            for entry in lfs.dir(images_dir) do
                if entry ~= "." and entry ~= ".." then
                    local f = io.open(images_dir .. "/" .. entry, "rb")
                    if f then
                        local data = f:read("*a")
                        f:close()
                        writer:addFileFromMemory("OEBPS/images/" .. entry, data)
                        local ext = entry:match("%.([^%.]+)$") or "png"
                        local mime_ext = ext == "jpg" and "jpeg" or ext
                        manifest[#manifest + 1] = string.format(
                            '<item id="i_%s" href="images/%s" media-type="image/%s"/>',
                            entry:gsub("%.", "_"), entry, mime_ext)
                    end
                end
            end
        end

        -- 3.4 写入结构文件
        writer:addFileFromMemory("OEBPS/content.opf", make_opf(book, manifest, spine, cover_meta))
        writer:addFileFromMemory("OEBPS/toc.ncx", make_ncx(book, valid))
        writer:addFileFromMemory("OEBPS/nav.xhtml", make_nav(book, valid))
        writer:addFileFromMemory("OEBPS/style.css", task.css or "body{line-height:1.7;margin:5%;}p{text-indent:2em;margin:.45em 0;}img{max-width:100%;}")
    end)
    writer:close()

    if not ok then
        os.remove(part)
        return { ok = false, error = tostring(err) }
    end

    if not os.rename(part, out) then
        os.remove(part)
        return { ok = false, error = "写入文件失败" }
    end

    return { ok = true, path = out, failed = failed }
end

return Worker
