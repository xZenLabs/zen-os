-- OPF editing is adapted from Rebind (MIT); see LICENSES.md.

local Archiver = require("ffi/archiver")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local XML = require("modules/filebrowser/metadata/vendor/slaxdom")

local M = {}
local NATIVE_WINDOWS = ffi.os == "Windows"
local HAS_CHMOD = not NATIVE_WINDOWS

if HAS_CHMOD then
    pcall(ffi.cdef, "int chmod(const char *path, mode_t mode);")
else
    pcall(ffi.cdef, [[
        int MultiByteToWideChar(unsigned int code_page, unsigned long flags,
            const char *source, int source_length, wchar_t *destination,
            int destination_length);
        int MoveFileExW(const wchar_t *existing, const wchar_t *replacement,
            unsigned long flags);
    ]])
end

local DC_NS = "http://purl.org/dc/elements/1.1/"
local OPF_NS = "http://www.idpf.org/2007/opf"
local MIMETYPE = "application/epub+zip"
local BACKUP_SUFFIX = ".zen-metadata.bak"
local TRANSACTION_VERSION = 1
local SPACE_MARGIN = 1024 * 1024
local SIDECAR_NAME = "/custom_metadata.lua"
local SIDECAR_NEW_SUFFIX = ".zen-metadata.new"
local SIDECAR_OLD_SUFFIX = ".zen-metadata.old"

local TEXT_FIELDS = {
    title = "title",
    language = "language",
    publisher = "publisher",
    description = "description",
}

local function paths(path)
    local backup = path .. BACKUP_SUFFIX
    return {
        backup = backup,
        companion = backup .. ".json",
        stage = path .. ".zen-metadata.tmp",
        restore_stage = path .. ".zen-metadata.restore",
        backup_new = backup .. ".new",
        backup_old = backup .. ".old",
        companion_new = backup .. ".json.new",
        companion_old = backup .. ".json.old",
        marker = path .. ".zen-metadata.txn",
        marker_new = path .. ".zen-metadata.txn.new",
        marker_old = path .. ".zen-metadata.txn.old",
        live_old = path .. ".zen-metadata.live-old",
        scratch = path .. ".zen-metadata.entry",
    }
end

local function trim(value)
    if type(value) ~= "string" then return value end
    return value:match("^%s*(.-)%s*$")
end

local function exists(path)
    return lfs.symlinkattributes(path) ~= nil
end

local function regular_file(path)
    local attr = lfs.symlinkattributes(path)
    return attr and attr.mode == "file", attr
end

local function permission_mode(permissions)
    if type(permissions) ~= "string" or #permissions < 9 then return nil end
    local mode = 0
    local ordinary = {
        [1] = { "r", 256 }, [2] = { "w", 128 },
        [4] = { "r", 32 }, [5] = { "w", 16 },
        [7] = { "r", 4 }, [8] = { "w", 2 },
    }
    for position, entry in pairs(ordinary) do
        if permissions:sub(position, position) == entry[1] then mode = mode + entry[2] end
    end
    local owner_exec = permissions:sub(3, 3)
    local group_exec = permissions:sub(6, 6)
    local other_exec = permissions:sub(9, 9)
    if owner_exec == "x" or owner_exec == "s" then mode = mode + 64 end
    if group_exec == "x" or group_exec == "s" then mode = mode + 8 end
    if other_exec == "x" or other_exec == "t" then mode = mode + 1 end
    if owner_exec == "s" or owner_exec == "S" then mode = mode + 2048 end
    if group_exec == "s" or group_exec == "S" then mode = mode + 1024 end
    if other_exec == "t" or other_exec == "T" then mode = mode + 512 end
    return mode
end

local function preserve_permissions(source, destination)
    if ffi.os == "Windows" then return true end
    local mode = permission_mode(lfs.attributes(source, "permissions"))
    if not mode or ffi.C.chmod(destination, mode) == 0 then return true end
    return nil, "could not preserve EPUB file permissions"
end

local function ensure_writable(path)
    local permissions = lfs.attributes(path, "permissions")
    if type(permissions) == "string"
            and permissions:sub(2, 2) ~= "w"
            and permissions:sub(5, 5) ~= "w"
            and permissions:sub(8, 8) ~= "w" then
        return nil, "EPUB path is not writable"
    end
    local file, err = io.open(path, "r+b")
    if not file then return nil, err or "EPUB path is not writable" end
    file:close()
    return true
end

local function remove_file(path)
    if not exists(path) then return true end
    local ok, err = os.remove(path)
    return ok ~= nil, err
end

local function move_file(source, destination)
    local ok, err = os.rename(source, destination)
    if not ok then return nil, err end
    return true
end

local function atomic_replace_file(source, destination)
    if ffi.os ~= "Windows" then return move_file(source, destination) end
    if not NATIVE_WINDOWS then
        local ok, err = remove_file(destination)
        if not ok then return nil, err end
        return move_file(source, destination)
    end
    local function wide(value)
        local size = ffi.C.MultiByteToWideChar(65001, 0, value, -1, nil, 0)
        if size <= 0 then return end
        local buffer = ffi.new("wchar_t[?]", size)
        if ffi.C.MultiByteToWideChar(65001, 0, value, -1, buffer, size) <= 0 then
            return
        end
        return buffer
    end
    local source_w, destination_w = wide(source), wide(destination)
    if not source_w or not destination_w then return nil, "invalid EPUB path" end
    local called, replaced = pcall(function()
        return ffi.C.MoveFileExW(source_w, destination_w, 0x1 + 0x8)
    end)
    if not called or replaced == 0 then return nil, "atomic EPUB replacement failed" end
    return true
end

local function sync_directory(path)
    local called, synced, err = pcall(ffiutil.fsyncDirectory, ffiutil.dirname(path))
    if not called then return nil, synced end
    if synced ~= true then return nil, err or "could not sync metadata directory" end
    return true
end

