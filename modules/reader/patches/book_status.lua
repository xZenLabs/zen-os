local function apply_book_status()
    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")

    -- Use KOReader's native "show Book Status at end of book" setting rather
    -- than hooking onEndOfBook ourselves.
    G_reader_settings:saveSetting("end_document_action", "book_status")

    -- Auto-mark the book as finished (summary.status = "complete") when the
    -- reader hits the end. ReaderStatus:onEndOfBook checks this before showing
    -- the Book Status widget, so it opens with "Finished" already selected.
    G_reader_settings:saveSetting("end_document_auto_mark", true)

    -- Always use the ZenOS custom Book Status layout (home + close buttons, cleaner stats)
    local BookStatusWidget = require("ui/widget/bookstatuswidget")
    local book_status = require("common/book_status")
    local library_navigation = require("common/library_navigation")
    local utils = require("common/utils")
    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")

    local _icons_dir
    local plugin_root = require("common/plugin_root")
    if plugin_root then _icons_dir = plugin_root .. "/icons/" end
    local _stock_icons_dir = require("libs/libkoreader-lfs").currentdir()
        .. "/resources/icons/mdlight/"

    local function resolve_icon(name)
        return utils.resolveIcon(_icons_dir, name)
            or utils.resolveLocalIcon(utils.getUserIconsDir(), name)
            or utils.resolveLocalIcon(_stock_icons_dir, name)
    end

    local function library_home_icon()
        local get_default_tab_icon = rawget(_G, "__ZEN_UI_NAVBAR_DEFAULT_TAB_ICON")
        local icon = type(get_default_tab_icon) == "function" and get_default_tab_icon()
        if type(icon) ~= "string" or icon == "" then
            local config = zen_plugin and zen_plugin.config
            local menu = type(config) == "table" and config.menu
            icon = type(menu) == "table" and menu.library_home_icon or "library"
        end
        return resolve_icon(icon) or resolve_icon("library")
    end

    if not BookStatusWidget._zen_status_cache_invalidation
            and type(BookStatusWidget.onChangeBookStatus) == "function" then
        BookStatusWidget._zen_status_cache_invalidation = true
        local original_onChangeBookStatus = BookStatusWidget.onChangeBookStatus
        function BookStatusWidget:onChangeBookStatus(...)
            local result = original_onChangeBookStatus(self, ...)
            local file = self.ui and self.ui.document and self.ui.document.file
            book_status.invalidate(file)
            return result
        end
    end

    local ok_reader_status, ReaderStatus = pcall(require, "apps/reader/modules/readerstatus")
    if ok_reader_status and not ReaderStatus._zen_status_cache_invalidation
            and type(ReaderStatus.markBook) == "function" then
        ReaderStatus._zen_status_cache_invalidation = true
        local original_markBook = ReaderStatus.markBook
        function ReaderStatus:markBook(...)
            local result = original_markBook(self, ...)
            local file = self.document and self.document.file
                or self.ui and self.ui.document and self.ui.document.file
            book_status.invalidate(file)
            return result
        end
    end

    -- Closing Book Status does not emit CloseDocument, so KOSync misses the final page.
    if ok_reader_status and not ReaderStatus._zen_end_of_book_progress_sync
            and type(ReaderStatus.onEndOfBook) == "function" then
        ReaderStatus._zen_end_of_book_progress_sync = true
        local original_onEndOfBook = ReaderStatus.onEndOfBook
        function ReaderStatus:onEndOfBook(...)
            local result = original_onEndOfBook(self, ...)
            local status_widget = UIManager:getTopmostVisibleWidget()
            if getmetatable(status_widget) == BookStatusWidget then
                local original_onCloseWidget = status_widget.onCloseWidget
                function status_widget:onCloseWidget(...)
                    local kosync = self.ui and self.ui.kosync
                    local settings = kosync and kosync.settings
                    if self.summary and self.summary.status == "complete"
                            and settings and settings.auto_sync
                            and settings.username and settings.userkey then
                        UIManager:broadcastEvent(Event:new("KOSyncPushProgress"))
                    end
                    if original_onCloseWidget then
                        return original_onCloseWidget(self, ...)
                    end
                end
            end
            return result
        end
    end

    BookStatusWidget.getStatusContent = function(self, width)
        local _ = require("gettext")
        local Size = require("ui/size")
        local Device = require("device")
        local Screen = Device.screen
        local ZenIconButton = require("common/ui/zen_icon_button")
        local Button = require("ui/widget/button")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local Geom = require("ui/geometry")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan = require("ui/widget/horizontalspan")
        local VerticalGroup = require("ui/widget/verticalgroup")
        local VerticalSpan = require("ui/widget/verticalspan")
        local is_landscape = Screen:getScreenMode() == "landscape"

        -- Build a custom header row instead of TitleBar so both icons share the
        -- same HorizontalGroup centerline, compensating for the home SVG's
        -- built-in top whitespace that TitleBar's top-aligned OverlapGroup exposes.
        local DGENERIC_ICON_SIZE = G_defaults:readSetting("DGENERIC_ICON_SIZE")
        local close_size = Screen:scaleBySize(DGENERIC_ICON_SIZE * 0.85)
        local home_size  = Screen:scaleBySize(DGENERIC_ICON_SIZE * 1.1)
        local btn_pad    = Screen:scaleBySize(6)

        local home_callback = function()
            local ui = self.ui
            if self.updated then
                ui.doc_settings:flush()
            end
            UIManager:close(self)
            if ui and ui.document then
                library_navigation.showFromReader(ui, zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN"))
            end
        end

        -- "Open next file" is only offered by KOReader when the folder collate
        -- order supports sequential navigation (not by access/date).
        local collate = G_reader_settings:readSetting("collate")
        local next_file_enabled = collate ~= "access" and collate ~= "date"

        local open_next_file_callback = function()
            local ui = self.ui
            if self.updated then
                ui.doc_settings:flush()
            end
            UIManager:close(self)
            UIManager:scheduleIn(0, function()
                if ui and ui.status then
                    ui.status:onOpenNextOrPreviousFileInFolder()
                end
            end)
        end

        -- On key devices, page-forward opens the next sequential file when
        -- available; otherwise it returns to the library.
        if Device:hasKeys() then
            if next_file_enabled then
                self.key_events.ZenOpenNextFile = { { Device.input.group.PgFwd } }
                self.onZenOpenNextFile = function()
                    open_next_file_callback()
                    return true
                end
            else
                self.key_events.ZenGoLibrary = { { Device.input.group.PgFwd } }
                self.onZenGoLibrary = function()
                    home_callback()
                    return true
                end
            end
        end

        local close_btn = ZenIconButton:new{
            file = resolve_icon("chevron.left"),
            width = close_size, height = close_size,
            padding = btn_pad,
            show_parent = self,
            callback = function() self:onClose() end,
        }
        local home_btn = ZenIconButton:new{
            file = library_home_icon(),
            width = home_size, height = home_size,
            padding = btn_pad,
            show_parent = self,
            callback = home_callback,
        }

        -- Center-align keeps both icons on the same horizontal midline. In
        -- landscape, keep the touch targets clear of the screen edges.
        local header_inset = is_landscape and self.padding or 0
        local close_btn_size = close_btn:getSize()
        local home_btn_size = home_btn:getSize()
        local header_row = HorizontalGroup:new{
            align = "center",
            close_btn,
            HorizontalSpan:new{
                width = math.max(0, width - header_inset * 2
                    - close_btn_size.w - home_btn_size.w),
            },
            home_btn,
        }
        local title_bar = VerticalGroup:new{
            CenterContainer:new{
                dimen = Geom:new{
                    w = width,
                    h = math.max(close_btn_size.h, home_btn_size.h),
                },
                header_row,
            },
            VerticalSpan:new{ width = Size.padding.default },
        }

        local stats_header = self:genHeader(_("Statistics"))
        local review_header = self:genHeader(_("Review"))
        local status_header = self:genHeader(self.readonly and _("Book Status") or _("Update Status"))

        -- Keep actions beside the stars in landscape so KOReader's fixed-height
        -- book-info panel does not overflow into the Statistics section.
        local book_info_width = width
        if is_landscape then
            book_info_width = width - math.floor(width * 0.05) - Screen:scaleBySize(132)
        end
        local action_width = next_file_enabled and math.floor(book_info_width * 0.27)
            or math.floor(book_info_width * 0.55)
        local action_gap = Screen:scaleBySize(8)
        local restart_book_btn = Button:new{
            text = _("Restart Book"),
            width = action_width,
            show_parent = self,
            callback = function()
                local ui = self.ui
                if self.updated then
                    ui.doc_settings:flush()
                end
                UIManager:close(self)
                UIManager:scheduleIn(0, function()
                    UIManager:broadcastEvent(Event:new("GotoPage", 1))
                end)
            end,
        }
        local next_file_btn
        if next_file_enabled then
            next_file_btn = Button:new{
                text = _("Open next file"),
                width = action_width,
                preselect = true, -- inverts colors: black bg, white text
                show_parent = self,
                callback = open_next_file_callback,
            }
        end
        local orig_generateRateGroup = BookStatusWidget.generateRateGroup
        self.generateRateGroup = function(s, w, h, rating)
            local btn_row
            if next_file_btn then
                btn_row = HorizontalGroup:new{
                    align = "center",
                    restart_book_btn,
                    HorizontalSpan:new{ width = action_gap },
                    next_file_btn,
                }
            else
                btn_row = restart_book_btn
            end
            if is_landscape then
                local btn_row_width = action_width
                if next_file_btn then
                    btn_row_width = action_width * 2 + action_gap
                end
                local stars_width = math.max(0, book_info_width - btn_row_width - action_gap)
                local stars = orig_generateRateGroup(s, stars_width, h, rating)
                local action_row = HorizontalGroup:new{
                    align = "center",
                    btn_row,
                    HorizontalSpan:new{ width = action_gap },
                    stars,
                }
                local row_lift = Screen:scaleBySize(6)
                return VerticalGroup:new{
                    VerticalSpan:new{ width = -row_lift },
                    action_row,
                    VerticalSpan:new{ width = row_lift },
                }
            end
            local stars = orig_generateRateGroup(s, w, h, rating)
            local btn_h = restart_book_btn:getSize().h
            return VerticalGroup:new{
                CenterContainer:new{
                    dimen = Geom:new{ w = w, h = btn_h },
                    btn_row,
                },
                VerticalSpan:new{ width = Screen:scaleBySize(6) },
                stars,
            }
        end
        local book_info_group = self:genBookInfoGroup()
        self.generateRateGroup = nil -- remove instance override

        local summary_group = self:genSummaryGroup(width)
        -- Only open review dialog when the tap is within the note frame bounds
        if self.note_frame then
            self.note_frame.onGesture = function(frame, ev)
                if ev and ev.ges == "tap" and ev.pos
                        and frame.dimen and frame.dimen:contains(ev.pos) then
                    return self:openReviewDialog()
                end
            end
        end

        local switch_group = self:generateSwitchGroup(width)

        -- Keep the existing star selection while making the header and restart
        -- controls reachable by moving upward through the focus layout.
        table.insert(self.layout, 1, { close_btn, home_btn })
        table.insert(self.layout, 2, { restart_book_btn })
        self.selected.y = self.selected.y + 2

        local content = VerticalGroup:new{
            align = "left",
            title_bar,
            book_info_group,
            stats_header,
            self:genStatisticsGroup(width),
            review_header,
            summary_group,
            status_header,
            switch_group,
        }

        local headers = { stats_header, review_header, status_header }
        for _i, header in ipairs(headers) do header[1].width = 0 end

        local overflow = content:getSize().h - Screen:getHeight()
        if overflow > 0 and self.note_widget and self.note_widget.height then
            local old_note_widget = self.note_widget
            local note_height = math.max(old_note_widget.line_height_px,
                old_note_widget.height - overflow)
            if note_height < old_note_widget.height then
                local TextBoxWidget = require("ui/widget/textboxwidget")
                self.note_widget = TextBoxWidget:new{
                    text = old_note_widget.text,
                    face = self.medium_font_face,
                    width = old_note_widget.width,
                    height = note_height,
                    scroll = true,
                    readonly = self.readonly,
                    parent = self,
                }
                self.note_frame[1] = self.note_widget
                old_note_widget:free()
                summary_group[2].dimen.h = math.max(self.note_frame:getSize().h,
                    summary_group[2].dimen.h - old_note_widget.height + note_height)
                summary_group:resetLayout()
                content:resetLayout()
            end
        end

        local free_height = math.max(0, Screen:getHeight() - content:getSize().h)
        local gap_height = math.floor(free_height / #headers)
        local extra = free_height % #headers
        for _i, header in ipairs(headers) do
            header[1].width = gap_height + (_i <= extra and 1 or 0)
            header:resetLayout()
        end
        content:resetLayout()
        return content
    end
end

return apply_book_status
