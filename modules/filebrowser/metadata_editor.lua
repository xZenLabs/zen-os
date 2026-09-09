local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local Menu = require("ui/widget/menu")
local ConfirmBox = require("ui/widget/confirmbox")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CoverUtils = require("common/cover_utils")
local IconItem = require("common/ui/icon_menu_item")
local icons = require("common/inline_icon_map")
local LanguageName = require("common/language_name")
local SolidCircle = require("common/ui/zen_solid_circle")
local ZenModalClose = require("common/ui/zen_modal_close")
local ZenButton = require("common/ui/zen_button")
local ZenSettingsTitleBar = require("common/ui/zen_settings_titlebar")
local CoverWidget = require("modules/filebrowser/patches/home/widgets/cover_common")
local logger = require("common/zen_logger").new("metadata_editor")
local _ = require("gettext")
local T = require("ffi/util").template

local Screen = Device.screen
local EMPTY = _("Not set")
local FIELD_ORDER = {
    "title", "authors", "series", "genres", "language", "publisher", "description",
}

local FIELD_SPECS = {
    title = { label = _("Title") },
    authors = { label = _("Authors"), list = true },
    series = { label = _("Series") },
    genres = { label = _("Genres"), list = true },
    language = { label = _("Language") },
    publisher = { label = _("Publisher") },
    description = { label = _("Description"), long = true },
}

local function trim(value)
    value = type(value) == "string" and value or tostring(value or "")
    return value:match("^%s*(.-)%s*$")
end

local function valid_number(value)
    local number = tonumber(trim(value))
    return number and number == number and number ~= math.huge and number ~= -math.huge
end

