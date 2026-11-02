local _ = require("gettext")
local T = require("ffi/util").template
local utils = require("common/utils")
local icons_dir = require("common/plugin_root") .. "/icons/"

local M = {}
local plugin

function M.configure(value)
    plugin = value
end

function M.enabled(ui)
    return plugin and plugin.config and plugin.config.features
        and plugin.config.features.reader_references == true
        and ui and ui.document and ui.link and ui.gotopage
end

function M.applyDefaults(ui)
    if not M.enabled(ui) then return end
    for key, value in pairs({ footnote_link_in_popup = true,
        footnote_popup_use_book_font = true, footnote_popup_relative_font_size = 0 }) do
        if G_reader_settings:readSetting(key) == nil then G_reader_settings:saveSetting(key, value) end
    end
end

function M.pageLabel(ui, page)
    if ui.pagemap and ui.pagemap:wantsPageLabels() then
        local xp = ui.document.getPageXPointer and ui.document:getPageXPointer(page)
        local label = xp and ui.pagemap:getXPointerPageLabel(xp, true)
        if label and label ~= "" then return label end
    end
    return tostring(page)
end

function M.locationPage(ui, location)
    if ui.rolling and location.xpointer then
        return ui.document:getPageFromXPointer(location.xpointer)
    end
    return location[1] and location[1].page
end

function M.backLocation(ui)
    for i = #(ui.link.location_stack or {}), 1, -1 do
        local location = ui.link.location_stack[i]
        if not ui.link:compareLocationToCurrent(location) then return location end
    end
end

function M.goBack(ui)
    local origin = ui.link:getCurrentLocation()
    repeat
        local count = #(ui.link.location_stack or {})
        ui.link:onGoBackLink()
        if #(ui.link.location_stack or {}) >= count then break end
    until not ui.link:compareLocationToCurrent(origin) or #ui.link.location_stack == 0
end

function M.pinLocations(ui)
    local locations = ui.doc_settings:readSetting("zen_pinned_pages")
    if not locations then
        local legacy = ui.doc_settings:readSetting("pinned_page")
        locations = legacy and { legacy } or {}
        ui.doc_settings:saveSetting("zen_pinned_pages", locations)
    end
    return locations
end

-- Read-only pin list from sidecar data; stock KOReader keeps a single pin.
function M.storedLocations(data)
    local owner = plugin or rawget(_G, "__ZEN_UI_PLUGIN")
    local features = owner and owner.config and owner.config.features
    local locations = features and features.reader_references == true and data.zen_pinned_pages
    return locations or data.pinned_page and { data.pinned_page } or {}
end

