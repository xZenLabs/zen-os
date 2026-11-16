local function apply_reader_top_status_bar()
    --[[
        Paints a configurable three-zone header at the top of the reader screen.
        Left / center / right slots each hold an ordered list of item keys.
        Items: time, battery, battery_icon, battery_percent, wifi, bluetooth, frontlight, ram,
               disk, incognito, custom_text, book_title, author, chapter,
               progress_percent, current_page, total_pages, page_progress, pin
        Wraps ReaderView.paintTo. Config via config.reader_top_status_bar.
    --]]

    local Blitbuffer    = require("ffi/blitbuffer")
    local ColorTextWidget = require("common/ui/color_text_widget")
    local ColorIconWidget = require("common/ui/color_icon_widget")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local RightContainer  = require("ui/widget/container/rightcontainer")

    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan  = require("ui/widget/verticalspan")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local LineWidget    = require("ui/widget/linewidget")
    local BD       = require("ui/bidi")
    local Size     = require("ui/size")
    local Geom     = require("ui/geometry")
    local Device   = require("device")
    local T        = require("ffi/util").template
    local datetime = require("datetime")
    local UIManager = require("ui/uimanager")
    local zen_utils = require("common/utils")
    local pin_icon = zen_utils.resolveLocalIcon(require("common/plugin_root") .. "/icons/", "pin")
    local inline_icons = require("common/inline_icon_map")
    local WifiState = require("common/wifi_state")
    local _ = require("gettext")
    local ReaderThemes = require("common/reader_themes")
    local Bluetooth = require("modules/menu/bluetooth/bluetooth")
    local Screen = Device.screen
    local CreDocument = require("document/credocument")
    local ReaderTypeset = require("apps/reader/modules/readertypeset")
    local ReaderDogear = require("apps/reader/modules/readerdogear")
    local ReaderView = require("apps/reader/modules/readerview")
    local ReaderUI = require("apps/reader/readerui")
    local ReaderStatusBar = require("common/reader_status_bar")
    local References = require("modules/reader/references")
    local HighlightViewport = require("modules/reader/highlight_viewport")
    local _ReaderView_paintTo_orig = ReaderView.paintTo
    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")

    ReaderStatusBar.disableKoreaderAltStatusBar(nil, zen_plugin and zen_plugin.ui)

    local logger = require("common/zen_logger").new("reader_top_status_bar")
    local DBG = function(...) logger.dbg("", ...) end

    local function is_enabled()
        local plugin = zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
        local features = plugin and plugin.config and plugin.config.features
        return type(features) == "table" and features.reader_top_status_bar == true
    end

    -- Bottom bar toggled off (tap/gesture) while it has something to show.
    local function footer_toggled_off(view)
        local footer = view.footer
        if not (footer and footer.mode_list) or footer.mode ~= footer.mode_list.off then return false end
        if footer.has_no_mode and footer.settings.disable_progress_bar then return false end
        if ReaderStatusBar.getTapHide(zen_plugin) == "bottom" then return false end
        local fcfg = zen_plugin and zen_plugin.config and zen_plugin.config.reader_footer
        return not (type(fcfg) == "table" and fcfg.status_bar_enabled == false)
    end

    local function should_show(view)
        if not is_enabled() or not view or footer_toggled_off(view)
                or ReaderStatusBar.isTopBarTapHidden(zen_plugin, view.footer) then return false end
        if view.render_mode ~= nil then
            local cfg = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
            return type(cfg) == "table" and not cfg.hide_in_cbz
        end
        return view.view_mode == "page" or HighlightViewport.isScrolling(view)
    end

    local function header_text_color()
        return ReaderThemes.getTextColor(zen_plugin) or Blitbuffer.COLOR_BLACK
    end

    local function is_view_active_top(view)
        if not (view and view.ui) then return false end
        local top_widget = UIManager:getTopmostVisibleWidget()
        if not top_widget then return false end
        if top_widget == view.ui or top_widget == view.ui.show_parent then
            return true
        end
        local highlight = view.ui.highlight
        if highlight and top_widget == highlight.highlight_dialog then return true end
        local parent = top_widget.show_parent
        return parent ~= nil and (parent == view.ui or parent == view.ui.show_parent)
    end

    -- Stable reference so suspend/resume can cancel/restart the timer.
    local _autoRefresh
    local _charging_refresh_timer
    local _resume_refresh_timer
    local repaintHeaderSlots, repaintActiveHeaderSlots
    -- Items whose painted values are tracked so timers refresh only changed slots.
    local RESUME_REFRESH_ITEMS = {
        "time", "wifi", "bluetooth", "battery", "battery_icon", "battery_percent",
        "frontlight", "ram", "disk", "incognito",
    }
    local MINUTE_REFRESH_ITEMS = { "time", "battery", "battery_icon", "battery_percent" }
    local TRACKED_SET = {}
    for _i, key in ipairs(RESUME_REFRESH_ITEMS) do TRACKED_SET[key] = true end

    -- === Separator value map (bar-specific spacing; labels live in common/constants.lua) ===

    local SEP_VALUES = {
        dot             = " \xC2\xB7 ", -- middle dot
        bar             = " | ",
        dash            = " - ",
        bullet          = " \xE2\x80\xA2 ", -- bullet
        space           = "  ",
        ["small-space"] = " ",
        none            = "",
    }

    -- === Caches for slow item fetchers ===

    local cached_ram_text,  cached_ram_time  = nil, 0

    local colors = {
        wifi_on = Blitbuffer.ColorRGB32(0x33, 0x99, 0xFF, 0xFF),
        wifi_searching = Blitbuffer.COLOR_DARK_GRAY,
        wifi_off = Blitbuffer.ColorRGB32(0xDD, 0x33, 0x33, 0xFF),
        resource = Blitbuffer.ColorRGB32(0x33, 0xAA, 0x55, 0xFF),
        frontlight = Blitbuffer.ColorRGB32(0xFF, 0xAA, 0x00, 0xFF),
        battery_high = Blitbuffer.ColorRGB32(0x33, 0xAA, 0x55, 0xFF),
        battery_mid = Blitbuffer.ColorRGB32(0xFF, 0xAA, 0x00, 0xFF),
        battery_low = Blitbuffer.ColorRGB32(0xDD, 0x33, 0x33, 0xFF),
    }

    -- === Item fetchers: return (primary_text, suffix_or_nil) ===

    local function getWifiItem()
        local state = WifiState.get()
        if not state then return nil end
        if state == "searching" then
            return inline_icons.wifi_on, nil, colors.wifi_searching, true
        end
        if state == "on" then
            return inline_icons.wifi_on, nil, colors.wifi_on
        end
        local cfg = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
        if type(cfg) == "table" and cfg.wifi_hide_when_off == true then return nil end
        return inline_icons.wifi_off, nil, colors.wifi_off
    end

    local function getBluetoothItem()
        if Bluetooth.isChanging and Bluetooth.isChanging() then
            return inline_icons.bluetooth_on, nil, colors.wifi_searching, true
        end
        local get_state = Bluetooth.getCachedState or Bluetooth.getState
        if get_state() then
            return inline_icons.bluetooth_on, nil, colors.wifi_on
        end
    end

    local function getRamItem()
        local now = os.time()
        if cached_ram_text and (now - cached_ram_time) < 30 then
            return inline_icons.settings_ram, " " .. cached_ram_text, colors.resource
        end
        local statm = io.open("/proc/self/statm", "r")
        if statm then
            local rss_pages = select(2, statm:read("*number", "*number"))
            statm:close()
            if rss_pages then
                cached_ram_text = string.format("%dM", math.floor(rss_pages / 256))
                cached_ram_time = now
                return inline_icons.settings_ram, " " .. cached_ram_text, colors.resource
            end
        end
        return inline_icons.settings_ram, " ?M", colors.resource
    end

    -- df runs once on first paint, then after a page-turn refresh when stale (getDiskFreeText caches 5 min).
    local disk_text, disk_at, _disk_refresh
    local function getDiskItem()
        local now = os.time()
        if not disk_text then
            disk_text, disk_at = zen_utils.getDiskFreeText() or "?", now
        elseif not _disk_refresh and now - disk_at >= 300 then
            _disk_refresh = function()
                _disk_refresh = nil
                disk_text, disk_at = zen_utils.getDiskFreeText() or "?", os.time()
                repaintActiveHeaderSlots({ "disk" })
            end
            UIManager:nextTick(_disk_refresh)
        end
        return inline_icons.settings_storage, " " .. disk_text, colors.resource
    end

    local function getFrontlightItem()
        local powerd = Device:getPowerDevice()
        if not powerd then return nil end
        if powerd:isFrontlightOn() then
            return "\xe2\x98\xbc", string.format(" %d", powerd:frontlightIntensity()), colors.frontlight
        end
        return "\xe2\x98\xbc", " " .. _("Off"), colors.frontlight
    end

    local function getBatteryState()
        if not Device:hasBattery() then return nil end
        local powerd = Device:getPowerDevice()
        local batt_lvl = powerd:getCapacity()
        local batt_symbol = powerd:getBatterySymbol(
            powerd:isCharged(), powerd:isCharging(), batt_lvl)
        local color = batt_lvl >= 50 and colors.battery_high
            or batt_lvl >= 20 and colors.battery_mid or colors.battery_low
        return BD.wrap(batt_symbol), batt_lvl, color
    end

    local function getBatteryItem()
        local symbol, level, color = getBatteryState()
        if not symbol then return nil end
        return symbol, level .. "%", color
    end

    local function getBatteryIconItem()
        local symbol, level, color = getBatteryState()
        if not symbol or level == nil then return nil end
        return symbol, nil, color
    end

    local function getBatteryPercentItem()
        local symbol, level = getBatteryState()
        if not symbol then return nil end
        return level .. "%", nil
    end

    local function getTimeItem()
        local use_12h = G_reader_settings:isTrue("twelve_hour_clock")
        return datetime.secondsToHour(os.time(), use_12h) or "", nil
    end

    local function getCustomTextItem()
        local cfg = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
        local text = type(cfg) == "table" and cfg.custom_text
        if not text or text == "" then text = Device.model or "ZenOS" end
        return text ~= "" and text or nil, nil
    end

    local function getIncognitoItem()
        local features = zen_plugin and zen_plugin.config and zen_plugin.config.features
        if type(features) == "table" and features.incognito_mode == true then
            return inline_icons.incognito, nil
        end
        return nil
    end

    -- doc_ctx is the ReaderView; its .ui.doc_props has title/authors, .ui.toc has chapter.
    local function getBookTitleItem(doc_ctx)
        if not doc_ctx or not doc_ctx.ui then return nil end
        local props = doc_ctx.ui.doc_props
        local title = props and props.title
        if not title or title == "" then return nil end
        return zen_utils.truncateUtf8(title, 40, "..."), nil
    end

    local function getAuthorItem(doc_ctx)
        if not doc_ctx or not doc_ctx.ui then return nil end
        local props = doc_ctx.ui.doc_props
        local authors = props and props.authors
        if not authors or authors == "" then return nil end
        return zen_utils.truncateUtf8(authors, 30, "..."), nil
    end

    local function getChapterItem(doc_ctx)
        if not doc_ctx or not doc_ctx.ui then return nil end
        local toc = doc_ctx.ui.toc
        if not toc then return nil end
        local chapter = toc:getTocTitleOfCurrentPage()
        if not chapter or chapter == "" then return nil end
        return zen_utils.truncateUtf8(chapter, 35, "..."), nil
    end

    local function getFooter(doc_ctx)
        if doc_ctx and doc_ctx.footer and doc_ctx.footer.ui then
            return doc_ctx.footer
        end
        return doc_ctx and doc_ctx.ui and doc_ctx.ui.view and doc_ctx.ui.view.footer or nil
    end

    local function getPageInfo(doc_ctx)
        local footer = getFooter(doc_ctx)
        local ui = (footer and footer.ui) or (doc_ctx and doc_ctx.ui)
        local document = ui and ui.document or (doc_ctx and doc_ctx.document)
        if not document then return nil end

        local pageno = footer and tonumber(footer.pageno)
        local pages = footer and tonumber(footer.pages)
        if not pageno and type(document.getCurrentPage) == "function" then
            pageno = tonumber(document:getCurrentPage())
        end
        if not pages and type(document.getPageCount) == "function" then
            pages = tonumber(document:getPageCount())
        end
        if not (pageno and pages and pages > 0) then return nil end

        if ui and ui.pagemap and type(ui.pagemap.wantsPageLabels) == "function"
                and ui.pagemap:wantsPageLabels() then
            return ui.pagemap:getCurrentPageLabel(true),
                ui.pagemap:getLastPageLabel(true), pageno, pages
        end

        if type(document.hasHiddenFlows) == "function" and document:hasHiddenFlows() then
            local flow = document:getPageFlow(pageno)
            local page = document:getPageNumberInFlow(pageno)
            local flow_pages = document:getTotalPagesInFlow(flow)
            if page and flow_pages then
                if flow == 0 then
                    return page, flow_pages, page, flow_pages
                end
                return ("[%d"):format(page), ("%d]%d"):format(flow_pages, flow), page, flow_pages
            end
        end

        return pageno, pages, pageno, pages
    end

    local function getDisplayPageInfo(doc_ctx)
        local current, total, pageno = getPageInfo(doc_ctx)
        local cfg = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
        if type(cfg) ~= "table" or cfg.page_count_scope ~= "chapter" then
            return current, total
        end
        local toc = doc_ctx and doc_ctx.ui and doc_ctx.ui.toc
        if not (toc and pageno and type(toc.getChapterPagesDone) == "function"
                and type(toc.getChapterPageCount) == "function") then
            return current, total
        end
        local done = toc:getChapterPagesDone(pageno)
        local count = toc:getChapterPageCount(pageno)
        if done == nil or not count or count <= 0 then return current, total end
        return done + 1, count
    end

    local function getPageProgressItem(doc_ctx)
        local current, total = getDisplayPageInfo(doc_ctx)
        if current == nil or total == nil then return nil end
        local cfg = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
        if type(cfg) == "table" and cfg.page_separator == "of" then
            return T(_("%1 of %2"), current, total), nil
        end
        return ("%s / %s"):format(current, total), nil
    end

    local function getCurrentPageItem(doc_ctx)
        local current = getDisplayPageInfo(doc_ctx)
        return current ~= nil and tostring(current) or nil, nil
    end

    local function getTotalPagesItem(doc_ctx)
        local total = select(2, getDisplayPageInfo(doc_ctx))
        return total ~= nil and tostring(total) or nil, nil
    end

    local function getProgressRatio(doc_ctx)
        local footer = getFooter(doc_ctx)
        local percent = footer and tonumber(footer.percent_finished)
        if not percent and footer and type(footer.getBookProgress) == "function" then
            local ok, value = pcall(footer.getBookProgress, footer)
            percent = ok and tonumber(value) or nil
        end
        if not percent then
            local pageno, pages = select(3, getPageInfo(doc_ctx))
            if pageno and pages and pages > 0 then
                percent = pageno / pages
            end
        end
        if not percent then return nil end
        if percent < 0 then percent = 0 elseif percent > 1 then percent = 1 end
        return percent
    end

    local function getProgressPercentItem(doc_ctx)
        local percent = getProgressRatio(doc_ctx)
        if not percent then return nil end
        local footer = getFooter(doc_ctx)
        local digits = footer and footer.settings and footer.settings.progress_pct_format or "0"
        return ("%." .. digits .. "f%%"):format(percent * 100), nil
    end

    local function getPinItem(doc_ctx)
        local ui = doc_ctx and doc_ctx.ui
        if References.enabled(ui) and References.isPinned(ui, ui:getCurrentPage()) then
            return pin_icon
        end
    end

    local item_fetchers = {
        pin         = getPinItem,
        wifi        = getWifiItem,
        bluetooth   = getBluetoothItem,
        incognito   = getIncognitoItem,
        disk        = getDiskItem,
        ram         = getRamItem,
        frontlight  = getFrontlightItem,
        battery     = getBatteryItem,
        battery_icon = getBatteryIconItem,
        battery_percent = getBatteryPercentItem,
        time        = getTimeItem,
        custom_text = getCustomTextItem,
        book_title  = getBookTitleItem,
        author      = getAuthorItem,
        chapter     = getChapterItem,
        progress_percent = getProgressPercentItem,
        current_page     = getCurrentPageItem,
        total_pages      = getTotalPagesItem,
        page_progress    = getPageProgressItem,
    }

    -- Returns display-ready icon/label parts for an ordered slot.
    local function collectItemTexts(order, doc_ctx)
        if type(order) ~= "table" or #order == 0 then return {} end
        local cfg = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
        local use_color = type(cfg) == "table" and cfg.colored == true
        local texts = {}
        for _i, key in ipairs(order) do
            local fn = item_fetchers[key]
            if fn then
                local icon, label, color, force_color = fn(doc_ctx)
                if icon ~= nil then
                    local text = label and (icon .. label) or icon
                    local entry = {
                        key = key,
                        text = text,
                        icon = icon,
                        label = label,
                        color = color and (use_color or force_color) and color or nil,
                    }
                    if key == "pin" then
                        entry.file, entry.text = icon, ""
                        entry.size = Screen:scaleBySize((cfg and cfg.font_size or 14) + 2)
                    end
                    table.insert(texts, entry)
                end
            end
        end
        return texts
    end

    local function freeWidgets(widgets)
        for _i, widget in ipairs(widgets or {}) do
            if widget.free then widget:free() end
        end
    end

    local function textWidget(text, face, fgcolor, max_width)
        return ColorTextWidget:new{
            text = text, face = face, fgcolor = fgcolor, invert_night_mode = false, padding = 0,
            max_width = max_width,
        }
    end

    local function iconWidget(file, size, fgcolor)
        return ColorIconWidget:new{ icon = file, width = size, height = size, alpha = true, fgcolor = fgcolor }
    end

    -- Builds a slot's widgets at natural size; returns (widgets, natural_width).
    local function buildSlotWidgets(texts, face, sep, fgcolor)
        local widgets, width = {}, 0
        for i = 1, #texts do
            if i > 1 and sep ~= "" then widgets[#widgets + 1] = textWidget(sep, face, fgcolor) end
            local entry = texts[i]
            if entry.file then
                widgets[#widgets + 1] = iconWidget(entry.file, entry.size, fgcolor)
            elseif entry.color and entry.icon ~= "" then
                widgets[#widgets + 1] = ColorTextWidget:new{
                    text = entry.icon, face = face, fgcolor = entry.color, padding = 0,
                }
                if entry.label and entry.label ~= "" then
                    widgets[#widgets + 1] = textWidget(entry.label, face, fgcolor)
                end
            else
                widgets[#widgets + 1] = textWidget(entry.text, face, fgcolor)
            end
        end
        for i = 1, #widgets do width = width + widgets[i]:getSize().w end
        return widgets, width
    end

    -- Fits slot widgets in max_width: truncates text while preserving SVG icons.
    -- Returns (group_or_nil, widgets).
    local function fitSlotWidgets(texts, widgets, natural_w, face, sep, fgcolor, max_width)
        if #widgets == 0 then return nil, widgets end
        if max_width and max_width <= 0 then
            freeWidgets(widgets)
            return nil, {}
        end
        if max_width and natural_w > max_width then
            local image_width, text_width = 0, 0
            for i, widget in ipairs(widgets) do
                if widget.setMaxWidth then
                    text_width = text_width + widget:getSize().w
                else
                    if widget.width > max_width then
                        widget:free()
                        widget = iconWidget(widget.icon, max_width, fgcolor)
                        widgets[i] = widget
                    end
                    image_width = image_width + widget:getSize().w
                end
            end
            if image_width > 0 then
                local ratio = math.max(0, max_width - image_width) / math.max(1, text_width)
                for _i, widget in ipairs(widgets) do
                    if widget.setMaxWidth then
                        local cap = math.floor(widget:getSize().w * ratio)
                        widget:setMaxWidth(math.max(1, cap))
                        if widget:getSize().w > cap then widget:setText("") end
                    end
                end
            else
                freeWidgets(widgets)
                local joined = texts[1].text
                for i = 2, #texts do joined = joined .. sep .. texts[i].text end
                widgets = { textWidget(joined, face, fgcolor, max_width) }
            end
        end
        local group = HorizontalGroup:new{}
        for i = 1, #widgets do group[i] = widgets[i] end
        return group, widgets
    end

    local function getChapterTicks(doc_ctx)
        local ui = doc_ctx and doc_ctx.ui
        local document = ui and ui.document
        local toc = ui and ui.toc
        if not (document and toc and type(toc.getTocTicksFlattened) == "function") then
            return nil
        end

        local ticks = toc:getTocTicksFlattened()
        local last = type(document.getPageCount) == "function" and document:getPageCount() or nil
        if type(ticks) ~= "table" or not last or last <= 0 then return nil end

        if type(document.hasHiddenFlows) == "function" and document:hasHiddenFlows() then
            local current = select(3, getPageInfo(doc_ctx))
            if not current then return nil end
            local flow = document:getPageFlow(current)
            -- ReaderToc replaces its ticks table on rerender/reset, which also invalidates this.
            local cache = ui._zen_top_bar_flow_ticks
            if not (cache and cache.ticks == ticks and cache.flow == flow) then
                local flow_ticks = {}
                for _i, pageno in ipairs(ticks) do
                    if document:getPageFlow(pageno) == flow then
                        flow_ticks[#flow_ticks + 1] = document:getPageNumberInFlow(pageno)
                    end
                end
                cache = { ticks = ticks, flow = flow, flow_ticks = flow_ticks,
                    last = document:getTotalPagesInFlow(flow) }
                ui._zen_top_bar_flow_ticks = cache
            end
            return cache.flow_ticks, cache.last
        end
        return ticks, last
    end

    local function paintBottomBorder(bb, x, y, width, cfg, doc_ctx)
        local document = doc_ctx and doc_ctx.ui and doc_ctx.ui.document
        local left_margin, right_margin = ReaderStatusBar.getHorizontalMargins(document, Screen:scaleBySize(10), zen_plugin)
        local line_w = math.max(0, width - left_margin - right_margin)
        if line_w <= 0 then return end
        local line_h = Size.line.medium
        if type(cfg) == "table" and cfg.bottom_border_progress == true then
            bb:paintRect(x + left_margin, y, line_w, line_h, Blitbuffer.COLOR_LIGHT_GRAY)
            local percent = getProgressRatio(doc_ctx)
            if percent and percent > 0 then
                local progress_w = math.ceil(line_w * percent)
                if progress_w > line_w then progress_w = line_w end
                bb:paintRect(x + left_margin, y, progress_w, line_h, Blitbuffer.COLOR_GRAY_5)
            end
            if cfg.show_chapter_marks == true then
                local ticks, last = getChapterTicks(doc_ctx)
                if ticks and last and last > 0 then
                    local tick_w = Screen:scaleBySize(2)
                    for _i, tick in ipairs(ticks) do
                        local ratio = tonumber(tick) and tick / last or nil
                        if ratio and ratio >= 0 and ratio <= 1 then
                            local tick_x = math.floor(line_w * ratio)
                            if tick_x + tick_w > line_w then tick_x = line_w - tick_w end
                            bb:paintRect(x + left_margin + tick_x, y, tick_w, line_h,
                                Blitbuffer.COLOR_BLACK)
                        end
                    end
                end
            end
        else
            local border = LineWidget:new{
                dimen = Geom:new{ w = line_w, h = line_h },
            }
            border:paintTo(bb, x + left_margin, y)
        end
    end

    local function getSlotOrders(cfg)
        local orders = {
            left = (type(cfg) == "table" and cfg.left_order) or {},
            center = type(cfg) == "table" and cfg.center_order or nil,
            right = (type(cfg) == "table" and cfg.right_order) or {},
        }
        if orders.center == nil then
            local pos = type(cfg) == "table" and cfg.position
            if pos == "left" then
                orders.left, orders.center, orders.right = { "time" }, {}, {}
            elseif pos == "right" then
                orders.left, orders.center, orders.right = {}, {}, { "time" }
            else
                orders.center = { "time" }
            end
        end
        return orders
    end

    local SLOTS = { "left", "center", "right" }

    local function hasItem(orders, key)
        for _i, slot in ipairs(SLOTS) do
            for _j, item in ipairs(orders[slot]) do
                if item == key then return true end
            end
        end
        return false
    end

    local function getReservedHeaderHeight()
        if not is_enabled() then return 0 end
        local cfg = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
        local orders = getSlotOrders(cfg)
        if #orders.left == 0 and #orders.center == 0 and #orders.right == 0 then return 0 end
        return ReaderStatusBar.getHeaderHeight(cfg, hasItem(orders, "pin"))
    end

    local function slotsContaining(cfg, item_keys)
        local wanted = {}
        for _i, key in ipairs(item_keys or {}) do wanted[key] = true end
        local orders = getSlotOrders(cfg)
        local slots = {}
        for _i, slot in ipairs(SLOTS) do
            for _j, key in ipairs(orders[slot]) do
                if wanted[key] then
                    table.insert(slots, slot)
                    break
                end
            end
        end
        return slots
    end

    local function entryValue(entry)
        return entry and (entry.text .. "\0" .. tostring(entry.color)) or false
    end

    -- Current values of the given items that are configured in a slot.
    local function itemValues(view, keys)
        local orders = getSlotOrders(zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar)
        local values = {}
        for _i, key in ipairs(keys) do
            if hasItem(orders, key) then values[key] = entryValue(collectItemTexts({ key }, view)[1]) end
        end
        return values
    end

    -- Items whose value differs from the painted header.
    local function changedItems(view, keys)
        local previous = view._zen_header_values
        local changed = {}
        for key, value in pairs(itemValues(view, keys)) do
            if not previous or previous[key] ~= value then changed[#changed + 1] = key end
        end
        return changed
    end

    -- Comparable key for theme colors, which are fresh cdata on each lookup.
    local function colorKey(color)
        if type(color) ~= "cdata" then return tostring(color) end
        local rgb = color:getColorRGB32()
        return rgb.r * 65536 + rgb.g * 256 + rgb.b
    end

    local function freeHeaderCache(view)
        local cache = view and view._zen_header_cache
        if cache then
            freeWidgets(cache.widgets)
            view._zen_header_cache = nil
        end
    end

    -- Builds the header widget from current config, reusing the view's cached widgets
    -- while item texts, colors and layout inputs are unchanged.
    -- doc_ctx: ReaderView (or nil); needed for book_title, author, chapter items.
    -- Returns header, widgets, height, width, per-slot regions and tracked item values; or nil if empty.
    -- Widgets stay owned by the view's cache (freed on rebuild or close).
    local function buildHeader(doc_ctx)
        local screen_width = Screen:getWidth()
        local cfg = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
        local face = ReaderStatusBar.getHeaderFace(cfg)
        local fgcolor = header_text_color()

        local top_pad = Size.padding.small
        local h_pad   = Size.span.horizontal_default
        local align_margins = ReaderStatusBar.isMarginAlignmentEnabled(zen_plugin)
        local document = doc_ctx and doc_ctx.ui and doc_ctx.ui.document
        local left_pad, right_pad = ReaderStatusBar.getHorizontalMargins(document, h_pad, zen_plugin)
        -- Include custom dogear sizing and right offsets from companion plugins.
        local dogear = doc_ctx and doc_ctx.dogear_visible and doc_ctx.dogear
        local dogear_icon = dogear and dogear.icon
        local dogear_dimen = dogear_icon and dogear_icon.dimen
        local dogear_x = dogear_dimen and tonumber(dogear_dimen.x)
        local dogear_width = dogear_icon and tonumber(dogear_icon.width)
            or dogear_dimen and tonumber(dogear_dimen.w)
            or dogear and tonumber(dogear.dogear_size)
        local dogear_is_right = dogear_x and dogear_width
            and dogear_x + dogear_width > screen_width / 2
        local right_inset = dogear_is_right and screen_width - dogear_x or dogear_width or 0
        right_inset = math.ceil(math.max(0, math.min(screen_width, right_inset)))
        right_pad = math.max(right_pad, right_inset > 0 and right_inset + h_pad or 0)

        local orders = getSlotOrders(cfg)
        local left_order, center_order, right_order = orders.left, orders.center, orders.right

        local sep_key = (type(cfg) == "table" and cfg.separator_key) or "small-space"
        local sep_val = sep_key == "custom"
            and ((type(cfg) == "table" and cfg.custom_separator) or "  ")
            or (SEP_VALUES[sep_key] or " ")

        -- Per-slot separator: only active when *_show_separator == true (default off).
        local function slot_sep(slot)
            if type(cfg) == "table" and cfg[slot .. "_show_separator"] == true then
                return sep_val
            end
            return SEP_VALUES["small-space"]
        end

        local left_sep = slot_sep("left")
        local center_sep = slot_sep("center")
        local right_sep = slot_sep("right")

        local left_texts = collectItemTexts(left_order, doc_ctx)
        local center_texts = collectItemTexts(center_order, doc_ctx)
        local right_texts = collectItemTexts(right_order, doc_ctx)
        local values = {}
        local sig = { screen_width, left_pad, right_pad, top_pad, tostring(align_margins), tostring(face),
            colorKey(fgcolor), tostring(Screen.night_mode), left_sep, center_sep, right_sep }
        for _i, slot in ipairs(SLOTS) do
            for _j, key in ipairs(orders[slot]) do
                if TRACKED_SET[key] then values[key] = false end
            end
        end
        for _i, texts in ipairs({ left_texts, center_texts, right_texts }) do
            sig[#sig + 1] = "|"
            for _j, entry in ipairs(texts) do
                if TRACKED_SET[entry.key] then values[entry.key] = entryValue(entry) end
                sig[#sig + 1] = entry.file or entry.text
                sig[#sig + 1] = entry.file and entry.size or tostring(entry.color)
            end
        end
        sig = table.concat(sig, "\1")
        local cache = doc_ctx and doc_ctx._zen_header_cache
        if cache and cache.sig == sig then
            return cache.header, cache.widgets, cache.height, screen_width, cache.slots, values
        end
        freeHeaderCache(doc_ctx)

        local left_ws, left_nat = buildSlotWidgets(left_texts, face, left_sep, fgcolor)
        local center_ws, center_nat = buildSlotWidgets(center_texts, face, center_sep, fgcolor)
        local right_ws, right_nat = buildSlotWidgets(right_texts, face, right_sep, fgcolor)

        local left_has = #left_texts > 0
        local center_has = #center_texts > 0
        local right_has = #right_texts > 0

        local left_cap = 0
        local center_cap = 0
        local right_cap = 0
        local left_w = 0
        local center_w = 0
        local right_w = 0
        local middle_w = 0

        if center_has then
            local max_center = math.max(0, screen_width - left_pad - right_pad)
            if not align_margins then
                max_center = math.max(0, screen_width - 2 * math.max(left_pad, right_pad))
            end
            center_cap = math.min(center_nat, max_center)
            center_w = center_cap

            local side_total = (align_margins and max_center or screen_width) - center_w
            left_w = (align_margins and left_pad or 0) + math.floor(side_total / 2)
            right_w = screen_width - center_w - left_w

            left_cap = left_has and math.max(0, left_w - left_pad) or 0
            right_cap = right_has and math.max(0, right_w - right_pad) or 0
        else
            local side_content_space = math.max(0, screen_width - left_pad - right_pad)
            if left_has and right_has then
                if left_nat + right_nat <= side_content_space then
                    left_cap = left_nat
                    right_cap = right_nat
                else
                    left_cap = math.floor(side_content_space / 2)
                    right_cap = side_content_space - left_cap
                end
                left_w = left_pad + left_cap
                right_w = right_pad + right_cap
                middle_w = math.max(0, screen_width - left_w - right_w)
            elseif left_has then
                left_cap = side_content_space
                left_w = screen_width
            elseif right_has then
                right_cap = side_content_space
                right_w = screen_width
            end
        end

        local left_grp, center_grp, right_grp
        left_grp, left_ws = fitSlotWidgets(left_texts, left_ws, left_nat, face, left_sep, fgcolor, left_cap)
        center_grp, center_ws = fitSlotWidgets(center_texts, center_ws, center_nat, face, center_sep, fgcolor, center_cap)
        right_grp, right_ws = fitSlotWidgets(right_texts, right_ws, right_nat, face, right_sep, fgcolor, right_cap)

        local all_widgets = {}
        for _i, ws in ipairs({ left_ws, center_ws, right_ws }) do
            for _j, w in ipairs(ws) do all_widgets[#all_widgets + 1] = w end
        end

        if not left_grp and not center_grp and not right_grp then
            DBG("buildHeader: all groups nil, doc_ctx=", doc_ctx and "present" or "nil",
                "left_order=", #left_order, "center_order=", #(center_order or {}), "right_order=", #right_order)
            freeWidgets(all_widgets)
            return nil, {}, 0, screen_width
        end

        local row_h = 0
        local function upd(w)
            if w then local s = w:getSize(); if s and s.h > row_h then row_h = s.h end end
        end
        upd(left_grp); upd(center_grp); upd(right_grp)
        local header_h = row_h + top_pad

        local function padded(grp)
            if not grp then return nil end
            local vg = VerticalGroup:new{}
            table.insert(vg, VerticalSpan:new{ width = top_pad })
            table.insert(vg, grp)
            return vg
        end

        local header = HorizontalGroup:new{}

        if center_grp then
            -- 3-zone layout: left | center | right
            if left_grp then
                table.insert(header, LeftContainer:new{
                    dimen = Geom:new{ w = left_w, h = header_h },
                    HorizontalGroup:new{
                        HorizontalSpan:new{ width = left_pad },
                        padded(left_grp),
                    },
                })
            else
                table.insert(header, HorizontalSpan:new{ width = left_w })
            end
            table.insert(header, CenterContainer:new{
                dimen = Geom:new{ w = center_w, h = header_h },
                padded(center_grp),
            })
            if right_grp then
                table.insert(header, RightContainer:new{
                    dimen = Geom:new{ w = right_w, h = header_h },
                    HorizontalGroup:new{
                        padded(right_grp),
                        HorizontalSpan:new{ width = right_pad },
                    },
                })
            else
                table.insert(header, HorizontalSpan:new{ width = right_w })
            end
        else
            -- 2-zone layout: left | right with adaptive middle gap.
            if left_grp then
                table.insert(header, LeftContainer:new{
                    dimen = Geom:new{ w = left_w, h = header_h },
                    HorizontalGroup:new{
                        HorizontalSpan:new{ width = left_pad },
                        padded(left_grp),
                    },
                })
            else
                table.insert(header, HorizontalSpan:new{ width = left_w })
            end
            if middle_w > 0 then
                table.insert(header, HorizontalSpan:new{ width = middle_w })
            end
            if right_grp then
                table.insert(header, RightContainer:new{
                    dimen = Geom:new{ w = right_w, h = header_h },
                    HorizontalGroup:new{
                        padded(right_grp),
                        HorizontalSpan:new{ width = right_pad },
                    },
                })
            else
                table.insert(header, HorizontalSpan:new{ width = right_w })
            end
        end

        local slot_regions = {}
        if left_grp then
            local left_content_w = math.min(screen_width, left_pad + left_grp:getSize().w)
            slot_regions.left = Geom:new{ x = 0, y = 0, w = left_content_w, h = header_h }
        end
        if center_grp then
            slot_regions.center = Geom:new{
                x = left_w, y = 0, w = center_w, h = header_h,
            }
        end
        if right_grp then
            local right_content_w = math.min(screen_width, right_grp:getSize().w + right_pad)
            slot_regions.right = Geom:new{
                x = screen_width - right_content_w,
                y = 0,
                w = right_content_w,
                h = header_h,
            }
        end

        if doc_ctx then
            doc_ctx._zen_header_cache = {
                sig = sig, header = header, widgets = all_widgets, height = header_h, slots = slot_regions,
            }
        end
        return header, all_widgets, header_h, screen_width, slot_regions, values
    end

    local function offsetSlotRegions(slot_regions, x, y)
        local result = {}
        for slot, region in pairs(slot_regions or {}) do
            result[slot] = Geom:new{
                x = x + region.x, y = y + region.y, w = region.w, h = region.h,
            }
        end
        return result
    end

    local function unionRegions(first, second)
        if not first then return second end
        if not second then return first end
        local x = math.min(first.x, second.x)
        local y = math.min(first.y, second.y)
        return Geom:new{
            x = x,
            y = y,
            w = math.max(first.x + first.w, second.x + second.w) - x,
            h = math.max(first.y + first.h, second.y + second.h) - y,
        }
    end

    if not ReaderDogear._zen_top_status_bar_refresh_patched then
        ReaderDogear._zen_top_status_bar_refresh_patched = true
        local orig_getRefreshRegion = ReaderDogear.getRefreshRegion
        ReaderDogear.getRefreshRegion = function(self)
            local region = orig_getRefreshRegion(self)
            return should_show(self.view) and unionRegions(region, self.view._zen_header_dimen) or region
        end
    end

    -- Rebuilds the header, but clears and flushes only slots containing the
    -- given items or any other tracked item whose value changed since the last paint.
    function repaintHeaderSlots(view, item_keys)
        if not should_show(view) then return end
        local top_widget = UIManager:getTopmostVisibleWidget()
        if not (top_widget == view.ui or top_widget == (view.ui and view.ui.show_parent)) then return end
        if not view._zen_header_dimen then
            DBG("repaintHeaderSlots SKIP: no _zen_header_dimen (paintTo never ran?)")
            return
        end
        if not view.ui then
            DBG("repaintHeaderSlots SKIP: view.ui is nil")
            return
        end
        local cfg2 = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
        local header, _widgets, header_h, screen_width, relative_slots, values = buildHeader(view)
        if not header then
            DBG("repaintHeaderSlots SKIP: buildHeader returned nil")
            return
        end
        values = values or itemValues(view, RESUME_REFRESH_ITEMS)
        local previous = view._zen_header_values or {}
        local keys = { unpack(item_keys) }
        for key, value in pairs(values) do
            if previous[key] ~= value then keys[#keys + 1] = key end
        end
        local target_slots = slotsContaining(cfg2, keys)
        if #target_slots == 0 then return end
        local show_border = type(cfg2) == "table" and cfg2.show_bottom_border
        local total_h = header_h + (show_border and Size.line.medium or 0)

        local dimen = view._zen_header_dimen
        dimen.h = total_h
        dimen.w = screen_width
        local current_slots = offsetSlotRegions(relative_slots, dimen.x, dimen.y)
        local previous_slots = view._zen_header_slots or {}
        local refresh_regions = {}
        for _i, slot in ipairs(target_slots) do
            local region = unionRegions(previous_slots[slot], current_slots[slot])
            if region then table.insert(refresh_regions, region) end
        end
        view._zen_header_slots = current_slots
        view._zen_header_values = values
        if #refresh_regions == 0 then return end

        local refresh_dither = top_widget and top_widget.dithered or nil
        local bb = Screen.bb
        if bb then
            local page_buffer = view.render_mode == nil and view.document and view.document.buffer
            local offset = view.state and view.state.offset
            local background = type(ReaderThemes.getBackgroundColor) == "function"
                and ReaderThemes.getBackgroundColor(zen_plugin) or Blitbuffer.COLOR_WHITE
            for _i, region in ipairs(refresh_regions) do
                if page_buffer and offset then
                    -- Restore the rendered backdrop with the page's exact colors and inversion.
                    bb:blitFrom(page_buffer, region.x, region.y,
                        region.x - dimen.x - offset.x, region.y - dimen.y - offset.y, region.w, region.h)
                else
                    bb:paintRectRGB32(region.x, region.y, region.w, region.h, background)
                end
            end
        end
        -- Clip unchanged slots to avoid darkening antialiased text on repeated paints.
        for _i, region in ipairs(refresh_regions) do
            local viewport = Screen.bb:viewport(region.x, region.y, region.w, region.h)
            header:paintTo(viewport, dimen.x - region.x, dimen.y - region.y)
            viewport:free()
        end
        if view.dogear_visible and view.dogear and type(view.dogear.paintTo) == "function" then
            view.dogear:paintTo(Screen.bb, dimen.x, dimen.y)
        end
        for _i, region in ipairs(refresh_regions) do
            UIManager:setDirty(nil, "ui", region, refresh_dither)
        end
    end

    local function activeReaderView(rui)
        local reader = rui and rui.view and rui or ReaderUI.instance
        return reader and reader.view
    end

    -- Repaints only when one of item_keys changed since the last paint.
    function repaintActiveHeaderSlots(item_keys, rui, repaint_reader)
        local view = activeReaderView(rui)
        if not (view and view.ui and view.ui.document) or not should_show(view)
                or not is_view_active_top(view) then return end
        local changed = changedItems(view, item_keys)
        if #changed == 0 then return end
        if repaint_reader then
            -- Match page turns: repaint the page and transparent header together.
            DBG("resume reader repaint", "mode=ui")
            UIManager:setDirty(view.ui.show_parent or view.ui, "ui")
        else
            repaintHeaderSlots(view, changed)
        end
    end

    local function autoRefresh()
        local view = activeReaderView()
        local cfg2 = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
        if not (view and view.ui and view.ui.document) or not should_show(view)
                or #slotsContaining(cfg2, MINUTE_REFRESH_ITEMS) == 0 then
            _autoRefresh = nil
            return
        end
        repaintActiveHeaderSlots(MINUTE_REFRESH_ITEMS)
        local t = os.date("*t")
        UIManager:scheduleIn(61 - t.sec, autoRefresh)
    end

    local function armAutoRefresh()
        if _autoRefresh then return end -- autoRefresh disarms itself once no minute item is configured
        local cfg2 = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
        if #slotsContaining(cfg2, MINUTE_REFRESH_ITEMS) == 0 then return end
        _autoRefresh = autoRefresh
        local t = os.date("*t")
        UIManager:scheduleIn(61 - t.sec, _autoRefresh)
    end

    local function cancelRefreshTimers(clear_auto_refresh)
        if _autoRefresh then
            UIManager:unschedule(_autoRefresh)
            if clear_auto_refresh then _autoRefresh = nil end
        end
        if _charging_refresh_timer then UIManager:unschedule(_charging_refresh_timer) end
        if _resume_refresh_timer then UIManager:unschedule(_resume_refresh_timer) end
        if _disk_refresh then UIManager:unschedule(_disk_refresh) end
        _charging_refresh_timer, _resume_refresh_timer, _disk_refresh = nil, nil, nil
    end

    local function scheduleChargingRefresh(rui)
        local view = activeReaderView(rui)
        if not should_show(view) then return end
        if _charging_refresh_timer then
            UIManager:unschedule(_charging_refresh_timer)
        end
        _charging_refresh_timer = function()
            _charging_refresh_timer = nil
            repaintActiveHeaderSlots({ "battery", "battery_icon", "battery_percent" })
        end
        UIManager:scheduleIn(1.5, _charging_refresh_timer)
    end

    if not ReaderUI._zen_top_status_bar_refresh_patched then
        ReaderUI._zen_top_status_bar_refresh_patched = true

        local orig_onSuspend = ReaderUI.onSuspend
        ReaderUI.onSuspend = function(rui, ...)
            if orig_onSuspend then orig_onSuspend(rui, ...) end
            cancelRefreshTimers(false)
        end

        local orig_onResume = ReaderUI.onResume
        ReaderUI.onResume = function(rui, ...)
            if orig_onResume then orig_onResume(rui, ...) end
            local view = activeReaderView(rui)
            if not should_show(view) or not _autoRefresh then return end
            DBG("onResume fired, _autoRefresh=armed",
                "view._zen_header_dimen=", view._zen_header_dimen and "present" or "nil",
                "view.ui=", view.ui and "present" or "nil")
            UIManager:unschedule(_autoRefresh)
            if _resume_refresh_timer then UIManager:unschedule(_resume_refresh_timer) end
            local repaint_reader = view.render_mode == nil and Device:isKindle()
                and Device:hasColorScreen() and ReaderThemes.getBackgroundColor(zen_plugin)
            -- One settled pass for values that changed while asleep.
            _resume_refresh_timer = function()
                _resume_refresh_timer = nil
                repaintActiveHeaderSlots(RESUME_REFRESH_ITEMS, nil, repaint_reader)
            end
            UIManager:scheduleIn(1.8, _resume_refresh_timer)
            local now_t = os.date("*t")
            UIManager:scheduleIn(61 - now_t.sec, _autoRefresh)
        end

        local orig_onCharging = ReaderUI.onCharging
        ReaderUI.onCharging = function(rui, ...)
            if orig_onCharging then orig_onCharging(rui, ...) end
            scheduleChargingRefresh(rui)
        end

        local orig_onNotCharging = ReaderUI.onNotCharging
        ReaderUI.onNotCharging = function(rui, ...)
            if orig_onNotCharging then orig_onNotCharging(rui, ...) end
            scheduleChargingRefresh(rui)
        end

        local orig_onNetworkConnected = ReaderUI.onNetworkConnected
        ReaderUI.onNetworkConnected = function(rui, ...)
            if orig_onNetworkConnected then orig_onNetworkConnected(rui, ...) end
            repaintActiveHeaderSlots({ "wifi" }, rui)
        end

        local orig_onNetworkDisconnected = ReaderUI.onNetworkDisconnected
        ReaderUI.onNetworkDisconnected = function(rui, ...)
            if orig_onNetworkDisconnected then orig_onNetworkDisconnected(rui, ...) end
            repaintActiveHeaderSlots({ "wifi" }, rui)
        end

        local orig_onNetworkStateChanged = ReaderUI.onNetworkStateChanged
        ReaderUI.onNetworkStateChanged = function(rui, ...)
            if orig_onNetworkStateChanged then orig_onNetworkStateChanged(rui, ...) end
            repaintActiveHeaderSlots({ "wifi" }, rui)
        end

        local orig_onBluetoothStateChanged = ReaderUI.onBluetoothStateChanged
        ReaderUI.onBluetoothStateChanged = function(rui, ...)
            if orig_onBluetoothStateChanged then orig_onBluetoothStateChanged(rui, ...) end
            repaintActiveHeaderSlots({ "bluetooth" }, rui)
        end

        local orig_onClose = ReaderUI.onClose
        ReaderUI.onClose = function(rui, ...)
            cancelRefreshTimers(true)
            freeHeaderCache(rui and rui.view)
            if orig_onClose then return orig_onClose(rui, ...) end
        end
    end

    if not CreDocument._zen_top_status_bar_margins_patched then
        CreDocument._zen_top_status_bar_margins_patched = true
        local orig_setPageMargins = CreDocument.setPageMargins
        CreDocument.setPageMargins = function(self, left, top, right, bottom)
            local reserve = tonumber(self._zen_top_status_bar_margin_reserve) or 0
            self._zen_top_status_bar_base_top_margin = top
            self._zen_top_status_bar_reserved_height = reserve
            return orig_setPageMargins(self, left, top + reserve, right, bottom)
        end
    end

    if not ReaderTypeset._zen_top_status_bar_margins_patched then
        ReaderTypeset._zen_top_status_bar_margins_patched = true
        local orig_onSetPageMargins = ReaderTypeset.onSetPageMargins
        ReaderTypeset.onSetPageMargins = function(self, margins, ...)
            local document = self.ui and self.ui.document
            if document then
                document._zen_top_status_bar_margin_reserve = self.view
                    and self.view.view_mode == "page" and getReservedHeaderHeight() or 0
            end
            local result = orig_onSetPageMargins(self, margins, ...)
            if document then document._zen_top_status_bar_margin_reserve = nil end
            return result
        end
    end

    local ReaderFooter = require("apps/reader/modules/readerfooter")
    if not ReaderFooter._zen_top_status_bar_toggle_patched then
        ReaderFooter._zen_top_status_bar_toggle_patched = true
        local orig_applyFooterMode = ReaderFooter.applyFooterMode
        ReaderFooter.applyFooterMode = function(self, ...)
            local result = orig_applyFooterMode(self, ...)
            -- Callers set self.mode before calling, so compare with the last applied state.
            local view = self.view
            local was_off = self._zen_top_bar_footer_off
            self._zen_top_bar_footer_off = view and footer_toggled_off(view)
            -- Callers only refresh the footer rect; refresh the header with it.
            if was_off ~= nil and is_enabled() and self._zen_top_bar_footer_off ~= was_off then
                local h = getReservedHeaderHeight()
                if h > 0 then
                    UIManager:setDirty(view.dialog, "ui", Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = h })
                end
            end
            return result
        end
    end

    if not ReaderView._zen_top_status_bar_view_mode_patched then
        ReaderView._zen_top_status_bar_view_mode_patched = true
        local orig_onSetViewMode = ReaderView.onSetViewMode
        ReaderView.onSetViewMode = function(self, new_mode, ...)
            local previous_mode = self.view_mode
            local result = orig_onSetViewMode(self, new_mode, ...)
            local typeset = self.ui and self.ui.typeset
            local highlight = self.ui and self.ui.highlight
            -- Corner selection temporarily scrolls; UpdatePos would drop its active touch.
            if previous_mode ~= self.view_mode and typeset and typeset.unscaled_margins
                    and not (highlight and highlight.restore_page_mode_func) then
                typeset:onSetPageMargins(typeset.unscaled_margins)
            end
            return result
        end
    end

    ReaderView.paintTo = function(self, bb, x, y)
        _ReaderView_paintTo_orig(self, bb, x, y)
        if bb ~= Screen.bb then return end -- offscreen renders, e.g. page-browser thumbnails
        local cfg2 = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
        if not should_show(self) then
            if _autoRefresh then
                UIManager:unschedule(_autoRefresh)
                _autoRefresh = nil
            end
            return
        end
        if not self.document then return end
        -- Guard: don't paint when reader is not active (allow overlays that
        -- belong to this ReaderUI via show_parent, e.g., AutoDim on resume).
        if not is_view_active_top(self) then
            return
        end

        local header, _widgets, header_h, screen_width, slot_regions, values = buildHeader(self)
        if not header then
            DBG("paintTo: buildHeader returned nil, skipping header paint")
            return
        end

        header:paintTo(bb, x, y)

        if type(cfg2) == "table" and cfg2.show_bottom_border then
            paintBottomBorder(bb, x, y + header_h, screen_width, cfg2, self)
            header_h = header_h + Size.line.medium
        end

        -- Store geometry for slot-scoped autonomous refreshes.
        self._zen_header_dimen = Geom:new{ x = x, y = y, w = screen_width, h = header_h }
        self._zen_header_slots = offsetSlotRegions(slot_regions, x, y)
        self._zen_header_values = values or itemValues(self, RESUME_REFRESH_ITEMS)

        -- Periodic refresh aligned with KOReader's footer minute tick.
        armAutoRefresh()
    end
end

return apply_reader_top_status_bar
