-- Pure TOC hierarchy and folding helpers shared by the chapters modal and the page-browser panel.
-- Mirrors KOReader's ReaderToc: only top-level entries show until a parent is unfolded, the
-- current chapter's ancestors start open, and a chapter's length runs to the next entry at its
-- depth or above.
local M = {}

-- Links ordered flat entries (with .depth) into a tree: sets idx, parent, has_children and
-- page_count; marks entries.nested when any entry has children. positions[i] is entry i's
-- counting position (nil when unknown), book_end the position just past the last page.
function M.link(entries, positions, book_end)
    local open = {}
    local function close(pos)
        local e = table.remove(open)
        local start = positions[e.idx]
        if pos and start then e.page_count = math.max(1, pos - start) end
    end
    for i, e in ipairs(entries) do
        e.idx = i
        while #open > 0 and open[#open].depth >= e.depth do close(positions[i]) end
        local parent = open[#open]
        if parent then e.parent, parent.has_children, entries.nested = parent, true, true end
        open[#open + 1] = e
    end
    while #open > 0 do close(book_end) end
    return entries
end

-- Expanded set (keyed by entry) opening every ancestor of entry.
function M.initialFolding(entry)
    local expanded = {}
    while entry and entry.parent do
        expanded[entry.parent] = true
        entry = entry.parent
    end
    return expanded
end

-- Entries whose ancestors are all expanded, in order.
function M.visible(entries, expanded)
    local rows = {}
    for _i, e in ipairs(entries) do
        local p = e.parent
        while p and expanded[p] do p = p.parent end
        if not p then rows[#rows + 1] = e end
    end
    return rows
end

-- Collapsing refolds descendants so reopening shows direct children only.
function M.toggle(entries, entry, expanded)
    if not expanded[entry] then
        expanded[entry] = true
        return
    end
    expanded[entry] = nil
    for i = entry.idx + 1, #entries do
        if entries[i].depth <= entry.depth then break end
        expanded[entries[i]] = nil
    end
end

-- "expanded"/"collapsed" for parents, "leaf" keeps the fold column aligned in nested lists.
function M.foldState(entry, expanded, nested)
    if entry.has_children then return expanded[entry] and "expanded" or "collapsed" end
    return nested and "leaf" or nil
end

function M.countText(entry, enabled)
    if enabled and entry.page_count then return "(" .. entry.page_count .. ")" end
end

function M.showsCounts(plugin)
    local cfg = plugin and plugin.config and plugin.config.page_browser
    return cfg ~= nil and cfg.toc_show_page_counts == true
end

return M
