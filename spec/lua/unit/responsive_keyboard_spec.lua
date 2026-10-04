describe("responsive keyboard patch", function()
    local haptics
    local original_settings_is_false
    local refreshes
    local repaints
    local scheduled
    local cancelled
    local GestureDetector
    local live_input
    local UIManager
    local VirtualKey
    local VirtualKeyboard
    local is_touch_device
    local is_eink_screen
    local is_kobo

    before_each(function()
        require("ffi/loadlib")
        haptics = {}
        refreshes = {}
        repaints = {}
        scheduled = {}
        cancelled = {}
        is_touch_device = true
        is_eink_screen = true
        is_kobo = false
        original_settings_is_false = G_reader_settings.isFalse
        G_reader_settings.isFalse = function() return false end

        live_input = {}
        ZenSpec.replace("device", {
            input = live_input,
            isTouchDevice = function() return is_touch_device end,
            hasEinkScreen = function() return is_eink_screen end,
            isKobo = function() return is_kobo end,
            performHapticFeedback = function(_, kind) haptics[#haptics + 1] = kind end,
        })
        UIManager = {
            _window_stack = {},
            widgetRepaint = function(_, widget)
                repaints[#repaints + 1] = widget
            end,
            setDirty = function(_, widget, mode, region, dither)
                refreshes[#refreshes + 1] = { widget, mode, region, dither }
            end,
            scheduleIn = function(_, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            unschedule = function(_, callback) cancelled[callback] = true end,
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
        VirtualKeyboard = {
            addKeys = addKeys,
            addChar = addChar,
            onCloseWidget = function(self) self.closed = true end,
            lang_to_keyboard_layout = { en = "en_keyboard", es = "es_keyboard" },
        }
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

    it("uses the lowercase key for a second tap already in flight when one-shot Shift releases", function()
        local typed = {}
        local keyboard = setmetatable({
            shiftmode = true,
            symbolmode = false,
            release_shift = true,
        }, { __index = VirtualKeyboard })
        function keyboard:setLayer()
            self.shiftmode = not self.shiftmode
            self.layout = self.shiftmode and self.upper_keys or self.lower_keys
        end
        local function letter(value)
            local key = setmetatable({ keyboard = keyboard, key = value }, { __index = VirtualKey })
            key.callback = function()
                keyboard:addChar(key.key)
                if keyboard.shiftmode and keyboard.release_shift then keyboard:setLayer("Shift") end
            end
            return key
        end
        local upper_a, upper_b = letter("A"), letter("B")
        keyboard.upper_keys = { { upper_a, upper_b } }
        keyboard.lower_keys = { { letter("a"), letter("b") } }
        keyboard.layout = keyboard.upper_keys
        keyboard.inputbox = { addChars = function(_, value) typed[#typed + 1] = value end }

        upper_a:onTapSelect(true)
        upper_b:onTapSelect(true)
        assert.are.same({ "A", "b" }, typed)

        typed = {}
        keyboard.shiftmode = true
        keyboard.release_shift = false
        keyboard.layout = keyboard.upper_keys
        upper_a:onTapSelect(true)
        upper_b:onTapSelect(true)
        assert.are.same({ "A", "B" }, typed)
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
            getKeyboardLayout = function() return "C" end,
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

    local function cursor_key(initial_position, length)
        local Geom = require("ui/geometry")
        local inputbox = {
            charlist = {},
            charpos = initial_position or 61,
        }
        for index = 1, length or 120 do inputbox.charlist[index] = "é" end
        function inputbox:moveCursorToCharPos(position)
            self.charpos = position
        end
        local keyboard = setmetatable({
            dimen = Geom:new{ x = 20, y = 10, w = 1000, h = 500 },
            ignore_first_hold_release = true,
            inputbox = inputbox,
            isVisible = function(self) return not self.closed end,
            getKeyboardLayout = function() return "es" end,
            keyboard_layer = 2,
        }, { __index = VirtualKeyboard })
        local frame = { dimen = Geom:new{ x = 120, y = 410, w = 700, h = 100 } }
        return setmetatable({
            [1] = frame,
            dimen = frame.dimen,
            ges_events = {},
            key = " ",
            keyboard = keyboard,
        }, { __index = VirtualKey })
    end

    it("moves one or two characters with small drags and responds immediately to reversal", function()
        local Geom = require("ui/geometry")
        local inserted = 0
        local key = cursor_key(5, 8)
        local inputbox = key.keyboard.inputbox

        assert.is_true(key:onHoldSelect(nil, { pos = Geom:new{ x = 520, y = 450 } }))
        assert.is_true(key[1].invert)
        assert.is_not_nil(key.ges_events.ZenCursorHoldPan)
        assert.is_not_nil(key.ges_events.ZenCursorRelease)

        key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 531, y = 450 } })
        assert.are.equal(5, inputbox.charpos)
        key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 534, y = 450 } })
        assert.are.equal(5, inputbox.charpos)
        key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 535, y = 450 } })
        assert.are.equal(6, inputbox.charpos)
        key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 566, y = 450 } })
        assert.are.equal(8, inputbox.charpos)
        key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 551, y = 450 } })
        assert.are.equal(7, inputbox.charpos)

        local other_key = setmetatable({
            keyboard = key.keyboard,
            callback = function() inserted = inserted + 1 end,
        }, { __index = VirtualKey })
        assert.is_true(other_key:onHoldReleaseKey())
        assert.is_false(key[1].invert)
        assert.are.equal(0, inserted)
        assert.are.equal(0, #scheduled)
    end)

    it("limits scrub redraws and applies the final finger position on release", function()
        local Geom = require("ui/geometry")
        local time = require("ui/time")
        for index = 1, 2 do
            is_eink_screen = index == 1
            local key = cursor_key()
            key:onHoldSelect(nil, { pos = Geom:new{ x = 520, y = 450 } })
            local range = key.ges_events.ZenCursorHoldPan[1]
            assert.are.equal(is_eink_screen and 10 or 30, range.rate)
            local pan = { ges = "hold_pan", pos = Geom:new{ x = 535, y = 450 }, time = time.s(1) }
            assert.is_true(range:match(pan))
            key:onZenCursorHoldPan(nil, pan)
            pan.pos.x, pan.time = 550, time.s(1) + time.ms(10)
            assert.is_false(range:match(pan))
            assert.are.equal(62, key.keyboard.inputbox.charpos)
            local release = { ges = "hold_release", pos = pan.pos }
            if index == 1 then
                key:onZenCursorRelease(nil, release)
            else
                local other = setmetatable({ keyboard = key.keyboard }, { __index = VirtualKey })
                other:onHoldReleaseKey(nil, release)
            end
            assert.are.equal(63, key.keyboard.inputbox.charpos)
            assert.is_nil(key.keyboard._zen_cursor_key)
        end
    end)

    it("refreshes the old and new cursor areas together without merging display updates", function()
        local Geom = require("ui/geometry")
        for index = 1, 2 do
            local key = cursor_key()
            local inputbox = key.keyboard.inputbox
            local text_widget = {
                dimen = Geom:new{ x = 100, y = 200, w = 600, h = 100 },
                cursor_line = { dimen = Geom:new{ w = 2, h = 20 } },
                cursor_restore_x = 10,
                cursor_restore_y = 0,
                dialog = {},
            }
            inputbox.text_widget = index == 1 and text_widget or { text_widget = text_widget }
            function inputbox:moveCursorToCharPos(position)
                self.charpos = position
                text_widget.cursor_restore_x = text_widget.cursor_restore_x + 20
                text_widget.cursor_restore_y = text_widget.cursor_restore_y + 20
            end
            key:onHoldSelect(nil, { pos = Geom:new{ x = 520, y = 450 } })
            key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 535, y = 450 } })
            local refresh = refreshes[#refreshes]
            assert.are.equal(text_widget.dialog, refresh[1])
            assert.are.equal("[ui]", refresh[2])
            assert.are.same(Geom:new{ x = 110, y = 200, w = 22, h = 40 }, refresh[3])
            key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 1019, y = 450 } })
            local callback = scheduled[#scheduled].callback
            callback()
            refresh = refreshes[#refreshes]
            assert.are.equal("[ui]", refresh[2])
            assert.are.same(Geom:new{ x = 150, y = 240, w = 22, h = 40 }, refresh[3])
            key:onZenCursorRelease()
        end
    end)

    it("uses fast Kobo cursor refreshes without downgrading text scrolling or other regions", function()
        local Geom = require("ui/geometry")
        is_kobo = true
        for index = 1, 4 do
            local key = cursor_key()
            local inputbox = key.keyboard.inputbox
            local text_widget = {
                dimen = Geom:new{ x = 100, y = 200, w = 600, h = 100 },
                cursor_line = { dimen = Geom:new{ w = 2, h = 20 } },
                cursor_restore_x = 10,
                cursor_restore_y = 0,
                virtual_line_num = 1,
                dialog = {},
            }
            local scrolled = index > 2
            local deferred = index % 2 == 1
            local scrollbar = Geom:new{ x = 700, y = 200, w = 10, h = 100 }
            inputbox.text_widget = { text_widget = text_widget }
            local original_set_dirty = UIManager.setDirty
            function inputbox:moveCursorToCharPos(position)
                self.charpos = position
                text_widget.cursor_restore_x = 30
                if scrolled then text_widget.virtual_line_num = 2 end
                local regions = scrolled and { text_widget.dimen } or {
                    Geom:new{ x = 110, y = 200, w = 2, h = 20 },
                    Geom:new{ x = 130, y = 200, w = 2, h = 20 },
                }
                regions[#regions + 1] = scrollbar
                for region_index = 1, #regions do
                    local region = regions[region_index]
                    if deferred then
                        UIManager:setDirty(text_widget.dialog, function() return "ui", region, true end)
                    else
                        UIManager:setDirty(text_widget.dialog, "ui", region, true)
                    end
                end
            end
            key:onHoldSelect(nil, { pos = Geom:new{ x = 520, y = 450 } })
            refreshes = {}
            key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 535, y = 450 } })
            assert.are.equal(original_set_dirty, UIManager.setDirty)
            for refresh_index = 1, #refreshes do
                local refresh = refreshes[refresh_index]
                local mode, region, dither = refresh[2], refresh[3], refresh[4]
                if type(mode) == "function" then mode, region, dither = mode() end
                if region == text_widget.dimen or region == scrollbar then
                    assert.are.equal("ui", mode)
                else
                    assert.are.equal(scrolled and "[ui]" or "fast", mode)
                end
                if refresh_index < #refreshes then assert.is_true(dither) end
            end
            assert.are.same(Geom:new{ x = 110, y = 200, w = 22, h = 20 },
                refreshes[#refreshes][3])
            key:onZenCursorRelease()
        end
    end)

    it("receives sub-threshold hold pans only in cursor mode, including return to the hold origin", function()
        local time = require("ui/time")
        local timers = {}
        live_input.main_finger_slot = 0
        live_input.setTimeout = function(_, _slot, name, callback) timers[name] = callback end
        live_input.clearTimeout = function() end
        local detector = GestureDetector:new{
            input = live_input,
            screen = { scaleByDPI = function(_, value) return value end },
            active_contacts = {},
            contact_count = 0,
            previous_tap = {},
            clock_id = 0,
        }
        local touch = { slot = 0, id = 1, x = 520, y = 450, timev = time.s(1) }
        detector:feedEvent{ touch }
        local hold = timers.hold()
        assert.are.equal("hold", hold.ges)
        touch.x = 535
        assert.are.equal(0, #detector:feedEvent{ touch })

        local key = cursor_key()
        key:onHoldSelect(nil, hold)
        local pan = detector:feedEvent{ touch }[1]
        assert.are.equal("hold_pan", pan.ges)
        key:onZenCursorHoldPan(nil, pan)
        assert.are.equal(62, key.keyboard.inputbox.charpos)
        touch.x = 520
        pan = detector:feedEvent{ touch }[1]
        assert.are.equal("hold_pan", pan.ges)
        key:onZenCursorHoldPan(nil, pan)
        assert.are.equal(61, key.keyboard.inputbox.charpos)

        touch.id, touch.y = -1, 0
        local release = detector:feedEvent{ touch }[1]
        assert.are.equal("hold_release", release.ges)
        assert.is_true(key.ges_events.ZenCursorRelease[1]:match(release))
        key:onZenCursorRelease()
        touch.id, touch.y, touch.timev = 2, 450, time.s(2)
        detector:feedEvent{ touch }
        timers.hold()
        touch.x = 535
        assert.are.equal(0, #detector:feedEvent{ touch })
    end)

    it("repeats farther in from both keyboard edges, stops inward, and cancels on release or lifecycle changes", function()
        local Geom = require("ui/geometry")
        local key = cursor_key()
        local inputbox = key.keyboard.inputbox
        key:onHoldSelect(nil, { pos = Geom:new{ x = 520, y = 450 } })
        key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 919, y = 450 } })
        assert.are.equal(0, #scheduled)
        key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 920, y = 450 } })
        assert.are.equal(87, inputbox.charpos)
        local repeat_right = scheduled[#scheduled].callback
        assert.are.equal(0.3, scheduled[#scheduled].delay)
        repeat_right()
        assert.are.equal(88, inputbox.charpos)
        assert.are.equal(0.1, scheduled[#scheduled].delay)
        key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 921, y = 450 } })
        assert.are.equal(repeat_right, scheduled[#scheduled].callback)
        repeat_right()
        assert.are.equal(89, inputbox.charpos)

        key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 800, y = 450 } })
        assert.is_true(cancelled[repeat_right])
        local position = inputbox.charpos
        repeat_right()
        assert.are.equal(position, inputbox.charpos)
        key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 120, y = 450 } })
        local repeat_left = scheduled[#scheduled].callback
        position = inputbox.charpos
        repeat_left()
        assert.are.equal(position - 1, inputbox.charpos)
        key:onZenCursorRelease()
        assert.is_true(cancelled[repeat_left])
        position = inputbox.charpos
        repeat_left()
        assert.are.equal(position, inputbox.charpos)

        for index = 1, 2 do
            key:onHoldSelect(nil, { pos = Geom:new{ x = 520, y = 450 } })
            key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 920, y = 450 } })
            local callback = scheduled[#scheduled].callback
            if index == 1 then key.keyboard:addKeys() else key.keyboard:onCloseWidget() end
            assert.is_true(cancelled[callback])
            assert.is_nil(key.keyboard._zen_cursor_key)
            position = inputbox.charpos
            callback()
            assert.are.equal(position, inputbox.charpos)
        end
        assert.is_true(key.keyboard.closed)
    end)

    it("keeps the middle of a narrow keyboard free of repeat zones", function()
        local Geom = require("ui/geometry")
        local key = cursor_key()
        key.keyboard.dimen.w, key.dimen.x, key.dimen.w = 60, 20, 60
        key:onHoldSelect(nil, { pos = Geom:new{ x = 50, y = 450 } })
        key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 51, y = 450 } })
        assert.are.equal(0, #scheduled)
        key:onZenCursorRelease()
    end)

    it("stops edge repeats at text boundaries and when dragged outside the keyboard vertically", function()
        local Geom = require("ui/geometry")
        for index, x in ipairs{ 21, 1019 } do
            local key = cursor_key()
            local inputbox = key.keyboard.inputbox
            key:onHoldSelect(nil, { pos = Geom:new{ x = 520, y = 450 } })
            key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = x, y = 450 } })
            local callback = scheduled[#scheduled].callback
            inputbox.charpos = index == 1 and 2 or #inputbox.charlist
            callback()
            assert.are.equal(index == 1 and 1 or #inputbox.charlist + 1, inputbox.charpos)
            local count = #scheduled
            callback()
            assert.are.equal(count, #scheduled)
            key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 520, y = 450 } })
            key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = x, y = 450 } })
            callback = scheduled[#scheduled].callback
            key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = x, y = 0 } })
            assert.is_true(cancelled[callback])
            key:onZenCursorRelease()
        end
    end)

    it("cancels edge repeats when another touch interrupts cursor mode", function()
        local Geom = require("ui/geometry")
        for index = 1, 4 do
            local key = cursor_key()
            key:onHoldSelect(nil, { pos = Geom:new{ x = 520, y = 450 } })
            key:onZenCursorHoldPan(nil, { pos = Geom:new{ x = 1019, y = 450 } })
            local callback = scheduled[#scheduled].callback
            local other = setmetatable({ key = "a", keyboard = key.keyboard }, { __index = VirtualKey })
            if index == 1 then
                other:onTapSelect(true)
            elseif index == 2 then
                other:onHoldSelect()
            else
                local release = {
                    ges = index == 3 and "two_finger_hold_release" or "two_finger_hold_pan_release",
                }
                assert.is_true(key.ges_events.ZenCursorRelease[index - 1]:match(release))
                key:onZenCursorRelease()
            end
            assert.is_true(cancelled[callback])
            assert.is_nil(key.keyboard._zen_cursor_key)
            local position = key.keyboard.inputbox.charpos
            callback()
            assert.are.equal(position, key.keyboard.inputbox.charpos)
        end
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
