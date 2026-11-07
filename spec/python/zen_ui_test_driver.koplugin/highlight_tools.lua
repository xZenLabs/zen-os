local Event = require("ui/event")
local Geom = require("ui/geometry")
local M = {}

local function note_editor()
    local UIManager = require("ui/uimanager")
    local InputDialog = require("ui/widget/inputdialog")
    for i = #UIManager._window_stack, 1, -1 do
        local widget = UIManager._window_stack[i].widget
        if getmetatable(widget) == InputDialog then return widget end
    end
end

local function words(ui)
    local list, seen = {}, {}
    for y = 100, ui.dimen.h - 120, 20 do
        for x = 60, ui.dimen.w - 60, 30 do
            local pos = ui.view:screenToPageTransform(Geom:new{ x = x, y = y })
            local ok, word = pcall(ui.document.getWordFromPosition, ui.document, pos, true)
            if ok and word and word.word and word.word ~= "" and word.sbox then
                local box = ui.paging and ui.view:pageToScreenTransform(pos.page, word.sbox) or word.sbox
                local key = box and box.x .. ":" .. box.y
                if key and not seen[key] then
                    seen[key] = true
                    list[#list + 1] = { x = box.x + box.w / 2, y = box.y + box.h / 2, text = word.word }
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.y == b.y and a.x < b.x or a.y < b.y end)
    return list
end

function M.command(params)
    local ui = require("apps/reader/readerui").instance
    if not ui then return { ok = false, error = "reader unavailable" } end
    local h = ui.highlight
    if params.action == "seed" then
        h:onClose()
        if params.ai then
            h._highlight_buttons["99_ai_assistant"] = function()
                return { callback = function() end }
            end
        end
        if ui.document.is_pdf then h.highlight_write_into_pdf = true end
        local positions = words(ui)
        if #positions < 10 then return { ok = false, error = "not enough selectable words", words = positions } end
        local pos0 = ui.view:screenToPageTransform(Geom:new(positions[3]))
        local pos1 = ui.view:screenToPageTransform(Geom:new(positions[6]))
        h.hold_pos = pos0
        h.selected_text = ui.document:getTextFromPositions(pos0, pos1)
        if ui.paging then h.view.highlight.temp[pos0.page] = h.selected_text.sboxes end
        if params.saved then
            h.selected_text.note = params.note_text or "Preserved note"
            h.selected_text.datetime = params.datetime
            local index = h:saveHighlight()
            h:clear()
            h:showHighlightDialog(index)
        else
            h:onShowHighlightMenu()
        end
    elseif params.action == "drag" then
        local controller = h._zen_highlight_handles
        if not controller then return { ok = false, error = "handles unavailable" } end
        local start, offset_y
        if controller.dragging then
            start = Geom:new(controller.touch_pos)
            offset_y = controller.offset_y
        else
            local knob = controller:geometry()[params.side or 1]
            if not knob then return { ok = false, error = "endpoint offscreen" } end
            start = Geom:new{ x = knob.x, y = knob.y }
            offset_y = knob.y - (knob.top + knob.height / 2)
        end
        local target = params.target or words(ui)[params.word or 10]
        local finish = Geom:new{ x = target.x, y = target.y + (params.raw and 0 or offset_y) }
        local dialog = controller.dialog
        local function gesture(kind, point)
            return dialog:handleEvent(Event:new("Gesture", { ges = kind, pos = point, start_pos = start }))
        end
        if not controller.dragging then gesture("touch", start) end
        gesture("pan", finish)
        if params.release ~= false then gesture("pan_release", finish) end
    elseif params.action == "release" then
        local controller = h._zen_highlight_handles
        if not controller or not controller.dragging then return { ok = false, error = "no active drag" } end
        controller.dialog:handleEvent(Event:new("Gesture", { ges = "pan_release", pos = Geom:new(controller.last_pos) }))
    elseif params.action == "close" then
        h:onClose()
    elseif params.action == "save" then
        h.highlight_dialog.buttons[1][1].callback()
    elseif params.action == "more" then
        h.highlight_dialog:getButtonById("zen_highlight_more").callback()
    elseif params.action == "settings" then
        h.highlight_dialog:getButtonById("zen_highlight_settings").callback()
    elseif params.action == "note" then
        if not h.highlight_dialog then h:showHighlightDialog(1) end
        h.highlight_dialog:getButtonById("zen_highlight_note").callback()
    elseif params.action == "note_close" then
        note_editor().title_bar.right_button.callback()
    elseif params.action == "note_keyboard" then
        local editor = note_editor()
        if editor:isKeyboardVisible() then editor:onCloseKeyboard()
        else editor:onShowKeyboard() end
        editor:reinit()
    end
    for _i = 1, params.reader_taps or 0 do
        require("ui/uimanager"):sendEvent(Event:new("Gesture", {
            ges = "tap", pos = Geom:new{ x = ui.dimen.w * 0.8, y = ui.dimen.h * 0.6 },
        }))
    end
    local controller = h._zen_highlight_handles
    local item = controller and (controller.draft or controller.item)
    local stored = ui.annotation.annotations[1]
    local ids, menu_icons = {}, {}
    for _i, row in ipairs(h.highlight_dialog and h.highlight_dialog.buttons or {}) do
        for _j, button in ipairs(row) do
            ids[#ids + 1] = button.id or button.icon or button.text
            menu_icons[#menu_icons + 1] = button.icon or ""
        end
    end
    local embedded_count = 0
    local menu_icon_files = {}
    for _i, row in ipairs(h.highlight_dialog and h.highlight_dialog.buttontable.buttons_layout or {}) do
        for _j, button in ipairs(row) do
            menu_icon_files[#menu_icon_files + 1] = (button.label_icon or button.label_widget).file or ""
        end
    end
    if ui.document.is_pdf then
        for _page, annotations in pairs(ui.document:getEmbeddedAnnotations() or {}) do
            embedded_count = embedded_count + #annotations
        end
    end
    local editor, editor_state = note_editor()
    if editor then
        local buttons = {}
        for _i, row in ipairs(editor.buttons) do
            local labels = {}
            for _j, button in ipairs(row) do labels[#labels + 1] = button.text end
            buttons[#buttons + 1] = labels
        end
        editor_state = { description = editor.description, buttons = buttons,
            bounds = editor.dialog_frame.dimen, available_height = editor[1].dimen.h,
            scroll_buttons = editor.add_scroll_buttons,
            close_icon = editor.title_bar.right_button and editor.title_bar.right_button.file }
    end
    return { ok = true, handles = controller and controller:geometry(), dragging = controller and controller.dragging == true,
        draft_text = item and item.text, stored_text = stored and stored.text, note = stored and stored.note,
        count = #ui.annotation.annotations, menu_ids = ids, menu_icons = menu_icons, menu_icon_files = menu_icon_files,
        menu_buttons = require("reader_tools").button_state(h.highlight_dialog and h.highlight_dialog.buttontable),
        words = words(ui),
        page = ui.rolling and ui.document:getCurrentPage() or ui.paging.current_page,
        position = ui.rolling and ui.document:getCurrentPos() or ui.paging.current_page,
        view_mode = ui.view.view_mode, restore_page_mode = h.restore_page_mode_func ~= nil,
        margins = ui.rolling and ui.document:getPageMargins(),
        footer_height = ui.view.footer:getHeight(),
        screen_w = ui.dimen.w, screen_h = ui.dimen.h,
        embedded_count = embedded_count, note_editor = editor_state }
end

return M