function M.pins(ui, locations)
    local pins = {}
    local images = ui.doc_settings:readSetting("zen_pinned_images") or {}
    for index, location in ipairs(locations or M.pinLocations(ui)) do
        local page, image
        if ui.rolling and type(location) == "string" then
            image = images[location]
            page = ui.document:getPageFromXPointer(image or location)
        elseif ui.paging then
            page = type(location) == "number" and location
                or type(location) == "table" and location[1] and location[1].page
        end
        if page and page >= 1 and page <= ui.document:getPageCount() then
            pins[#pins + 1] = { page = page, location = location, index = index, image = image }
        end
    end
    return pins
end

function M.pinnedPage(ui)
    local pin = M.pins(ui)[1]
    return pin and pin.page
end

function M.isPinned(ui, page)
    local pins = M.pins(ui)
    if #pins == 0 then return false end -- common case on every header paint
    local location = page and ui.rolling and ui.document:getPageXPointer(page)
    for _i, pin in ipairs(pins) do
        if pin.page == page or location and pin.location == location then return true end
    end
    return false
end

function M.setPin(ui, page, remove, image)
    page = page or ui:getCurrentPage()
    if not page or page < 1 or page > ui.document:getPageCount() then return end
    local footer = ui.view and ui.view.footer
    local footer_height = footer and footer:getHeight()
    local locations = M.pinLocations(ui)
    local location = image or ui.rolling and ui.document:getPageXPointer(page) or page
    local found
    for _i, pin in ipairs(M.pins(ui)) do
        if pin.page == page or pin.location == location then
            found, location = pin.index, pin.location
            break
        end
    end
    if remove then
        if not found then return end
        table.remove(locations, found)
        local images = ui.doc_settings:readSetting("zen_pinned_image_settings")
        if images then
            images[ui.rolling and location or page] = nil
            ui.doc_settings:saveSetting("zen_pinned_image_settings", images)
        end
    elseif not found then
        locations[#locations + 1] = location
    else return end
    ui.doc_settings:saveSetting("zen_pinned_pages", locations)
    local images = ui.doc_settings:readSetting("zen_pinned_images")
    if image or images then
        images = images or {}
        images[location] = not remove and image or nil
        ui.doc_settings:saveSetting("zen_pinned_images", images)
    end
    -- Keep one native pin available when the reference drawer is disabled.
    ui.doc_settings:saveSetting("pinned_page", locations[1])
    if footer and ui.view.footer_visible then
        if footer:getHeight() ~= footer_height then footer:refreshFooter(true, true)
        else footer:onUpdateFooter(true, true) end
    end
    if ui.view then require("ui/uimanager"):setDirty(ui, "ui") end
    return true
end

function M.selectionPage(highlight, index)
    if not highlight or not highlight.ui then return end
    local ui = highlight.ui
    if not M.enabled(ui) then return end
    local selection = highlight.selected_text
    local annotation = index and ui.annotation and ui.annotation.annotations[index]
    local pos = selection and selection.pos0 or annotation and (annotation.pos0 or annotation.page)
    if ui.rolling and type(pos) == "string" then return ui.document:getPageFromXPointer(pos) end
    if type(pos) == "table" and pos.page then return pos.page end
    if annotation and type(annotation.page) == "number" then return annotation.page end
    return ui:getCurrentPage()
end

function M.pinButtons(ui, page, close)
    if not M.enabled(ui) then return {} end
    local pinned = M.isPinned(ui, page)
    local buttons = {{
        text = _("Pin this page"),
        enabled = page ~= nil and not pinned,
        callback = function()
            M.setPin(ui, page)
            if close then close() end
        end,
    }}
    if pinned then
        buttons[#buttons + 1] = {
            text = _("Remove pin"),
            callback = function()
                M.setPin(ui, page, true)
                if close then close() end
            end,
        }
    end
    return buttons
end

function M.addPinButton(buttons, ui, page, close, settings_key)
    if not M.enabled(ui) or not page then return end
    for _i, row in ipairs(buttons) do
        for _j, button in ipairs(row) do
            if button.id == "zen_pin" then return end
        end
    end
    local pinned = M.isPinned(ui, page)
    local button = M.pinButtons(ui, page, close)[pinned and 2 or 1]
    button.id = "zen_pin"
    button.icon = utils.resolveLocalIcon(icons_dir, pinned and "pin_remove" or "pin")
    local settings = plugin.config[settings_key or "highlight_lookup"] or {}
    button.text = settings.show_labels and (pinned and _("Remove pin") or _("Pin")) or nil
    buttons[1] = buttons[1] or {}
    buttons[1][#buttons[1] + 1] = button
end

function M.paintPin(ui, page, bb, x, y, width, height)
    if not M.enabled(ui) or not M.isPinned(ui, page) then return end
    local Screen = require("device").screen
    -- Thumbnail sources fit one screen dimension before their final downscale.
    local scale = math.max(width / Screen:getWidth(), height / Screen:getHeight())
    local size = math.max(1, math.floor(ui.view.dogear.icon:getSize().w * scale + 0.5))
    local icon = require("ui/widget/iconwidget"):new{
        file = utils.resolveLocalIcon(icons_dir, "pin"), width = size, height = size, alpha = true,
    }
    x = x + width - size * 2 - Screen:scaleBySize(2)
    icon:paintTo(bb, x, y)
    icon:free()
end

local function imageXPointer(document, pos)
    local range = document._document:getTextFromPositions(pos.x, pos.y, pos.x, pos.y, false, false, true)
    local parent = range and range.pos0:match("^(.*)/")
    while parent and parent ~= "" do
        -- CRe's node metadata preserves hierarchy without parsing book HTML.
        local nodes = select(3, document:getHTMLFromXPointer(parent, 0x8000, false))
        local paths, counts = {}, {}
        for row in (nodes or ""):gmatch("[^\n]+") do
            local level, tag = row:match("^%d+\t(%d+)\t%d+\t([^\t]+)")
            if level then
                level = tonumber(level)
                if not next(paths) then
                    paths[level] = parent
                else
                    counts[level] = counts[level] or {}
                    counts[level][tag] = (counts[level][tag] or 0) + 1
                    paths[level] = paths[level - 1] .. "/" .. tag .. "[" .. counts[level][tag] .. "]"
                end
                counts[level + 1] = nil
                if tag == "img" or tag == "svg" then
                    local xp = paths[level] .. ".0"
                    local boxes = document._document:getWordBoxesFromPositions(xp, xp, true, true)
                    for _i, box in ipairs(boxes or {}) do
                        if pos.x >= box.x0 and pos.x < box.x1 and pos.y >= box.y0 and pos.y < box.y1 then
                            return xp
                        end
                    end
                end
            end
        end
        parent = parent:match("^(.*)/")
    end
end

function M.imageMenu(highlight, page, position, spec, open)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Labels = require("common/ui/button_labels")
    local labels = plugin.config.highlight_lookup and plugin.config.highlight_lookup.show_labels == true
    local image = spec.image
    local buttons = {{ { text = labels and _("View image") or nil,
        icon = utils.resolveLocalIcon(icons_dir, "fullscreen"), callback = function()
        local viewer = open()
        image = nil -- The viewer takes ownership of the image.
        highlight:onClose()
        UIManager:show(viewer)
    end } }}
    M.addPinButton(buttons, highlight.ui, page, function() highlight:onClose() end)
    if highlight.ui.rolling and not M.isPinned(highlight.ui, page) then
        buttons[1][2].callback = function()
            local pos = highlight.view:screenToPageTransform(position)
            M.setPin(highlight.ui, page, nil, imageXPointer(highlight.ui.document, pos))
            highlight:onClose()
        end
    end
    if labels then buttons = Labels.prepare(buttons) end
    require("modules/reader/highlight_menu_items").compact(buttons)
    local dialog = ButtonDialog:new{
        name = "highlight_image_dialog", buttons = buttons,
        shrink_unneeded_width = not labels,
        anchor = function() return position end,
    }
    if labels then Labels.apply(dialog.buttontable, buttons) end
    dialog.onCloseWidget = function(self)
        if image then
            if type(image) == "function" then image(false)
            elseif spec.image_disposable ~= false and image.free then image:free() end
            image = nil
        end
        if highlight.highlight_dialog == self then highlight.highlight_dialog = nil end
        ButtonDialog.onCloseWidget(self)
    end
    highlight.highlight_dialog = dialog
    return dialog
end

function M.openPinned(ui, index)
    if not M.enabled(ui) then return end
    local pins = M.pins(ui)
    if not index then
        local last = ui.doc_settings:readSetting("zen_last_pinned_page")
        for i, pin in ipairs(pins) do
            if (ui.rolling and pin.location or pin.page) == last then index = i; break end
        end
    end
    index = math.max(1, math.min(index or 1, #pins))
    local pin = pins[index]
    if not pin then return end
    local Drawer = require("modules/reader/reference_drawer")
    local ok, result = pcall(Drawer.new, Drawer, {
        ui = ui, page = pin.page, pin_index = index, pins = pins, plugin = plugin,
    })
    if not ok then
        require("logger").warn("ZenOS: reference preview failed", result)
        require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
            text = _("Unable to open reference preview."),
        })
        return false
    end
    require("ui/uimanager"):show(result)
    ui.doc_settings:saveSetting("zen_last_pinned_page", ui.rolling and pin.location or pin.page)
    return true
end

function M.openFootnote(ui)
    local state = ui._zen_references
    if M.enabled(ui) and state and state.footnote then
        ui.link:showAsFootnotePopup(state.footnote)
    end
end

function M.actions(ui, close)
    local actions = {}
    if not M.enabled(ui) then return actions end
    local previous = M.backLocation(ui)
    local page = previous and M.locationPage(ui, previous)
    if page then
        actions[#actions + 1] = { id = "back", text = T(_("Return to page %1"), M.pageLabel(ui, page)),
            icon = utils.resolveLocalIcon(icons_dir, "return"),
            callback = function() close(); M.goBack(ui) end }
    end
    return actions
end

function M.clear(ui)
    if ui and ui._zen_return_button then ui._zen_return_button:hide() end
    local state = ui and ui._zen_references
    if state and state.drawer then state.drawer:onClose() end
    if ui then ui._zen_references = nil end
end

return M