local function copy_value(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = copy_value(item) end
    return copy
end

local function normalize_list(value)
    if type(value) == "string" then
        local values = {}
        value = value:gsub("\r\n", "\n"):gsub("\r", "\n") .. "\n"
        for line in value:gmatch("(.-)\n") do
            line = trim(line)
            if line ~= "" then values[#values + 1] = line end
        end
        return values
    end
    local values = {}
    for _i, item in ipairs(type(value) == "table" and value or {}) do
        item = trim(item)
        if item ~= "" then values[#values + 1] = item end
    end
    return values
end

local function normalize_draft(value)
    value = type(value) == "table" and value or {}
    return {
        title = trim(value.title),
        authors = normalize_list(value.authors),
        series_name = trim(value.series_name or value.series),
        series_index = trim(value.series_index),
        genres = normalize_list(value.genres or value.keywords),
        language = trim(value.language),
        publisher = trim(value.publisher),
        description = trim(value.description),
        isbn = trim(value.isbn),
    }
end

local function same_value(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    if #left ~= #right then return false end
    for index, value in ipairs(left) do
        if not same_value(value, right[index]) then return false end
    end
    return true
end

local function join_list(value, separator)
    return table.concat(type(value) == "table" and value or {}, separator or ", ")
end

local function series_text(draft)
    if draft.series_name == "" then return "" end
    if draft.series_index == "" then return draft.series_name end
    return draft.series_name .. " #" .. tostring(draft.series_index)
end

local function preview(value)
    value = tostring(value or ""):gsub("%s+", " ")
    return value ~= "" and value or EMPTY
end

local function has_value(key, draft)
    if key == "authors" or key == "genres" then return #draft[key] > 0 end
    if key == "series" then return draft.series_name ~= "" end
    return draft[key] ~= ""
end

local function file_name(file)
    return tostring(file or ""):match("([^/\\]+)$") or tostring(file or "")
end

local function file_extension(file)
    return file_name(file):match("(%.[^.]*)$") or ""
end

local function paint_focus_rectangle(bb, x, y, width, height, outset)
    outset = outset or 0
    x, y = x - outset, y - outset
    width, height = width + outset * 2, height + outset * 2
    local line = math.max(1, Screen:scaleBySize(2))
    bb:invertRect(x, y, width, line)
    bb:invertRect(x, y + height - line, width, line)
    if height > line * 2 then
        bb:invertRect(x, y + line, line, height - line * 2)
        bb:invertRect(x + width - line, y + line, line, height - line * 2)
    end
end

local MetadataEditor = Menu:extend{}

local CoverTap = InputContainer:extend{}

function CoverTap:init()
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
    self.ges_events = {
        TapCover = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function CoverTap:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self[1]:paintTo(bb, x, y)
    if self.focused then
        paint_focus_rectangle(bb, x, y, self.dimen.w, self.dimen.h,
            Screen:scaleBySize(2))
    end
end

function CoverTap:onTapCover()
    return self.editor:_editCover()
end

local FieldTap = InputContainer:extend{}

function FieldTap:init()
    local size = self[1]:getSize()
    self.dimen = Geom:new{ x = 0, y = 0, w = size.w, h = size.h }
    self.ges_events = {
        TapField = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
end

function FieldTap:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self[1]:paintTo(bb, x, y)
    if self.focused then
        paint_focus_rectangle(bb, x, y, self.dimen.w, self.dimen.h,
            Screen:scaleBySize(2))
    end
end

function FieldTap:onTapField()
    if self.enabled and self.callback then self.callback() end
    return true
end

function FieldTap:onFocus()
    if self.editor.getFocusItem and self.editor:getFocusItem() ~= self then return false end
    self.focused = true
    UIManager:setDirty(self.editor, "fast", self.dimen)
    return true
end

function FieldTap:onUnfocus()
    if not self.focused then return false end
    self.focused = false
    UIManager:setDirty(self.editor, "fast", self.dimen)
    return true
end

CoverTap.onFocus = FieldTap.onFocus
CoverTap.onUnfocus = FieldTap.onUnfocus

local function zen_button(options, filled, radius)
    local button = Button:new(options)
    button._zen_filled = filled == true
    button.paintTo = function(self, bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        local paint_filled = self._zen_filled ~= (self._zen_focused == true)
        local max_text_width = math.max(1, self.dimen.w - Screen:scaleBySize(12))
        if paint_filled then
            ZenButton.paintFilled(bb, x, y, self.dimen.w, self.dimen.h,
                self.text, self.text_font_size, radius, max_text_width)
        else
            ZenButton.paintOutlined(bb, x, y, self.dimen.w, self.dimen.h,
                self.text, self.text_font_size, radius, Screen:scaleBySize(1),
                max_text_width)
        end
        if self._zen_focused then
            paint_focus_rectangle(bb, x, y, self.dimen.w, self.dimen.h,
                Screen:scaleBySize(2))
        end
    end
    button.onFocus = function(self)
        self._zen_focused = true
        UIManager:setDirty(self.show_parent, "fast", self.dimen)
        return true
    end
    button.onUnfocus = function(self)
        self._zen_focused = false
        UIManager:setDirty(self.show_parent, "fast", self.dimen)
        return true
    end
    button._doFeedbackHighlight = function() end
    button._undoFeedbackHighlight = function() end
    return button
end

local function uniform_covers_enabled()
    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    local config = type(plugin) == "table" and plugin.config
        or require("config/manager").get()
    return type(config) == "table" and type(config.features) == "table"
        and config.features.browser_cover_mosaic_uniform == true
end

local function cover_thumbnail(source, max_w, max_h, face, color)
    local border = CoverUtils.BORDER_SIZE or Size.border.thin
    local inner_w = math.max(1, max_w - 2 * border)
    local inner_h = math.max(1, max_h - 2 * border)
    local uniform = uniform_covers_enabled()
    local cover
    if source and source.file then
        cover = CoverUtils.loadExplicitCover(source.file)
    elseif source and source.image and type(source.image.copy) == "function" then
        local ok_copy, image = pcall(source.image.copy, source.image)
        if ok_copy and image then
            local ok_size, width, height = pcall(function()
                return image:getWidth(), image:getHeight()
            end)
            if ok_size then
                cover = { data = image, w = width, h = height }
            elseif type(image.free) == "function" then
                image:free()
            end
        end
    end
    if cover then
        local width, height
        if uniform then
            width, height = CoverUtils.calcDims(inner_w, inner_h)
        else
            width, height = CoverUtils.fitDims(inner_w, inner_h, cover.w, cover.h)
        end
        local frame = CoverUtils.drawSingle(cover, inner_w, inner_h, border, uniform)
        return CoverWidget.decorate_cover_frame(frame), width + 2 * border, height + 2 * border
    end
    local width, height = CoverUtils.calcDims(inner_w, inner_h)
    local frame = FrameContainer:new{
        width = width + 2 * border,
        height = height + 2 * border,
        padding = 0,
        bordersize = border,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = height },
            TextWidget:new{ text = "—", face = face, fgcolor = color },
        },
    }
    return CoverWidget.decorate_cover_frame(frame), width + 2 * border, height + 2 * border
end

function MetadataEditor:_fieldChanged(key)
    if key == "series" then
        return self.draft.series_name ~= self.original.series_name
            or self.draft.series_index ~= self.original.series_index
    end
    return not same_value(self.draft[key], self.original[key])
end

function MetadataEditor:isDirty()
    return self:isMetadataDirty() or self.pending_cover ~= nil
end

function MetadataEditor:isMetadataDirty()
    for _i, key in ipairs(FIELD_ORDER) do
        if (key ~= "publisher" or self.is_epub) and self:_fieldChanged(key) then
            return true
        end
    end
    return false
end

function MetadataEditor:getDraft()
    return copy_value(self.draft)
end

function MetadataEditor:getPendingCover()
    return self.pending_cover and self.pending_cover.path or nil
end

function MetadataEditor:getPendingCoverSource()
    return self.pending_cover and self.pending_cover.source or nil
end

function MetadataEditor:setPendingCover(path, temporary, source)
    if type(path) ~= "string" or path == "" then return false end
    if self.pending_cover and self.pending_cover.temporary then
        os.remove(self.pending_cover.path)
    end
    self.pending_cover = {
        path = path,
        temporary = temporary == true,
        source = source,
    }
    logger.dbg("cover staged source=", tostring(source), " temporary=", tostring(temporary == true))
    self:_refresh("cover")
    if self._cover_picker then UIManager:setDirty(self._cover_picker, "ui") end
    return true
end

function MetadataEditor:clearPendingCover()
    if self.pending_cover and self.pending_cover.temporary then
        os.remove(self.pending_cover.path)
    end
    self.pending_cover = nil
    logger.dbg("staged cover cleared")
    self:_refresh("cover")
    if self._cover_picker then UIManager:setDirty(self._cover_picker, "ui") end
end

function MetadataEditor:markMetadataSaved()
    self.original = copy_value(self.draft)
    self:_syncTitleAction()
end

function MetadataEditor:_fieldPreview(key)
    if key == "authors" or key == "genres" then
        return preview(join_list(self.draft[key]))
    elseif key == "series" then
        return preview(series_text(self.draft))
    elseif key == "language" and self.draft.language ~= "" then
        local name = LanguageName.get(self.draft.language)
        if name ~= self.draft.language then
            return T(_("%1 · %2"), name, self.draft.language)
        end
    end
    return preview(self.draft[key])
end

function MetadataEditor:_buildItems()
    local items = {}
    local caret = BD.mirroredUILayout() and "chevron.left" or "chevron.right"
    items[#items + 1] = {
        text = _("Book details"),
        _zen_display_text = _("Book details"),
        _zen_settings_row = true,
        _zen_settings_content_func = function(width, height, face, enabled)
            return self:_bookDetailsContent(width, height, face, enabled)
        end,
        _zen_focus_border_only = true,
        _metadata_key = "details",
        callback = function() self:_editCover() end,
    }
    items[#items + 1] = {
        text = _("Description"),
        _zen_display_text = _("Description"),
        _zen_settings_row = true,
        _zen_settings_content_func = function(width, height, face, enabled)
            return self:_descriptionContent(width, height, face, enabled)
        end,
        _zen_focus_border_only = true,
        _zen_has_submenu = true,
        _zen_caret_icon = caret,
        _metadata_key = "description",
        callback = function() self:_editField("description") end,
    }
    return items
end

function MetadataEditor:_bookDetailsContent(width, height, _face, enabled)
    local pad = Screen:scaleBySize(12)
    local gap = Screen:scaleBySize(18)
    local cover_max_w = math.max(1, math.floor(width * 0.3))
    local cover_max_h = math.max(1, height - 2 * pad)
    local metadata_face = Font:getFace("xx_smallinfofont")
    local color = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
    local current = self.pending_cover and { file = self.pending_cover.path }
        or self.current_cover and { image = self.current_cover } or nil
    local thumbnail, thumb_w = cover_thumbnail(current, cover_max_w, cover_max_h,
        metadata_face, color)
    local text_w = math.max(1, width - IconItem.getSettingsLeftPadding()
        - thumb_w - gap - pad)
    local row_count = self.is_epub and 7 or 6
    local row_gap = Screen:scaleBySize(4)
    local row_h = math.max(1, math.min(Screen:scaleBySize(46),
        math.floor((height - 2 * pad - row_gap * (row_count - 1)) / row_count)))
    local label_gap = Screen:scaleBySize(6)
    local label_w = math.min(Screen:scaleBySize(82), math.floor(text_w * 0.25))
    local inputs_w = math.max(1, text_w - label_w - label_gap)
    local field_border = Screen:scaleBySize(1)
    local field_padding = Screen:scaleBySize(8)
    local field_h = math.max(1, row_h - Screen:scaleBySize(2))
    local details = VerticalGroup:new{ align = "left", HorizontalSpan:new{ width = text_w } }
    self._field_focus_rows = {}
    local function make_field(value, key)
        local inner_w = math.max(1, inputs_w - 2 * field_border)
        local field = FieldTap:new{
            editor = self,
            enabled = enabled,
            _metadata_key = key,
            callback = key == "filename"
                and function() self:_editFilename() end
                or function() self:_editField(key) end,
            SolidCircle:new{
                width = inputs_w,
                height = field_h,
                radius = math.min(Screen:scaleBySize(7), math.floor(field_h / 2)),
                bordersize = field_border,
                background = Blitbuffer.COLOR_WHITE,
                LeftContainer:new{
                    dimen = Geom:new{
                        w = inner_w,
                        h = math.max(1, field_h - 2 * field_border),
                    },
                    HorizontalGroup:new{
                        HorizontalSpan:new{ width = field_padding },
                        TextWidget:new{
                            text = preview(value),
                            max_width = math.max(1, inner_w - 2 * field_padding),
                            face = metadata_face,
                            fgcolor = color,
                            padding = 0,
                        },
                    },
                },
            },
        }
        self._field_focus_rows[#self._field_focus_rows + 1] = { field }
        return field
    end
    local function add_row(label, key, value)
        local row = HorizontalGroup:new{
            align = "center",
            LeftContainer:new{
                dimen = Geom:new{ w = label_w, h = row_h },
                TextWidget:new{
                    text = label,
                    max_width = label_w,
                    face = metadata_face,
                    bold = true,
                    fgcolor = color,
                    padding = 0,
                },
            },
            HorizontalSpan:new{ width = label_gap },
            make_field(value, key),
        }
        if #details > 1 then details[#details + 1] = VerticalSpan:new{ width = row_gap } end
        details[#details + 1] = row
    end
    add_row(_("Title"), "title", self.draft.title)
    add_row(_("Authors"), "authors", join_list(self.draft.authors))
    add_row(_("Series"), "series", series_text(self.draft))
    add_row(_("Genres"), "genres", join_list(self.draft.genres))
    add_row(_("Language"), "language", self.draft.language)
    if self.is_epub then add_row(_("Publisher"), "publisher", self.draft.publisher) end
    add_row(_("Filename"), "filename", file_name(self.file))
    self._cover_focus = CoverTap:new{
        editor = self,
        _metadata_key = "cover",
        thumbnail,
    }
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        HorizontalGroup:new{
            align = "center",
            allow_mirroring = false,
            HorizontalSpan:new{ width = IconItem.getSettingsLeftPadding() },
            self._cover_focus,
            HorizontalSpan:new{ width = gap },
            details,
        },
    }
end

function MetadataEditor:_descriptionContent(width, height, face, enabled)
    local left_pad = IconItem.getSettingsLeftPadding()
    local right_pad = Screen:scaleBySize(12)
    local vertical_pad = Screen:scaleBySize(12)
    local gap = Screen:scaleBySize(6)
    local color = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
    local text_w = math.max(1, width - left_pad - right_pad)
    local label = TextWidget:new{
        text = _("Description"),
        max_width = text_w,
        face = face,
        bold = true,
        fgcolor = color,
        padding = 0,
    }
    local preview_h = math.max(1, height - 2 * vertical_pad - label:getSize().h - gap)
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = left_pad },
            VerticalGroup:new{
                align = "left",
                label,
                VerticalSpan:new{ width = gap },
                TextBoxWidget:new{
                    text = preview(self.draft.description),
                    width = text_w,
                    height = preview_h,
                    face = Font:getFace("xx_smallinfofont"),
                    fgcolor = color,
                    alignment = "left",
                    alignment_strict = true,
                    height_overflow_show_ellipsis = true,
                },
            },
        },
    }
end

function MetadataEditor:getCoverComparisonHeight()
    local gap = Screen:scaleBySize(20)
    local covers_w = math.floor(Screen:getWidth() * 0.75)
    local cover_w = math.max(1, math.floor((covers_w - gap) / 2))
    local ratio = math.max(0.1, CoverUtils.getRatio())
    return math.min(math.floor(Screen:getHeight() * 0.7),
        math.floor(cover_w / ratio) + Screen:scaleBySize(38))
end

function MetadataEditor:_coverComparisonContent(width, height)
    local gap = Screen:scaleBySize(20)
    local covers_w = math.floor(width * 0.75)
    local preview_w = math.max(1, math.floor((covers_w - gap) / 2))
    local available_h = math.max(1, height - Screen:scaleBySize(38))
    local face = Font:getFace("smallinfofont")
    local function preview_pair(label, source)
        local thumbnail = cover_thumbnail(source, preview_w, available_h,
            face, Blitbuffer.COLOR_BLACK)
        return CenterContainer:new{
            dimen = Geom:new{ w = preview_w, h = height },
            VerticalGroup:new{
                align = "center",
                TextWidget:new{ text = label, face = face, bold = true },
                VerticalSpan:new{ width = Screen:scaleBySize(6) },
                thumbnail,
            },
        }
    end
    local current = self.current_cover and { image = self.current_cover } or nil
    local pending = self.pending_cover and { file = self.pending_cover.path } or nil
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        HorizontalGroup:new{
            align = "center",
            allow_mirroring = false,
            preview_pair(_("Current"), current),
            HorizontalSpan:new{ width = gap },
            preview_pair(_("New"), pending),
        },
    }
end

function MetadataEditor:paintCoverComparison(bb, x, y, width, height)
    local content = self:_coverComparisonContent(width, height)
    content:paintTo(bb, x, y)
    content:free()
end

function MetadataEditor:showCoverFullscreen(x, width)
    local options = {
        fullscreen = true,
        with_title_bar = false,
    }
    if x < width / 2 then
        if not self.current_cover then return true end
        options.image = self.current_cover
        options.image_disposable = false
    else
        local path = self:getPendingCover()
        if not path then return true end
        options.file = path
    end
    local viewer = require("ui/widget/imageviewer"):new(options)
    viewer.onTap = function(viewer_self)
        viewer_self:onClose()
        return true
    end
    UIManager:show(viewer)
    return true
end

function MetadataEditor:_makeTitleBar()
    return ZenSettingsTitleBar:new{
        width = self.width,
        title = _("Edit metadata"),
        title_full_width = true,
        back_visible = true,
        search_visible = false,
        status_factory = function() end,
        show_parent = self,
        back_callback = function() return self:_requestClose(false) end,
        back_hold_callback = function() return self:_requestClose(false) end,
        close_callback = function() return self:_requestClose(true) end,
    }
end

function MetadataEditor:_syncTitleAction()
    local action
    if self:isDirty() and not self.save_pending then
        action = {
            text = icons.save .. "  " .. _("Save"),
            zen_button = true,
            filled = true,
            height = Screen:scaleBySize(36),
            padding_h = Screen:scaleBySize(16),
            text_font_size = 22,
            callback = function() return self:_save(false) end,
        }
    end
    self.title_bar:setAction(action)
    if self.layout then self.title_bar:installFocusLayout(self) end
end

function MetadataEditor:_hardcoverText()
    if self.edition_summary ~= "" then
        local provider = trim(self.edition_provider)
        if provider == "" then provider = _("Hardcover") end
        return T(_("%1 · %2"), provider, self.edition_summary)
    end
    return _("Find metadata")
end

function MetadataEditor:_makeMetadataHeader()
    local pad = Screen:scaleBySize(5)
    local gap = Screen:scaleBySize(6)
    local button_count = self.can_restore and 3 or 2
    local button_w = math.min(Screen:scaleBySize(210),
        math.floor((self.width - 2 * pad - gap * (button_count - 1)) / button_count))
    local button_h = Screen:scaleBySize(32)
    local radius = Screen:scaleBySize(8)
    self._open_with_button = zen_button({
        text = _("Open with…"),
        width = button_w,
        height = button_h,
        bordersize = 0,
        padding_h = Screen:scaleBySize(6),
        padding_v = 0,
        text_font_size = 16,
        avoid_text_truncation = false,
        enabled = type(self.on_open_with) == "function",
        show_parent = self,
        callback = function() return self:_openWith() end,
    }, false, radius)
    self._hardcover_button = zen_button({
        text = self:_hardcoverText(),
        width = button_w,
        height = button_h,
        bordersize = 0,
        padding_h = Screen:scaleBySize(6),
        padding_v = 0,
        text_font_size = 16,
        avoid_text_truncation = false,
        enabled = type(self.on_hardcover) == "function",
        show_parent = self,
        callback = function() return self:_openHardcover() end,
    }, true, radius)
    self._restore_button = self.can_restore and zen_button({
        text = _("Restore"),
        width = button_w,
        height = button_h,
        bordersize = 0,
        padding_h = Screen:scaleBySize(6),
        padding_v = 0,
        text_font_size = 16,
        avoid_text_truncation = false,
        enabled = type(self.on_restore) == "function",
        show_parent = self,
        callback = function() return self:_requestRestore() end,
    }, false, radius) or nil
    local action_buttons = { self._open_with_button, self._hardcover_button }
    if self._restore_button then action_buttons[#action_buttons + 1] = self._restore_button end
    self._action_buttons = {}
    if BD.mirroredUILayout() then
        for index = #action_buttons, 1, -1 do
            self._action_buttons[#self._action_buttons + 1] = action_buttons[index]
        end
    else
        self._action_buttons = action_buttons
    end
    local row = HorizontalGroup:new{ align = "center" }
    for index, button in ipairs(self._action_buttons) do
        if index > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
        table.insert(row, button)
    end
    local height = self._hardcover_button:getSize().h + 2 * pad
    return FrameContainer:new{
        width = self.width,
        height = height,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = height },
            row,
        },
    }
end

function MetadataEditor:_updateMetadataHeader()
    if self._hardcover_button then
        self._hardcover_button:setText(self:_hardcoverText(), self._hardcover_button.width)
    end
end

function MetadataEditor:_recalculateDimen(_no_recalculate_dimen)
    local requested_page = self.page or 1
    Menu._recalculateDimen(self, false)
    if not (self.available_height and self.item_dimen) then return end
    self.available_height = math.max(1,
        self.available_height - (self._metadata_header_h or 0))
    self.perpage = math.min(math.max(1, #self.item_table), 2)
    if self.perpage >= #self.item_table
            and self.page_return_arrow and self.page_info_text then
        self.available_height = self.available_height
            + math.max(self.page_return_arrow:getSize().h,
                self.page_info_text:getSize().h)
            + Size.padding.button
    end
    self.font_size = IconItem.getSettingsFontSize()
    self.page_num = self:getPageNumber(#self.item_table)
    self.page = math.max(1, math.min(requested_page, self.page_num))
    self.item_dimen.h = math.max(1,
        math.floor(self.available_height / self.perpage))
end

function MetadataEditor:mergeTitleBarIntoLayout()
    if self.title_bar and self.title_bar.installFocusLayout then
        self.title_bar:installFocusLayout(self)
    end
    local details_index
    for index, row in ipairs(self.layout) do
        local item = row[1]
        if item and item.entry and item.entry._metadata_key == "details" then
            details_index = index
            break
        end
    end
    if details_index and self._cover_focus then
        local details = self.layout[details_index][1]
        local details_focused = self.selected and self.selected.y == details_index
        if details_focused and details.onUnfocus then details:onUnfocus() end
        self.layout[details_index] = { self._cover_focus }
        for index, row in ipairs(self._field_focus_rows or {}) do
            table.insert(self.layout, details_index + index, row)
        end
        if self.selected and self.selected.y > details_index then
            self.selected.y = self.selected.y + #(self._field_focus_rows or {})
        elseif details_focused then
            local target = self._cover_focus
            local target_y = details_index
            for index, row in ipairs(self._field_focus_rows or {}) do
                if row[1]._metadata_key == self._metadata_focus_key then
                    target, target_y = row[1], details_index + index
                    break
                end
            end
            self.selected.x, self.selected.y = 1, target_y
            target:onFocus()
        end
    end
    local buttons = {}
    for _i, button in ipairs(self._action_buttons or {}) do
        if button.enabled then buttons[#buttons + 1] = button end
    end
    if #buttons > 0 then
        table.insert(self.layout, buttons)
    end
    self._metadata_focus_key = nil
end

function MetadataEditor:_isHorizontalFocusRow()
    local row = self.layout and self.selected and self.layout[self.selected.y]
    return row and #row > 1 or false
end

function MetadataEditor:_moveDetailsFocus(direction)
    local focused = self.getFocusItem and self:getFocusItem()
    local target
    if direction < 0 and focused and focused ~= self._cover_focus
            and focused._metadata_key then
        self._metadata_last_field_key = focused._metadata_key
        target = self._cover_focus
    elseif direction > 0 and focused == self._cover_focus then
        for _i, row in ipairs(self._field_focus_rows or {}) do
            if row[1]._metadata_key == self._metadata_last_field_key then
                target = row[1]
                break
            end
        end
        target = target or (self._field_focus_rows[1] and self._field_focus_rows[1][1])
    end
    if not target then return false end
    local x, y = self:getFocusableWidgetXY(target)
    return x and y and self:moveFocusTo(x, y) or false
end

function MetadataEditor:onFocusMove(args)
    local direction = args and args[1] or 0
    if direction ~= 0 and self:_moveDetailsFocus(direction) then return true end
    return Menu.onFocusMove(self, args)
end

function MetadataEditor:onZenMetadataFocusLeft()
    if self:_isHorizontalFocusRow() then
        return self:onFocusMove({ -1, 0 })
    end
    if self:_moveDetailsFocus(-1) then return true end
    return self:_requestClose(false)
end

function MetadataEditor:onZenMetadataFocusRight()
    if self:_isHorizontalFocusRow() then
        return self:onFocusMove({ 1, 0 })
    end
    if self:_moveDetailsFocus(1) then return true end
    return Menu.onRight(self)
end

function MetadataEditor:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.is_borderless = true
    self.is_popout = false
    self.covers_fullscreen = true
    self.title_bar_fm_style = true
    self.name = "zen_metadata_editor"
    self.is_enable_shortcut = false
    self.linesize = Size.line.thin
    self.line_color = Blitbuffer.COLOR_LIGHT_GRAY
    self.original = self.original or normalize_draft(self.metadata)
    self.draft = self.draft or normalize_draft(self.metadata)
    self.manual_fields = self.manual_fields or {}
    self.field_sources = self.field_sources or {}
    for _i, key in ipairs(FIELD_ORDER) do
        if self.field_sources[key] == nil then self.field_sources[key] = "original" end
    end
    self.edition_summary = trim(self.edition_summary)
    self.edition_provider = trim(self.edition_provider)
    self.item_table = self:_buildItems()
    self.custom_title_bar = self:_makeTitleBar()
    self._metadata_header = self:_makeMetadataHeader()
    self._metadata_header_h = self._metadata_header:getSize().h
    Menu.init(self)
    if Device.hasFewKeys and Device:hasFewKeys() then
        self.key_events = self.key_events or {}
        self.key_events.Close = { { "Back" } }
        self.key_events.Right = nil
        self.key_events.ZenMetadataFocusLeft = { { "Left" } }
        self.key_events.ZenMetadataFocusRight = { { "Right" } }
    end
    table.insert(self.content_group, self._metadata_header)
    self.content_group:resetLayout()
    self:_syncTitleAction()
end

function MetadataEditor:_fieldDialogButtons(close, save)
    return {{
        {
            text = _("Find metadata"),
            enabled = type(self.on_hardcover) == "function",
            callback = function()
                close()
                UIManager:nextTick(function() self:_openHardcover() end)
            end,
        },
        { text = _("Save"), callback = save },
    }}
end

function MetadataEditor:_editFilename()
    if self.save_pending or type(self.on_rename) ~= "function" then return true end
    local seed = file_name(self.file)
    local dialog
    local function rename()
        local basename = dialog:getInputText()
        if basename == seed then
            UIManager:close(dialog)
            return
        end
        if trim(basename) == "" or basename:find("/", 1, true)
                or basename:find("\\", 1, true) then
            self:showError(_("Enter a valid filename."))
            return
        end
        if file_extension(basename):lower() ~= file_extension(seed):lower() then
            self:showError(_("Keep the current file extension."))
            return
        end
        local next_file, err = self.on_rename(basename, self)
        if not next_file then
            self:showError(err or _("Renaming the file failed."))
            return
        end
        self:setFile(next_file)
        UIManager:close(dialog)
    end
    local function changed() return dialog:getInputText() ~= seed end
    local function close() return self:_confirmDialogClose(dialog, changed, rename) end
    dialog = InputDialog:new{
        title = _("Filename"),
        input = seed,
        buttons = self:_fieldDialogButtons(
            function() UIManager:close(dialog) end, rename),
    }
    ZenModalClose.installDialog(dialog, close)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return true
end

function MetadataEditor:_editCover()
    if self.save_pending or type(self.on_cover) ~= "function" then return true end
    self.on_cover(self)
    return true
end

function MetadataEditor:_openWith()
    if self.save_pending or type(self.on_open_with) ~= "function" then return true end
    self.on_open_with(self)
    return true
end

function MetadataEditor:onScreenResize()
    local requested_page = self.page or 1
    local requested_item = self.itemnumber
    self:init()
    if requested_item and self.item_table[requested_item] then
        self.itemnumber = requested_item
        self.page = self:getPageNumber(requested_item)
    else
        self.page = math.max(1, math.min(requested_page, self.page_num or 1))
    end
    self:updateItems(1, true)
    return false
end

function MetadataEditor:_refresh(key)
    self._metadata_focus_key = key
    self.item_table = self:_buildItems()
    self:_syncTitleAction()
    self:_updateMetadataHeader()
    local selected
    if key == "cover" or key == "filename"
            or (FIELD_SPECS[key] and key ~= "description") then
        key = "details"
    end
    for index, item in ipairs(self.item_table) do
        if item._metadata_key == key then selected = index break end
    end
    if selected then
        self.page = self:getPageNumber(selected)
        self.itemnumber = selected
    end
    self:updateItems(nil, false)
end

function MetadataEditor:_applyField(key, value)
    self.field_sources = self.field_sources or {}
    if key == "series" then
        self.draft.series_name = trim(value[1])
        local index = trim(value[2])
        self.draft.series_index = self.draft.series_name ~= "" and index or ""
    elseif FIELD_SPECS[key].list then
        self.draft[key] = normalize_list(value)
    else
        self.draft[key] = trim(value)
    end
    self.manual_fields[key] = true
    self.field_sources[key] = "manual"
    logger.dbg("draft field updated key=", key)
    self:_refresh(key)
end

function MetadataEditor:_confirmDialogClose(dialog, changed, apply)
    if not changed() then
        UIManager:close(dialog)
        return true
    end
    UIManager:show(MultiConfirmBox:new{
        text = _("You have unsaved changes."),
        cancel_text = _("Keep editing"),
        choice1_text = _("Discard"),
        choice1_callback = function() UIManager:close(dialog) end,
        choice2_text = _("Save"),
        choice2_callback = apply,
    })
    return true
end

function MetadataEditor:_editSeries()
    local seed = { self.draft.series_name, self.draft.series_index }
    local dialog
    local function apply()
        local values = dialog:getFields()
        local index = trim(values[2])
        if index ~= "" and not valid_number(index) then
            self:showError(_("Series position must be a number."))
            return
        end
        self:_applyField("series", values)
        UIManager:close(dialog)
    end
    local function changed()
        local values = dialog:getFields()
        return values[1] ~= seed[1] or values[2] ~= seed[2]
    end
    local function close() return self:_confirmDialogClose(dialog, changed, apply) end
    dialog = MultiInputDialog:new{
        title = _("Series"),
        fields = {
            { description = _("Name"), text = seed[1] },
            { description = _("Position"), text = seed[2] },
        },
        buttons = self:_fieldDialogButtons(
            function() UIManager:close(dialog) end, apply),
    }
    ZenModalClose.installDialog(dialog, close)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MetadataEditor:_editField(key)
    if key == "series" then return self:_editSeries() end
    local spec = FIELD_SPECS[key]
    local seed = spec.list and join_list(self.draft[key], "\n") or self.draft[key]
    local dialog
    local function apply()
        local value = dialog:getInputText()
        if self.is_epub and (key == "title" or key == "language")
                and trim(value) == "" then
            self:showError(key == "title"
                and _("An EPUB title is required.")
                or _("An EPUB language is required."))
            return
        end
        self:_applyField(key, value)
        UIManager:close(dialog)
    end
    local function changed() return dialog:getInputText() ~= seed end
    local function close() return self:_confirmDialogClose(dialog, changed, apply) end
    dialog = InputDialog:new{
        title = spec.label,
        input = seed,
        input_hint = spec.list and _("One per line") or spec.label,
        description = spec.list and _("Enter one value per line.") or nil,
        allow_newline = spec.list or spec.long,
        fullscreen = spec.long,
        condensed = spec.long,
        add_nav_bar = key ~= "description" and spec.long,
        use_available_height = spec.long,
        scroll_by_pan = spec.long,
        text_height = spec.list and Screen:scaleBySize(110) or nil,
        buttons = self:_fieldDialogButtons(
            function() UIManager:close(dialog) end, apply),
    }
    ZenModalClose.installDialog(dialog, close)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MetadataEditor:applyHardcover(metadata, summary, source, source_label)
    local incoming = normalize_draft(metadata)
    source = trim(source)
    if source == "" then source = "hardcover" end
    self.field_sources = self.field_sources or {}
    local applied, skipped = 0, 0
    for _i, key in ipairs(FIELD_ORDER) do
        if (key ~= "publisher" or self.is_epub) and has_value(key, incoming) then
            if self.manual_fields[key] or self.field_sources[key] == "manual" then
                skipped = skipped + 1
            elseif key == "series" then
                self.draft.series_name = incoming.series_name
                if incoming.series_index ~= "" then
                    self.draft.series_index = incoming.series_index
                end
                self.field_sources[key] = source
                applied = applied + 1
            else
                self.draft[key] = copy_value(incoming[key])
                self.field_sources[key] = source
                applied = applied + 1
            end
        end
    end
    self.edition_summary = trim(summary)
    self.edition_provider = trim(source_label)
    if self.edition_provider == "" and source == "hardcover" then
        self.edition_provider = _("Hardcover")
    end
    logger.dbg("Provider draft merged source=", source,
        " applied=", applied, " retained=", skipped)
    self:_refresh()
    return skipped
end

function MetadataEditor:_openHardcover()
    if self.save_pending or type(self.on_hardcover) ~= "function" then return true end
    local metadata, summary = self.on_hardcover(self:getDraft(), self)
    if type(metadata) == "table" then
        self:applyHardcover(metadata, summary)
    elseif summary ~= nil then
        self:setEditionSummary(summary)
    end
    return true
end

function MetadataEditor:_save(close_all)
    if self.save_pending or not self:isDirty() then return true end
    if type(self.on_save) ~= "function" then return true end
    if self.is_epub and self.draft.title == "" then
        self:showError(_("An EPUB title is required."))
        return true
    elseif self.is_epub and self.draft.language == "" then
        self:showError(_("An EPUB language is required."))
        return true
    elseif self.draft.series_index ~= "" and not valid_number(self.draft.series_index) then
        self:showError(_("Series position must be a number."))
        return true
    end
    if self.draft.series_name == "" then self.draft.series_index = "" end
    self._save_close_all = close_all == true
    self:setSavePending(true)
    local ok, err = self.on_save(self:getDraft(), self)
    if ok == nil and err == nil then return true end
    return self:completeSave(ok, err)
end

function MetadataEditor:completeSave(ok, err)
    if not self.save_pending then return true end
    local close_all = self._save_close_all
    self._save_close_all = nil
    self:setSavePending(false)
    if not ok then
        self:showError(err or _("Saving metadata failed."))
        return true
    end
    self.original = copy_value(self.draft)
    self:_close(close_all)
    return true
end

function MetadataEditor:cancelSave()
    self._save_close_all = nil
    self:setSavePending(false)
    return true
end

function MetadataEditor:_requestRestore()
    if self.save_pending or type(self.on_restore) ~= "function" then return true end
    local function restore()
        local ok, err = self.on_restore(self)
        if ok == nil and err == nil then return end
        if not ok then
            self:showError(err or _("Restoring metadata failed."))
        else
            self:_close(false)
        end
    end
    UIManager:show(ConfirmBox:new{
        text = self:isDirty()
            and _("Restore the previous metadata and discard your unsaved changes?")
            or _("Restore the previous metadata for this book?"),
        cancel_text = _("Cancel"),
        ok_text = _("Restore"),
        ok_callback = restore,
    })
    return true
end

function MetadataEditor:_requestClose(close_all)
    if self.save_pending then return true end
    if not self:isDirty() then return self:_close(close_all) end
    UIManager:show(MultiConfirmBox:new{
        text = _("You have unsaved metadata changes."),
        cancel_text = _("Keep editing"),
        choice1_text = _("Discard"),
        choice1_callback = function() self:_close(close_all) end,
        choice2_text = _("Save"),
        choice2_callback = function() self:_save(close_all) end,
    })
    return true
end

function MetadataEditor:_close(close_all)
    if self._closed then return true end
    self._closed = true
    UIManager:close(self)
    if self.pending_cover and self.pending_cover.temporary then
        os.remove(self.pending_cover.path)
    end
    if self.current_cover and type(self.current_cover.free) == "function" then
        pcall(self.current_cover.free, self.current_cover)
    end
    self.pending_cover = nil
    self.current_cover = nil
    if close_all and self.on_close_all then
        self.on_close_all()
    elseif not close_all and self.on_back then
        self.on_back()
    end
    return true
end

function MetadataEditor:onMenuSelect(item)
    if item and type(item.callback) == "function" then item.callback() end
    return true
end

function MetadataEditor:onClose()
    return self:_requestClose(false)
end

function MetadataEditor:onCloseAllMenus()
    return self:_requestClose(true)
end

function MetadataEditor:setDraft(metadata)
    self.draft = normalize_draft(metadata)
    self:_refresh()
end

function MetadataEditor:setEditionSummary(summary, provider)
    self.edition_summary = trim(summary)
    if provider ~= nil then self.edition_provider = trim(provider) end
    self:_updateMetadataHeader()
    UIManager:setDirty(self, "ui")
end

function MetadataEditor:setFile(file)
    self.file = file
    self:_refresh("filename")
end

function MetadataEditor:setCustomCover(custom)
    self.has_custom_cover = custom == true
    self:_refresh("cover")
end

function MetadataEditor:setSavePending(pending)
    self.save_pending = pending == true
    self:_syncTitleAction()
    if self.layout then self:updateItems(nil, true) end
end

function MetadataEditor:setRestoreAvailable(available)
    available = available == true
    if self.can_restore == available then return end
    self.can_restore = available
    self:_refresh()
end

function MetadataEditor:showError(text)
    UIManager:show(InfoMessage:new{ text = tostring(text or _("Unknown error")) })
end

local M = {}

function M.show(options)
    options = options or {}
    local editor = MetadataEditor:new(options)
    UIManager:show(editor, "full")
    return editor
end

M.Widget = MetadataEditor
M.normalizeDraft = normalize_draft

IconItem.installMenuPatch()

return M
