local M = {}

local function copy_array(values)
    local out = {}
    for _i, value in ipairs(values) do out[_i] = value end
    return out
end

local function lower(value)
    return tostring(value or ""):lower()
end

local function natural_less(first, second)
    local first_text = lower(first)
    local second_text = lower(second)
    local first_prefix, first_number = first_text:match("^(.-)(%d+)%D*$")
    local second_prefix, second_number = second_text:match("^(.-)(%d+)%D*$")
    if first_prefix == second_prefix and first_number and second_number
            and tonumber(first_number) ~= tonumber(second_number) then
        return tonumber(first_number) < tonumber(second_number)
    end
    return first_text < second_text
end

local function metadata_collate(metadata, less)
    return {
        item_func = function(item)
            item.doc_props = metadata[item.file or item.path]
        end,
        init_sort_func = function()
            return less
        end,
    }
end

function M.new()
    local paths = {
        zeta = "/books/zeta-20.epub",
        alpha = "/books/alpha-3.epub",
        middle = "/books/middle-10.epub",
        beta = "/books/beta-1.epub",
    }
    local metadata = {
        [paths.zeta] = {
            title = "Gamma 2", display_title = "Gamma 2", authors = "Author C",
            series = "Series B", series_index = 2, keywords = "Tag B",
        },
        [paths.alpha] = {
            title = "Gamma 10", display_title = "Gamma 10", authors = "Author A",
            series = "Series C", series_index = 4, keywords = "Tag D",
        },
        [paths.middle] = {
            title = "Gamma 1", display_title = "Gamma 1", authors = "Author D",
            series = "Series A", series_index = 3, keywords = "Tag A",
        },
        [paths.beta] = {
            title = "Alpha 5", display_title = "Alpha 5", authors = "Author B",
            series = "Series B", series_index = 1, keywords = "Tag C",
        },
    }
    local access = {
        [paths.zeta] = 100,
        [paths.alpha] = 400,
        [paths.middle] = 300,
        [paths.beta] = 200,
    }
    local change = {
        [paths.zeta] = 400,
        [paths.alpha] = 100,
        [paths.middle] = 200,
        [paths.beta] = 300,
    }
    local expected = {
        strcoll = { paths.alpha, paths.beta, paths.middle, paths.zeta },
        title = { paths.beta, paths.middle, paths.alpha, paths.zeta },
        title_natural = { paths.beta, paths.middle, paths.zeta, paths.alpha },
        authors = { paths.alpha, paths.beta, paths.zeta, paths.middle },
        series = { paths.middle, paths.beta, paths.zeta, paths.alpha },
        series_index = { paths.beta, paths.zeta, paths.middle, paths.alpha },
        access = { paths.alpha, paths.middle, paths.beta, paths.zeta },
        date_added = { paths.zeta, paths.beta, paths.middle, paths.alpha },
        keywords = { paths.middle, paths.zeta, paths.beta, paths.alpha },
    }
    local entries = {}
    for _i, path in ipairs({ paths.zeta, paths.alpha, paths.middle, paths.beta }) do
        entries[#entries + 1] = {
            file = path,
            path = path,
            text = path:match("([^/]+)$"),
            attr = {
                mode = "file", access = access[path], modification = access[path],
                change = change[path], size = 1,
            },
        }
    end
    return {
        access = access,
        entries = entries,
        expected = expected,
        metadata = metadata,
        paths = paths,
    }
end

function M.copy_entries(entries)
    local out = {}
    for _i, entry in ipairs(entries) do
        out[#out + 1] = {
            file = entry.file,
            path = entry.path,
            text = entry.text,
            attr = {
                mode = entry.attr.mode,
                access = entry.attr.access,
                modification = entry.attr.modification,
                change = entry.attr.change,
                size = entry.attr.size,
            },
        }
    end
    return out
end

function M.collates(metadata)
    return {
        strcoll = {
            init_sort_func = function()
                return function(a, b) return lower(a.text) < lower(b.text) end
            end,
        },
        access = {
            init_sort_func = function()
                return function(a, b) return a.attr.access > b.attr.access end
            end,
        },
        title = metadata_collate(metadata, function(a, b)
            return lower(a.doc_props.display_title) < lower(b.doc_props.display_title)
        end),
        title_natural = metadata_collate(metadata, function(a, b)
            return natural_less(a.doc_props.display_title, b.doc_props.display_title)
        end),
        authors = metadata_collate(metadata, function(a, b)
            local first = lower(a.doc_props.authors)
            local second = lower(b.doc_props.authors)
            if first ~= second then return first < second end
            return lower(a.doc_props.display_title) < lower(b.doc_props.display_title)
        end),
        series = metadata_collate(metadata, function(a, b)
            local first = lower(a.doc_props.series)
            local second = lower(b.doc_props.series)
            if first ~= second then return first < second end
            if a.doc_props.series_index ~= b.doc_props.series_index then
                return a.doc_props.series_index < b.doc_props.series_index
            end
            return lower(a.doc_props.display_title) < lower(b.doc_props.display_title)
        end),
        keywords = metadata_collate(metadata, function(a, b)
            local first = lower(a.doc_props.keywords)
            local second = lower(b.doc_props.keywords)
            if first ~= second then return first < second end
            return lower(a.doc_props.display_title) < lower(b.doc_props.display_title)
        end),
    }
end

function M.paths_from_entries(entries)
    local out = {}
    for _i, entry in ipairs(entries) do out[#out + 1] = entry.file or entry.path end
    return out
end

function M.reversed(values)
    local out = copy_array(values)
    for index = 1, math.floor(#out / 2) do
        local opposite = #out - index + 1
        out[index], out[opposite] = out[opposite], out[index]
    end
    return out
end

return M
