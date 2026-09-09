local function apply_reader_top_status_bar()
    --[[
        Paints a configurable three-zone header at the top of the reader screen.
        Left / center / right slots each hold an ordered list of item keys.
        Items: time, battery, battery_icon, battery_percent, wifi, frontlight, ram,
               disk, incognito, custom_text, book_title, author, chapter,
               progress_percent, current_page, total_pages, page_progress
        Wraps ReaderView.paintTo. Config via config.reader_top_status_bar.
    --]]

    local Blitbuffer    = require("ffi/blitbuffer")
    local TextWidget    = require("ui/widget/textwidget")
    local ColorTextWidget = require("common/ui/color_text_widget")
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
    local Font     = require("ui/font")
    local datetime = require("datetime")
    local UIManager = require("ui/uimanager")
    local zen_utils = require("common/utils")
    local inline_icons = require("common/inline_icon_map")
    local _ = require("gettext")
    local ReaderThemes = require("common/reader_themes")
    local Screen = Device.screen
    local CreDocument = require("document/credocument")
    local ReaderTypeset = require("apps/reader/modules/readertypeset")
    local ReaderView = require("apps/reader/modules/readerview")
    local ReaderUI = require("apps/reader/readerui")
    local _ReaderView_paintTo_orig = ReaderView.paintTo
    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")

    require("common/reader_status_bar").disableKoreaderAltStatusBar(nil, zen_plugin and zen_plugin.ui)

    local logger = require("common/zen_logger").new("reader_top_status_bar")
    local DBG = function(...) logger.dbg("", ...) end

    local function is_enabled()
        local plugin = zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
        local features = plugin and plugin.config and plugin.config.features
        return type(features) == "table" and features.reader_top_status_bar == true
    end

    local function should_show(view)
        if not is_enabled() or not view then return false end
        if view.render_mode ~= nil then
            local cfg = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
            return type(cfg) == "table" and not cfg.hide_in_cbz
        end
        return view.view_mode == "page"
    end

    local function header_text_color()
        return ReaderThemes.getTextColor(zen_plugin) or Blitbuffer.COLOR_BLACK
    end

    local function is_view_active_top(view)
        if not (view and view.ui) then return false end
        local stack = UIManager._window_stack
        local top = stack and stack[#stack]
        local top_widget = top and top.widget
        if not top_widget then return false end
        if top_widget == view.ui or top_widget == view.ui.show_parent then
            return true
        end
        local parent = top_widget.show_parent
        return parent == view.ui or parent == view.ui.show_parent
    end

    -- Stable reference so suspend/resume can cancel/restart the timer.
    local _autoRefresh
    local _charging_refresh_timer
    local _resume_refresh_timer_1
    local _resume_refresh_timer_2
    local RESUME_REFRESH_ITEMS = {
        "time", "wifi", "battery", "battery_icon", "battery_percent",
        "frontlight", "ram", "disk", "incognito",
    }
    local MINUTE_REFRESH_ITEMS = { "time", "battery", "battery_icon", "battery_percent" }

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

    local cached_disk_text, cached_disk_time = nil, 0
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
        local ok, NetworkMgr = pcall(require, "ui/network/manager")
        if not ok then return nil end
        if NetworkMgr:isWifiOn() then
            -- Gray while Wi-Fi is on but has no IP yet (searching); gate on
            -- isConnected() -- the same signal that fires onNetworkConnected ->
            -- header refresh. ssid presence lags that event, leaving a stuck icon.
            if NetworkMgr:isConnected() then
                return "\u{ECA8}", nil, colors.wifi_on
            end
            return "\u{ECA8}", nil, colors.wifi_searching, true
        end
        local cfg = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
        if type(cfg) == "table" and cfg.wifi_hide_when_off == true then return nil end
        return "\u{ECA9}", nil, colors.wifi_off
    end

    local function getRamItem()
        local now = os.time()
        if cached_ram_text and (now - cached_ram_time) < 30 then
            return "\u{EA5A}", " " .. cached_ram_text, colors.resource
        end
        local statm = io.open("/proc/self/statm", "r")
        if statm then
            local rss_pages = select(2, statm:read("*number", "*number"))
            statm:close()
            if rss_pages then
                cached_ram_text = string.format("%dM", math.floor(rss_pages / 256))
                cached_ram_time = now
                return "\u{EA5A}", " " .. cached_ram_text, colors.resource
            end
        end
        return "\u{EA5A}", " ?M", colors.resource
    end

    local function getDiskItem()
        local now = os.time()
        if cached_disk_text and (now - cached_disk_time) < 300 then
            return "\u{F0A0}", " " .. cached_disk_text, colors.resource
        end
        local paths = require("common/paths")
        local home_dir = paths.getHomeDir()
        local dirs = {}
        if home_dir and home_dir ~= "" then table.insert(dirs, home_dir) end
        for _i, p in ipairs({ "/mnt/us", "/mnt/onboard", "/sdcard", "/" }) do
            table.insert(dirs, p)
        end
        for _i, dir in ipairs(dirs) do
            local pipe = io.popen("df -h " .. dir .. " 2>/dev/null")
            if pipe then
                for line in pipe:lines() do
                    local avail = line:match("%S+%s+%S+%s+%S+%s+(%S+)")
                    if avail and avail:match("^%d") then
                        pipe:close()
                        cached_disk_text = avail
                        cached_disk_time = now
                        return "\u{F0A0}", " " .. avail, colors.resource
                    end
                end
                pipe:close()
            end
        end
        return "\u{F0A0}", " ?", colors.resource
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

    local function getPageProgressItem(doc_ctx)
        local current, total = getPageInfo(doc_ctx)
        if current == nil or total == nil then return nil end
        return ("%s / %s"):format(current, total), nil
    end

    local function getCurrentPageItem(doc_ctx)
        local current = getPageInfo(doc_ctx)
        return current ~= nil and tostring(current) or nil, nil
    end

    local function getTotalPagesItem(doc_ctx)
        local total = select(2, getPageInfo(doc_ctx))
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

    local item_fetchers = {
        wifi        = getWifiItem,
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
                    table.insert(texts, {
                        text = text,
                        icon = icon,
                        label = label,
                        color = color and (use_color or force_color) and color or nil,
                    })
                end
            end
        end
        return texts
    end

    local function measureTextsWidth(texts, face, sep)
        if type(texts) ~= "table" or #texts == 0 then return 0 end
        local total = 0
        for i = 1, #texts do
            if i > 1 and sep ~= "" then
                local sep_w = TextWidget:new{
                    text = sep,
                    face = face,
                    padding = 0,
                }
                total = total + sep_w:getSize().w
                sep_w:free()
            end
            local tw = TextWidget:new{
                text = texts[i].text,
                face = face,
                fgcolor = header_text_color(),
                padding = 0,
            }
            total = total + tw:getSize().w
            tw:free()
        end
        return total
    end

    -- Builds a HorizontalGroup from pre-collected texts.
    -- If max_width is set and content overflows, rebuilds as a single ellipsis-truncated TextWidget.
    -- Returns (group_or_nil, widgets_list, natural_width).
    local function buildGroupFromTexts(texts, face, sep, max_width)
        if type(texts) ~= "table" or #texts == 0 then return nil, {}, 0 end
        if max_width and max_width <= 0 then return nil, {}, measureTextsWidth(texts, face, sep) end
        local group = HorizontalGroup:new{}
        local widgets = {}
        local natural_w = measureTextsWidth(texts, face, sep)
        for i = 1, #texts do
            if i > 1 and sep ~= "" then
                local sep_w = TextWidget:new{
                    text = sep,
                    face = face,
                    fgcolor = header_text_color(),
                    padding = 0,
                }
                table.insert(group, sep_w)
                table.insert(widgets, sep_w)
            end
            local entry = texts[i]
            if entry.color and entry.icon ~= "" then
                local icon_w = ColorTextWidget:new{
                    text = entry.icon,
                    face = face,
                    fgcolor = entry.color,
                    padding = 0,
                }
                table.insert(group, icon_w)
                table.insert(widgets, icon_w)
                if entry.label and entry.label ~= "" then
                    local label_w = TextWidget:new{
                        text = entry.label,
                        face = face,
                        fgcolor = header_text_color(),
                        padding = 0,
                    }
                    table.insert(group, label_w)
                    table.insert(widgets, label_w)
                end
            else
                local tw = TextWidget:new{
                    text = entry.text,
                    face = face,
                    fgcolor = header_text_color(),
                    padding = 0,
                }
                table.insert(group, tw)
                table.insert(widgets, tw)
            end
        end

        if max_width and natural_w > max_width then
            for _i, w in ipairs(widgets) do if w.free then w:free() end end
            local joined = texts[1] and texts[1].text or ""
            for i = 2, #texts do joined = joined .. sep .. texts[i].text end
            local tw = TextWidget:new{
                text      = joined,
                face      = face,
                fgcolor   = header_text_color(),
                padding   = 0,
                max_width = max_width,
            }
            return HorizontalGroup:new{ tw }, { tw }, natural_w
        end
        return group, widgets, natural_w
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
            local flow_ticks = {}
            for _i, pageno in ipairs(ticks) do
                if document:getPageFlow(pageno) == flow then
                    table.insert(flow_ticks, document:getPageNumberInFlow(pageno))
                end
            end
            return flow_ticks, document:getTotalPagesInFlow(flow)
        end
        return ticks, last
    end

    local function paintBottomBorder(bb, x, y, width, cfg, doc_ctx)
        local h_margin = Screen:scaleBySize(10)
        local line_w = math.max(0, width - 2 * h_margin)
        if line_w <= 0 then return end
        local line_h = Size.line.medium
        if type(cfg) == "table" and cfg.bottom_border_progress == true then
            bb:paintRect(x + h_margin, y, line_w, line_h, Blitbuffer.COLOR_LIGHT_GRAY)
            local percent = getProgressRatio(doc_ctx)
            if percent and percent > 0 then
                local progress_w = math.ceil(line_w * percent)
                if progress_w > line_w then progress_w = line_w end
                bb:paintRect(x + h_margin, y, progress_w, line_h, Blitbuffer.COLOR_GRAY_5)
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
                            bb:paintRect(x + h_margin + tick_x, y, tick_w, line_h,
                                Blitbuffer.COLOR_BLACK)
                        end
                    end
                end
            end
        else
            local border = LineWidget:new{
                dimen = Geom:new{ w = line_w, h = line_h },
            }
            border:paintTo(bb, x + h_margin, y)
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

    local function getHeaderFace(cfg)
        local footer_settings = G_reader_settings:readSetting("footer")
        local face_cfg = type(cfg) == "table" and cfg.font_face or "default"
        local font_name = face_cfg == "default"
            and ((footer_settings and footer_settings.text_font_face) or "NotoSans-Regular.ttf")
            or face_cfg
        local font_size = type(cfg) == "table" and cfg.font_size or 14
        return Font:getFace(font_name, font_size)
    end

    local function getReservedHeaderHeight(view)
        if not is_enabled() or view.footer.reclaim_height then return 0 end
        local cfg = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
        local orders = getSlotOrders(cfg)
        if #orders.left == 0 and #orders.center == 0 and #orders.right == 0 then return 0 end

        local height = view.footer:getHeight()
        if type(cfg) == "table" and cfg.show_bottom_border == true then
            height = height + Size.line.medium
        end
        return height
    end

    local function slotsContaining(cfg, item_keys)
        local wanted = {}
        for _i, key in ipairs(item_keys or {}) do wanted[key] = true end
        local orders = getSlotOrders(cfg)
        local slots = {}
        for _i, slot in ipairs({ "left", "center", "right" }) do
            for _j, key in ipairs(orders[slot]) do
                if wanted[key] then
                    table.insert(slots, slot)
                    break
                end
            end
        end
        return slots
    end

    -- Builds the header widget from current config.
    -- doc_ctx: ReaderView (or nil); needed for book_title, author, chapter items.
    -- Returns header, widgets, height, width, and per-slot regions; or nil if empty.
    local function buildHeader(doc_ctx)
        local screen_width = Screen:getWidth()
        local cfg = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
        local face = getHeaderFace(cfg)

        local top_pad = Size.padding.small
        local h_pad   = Screen:scaleBySize(10)
        -- Include custom dogear sizing and right offsets from companion plugins.
        local dogear = doc_ctx and doc_ctx.dogear
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

        local all_widgets = {}

        local left_sep = slot_sep("left")
        local center_sep = slot_sep("center")
        local right_sep = slot_sep("right")

        local left_texts = collectItemTexts(left_order, doc_ctx)
        local center_texts = collectItemTexts(center_order, doc_ctx)
        local right_texts = collectItemTexts(right_order, doc_ctx)

        local left_has = #left_texts > 0
        local center_has = #center_texts > 0
        local right_has = #right_texts > 0

        local left_nat = measureTextsWidth(left_texts, face, left_sep)
        local center_nat = measureTextsWidth(center_texts, face, center_sep)
        local right_nat = measureTextsWidth(right_texts, face, right_sep)

        local left_pad = left_has and h_pad or 0
        local right_pad = right_has and h_pad + right_inset or 0

        local left_cap = 0
        local center_cap = 0
        local right_cap = 0
        local left_w = 0
        local center_w = 0
        local right_w = 0
        local middle_w = 0

        if center_has then
            local max_center = math.max(0, screen_width - left_pad - right_pad)
            center_cap = math.min(center_nat, max_center)
            center_w = center_cap

            local side_total = screen_width - center_w
            left_w = math.floor(side_total / 2)
            right_w = side_total - left_w

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
                left_cap = math.max(0, screen_width - left_pad)
                left_w = screen_width
            elseif right_has then
                right_cap = math.max(0, screen_width - right_pad)
                right_w = screen_width
            end
        end

        local left_grp, left_ws = buildGroupFromTexts(left_texts, face, left_sep, left_cap)
        local center_grp, center_ws = buildGroupFromTexts(center_texts, face, center_sep, center_cap)
        local right_grp, right_ws = buildGroupFromTexts(right_texts, face, right_sep, right_cap)

        for _i, w in ipairs(left_ws)   do table.insert(all_widgets, w) end
        for _i, w in ipairs(center_ws) do table.insert(all_widgets, w) end
        for _i, w in ipairs(right_ws)  do table.insert(all_widgets, w) end

        if not left_grp and not center_grp and not right_grp then
            DBG("buildHeader: all groups nil, doc_ctx=", doc_ctx and "present" or "nil",
                "left_order=", #left_order, "center_order=", #(center_order or {}), "right_order=", #right_order)
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
                        HorizontalSpan:new{ width = h_pad },
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
                        HorizontalSpan:new{ width = h_pad },
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
            local left_content_w = math.min(screen_width, h_pad + left_grp:getSize().w)
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

        return header, all_widgets, header_h, screen_width, slot_regions
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

    local function freeWidgets(widgets)
        for _i, widget in ipairs(widgets or {}) do
            if widget.free then widget:free() end
        end
    end

    -- Rebuilds the header, but clears and flushes only slots containing the
    -- items affected by the timer or event.
    local function repaintHeaderSlots(view, item_keys)
        if not should_show(view) then return end
        local stack = UIManager._window_stack
        local top = stack and stack[#stack]
        local top_widget = top and top.widget
        if not (top_widget == view.ui or top_widget == (view.ui and view.ui.show_parent)) then return end
        if not view._zen_header_dimen then
            DBG("repaintHeaderSlots SKIP: no _zen_header_dimen (paintTo never ran?)")
            return
        end
        if not view.ui then
            DBG("repaintHeaderSlots SKIP: view.ui is nil")
            return
        end
        local header, all_widgets, header_h, screen_width, relative_slots = buildHeader(view)
        if not header then
            DBG("repaintHeaderSlots SKIP: buildHeader returned nil")
            return
        end
        local cfg2 = zen_plugin and zen_plugin.config and zen_plugin.config.reader_top_status_bar
        local target_slots = slotsContaining(cfg2, item_keys)
        if #target_slots == 0 then
            freeWidgets(all_widgets)
            return
        end
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
        if #refresh_regions == 0 then
            view._zen_header_slots = current_slots
            freeWidgets(all_widgets)
            return
        end

        local refresh_dither = top_widget and top_widget.dithered or nil
        local bb = Screen.bb
        if bb then
            local background = type(ReaderThemes.getBackgroundColor) == "function"
                and ReaderThemes.getBackgroundColor(zen_plugin) or Blitbuffer.COLOR_WHITE
            for _i, region in ipairs(refresh_regions) do
                bb:paintRect(region.x, region.y, region.w, region.h, background)
            end
        end
        UIManager:widgetRepaint(header, dimen.x, dimen.y)
        if view.dogear_visible and view.dogear and type(view.dogear.paintTo) == "function" then
            view.dogear:paintTo(Screen.bb, dimen.x, dimen.y)
        end
        for _i, region in ipairs(refresh_regions) do
            UIManager:setDirty(nil, "ui", region, refresh_dither)
        end
        view._zen_header_slots = current_slots
        freeWidgets(all_widgets)
    end

    local function activeReaderView(rui)
        local reader = rui and rui.view and rui or ReaderUI.instance
        return reader and reader.view
    end

    local function repaintActiveHeaderSlots(item_keys, rui)
        local view = activeReaderView(rui)
        if not (view and view.ui and view.ui.document) or not should_show(view) then return end
        if is_view_active_top(view) then
            repaintHeaderSlots(view, item_keys)
        end
    end

    local function autoRefresh()
        local view = activeReaderView()
        if not (view and view.ui and view.ui.document) or not should_show(view) then
            _autoRefresh = nil
            return
        end
        if is_view_active_top(view) then
            repaintHeaderSlots(view, MINUTE_REFRESH_ITEMS)
        end
        local t = os.date("*t")
        UIManager:scheduleIn(60 - t.sec, autoRefresh)
    end

    local function armAutoRefresh()
        if _autoRefresh then return end
        _autoRefresh = autoRefresh
        local t = os.date("*t")
        UIManager:scheduleIn(60 - t.sec, _autoRefresh)
    end

    local function cancelRefreshTimers(clear_auto_refresh)
        if _autoRefresh then
            UIManager:unschedule(_autoRefresh)
            if clear_auto_refresh then _autoRefresh = nil end
        end
        if _charging_refresh_timer then
            UIManager:unschedule(_charging_refresh_timer)
            _charging_refresh_timer = nil
        end
        if _resume_refresh_timer_1 then
            UIManager:unschedule(_resume_refresh_timer_1)
            _resume_refresh_timer_1 = nil
        end
        if _resume_refresh_timer_2 then
            UIManager:unschedule(_resume_refresh_timer_2)
            _resume_refresh_timer_2 = nil
        end
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
            if _resume_refresh_timer_1 then UIManager:unschedule(_resume_refresh_timer_1) end
            if _resume_refresh_timer_2 then UIManager:unschedule(_resume_refresh_timer_2) end
            _resume_refresh_timer_1 = function()
                _resume_refresh_timer_1 = nil
                repaintActiveHeaderSlots(RESUME_REFRESH_ITEMS)
            end
            _resume_refresh_timer_2 = function()
                _resume_refresh_timer_2 = nil
                repaintActiveHeaderSlots(RESUME_REFRESH_ITEMS)
            end
            UIManager:scheduleIn(0.6, _resume_refresh_timer_1)
            UIManager:scheduleIn(1.8, _resume_refresh_timer_2)
            local now_t = os.date("*t")
            UIManager:scheduleIn(60 - now_t.sec, _autoRefresh)
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

        local orig_onClose = ReaderUI.onClose
        ReaderUI.onClose = function(rui, ...)
            cancelRefreshTimers(true)
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
                    and self.view.view_mode == "page" and getReservedHeaderHeight(self.view) or 0
            end
            local result = orig_onSetPageMargins(self, margins, ...)
            if document then document._zen_top_status_bar_margin_reserve = nil end
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

        local header, all_widgets, header_h, screen_width, slot_regions = buildHeader(self)
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

        -- Free FFI-backed TextWidget memory immediately after paint.
        for _i, w in ipairs(all_widgets) do
            if w.free then w:free() end
        end

        -- Periodic refresh aligned to the top of each minute.
        armAutoRefresh()
    end
end

return apply_reader_top_status_bar
