describe("responsive keyboard patch", function()
    local haptics
    local original_settings_is_false
    local refreshes
    local repaints
    local scheduled
    local GestureDetector
    local live_input
    local UIManager
    local VirtualKey
    local VirtualKeyboard
    local is_touch_device

    before_each(function()
        require("ffi/loadlib")
        haptics = {}
        refreshes = {}
        repaints = {}
        scheduled = {}
        is_touch_device = true
        original_settings_is_false = G_reader_settings.isFalse
        G_reader_settings.isFalse = function() return false end

        live_input = {}
        ZenSpec.replace("device", {
            input = live_input,
            isTouchDevice = function() return is_touch_device end,
            performHapticFeedback = function(_, kind) haptics[#haptics + 1] = kind end,
        })
        UIManager = {
            _window_stack = {},
            widgetRepaint = function(_, widget)
                repaints[#repaints + 1] = widget
            end,
            setDirty = function(_, widget, mode, region)
                refreshes[#refreshes + 1] = { widget, mode, region }
            end,
            scheduleIn = function(_, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            unschedule = function() end,
        }
        function UIManager:show(widget)
            self._window_stack[#self._window_stack + 1] = { widget = widget }
        end
        function UIManager:close(widget)
            if self._window_stack[#self._window_stack].widget == widget then
                table.remove(self._window_stack)
            end
        end
        ZenSpec.replace("ui/uimanager", UIManager)
        VirtualKey = {}
        function VirtualKey:init() end
        function VirtualKey:onHoldReleaseKey()
            if self.callback then self.callback() end
            return true
        end
        local function addKeys(self)
            if self and self.KEYS then
                self._built_third_row_size = #self.KEYS[3]
                self._built_x_key_chars = self.KEYS[4][3] and self.KEYS[4][3][self.keyboard_layer]
                self._built_rows = {}
                self._built_row_widths = {}
                for row_index = 1, #self.KEYS do
                    self._built_rows[row_index] = {}
                    self._built_row_widths[row_index] = {}
                    for key_index = 1, #self.KEYS[row_index] do
                        local spec = self.KEYS[row_index][key_index]
                        local key_chars = spec[self.keyboard_layer]
                        local key = type(key_chars) == "table" and key_chars[1] or key_chars
                        self._built_rows[row_index][key_index] = spec.label
                            or type(key_chars) == "table" and key_chars.label or key
                        self._built_row_widths[row_index][key_index] =
                            type(key_chars) == "table" and key_chars.width or spec.width or 1
                    end
                end
                self._built_bottom_row = {
                    size = #self.KEYS[5],
                    first = self.KEYS[5][1],
                    second = self.KEYS[5][2],
                    third = self.KEYS[5][3],
                    fourth = self.KEYS[5][4],
                    second_width = self.KEYS[5][2].width,
                }
            end
            return VirtualKey
        end
        local function addChar(self, key)
            self.inputbox:addChars(key)
        end
        VirtualKeyboard = { addKeys = addKeys, addChar = addChar }
        ZenSpec.replace("ui/widget/virtualkeyboard", VirtualKeyboard)
        ZenSpec.unload("device/gesturedetector")
        ZenSpec.unload("modules/global/patches/responsive_keyboard")
        require("modules/global/patches/responsive_keyboard")()
        GestureDetector = require("device/gesturedetector")
    end)

    after_each(function()
        G_reader_settings.isFalse = original_settings_is_false
        ZenSpec.unload("modules/global/patches/responsive_keyboard")
        ZenSpec.unload("device/gesturedetector")
        ZenSpec.unload("ui/widget/virtualkeyboard")
        ZenSpec.unload("ui/uimanager")
        ZenSpec.unload("device")
    end)

    it("enables concurrent taps only while the keyboard is shown", function()
        local keyboard = setmetatable({}, { __index = VirtualKeyboard })

        UIManager:show(keyboard)
        assert.is_true(live_input.allow_concurrent_taps)

        UIManager:close(keyboard)
        assert.is_false(live_input.allow_concurrent_taps)
    end)

    it("renders enabled shift and symbol modifiers black", function()
        local Blitbuffer = require("ffi/blitbuffer")
        local keyboard = {
            shiftmode = true,
            symbolmode = true,
            shiftmode_keys = { [""] = true },
            symbolmode_keys = { ["⌥"] = true },
        }
        local shift = setmetatable({
            [1] = { background = Blitbuffer.COLOR_LIGHT_GRAY },
            keyboard = keyboard,
            key = "",
            label = "",
        }, { __index = VirtualKey })
        local symbol = setmetatable({
            [1] = { background = Blitbuffer.COLOR_LIGHT_GRAY },
            keyboard = keyboard,
            label = "⌥",
        }, { __index = VirtualKey })

        shift:init()
        symbol:init()

        assert.are.equal(Blitbuffer.COLOR_WHITE, shift[1].background)
        assert.is_true(shift[1].invert)
        assert.are.equal(Blitbuffer.COLOR_WHITE, symbol[1].background)
        assert.is_true(symbol[1].invert)
    end)

    it("simplifies and centers English touch letter rows", function()
        local comma = { { ";" }, { "," }, { ";" }, { "," } }
        local third_row = { {}, {}, {}, {}, {}, {}, {}, {}, {}, comma }
        local symbol = { label = "⌥", width = 1.5 }
        local globe = { label = "🌐" }
        local period = { ".", ".", ":", ":" }
        local space = { " ", " ", " ", " ", width = 3 }
        local left = { label = "←" }
        local right = { label = "→" }
        local enter = { label = "⮠", "\n", "\n", "\n", "\n", width = 1.5 }
        local bottom_row = { symbol, globe, period, space, left, right, enter }
        local keyboard = setmetatable({
            KEYS = { {}, {}, third_row, {}, bottom_row },
            keyboard_layer = 2,
            getKeyboardLayout = function() return "en" end,
        }, { __index = VirtualKeyboard })

        keyboard:addKeys()
        assert.are.equal(9, keyboard._built_third_row_size)
        assert.are.equal(3, keyboard._built_bottom_row.size)
        assert.are.equal(symbol, keyboard._built_bottom_row.first)
        assert.are.equal(space, keyboard._built_bottom_row.second)
        assert.are.equal(globe, keyboard._built_bottom_row.third)
        assert.are.equal(7, keyboard._built_bottom_row.second_width)
        assert.are.equal(10, #third_row)
        assert.are.equal(comma, third_row[10])
        assert.are.equal(7, #bottom_row)
        assert.are.equal(3, space.width)

        keyboard.keyboard_layer = 3
        keyboard:addKeys()
        assert.are.equal(10, keyboard._built_third_row_size)
        assert.are.equal(7, keyboard._built_bottom_row.size)

        keyboard.keyboard_layer = 2
        is_touch_device = false
        keyboard:addKeys()
        assert.are.equal(9, keyboard._built_third_row_size)
        assert.are.equal(7, keyboard._built_bottom_row.size)
    end)

    it("reorganizes English touch symbol layers without numeric keys", function()
        local layout = require("ui/data/keyboardlayouts/en_keyboard")
        local original_keys = layout.keys
        local keyboard = setmetatable({
            KEYS = original_keys,
            keyboard_layer = 4,
            getKeyboardLayout = function() return "en" end,
        }, { __index = VirtualKeyboard })

        keyboard:addKeys()
        assert.are.same({ "[", "]", "{", "}", "#", "%", "^", "*", "+", "=" },
            keyboard._built_rows[1])
        assert.are.same({ "_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•" },
            keyboard._built_rows[2])
        assert.are.same({ ":", ";", "(", ")", "$", "&", "@", '"', "⮠" },
            keyboard._built_rows[3])
        assert.are.same({ 1, 1, 1, 1, 1, 1, 1, 1, 2 }, keyboard._built_row_widths[3])
        assert.are.same({ "", "-", "/", ".", ",", "?", "!", "`", "" },
            keyboard._built_rows[4])
        assert.are.same({ 1.5, 1, 1, 1, 1, 1, 1, 1, 1.5 }, keyboard._built_row_widths[4])
        assert.are.same({ "⌥", "_", "🌐" },
            keyboard._built_rows[5])
        assert.are.same({ 1.5, 7, 1 }, keyboard._built_row_widths[5])
        assert.are.equal(7, keyboard._built_bottom_row.second_width)
        assert.are.equal(original_keys, keyboard.KEYS)
        assert.are.equal(1.5, original_keys[5][1].width)
        assert.are.equal(3, original_keys[5][4].width)
        assert.are.equal(1.5, original_keys[5][7].width)

        keyboard.keyboard_layer = 3
        keyboard:addKeys()
        assert.are.same({ "[", "]", "{", "}", "#", "%", "^", "*", "+", "=" },
            keyboard._built_rows[1])
        assert.are.same({ "≤", "≥", "≠", "∓", "±", "÷", "⨯", "∂", "∫", "Σ" },
            keyboard._built_rows[2])
        assert.are.same({ "∇", "…", "†", "¶", "№", "‰", "°", "«", "»", "⮠" },
            keyboard._built_rows[3])
        assert.are.same({ 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 }, keyboard._built_row_widths[3])
        assert.are.same({ "", "`", "‘", "’", "“", "”", "∞", ";", "" },
            keyboard._built_rows[4])
        assert.are.same({ 1.5, 1, 1, 1, 1, 1, 1, 1, 1.5 }, keyboard._built_row_widths[4])
        assert.are.same({ "⌥", "_", "🌐" },
            keyboard._built_rows[5])
        assert.are.same({ 1.5, 7, 1 }, keyboard._built_row_widths[5])
        assert.are.equal(7, keyboard._built_bottom_row.second_width)
        assert.are.equal(original_keys, keyboard.KEYS)

        keyboard.keyboard_layer = 1
        keyboard:addKeys()
        assert.is_nil(keyboard._built_x_key_chars.alt_label)
        for index = 1, #keyboard._built_x_key_chars do
            assert.are_not.equal("Σ", keyboard._built_x_key_chars[index])
        end
        assert.are.equal("Σ", original_keys[4][3][1].alt_label)
        assert.are.equal("Σ", original_keys[4][3][1][3])

        keyboard.keyboard_layer = 2
        keyboard:addKeys()
        assert.is_nil(keyboard._built_x_key_chars.alt_label)
        assert.are.equal("σ", keyboard._built_x_key_chars[3])
        assert.are.equal("ς", keyboard._built_x_key_chars[4])
    end)

    it("requires two intentional spacebar taps for period and space", function()
        local Geom = require("ui/geometry")
        local time = require("ui/time")
        local inputbox = { text = "word" }
        function inputbox:getChar(offset)
            local index = #self.text + 1 + offset
            if index < 1 or index > #self.text then return nil end
            return self.text:sub(index, index)
        end
        function inputbox:delChar()
            self.text = self.text:sub(1, -2)
        end
        function inputbox:addChars(chars)
            self.text = self.text .. chars
        end
        local keyboard = setmetatable({ inputbox = inputbox }, { __index = VirtualKeyboard })
        local frame = { dimen = Geom:new{ x = 100, y = 400, w = 700, h = 100 } }
        local space = setmetatable({
            [1] = frame,
            dimen = frame.dimen,
            key = " ",
            keyboard = keyboard,
            callback = function() keyboard:addChar(" ") end,
        }, { __index = VirtualKey })

        space:onTapSelect(nil, {
            ges = "tap", time = time.ms(100), pos = Geom:new{ x = 300, y = 450 },
        })
        assert.are.equal("word ", inputbox.text)
        space:onTapSelect(nil, {
            ges = "tap", time = time.ms(250), pos = Geom:new{ x = 310, y = 450 },
        })
        assert.are.equal("word. ", inputbox.text)

        inputbox.text = "word"
        space:onTapSelect(nil, {
            ges = "tap", time = time.ms(500), pos = Geom:new{ x = 300, y = 450 },
        })
        space:onTapSelect(nil, {
            ges = "tap", time = time.ms(650), pos = Geom:new{ x = 300, y = 350 },
        })
        assert.are.equal("word  ", inputbox.text)

        inputbox.text = "word"
        keyboard._zen_space_tap = nil
        space:onTapSelect(nil, {
            ges = "tap", time = time.ms(800), pos = Geom:new{ x = 300, y = 450 },
        })
        space:onTapSelect(nil, {
            ges = "tap", time = time.ms(850), pos = Geom:new{ x = 300, y = 450 },
        })
        assert.are.equal("word  ", inputbox.text)

        inputbox.text = "word"
        keyboard._zen_space_tap = nil
        space:onTapSelect(nil, {
            ges = "tap", time = time.ms(1000), pos = Geom:new{ x = 300, y = 450 },
        })
        space:onTapSelect(nil, {
            ges = "tap", time = time.ms(1350), pos = Geom:new{ x = 300, y = 450 },
        })
        assert.are.equal("word  ", inputbox.text)
    end)

    it("moves the cursor live while hold-panning the spacebar", function()
        local Geom = require("ui/geometry")
        local inserted = 0
        local inputbox = {
            charlist = { "a", "b", "c", "d", "e", "f", "g", "h" },
            charpos = 5,
        }
        function inputbox:moveCursorToCharPos(position)
            self.charpos = position
        end
        local keyboard = {
            dimen = Geom:new{ x = 0, y = 0, w = 1000, h = 500 },
            ignore_first_hold_release = true,
            inputbox = inputbox,
        }
        local frame = { dimen = Geom:new{ x = 100, y = 400, w = 700, h = 100 } }
        local key = setmetatable({
            [1] = frame,
            dimen = frame.dimen,
            ges_events = {},
            key = " ",
            keyboard = keyboard,
            callback = function() inserted = inserted + 1 end,
        }, { __index = VirtualKey })

        assert.is_true(key:onHoldSelect(nil, { pos = Geom:new{ x = 100, y = 450 } }))
        assert.is_true(frame.invert)
        assert.is_not_nil(key.ges_events.ZenCursorHoldPan)
        assert.is_not_nil(key.ges_events.ZenCursorRelease)

        key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 124, y = 450 } })
        assert.are.equal(5, inputbox.charpos)
        key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 126, y = 450 } })
        assert.are.equal(6, inputbox.charpos)
        key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 76, y = 450 } })
        assert.are.equal(5, inputbox.charpos)

        local other_key = setmetatable({
            keyboard = keyboard,
            callback = function() inserted = inserted + 1 end,
        }, { __index = VirtualKey })
        assert.is_true(other_key:onHoldReleaseKey())
        assert.is_false(frame.invert)
        assert.are.equal(0, inserted)
    end)

    it("inserts immediately and releases black feedback asynchronously", function()
        local callback_count = 0
        local frame = { dimen = { x = 1, y = 2, w = 3, h = 4 } }
        local keyboard_root = {}
        local key = setmetatable({
            [1] = frame,
            keyboard = { [1] = keyboard_root, ignore_first_hold_release = true },
            flash_keyboard = false,
            callback = function() callback_count = callback_count + 1 end,
        }, { __index = VirtualKey })

        assert.is_true(key:onTapSelect())
        assert.are.equal(1, callback_count)
        assert.are.same({ "KEYBOARD_TAP" }, haptics)
        assert.is_true(frame.invert)
        assert.are.equal("fast", refreshes[1][2])
        assert.are.equal(0.15, scheduled[1].delay)

        scheduled[1].callback()
        assert.is_false(frame.invert)
        assert.are.equal("fast", refreshes[2][2])
        assert.are.equal(2, #repaints)
    end)

    it("recovers a cross-key swipe as two rapid key taps", function()
        local Geom = require("ui/geometry")
        local typed = {}
        local keyboard = { ignore_first_hold_release = true }
        local first = setmetatable({
            [1] = { dimen = Geom:new{ x = 0, y = 0, w = 10, h = 10 } },
            dimen = Geom:new{ x = 0, y = 0, w = 10, h = 10 },
            keyboard = keyboard,
            key = "t",
            callback = function() typed[#typed + 1] = "t" end,
            swipe_callback = function() typed[#typed + 1] = "™" end,
        }, { __index = VirtualKey })
        local second = setmetatable({
            [1] = { dimen = Geom:new{ x = 20, y = 20, w = 10, h = 10 } },
            dimen = Geom:new{ x = 20, y = 20, w = 10, h = 10 },
            keyboard = keyboard,
            key = "m",
            callback = function() typed[#typed + 1] = "m" end,
        }, { __index = VirtualKey })
        keyboard.layout = { { first }, { second } }

        assert.is_true(first:onSwipeKey(nil, {
            direction = "southeast",
            distance = 28,
            end_pos = Geom:new{ x = 25, y = 25, w = 0, h = 0 },
        }))
        assert.are.same({ "t", "m" }, typed)
        assert.are.same({ "KEYBOARD_TAP", "KEYBOARD_TAP" }, haptics)
    end)

    it("requires a half-key movement for intentional swipes", function()
        local Geom = require("ui/geometry")
        local typed = {}
        local keyboard = { ignore_first_hold_release = true }
        local key = setmetatable({
            [1] = { dimen = Geom:new{ x = 0, y = 0, w = 100, h = 100 } },
            dimen = Geom:new{ x = 0, y = 0, w = 100, h = 100 },
            keyboard = keyboard,
            key = "n",
            callback = function() typed[#typed + 1] = "n" end,
            swipe_callback = function() typed[#typed + 1] = "ñ" end,
        }, { __index = VirtualKey })
        keyboard.layout = { { key } }

        key:onSwipeKey(nil, {
            direction = "west",
            distance = 49,
            end_pos = Geom:new{ x = 25, y = 50, w = 0, h = 0 },
        })
        assert.are.same({ "n" }, typed)

        typed = {}
        key:onSwipeKey(nil, {
            direction = "west",
            distance = 50,
            end_pos = Geom:new{ x = 25, y = 50, w = 0, h = 0 },
        })
        assert.are.same({ "ñ" }, typed)
    end)

    it("keeps overlapping rapid taps as separate key presses", function()
        local time = require("ui/time")
        local input = {
            main_finger_slot = 0,
            disable_double_tap = true,
            allow_concurrent_taps = VirtualKeyboard.allow_concurrent_taps,
            setTimeout = function() end,
            clearTimeout = function() end,
        }
        assert.is_true(input.allow_concurrent_taps)
        local detector = GestureDetector:new{
            input = input,
            screen = { scaleByDPI = function(_, value) return value end },
            active_contacts = {},
            contact_count = 0,
            previous_tap = {},
            clock_id = 0,
        }
        local first = { slot = 0, id = 1, x = 10, y = 20, timev = time.s(1) }
        local second = { slot = 1, id = 2, x = 80, y = 20, timev = time.s(1) + time.ms(10) }

        detector:feedEvent{ first, second }
        first.id = -1
        first.timev = time.s(1) + time.ms(20)
        local first_gestures = detector:feedEvent{ first }
        second.id = -1
        second.timev = time.s(1) + time.ms(30)
        local second_gestures = detector:feedEvent{ second }

        assert.are.equal("tap", first_gestures[1].ges)
        assert.are.equal(10, first_gestures[1].pos.x)
        assert.are.equal("tap", second_gestures[1].ges)
        assert.are.equal(80, second_gestures[1].pos.x)
    end)
end)