local function make_path_durable(path)
    local missing = {}
    local current = path
    while current and current ~= "" and not exists(current) do
        missing[#missing + 1] = current
        local parent = ffiutil.dirname(current)
        if parent == current then break end
        current = parent
    end
    local ok, err = require("util").makePath(path)
    if not ok then return nil, err end
    for index = #missing, 1, -1 do
        ok, err = sync_directory(missing[index])
        if not ok then return nil, err end
    end
    return true
end

local function sync_file(path)
    local file, err = io.open(path, "r+b")
    if not file then return nil, err end
    local called, synced, sync_err = pcall(ffiutil.fsyncOpenedFile, file, true)
    local closed, close_err = file:close()
    if not called then return nil, synced end
    if synced ~= true or closed == nil then
        return nil, sync_err or close_err or "could not sync temporary EPUB"
    end
    return true
end

local function write_bytes(path, content)
    local file, err = io.open(path, "wb")
    if not file then return nil, err end
    local ok, write_err = file:write(content)
    if not ok then
        file:close()
        return nil, write_err
    end
    local flushed, flush_err = file:flush()
    if flushed == nil then
        file:close()
        remove_file(path)
        return nil, flush_err
    end
    local called, synced, sync_err = pcall(ffiutil.fsyncOpenedFile, file, true)
    local closed, close_err = file:close()
    if not called or synced ~= true or closed == nil then
        remove_file(path)
        return nil, called and (sync_err or close_err) or synced
    end
    local check, check_err = io.open(path, "rb")
    if not check then
        remove_file(path)
        return nil, check_err
    end
    local saved, read_err = check:read("*a")
    check:close()
    if saved ~= content then
        remove_file(path)
        return nil, read_err or "short metadata state write"
    end
    return true
end

local function read_bytes(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local content, read_err = file:read("*a")
    file:close()
    if content == nil then return nil, read_err end
    return content
end

local function copy_file(source_path, destination_path)
    local source, err = io.open(source_path, "rb")
    if not source then return nil, err end
    local destination, destination_err = io.open(destination_path, "wb")
    if not destination then
        source:close()
        return nil, destination_err
    end

    while true do
        local chunk = source:read(64 * 1024)
        if not chunk then break end
        local ok, write_err = destination:write(chunk)
        if not ok then
            source:close()
            destination:close()
            return nil, write_err
        end
    end
    source:close()
    local permissions_ok, permissions_err = preserve_permissions(
        source_path, destination_path)
    if not permissions_ok then
        destination:close()
        remove_file(destination_path)
        return nil, permissions_err
    end
    local flushed, flush_err = destination:flush()
    if flushed == nil then
        destination:close()
        remove_file(destination_path)
        return nil, flush_err
    end
    local called, synced, sync_err = pcall(ffiutil.fsyncOpenedFile, destination, true)
    local closed, close_err = destination:close()
    if not called or synced ~= true or closed == nil then
        remove_file(destination_path)
        return nil, called and (sync_err or close_err) or synced
    end

    local source_size = lfs.attributes(source_path, "size")
    local destination_size = lfs.attributes(destination_path, "size")
    if source_size == nil or destination_size ~= source_size then
        return nil, "short copy"
    end
    return true
end

local function files_equal(left_path, right_path)
    local left_size = lfs.attributes(left_path, "size")
    local right_size = lfs.attributes(right_path, "size")
    if left_size == nil or right_size == nil then return nil, "file is missing" end
    if left_size ~= right_size then return false end
    local left, err = io.open(left_path, "rb")
    if not left then return nil, err end
    local right, right_err = io.open(right_path, "rb")
    if not right then
        left:close()
        return nil, right_err
    end
    while true do
        local left_chunk, left_err = left:read(64 * 1024)
        local right_chunk, read_err = right:read(64 * 1024)
        if left_err or read_err then
            left:close()
            right:close()
            return nil, left_err or read_err
        end
        if left_chunk ~= right_chunk then
            left:close()
            right:close()
            return false
        end
        if not left_chunk then break end
    end
    left:close()
    right:close()
    return true
end

local function sync_directory_contents(path)
    local called, synced, err = pcall(ffiutil.fsyncDirectory, path)
    if not called then return nil, synced end
    if synced ~= true then return nil, err or "could not sync metadata directory" end
    return true
end

local function remove_tree(path)
    local attr = lfs.symlinkattributes(path)
    if not attr then return true end
    if attr.mode ~= "directory" then return remove_file(path) end
    local called, iterator, state = pcall(lfs.dir, path)
    if not called then return nil, iterator end
    for entry in iterator, state do
        if entry ~= "." and entry ~= ".." then
            local ok, err = remove_tree(path .. "/" .. entry)
            if not ok then return nil, err end
        end
    end
    local ok, err = lfs.rmdir(path)
    return ok == true, err
end

local function copy_tree(source, destination, skip)
    local attr = lfs.symlinkattributes(source)
    if not attr or attr.mode ~= "directory" then
        return nil, "hash sidecar directory is missing"
    end
    local made, make_err = lfs.mkdir(destination)
    if not made then return nil, make_err end
    local called, iterator, state = pcall(lfs.dir, source)
    if not called then return nil, iterator end
    for entry in iterator, state do
        if entry ~= "." and entry ~= ".." then
            local source_entry = source .. "/" .. entry
            if not skip or not skip[source_entry] then
                local destination_entry = destination .. "/" .. entry
                local entry_attr = lfs.symlinkattributes(source_entry)
                local ok, err
                if entry_attr and entry_attr.mode == "directory" then
                    ok, err = copy_tree(source_entry, destination_entry, skip)
                elseif entry_attr and entry_attr.mode == "file" then
                    ok, err = copy_file(source_entry, destination_entry)
                else
                    ok, err = nil, "unsupported entry in hash sidecar directory"
                end
                if not ok then return nil, err end
            end
        end
    end
    return sync_directory_contents(destination)
end

local function encode_json(value)
    local ok, encoded = pcall(json.encode, value)
    if not ok or type(encoded) ~= "string" then
        return nil, "could not serialize metadata backup state"
    end
    return encoded
end

local function read_json(path)
    local content, err = read_bytes(path)
    if not content then return nil, err end
    local ok, decoded = pcall(json.decode, content)
    if not ok or type(decoded) ~= "table" then
        return nil, "malformed metadata backup state"
    end
    return decoded
end

local function write_json(path, value)
    local encoded, err = encode_json(value)
    if not encoded then return nil, err end
    local ok
    ok, err = write_bytes(path, encoded)
    if not ok then return nil, err end
    local verified
    verified, err = read_json(path)
    if not verified then
        remove_file(path)
        return nil, err
    end
    return true
end

local function ensure_free_space(path, required)
    local ok, free = pcall(function()
        return select(2, ffiutil.df(ffiutil.dirname(path)))
    end)
    if ok and type(free) == "number" and free < required + SPACE_MARGIN then
        return nil, "not enough free space to update this EPUB safely"
    end
    return true
end

local function is_element(node)
    return type(node) == "table" and node.type == "element"
end

local function child_elements(element)
    local children = {}
    for _i, child in ipairs(element.kids or {}) do
        if is_element(child) then children[#children + 1] = child end
    end
    return children
end

local function attr_get(element, name)
    return element.attr and element.attr[name]
end

local function attr_set(element, name, value)
    element.attr = element.attr or {}
    element.attr[name] = value
    for _i, attribute in ipairs(element.attr) do
        local full_name = attribute.nsPrefix
            and attribute.nsPrefix .. ":" .. attribute.name or attribute.name
        if full_name == name then
            attribute.value = value
            return
        end
    end
    element.attr[#element.attr + 1] = {
        type = "attribute",
        name = name,
        value = value,
    }
end

local function node_text(element)
    local parts = {}
    for _i, child in ipairs(element.kids or {}) do
        if child.type == "text" then parts[#parts + 1] = child.value end
    end
    return table.concat(parts)
end

local function set_node_text(element, value)
    element.kids = { { type = "text", name = "#text", value = value } }
end

local function new_element(name, prefix, attrs, text, namespace)
    local element = {
        type = "element",
        name = name,
        nsPrefix = prefix,
        nsURI = namespace,
        kids = {},
        attr = {},
    }
    for _i, attribute in ipairs(attrs or {}) do
        attr_set(element, attribute[1], attribute[2])
    end
    if text ~= nil then set_node_text(element, text) end
    return element
end

local function new_meta(metadata, attrs, text)
    return new_element("meta", metadata.nsPrefix, attrs, text,
        metadata.nsURI or OPF_NS)
end

local function append_child(parent, child)
    parent.kids[#parent.kids + 1] = {
        type = "text",
        name = "#text",
        value = "\n    ",
    }
    parent.kids[#parent.kids + 1] = child
end

local function is_dc(element, local_name)
    return is_element(element) and element.name == local_name
        and (element.nsURI == DC_NS or element.nsPrefix == "dc")
end

local function is_meta(element)
    return is_element(element) and element.name == "meta"
end

local function find_metadata(package)
    for _i, element in ipairs(child_elements(package)) do
        if element.name == "metadata" then return element end
    end
end

local function ensure_dc_prefix(metadata)
    for _i, element in ipairs(child_elements(metadata)) do
        if element.nsURI == DC_NS and element.nsPrefix then
            return element.nsPrefix
        end
    end
    for _i, attribute in ipairs(metadata.attr or {}) do
        if attribute.value == DC_NS then
            if attribute.nsPrefix == "xmlns" then return attribute.name end
            local prefix = attribute.name and attribute.name:match("^xmlns:(.+)$")
            if prefix then return prefix end
        end
    end
    attr_set(metadata, "xmlns:dc", DC_NS)
    return "dc"
end

local function first_dc(metadata, local_name)
    for _i, element in ipairs(child_elements(metadata)) do
        if is_dc(element, local_name) then return element end
    end
end

local function dc_elements(metadata, local_name)
    local found = {}
    for _i, element in ipairs(child_elements(metadata)) do
        if is_dc(element, local_name) then found[#found + 1] = element end
    end
    return found
end

local function remove_elements(metadata, removed)
    local kept = {}
    local removed_ids = {}
    for _i, child in ipairs(metadata.kids or {}) do
        if removed[child] then
            local id = attr_get(child, "id")
            if id and id ~= "" then removed_ids["#" .. id] = true end
        else
            kept[#kept + 1] = child
        end
    end
    if next(removed_ids) then
        local without_refinements = {}
        for _i, child in ipairs(kept) do
            local remove = is_meta(child) and removed_ids[attr_get(child, "refines")] == true
            if not remove then without_refinements[#without_refinements + 1] = child end
        end
        kept = without_refinements
    end
    metadata.kids = kept
end

local function remove_dc(metadata, local_name)
    local removed = {}
    for _i, element in ipairs(dc_elements(metadata, local_name)) do
        removed[element] = true
    end
    remove_elements(metadata, removed)
end

local function set_dc_text(metadata, local_name, prefix, value)
    local element = first_dc(metadata, local_name)
    if element then
        set_node_text(element, value)
    else
        append_child(metadata, new_element(local_name, prefix, nil, value, DC_NS))
    end
end

local function set_dc_list(metadata, local_name, prefix, values)
    local existing = dc_elements(metadata, local_name)
    for index, value in ipairs(values) do
        if existing[index] then
            set_node_text(existing[index], value)
        else
            append_child(metadata, new_element(local_name, prefix, nil, value, DC_NS))
        end
    end
    local removed = {}
    for index = #values + 1, #existing do removed[existing[index]] = true end
    if next(removed) then remove_elements(metadata, removed) end
end

local function author_creators(metadata)
    local refined_roles = {}
    for _i, element in ipairs(child_elements(metadata)) do
        if is_meta(element) and attr_get(element, "property") == "role" then
            local refines = attr_get(element, "refines")
            local role = trim(node_text(element)):lower()
            if refines and role ~= "" then
                local state = refined_roles[refines] or {}
                state.author = state.author or role == "aut"
                refined_roles[refines] = state
            end
        end
    end

    local authors = {}
    for _i, element in ipairs(dc_elements(metadata, "creator")) do
        local role = attr_get(element, "opf:role") or attr_get(element, "role")
        local is_author
        if role and trim(role) ~= "" then
            is_author = trim(role):lower() == "aut"
        else
            local id = attr_get(element, "id")
            local refined = id and refined_roles["#" .. id]
            is_author = refined == nil or refined.author == true
        end
        if is_author then authors[#authors + 1] = element end
    end
    return authors
end

local function set_authors(metadata, prefix, values)
    local existing = author_creators(metadata)
    for index, value in ipairs(values) do
        if existing[index] then
            set_node_text(existing[index], value)
        else
            append_child(metadata, new_element("creator", prefix, nil, value, DC_NS))
        end
    end
    local removed = {}
    for index = #values + 1, #existing do removed[existing[index]] = true end
    if next(removed) then remove_elements(metadata, removed) end
end

local function remove_meta(metadata, predicate)
    local removed = {}
    for _i, element in ipairs(child_elements(metadata)) do
        if is_meta(element) and predicate(element) then removed[element] = true end
    end
    if next(removed) then remove_elements(metadata, removed) end
end

local function find_meta(metadata, predicate)
    for _i, element in ipairs(child_elements(metadata)) do
        if is_meta(element) and predicate(element) then return element end
    end
end

local function format_index(value)
    if value == nil or value == "" then return nil end
    local number = tonumber(value)
    if number and number == math.floor(number) then return tostring(math.floor(number)) end
    return number and string.format("%.15g", number) or tostring(value)
end

local function set_calibre_series(metadata, name, index)
    remove_meta(metadata, function(element)
        local meta_name = attr_get(element, "name")
        return meta_name == "calibre:series" or meta_name == "calibre:series_index"
    end)
    append_child(metadata, new_meta(metadata, {
        { "name", "calibre:series" },
        { "content", name },
    }))
    local rendered_index = format_index(index)
    if rendered_index then
        append_child(metadata, new_meta(metadata, {
            { "name", "calibre:series_index" },
            { "content", rendered_index },
        }))
    end
end

local function series_collections(metadata)
    local collections = {}
    local by_refines = {}
    for _i, element in ipairs(child_elements(metadata)) do
        if is_meta(element) and attr_get(element, "property") == "belongs-to-collection" then
            local item = { element = element, id = attr_get(element, "id") }
            collections[#collections + 1] = item
            if item.id and item.id ~= "" then by_refines["#" .. item.id] = item end
        end
    end
    for _i, element in ipairs(child_elements(metadata)) do
        if is_meta(element) then
            local item = by_refines[attr_get(element, "refines")]
            if item and attr_get(element, "property") == "collection-type" then
                item.has_type = true
                item.is_series = trim(node_text(element)):lower() == "series"
                item.type_element = element
            elseif item and attr_get(element, "property") == "group-position" then
                item.position_element = element
            end
        end
    end
    return collections
end

local function unique_series_id(metadata)
    local used = {}
    for _i, element in ipairs(child_elements(metadata)) do
        local id = attr_get(element, "id")
        if id then used[id] = true end
    end
    local base = "zen-metadata-series"
    local candidate = base
    local suffix = 2
    while used[candidate] do
        candidate = base .. "-" .. suffix
        suffix = suffix + 1
    end
    return candidate
end

local function set_epub3_series(metadata, name, index)
    local selected
    for _i, collection in ipairs(series_collections(metadata)) do
        if collection.is_series then
            selected = collection
            break
        end
    end
    if not selected then
        local id = unique_series_id(metadata)
        local collection = new_meta(metadata, {
            { "property", "belongs-to-collection" },
            { "id", id },
        }, name)
        append_child(metadata, collection)
        selected = { element = collection, id = id, is_series = true }
    else
        if not selected.id or selected.id == "" then
            selected.id = unique_series_id(metadata)
            attr_set(selected.element, "id", selected.id)
        end
        set_node_text(selected.element, name)
    end

    local refines = "#" .. selected.id
    if selected.type_element then
        set_node_text(selected.type_element, "series")
    else
        append_child(metadata, new_meta(metadata, {
            { "refines", refines },
            { "property", "collection-type" },
        }, "series"))
    end

    local rendered_index = format_index(index)
    if rendered_index then
        if selected.position_element then
            set_node_text(selected.position_element, rendered_index)
        else
            append_child(metadata, new_meta(metadata, {
                { "refines", refines },
                { "property", "group-position" },
            }, rendered_index))
        end
    else
        remove_meta(metadata, function(element)
            return attr_get(element, "refines") == refines
                and attr_get(element, "property") == "group-position"
        end)
    end
end

local function clear_series(metadata)
    remove_meta(metadata, function(element)
        local name = attr_get(element, "name")
        return name == "calibre:series" or name == "calibre:series_index"
    end)
    local removed = {}
    local fallback
    for _i, collection in ipairs(series_collections(metadata)) do
        if collection.is_series then
            removed[collection.element] = true
        elseif not collection.has_type and not fallback then
            fallback = collection
        end
    end
    if fallback then removed[fallback.element] = true end
    if next(removed) then remove_elements(metadata, removed) end
end

local function read_series(metadata)
    local calibre = find_meta(metadata, function(element)
        return attr_get(element, "name") == "calibre:series"
    end)
    if calibre then
        local index = find_meta(metadata, function(element)
            return attr_get(element, "name") == "calibre:series_index"
        end)
        return attr_get(calibre, "content"), index and attr_get(index, "content")
    end

    local fallback
    for _i, collection in ipairs(series_collections(metadata)) do
        if not collection.has_type then fallback = fallback or collection end
        if collection.is_series then
            return node_text(collection.element),
                collection.position_element and node_text(collection.position_element)
        end
    end
    if fallback then
        return node_text(fallback.element),
            fallback.position_element and node_text(fallback.position_element)
    end
end

local function isbn_digits(value)
    if type(value) ~= "string" then return nil end
    return value:upper():gsub("[^0-9X]", "")
end

local function valid_isbn10(value)
    if #value ~= 10 or not value:match("^%d%d%d%d%d%d%d%d%d[%dX]$") then return false end
    local sum = 0
    for index = 1, 10 do
        local char = value:sub(index, index)
        local digit = char == "X" and 10 or tonumber(char)
        sum = sum + digit * (11 - index)
    end
    return sum % 11 == 0
end

local function valid_isbn13(value)
    if #value ~= 13 or not value:match("^%d+$") then return false end
    local sum = 0
    for index = 1, 13 do
        local weight = index % 2 == 0 and 3 or 1
        sum = sum + tonumber(value:sub(index, index)) * weight
    end
    return sum % 10 == 0
end

local function normalize_isbn(value)
    local digits = isbn_digits(value)
    if not digits then return nil end
    if valid_isbn13(digits) or valid_isbn10(digits) then return digits end
end

local function isbn_identifier(element)
    if not is_dc(element, "identifier") then return false end
    if normalize_isbn(node_text(element)) then return true end
    local scheme = attr_get(element, "scheme")
    if type(scheme) == "string" and scheme:lower() == "isbn" then return true end
    return node_text(element):lower():find("isbn", 1, true) ~= nil
end

local function read_isbn(metadata)
    local isbn10
    for _i, element in ipairs(child_elements(metadata)) do
        if is_dc(element, "identifier") then
            local value = normalize_isbn(node_text(element))
            if value and #value == 13 then return value end
            if value then isbn10 = isbn10 or value end
        end
    end
    return isbn10
end

local function set_isbn(package, metadata, prefix, value)
    local identifiers = {}
    for _i, element in ipairs(child_elements(metadata)) do
        if isbn_identifier(element) then identifiers[#identifiers + 1] = element end
    end
    if value ~= "" then
        if #identifiers == 0 then
            append_child(metadata,
                new_element("identifier", prefix, nil, "urn:isbn:" .. value, DC_NS))
        else
            for _i, element in ipairs(identifiers) do set_node_text(element, value) end
        end
        return true
    end

    local unique_id = attr_get(package, "unique-identifier")
    for _i, element in ipairs(identifiers) do
        if unique_id and attr_get(element, "id") == unique_id then
            return nil, "the ISBN is this EPUB's required unique identifier and cannot be removed"
        end
    end
    local removed = {}
    for _i, element in ipairs(identifiers) do removed[element] = true end
    if next(removed) then remove_elements(metadata, removed) end
    return true
end

local function parse_opf(xml)
    local ok, document = pcall(XML.dom, XML, xml)
    if not ok or not document or not document.root or document.root.name ~= "package" then
        return nil, nil, "could not parse the EPUB package document"
    end
    local metadata = find_metadata(document.root)
    if not metadata then return nil, nil, "the EPUB package has no metadata element" end
    return document, metadata
end

local function metadata_from_dom(metadata)
    local authors = {}
    local genres = {}
    local author_elements = {}
    for _i, element in ipairs(author_creators(metadata)) do author_elements[element] = true end
    for _i, element in ipairs(child_elements(metadata)) do
        if author_elements[element] then
            authors[#authors + 1] = node_text(element)
        elseif is_dc(element, "subject") then
            genres[#genres + 1] = node_text(element)
        end
    end
    local series_name, series_index = read_series(metadata)
    return {
        title = first_dc(metadata, "title") and node_text(first_dc(metadata, "title")) or nil,
        authors = authors,
        series_name = series_name,
        series_index = series_index,
        genres = genres,
        language = first_dc(metadata, "language") and node_text(first_dc(metadata, "language")) or nil,
        publisher = first_dc(metadata, "publisher") and node_text(first_dc(metadata, "publisher")) or nil,
        description = first_dc(metadata, "description") and node_text(first_dc(metadata, "description")) or nil,
        isbn = read_isbn(metadata),
    }
end

local function normalize_list(value, field)
    if type(value) ~= "table" then return nil, field .. " must be a list" end
    local normalized = {}
    for index, item in ipairs(value) do
        if type(item) ~= "string" then
            return nil, field .. " item " .. index .. " must be text"
        end
        item = trim(item)
        if item ~= "" then normalized[#normalized + 1] = item end
    end
    return normalized
end

local function normalize_draft(draft)
    if type(draft) ~= "table" then return nil, nil, "metadata draft must be a table" end
    local values, present = {}, {}
    for key in pairs(TEXT_FIELDS) do
        local value = rawget(draft, key)
        if value ~= nil then
            if type(value) ~= "string" then return nil, nil, key .. " must be text" end
            values[key] = trim(value)
            present[key] = true
        end
    end
    for _i, key in ipairs({ "authors", "genres" }) do
        if rawget(draft, key) ~= nil then
            local list, err = normalize_list(draft[key], key)
            if not list then return nil, nil, err end
            values[key] = list
            present[key] = true
        end
    end
    if rawget(draft, "series_name") ~= nil then
        if type(draft.series_name) ~= "string" then
            return nil, nil, "series_name must be text"
        end
        values.series_name = trim(draft.series_name)
        present.series_name = true
    end
    if rawget(draft, "series_index") ~= nil then
        local rendered = trim(tostring(draft.series_index))
        if rendered ~= "" then
            local number = tonumber(rendered)
            if not number or number ~= number or number == math.huge or number == -math.huge then
                return nil, nil, "series_index must be a finite number"
            end
            values.series_index = format_index(number)
        end
        present.series_index = true
    end
    if rawget(draft, "isbn") ~= nil then
        if type(draft.isbn) ~= "string" then return nil, nil, "isbn must be text" end
        local raw = trim(draft.isbn)
        if raw == "" then
            values.isbn = ""
        else
            values.isbn = normalize_isbn(raw)
            if not values.isbn then return nil, nil, "isbn must be a valid ISBN-10 or ISBN-13" end
        end
        present.isbn = true
    end
    return values, present
end

local function edit_opf(opf_xml, values, present)
    local document, metadata, err = parse_opf(opf_xml)
    if not document then return nil, err end
    local prefix = ensure_dc_prefix(metadata)

    for key, local_name in pairs(TEXT_FIELDS) do
        if present[key] then
            if values[key] == "" then
                remove_dc(metadata, local_name)
            else
                set_dc_text(metadata, local_name, prefix, values[key])
            end
        end
    end
    if present.authors then set_authors(metadata, prefix, values.authors) end
    if present.genres then set_dc_list(metadata, "subject", prefix, values.genres) end

    if present.series_name or present.series_index then
        local current_name, current_index = read_series(metadata)
        local name = present.series_name and values.series_name or current_name
        local index = present.series_index and values.series_index or current_index
        if not name or name == "" then
            clear_series(metadata)
        else
            set_calibre_series(metadata, name, index)
            local version = tonumber((attr_get(document.root, "version") or ""):match("^%d+"))
            if version and version >= 3 then
                set_epub3_series(metadata, name, index)
            end
        end
    end
    if present.isbn then
        local ok
        ok, err = set_isbn(document.root, metadata, prefix, values.isbn)
        if not ok then return nil, err end
    end

    local ok, serialized = pcall(XML.xml, XML, document)
    if not ok or type(serialized) ~= "string" then
        return nil, "could not serialize the edited EPUB package"
    end
    return serialized
end

local function parse_container(xml)
    local ok, document = pcall(XML.dom, XML, xml)
    if not ok or not document or not document.root or document.root.name ~= "container" then
        return nil, "could not parse META-INF/container.xml"
    end
    local rootfiles = {}
    local function visit(node)
        for _i, child in ipairs(child_elements(node)) do
            if child.name == "rootfile" and attr_get(child, "full-path") then
                rootfiles[#rootfiles + 1] = attr_get(child, "full-path")
            end
            visit(child)
        end
    end
    visit(document.root)
    if #rootfiles ~= 1 then
        return nil, "EPUBs with anything other than one package document are not supported"
    end
    local path = rootfiles[1]
    if path == "" or path:sub(1, 1) == "/" or path:find("\\", 1, true)
            or path:find("%z") then
        return nil, "the EPUB package path is unsafe"
    end
    for segment in path:gmatch("[^/]+") do
        if segment == "." or segment == ".." then
            return nil, "the EPUB package path is unsafe"
        end
    end
    return path
end

local function validate_zip_header(path, require_mimetype)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local header = file:read(30)
    if not header or #header ~= 30 or header:sub(1, 4) ~= "PK\003\004" then
        file:close()
        return nil, "the EPUB does not start with a ZIP file entry"
    end
    -- Only repacked output needs a first, uncompressed mimetype entry.
    if not require_mimetype then
        file:close()
        return true
    end
    local function uint16(offset)
        local low, high = header:byte(offset, offset + 1)
        return low + high * 256
    end
    local method = uint16(9)
    local name_length = uint16(27)
    local name = file:read(name_length)
    file:close()
    if name ~= "mimetype" then return nil, "the EPUB mimetype entry is not first" end
    if method ~= 0 then return nil, "the EPUB mimetype entry is compressed" end
    return true
end

local function open_reader(path)
    local reader = Archiver.Reader:new()
    if not reader:open(path) then return nil, reader.err or "could not open EPUB archive" end
    return reader
end

local function archive_path_is_safe(path)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/"
            or path:match("^%a:/") or path:find("\\", 1, true)
            or path:find("%z") then
        return false
    end
    local checked = path:sub(-1) == "/" and path:sub(1, -2) or path
    if checked == "" or checked:find("//", 1, true) then return false end
    for segment in checked:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return false end
    end
    return true
end

local function scan_archive(path, capture, verify_all, scratch_path)
    local reader, err = open_reader(path)
    if not reader then return nil, err end
    if verify_all then
        scratch_path = scratch_path or path .. ".zen-metadata.entry"
        local removed
        removed, err = remove_file(scratch_path)
        if not removed then
            reader:close()
            return nil, err
        end
    end
    local function abort(message)
        reader:close()
        if scratch_path then remove_file(scratch_path) end
        return nil, message
    end
    local result = { paths = {}, contents = {} }
    local seen = {}
    for entry in reader:iterate() do
        if not archive_path_is_safe(entry.path) then
            return abort("the EPUB contains an unsafe archive entry path")
        end
        if seen[entry.path] then
            return abort("the EPUB contains duplicate archive entries")
        end
        seen[entry.path] = true
        if entry.mode == "file" then
            result.paths[#result.paths + 1] = entry.path
            if capture[entry.path] then
                local content = reader:extractToMemory(entry.path)
                if content == nil then
                    err = reader.err or ("could not read EPUB entry " .. entry.path)
                    return abort(err)
                end
                result.contents[entry.path] = content
            elseif verify_all then
                local extracted, extract_err = reader:extractToPath(
                    entry.path, scratch_path)
                if not extracted
                        or lfs.attributes(scratch_path, "size") ~= entry.size then
                    return abort(extract_err or reader.err
                        or ("could not read EPUB entry " .. entry.path))
                end
                local removed, remove_err = remove_file(scratch_path)
                if not removed then return abort(remove_err) end
            end
        elseif entry.mode ~= "directory" then
            return abort("the EPUB contains an unsupported non-file archive entry")
        end
    end
    err = reader.err
    reader:close()
    if scratch_path then
        local removed, remove_err = remove_file(scratch_path)
        if not removed then return nil, remove_err end
    end
    if err then return nil, err end
    return result
end

local function inspect_epub(path, verify_all, scratch_path)
    local regular = regular_file(path)
    if not regular then return nil, "EPUB path is not a regular file" end
    local ok, err = validate_zip_header(path)
    if not ok then return nil, err end
    local first
    first, err = scan_archive(path, {
        ["mimetype"] = true,
        ["META-INF/container.xml"] = true,
    }, verify_all, scratch_path)
    if not first then return nil, err end
    if first.contents.mimetype ~= MIMETYPE then
        return nil, "invalid EPUB mimetype entry"
    end
    local container = first.contents["META-INF/container.xml"]
    if not container then return nil, "EPUB is missing META-INF/container.xml" end
    local opf_path
    opf_path, err = parse_container(container)
    if not opf_path then return nil, err end
    local second
    second, err = scan_archive(path, { [opf_path] = true }, false)
    if not second then return nil, err end
    local opf_xml = second.contents[opf_path]
    if not opf_xml then return nil, "EPUB package document was not found in the archive" end
    local document, metadata
    document, metadata, err = parse_opf(opf_xml)
    if not document then return nil, err end
    return {
        paths = first.paths,
        opf_path = opf_path,
        opf_xml = opf_xml,
        metadata = metadata_from_dom(metadata),
    }
end

local function same_list(left, right)
    if type(left) ~= "table" or type(right) ~= "table" or #left ~= #right then return false end
    for index = 1, #left do
        if left[index] ~= right[index] then return false end
    end
    return true
end

local function same_paths(left, right)
    if #left ~= #right then return false end
    local counts = {}
    for _i, path in ipairs(left) do counts[path] = (counts[path] or 0) + 1 end
    for _i, path in ipairs(right) do
        if not counts[path] then return false end
        counts[path] = counts[path] - 1
        if counts[path] == 0 then counts[path] = nil end
    end
    return next(counts) == nil
end

local function normalized_text(value)
    return value == nil and "" or tostring(value)
end

local function expected_matches(actual, values, present, allow_series_fallback_after_clear)
    for key in pairs(TEXT_FIELDS) do
        if present[key] and normalized_text(actual[key]) ~= normalized_text(values[key]) then
            return false
        end
    end
    if present.authors and not same_list(actual.authors, values.authors) then return false end
    if present.genres and not same_list(actual.genres, values.genres) then return false end
    local clearing_series = allow_series_fallback_after_clear
        and present.series_name and normalized_text(values.series_name) == ""
    if present.series_name and not clearing_series
            and normalized_text(actual.series_name) ~= normalized_text(values.series_name) then
        return false
    end
    if present.series_index and not clearing_series
            and normalized_text(format_index(actual.series_index))
                ~= normalized_text(format_index(values.series_index)) then
        return false
    end
    if present.isbn and normalized_text(actual.isbn) ~= normalized_text(values.isbn) then
        return false
    end
    return true
end

local function has_changes(actual, values, present)
    return not expected_matches(actual, values, present)
end

local function repack(source_path, stage_path, opf_path, edited_opf, scratch_path)
    remove_file(stage_path)
    local scratch_ok, scratch_err = remove_file(scratch_path)
    if not scratch_ok then return nil, scratch_err end
    local reader, err = open_reader(source_path)
    if not reader then return nil, err end
    local writer = Archiver.Writer:new()
    if not writer:open(stage_path, "epub") then
        reader:close()
        return nil, writer.err or "could not create temporary EPUB"
    end

    local failure
    if not writer:setZipCompression("store")
            or not writer:addFileFromMemory("mimetype", MIMETYPE, 0)
            or not writer:setZipCompression("deflate") then
        failure = writer.err or "could not write EPUB mimetype entry"
    end
    local wrote_opf = false
    if not failure then
        for entry in reader:iterate() do
            if entry.mode == "file" then
                if entry.path ~= "mimetype" then
                    if entry.path == opf_path then
                        wrote_opf = true
                        if not writer:addFileFromMemory(entry.path, edited_opf, 0) then
                            failure = writer.err
                                or ("could not write EPUB entry " .. entry.path)
                            break
                        end
                    else
                        local extracted, extract_err = reader:extractToPath(
                            entry.path, scratch_path)
                        if not extracted
                                or lfs.attributes(scratch_path, "size") ~= entry.size then
                            failure = extract_err or reader.err
                                or ("could not read EPUB entry " .. entry.path)
                            break
                        end
                        if HAS_CHMOD and ffi.C.chmod(scratch_path, 384) ~= 0 then
                            failure = "could not make temporary EPUB entry readable"
                            break
                        end
                        -- KOReader closes but retains this reader after addPath.
                        writer.archive_read_disk = nil
                        writer:addPath(entry.path, scratch_path, false, 0)
                        -- addPath returns false at EOF in supported KOReader releases.
                        if writer.err then
                            failure = writer.err
                                or ("could not write EPUB entry " .. entry.path)
                            break
                        end
                        local removed, remove_err = remove_file(scratch_path)
                        if not removed then
                            failure = remove_err
                            break
                        end
                    end
                end
            elseif entry.mode ~= "directory" then
                failure = "the EPUB contains an unsupported non-file archive entry"
                break
            end
        end
    end
    failure = failure or reader.err
    writer:close()
    reader:close()
    local removed, remove_err = remove_file(scratch_path)
    if not removed and not failure then failure = remove_err end
    if not wrote_opf and not failure then failure = "EPUB package entry disappeared while rewriting" end
    if failure then
        remove_file(stage_path)
        return nil, failure
    end
    local ok
    ok, err = preserve_permissions(source_path, stage_path)
    if ok then ok, err = sync_file(stage_path) end
    if not ok then remove_file(stage_path) end
    return ok, err
end

local function validate_stage(path, source, values, present, scratch_path, expected_opf)
    local ok, err = validate_zip_header(path, true)
    if not ok then return nil, err end
    local stage
    stage, err = inspect_epub(path, true, scratch_path)
    if not stage then return nil, err end
    if stage.opf_path ~= source.opf_path or not same_paths(stage.paths, source.paths) then
        return nil, "rewritten EPUB does not contain the same files as the original"
    end
    if expected_opf and stage.opf_xml ~= expected_opf then
        return nil, "rewritten EPUB package document did not match the edited metadata"
    end
    if not expected_matches(stage.metadata, values, present, true) then
        return nil, "rewritten EPUB metadata did not match the requested values"
    end
    return stage
end

local function companion_payload(snapshot)
    if snapshot ~= nil and type(snapshot) ~= "table" then
        return nil, "sidecar_snapshot must be a table"
    end
    return {
        version = TRANSACTION_VERSION,
        sidecar_snapshot = snapshot or {},
    }
end

local function read_companion(path)
    if not exists(path) then return nil, "EPUB metadata backup state is missing" end
    local payload, err = read_json(path)
    if not payload then return nil, err end
    if payload.version ~= TRANSACTION_VERSION or type(payload.sidecar_snapshot) ~= "table" then
        return nil, "unsupported metadata backup state"
    end
    if payload.book_hash ~= nil and (type(payload.book_hash) ~= "string"
            or not payload.book_hash:match("^[0-9a-fA-F]+$")) then
        return nil, "unsupported metadata backup state"
    end
    if payload.sidecar_fingerprint ~= nil
            and (type(payload.sidecar_fingerprint) ~= "string"
                or not payload.sidecar_fingerprint:match("^[0-9a-fA-F]+$")) then
        return nil, "unsupported metadata backup state"
    end
    return payload.sidecar_snapshot, nil, payload.book_hash,
        payload.sidecar_fingerprint
end

local function restore_old(current, old, had_current)
    if exists(old) then
        local ok, err = remove_file(current)
        if not ok then return nil, err end
        return move_file(old, current)
    end
    if had_current == false then return remove_file(current) end
    return true
end

local function transaction_stage(artifact, marker)
    return marker.operation == "restore" and artifact.restore_stage or artifact.stage
end

local function canonical_sidecar_target(path)
    if type(path) ~= "string" or path:sub(-#SIDECAR_NAME) ~= SIDECAR_NAME then
        return nil
    end
    local absolute = path:sub(1, 1) == "/"
        or ffi.os == "Windows" and (path:match("^%a:[/\\]") or path:match("^[/\\][/\\]"))
    if not absolute then return nil end
    local parent = ffiutil.realpath(ffiutil.dirname(path))
    if not parent then return nil end
    local separator = parent:match("[/\\]$") and "" or "/"
    local canonical = parent .. separator .. SIDECAR_NAME:sub(2)
    return ffi.os == "Windows" and canonical:lower() or canonical
end

local function canonical_sidecar_directory(path)
    if type(path) ~= "string" or path:sub(-4) ~= ".sdr" then return nil end
    local absolute = path:sub(1, 1) == "/"
        or ffi.os == "Windows" and (path:match("^%a:[/\\]") or path:match("^[/\\][/\\]"))
    if not absolute then return nil end
    local parent = ffiutil.realpath(ffiutil.dirname(path))
    if not parent then return nil end
    local name = path:match("([^/\\]+)$")
    if not name then return nil end
    local separator = parent:match("[/\\]$") and "" or "/"
    local canonical = parent .. separator .. name
    return ffi.os == "Windows" and canonical:lower() or canonical
end

local function direct_hash_sidecar_directory(book_path)
    if not regular_file(book_path) then return nil end
    local hash = require("util").partialMD5(book_path)
    if type(hash) ~= "string" or #hash < 2 then return nil end
    local loaded, DocSettings = pcall(require, "docsettings")
    if not loaded or type(DocSettings.getSidecarStorage) ~= "function" then return nil end
    local storage = DocSettings.getSidecarStorage("hash")
    if type(storage) ~= "string" or storage == "" then return nil end
    return storage .. "/" .. hash:sub(1, 2) .. "/" .. hash .. ".sdr"
end

local function sidecar_directory_fingerprint(directory)
    local attr = lfs.symlinkattributes(directory)
    if not attr then return nil end
    if attr.mode ~= "directory" then return nil, "invalid hash sidecar directory" end
    local update = require("ffi/sha2").md5()
    local function walk(path, relative)
        local called, iterator, state = pcall(lfs.dir, path)
        if not called then return nil, iterator end
        local entries = {}
        for entry in iterator, state do
            if entry ~= "." and entry ~= ".." then entries[#entries + 1] = entry end
        end
        table.sort(entries)
        for _i, entry in ipairs(entries) do
            local entry_path = path .. "/" .. entry
            local entry_relative = relative == "" and entry or relative .. "/" .. entry
            local entry_attr = lfs.symlinkattributes(entry_path)
            if not entry_attr then return nil, "hash sidecar entry disappeared" end
            if entry_attr.mode == "directory" then
                update("D\0" .. entry_relative .. "\0")
                local ok, err = walk(entry_path, entry_relative)
                if not ok then return nil, err end
            elseif entry_attr.mode == "file" then
                update("F\0" .. entry_relative .. "\0" .. tostring(entry_attr.size) .. "\0")
                local file, err = io.open(entry_path, "rb")
                if not file then return nil, err end
                local read = 0
                while true do
                    local chunk = file:read(64 * 1024)
                    if not chunk then break end
                    read = read + #chunk
                    update(chunk)
                end
                file:close()
                if read ~= entry_attr.size then return nil, "short hash sidecar read" end
            else
                return nil, "unsupported entry in hash sidecar directory"
            end
        end
        return true
    end
    local ok, err = walk(directory, "")
    if not ok then return nil, err end
    return update()
end

local function current_hash_sidecar_fingerprint(book_path)
    local directory = direct_hash_sidecar_directory(book_path)
    if not directory then return nil end
    return sidecar_directory_fingerprint(directory)
end

local function hash_sidecar_artifacts(target, book_path)
    local owner = require("ffi/sha2").md5(ffiutil.realpath(book_path) or book_path)
    local prefix = target .. ".zen-metadata." .. owner
    return prefix .. ".new", prefix .. ".old"
end

local function sidecar_belongs_to_book(target, book_path, candidates, directory_target)
    local canonicalize = directory_target
        and canonical_sidecar_directory or canonical_sidecar_target
    local canonical = canonicalize(target)
    if not canonical then return false end
    local loaded, DocSettings = pcall(require, "docsettings")
    if not loaded or type(DocSettings.getSidecarDir) ~= "function" then return false end
    if not directory_target then
        for _i, location in ipairs({ "doc", "dir" }) do
            local called, directory = pcall(DocSettings.getSidecarDir,
                DocSettings, book_path, location)
            if called and type(directory) == "string" then
                if canonicalize(directory .. SIDECAR_NAME) == canonical then return true end
            end
        end
    end
    for _i, candidate in ipairs(candidates or { book_path }) do
        local directory = direct_hash_sidecar_directory(candidate)
        local expected = directory_target and directory
            or directory and directory .. SIDECAR_NAME
        if expected and canonicalize(expected) == canonical then return true end
    end
    return false
end

local function validate_sidecar_update(update, initial, book_path, candidates)
    if update == nil then return true end
    if update.kind == "group" then
        if type(update.updates) ~= "table" or #update.updates < 1
                or #update.updates > 2 then
            return nil, "invalid grouped sidecar transaction"
        end
        for _i, child in ipairs(update.updates) do
            if type(child) ~= "table" or child.kind == "group" then
                return nil, "invalid grouped sidecar transaction"
            end
            local ok, err = validate_sidecar_update(
                child, initial, book_path, candidates)
            if not ok then return nil, err end
        end
        return true
    end
    if update.kind == "directory" then
        local expected_stage, expected_old = hash_sidecar_artifacts(
            update.target, book_path)
        if type(update.source) ~= "string"
                or type(update.target) ~= "string"
                or type(update.stage) ~= "string"
                or type(update.old) ~= "string"
                or type(update.had_target) ~= "boolean"
                or update.source == update.target
                or update.stage ~= expected_stage
                or update.old ~= expected_old then
            return nil, "invalid hash sidecar transaction"
        end
        local source_matches = sidecar_belongs_to_book(
            update.source, book_path, candidates, true)
        local target_matches = sidecar_belongs_to_book(
            update.target, book_path, candidates, true)
        if not source_matches or not target_matches then
            return nil, "hash sidecar transaction does not belong to this EPUB"
        end
        if initial then
            if lfs.symlinkattributes(update.source, "mode") ~= "directory"
                    or lfs.symlinkattributes(update.stage, "mode") ~= "directory"
                    or exists(update.old)
                    or exists(update.target) ~= update.had_target then
                return nil, "hash sidecar changed before EPUB replacement"
            end
        end
        return true
    end
    if type(update) ~= "table"
            or type(update.target) ~= "string"
            or type(update.stage) ~= "string"
            or type(update.old) ~= "string"
            or type(update.delete) ~= "boolean"
            or type(update.had_target) ~= "boolean"
            or update.target:sub(-#SIDECAR_NAME) ~= SIDECAR_NAME
            or update.stage ~= update.target .. SIDECAR_NEW_SUFFIX
            or update.old ~= update.target .. SIDECAR_OLD_SUFFIX then
        return nil, "invalid sidecar transaction"
    end
    if not sidecar_belongs_to_book(update.target, book_path, candidates, false) then
        return nil, "sidecar transaction does not belong to this EPUB"
    end
    if initial then
        if exists(update.old) or exists(update.target) ~= update.had_target then
            return nil, "sidecar changed before EPUB replacement"
        end
        if update.delete then
            if not update.had_target or exists(update.stage) then
                return nil, "invalid sidecar deletion transaction"
            end
        elseif not regular_file(update.stage) then
            return nil, "staged sidecar metadata is missing"
        end
    end
    return true
end

local VALID_PHASES = {
    prepared = true,
    replaced = true,
    rolled_back_file = true,
    committed = true,
}

local function validate_marker(marker, path)
    if type(marker) ~= "table"
            or marker.version ~= TRANSACTION_VERSION
            or (marker.operation ~= "write" and marker.operation ~= "restore")
            or not VALID_PHASES[marker.phase]
            or type(marker.had_backup) ~= "boolean"
            or type(marker.had_companion) ~= "boolean"
            or (marker.keep_backup ~= nil
                and type(marker.keep_backup) ~= "boolean") then
        return nil, "unsupported EPUB metadata recovery marker"
    end
    local artifact = paths(path)
    return validate_sidecar_update(marker.sidecar, false, path, {
        path,
        artifact.backup,
        transaction_stage(artifact, marker),
        artifact.live_old,
    })
end

local function rollback_sidecar(update)
    if not update then return true end
    if update.kind == "group" then
        for index = #update.updates, 1, -1 do
            local ok, err = rollback_sidecar(update.updates[index])
            if not ok then return nil, err end
        end
        return true
    end
    local remove = update.kind == "directory" and remove_tree or remove_file
    if exists(update.old) then
        local ok, err = remove(update.target)
        if not ok then return nil, err end
        ok, err = move_file(update.old, update.target)
        if not ok then return nil, err end
    elseif not update.had_target then
        local ok, err = remove(update.target)
        if not ok then return nil, err end
    end
    local ok, err = remove(update.stage)
    if not ok then return nil, err end
    return sync_directory(update.target)
end

local function commit_sidecar(update)
    if not update then return true end
    if update.kind == "group" then
        for _i, child in ipairs(update.updates) do
            local ok, err = commit_sidecar(child)
            if not ok then return nil, err end
        end
        return true
    end
    local ok, err
    if update.had_target then
        ok, err = move_file(update.target, update.old)
        if not ok then return nil, err end
        ok, err = sync_directory(update.target)
        if not ok then return nil, err end
    end
    if not update.delete then
        ok, err = move_file(update.stage, update.target)
        if not ok then return nil, err end
        ok, err = sync_directory(update.target)
        if not ok then return nil, err end
    end
    return true
end

local function finish_sidecar(update, committed)
    if not update then return true end
    if update.kind == "group" then
        local start, stop, step = 1, #update.updates, 1
        if not committed then start, stop, step = #update.updates, 1, -1 end
        for index = start, stop, step do
            local ok, err = finish_sidecar(update.updates[index], committed)
            if not ok then return nil, err end
        end
        return true
    end
    if not committed then return rollback_sidecar(update) end
    local remove = update.kind == "directory" and remove_tree or remove_file
    local ok, err = remove(update.old)
    if not ok then return nil, err end
    ok, err = remove(update.stage)
    if not ok then return nil, err end
    return sync_directory(update.target)
end

local function recover_hash_sidecar_target(target, book_path)
    local stage, old = hash_sidecar_artifacts(target, book_path)
    local ok, err = remove_tree(stage)
    if not ok then return nil, err end
    if exists(target) then
        ok, err = remove_tree(old)
    elseif exists(old) then
        ok, err = move_file(old, target)
    end
    if not ok then return nil, err end
    return sync_directory(target)
end

local function update_staged_hash_identity(directory, book_path, staged_book)
    local DocSettings = require("docsettings")
    local filename = type(DocSettings.getSidecarFilename) == "function"
        and DocSettings.getSidecarFilename(book_path)
        or "metadata." .. (book_path:match(".*%.(.+)") or "_") .. ".lua"
    local sidecar = directory .. "/" .. filename
    if not regular_file(sidecar) then return true end
    local loader, load_err = loadfile(sidecar)
    local called, data
    if loader then called, data = pcall(loader) end
    if not loader or not called or type(data) ~= "table" then
        return nil, load_err or data or "invalid hash sidecar settings"
    end
    local hash = require("util").partialMD5(staged_book)
    if type(hash) ~= "string" then return nil, "could not hash staged EPUB" end
    data.partial_md5_checksum = hash
    data.doc_path = book_path
    local content = "return " .. require("dump")(data, nil, true) .. "\n"
    local ok, err = write_bytes(sidecar, content)
    if not ok then return nil, err end
    loader, load_err = loadfile(sidecar)
    if loader then called, data = pcall(loader) end
    if not loader or not called or type(data) ~= "table"
            or data.partial_md5_checksum ~= hash or data.doc_path ~= book_path then
        return nil, load_err or data or "invalid rewritten hash sidecar settings"
    end
    return true
end

local function prepare_hash_sidecar(path, staged_book, update, allowed_existing_hash,
        allowed_sidecar_fingerprint)
    local source = direct_hash_sidecar_directory(path)
    local target = direct_hash_sidecar_directory(staged_book)
    if not source or not target or source == target then return true, update end
    local source_mode = lfs.symlinkattributes(source, "mode")
    if not source_mode then return true, update end
    if source_mode ~= "directory" then return nil, "invalid hash sidecar directory" end
    local folds_custom = update and canonical_sidecar_target(update.target)
        == canonical_sidecar_target(source .. SIDECAR_NAME)

    local ok, err = make_path_durable(ffiutil.dirname(target))
    if not ok then return nil, err end
    local staged_hash = require("util").partialMD5(staged_book)
    if exists(target) then
        local fingerprint, fingerprint_err = sidecar_directory_fingerprint(target)
        if staged_hash ~= allowed_existing_hash
                or not allowed_sidecar_fingerprint
                or fingerprint ~= allowed_sidecar_fingerprint then
            return nil, fingerprint_err
                or "the destination hash sidecar changed or belongs to another book"
        end
    end
    ok, err = recover_hash_sidecar_target(target, path)
    if not ok then return nil, err end

    local stage, old = hash_sidecar_artifacts(target, path)
    local skip = folds_custom and {
        [update.stage] = true,
        [update.old] = true,
    } or nil
    ok, err = copy_tree(source, stage, skip)
    if not ok then
        remove_tree(stage)
        return nil, err
    end

    if folds_custom then
        local staged_custom = stage .. SIDECAR_NAME
        if update.delete then
            ok, err = remove_file(staged_custom)
        else
            ok, err = copy_file(update.stage, staged_custom)
        end
        if ok then ok, err = sync_directory_contents(stage) end
        local removed, remove_err = remove_file(update.stage)
        if ok and not removed then ok, err = nil, remove_err end
        if not ok then
            remove_tree(stage)
            return nil, err
        end
    end
    ok, err = update_staged_hash_identity(stage, path, staged_book)
    if not ok then
        remove_tree(stage)
        return nil, err
    end
    ok, err = sync_directory(stage)
    if not ok then
        remove_tree(stage)
        return nil, err
    end
    local directory_update = {
        kind = "directory",
        source = source,
        target = target,
        stage = stage,
        old = old,
        had_target = exists(target),
    }
    if update and not folds_custom then
        return true, { kind = "group", updates = { update, directory_update } }
    end
    return true, directory_update
end

local function prepare_sidecar(path, callback, metadata, callback_value, staged_book,
        allowed_existing_hash, allowed_sidecar_fingerprint)
    local update
    if callback then
        local called, accepted, update_or_err = pcall(callback, metadata, callback_value)
        if not called then return nil, accepted end
        if accepted ~= true then return nil, update_or_err or "sidecar preparation failed" end
        local ok, err = validate_sidecar_update(update_or_err, true, path, {
            path,
            staged_book,
        })
        if not ok then return nil, err end
        update = update_or_err
    end
    local ok, update_or_err = prepare_hash_sidecar(
        path, staged_book, update, allowed_existing_hash,
        allowed_sidecar_fingerprint)
    if not ok then
        rollback_sidecar(update)
        return nil, update_or_err
    end
    local valid, err = validate_sidecar_update(update_or_err, true, path, {
        path,
        staged_book,
    })
    if not valid then
        rollback_sidecar(update_or_err)
        return nil, err
    end
    return true, update_or_err
end

local function write_marker(path, marker)
    local artifact = paths(path)
    local ok, err = write_json(artifact.marker_new, marker)
    if not ok then return nil, err end
    if ffi.os ~= "Windows" or not exists(artifact.marker) then
        ok, err = move_file(artifact.marker_new, artifact.marker)
        if not ok then return nil, err end
        return sync_directory(path)
    end

    ok, err = remove_file(artifact.marker_old)
    if not ok then return nil, err end
    ok, err = move_file(artifact.marker, artifact.marker_old)
    if not ok then return nil, err end
    ok, err = sync_directory(path)
    if not ok then
        move_file(artifact.marker_old, artifact.marker)
        sync_directory(path)
        return nil, err
    end
    ok, err = move_file(artifact.marker_new, artifact.marker)
    if not ok then
        move_file(artifact.marker_old, artifact.marker)
        sync_directory(path)
        return nil, err
    end
    ok, err = sync_directory(path)
    if not ok then return nil, err end
    ok, err = remove_file(artifact.marker_old)
    if not ok then return nil, err end
    return sync_directory(path)
end

local function recover_marker(path)
    local artifact = paths(path)
    if not exists(artifact.marker_old) then return true end
    local ok, err
    if exists(artifact.marker) then
        local current = read_json(artifact.marker)
        if current then
            ok, err = remove_file(artifact.marker_old)
        else
            ok, err = remove_file(artifact.marker)
            if ok then ok, err = move_file(artifact.marker_old, artifact.marker) end
        end
    else
        ok, err = move_file(artifact.marker_old, artifact.marker)
    end
    if not ok then return nil, err end
    return sync_directory(path)
end

local function replace_live(path, stage)
    local ok, err = atomic_replace_file(stage, path)
    if not ok then return nil, err end
    ok, err = sync_directory(path)
    if not ok then return nil, err end
    return true
end

local function set_transaction_phase(path, phase)
    local marker, err = read_json(paths(path).marker)
    if not marker then return nil, err end
    marker.phase = phase
    return write_marker(path, marker)
end

local function finish_transaction(path, committed)
    local artifact = paths(path)
    local marker, err = read_json(artifact.marker)
    if not marker then return nil, err end
    local valid
    valid, err = validate_marker(marker, path)
    if not valid then return nil, err end

    local stage = transaction_stage(artifact, marker)
    committed = committed == true
    local sidecar_ok
    sidecar_ok, err = finish_sidecar(marker.sidecar, committed)
    if not sidecar_ok then return nil, "could not recover sidecar metadata: " .. tostring(err) end
    if committed then
        local stale_files = {
            artifact.backup_old,
            artifact.companion_old,
            artifact.backup_new,
            artifact.companion_new,
            artifact.live_old,
        }
        if marker.keep_backup == false then
            stale_files[#stale_files + 1] = artifact.backup
            stale_files[#stale_files + 1] = artifact.companion
        end
        for _i, stale in ipairs(stale_files) do
            local ok
            ok, err = remove_file(stale)
            if not ok then return nil, err end
        end
    else
        local ok
        ok, err = restore_old(artifact.backup, artifact.backup_old,
            marker.had_backup == true)
        if not ok then return nil, "could not recover metadata backup: " .. tostring(err) end
        ok, err = restore_old(artifact.companion, artifact.companion_old,
            marker.had_companion == true)
        if not ok then return nil, "could not recover metadata state: " .. tostring(err) end
        for _i, stale in ipairs({
            artifact.backup_new,
            artifact.companion_new,
        }) do
            ok, err = remove_file(stale)
            if not ok then return nil, err end
        end
        ok, err = sync_directory(path)
        if not ok then return nil, err end
    end
    local ok
    ok, err = remove_file(artifact.marker_new)
    if not ok then return nil, err end
    ok, err = remove_file(artifact.marker_old)
    if not ok then return nil, err end
    ok, err = remove_file(artifact.marker)
    if not ok then return nil, err end
    ok, err = sync_directory(path)
    if not ok then return nil, err end
    local durable_outcome = committed and "committed" or "rolled_back"
    for _i, stale in ipairs({ stage, artifact.live_old }) do
        ok, err = remove_file(stale)
        if not ok then return nil, err, durable_outcome end
    end
    ok, err = sync_directory(path)
    if not ok then return nil, err, durable_outcome end
    return true, nil, durable_outcome
end

local function rollback_replacement(path)
    local artifact = paths(path)
    local marker, err = read_json(artifact.marker)
    if not marker then return nil, err end
    local stage = transaction_stage(artifact, marker)
    local previous_path = artifact.backup
    local previous
    previous, err = inspect_epub(previous_path, true, artifact.scratch)
    if not previous then
        return nil, "replacement rollback original is invalid: " .. tostring(err)
    end

    local live_is_previous = false
    if exists(stage) then
        local attempted
        attempted, err = inspect_epub(stage, false)
        if not attempted or not same_paths(attempted.paths, previous.paths) then
            return nil, "replacement rollback attempted EPUB is invalid: "
                .. tostring(err or "entry mismatch")
        end
        if exists(path) then
            live_is_previous, err = files_equal(path, previous_path)
            if live_is_previous == nil then return nil, err end
            if not live_is_previous then
                local live_is_attempted
                live_is_attempted, err = files_equal(path, stage)
                if live_is_attempted == nil then return nil, err end
                if not live_is_attempted then
                    return nil, "replacement rollback live state is invalid"
                end
            end
        end
    elseif not regular_file(path) then
        return nil, "replacement rollback EPUB is missing"
    end

    if not live_is_previous then
        if exists(artifact.live_old) then
            local matches
            matches, err = files_equal(artifact.live_old, previous_path)
            if matches == nil then return nil, err end
            if not matches then return nil, "replacement rollback original changed" end
        else
            local copied
            copied, err = copy_file(previous_path, artifact.live_old)
            if not copied then
                return nil, "could not stage replacement rollback: " .. tostring(err)
            end
            local staged
            staged, err = inspect_epub(artifact.live_old, false)
            if not staged or not same_paths(staged.paths, previous.paths) then
                remove_file(artifact.live_old)
                return nil, "replacement rollback validation failed: "
                    .. tostring(err or "entry mismatch")
            end
            local synced
            synced, err = sync_directory(path)
            if not synced then return nil, err end
        end
        if not exists(stage) then
            local copied
            copied, err = copy_file(path, stage)
            if not copied then return nil, "could not preserve replaced EPUB: " .. tostring(err) end
            copied, err = sync_directory(path)
            if not copied then return nil, err end
            local attempted
            attempted, err = inspect_epub(stage, false)
            if not attempted or not same_paths(attempted.paths, previous.paths) then
                return nil, "replacement rollback attempted EPUB is invalid: "
                    .. tostring(err or "entry mismatch")
            end
        end
    end
    local sidecar_ok
    sidecar_ok, err = rollback_sidecar(marker.sidecar)
    if not sidecar_ok then
        return nil, "could not roll back sidecar metadata: " .. tostring(err)
    end
    local ok
    if not live_is_previous then
        ok, err = atomic_replace_file(artifact.live_old, path)
        if not ok then return nil, "could not restore original EPUB: " .. tostring(err) end
        ok, err = sync_directory(path)
        if not ok then return nil, err end
    end
    ok, err = set_transaction_phase(path, "rolled_back_file")
    if not ok then return nil, err end
    return finish_transaction(path, false)
end

local function cleanup_stale(path)
    local artifact = paths(path)
    local changed = false
    for _i, stale in ipairs({
        artifact.stage,
        artifact.restore_stage,
        artifact.backup_new,
        artifact.companion_new,
        artifact.marker_new,
        artifact.marker_old,
        artifact.scratch,
    }) do
        if exists(stale) then
            local ok, err = remove_file(stale)
            if not ok then return nil, err end
            changed = true
        end
    end
    if exists(artifact.backup_old) then
        if exists(artifact.backup) then
            local ok, err = remove_file(artifact.backup_old)
            if not ok then return nil, err end
        else
            local ok, err = move_file(artifact.backup_old, artifact.backup)
            if not ok then return nil, err end
        end
        changed = true
    end
    if exists(artifact.companion_old) then
        if exists(artifact.companion) then
            local ok, err = remove_file(artifact.companion_old)
            if not ok then return nil, err end
        else
            local ok, err = move_file(artifact.companion_old, artifact.companion)
            if not ok then return nil, err end
        end
        changed = true
    end
    if exists(artifact.live_old) then
        local ok, err
        if exists(path) then
            ok, err = remove_file(artifact.live_old)
        else
            ok, err = move_file(artifact.live_old, path)
        end
        if not ok then return nil, err end
        changed = true
    end
    if changed then return sync_directory(path) end
    return true
end

local function recover(path, force_sync)
    local artifact = paths(path)
    local marker_ok, marker_err = recover_marker(path)
    if not marker_ok then return nil, marker_err end
    if exists(artifact.marker) then
        local marker, err = read_json(artifact.marker)
        if not marker then return nil, err end
        local valid
        valid, err = validate_marker(marker, path)
        if not valid then return nil, err end
        local stage = transaction_stage(artifact, marker)
        if marker.phase == "committed" then
            local ok, outcome
            ok, err, outcome = finish_transaction(path, true)
            if ok or outcome == "committed" then return true, nil, "committed" end
            return nil, err
        end
        if marker.phase == "rolled_back_file" then
            local ok
            ok, err = finish_transaction(path, false)
            return ok, err, ok and "rolled_back" or nil
        end
        if marker.phase == "replaced"
                or exists(artifact.live_old)
                or (marker.phase == "prepared" and not exists(stage)) then
            local ok
            ok, err = rollback_replacement(path)
            return ok, err, ok and "rolled_back" or nil
        end
        local ok
        ok, err = finish_transaction(path, false)
        return ok, err, ok and "rolled_back" or nil
    end
    local ok, err = cleanup_stale(path)
    if ok and force_sync then ok, err = sync_directory(path) end
    return ok, err, ok and "clean" or nil
end

local function begin_transaction(path, operation, sidecar, keep_backup)
    local artifact = paths(path)
    local marker = {
        version = TRANSACTION_VERSION,
        operation = operation,
        phase = "prepared",
        had_backup = exists(artifact.backup),
        had_companion = exists(artifact.companion),
        keep_backup = keep_backup ~= false,
        sidecar = sidecar,
    }
    local ok, err = write_marker(path, marker)
    if not ok then
        rollback_sidecar(sidecar)
        return nil, err
    end

    if marker.had_backup then
        ok, err = move_file(artifact.backup, artifact.backup_old)
        if not ok then return nil, err end
    end
    if marker.had_companion then
        ok, err = move_file(artifact.companion, artifact.companion_old)
        if not ok then return nil, err end
    end
    ok, err = move_file(artifact.backup_new, artifact.backup)
    if not ok then return nil, err end
    ok, err = move_file(artifact.companion_new, artifact.companion)
    if not ok then return nil, err end
    return sync_directory(path)
end

local function finish_replacement(path, sidecar)
    local marked, mark_err = set_transaction_phase(path, "replaced")
    if not marked then
        local rolled, rollback_err = rollback_replacement(path)
        return nil, rolled and tostring(mark_err)
            or tostring(mark_err) .. "; rollback failed: " .. tostring(rollback_err)
    end
    local sidecar_ok, sidecar_err = commit_sidecar(sidecar)
    if not sidecar_ok then
        local rolled, rollback_err = rollback_replacement(path)
        sidecar_err = tostring(sidecar_err or "sidecar update failed")
        return nil, rolled and sidecar_err
            or sidecar_err .. "; rollback failed: " .. tostring(rollback_err)
    end
    local phase_ok, phase_err = set_transaction_phase(path, "committed")
    if not phase_ok then
        local recovered, recovery_err, outcome = recover(path)
        if recovered and outcome == "committed" then return true end
        return nil, recovered and tostring(phase_err)
            or tostring(phase_err) .. "; recovery failed: " .. tostring(recovery_err)
    end
    local finished, finish_err, outcome = finish_transaction(path, true)
    if not finished then
        if outcome == "committed" then return true end
        local recovered, recovery_err, recovered_outcome = recover(path, true)
        if recovered and (recovered_outcome == "committed"
                or recovered_outcome == "clean") then
            return true
        end
        return nil, "could not finish EPUB transaction: " .. tostring(finish_err)
            .. "; recovery failed: " .. tostring(recovery_err)
    end
    return true
end

function M.isEpub(path)
    return type(path) == "string" and path:lower():sub(-5) == ".epub"
end

function M.backupPath(path)
    return type(path) == "string" and paths(path).backup or nil
end

function M.read(path)
    if not M.isEpub(path) then return nil, "embedded metadata editing supports EPUB files only" end
    local ok, err = recover(path)
    if not ok then return nil, err end
    local inspected
    inspected, err = inspect_epub(path, false)
    if not inspected then return nil, err end
    return inspected.metadata
end

function M.write(path, draft, options)
    if not M.isEpub(path) then return nil, "embedded metadata editing supports EPUB files only" end
    local values, present, err = normalize_draft(draft)
    if not values then return nil, err end
    options = options or {}
    local snapshot_supplied = rawget(options, "sidecar_snapshot") ~= nil
    local payload
    payload, err = companion_payload(options.sidecar_snapshot)
    if not payload then return nil, err end
    local ok
    ok, err = recover(path)
    if not ok then return nil, err end
    payload.book_hash = require("util").partialMD5(path)
    payload.sidecar_fingerprint, err = current_hash_sidecar_fingerprint(path)
    if err then return nil, err end
    local artifact = paths(path)
    local allowed_existing_hash, allowed_sidecar_fingerprint
    if exists(artifact.companion) then
        local companion = { read_companion(artifact.companion) }
        if companion[2] then return nil, companion[2] end
        allowed_existing_hash = companion[3]
        allowed_sidecar_fingerprint = companion[4]
    end
    local source
    source, err = inspect_epub(path, false)
    if not source then return nil, err end
    local metadata_changed = has_changes(source.metadata, values, present)
    if not metadata_changed and not snapshot_supplied then return true end

    local source_size = lfs.attributes(path, "size") or 0
    ok, err = ensure_free_space(path, source_size * 2)
    if not ok then return nil, err end
    ok, err = ensure_writable(path)
    if not ok then return nil, err end
    source, err = inspect_epub(path, true, artifact.scratch)
    if not source then return nil, err end

    local staged_metadata
    if metadata_changed then
        local edited
        edited, err = edit_opf(source.opf_xml, values, present)
        if not edited then return nil, err end
        ok, err = repack(path, artifact.stage, source.opf_path, edited,
            artifact.scratch)
        if not ok then return nil, err end
        local staged
        staged, err = validate_stage(artifact.stage, source, values, present,
            artifact.scratch, edited)
        ok = staged ~= nil
        staged_metadata = staged and staged.metadata
    else
        ok, err = copy_file(path, artifact.stage)
        if ok then
            local stage
            stage, err = inspect_epub(artifact.stage, false)
            ok = stage ~= nil and same_paths(stage.paths, source.paths)
            staged_metadata = stage and stage.metadata
        end
    end
    if not ok then
        remove_file(artifact.stage)
        return nil, "temporary EPUB validation failed: " .. tostring(err)
    end
    ok, err = copy_file(path, artifact.backup_new)
    if not ok then
        remove_file(artifact.stage)
        remove_file(artifact.backup_new)
        return nil, "could not create EPUB backup: " .. tostring(err)
    end
    local backup_copy
    backup_copy, err = inspect_epub(artifact.backup_new, false)
    if not backup_copy or not same_paths(backup_copy.paths, source.paths) then
        remove_file(artifact.stage)
        remove_file(artifact.backup_new)
        return nil, "EPUB backup validation failed: " .. tostring(err or "entry mismatch")
    end
    ok, err = write_json(artifact.companion_new, payload)
    if not ok then
        remove_file(artifact.stage)
        remove_file(artifact.backup_new)
        remove_file(artifact.companion_new)
        return nil, err
    end

    local sidecar_ok, sidecar_update = prepare_sidecar(
        path, options.prepare_sidecar, staged_metadata, nil, artifact.stage,
        allowed_existing_hash, allowed_sidecar_fingerprint)
    if not sidecar_ok then
        remove_file(artifact.stage)
        remove_file(artifact.backup_new)
        remove_file(artifact.companion_new)
        return nil, sidecar_update
    end

    ok, err = begin_transaction(path, "write", sidecar_update, options.keep_backup)
    if not ok then
        local recovered, recovery_err = recover(path)
        return nil, recovered and tostring(err)
            or tostring(err) .. "; recovery failed: " .. tostring(recovery_err)
    end
    ok, err = replace_live(path, artifact.stage)
    if not ok then
        local recovered, recovery_err = recover(path)
        return nil, recovered and ("could not replace original EPUB: " .. tostring(err))
            or "could not replace original EPUB: " .. tostring(err)
                .. "; recovery failed: " .. tostring(recovery_err)
    end
    return finish_replacement(path, sidecar_update)
end

function M.canRestore(path)
    if not M.isEpub(path) then return false end
    local ok, err = recover(path)
    if not ok then return false, err end
    local artifact = paths(path)
    if not regular_file(artifact.backup) then return false end
    local inspected
    inspected, err = inspect_epub(artifact.backup, false)
    if not inspected then return false, err end
    local snapshot
    snapshot, err = read_companion(artifact.companion)
    if not snapshot then return false, err end
    return true
end

function M.restore(path, options)
    if not M.isEpub(path) then return nil, "embedded metadata editing supports EPUB files only" end
    options = options or {}
    local payload, err = companion_payload(options.sidecar_snapshot)
    if not payload then return nil, err end
    local ok
    ok, err = recover(path)
    if not ok then return nil, err end
    payload.book_hash = require("util").partialMD5(path)
    payload.sidecar_fingerprint, err = current_hash_sidecar_fingerprint(path)
    if err then return nil, err end

    local artifact = paths(path)
    if not regular_file(artifact.backup) then return nil, "no EPUB metadata backup is available" end
    local current_size = lfs.attributes(path, "size") or 0
    local backup_size = lfs.attributes(artifact.backup, "size") or 0
    ok, err = ensure_free_space(path, current_size + backup_size)
    if not ok then return nil, err end
    local current, backup
    current, err = inspect_epub(path, true, artifact.scratch)
    if not current then return nil, err end
    ok, err = ensure_writable(path)
    if not ok then return nil, err end
    backup, err = inspect_epub(artifact.backup, true, artifact.scratch)
    if not backup then return nil, "EPUB metadata backup is invalid: " .. tostring(err) end
    local restored_snapshot, restored_hash, restored_fingerprint
    restored_snapshot, err, restored_hash, restored_fingerprint =
        read_companion(artifact.companion)
    if not restored_snapshot then return nil, err end

    ok, err = copy_file(artifact.backup, artifact.restore_stage)
    if not ok then return nil, "could not stage EPUB restore: " .. tostring(err) end
    local restore_copy
    restore_copy, err = inspect_epub(artifact.restore_stage, false)
    if not restore_copy or not same_paths(restore_copy.paths, backup.paths) then
        remove_file(artifact.restore_stage)
        return nil, "staged EPUB restore failed validation: " .. tostring(err or "entry mismatch")
    end
    ok, err = copy_file(path, artifact.backup_new)
    if not ok then
        remove_file(artifact.restore_stage)
        remove_file(artifact.backup_new)
        return nil, "could not stage undo backup: " .. tostring(err)
    end
    local undo_copy
    undo_copy, err = inspect_epub(artifact.backup_new, false)
    if not undo_copy or not same_paths(undo_copy.paths, current.paths) then
        remove_file(artifact.restore_stage)
        remove_file(artifact.backup_new)
        return nil, "undo backup failed validation: " .. tostring(err or "entry mismatch")
    end
    ok, err = write_json(artifact.companion_new, payload)
    if not ok then
        remove_file(artifact.restore_stage)
        remove_file(artifact.backup_new)
        remove_file(artifact.companion_new)
        return nil, err
    end

    local sidecar_ok, sidecar_update = prepare_sidecar(
        path, options.prepare_sidecar, backup.metadata, restored_snapshot,
        artifact.restore_stage, restored_hash, restored_fingerprint)
    if not sidecar_ok then
        remove_file(artifact.restore_stage)
        remove_file(artifact.backup_new)
        remove_file(artifact.companion_new)
        return nil, sidecar_update
    end

    ok, err = begin_transaction(path, "restore", sidecar_update)
    if not ok then
        local recovered, recovery_err = recover(path)
        return nil, recovered and tostring(err)
            or tostring(err) .. "; recovery failed: " .. tostring(recovery_err)
    end
    ok, err = replace_live(path, artifact.restore_stage)
    if not ok then
        local recovered, recovery_err = recover(path)
        return nil, recovered and ("could not restore EPUB: " .. tostring(err))
            or "could not restore EPUB: " .. tostring(err)
                .. "; recovery failed: " .. tostring(recovery_err)
    end
    ok, err = finish_replacement(path, sidecar_update)
    if not ok then return nil, err end
    return restored_snapshot
end

return M
