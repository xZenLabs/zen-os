local function apply_status_bar()
    -- Custom status bar for the KOReader File Manager title row.

    local BD = require("ui/bidi")
    local Device = require("device")
    local FileManager = require("apps/filemanager/filemanager")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local NetworkMgr = require("ui/network/manager")
    local OverlapGroup = require("ui/widget/overlapgroup")
    local RightContainer = require("ui/widget/container/rightcontainer")
    local TextWidget = require("ui/widget/textwidget")
    local ColorTextWidget = require("common/ui/color_text_widget")
    local UIManager = require("ui/uimanager")
    local Screen = Device.screen
    local Blitbuffer = require("ffi/blitbuffer")
    local LineWidget = require("ui/widget/linewidget")
    local Size = require("ui/size")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local clock_timer = require("common/clock_timer")
    local DateFormat = require("common/date_format")
    local library_font = require("modules/filebrowser/patches/library_font")
    local utils = require("common/utils")
    local paths = require("common/paths")
    local SharedState = require("common/shared_state")
    local status_bar_registry = require("common/status_bar_registry")
    local Background = require("common/ui/background")
    local Bluetooth = require("common/bluetooth")
    local inline_icons = require("common/inline_icon_map")
    local _ = require("gettext")

    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if not zen_plugin or type(zen_plugin.config) ~= "table" then
        return
    end

    local function is_enabled()
        return true
    end

    -- === Persistent config ===

    -- Separator values (bar-specific spacing; labels live in common/constants.lua)
    local SEP_VALUES = {
        dot             = "  \xC2\xB7  ",
        bar             = "  |  ",
        dash            = "  -  ",
        bullet          = "  \xE2\x80\xA2  ",
        space           = "   ",
        ["small-space"] = " ",
        none            = "",
    }

    local function getRegistryFetcher(key)
        local entry = status_bar_registry.get(key)
        return type(entry) == "table" and entry.fetch or nil
    end

    local config_default = {
        custom_text = "",  -- shown by the "custom_text" item; empty = device model name
        separator_key = "dot",
        custom_separator = "  ",
        left_order   = { "time" },
        center_order = {},
        right_order  = { "wifi", "battery" },
        date_format = "short",
        show_bottom_border = true,
        colored = false,
        bold_text = false,
        wifi_hide_when_off = false,
        hide_browser_bar = true,
    }

    local logger = require("common/zen_logger").new("status_bar")

    local function _serializeOrder(t)
        if type(t) ~= "table" then return tostring(t) end
        return "{" .. table.concat(t, ", ") .. "}"
    end

    local function loadConfig()
        local config = zen_plugin.config.status_bar or {}
        logger.dbg("loadConfig raw: left_order=",
            _serializeOrder(config.left_order),
            "center_order=", _serializeOrder(config.center_order),
            "right_order=",  _serializeOrder(config.right_order))
        -- Migration: convert old show/order/show_time format to left_order/right_order
        if config.left_order == nil and config.right_order == nil then
            logger.info("migrating legacy status bar config to left/center/right order")
            local old_order = type(config.order) == "table" and config.order
                              or { "wifi", "disk", "ram", "frontlight", "battery" }
            local old_show  = type(config.show) == "table" and config.show or {}
            local migrated_right = {}
            for _i, key in ipairs(old_order) do
                if old_show[key] ~= false then
                    table.insert(migrated_right, key)
                end
            end
            if config.show_time ~= false then
                local tpos = config.time_position or "center"
                if tpos == "right" then
                    config.left_order   = {}
                    config.center_order = {}
                    table.insert(migrated_right, 1, "time")
                    config.right_order  = migrated_right
                elseif tpos == "center" then
                    config.left_order   = {}
                    config.center_order = { "time" }
                    config.right_order  = migrated_right
                else
                    config.left_order   = { "time" }
                    config.center_order = {}
                    config.right_order  = migrated_right
                end
            else
                config.left_order   = {}
                config.center_order = {}
                config.right_order  = migrated_right
            end
        end
        -- Merge scalar defaults
        for k, v in pairs(config_default) do
            if config[k] == nil then
                logger.dbg("merging default for nil key:", k,
                    "->", type(v) == "table" and _serializeOrder(v) or tostring(v))
                config[k] = utils.deepcopy(v)
            end
        end
        logger.dbg("post-defaults: left_order=",
            _serializeOrder(config.left_order),
            "center_order=", _serializeOrder(config.center_order),
            "right_order=",  _serializeOrder(config.right_order))
        -- Preserve dormant external keys: their plugins may register after ZenOS.
        local seen = {}
        local function clean_order(list, side_name)
            local out = {}
            for _i, v in ipairs(type(list) == "table" and list or {}) do
                if type(v) ~= "string" or v == "" then
                    logger.warn("dropping invalid item on", side_name, ":", tostring(v))
                elseif seen[v] then
                    logger.warn("dropping duplicate item across sides:", tostring(v), "on", side_name)
                else
                    seen[v] = true
                    table.insert(out, v)
                end
            end
            return out
        end
        config.left_order   = clean_order(config.left_order, "left_order")
        config.center_order = clean_order(config.center_order, "center_order")
        config.right_order  = clean_order(config.right_order, "right_order")
        logger.dbg("final: left_order=",
            _serializeOrder(config.left_order),
            "center_order=", _serializeOrder(config.center_order),
            "right_order=",  _serializeOrder(config.right_order))
        zen_plugin.config.status_bar = config
        return config
    end

    local config = loadConfig()

    local function getSeparator()
        if config.separator_key == "custom" then
            return config.custom_separator or "  "
        end
        return SEP_VALUES[config.separator_key] or "  \xC2\xB7  "
    end

    -- === Layout constants ===

    local function isUIMagnified()
        local ft = zen_plugin.config and zen_plugin.config.features
        local lc = zen_plugin.config and zen_plugin.config.lockdown
        return type(ft) == "table" and ft.lockdown_mode == true
            and type(lc) == "table" and lc.magnify_ui == true
    end

    local function getBarFont()
        local base = Font.sizemap and Font.sizemap["xx_smallinfofont"] or 18
        local size = isUIMagnified() and math.floor(base * 1.25 + 0.5) or nil
        if size then
            return library_font.getFace(size)
        end
        return library_font.getFace(base)
    end

    -- Returns a bold TextWidget that shrinks font size before truncating.
    -- Tries each step in `shrink_steps` pt below the base face; applies
    -- max_width (with ellipsis) only when even the smallest size is still too wide.
    -- The center title only changes on path changes; memoize it so the
    -- per-minute tick and focus-move rebuilds don't re-probe font sizes for an
    -- identical string (each probe is a Harfbuzz shape of the full title).
    local _fit_text_key = nil
    local _fit_text_widget = nil
    local function fitTextWidget(text, max_width)
        local base_face = getBarFont()
        local key = text .. "\0" .. max_width .. "\0" .. (base_face.orig_size or base_face.size)
        if _fit_text_key == key and _fit_text_widget then
            return _fit_text_widget
        end
        local base_size = base_face.orig_size or base_face.size or 14
        local min_size  = math.max(10, base_size - 4)
        local size = base_size
        local widget
        while size >= min_size do
            local face  = library_font.getFace(size)
            local probe = TextWidget:new{ text = text, face = face, bold = true }
            local w = probe:getSize().w
            probe:free()
            if w <= max_width then
                widget = TextWidget:new{ text = text, face = face, bold = true }
                break
            end
            size = size - 1
        end
        -- Still too wide at minimum size: truncate.
        if not widget then
            widget = TextWidget:new{
                text = text,
                face = library_font.getFace(min_size),
                bold = true,
                max_width = max_width,
            }
        end
        _fit_text_key = key
        _fit_text_widget = widget
        return widget
    end
    local h_padding = Screen:scaleBySize(10)

    -- Builds the far-left back chevron. KOReader's Button flattens its icon
    -- against an opaque white tile at render time (IconWidget alpha=false), which
    -- leaves a white box around the chevron when a library background is showing.
    -- Force the icon to keep its alpha channel and drop the frame's white fill so
    -- the background paints through.
    -- Back chevron only depends on icon size; memoize it and swap the
    -- callback on reuse (the callback captures the per-call path).
    local _back_btn_icon_size = nil
    local _back_btn_widget = nil
    local function makeBackButton(icon_size, callback)
        if _back_btn_icon_size == icon_size and _back_btn_widget then
            _back_btn_widget.callback = callback or function() end
            return _back_btn_widget
        end
        local Button = require("ui/widget/button")
        local back_widget = Button:new{
            icon        = "chevron.left",
            icon_width  = icon_size,
            icon_height = icon_size,
            bordersize  = 0,
            padding     = 0,
            callback    = callback or function() end,
        }
        local lw = back_widget.label_widget
        if lw then
            lw.alpha = true
            lw:free()  -- drop the flattened (white-baked) bb so it re-renders with alpha
        end
        if back_widget.frame then
            back_widget.frame.background = nil
        end
        -- KOReader's stock flash_ui feedback repaints the button through the
        -- widget stack, filling the titlebar white (the library background is
        -- only painted by our repaintTitleBar) and leaving a white/inverted box
        -- around the transparent chevron. Drop the tap feedback entirely so the
        -- background stays untouched.
        back_widget._doFeedbackHighlight = function() end
        back_widget._undoFeedbackHighlight = function() end
        _back_btn_icon_size = icon_size
        _back_btn_widget = back_widget
        return back_widget
    end

    -- Disk free space cache
    local cached_disk_text = nil
    local cached_disk_time = 0
    -- RAM usage cache
    local cached_ram_text = nil
    local cached_ram_time = 0

    -- === Color definitions ===

    local colors = {
        wifi_on = Blitbuffer.ColorRGB32(0x33, 0x99, 0xFF, 0xFF),     -- blue
        wifi_searching = Blitbuffer.COLOR_DARK_GRAY,
        wifi_off = Blitbuffer.ColorRGB32(0xDD, 0x33, 0x33, 0xFF),   -- red
        disk = Blitbuffer.ColorRGB32(0x33, 0xAA, 0x55, 0xFF),       -- green
        ram = Blitbuffer.ColorRGB32(0x33, 0xAA, 0x55, 0xFF),        -- green
        frontlight = Blitbuffer.ColorRGB32(0xFF, 0xAA, 0x00, 0xFF), -- amber
        battery_high = Blitbuffer.ColorRGB32(0x33, 0xAA, 0x55, 0xFF),   -- green
        battery_mid = Blitbuffer.ColorRGB32(0xFF, 0xAA, 0x00, 0xFF),    -- yellow/amber
        battery_low = Blitbuffer.ColorRGB32(0xDD, 0x33, 0x33, 0xFF),    -- red
    }

    -- === Data fetching functions (return icon, label, color) ===

    local function getDeviceName()
        if config.custom_text and config.custom_text ~= "" then
            return config.custom_text
        end
        return Device.model or "KOReader"
    end

    local function getWifiInfo()
        if NetworkMgr:isWifiOn() then
            -- Gate on isConnected() (has IP), the same signal that fires
            -- NetworkConnected -> onNetworkConnected -> status bar refresh.
            -- ssid presence lags/mismatches that event, leaving a stuck gray icon.
            if NetworkMgr:isConnected() then
                return "\u{ECA8}", nil, colors.wifi_on
            end
            return "\u{ECA8}", nil, colors.wifi_searching, nil, true
        elseif not config.wifi_hide_when_off then
            return "\u{ECA9}", nil, colors.wifi_off
        end
        return nil
    end

    local function getBluetoothInfo()
        local enabled = Bluetooth.getState()
        if enabled == nil then return nil end
        if enabled then
            return inline_icons.bluetooth_on, nil, colors.wifi_on
        end
        return nil
    end

    local function getIncognitoInfo()
        local features = zen_plugin.config and zen_plugin.config.features
        if type(features) == "table" and features.incognito_mode == true then
            return inline_icons.incognito
        end
        return nil
    end

    local function getRamInfo()
        local now = os.time()
        if cached_ram_text and (now - cached_ram_time) < 30 then
            return "\u{EA5A}", " " .. cached_ram_text, colors.ram
        end
        local statm = io.open("/proc/self/statm", "r")
        if statm then
            local _, rss = statm:read("*number", "*number")
            statm:close()
            if rss then
                cached_ram_text = string.format("%dM", math.floor(rss / 256))
                cached_ram_time = now
                return "\u{EA5A}", " " .. cached_ram_text, colors.ram
            end
        end
        return "\u{EA5A}", " ?M", colors.ram
    end

    local function getDiskInfo()
        local now = os.time()
        if cached_disk_text and (now - cached_disk_time) < 300 then
            return "\u{F0A0}", " " .. cached_disk_text, colors.disk
        end
        -- Use the home_dir KOReader is actually browsing, then common fallbacks.
        local home_dir = paths.getHomeDir()
        local search_paths = {}
        if home_dir and home_dir ~= "" then
            table.insert(search_paths, home_dir)
        end
        for _i, p in ipairs({ "/mnt/us", "/mnt/onboard", "/sdcard", "/" }) do
            table.insert(search_paths, p)
        end
        for _i, spath in ipairs(search_paths) do
            local pipe = io.popen("df -h " .. spath .. " 2>/dev/null")
            if pipe then
                for line in pipe:lines() do
                    local avail = line:match("%S+%s+%S+%s+%S+%s+(%S+)")
                    -- Only accept lines where the available field starts with a digit
                    if avail and avail:match("^%d") then
                        pipe:close()
                        cached_disk_text = avail
                        cached_disk_time = now
                        return "\u{F0A0}", " " .. avail, colors.disk
                    end
                end
                pipe:close()
            end
        end
        return "\u{F0A0}", " ?", colors.disk
    end

    local function getFrontlightInfo()
        local powerd = Device:getPowerDevice()
        if powerd:isFrontlightOn() then
            return "☼", string.format(" %d", powerd:frontlightIntensity()), colors.frontlight
        else
            return "☼", " " .. _("Off"), colors.frontlight
        end
    end

    local function getBatteryInfo()
        if Device:hasBattery() then
            local powerd = Device:getPowerDevice()
            local batt_lvl = powerd:getCapacity()
            local batt_symbol = powerd:getBatterySymbol(
                powerd:isCharged(), powerd:isCharging(), batt_lvl)
            local color
            if batt_lvl >= 50 then
                color = colors.battery_high
            elseif batt_lvl >= 20 then
                color = colors.battery_mid
            else
                color = colors.battery_low
            end
            return BD.wrap(batt_symbol), batt_lvl .. "%", color
        end
        return nil
    end

    local function getTimeInfo()
        local twelve_hour = G_reader_settings:isTrue("twelve_hour_clock")
        local fmt = twelve_hour and "%I:%M %p" or "%H:%M"
        local time_str = os.date(fmt)
        if twelve_hour then
            time_str = time_str:gsub("^0(%d:)", "%1")
        end
        return time_str, nil, nil
    end

    local function getDateInfo()
        return DateFormat.format(config.date_format), nil, nil
    end

    local function getCustomTextInfo()
        local text = (config.custom_text ~= nil and config.custom_text ~= "")
                     and config.custom_text or getDeviceName()
        return (text ~= "") and text or nil, nil, nil
    end

    -- === Item registry ===

    local item_fetchers = {
        bluetooth   = getBluetoothInfo,
        incognito   = getIncognitoInfo,
        wifi        = getWifiInfo,
        disk        = getDiskInfo,
        ram         = getRamInfo,
        frontlight  = getFrontlightInfo,
        battery     = getBatteryInfo,
        time        = getTimeInfo,
        date        = getDateInfo,
        custom_text = getCustomTextInfo,
    }

    -- === Build the status row ===

    -- Converts an ordered list of item keys into a HorizontalGroup widget.
    -- Module-level so it can be used by both createStatusRow and buildStatusRow.
    -- face: optional Font face override; falls back to getBarFont().
    local function _buildGroup(order, face, bold_override)
        local group     = HorizontalGroup:new{}
        local sep       = getSeparator()
        local use_color = config.colored
        local bold      = bold_override ~= nil and bold_override or config.bold_text or false
        local first     = true
        local function f() return face or getBarFont() end
        local function iconFace()
            local text_face = f()
            local size = text_face.orig_size or text_face.size or 14
            return Font:getFace("nerdfonts/symbols.ttf", size)
                or Font:getFace("SymbolsNerdFont-Regular.ttf", size)
                or text_face
        end
        for _i, key in ipairs(order) do
            local builtin = item_fetchers[key]
            local fn = builtin or getRegistryFetcher(key)
            if fn then
                local icon, label, color, icon_image, force_color
                if builtin then
                    icon, label, color, icon_image, force_color = fn()
                else
                    -- External fetchers are untrusted; a throw must not break the bar.
                    local ok, a, b, c, d = pcall(fn)
                    if ok then icon, label, color, icon_image = a, b, c, d end
                end
                local effective_color = color and (use_color or force_color) and color or nil
                local has_icon = icon ~= nil and icon ~= ""
                local has_label = label ~= nil and label ~= ""
                if has_icon or has_label then
                    if not first and sep ~= "" then
                        table.insert(group, TextWidget:new{ text = sep, face = f(), bold = bold })
                    end
                    if not builtin and has_icon then
                        local widget_class = effective_color and ColorTextWidget or TextWidget
                        local icon_opts = {
                            text = icon, face = iconFace(), bold = bold,
                        }
                        if effective_color then icon_opts.fgcolor = effective_color end

                        local ImageWidget = require("ui/widget/imagewidget")
                        table.insert(group, icon_image and ImageWidget:new {
                            file = icon,
                            width = Screen:scaleBySize(f().size * 1.5),
                            height = Screen:scaleBySize(f().size * 1.5),
                            alpha = true, is_icon = true
                        } or widget_class:new(icon_opts))
                        if has_label then
                            table.insert(group, TextWidget:new{ text = label, face = f(), bold = bold })
                        end
                    elseif effective_color and has_icon then
                        local ImageWidget = require("ui/widget/imagewidget")
                        table.insert(group, icon_image and ImageWidget:new {
                            file = icon,
                            width = Screen:scaleBySize(f().size * 1.5),
                            height = Screen:scaleBySize(f().size * 1.5),
                            alpha = true, is_icon = true
                        } or ColorTextWidget:new {
                            text = icon, face = f(), fgcolor = effective_color, bold = bold,
                        })
                        if has_label then
                            table.insert(group, TextWidget:new{ text = label, face = f(), bold = bold })
                        end
                    elseif has_icon then
                        local text = has_label and (icon .. label) or icon
                        table.insert(group, TextWidget:new{ text = text, face = f(), bold = bold })
                    else
                        table.insert(group, TextWidget:new{ text = label, face = f(), bold = bold })
                    end
                    first = false
                end
            end
        end
        return #group > 0 and group or nil
    end

    local function normalizeDirPath(path)
        if type(path) ~= "string" or path == "" then return nil end
        path = paths.normPath(path)
        if path ~= "/" then path = path:gsub("/+$", "") end
        return path ~= "" and path or "/"
    end

    local function clearRestoredItemFocus(file_chooser)
        local features = zen_plugin.config and zen_plugin.config.features
        if type(features) ~= "table" or features.browser_hide_underline ~= true then return end

        file_chooser.itemnumber = nil
        file_chooser.prev_itemnumber = nil
        local selected = file_chooser.selected
        local row = selected and file_chooser.layout and file_chooser.layout[selected.y]
        local item = row and row[selected.x]
        if item and type(item.onUnfocus) == "function" then
            item:onUnfocus()
        end
    end

    local function createStatusRow(path, file_manager, nav_title)
        local CenterContainer = require("ui/widget/container/centercontainer")

        -- Detect whether we are inside a subfolder of, or at, the home directory
        local in_subfolder = false
        local folder_name = nil
        local home_dir = paths.getHomeDir()
        local norm_path = normalizeDirPath(path)
        if home_dir and path then
            if norm_path ~= home_dir and norm_path:sub(1, #home_dir + 1) == home_dir .. "/" then
                in_subfolder = true
                folder_name = path:match("([^/]+)/?$") or path
            end
        end

        -- Virtual series folders keep file_chooser.path at the parent dir, so the
        -- subfolder check above misses them. Treat being in a series view as a
        -- subfolder so the back chevron always shows and can exit the group.
        local item_table = file_manager and file_manager.file_chooser
            and file_manager.file_chooser.item_table
        local in_series_view = item_table and item_table.is_in_series_view == true
        if in_series_view then
            in_subfolder = true
        end

        local home_locked = paths.isHomeLocked()
        local features = zen_plugin.config.features
        local navbar = zen_plugin.config.navbar
        local folder_root = type(navbar) == "table"
            and normalizeDirPath(navbar.folder_path) or nil
        local at_folder_tab_root = type(features) == "table" and features.navbar == true
            and type(navbar) == "table"
            and type(navbar.show_tabs) == "table"
            and navbar.show_tabs.folder == true
            and folder_root ~= nil and folder_root ~= ""
            and norm_path == folder_root
            and not in_series_view

        -- Show back in subfolders, but treat the configured Folder tab path as its root.
        -- path must be non-nil — callers like collections pass nil for non-filesystem views.
        local show_back = path ~= nil and not at_folder_tab_root
            and (in_subfolder or not home_locked)

        -- Back chevron is always pinned to the far-left when navigation is available
        local back_widget = nil
        local back_callback = nil
        local icon_size = Screen:scaleBySize(isUIMagnified() and 35 or 28)  -- 28 * 1.25 = 35
        if show_back then
            local ffiUtil = require("ffi/util")
            back_callback = function()
                local file_chooser = file_manager and file_manager.file_chooser
                if file_chooser and file_chooser.onFolderUp then
                    UIManager:scheduleIn(0.1, function()
                        if file_manager.file_chooser then
                            local active_chooser = file_manager.file_chooser
                            active_chooser:onFolderUp()
                            clearRestoredItemFocus(active_chooser)
                        end
                    end)
                    return
                end

                local parent = ffiUtil.dirname(path)
                if file_chooser and parent then
                    -- Defer the path change to avoid button dimen crash during feedback highlight
                    UIManager:scheduleIn(0.1, function()
                        if file_manager.file_chooser then
                            file_manager.file_chooser:changeToPath(parent)
                        end
                    end)
                end
            end
            back_widget = makeBackButton(icon_size, back_callback)
        end

        local left_content  = _buildGroup(config.left_order   or {})
        local right_content = _buildGroup(config.right_order  or {})

        -- Row height = max of all present widgets
        local row_height = Screen:scaleBySize(18)
        local function updateRowHeight(w)
            if w then
                local sz = w:getSize()
                if sz and sz.h > row_height then row_height = sz.h end
            end
        end
        updateRowHeight(back_widget)
        updateRowHeight(left_content)
        updateRowHeight(right_content)

        local screen_w    = Screen:getWidth()
        local inner_w     = screen_w - h_padding * 2
        local chevron_gap = Screen:scaleBySize(6)

        -- Left zone: h_padding + [chevron] + [gap] + [left_content]
        local left_group = HorizontalGroup:new{}
        table.insert(left_group, HorizontalSpan:new{ width = h_padding })
        if back_widget then
            table.insert(left_group, back_widget)
            if left_content then
                table.insert(left_group, HorizontalSpan:new{ width = chevron_gap })
            end
        end
        if left_content then
            table.insert(left_group, left_content)
        end

        -- Right zone width: right_content + h_padding
        local right_w = h_padding
            + (right_content and right_content:getSize().w or 0)

        -- Center max_width: ensure the centered text never overlaps left or right.
        -- The text is centered on screen, so it can extend at most
        -- (screen_w/2 - side_w) on each side. Take the tighter of the two sides,
        -- then double it for the full available span.
        local left_w = left_group:getSize().w
        local half_avail = math.floor(screen_w / 2) - math.max(left_w, right_w)
        local center_max_w = math.max(1, half_avail * 2)

        -- Center: nav_title override > folder name when in subfolder > configured center items
        local center_content
        if nav_title then
            center_content = fitTextWidget(nav_title, center_max_w)
        elseif in_subfolder and folder_name then
            center_content = fitTextWidget(folder_name, center_max_w)
        else
            center_content = _buildGroup(config.center_order or {})
        end

        updateRowHeight(center_content)

        local row = OverlapGroup:new{
            dimen = Geom:new{ w = screen_w, h = row_height },
            LeftContainer:new{
                dimen = Geom:new{ w = screen_w, h = row_height },
                left_group,
            },
        }

        if center_content then
            table.insert(row, CenterContainer:new{
                dimen = Geom:new{ w = screen_w, h = row_height },
                center_content,
            })
        end

        if right_content then
            table.insert(row, RightContainer:new{
                dimen = Geom:new{ w = screen_w, h = row_height },
                HorizontalGroup:new{
                    right_content,
                    HorizontalSpan:new{ width = h_padding },
                },
            })
        end

        -- Invisible overlay extending the back button's tap area below the status bar.
        if show_back and back_callback then
            local InputContainer = require("ui/widget/container/inputcontainer")
            local GestureRange = require("ui/gesturerange")
            local hitbox_extra = Screen:scaleBySize(30)
            local hitbox_w = Screen:scaleBySize(60)
            local hb_dimen = Geom:new{ w = hitbox_w, h = row_height + hitbox_extra }
            local back_hitbox = InputContainer:new{
                dimen = hb_dimen,
                ges_events = {
                    TapBack = { GestureRange:new{ ges = "tap", range = hb_dimen } },
                },
            }
            function back_hitbox:onTapBack() back_callback(); return true end
            table.insert(row, back_hitbox)
            -- Store zone so FileManager.handleEvent can intercept taps from below the title bar.
            if file_manager then
                file_manager._zen_back_tap_zone = { w = hitbox_w, h = row_height + hitbox_extra, callback = back_callback }
            end
        else
            if file_manager then file_manager._zen_back_tap_zone = nil end
        end

        if not config.show_bottom_border then
            return row
        end

        local border = LineWidget:new{
            dimen = Geom:new{ w = inner_w, h = Size.line.medium },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        }

        local vg = VerticalGroup:new{ align = "center", row }
        table.insert(vg, CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = Size.line.medium },
            border,
        })
        return vg
    end

    -- Builds a pure item row (no file-browser navigation) suitable for embedding in other panels.
    -- width: desired row width in pixels (e.g. the panel's inner_width).
    -- opts:  optional table with:
    --   padding   (number)  edge inset in pixels; defaults to h_padding
    --   font_name (string)  Font sizemap key, e.g. "x_smallinfofont"; defaults to "xx_smallinfofont"
    --   font_size_delta (number) adjusts the resolved font size
    --   bold_text (boolean) overrides the global status-bar bold setting
    --   show_bottom_border (boolean) defaults to false for embedded rows
    local function buildStatusRow(width, opts)
        opts = opts or {}
        local edge_pad = opts.padding ~= nil and opts.padding or h_padding
        local face
        if opts.font_name then
            local sized = Font.sizemap and Font.sizemap[opts.font_name]
            if sized then
                if type(opts.font_size_delta) == "number" then
                    sized = math.max(8, sized + opts.font_size_delta)
                end
                face = library_font.getFace(sized)
            end
        end
        if not face then face = getBarFont() end

        local left_content   = _buildGroup(config.left_order   or {}, face, opts.bold_text)
        local center_content = _buildGroup(config.center_order or {}, face, opts.bold_text)
        local right_content  = _buildGroup(config.right_order  or {}, face, opts.bold_text)

        local row_height = Screen:scaleBySize(opts.row_height or 16)
        local function upd(w)
            if w then local s = w:getSize(); if s and s.h > row_height then row_height = s.h end end
        end
        upd(left_content); upd(center_content); upd(right_content)

        local left_group = HorizontalGroup:new{}
        table.insert(left_group, HorizontalSpan:new{ width = edge_pad })
        if left_content then table.insert(left_group, left_content) end

        local row = OverlapGroup:new{
            dimen = Geom:new{ w = width, h = row_height },
            LeftContainer:new{
                dimen = Geom:new{ w = width, h = row_height },
                left_group,
            },
        }
        if center_content then
            local CenterContainer = require("ui/widget/container/centercontainer")
            table.insert(row, CenterContainer:new{
                dimen = Geom:new{ w = width, h = row_height },
                center_content,
            })
        end
        if right_content then
            table.insert(row, RightContainer:new{
                dimen = Geom:new{ w = width, h = row_height },
                HorizontalGroup:new{
                    right_content,
                    HorizontalSpan:new{ width = edge_pad },
                },
            })
        end
        if opts.show_bottom_border ~= true then
            return row
        end
        local border = LineWidget:new{
            dimen = Geom:new{ w = math.max(1, width - edge_pad * 2), h = Size.line.medium },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        }
        local CenterContainer = require("ui/widget/container/centercontainer")
        local vg = VerticalGroup:new{ align = "center", row }
        table.insert(vg, CenterContainer:new{
            dimen = Geom:new{ w = width, h = Size.line.medium },
            border,
        })
        return vg
    end

    rawset(_G, "__ZENOS_BUILD_STATUS_ROW", function(width, opts)
        opts = opts or {}
        if opts.show_bottom_border == nil then
            opts.show_bottom_border = config.show_bottom_border ~= false
        end
        return buildStatusRow(width, opts)
    end)

    local function topmost_non_toast_widget()
        local stack = UIManager._window_stack
        if type(stack) ~= "table" then return end
        for index = #stack, 1, -1 do
            local widget = stack[index] and stack[index].widget
            if widget and not widget.toast then return widget end
        end
    end

    -- Refresh TouchMenu panels from the shared minute heartbeat.
    local function schedulePanelRefresh(menu)
        if menu._zen_status_timer then
            clock_timer.unbind(menu)
        end
        local function tick(target)
            if not (target.item_table and target.item_table.panel) then
                target._zen_status_timer = nil
                clock_timer.unbind(target)
                return
            end
            if topmost_non_toast_widget() ~= target then return end
            target:updateItems()
        end
        menu._zen_status_timer = tick
        clock_timer.bind(menu, tick)
    end

    local function cancelPanelRefresh(menu)
        if menu._zen_status_timer then
            clock_timer.unbind(menu)
            menu._zen_status_timer = nil
        end
    end

    -- Builds a status row identical to createStatusRow but with a custom back
    -- button that always shows and calls back_callback when tapped.  Used by
    -- collections.lua for named-collection views so the chevron goes back to
    -- the collections list rather than navigating the filesystem.
    local function createStatusRowCustomBack(back_callback, title)
        local CenterContainer = require("ui/widget/container/centercontainer")
        local icon_size = Screen:scaleBySize(isUIMagnified() and 35 or 28)
        local back_widget = makeBackButton(icon_size, back_callback)
        local left_content   = _buildGroup(config.left_order   or {})
        local right_content  = _buildGroup(config.right_order  or {})

        local row_height = Screen:scaleBySize(18)
        local function updateRowHeight(w)
            if w then
                local sz = w:getSize()
                if sz and sz.h > row_height then row_height = sz.h end
            end
        end
        updateRowHeight(back_widget)
        updateRowHeight(left_content)
        updateRowHeight(right_content)

        local chevron_gap = Screen:scaleBySize(6)
        local screen_w    = Screen:getWidth()
        local inner_w     = screen_w - h_padding * 2

        -- Build left_group first so we can measure it for center_max_w.
        local left_group  = HorizontalGroup:new{}
        table.insert(left_group, HorizontalSpan:new{ width = h_padding })
        table.insert(left_group, back_widget)
        if left_content then
            table.insert(left_group, HorizontalSpan:new{ width = chevron_gap })
            table.insert(left_group, left_content)
        end

        local left_w  = left_group:getSize().w
        local right_w = h_padding + (right_content and right_content:getSize().w or 0)
        local half_avail = math.floor(screen_w / 2) - math.max(left_w, right_w)
        local center_max_w = math.max(1, half_avail * 2)

        local center_content
        if title then
            center_content = fitTextWidget(title, center_max_w)
        else
            center_content = _buildGroup(config.center_order or {})
        end
        updateRowHeight(center_content)

        local row = OverlapGroup:new{
            dimen = Geom:new{ w = screen_w, h = row_height },
            LeftContainer:new{
                dimen = Geom:new{ w = screen_w, h = row_height },
                left_group,
            },
        }
        if center_content then
            table.insert(row, CenterContainer:new{
                dimen = Geom:new{ w = screen_w, h = row_height },
                center_content,
            })
        end
        if right_content then
            table.insert(row, RightContainer:new{
                dimen = Geom:new{ w = screen_w, h = row_height },
                HorizontalGroup:new{
                    right_content,
                    HorizontalSpan:new{ width = h_padding },
                },
            })
        end

        -- Invisible overlay extending the back button's tap area below the status bar.
        if back_callback then
            local InputContainer = require("ui/widget/container/inputcontainer")
            local GestureRange = require("ui/gesturerange")
            local hitbox_extra = Screen:scaleBySize(30)
            local hitbox_w = Screen:scaleBySize(60)
            local hb_dimen = Geom:new{ w = hitbox_w, h = row_height + hitbox_extra }
            local back_hitbox = InputContainer:new{
                dimen = hb_dimen,
                ges_events = {
                    TapBack = { GestureRange:new{ ges = "tap", range = hb_dimen } },
                },
            }
            function back_hitbox:onTapBack() back_callback(); return true end
            table.insert(row, back_hitbox)
        end

        if not config.show_bottom_border then
            return row
        end
        local border = LineWidget:new{
            dimen      = Geom:new{ w = inner_w, h = Size.line.medium },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        }
        local vg = VerticalGroup:new{ align = "center", row }
        table.insert(vg, CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = Size.line.medium },
            border,
        })
        return vg
    end

    -- Safe repaint for a titlebar widget: clears the region to white first,
    -- then repaints the widget tree, then flushes to the e-ink display.
    -- Avoids overlap artifacts (VerticalGroup/OverlapGroup don't clear their
    -- background) and avoids the dithered-widget freeze (never marks the
    -- parent menu dirty).
    local function repaintTitleBar(tb)
        if not tb or not tb.dimen then return end
        local bb = Screen.bb
        if bb then
            local bg_path = Background.library_path(zen_plugin)
            if bg_path == "" or not Background.paintScreenRegion(bb,
                    tb.dimen.x, tb.dimen.y, tb.dimen.x, tb.dimen.y,
                    tb.dimen.w, tb.dimen.h, bg_path) then
                bb:paintRect(tb.dimen.x, tb.dimen.y, tb.dimen.w, tb.dimen.h, Blitbuffer.COLOR_WHITE)
            end
        end
        UIManager:widgetRepaint(tb, tb.dimen.x, tb.dimen.y)
        -- CoverBrowser paints library/group pages dithered (show_parent.dithered).
        -- A non-dithered "ui" refresh of this region renders whiter than the
        -- surrounding dithered page, leaving a brighter box. Honor the top
        -- widget's dithering hint so the region matches.
        local top_widget = topmost_non_toast_widget()
        local refresh_dither = top_widget and top_widget.dithered or nil
        UIManager:setDirty(nil, "ui", tb.dimen, refresh_dither)
    end

    -- Expose for cross-patch use. Stored on the plugin table so it is naturally
    -- scoped to when this feature is active and cleaned up on plugin reload.
    if type(zen_plugin) == "table" then
        local status_bar_api = {
            createStatusRow = createStatusRow,
            createStatusRowCustomBack = createStatusRowCustomBack,
            buildStatusRow = buildStatusRow,
            schedulePanelRefresh = schedulePanelRefresh,
            cancelPanelRefresh = cancelPanelRefresh,
            repaintTitleBar = repaintTitleBar,
            clockTimer = clock_timer,
        }
        local function register_status_bar_api(plugin)
            SharedState.register(plugin or zen_plugin, status_bar_api)
        end
        SharedState.registerLoader({
            "createStatusRow",
            "createStatusRowCustomBack",
            "buildStatusRow",
            "schedulePanelRefresh",
            "cancelPanelRefresh",
            "repaintTitleBar",
            "clockTimer",
        }, register_status_bar_api)
        register_status_bar_api(zen_plugin)
    end

    -- === Replace title content and reposition buttons ===

    -- Intercept taps in the back button zone before FileChooser consumes them.
    -- The hitbox in the OverlapGroup only works within the title bar's gesture area;
    -- taps in the extended zone (into the file list) are eaten by FileChooser first.
    do
        local orig_fm_handleEvent = FileManager.handleEvent
        FileManager.handleEvent = function(self_fm, event)
            if event.name == "Gesture" and is_enabled() and self_fm._zen_back_tap_zone then
                local ges_ev = event.args and event.args[1]
                if ges_ev and ges_ev.ges == "tap" then
                    local zone = self_fm._zen_back_tap_zone
                    local pos  = ges_ev.pos
                    if pos and pos.x >= 0 and pos.x < zone.w
                            and pos.y >= 0 and pos.y < zone.h then
                        zone.callback()
                        return true
                    end
                end
            end
            return orig_fm_handleEvent(self_fm, event)
        end
    end

    local function home_without_status_bar_is_on_top()
        local widget = topmost_non_toast_widget()
        return widget and widget._zen_home_show_status_bar == false
    end

    function FileManager:_updateStatusBar(no_repaint)
        if not is_enabled() or home_without_status_bar_is_on_top() then
            return
        end

        local tb = self.title_bar
        if not tb or not tb.title_group then return end

        local title_group = tb.title_group
        if #title_group < 2 then return end

        local current_path = self.file_chooser and self.file_chooser.path
        logger.dbg("_updateStatusBar: left=",
            _serializeOrder(config.left_order),
            "center=", _serializeOrder(config.center_order),
            "right=",  _serializeOrder(config.right_order))
        local status_row = createStatusRow(current_path, self)
        title_group[2] = status_row
        title_group:resetLayout()

        -- title_group: [1] VerticalSpan, [2] status_row, [3] VerticalSpan, [4] subtitle
        local subtitle_y = 0
        for i = 1, math.min(3, #title_group) do
            subtitle_y = subtitle_y + title_group[i]:getSize().h
        end

        local subtitle_h = 0
        if #title_group >= 4 then
            subtitle_h = title_group[4]:getSize().h
        end

        local area_h = tb.titlebar_height - subtitle_y
        local subtitle_center_y = subtitle_y + math.floor((area_h - subtitle_h) / 2)

        -- Center button icons with subtitle text
        local btn_padding = tb.button_padding
        local icon_h = tb.left_button and tb.left_button.width or 0
        local target_center = subtitle_center_y + math.floor(subtitle_h / 2)
        local button_y = target_center - btn_padding - math.floor(icon_h / 2)

        if tb.left_button then
            tb.left_button.overlap_align = nil
            tb.left_button.overlap_offset = {0, button_y}
        end
        if tb.right_button then
            local btn_w = tb.right_button:getSize().w
            tb.right_button.overlap_align = nil
            tb.right_button.overlap_offset = {tb.width - btn_w, button_y}
        end

        -- Center subtitle vertically in the area
        if #title_group >= 3 then
            local VerticalSpan = require("ui/widget/verticalspan")
            local status_row_bottom = 0
            for i = 1, 2 do
                status_row_bottom = status_row_bottom + title_group[i]:getSize().h
            end
            local new_padding = subtitle_center_y - status_row_bottom
            if new_padding > 0 then
                title_group[3] = VerticalSpan:new{ width = new_padding }
                title_group:resetLayout()
            end
        end

        local top_widget = topmost_non_toast_widget()
        if not no_repaint and FileManager.instance == self and self.invisible ~= true
                and (top_widget == self or top_widget == self.show_parent) then
            -- Clear the full titlebar region so stale pixels from a previously
            -- wider right-side group don't leave ghosts.
            repaintTitleBar(tb)
        end
    end

    -- === Hooks ===

    -- Holds the current autoRefresh callback so resume can rebind it after
    -- pausing the shared heartbeat during suspend.
    local _fm_autoRefresh = nil
    local rakuyomi_view_names = {
        chapter_listing = true,
        library_view = true,
    }

    local function suppresses_status_bar(widget)
        if not widget then return false end
        if rakuyomi_view_names[widget.name] == true then return true end
        if widget._zen_home_show_status_bar == false then
            -- Home page without a top status bar. Still allow event-driven
            -- refresh of an embedded featured status bar (or other clock-refresh
            -- widgets) so its Wi-Fi/battery indicators update on toggle.
            if widget._zen_home_refresh_clock_widgets
                    and widget._zen_home_has_clock_refreshers then
                return false
            end
            return true
        end
        return false
    end

    local function refreshVisibleStatusBar(fm, clock_tick)
        if FileManager.instance ~= fm then return end
        local top_widget = topmost_non_toast_widget()

        if suppresses_status_bar(top_widget) then return end
        if top_widget == fm or top_widget == fm.show_parent then
            fm:_updateStatusBar()
        elseif top_widget and top_widget._zen_status_refresh then
            if clock_tick and top_widget._zen_status_clock_bound then return end
            top_widget._zen_status_refresh(top_widget)
        elseif top_widget and top_widget._zen_home_refresh_clock_widgets then
            -- Featured embedded status bar: no _zen_status_refresh, refreshes via
            -- its clock-widget refreshers instead. Skip clock ticks it handles
            -- through its own heartbeat binding to avoid a double refresh.
            if clock_tick and top_widget._zen_status_clock_bound then return end
            top_widget:_zen_home_refresh_clock_widgets()
        end
    end

    local show_refresh_pending = false
    local function scheduleShowStatusRefresh(fm)
        if not fm or show_refresh_pending then return end
        show_refresh_pending = true
        UIManager:nextTick(function()
            show_refresh_pending = false
            refreshVisibleStatusBar(fm, false)
        end)
    end

    local function has_refreshable_status_bar(widget, fm)
        return widget == fm
            or widget == fm.show_parent
            or widget._zen_status_refresh
            or widget._zen_home_refresh_clock_widgets
    end

    local Menu = require("ui/widget/menu")
    Menu._zen_status_bar_on_show_refresh = function(menu)
        local fm = FileManager.instance
        if fm and is_enabled() and has_refreshable_status_bar(menu, fm) then
            scheduleShowStatusRefresh(fm)
        end
    end
    if not Menu._zen_status_bar_on_show_patched then
        Menu._zen_status_bar_on_show_patched = true
        local orig_menu_onShow = Menu.onShow
        Menu.onShow = function(menu, ...)
            local result
            if orig_menu_onShow then
                result = orig_menu_onShow(menu, ...)
            end
            if Menu._zen_status_bar_on_show_refresh then
                Menu._zen_status_bar_on_show_refresh(menu)
            end
            return result
        end
    end

    local orig_setupLayout = FileManager.setupLayout

    function FileManager:setupLayout()
        if not is_enabled() then
            return orig_setupLayout(self)
        end

        if config.hide_browser_bar then
            -- Patch TitleBar constructor to suppress only the subtitle row and
            -- icon buttons.  Our custom status row (the title area) is kept so
            -- the height accounts for it and _updateStatusBar can still paint it.
            local TitleBar = require("ui/widget/titlebar")
            local orig_new = TitleBar.new
            TitleBar.new = function(cls, t)
                if type(t) == "table" then
                    t.subtitle            = nil
                    t.subtitle_truncate_left = nil
                    t.subtitle_fullwidth  = nil
                    t.left_icon           = nil
                    t.left_icon_tap_callback  = nil
                    t.left_icon_hold_callback = nil
                    t.right_icon          = nil
                    t.right_icon_tap_callback  = nil
                    t.right_icon_hold_callback = nil
                    t.title_tap_callback  = nil
                    t.title_hold_callback = nil
                    t.bottom_v_padding    = 0
                    -- Replace title text with a space so the slot has correct
                    -- height but shows nothing before _updateStatusBar paints
                    -- our custom row over it.
                    t.title               = " "
                end
                return orig_new(cls, t)
            end
            orig_setupLayout(self)
            TitleBar.new = orig_new
        else
            orig_setupLayout(self)
        end

        -- Build immediately so KOReader's queued layout paint shows our custom row.
        self:_updateStatusBar(true)

        -- Finish titlebar setup after all plugins (coverbrowser etc.) initialize.
        local fm = self
        UIManager:nextTick(function()
            -- Restore subtitle path only when subtitle widget exists
            if not config.hide_browser_bar and fm.file_chooser
                    and fm.file_chooser.path then
                fm:updateTitleBarPath(fm.file_chooser.path)
            end

            -- Disable page_info_text to prevent ghost search dialog when tapping title area
            if config.hide_browser_bar and fm.file_chooser then
                -- Completely hide page_info by collapsing its dimensions
                if fm.file_chooser.page_info then
                    fm.file_chooser.page_info.dimen = Geom:new{w = 0, h = 0}
                    -- Make it ignore all input
                    fm.file_chooser.page_info.handleEvent = function() return false end
                end
                -- Also disable the text button itself as extra safety
                if fm.file_chooser.page_info_text then
                    fm.file_chooser.page_info_text.readonly = true
                    fm.file_chooser.page_info_text.dimen = Geom:new{w = 0, h = 0}
                end
            end
        end)

        -- Periodic refresh for time/battery/disk. The shared heartbeat is
        -- minute-aligned and also drives home/group standalone pages.
        local function autoRefresh()
            refreshVisibleStatusBar(fm, true)
        end
        _fm_autoRefresh = autoRefresh
        clock_timer.subscribe("filemanager_status_bar", autoRefresh)
    end

    local orig_onPathChanged = FileManager.onPathChanged

    function FileManager:onPathChanged(path)
        if orig_onPathChanged then
            orig_onPathChanged(self, path)
        end
        if is_enabled() then
            -- Run synchronously so the titlebar update is included in the same
            -- paint cycle as updateItems' refresh.  Deferring to nextTick caused
            -- a second e-ink refresh (visible flash) and could leave ghost
            -- artifacts on the right edge when the two partial "ui" repaints
            -- didn't fully overlap.
            self:_updateStatusBar()
        end
    end

    local function chainHook(event_name)
        local orig = FileManager[event_name]
        FileManager[event_name] = function(self)
            if orig then orig(self) end
            if not is_enabled() then return end
            -- Only refresh the topmost widget.  If a screensaver, dialog, or
            -- TouchMenu is on top, skip — avoids painting behind overlays
            -- and into the sleep screen.
            refreshVisibleStatusBar(self, false)
        end
    end

    chainHook("onNetworkConnected")
    chainHook("onNetworkDisconnected")

    -- Charging events arrive in pairs during USB negotiation (NotCharging -> Charging)
    -- within a few seconds of each other.  A synchronous rebuild per-event causes
    -- multiple stacked e-ink partial refreshes and makes the device feel frozen.
    -- Debounce: coalesce all charging events into one refresh 1.5 s after the last one.
    local _charging_refresh_timer = nil
    local function scheduleChargingRefresh(fm)
        if _charging_refresh_timer then
            UIManager:unschedule(_charging_refresh_timer)
        end
        _charging_refresh_timer = function()
            _charging_refresh_timer = nil
            refreshVisibleStatusBar(fm, false)
        end
        UIManager:scheduleIn(1.5, _charging_refresh_timer)
    end

    do
        local function hookCharging(event_name)
            local orig = FileManager[event_name]
            FileManager[event_name] = function(self)
                if orig then orig(self) end
                if not is_enabled() then return end
                scheduleChargingRefresh(self)
            end
        end
        hookCharging("onCharging")
        hookCharging("onNotCharging")
    end

    -- Suspend: pause the shared heartbeat so it does not fire during sleep.
    -- Resume: do a visible refresh and restart it on the next minute boundary.
    local orig_onSuspend = FileManager.onSuspend
    FileManager.onSuspend = function(self)
        if orig_onSuspend then orig_onSuspend(self) end
        clock_timer.pause()
        -- Cancel any pending charging debounce so it doesn't paint into the screensaver.
        if _charging_refresh_timer then
            UIManager:unschedule(_charging_refresh_timer)
            _charging_refresh_timer = nil
        end
    end

    -- Refresh the filebrowser status bar whenever any TouchMenu closes
    -- (e.g. after changing settings, toggling night mode, etc.)
    -- Guard: skip if a fullscreen overlay (e.g. QuickstartScreen) is now on top.
    local TouchMenu = require("ui/widget/touchmenu")
    local orig_tm_close = TouchMenu.onCloseWidget
    TouchMenu.onCloseWidget = function(self_tm)
        if orig_tm_close then orig_tm_close(self_tm) end
        local fm = FileManager.instance
        if fm and is_enabled() then
            UIManager:nextTick(function()
                refreshVisibleStatusBar(fm, false)
            end)
        end
    end

    -- onResume: defer long enough for the screensaver to finish its full-screen
    -- repaint and for the titlebar layout to be fully established.  nextTick
    -- (one loop pass) is too fast — it races against the screensaver's flashui
    -- flush and can fire before paintTo has set correct layout geometry, which
    -- causes child widgets to render at offset (0,0) i.e. top-left.
    -- scheduleIn(0) ticks once more after all current events and repaints settle.
    -- The topmost-widget guard (same as autoRefresh) prevents painting during
    -- any modal that might still be on top.
    local orig_onResume = FileManager.onResume
    FileManager.onResume = function(self)
        if orig_onResume then orig_onResume(self) end
        if is_enabled() then
            local fm = self
            -- Refresh whichever bar is currently visible.  Two attempts because
            -- the screensaver may still be the topmost widget immediately after
            -- resume and block the guard on the first try.
            local function doResumeRefresh()
                refreshVisibleStatusBar(fm, false)
            end
            UIManager:scheduleIn(0.5, doResumeRefresh)
            UIManager:scheduleIn(1.5, doResumeRefresh)
            -- Restart the shared minute heartbeat after the display settles.
            UIManager:scheduleIn(2, function()
                if FileManager.instance ~= fm or not _fm_autoRefresh then return end
                clock_timer.resume()
                clock_timer.subscribe("filemanager_status_bar", _fm_autoRefresh)
                clock_timer.restart()
            end)
        end
    end
end


return apply_status_bar
