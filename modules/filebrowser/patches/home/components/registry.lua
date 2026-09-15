local builtin_components = {
    require("modules/filebrowser/patches/home/widgets/datetime"),
    require("modules/filebrowser/patches/home/widgets/featured"),
    require("modules/filebrowser/patches/home/widgets/stats_triplet"),
    require("modules/filebrowser/patches/home/widgets/reading_goals"),
    require("modules/filebrowser/patches/home/widgets/strip"),
    require("modules/filebrowser/patches/home/widgets/quotes"),
}

local builtin_by_id = {}
for _i, comp in ipairs(builtin_components) do
    builtin_by_id[comp.id] = comp
end

local external_by_id = {}
local refresh_callback = nil
local M = {}

M.CAPACITY_UNITS = 10
M.MAX_CAPACITY_UNITS = 20

-- Android may expose native framebuffer axes independently of UI rotation.
local REFERENCE_ASPECT_RATIO = 4 / 3

local SIZE_UNITS = {
    xs = 1,
    s = 2,
    m = 3,
    l = 4,
    xl = 10,
}

local LAYOUT_GROWTH = {
    featured = { max = 4, priority = 2 },
    quotes = { max = 3, priority = 3 },
    reading_goals = { max = 1, priority = 4 },
    stats_triplet = { max = 1, priority = 4 },
    strip = { max = 4, expanded_max = 6, priority = 1 },
}

local function clamp_units(value)
    local units = math.floor((tonumber(value) or 2) + 0.5)
    return math.max(1, math.min(M.CAPACITY_UNITS, units))
end

function M.capacityUnits(width, height)
    width, height = tonumber(width), tonumber(height)
    if not width or not height then
        local ok, Device = pcall(require, "device")
        local screen = ok and Device and Device.screen
        if screen then
            width = tonumber(screen:getWidth())
            height = tonumber(screen:getHeight())
        end
    end
    if not width or width <= 0 or not height or height <= 0 then
        return M.CAPACITY_UNITS
    end
    local short_side = math.min(width, height)
    local long_side = math.max(width, height)
    local capacity = math.floor(
        M.CAPACITY_UNITS * long_side / short_side / REFERENCE_ASPECT_RATIO + 0.5)
    return math.max(M.CAPACITY_UNITS, math.min(M.MAX_CAPACITY_UNITS, capacity))
end

local MIN_LAYOUT_UNITS = {
    datetime = 1,
    featured = 2,
    quotes = 1.5,
    reading_goals = 1,
    stats_triplet = 1,
    strip = 1.5,
}

local function size_value(component)
    if type(component) == "table" and component.size ~= nil then
        return component.size
    end
    return component
end

function M.sizeClass(component)
    local size = size_value(component)
    if type(size) == "string" then
        local name = size:lower()
        if SIZE_UNITS[name] then return name end
    elseif type(size) == "table" then
        local name = type(size.class) == "string" and size.class:lower() or nil
        if name and SIZE_UNITS[name] then return name end
    end
    return nil
end

function M.baseSizeUnits(component)
    local size = size_value(component)
    local class = M.sizeClass(size)
    if class then return SIZE_UNITS[class] end
    if type(size) == "number" then return clamp_units(size) end
    if type(size) == "table" then
        if tonumber(size.units) then
            return math.max(1, math.min(M.CAPACITY_UNITS, tonumber(size.units)))
        end
        local pct = tonumber(size.preferred_pct)
        if pct then return clamp_units(pct * M.CAPACITY_UNITS) end
        if tonumber(size.preferred) then return clamp_units(size.preferred) end
    end
    return SIZE_UNITS.s
end

function M.sizeUnits(component, module_cfg)
    local units = M.baseSizeUnits(component)
    if type(module_cfg) == "table" and module_cfg.two_rows == true then
        units = math.min(6, units * 2)
    end
    return math.min(M.CAPACITY_UNITS, units)
end

function M.sizeLabel(component, module_cfg)
    local class = M.sizeClass(component)
    local label = class and class:upper() or tostring(M.baseSizeUnits(component))
    if M.sizeUnits(component, module_cfg) ~= M.baseSizeUnits(component) then
        label = label .. " × 2"
    end
    return label
end

