describe("Double-tap book opening", function()
    local now
    local config
    local saved_modules
    local scheduled

    before_each(function()
        saved_modules = {
            time = package.loaded["ui/time"],
            gesture_detector = package.loaded["device/gesturedetector"],
            config_manager = package.loaded["config/manager"],
            ui_manager = package.loaded["ui/uimanager"],
        }
        now = 0
        config = { developer = { double_tap_to_open_books = true } }
        scheduled = {}
        ZenSpec.replace("ui/time", {
            now = function() return now end,
            ms = function(value) return value / 1000 end,
            to_s = function(value) return value end,
        })
        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function(_self, delay, callback) scheduled[callback] = delay end,
            unschedule = function(_self, callback) scheduled[callback] = nil end,
        })
        ZenSpec.replace("device/gesturedetector", {
            ges_double_tap_interval = 0.3,
        })
        ZenSpec.replace("config/manager", {
            get = function() return config end,
        })
        ZenSpec.unload("common/book_open_tap")
    end)

    after_each(function()
        ZenSpec.unload("common/book_open_tap")
        package.loaded["ui/time"] = saved_modules.time
        package.loaded["device/gesturedetector"] = saved_modules.gesture_detector
        package.loaded["config/manager"] = saved_modules.config_manager
        package.loaded["ui/uimanager"] = saved_modules.ui_manager
    end)

    it("opens only after two rapid taps on the same book", function()
        local BookOpenTap = require("common/book_open_tap")

        assert.is_false(BookOpenTap.willOpen("/books/one.epub", 0))
        assert.is_false(BookOpenTap.shouldOpen("/books/one.epub"))
        assert.is_true(BookOpenTap.willOpen("/books/one.epub", 0.2))
        now = 0.2
        assert.is_true(BookOpenTap.shouldOpen("/books/one.epub"))
        assert.is_false(BookOpenTap.willOpen("/books/one.epub", 0.25))
        now = 0.25
        assert.is_false(BookOpenTap.shouldOpen("/books/one.epub"))
    end)

    it("rejects late and mismatched second taps", function()
        local BookOpenTap = require("common/book_open_tap")

        assert.is_false(BookOpenTap.shouldOpen("/books/one.epub"))
        now = 0.3
        assert.is_false(BookOpenTap.shouldOpen("/books/one.epub"))
        now = 0.4
        assert.is_false(BookOpenTap.shouldOpen("/books/two.epub"))
        now = 0.5
        assert.is_true(BookOpenTap.shouldOpen("/books/two.epub"))
    end)

    it("keeps single-tap opening when disabled", function()
        local BookOpenTap = require("common/book_open_tap")
        config.developer.double_tap_to_open_books = false

        assert.is_true(BookOpenTap.willOpen("/books/one.epub"))
        assert.is_true(BookOpenTap.shouldOpen("/books/one.epub"))
    end)

    it("opens the single-tap menu only after the double-tap interval", function()
        local BookOpenTap = require("common/book_open_tap")
        config.developer.single_tap_to_open_context_menu = true
        local menus = 0
        local show_menu = function() menus = menus + 1 end

        assert.is_false(BookOpenTap.shouldOpen("/books/one.epub", 0, show_menu))
        assert.are.equal(0, menus)
        local callback, delay = next(scheduled)
        assert.are.equal(0.3, delay)
        callback()
        assert.are.equal(1, menus)
        assert.is_nil(next(scheduled))
        assert.is_false(BookOpenTap.willOpen("/books/one.epub", 0.3))
    end)

    it("cancels the menu on a double tap or reset", function()
        local BookOpenTap = require("common/book_open_tap")
        config.developer.single_tap_to_open_context_menu = true
        local show_menu = function() error("unexpected context menu") end

        assert.is_false(BookOpenTap.shouldOpen("/books/one.epub", 0, show_menu))
        assert.is_true(BookOpenTap.shouldOpen("/books/one.epub", 0.2, show_menu))
        assert.is_nil(next(scheduled))
        assert.is_false(BookOpenTap.shouldOpen("/books/two.epub", 1, show_menu))
        BookOpenTap.reset()
        assert.is_nil(next(scheduled))
    end)

    it("replaces the pending menu when another book is tapped", function()
        local BookOpenTap = require("common/book_open_tap")
        config.developer.single_tap_to_open_context_menu = true
        local selected
        BookOpenTap.shouldOpen("/books/one.epub", 0, function() selected = "one" end)
        BookOpenTap.shouldOpen("/books/two.epub", 0.1, function() selected = "two" end)
        local callback = next(scheduled)
        assert.is_nil(next(scheduled, callback))
        callback()
        assert.are.equal("two", selected)
    end)

    it("does not open menus when either setting is disabled", function()
        local BookOpenTap = require("common/book_open_tap")
        local show_menu = function() error("unexpected context menu") end
        BookOpenTap.shouldOpen("/books/one.epub", 0, show_menu)
        assert.is_nil(next(scheduled))

        config.developer.single_tap_to_open_context_menu = true
        BookOpenTap.shouldOpen("/books/one.epub", 1, show_menu)
        local callback = next(scheduled)
        config.developer.single_tap_to_open_context_menu = false
        callback()
        assert.is_nil(next(scheduled))

        config.developer.single_tap_to_open_context_menu = true
        config.developer.double_tap_to_open_books = false
        assert.is_true(BookOpenTap.shouldOpen("/books/one.epub", 2, show_menu))
        assert.is_nil(next(scheduled))
    end)
end)
