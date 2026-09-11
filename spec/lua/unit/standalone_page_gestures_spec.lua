describe("standalone page gestures", function()
    local original_guard
    local original_modules
    local UIManager
    local FileManager

    local module_names = {
        "apps/filemanager/filemanager",
        "common/clock_timer",
        "common/ui/background",
        "common/widget_resources",
        "modules/filebrowser/patches/standalone_page",
        "ui/geometry",
        "ui/uimanager",
        "ui/widget/menu",
        "ui/widget/titlebar",
    }

    before_each(function()
        original_guard = rawget(_G, "__ZEN_UI_BROADCAST_GUARD_PATCHED")
        original_modules = {}
        for _i, name in ipairs(module_names) do
            original_modules[name] = package.loaded[name]
        end

        _G.__ZEN_UI_BROADCAST_GUARD_PATCHED = nil
        UIManager = {
            broadcastEvent = function() end,
        }
        FileManager = {}
        ZenSpec.replace("apps/filemanager/filemanager", FileManager)
        ZenSpec.replace("common/clock_timer", { bind = function() end })
        ZenSpec.replace("common/ui/background", {})
        ZenSpec.replace("common/widget_resources", {
            replaceChild = function(group, index, child) group[index] = child end,
        })
        ZenSpec.replace("ui/geometry", {})
        ZenSpec.replace("ui/uimanager", UIManager)
        ZenSpec.replace("ui/widget/menu", {})
        ZenSpec.replace("ui/widget/titlebar", {})
    end)

    after_each(function()
        _G.__ZEN_UI_BROADCAST_GUARD_PATCHED = original_guard
        for _i, name in ipairs(module_names) do
            package.loaded[name] = original_modules[name]
        end
    end)

    local function zone(id, ges_name, calls)
        return {
            def = { id = id },
            gs_range = {
                match = function(_self, ges)
                    return ges.ges == ges_name
                end,
            },
            handler = function()
                calls[#calls + 1] = id
                return true
            end,
        }
    end

    it("shows a supplied label in a standalone status row", function()
        local received_label
        local title_group = { {}, {} }
        title_group.resetLayout = function() end
        FileManager.instance = {}
        local menu = { title_bar = { title_group = title_group } }
        local StandalonePage = require("modules/filebrowser/patches/standalone_page")

        StandalonePage.apply_status_row(menu, {
            label = "Kindle Library",
            createStatusRow = function(_path, _file_manager, label)
                received_label = label
                return { label = label }
            end,
        })

        assert.are.equal("Kindle Library", received_label)
        assert.are.equal("Kindle Library", title_group[2].label)
    end)

    it("gives every Gesture Manager family priority over page handlers", function()
        local StandalonePage = require("modules/filebrowser/patches/standalone_page")
        local page_calls = 0
        local gesture_calls = {}
        local menu = {
            handleEvent = function()
                page_calls = page_calls + 1
                return true
            end,
        }
        FileManager.instance = {
            _ordered_touch_zones = {},
        }
        StandalonePage.enable_gesture_manager_dispatch(menu)

        local cases = {
            { "tap_top_left_corner", "tap" },
            { "hold_top_right_corner", "hold" },
            { "double_tap_bottom_left_corner", "double_tap" },
            { "one_finger_swipe_left_edge_down", "swipe" },
            { "short_diagonal_swipe", "swipe" },
            { "two_finger_tap_top_left_corner", "two_finger_tap" },
            { "two_finger_swipe_south", "two_finger_swipe" },
            { "spread_gesture", "spread" },
            { "pinch_gesture", "pinch" },
            { "rotate_cw", "rotate" },
            { "multiswipe", "multiswipe" },
        }
        for _i, case in ipairs(cases) do
            FileManager.instance._ordered_touch_zones = {
                zone(case[1], case[2], gesture_calls),
            }
            assert.is_true(menu:handleEvent({
                handler = "onGesture",
                args = { { ges = case[2], direction = "south" } },
            }))
        end

        assert.are.equal(0, page_calls)
        assert.are.same({
            "tap_top_left_corner",
            "hold_top_right_corner",
            "double_tap_bottom_left_corner",
            "one_finger_swipe_left_edge_down",
            "short_diagonal_swipe",
            "two_finger_tap_top_left_corner",
            "two_finger_swipe_south",
            "spread_gesture",
            "pinch_gesture",
            "rotate_cw",
            "multiswipe",
        }, gesture_calls)
    end)

    it("gives the standalone navbar priority inside its screen band", function()
        local StandalonePage = require("modules/filebrowser/patches/standalone_page")
        local page_calls = 0
        local gesture_calls = {}
        local menu = {
            dimen = { h = 1000 },
            _zen_navbar_height = 100,
            handleEvent = function()
                page_calls = page_calls + 1
                return true
            end,
        }
        FileManager.instance = {
            _ordered_touch_zones = {
                zone("tap_bottom_right_corner", "tap", gesture_calls),
            },
        }
        StandalonePage.enable_gesture_manager_dispatch(menu)

        assert.is_true(menu:handleEvent({
            handler = "onGesture",
            args = { { ges = "tap", pos = { y = 950 } } },
        }))
        assert.are.equal(1, page_calls)
        assert.are.same({}, gesture_calls)

        assert.is_true(menu:handleEvent({
            handler = "onGesture",
            args = { { ges = "tap", pos = { y = 800 } } },
        }))
        assert.are.equal(1, page_calls)
        assert.are.same({ "tap_bottom_right_corner" }, gesture_calls)
    end)

    it("keeps Home page swipes local without suppressing diagonals", function()
        local StandalonePage = require("modules/filebrowser/patches/standalone_page")
        local swipes = {}
        local menu = {
            _zen_block_fm_horizontal_swipe = true,
            handleEvent = function(self, event)
                return self:onSwipe(nil, event.args[1])
            end,
            onSwipe = function(_self, _arg, ges)
                swipes[#swipes + 1] = ges.direction
                return true
            end,
        }
        FileManager.instance = { _ordered_touch_zones = {} }
        StandalonePage.enable_filemanager_dispatch(menu)

        assert.is_true(menu:handleEvent({
            handler = "onGesture",
            args = { { ges = "swipe", direction = "west" } },
        }))
        assert.are.same({}, swipes)

        assert.is_true(menu:handleEvent({
            handler = "onGesture",
            args = { { ges = "swipe", direction = "southeast" } },
        }))
        assert.are.same({ "southeast" }, swipes)
    end)

    it("honors the touch-input filter for forwarded gestures", function()
        local StandalonePage = require("modules/filebrowser/patches/standalone_page")
        local gesture_calls = {}
        local menu = { handleEvent = function() return false end }
        FileManager.instance = {
            _ordered_touch_zones = {
                zone("short_diagonal_swipe", "swipe", gesture_calls),
            },
            isGestureAlwaysActive = function(self)
                return self.allow_gesture == true
            end,
        }
        StandalonePage.enable_gesture_manager_dispatch(menu)
        UIManager._input_gestures_disabled = true
        local event = {
            handler = "onGesture",
            args = { { ges = "swipe", direction = "southeast" } },
        }

        assert.is_false(menu:handleEvent(event))
        assert.are.same({}, gesture_calls)

        FileManager.instance.allow_gesture = true
        assert.is_true(menu:handleEvent(event))
        assert.are.same({ "short_diagonal_swipe" }, gesture_calls)
    end)
end)
