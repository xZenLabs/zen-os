-- Embedded ComicInfo.xml metadata for cbz; MuPDF reports none for comic archives.
local M = {}

local MAX_XML_BYTES = 1024 * 1024

local function trim(value)
    return value:match("^%s*(.-)%s*$")
end

local function field(xml, tag)
    local value = xml:match("<" .. tag .. "%s*>(.-)</" .. tag .. ">")
    if not value then return nil end
    value = trim(require("util").htmlEntitiesToUtf8((value:gsub("<!%[CDATA%[(.-)%]%]>", "%1"))))
    return value ~= "" and value or nil
end

-- ComicInfo lists are comma separated; KOReader keeps one entry per line.
local function lines(value, more)
    local seen, out = {}, {}
    for entry in ((value or "") .. "," .. (more or "")):gmatch("[^,]+") do
        entry = trim(entry)
        if entry ~= "" and not seen[entry] then
            seen[entry] = true
            out[#out + 1] = entry
        end
    end
    return out[1] and table.concat(out, "\n") or nil
end

function M.parse(xml)
    local series = field(xml, "Series")
    local number = (field(xml, "Number") or field(xml, "Volume") or ""):match("^%d+%.?%d*$")
    return {
        title = field(xml, "Title"),
        authors = lines(field(xml, "Writer") or field(xml, "Penciller")),
        -- Document:getProps splits "Name #N" back into series and series_index.
        series = series and number and (series .. " #" .. number) or series,
        language = field(xml, "LanguageISO"),
        keywords = lines(field(xml, "Genre"), field(xml, "Tags")),
        description = field(xml, "Summary"),
    }
end

function M.read(file)
    local ok_archiver, Archiver = pcall(require, "ffi/archiver")
    if not ok_archiver then return nil end
    local reader = Archiver.Reader:new()
    if not reader:open(file) then return nil end
    local ok, xml = pcall(function()
        for entry in reader:iterate() do
            if entry.mode == "file" and entry.path:lower():match("[^/]*$") == "comicinfo.xml"
                    and tonumber(entry.size) <= MAX_XML_BYTES then
                return reader:extractToMemory(entry.index)
            end
        end
    end)
    pcall(reader.close, reader)
    return ok and xml and M.parse(xml) or nil
end

function M.install(plugin)
    require("common/on_require").whenLoaded("document/pdfdocument", function()
        local PdfDocument = require("document/pdfdocument")
        if PdfDocument._zen_comic_info then return end
        PdfDocument._zen_comic_info = true
        -- Subclasses with their own getDocumentProps (Rakuyomi) keep it.
        local orig_getDocumentProps = PdfDocument.getDocumentProps
        function PdfDocument:getDocumentProps()
            local props = orig_getDocumentProps(self)
            if type(self.file) == "string" and self.file:lower():sub(-4) == ".cbz" then
                for key, value in pairs(M.read(self.file) or {}) do props[key] = value end
            end
            return props
        end
    end)

    -- Rows cached before ComicInfo support hold no metadata; drop them once so they re-index.
    local meta = plugin and plugin.config and plugin.config._meta
    if not meta or meta.comic_info_cache_migrated then return end
    local ok_bim, manager = pcall(require, "bookinfomanager")
    if ok_bim and pcall(function()
        manager:openDbConnection()
        manager.db_conn:exec("DELETE FROM bookinfo WHERE filename LIKE '%.cbz' AND has_meta IS NULL")
    end) then
        meta.comic_info_cache_migrated = true
        plugin:saveConfig()
    end
end

return M
