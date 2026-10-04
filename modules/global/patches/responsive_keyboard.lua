local function find_upvalue(fn, target)
    local index = 1
    while true do
        local name, value = debug.getupvalue(fn, index)
        if not name then return nil end
        if name == target then return value end
        index = index + 1
    end
end

local function apply_responsive_keyboard()
    local Blitbuffer = require("ffi/blitbuffer")
    local Device = require("device")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local UIManager = require("ui/uimanager")
    local GestureDetector = require("device/gesturedetector")
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    local logger = require("logger")
    local time = require("ui/time")
    local double_space_min_interval = time.ms(80)
    local double_space_max_interval = time.ms(300)
    local Contact = find_upvalue(GestureDetector.newContact, "Contact")
    local VirtualKey = find_upvalue(VirtualKeyboard.addKeys, "VirtualKey")
    assert(type(Contact) == "table", "GestureDetector Contact class not found")
    assert(type(VirtualKey) == "table", "VirtualKeyboard VirtualKey class not found")

    local function modifier_active(key)
        local keyboard = key.keyboard
        return keyboard and ((keyboard.shiftmode
                and (keyboard.shiftmode_keys[key.label] ~= nil
                    or keyboard.shiftmode_keys[key.key] ~= nil))
            or (keyboard.symbolmode and keyboard.symbolmode_keys[key.label] ~= nil))
    end

    if not VirtualKey._zen_active_modifier then
        VirtualKey._zen_active_modifier = true
        local original_init = VirtualKey.init
        function VirtualKey:init(...)
            original_init(self, ...)
            if modifier_active(self) then
                self[1].background = Blitbuffer.COLOR_WHITE
                self[1].invert = true
            end
        end
    end

    VirtualKeyboard.allow_concurrent_taps = true

    if not VirtualKeyboard._zen_touch_qwerty then
        VirtualKeyboard._zen_touch_qwerty = true
        local original_add_keys = VirtualKeyboard.addKeys
        function VirtualKeyboard:addKeys(...)
            local keys = self.KEYS
            local layouts = self.lang_to_keyboard_layout
            local english_layout = (layouts[self:getKeyboardLayout()] or layouts.en) == "en_keyboard"
            local standard_layout = keys and #keys == 5 and #keys[1] == 10
                and #keys[2] == 10 and #keys[3] == 10 and #keys[4] == 9 and #keys[5] == 7
            if english_layout and self.keyboard_layer > 2 and Device:isTouchDevice()
                    and standard_layout then
                local layer = self.keyboard_layer
                local symbols
                if layer == 4 then
                    -- Common punctuation page.
                    symbols = {
                        { keys[4][4][4], keys[4][5][4], keys[4][2][4], keys[4][3][4],
                            keys[3][5][4], "%", "^", keys[3][6][4], keys[2][10][4], keys[1][6][4] },
                        { keys[1][4][4], keys[2][4][4], keys[2][5][4], keys[2][3][4],
                            keys[3][1][4], keys[3][2][4], "€", "£", "¥", "•" },
                        { keys[5][3][3], keys[3][10][3], keys[3][3][4], keys[3][4][4],
                            "$", "&", "@", keys[1][5][4] },
                        { keys[1][3][4], keys[2][6][4], keys[5][3][4], keys[3][10][4],
                            keys[2][1][4], keys[1][1][4], keys[1][1][3] },
                    }
                else
                    -- Secondary symbols and the existing advanced keys.
                    symbols = {
                        { keys[4][4][4], keys[4][5][4], keys[4][2][4], keys[4][3][4],
                            keys[3][5][4], "%", "^", keys[3][6][4], keys[2][10][4], keys[1][6][4] },
                        { keys[3][1][3], keys[3][2][3], keys[1][6][3], keys[1][10][3],
                            keys[2][10][3], keys[2][6][3], keys[3][6][3], keys[2][1][3],
                            keys[2][2][3], "Σ" },
                        { keys[2][3][3], keys[2][5][3], keys[3][3][3], keys[3][4][3],
                            keys[3][5][3], keys[4][2][3], keys[4][3][3], keys[4][4][3],
                            keys[4][5][3] },
                        { keys[1][1][3], keys[1][2][3], keys[1][3][3], keys[1][4][3],
                            keys[1][5][3], keys[2][4][3], keys[3][10][3] },
                    }
                end
                local function symbol_row(values)
                    local row = {}
                    for index = 1, #values do
                        row[index] = { [layer] = values[index] }
                    end
                    return row
                end
                local fourth_row = symbol_row(symbols[4])
                table.insert(fourth_row, 1, keys[4][1])
                fourth_row[#fourth_row + 1] = keys[4][9]
                local third_row = symbol_row(symbols[3])
                third_row[#third_row + 1] = keys[5][7]
                local space_width = keys[5][4].width
                local enter_width = keys[5][7].width
                keys[5][4].width = 7
                keys[5][7].width = layer == 4 and 2 or 1
                self.KEYS = {
                    symbol_row(symbols[1]),
                    symbol_row(symbols[2]),
                    third_row,
                    fourth_row,
                    { keys[5][1], keys[5][4], keys[5][2] },
                }
                original_add_keys(self, ...)
                self.KEYS = keys
                keys[5][4].width = space_width
                keys[5][7].width = enter_width
                return
            end

            local row = keys and keys[3]
            local last_key = row and row[#row]
            local lowercase = last_key and last_key[2]
            local is_comma = type(lowercase) == "table" and lowercase[1] == ","
            local english_letters = english_layout and self.keyboard_layer <= 2
            local hide_comma = english_letters and row and #row == 10 and is_comma
            local bottom_row = keys and keys[5]
            local simplify_bottom = english_letters and Device:isTouchDevice()
                and bottom_row and #bottom_row == 7 and bottom_row[4][2] == " "
            local space_width = simplify_bottom and bottom_row[4].width
            local x_key = english_letters and keys[4] and keys[4][3]
            local clean_x_key
            if x_key then
                clean_x_key = {}
                for layer = 1, #x_key do
                    local popup = x_key[layer]
                    if layer <= 2 and type(popup) == "table" then
                        local clean_popup = {}
                        for name, value in pairs(popup) do
                            if value ~= "Σ" then clean_popup[name] = value end
                        end
                        clean_x_key[layer] = clean_popup
                    else
                        clean_x_key[layer] = popup
                    end
                end
            end
            if not hide_comma and not simplify_bottom and not clean_x_key then
                return original_add_keys(self, ...)
            end

            if hide_comma then table.remove(row) end
            if clean_x_key then keys[4][3] = clean_x_key end
            if simplify_bottom then
                bottom_row[4].width = 7
                keys[5] = { bottom_row[1], bottom_row[4], bottom_row[2] }
            end
            original_add_keys(self, ...)
            if simplify_bottom then
                bottom_row[4].width = space_width
                keys[5] = bottom_row
            end
            if clean_x_key then keys[4][3] = x_key end
            if hide_comma then row[#row + 1] = last_key end
        end
    end

    if not VirtualKeyboard._zen_phone_space then
        VirtualKeyboard._zen_phone_space = true
        local original_add_char = VirtualKeyboard.addChar
        function VirtualKeyboard:addChar(key)
            local deliberate_double_space = self._zen_double_space
            self._zen_double_space = nil
            if key ~= " " then self._zen_space_tap = nil end
            if key == " " and deliberate_double_space and self.inputbox:getChar(-1) == " " then
                logger.dbg("Zen keyboard double space")
                self.inputbox:delChar()
                return original_add_char(self, ". ")
            end
            return original_add_char(self, key)
        end
    end

    -- Stable KOReader does not propagate this widget flag to the live input driver.
    if Device.input.allow_concurrent_taps == nil and not UIManager._zen_concurrent_taps then
        UIManager._zen_concurrent_taps = true
        local original_show = UIManager.show
        local original_close = UIManager.close
        function UIManager:show(widget, ...)
            original_show(self, widget, ...)
            if widget and (not self.silent_mode or not widget.honor_silent_mode) then
                Device.input.allow_concurrent_taps = widget.allow_concurrent_taps == true
            end
        end
        function UIManager:close(widget, ...)
            original_close(self, widget, ...)
            local top_window = self._window_stack[#self._window_stack]
            Device.input.allow_concurrent_taps = top_window
                and top_window.widget.allow_concurrent_taps == true or false
        end
    end
    local top_window = UIManager._window_stack[#UIManager._window_stack]
    if top_window then
        Device.input.allow_concurrent_taps = top_window.widget.allow_concurrent_taps == true
    end
    logger.dbg("Zen keyboard patch active", "class_concurrent=", VirtualKeyboard.allow_concurrent_taps,
        "live_concurrent=", Device.input.allow_concurrent_taps)

    -- Backport concurrent keyboard taps from recent KOReader to stable releases.
    if not Contact._zen_concurrent_taps then
        Contact._zen_concurrent_taps = true
        local original_tap_state = Contact.tapState
        function Contact:tapState(new_tap)
            local tev = self.current_tev
            logger.dbg("Zen keyboard contact", "slot=", self.slot, "id=", tev.id,
                "buddy=", self.buddy_contact ~= nil, "down=", self.down,
                "concurrent=", self.ges_dec.input.allow_concurrent_taps)
            if tev.id == -1 and self.buddy_contact and self.down
                    and self.ges_dec.input.allow_concurrent_taps then
                logger.dbg("Zen keyboard concurrent tap", "slot=", self.slot,
                    "x=", tev.x, "y=", tev.y)
                self.ges_dec:dropContact(self)
                return {
                    ges = "tap",
                    pos = Geom:new{ x = tev.x, y = tev.y, w = 0, h = 0 },
                    time = tev.timev,
                }
            end
            local gesture = original_tap_state(self, new_tap)
            if gesture then
                logger.dbg("Zen keyboard gesture", "slot=", self.slot,
                    "type=", gesture.ges, "x=", gesture.pos and gesture.pos.x,
                    "y=", gesture.pos and gesture.pos.y)
            end
            return gesture
        end
    end

    if VirtualKey._zen_responsive_keyboard then return end
    VirtualKey._zen_responsive_keyboard = true

    local function repaint(key, highlighted)
        local frame = key[1]
        if not frame or not frame.dimen then return end
        frame.invert = highlighted or modifier_active(key) or false
        logger.dbg("Zen keyboard feedback", "key=", key.key,
            "state=", highlighted and "black" or "normal",
            "x=", frame.dimen.x, "y=", frame.dimen.y)
        UIManager:widgetRepaint(frame, frame.dimen.x, frame.dimen.y)
        UIManager:setDirty(nil, "fast", frame.dimen)
    end

    local function show_feedback(key)
        if key._zen_feedback_release then
            UIManager:unschedule(key._zen_feedback_release)
        end
        repaint(key, true)
        if key.close_after_callback_widget then return end

        local keyboard = key.keyboard
        local keyboard_root = keyboard and keyboard[1]
        local frame = key[1]
        local function release()
            key._zen_feedback_release = nil
            if key[1] ~= frame or not keyboard or keyboard[1] ~= keyboard_root then return end
            if type(keyboard.isVisible) == "function" and not keyboard:isVisible() then return end
            repaint(key, false)
        end
        key._zen_feedback_release = release
        UIManager:scheduleIn(0.15, release)
    end

    local cursor_key

    local function stop_cursor_repeat(key)
        if key._zen_cursor_repeat then
            UIManager:unschedule(key._zen_cursor_repeat)
            key._zen_cursor_repeat = nil
        end
    end

    local function finish_cursor_move(key, ges)
        if not key or not key._zen_cursor_x then return false end
        if ges and ges.ges == "hold_release" then key:onZenCursorHoldPan(nil, ges) end
        stop_cursor_repeat(key)
        cursor_key = nil
        key.keyboard._zen_cursor_key = nil
        key._zen_cursor_x = nil
        key._zen_cursor_remainder = nil
        key._zen_cursor_direction = nil
        key.ignore_key_release = nil
        logger.dbg("Zen keyboard cursor end")
        repaint(key, false)
        return true
    end

    local function cursor_region(text_widget)
        if not text_widget or not text_widget.dimen or not text_widget.cursor_line
                or not text_widget.cursor_restore_x then return nil end
        local size = text_widget.cursor_line.dimen
        return Geom:new{
            x = text_widget.dimen.x + text_widget.cursor_restore_x,
            y = text_widget.dimen.y + text_widget.cursor_restore_y,
            w = size.w,
            h = size.h,
        }
    end

    local function move_cursor(key, chars)
        local inputbox = key.keyboard.inputbox
        local position = inputbox.charpos
        local target = math.max(1, math.min(#inputbox.charlist + 1, position + chars))
        if target == position then return false end
        local text_widget = inputbox.text_widget
        text_widget = text_widget and (text_widget.text_widget or text_widget)
        local old_region = cursor_region(text_widget)
        local fast_cursor = Device:isKobo() and old_region ~= nil
        local region
        if fast_cursor then
            local old_line = text_widget.virtual_line_num
            local original_set_dirty = UIManager.setDirty
            -- Stock cursor refreshes would otherwise promote our fast update back to ui.
            UIManager.setDirty = function(ui, widget, mode, area, dither)
                if widget == (text_widget.dialog or "all") then
                    local refresh = mode
                    mode = function()
                        local kind, bounds, hint = refresh, area, dither
                        if type(refresh) == "function" then kind, bounds, hint = refresh() end
                        if fast_cursor and kind == "ui" and region and region:contains(bounds) then
                            kind = "fast"
                        end
                        return kind, bounds, hint
                    end
                end
                return original_set_dirty(ui, widget, mode, area, dither)
            end
            local ok, err = pcall(inputbox.moveCursorToCharPos, inputbox, target)
            UIManager.setDirty = original_set_dirty
            if not ok then error(err) end
            fast_cursor = text_widget.virtual_line_num == old_line
        else
            inputbox:moveCursorToCharPos(target)
        end
        region = cursor_region(text_widget)
        if region then
            if old_region then region = region:combine(old_region) end
            -- Avoid overlapping e-ink updates leaving earlier cursor positions visible.
            UIManager:setDirty(text_widget.dialog or "all", fast_cursor and "fast" or "[ui]", region)
        end
        logger.dbg("Zen keyboard cursor move", "chars=", chars, "position=", target)
        return inputbox.charpos ~= position
    end

    local original_hold_state = Contact.holdState
    function Contact:holdState(new_hold)
        -- Cursor mode needs small pans, including movement back inside the usual dead zone.
        if cursor_key and not new_hold and not self.buddy_contact
                and self.down and self.current_tev.id ~= -1 then
            local gesture = self:handlePan()
            gesture.ges = "hold_pan"
            return gesture
        end
        return original_hold_state(self, new_hold)
    end

    local original_add_keys = VirtualKeyboard.addKeys
    function VirtualKeyboard:addKeys(...)
        finish_cursor_move(self._zen_cursor_key)
        return original_add_keys(self, ...)
    end

    local original_close_widget = VirtualKeyboard.onCloseWidget
    function VirtualKeyboard:onCloseWidget(...)
        finish_cursor_move(self._zen_cursor_key)
        return original_close_widget(self, ...)
    end

    local function key_at(keyboard, pos)
        if not keyboard or not keyboard.layout or not pos then return nil end
        for row_index = 1, #keyboard.layout do
            local row = keyboard.layout[row_index]
            for key_index = 1, #row do
                local key = row[key_index]
                if key.dimen and pos:intersectWith(key.dimen) then return key end
            end
        end
    end

    function VirtualKey:onTapSelect(skip_flash, ges)
        finish_cursor_move(cursor_key)
        Device:performHapticFeedback("KEYBOARD_TAP")
        self.keyboard.ignore_first_hold_release = false
        self.keyboard._zen_double_space = nil
        local direct_space_tap = self.key == " " and ges and ges.ges == "tap"
            and ges.pos and ges.time
        if direct_space_tap then
            local previous = self.keyboard._zen_space_tap
            local elapsed = previous and ges.time - previous.time
            local dx = previous and ges.pos.x - previous.x or 0
            local dy = previous and ges.pos.y - previous.y or 0
            local slop = math.min(self.dimen.w, self.dimen.h) * 0.5
            local deliberate = previous and elapsed >= double_space_min_interval
                and elapsed <= double_space_max_interval
                and dx * dx + dy * dy <= slop * slop
            self.keyboard._zen_double_space = deliberate or nil
            self.keyboard._zen_space_tap = deliberate and nil or {
                time = ges.time,
                x = ges.pos.x,
                y = ges.pos.y,
            }
            logger.dbg("Zen keyboard space tap", "elapsed_ms=", elapsed and time.to_ms(elapsed),
                "dx=", dx, "dy=", dy, "double=", deliberate)
        else
            self.keyboard._zen_space_tap = nil
        end
        logger.dbg("Zen keyboard tap", "key=", self.key, "skip_flash=", skip_flash,
            "skiptap=", self.skiptap, "flash_setting=", self.flash_keyboard)
        local keyboard = self.keyboard
        local current_key = self._zen_replacement_layout == keyboard.layout
            and self._zen_replacement_key
        if not skip_flash and not self.skiptap then
            show_feedback(current_key or self)
        end
        local shifted_layout = keyboard.shiftmode and keyboard.release_shift
            and not keyboard.symbolmode and keyboard.layout
        local callback = current_key and current_key.callback or self.callback
        if callback then callback() end
        if shifted_layout and keyboard.layout and shifted_layout ~= keyboard.layout
                and not keyboard.shiftmode then
            -- A second tap may still be targeting the keys from before the Shift redraw.
            for row_index, row in ipairs(shifted_layout) do
                local current_row = keyboard.layout[row_index]
                if current_row then
                    for key_index, old_key in ipairs(row) do
                        old_key._zen_replacement_layout = keyboard.layout
                        old_key._zen_replacement_key = current_row[key_index]
                    end
                end
            end
        end
        self.keyboard._zen_double_space = nil
        return true
    end

    function VirtualKey:onHoldSelect(_arg, ges)
        finish_cursor_move(cursor_key)
        Device:performHapticFeedback("LONG_PRESS")
        self.keyboard._zen_space_tap = nil
        self.keyboard._zen_double_space = nil
        if self.key == " " and ges and ges.pos then
            if self._zen_feedback_release then
                UIManager:unschedule(self._zen_feedback_release)
                self._zen_feedback_release = nil
            end
            self.keyboard.ignore_first_hold_release = false
            self.keyboard._zen_cursor_key = self
            cursor_key = self
            self.ignore_key_release = true
            self._zen_cursor_x = ges.pos.x
            self._zen_cursor_remainder = 0
            self.ges_events.ZenCursorHoldPan = {
                GestureRange:new{
                    ges = "hold_pan",
                    rate = Device:hasEinkScreen() and 10 or 30,
                },
            }
            self.ges_events.ZenCursorRelease = {
                GestureRange:new{ ges = "hold_release" },
                GestureRange:new{ ges = "two_finger_hold_release" },
                GestureRange:new{ ges = "two_finger_hold_pan_release" },
            }
            logger.dbg("Zen keyboard cursor start", "x=", ges.pos.x)
            repaint(self, true)
            return true
        end
        logger.dbg("Zen keyboard hold", "key=", self.key, "skiphold=", self.skiphold,
            "popup=", self.hold_cb_is_popup)
        if self.flash_keyboard and not self.skiphold and not self.hold_cb_is_popup then
            show_feedback(self)
        end
        if self.hold_callback then self.hold_callback() end
        return true
    end

    function VirtualKey:onZenCursorHoldPan(_arg, ges)
        if not self._zen_cursor_x or not ges or not ges.pos then return false end
        local step = math.max(1, math.floor(self.dimen.h * 0.15))
        local delta = ges.pos.x - self._zen_cursor_x
        if delta * self._zen_cursor_remainder < 0 then self._zen_cursor_remainder = 0 end
        delta = delta + self._zen_cursor_remainder
        local chars = delta >= 0 and math.floor(delta / step) or math.ceil(delta / step)
        self._zen_cursor_x = ges.pos.x
        self._zen_cursor_remainder = delta - chars * step
        if chars ~= 0 then move_cursor(self, chars) end

        local bounds = self.keyboard.dimen
        local edge = math.min(self.dimen.h, bounds.w * 0.2)
        local direction
        if ges.pos.y >= bounds.y and ges.pos.y < bounds.y + bounds.h then
            if ges.pos.x <= bounds.x + edge then direction = -1
            elseif ges.pos.x >= bounds.x + bounds.w - edge then direction = 1 end
        end
        if direction == self._zen_cursor_direction then return true end
        stop_cursor_repeat(self)
        self._zen_cursor_direction = direction
        if direction then
            local function repeat_cursor()
                if self._zen_cursor_repeat ~= repeat_cursor then return end
                if type(self.keyboard.isVisible) == "function" and not self.keyboard:isVisible() then
                    finish_cursor_move(self)
                    return
                end
                if move_cursor(self, direction) then
                    UIManager:scheduleIn(0.1, repeat_cursor)
                else
                    stop_cursor_repeat(self)
                end
            end
            self._zen_cursor_repeat = repeat_cursor
            UIManager:scheduleIn(0.3, repeat_cursor)
        end
        return true
    end

    function VirtualKey:onZenCursorRelease(_arg, ges)
        return finish_cursor_move(self, ges)
    end

    local original_hold_release = VirtualKey.onHoldReleaseKey
    function VirtualKey:onHoldReleaseKey(arg, ges, ...)
        if finish_cursor_move(self.keyboard and self.keyboard._zen_cursor_key, ges) then return true end
        return original_hold_release(self, arg, ges, ...)
    end

    function VirtualKey:onSwipeKey(_arg, ges)
        self.keyboard._zen_space_tap = nil
        self.keyboard._zen_double_space = nil
        local frame = self[1]
        local dimen = frame and frame.dimen
        local minimum_distance = dimen and math.min(dimen.w, dimen.h) * 0.5
        local end_key = key_at(self.keyboard, ges and ges.end_pos)
        logger.dbg("Zen keyboard swipe", "key=", self.key,
            "direction=", ges and ges.direction, "distance=", ges and ges.distance,
            "minimum=", minimum_distance, "end_key=", end_key and end_key.key)
        if end_key and end_key ~= self then
            logger.dbg("Zen keyboard recovered rapid keys", "first=", self.key,
                "second=", end_key.key)
            self:onTapSelect()
            end_key:onTapSelect()
            return true
        end
        if minimum_distance and ges and ges.distance and ges.distance < minimum_distance then
            logger.dbg("Zen keyboard short swipe treated as tap", "key=", self.key)
            return self:onTapSelect()
        end
        if G_reader_settings:isFalse("keyboard_swipes_enabled") then
            return self:onTapSelect()
        end
        Device:performHapticFeedback("KEYBOARD_TAP")
        show_feedback(self)
        if self.swipe_callback then self.swipe_callback(ges) end
        return true
    end
end

return apply_responsive_keyboard
