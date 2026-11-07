local DocSettings = require("docsettings")
local BookNote = require("modules/reader/book_note")
local References = require("modules/reader/references")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local M = {}
M.kinds = { bookmarks = true, highlights = true, annotations = true, pins = true }

local function values(value)
    if type(value) == "table" then return value end
    local result = {}
    for entry in tostring(value or ""):gmatch("[^,;\n|\t]+") do
        entry = util.trim(entry)
        if entry ~= "" then result[#result + 1] = entry end
    end
    return result
end

local function equal(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
    for key in pairs(b) do if a[key] == nil then return false end end
    return true
end

function M.resolve(ui, record)
    for index, annotation in ipairs(ui.annotation.annotations) do
        local source = record.annotation
        if annotation == source or (annotation.datetime == source.datetime
                and equal(annotation.page, source.page) and equal(annotation.pos0, source.pos0)
                and equal(annotation.pos1, source.pos1)) then
            return index, annotation
        end
    end
end

function M.resolvePin(ui, record)
    for _i, pin in ipairs(References.pins(ui, References.storedLocations(ui.doc_settings.data))) do
        if equal(pin.location, record.location) then return pin end
    end
end

function M.normalize(file, annotations, props, pins)
    props = props or {}
    local records = {}
    local title = props.display_title or props.title or file:match("([^/]+)$")
    local author = type(props.authors) == "table" and table.concat(props.authors, ", ") or props.authors or ""
    for index, annotation in ipairs(annotations or {}) do
        records[#records + 1] = {
            file = file, annotation = annotation, order = index,
            kind = annotation.drawer and "highlight" or "bookmark",
            text = annotation.text or "", note = annotation.note or "",
            datetime = annotation.datetime or "", chapter = annotation.chapter or "",
            color = annotation.color or "gray", style = annotation.drawer or "",
            page_label = tostring(annotation.pageref or annotation.pageno
                or (type(annotation.page) == "number" and annotation.page) or ""),
            title = title, author = author,
            tags = values(annotation.tags or annotation.keywords or props.keywords),
        }
    end
    pins = pins or {}
    for index, pin in ipairs(pins) do
        records[#records + 1] = {
            file = file, kind = "pin", id = file .. "#pin" .. index, location = pin.location,
            -- Pins sort between the book note (0) and annotations (1..n).
            order = index / (#pins + 1), text = "", note = "", datetime = "",
            chapter = pin.chapter or "", page_label = pin.page_label or "", color = "", style = "",
            title = title, author = author, tags = values(props.keywords),
        }
    end
    local text, note_error, note_path, modified = BookNote.read(file)
    if text and text ~= "" and note_path and not note_error then
        records[#records + 1] = {
            file = file, kind = "note", order = 0, text = "", note = text,
            datetime = os.date("%Y-%m-%d %H:%M:%S", modified), chapter = "", page_label = "",
            color = "", style = "", tags = values(props.keywords), title = title, author = author,
        }
    end
    return records
end

function M.textMatches(text, rule)
    if not rule or not rule.text or rule.text == "" then return true end
    text = tostring(text or "")
    local function contains(needle)
        return util.stringSearch(text, needle, rule.case_sensitive == true) > 0
    end
    if rule.mode == "phrase" then return contains(rule.text) end
    local any = rule.mode == "any"
    for word in rule.text:gmatch("%S+") do
        local found = contains(word)
        if any and found then return true end
        if not any and not found then return false end
    end
    return not any
end

function M.matches(record, state, kind)
    if kind == "bookmarks" and record.kind ~= "bookmark" then return false end
    if kind == "highlights" and record.kind ~= "highlight" then return false end
    if kind == "pins" and record.kind ~= "pin" then return false end
    if state.query ~= "" and not M.textMatches(record.text .. "\n" .. record.note,
            { text = state.query, mode = "all" }) then return false end
    for facet, filter in pairs(state.filters) do
        local value = record[facet]
        local candidates = type(value) == "table" and value or { value }
        local included = next(filter.include) == nil
        for _i, candidate in ipairs(candidates) do
            if filter.exclude[candidate] then return false end
            if filter.include[candidate] then included = true end
        end
        if not included then return false end
    end
    for field, rules in pairs(state.text_filters) do
        if not M.textMatches(record[field], rules.include) then return false end
        if rules.exclude and rules.exclude.text ~= ""
                and not rules.exclude.text:match("^%s*$")
                and M.textMatches(record[field], rules.exclude) then return false end
    end
    return true
end

local Session = {}
Session.__index = Session

function M.new(ui)
    return setmetatable({ ui = ui, scope = ui and "current" or "all", query = "", filters = {}, text_filters = {},
        books = {}, pages = {}, sort = "page", reverse = false }, Session)
end

function Session:refreshCurrent()
    local ui = self.ui
    if not ui then return end
    local pins = {}
    for _i, pin in ipairs(References.pins(ui, References.storedLocations(ui.doc_settings.data))) do
        pins[#pins + 1] = { location = pin.location, chapter = ui.toc and ui.toc:getTocTitleByPage(pin.page),
            page_label = ui.bookmark and ui.bookmark:getBookmarkPageString(ui.rolling and pin.location or pin.page) }
    end
    local records = M.normalize(ui.document.file, ui.annotation and ui.annotation.annotations, ui.doc_props, pins)
    for _i, record in ipairs(records) do
        if record.annotation and ui.bookmark then
            record.page_label = ui.bookmark:getBookmarkPageString(record.annotation.page)
        end
    end
    self.books[ui.document.file] = records
end

local function load_book(file)
    local sidecar = DocSettings:findSidecarFile(file)
    local settings = sidecar and DocSettings.openSettingsFile(sidecar)
    local data = settings and settings.data or {}
    local props = {}
    for key, value in pairs(data.doc_props or {}) do props[key] = value end
    local custom_file = DocSettings:findCustomMetadataFile(file)
    if custom_file then
        local custom = DocSettings.openSettingsFile(custom_file).data
        for key, value in pairs(custom.custom_props or custom.doc_props or {}) do props[key] = value end
    end
    props.display_title = props.title
    local annotations = data.annotations
    if not annotations then
        annotations = {}
        local highlights = data.highlight or {}
        for index = #(data.bookmarks or {}), 1, -1 do
            local bookmark = data.bookmarks[index]
            local item = { page = bookmark.page, pos0 = bookmark.pos0, pos1 = bookmark.pos1,
                datetime = bookmark.datetime, chapter = bookmark.chapter,
                text = bookmark.notes, note = bookmark.text }
            if bookmark.highlighted then
                for _page, page_highlights in pairs(highlights) do
                    for _i, highlight in ipairs(page_highlights) do
                        if equal(highlight.pos0, bookmark.pos0) and equal(highlight.pos1, bookmark.pos1) then
                            item.drawer, item.color = highlight.drawer, highlight.color
                            item.text = item.text or highlight.text
                            break
                        end
                    end
                    if item.drawer then break end
                end
                item.drawer = item.drawer or "lighten"
            end
            annotations[#annotations + 1] = item
        end
    end
    local pins = {}
    for _i, location in ipairs(References.storedLocations(data)) do
        -- Reflowable pins are XPointers; their page needs the open document.
        local page = type(location) == "number" and location or type(location) == "table" and location[1] and location[1].page
        pins[#pins + 1] = { location = location, page_label = page and tostring(page) }
    end
    return M.normalize(file, annotations, props, pins)
end

function Session:refreshBook(file)
    local ok, records = pcall(load_book, file)
    if ok then self.books[file] = records end
end

function Session:loadAll(on_update)
    if self.loaded or self.loading then return end
    local history = require("readhistory")
    history:reload(false)
    local realpath = require("ffi/util").realpath
    local current_file = self.ui and self.ui.document.file
    local entries, seen = history.hist or {}, {}
    if current_file then seen[current_file], seen[realpath(current_file) or current_file] = true, true end
    self.loading = true
    local offset = 1
    local UIManager = require("ui/uimanager")
    local time = require("ui/time")
    local last_update -- full viewer rebuilds are throttled to one per second while loading
    self.worker = function()
        if self.closed then return end
        -- Paths resolve inside each batch so opening "All books" never stalls on the whole history.
        local loaded = 0
        while loaded < 10 and offset <= #entries do
            local entry = entries[offset]
            offset = offset + 1
            local file = entry.file and (realpath(entry.file) or entry.file)
            if file and not seen[file] and lfs.attributes(file, "mode") == "file" then
                seen[file] = true
                loaded = loaded + 1
                local ok, records = pcall(load_book, file)
                if ok then self.books[file] = records end
            end
        end
        self.loading = offset <= #entries
        self.loaded = not self.loading
        local now = time.now()
        if self.loaded or not last_update or now - last_update >= time.s(1) then
            last_update = now
            on_update()
        end
        if self.loading and not self.closed then UIManager:scheduleIn(0.01, self.worker) end
    end
    UIManager:nextTick(self.worker)
end

function Session:allRecords()
    local records = {}
    for file, book in pairs(self.books) do
        if self.scope == "all" or file == self.ui.document.file then
            for _i, record in ipairs(book) do records[#records + 1] = record end
        end
    end
    return records
end

function Session:items(kind)
    local items = {}
    for _i, record in ipairs(self:allRecords()) do
        if M.matches(record, self, kind) then items[#items + 1] = record end
    end
    table.sort(items, function(a, b)
        local before
        if self.sort == "date" and a.datetime ~= b.datetime then
            before = a.datetime < b.datetime
        elseif a.file ~= b.file then
            before = a.title == b.title and a.file < b.file or a.title ~= b.title and a.title < b.title
        else
            before = a.order < b.order
        end
        if self.reverse then return not before and a ~= b end
        return before
    end)
    return items
end

function Session:close()
    self.closed = true
    if self.worker then require("ui/uimanager"):unschedule(self.worker) end
    self.books = {}
    self.row_heights = nil
end

return M