function M.totalUnits(enabled, modules)
    local total = 0
    enabled = type(enabled) == "table" and enabled or {}
    modules = type(modules) == "table" and modules or {}
    for id, value in pairs(enabled) do
        local component = value == true and M.get(id) or nil
        if component then
            total = total + M.sizeUnits(component, modules[id])
        end
    end
    return total
end

function M.layoutUnits(components, capacity)
    components = components or {}
    capacity = math.max(1, tonumber(capacity) or M.CAPACITY_UNITS)
    local units = {}
    local requested = {}
    local expanded = {}
    local total = 0
    local requested_total = 0
    local priorities = {}
    local seen_priorities = {}
    for i, component in ipairs(components) do
        local base = M.baseSizeUnits(component)
        units[i] = base
        total = total + base
        requested[i] = math.max(base, tonumber(component._home_units) or base)
        expanded[i] = requested[i] > base
        requested_total = requested_total + requested[i]
        local growth = LAYOUT_GROWTH[component.id]
        if growth and not seen_priorities[growth.priority] then
            seen_priorities[growth.priority] = true
            priorities[#priorities + 1] = growth.priority
        end
    end
    table.sort(priorities)

    if requested_total > capacity then
        local minimums = {}
        local minimum_total = 0
        for i, component in ipairs(components) do
            local base = M.baseSizeUnits(component)
            local multiplier = requested[i] > base and requested[i] / base or 1
            local minimum = (MIN_LAYOUT_UNITS[component.id] or 1) * multiplier
            minimums[i] = math.min(requested[i], minimum)
            minimum_total = minimum_total + minimums[i]
        end

        if minimum_total >= capacity then
            local scale = capacity / minimum_total
            for i, minimum in ipairs(minimums) do
                units[i] = minimum * scale
            end
            return units
        end

        local flexible_total = requested_total - minimum_total
        local remaining = capacity - minimum_total
        for i, value in ipairs(requested) do
            local flexible = value - minimums[i]
            units[i] = minimums[i] + (flexible_total > 0
                and remaining * flexible / flexible_total or 0)
        end
        return units
    end

    local growth_capacity = math.min(
        capacity, math.max(M.CAPACITY_UNITS, requested_total))
    local remaining = math.max(0, growth_capacity - total)
    for _i, priority in ipairs(priorities) do
        while remaining > 0 do
            local grew = false
            for i, component in ipairs(components) do
                local growth = LAYOUT_GROWTH[component.id]
                local max_units = growth
                    and math.max(growth.max, tonumber(component._home_units) or 0) or 0
                if growth and growth.expanded_max and expanded[i] then
                    max_units = math.max(max_units, growth.expanded_max)
                end
                if growth and growth.priority == priority and units[i] < max_units then
                    local added = math.min(1, remaining, max_units - units[i])
                    units[i] = units[i] + added
                    remaining = remaining - added
                    grew = true
                    if remaining == 0 then break end
                end
            end
            if not grew then break end
        end
        if remaining == 0 then break end
    end
    return units
end

function M.gridHeights(unit_counts, body_h, gap, capacity, max_heights)
    local heights = {}
    capacity = math.max(1, tonumber(capacity) or M.CAPACITY_UNITS)
    gap = math.max(0, math.floor(tonumber(gap) or 0))
    body_h = math.max(1, math.floor(tonumber(body_h) or 1))
    local pitch = (body_h + gap) / capacity
    local used_units = 0

    for _i, value in ipairs(unit_counts or {}) do
        if used_units >= capacity then break end
        local units = math.max(0, math.min(
            capacity - used_units,
            tonumber(value) or 1
        ))
        if units > 0 then
            local start_px = math.floor(used_units * pitch + 0.5)
            used_units = used_units + units
            local end_px = math.floor(used_units * pitch - gap + 0.5)
            heights[#heights + 1] = math.max(1, end_px - start_px)
        end
    end

    local recipients = {}
    local recipient_weight = 0
    for i, height in ipairs(heights) do
        local maximum = max_heights and tonumber(max_heights[i])
        if maximum and maximum > 0 then
            maximum = math.floor(maximum)
            if height > maximum then heights[i] = maximum end
        end
        if not maximum or maximum <= 0 or heights[i] < maximum then
            local weight = math.max(0, tonumber(unit_counts[i]) or 0)
            recipients[#recipients + 1] = {
                index = i,
                maximum = maximum,
                weight = weight,
            }
            recipient_weight = recipient_weight + weight
        end
    end
    -- Fill unused tracks without stretching width-limited rows past their cap.
    local allocated = math.max(0, #heights - 1) * gap
    for _i, height in ipairs(heights) do allocated = allocated + height end
    local distributable = math.max(0, body_h - allocated)
    local remaining = distributable
    while remaining > 0 and recipient_weight > 0 do
        local pass_budget = remaining
        local assigned = 0
        local spent = 0
        local next_recipients = {}
        local next_weight = 0
        for i, recipient in ipairs(recipients) do
            local share = i == #recipients and pass_budget - assigned
                or math.floor(pass_budget * recipient.weight / recipient_weight)
            assigned = assigned + share
            local current = heights[recipient.index]
            local headroom = recipient.maximum
                and math.max(0, recipient.maximum - current) or share
            local added = math.min(share, headroom)
            heights[recipient.index] = current + added
            spent = spent + added
            if not recipient.maximum or current + added < recipient.maximum then
                next_recipients[#next_recipients + 1] = recipient
                next_weight = next_weight + recipient.weight
            end
        end
        if spent <= 0 then break end
        remaining = remaining - spent
        recipients = next_recipients
        recipient_weight = next_weight
    end

    return heights
end

function M.minLayoutUnits(component)
    local id = type(component) == "table" and component.id or component
    return MIN_LAYOUT_UNITS[id] or 1
end

-- Plan row heights so that the white space between the widgets' content
-- boxes can be equal, with the top and bottom margins mirroring each other
-- (the rule equalSpacingShifts() then enforces). gridHeights() sizes rows
-- from the unit grid and hands all leftover height to one flexible row;
-- equalSpacingShifts() can only move content inside its own row afterwards,
-- so that leftover shows up as one oversized gap. This plans the frames from
-- what each widget needs instead:
--   rows[i].cap       preferred height (content plus the widget's own padding)
--   rows[i].top       padding above the content inside the preferred height
--   rows[i].bottom    padding below the content inside the preferred height
--   rows[i].elastic   true when the widget renders at any height up to its
--                     preferred one (Featured scales its cover); such a row
--                     gives height up when the rigid rows and the white space
--                     need it, and takes spare height when it can use it
--   rows[i].min_h     smallest height an elastic row may be squeezed to
-- Returns { heights = {...}, content_top = {...}, gap = G, margin_top = M1,
-- margin_bottom = M2 } -- content_top is where each content box sits inside
-- its row when the inner gaps are G and the margins M1/M2 -- or nil when the
-- rows cannot be planned (the caller then keeps gridHeights()).
function M.planRowHeights(rows, body_h, gap, page_pad)
    local n = type(rows) == "table" and #rows or 0
    if n < 2 then return nil end
    gap = math.max(0, math.floor(tonumber(gap) or 0))
    page_pad = math.max(0, math.floor(tonumber(page_pad) or 0))
    body_h = math.max(1, math.floor(tonumber(body_h) or 1))
    local full_h = body_h + page_pad * 2

    local caps, pt, pb, est, elastic, min_h = {}, {}, {}, {}, {}, {}
    local any_elastic = false
    local rigid_est, elastic_caps, natural, minimum = 0, 0, 0, 0
    for i, row in ipairs(rows) do
        local cap = math.floor(tonumber(row.cap) or 0)
        if cap < 1 then return nil end
        pt[i] = math.max(0, math.floor(tonumber(row.top) or 0))
        pb[i] = math.max(0, math.floor(tonumber(row.bottom) or 0))
        caps[i] = cap
        est[i] = math.max(1, cap - pt[i] - pb[i])
        elastic[i] = row.elastic == true
        min_h[i] = math.max(1, math.floor(tonumber(row.min_h) or 1))
        if elastic[i] then
            any_elastic = true
            elastic_caps = elastic_caps + cap
            natural = natural + est[i]
            minimum = minimum + math.max(1, min_h[i] - pt[i] - pb[i])
        else
            rigid_est = rigid_est + est[i]
        end
    end

    -- A squeezed elastic row fills its frame, so its content sits exactly at
    -- its own padding: a boundary next to it can only be adjusted from the
    -- other side, and a margin next to it is fixed at page_pad plus that
    -- padding. Spare height, when there is any, goes to an elastic row the
    -- visual pass can still move (not the first row, which it keeps fixed);
    -- otherwise it widens the inner gaps.
    local function fills(i) return elastic[i] end
    local top_fixed = fills(1) and (page_pad + pt[1]) or nil
    local bottom_fixed = fills(n) and (pb[n] + page_pad) or nil
    local margin_floor = math.max(page_pad + pt[1], pb[n] + page_pad)
    local g_min, fixed_inner, free_inner = gap, 0, 0
    for i = 1, n - 1 do
        if fills(i) and fills(i + 1) then
            fixed_inner = fixed_inner + pb[i] + gap + pt[i + 1]
        else
            free_inner = free_inner + 1
            g_min = math.max(g_min, pb[i] + gap + pt[i + 1])
        end
    end

    local G, M1, M2
    if not any_elastic then
        -- Nothing can grow or shrink: space evenly, margins and inner gaps
        -- all the same, if the rows fit at full size with that much room.
        G = math.floor((full_h - rigid_est) / (n + 1))
        if G < math.max(g_min, margin_floor) then return nil end
        M1, M2 = G, G
    else
        -- White space stays at what the paddings need; the elastic rows take
        -- what is left (growing into it, or shrinking to make room).
        G = g_min
        local mirror = top_fixed or bottom_fixed or math.max(margin_floor, G)
        M1 = top_fixed or math.max(mirror, page_pad + pt[1])
        M2 = bottom_fixed or math.max(mirror, pb[n] + page_pad)
        local budget = full_h - M1 - M2 - fixed_inner - free_inner * G - rigid_est
        if budget < minimum then return nil end
        local surplus = math.max(0, budget - natural)
        local sink_caps = 0
        for i = 2, n do if elastic[i] then sink_caps = sink_caps + caps[i] end end
        if surplus > 0 and sink_caps == 0 then
            -- Only the first row could take it: widen the inner gaps instead.
            if free_inner == 0 then return nil end
            local widen = math.floor(surplus / free_inner)
            G = G + widen
            budget = budget - widen * free_inner
            surplus = math.max(0, budget - natural)
        end
        local function share(total, weight_of, is_sink)
            local assigned, last = 0, nil
            for i = 1, n do if is_sink(i) then last = i end end
            for i = 1, n do
                if is_sink(i) then
                    local e = i == last and (total - assigned) or math.floor(total * weight_of(i))
                    assigned = assigned + e
                    est[i] = est[i] + e
                end
            end
        end
        if surplus > 0 then
            -- Grow: natural sizes plus the spare height on the movable rows.
            share(surplus, function(i) return caps[i] / sink_caps end,
                function(i) return elastic[i] and i > 1 end)
        else
            -- Shrink: the elastic rows split what is left by preferred height.
            for i = 1, n do if elastic[i] then est[i] = 0 end end
            share(budget, function(i) return caps[i] / elastic_caps end,
                function(i) return elastic[i] end)
        end
    end

    -- Blank space around each content box: margins take M - page_pad, each
    -- inner boundary shares G - gap, never below the structural paddings.
    local a, b = {}, {}
    a[1] = fills(1) and pt[1] or (M1 - page_pad)
    b[n] = fills(n) and pb[n] or (M2 - page_pad)
    for i = 1, n - 1 do
        if fills(i) and fills(i + 1) then
            b[i], a[i + 1] = pb[i], pt[i + 1]
        elseif fills(i) then
            b[i] = pb[i]
            a[i + 1] = G - gap - pb[i]
        elseif fills(i + 1) then
            a[i + 1] = pt[i + 1]
            b[i] = G - gap - pt[i + 1]
        else
            local extra = (G - gap) - pb[i] - pt[i + 1]
            b[i] = pb[i] + math.floor(extra / 2)
            a[i + 1] = pt[i + 1] + extra - math.floor(extra / 2)
        end
        if b[i] < pb[i] or a[i + 1] < pt[i + 1] then return nil end
    end
    if a[1] < pt[1] or b[n] < pb[n] then return nil end

    local heights = {}
    local used = gap * (n - 1)
    for i = 1, n do
        heights[i] = a[i] + est[i] + b[i]
        used = used + heights[i]
    end
    -- Rounding remainder: an elastic row absorbs it, else the bottom margin.
    local rem = body_h - used
    if rem ~= 0 then
        local target
        for i = 1, n do if elastic[i] then target = i; break end end
        if not target then target = n; b[n] = b[n] + rem end
        heights[target] = heights[target] + rem
        if heights[target] < 1 then return nil end
    end
    return { heights = heights, content_top = a, gap = G, margin_top = M1, margin_bottom = M2 }
end

function M.equalSpacingShifts(items, options)
    local count = #(items or {})
    if count < 2 then return {} end

    local function configured_shift_bounds(item)
        local first = item.min_shift or 0
        local second = item.max_shift or 0
        return math.min(first, second), math.max(first, second)
    end

    local pinned_last_shift
    if type(options) == "table" and type(options.bottom) == "number" then
        local last = items[count]
        local min_shift, max_shift = configured_shift_bounds(last)
        pinned_last_shift = math.floor(options.bottom
            - (last.row_y or 0) - (last.bottom or 0) + 0.5)
        pinned_last_shift = math.max(min_shift,
            math.min(max_shift, pinned_last_shift))
    end

    local function shift_bounds(item, index)
        if pinned_last_shift ~= nil and index == count then
            return pinned_last_shift, pinned_last_shift
        end
        return configured_shift_bounds(item)
    end

    local base_gaps = {}
    local max_gap = 0
    for i = 1, count - 1 do
        local current = items[i]
        local following = items[i + 1]
        local gap = (following.row_y or 0) + (following.top or 0)
            - (current.row_y or 0) - (current.bottom or 0)
        base_gaps[i] = gap
        max_gap = math.max(max_gap, gap)
    end
    for i, item in ipairs(items) do
        local min_shift, max_shift = shift_bounds(item, i)
        max_gap = max_gap
            + max_shift - min_shift
    end
    max_gap = math.floor(max_gap + math.abs(pinned_last_shift or 0))

    local best_shifts
    local best_cost
    for target_gap = 0, max_gap do
        local offsets = { 0 }
        local sum_offsets = 0
        for i = 1, count - 1 do
            offsets[i + 1] = offsets[i] + target_gap - base_gaps[i]
            sum_offsets = sum_offsets + offsets[i + 1]
        end

        local lower = -math.huge
        local upper = math.huge
        for i = 1, count do
            local min_shift, max_shift = shift_bounds(items[i], i)
            lower = math.max(lower, min_shift - offsets[i])
            upper = math.min(upper, max_shift - offsets[i])
        end
        if lower <= upper then
            local anchor = math.floor(-sum_offsets / count + 0.5)
            anchor = math.max(lower, math.min(upper, anchor))
            local shifts = {}
            local cost = 0
            for i = 1, count do
                shifts[i] = anchor + offsets[i]
                cost = cost + (items[i].shift_weight or 1) * shifts[i] * shifts[i]
            end
            if best_cost == nil or cost < best_cost then
                best_cost = cost
                best_shifts = shifts
            end
        end
    end
    if best_shifts then return best_shifts end

    local shifts = {}
    for i, item in ipairs(items) do
        local min_shift, max_shift = shift_bounds(item, i)
        shifts[i] = math.max(min_shift, math.min(max_shift, 0))
    end

    local function score()
        local gaps = {}
        local overlap = 0
        for i = 1, count - 1 do
            gaps[i] = base_gaps[i] + shifts[i + 1] - shifts[i]
            if gaps[i] < 0 then overlap = overlap + gaps[i] * gaps[i] end
        end
        local variance = 0
        for i = 1, #gaps do
            for j = i + 1, #gaps do
                local delta = gaps[i] - gaps[j]
                variance = variance + delta * delta
            end
        end
        local movement = 0
        for i, shift in ipairs(shifts) do
            movement = movement + (items[i].shift_weight or 1) * shift * shift
        end
        return overlap, variance, movement
    end

    local function improves(overlap, variance, movement, best_overlap, best_variance, best_movement)
        return overlap < best_overlap
            or overlap == best_overlap and variance < best_variance
            or overlap == best_overlap and variance == best_variance and movement < best_movement
    end

    for _pass = 1, 20 do
        local changed = false
        for i, item in ipairs(items) do
            local min_shift, max_shift = shift_bounds(item, i)
            min_shift = math.ceil(min_shift)
            max_shift = math.floor(max_shift)
            local original = shifts[i]
            local best = original
            local best_overlap, best_variance, best_movement = score()
            for candidate = min_shift, max_shift do
                shifts[i] = candidate
                local overlap, variance, movement = score()
                if improves(overlap, variance, movement,
                        best_overlap, best_variance, best_movement) then
                    best = candidate
                    best_overlap, best_variance, best_movement = overlap, variance, movement
                end
            end
            shifts[i] = best
            if best ~= original then changed = true end
        end
        if not changed then break end
    end
    local overlap = score()
    if overlap > 0 and pinned_last_shift ~= nil then
        return M.equalSpacingShifts(items)
    end
    return shifts
end

function M.list()
    local components = {}
    for _i, comp in ipairs(builtin_components) do
        components[#components + 1] = comp
    end

    local external_ids = {}
    for id in pairs(external_by_id) do
        external_ids[#external_ids + 1] = id
    end
    table.sort(external_ids)
    for _i, id in ipairs(external_ids) do
        components[#components + 1] = external_by_id[id]
    end
    return components
end

function M.get(id)
    return builtin_by_id[id] or external_by_id[id]
end

function M.normalizeRows(rows, default_order, default_enabled)
    rows = type(rows) == "table" and rows or {}
    default_order = type(default_order) == "table" and default_order or {}
    default_enabled = type(default_enabled) == "table" and default_enabled or {}

    local order = {}
    local seen = {}
    for _i, id in ipairs(type(rows.order) == "table" and rows.order or {}) do
        if type(id) == "string" and id ~= "" and not seen[id] then
            order[#order + 1] = id
            seen[id] = true
        end
    end

    local enabled = {}
    local has_enabled = false
    for id, value in pairs(type(rows.enabled) == "table" and rows.enabled or {}) do
        if type(id) == "string" and id ~= "" then
            enabled[id] = value == true
            if value == true then has_enabled = true end
        end
    end
    if not has_enabled then
        for id, value in pairs(default_enabled) do
            enabled[id] = value == true
        end
    end
    local components = M.list()
    for _i, comp in ipairs(components) do
        if enabled[comp.id] == nil then enabled[comp.id] = false end
    end

    for _i, id in ipairs(default_order) do
        if type(id) == "string" and id ~= "" and not seen[id] then
            order[#order + 1] = id
            seen[id] = true
        end
    end
    for _i, comp in ipairs(components) do
        if not seen[comp.id] then
            order[#order + 1] = comp.id
            seen[comp.id] = true
        end
    end

    local dormant_ids = {}
    for id in pairs(enabled) do
        if not seen[id] then dormant_ids[#dormant_ids + 1] = id end
    end
    table.sort(dormant_ids)
    for _i, id in ipairs(dormant_ids) do
        order[#order + 1] = id
    end

    rows.order = order
    rows.enabled = enabled
    rows.max_rows = nil
    rows.capacity_units = M.CAPACITY_UNITS
    return rows
end

local function refresh()
    if refresh_callback then
        pcall(refresh_callback)
    end
end

-- build(ctx) receives width, height, is_first_row, and module_cfg.
function M.register(id, build, opts)
    if type(id) ~= "string" or id == "" or type(build) ~= "function"
            or builtin_by_id[id] then
        return false
    end
    opts = type(opts) == "table" and opts or {}
    external_by_id[id] = {
        id = id,
        label = type(opts.label) == "string" and opts.label or id,
        size = (type(opts.size) == "table" or type(opts.size) == "string"
            or type(opts.size) == "number") and opts.size or nil,
        build = build,
    }
    refresh()
    return true
end

function M.unregister(id)
    if external_by_id[id] == nil then return end
    external_by_id[id] = nil
    refresh()
end

function M.setRefreshCallback(callback)
    refresh_callback = type(callback) == "function" and callback or nil
end

function M.install()
    rawset(_G, "__ZENOS_REGISTER_HOME_ITEM", M.register)
    rawset(_G, "__ZENOS_UNREGISTER_HOME_ITEM", M.unregister)
    rawset(_G, "__ZEN_UI_REGISTER_HOME_ITEM", M.register)
    rawset(_G, "__ZEN_UI_UNREGISTER_HOME_ITEM", M.unregister)
end

return M
