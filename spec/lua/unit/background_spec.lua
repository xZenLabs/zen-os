describe("library background cleanup", function()
    local original_plugin

    before_each(function()
        original_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        ZenSpec.replace("device", { screen = {} })
        ZenSpec.replace("ffi/blitbuffer", { COLOR_WHITE = "white" })
        ZenSpec.replace("common/zen_logger", {
            new = function()
                return { warn = function() end }
            end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/widget/imagewidget", {})
        ZenSpec.replace("libs/libkoreader-lfs", {})
        ZenSpec.unload("common/ui/background")
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = original_plugin
        ZenSpec.unload("common/ui/background")
    end)

    it("keeps explicitly opaque widget backgrounds", function()
        local Background = require("common/ui/background")
        local protected = { background = "white", _zen_keep_background = true }
        local ordinary = { background = "white" }

        Background.clearWhiteBackgrounds({ protected, ordinary })

        assert.are.equal("white", protected.background)
        assert.is_nil(ordinary.background)
    end)

    it("accepts PNG backgrounds over white and fades the cached result", function()
        local screen = {
            night_mode = false,
            getWidth = function() return 800 end,
            getHeight = function() return 600 end,
        }
        local buffers = {}
        ZenSpec.replace("device", { screen = screen })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function() return "file" end,
        })
        ZenSpec.replace("ui/widget/imagewidget", {
            new = function(_class, options)
                return {
                    _img_w = 800,
                    _img_h = 600,
                    getSize = function() return { w = 800, h = 600 } end,
                    paintTo = function(_self, buffer)
                        assert.is_true(options.alpha)
                        assert.are.equal("white", buffer.fill_color)
                        buffer.image_paints = buffer.image_paints + 1
                    end,
                    free = function() end,
                }
            end,
        })
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_WHITE = "white",
            new = function()
                local buffer = {
                    image_paints = 0,
                    inversions = 0,
                }
                function buffer:fill(color) self.fill_color = color end
                function buffer:invertRect() self.inversions = self.inversions + 1 end
                function buffer:lightenRect(_x, _y, _w, _h, amount)
                    self.lightened = amount
                end
                function buffer:darkenRect(_x, _y, _w, _h, amount)
                    self.darkened = amount
                end
                function buffer:free() end
                buffers[#buffers + 1] = buffer
                return buffer
            end,
        })
        _G.__ZEN_UI_PLUGIN = {
            config = {
                library_background = {
                    enabled = true,
                    path = "/library/background.png",
                    opacity = 40,
                },
            },
        }
        ZenSpec.unload("common/ui/background")

        local Background = require("common/ui/background")
        assert.is_true(Background.isSupportedImagePath("/library/background.PNG"))
        assert.is_false(Background.isSupportedImagePath("/library/background.webp"))
        assert.is_true(Background.validateImage("/library/background.png"))
        assert.are.equal("/library/background.png", Background.library_path())
        local copies = 0
        local destination = {
            getType = function() return "bb8" end,
            blitFrom = function() copies = copies + 1 end,
        }

        assert.is_true(Background.paintScreenRegion(destination,
            0, 0, 0, 0, 800, 600, "/library/background.png"))
        assert.is_true(Background.paintScreenRegion(destination,
            0, 0, 0, 0, 800, 600, "/library/background.png"))
        assert.are.equal(1, #buffers)
        assert.are.equal(1, buffers[1].image_paints)
        assert.are.equal(0, buffers[1].inversions)
        assert.are.equal(0.6, buffers[1].lightened)
        assert.is_nil(buffers[1].darkened)

        screen.night_mode = true
        _G.__ZEN_UI_PLUGIN.config.library_background.opacity = 25
        assert.is_true(Background.paintScreenRegion(destination,
            0, 0, 0, 0, 800, 600, "/library/background.png"))
        assert.are.equal(2, #buffers)
        assert.are.equal(1, buffers[2].inversions)
        assert.are.equal(0.75, buffers[2].darkened)
        assert.is_nil(buffers[2].lightened)
        assert.are.equal(3, copies)
    end)

    it("coalesces missing-image recovery without restoring the live widget tree", function()
        local exists = true
        local saved = 0
        local recoveries = 0
        local scheduled = {}
        local path = "/library/background.jpg"
        local config = {
            library_background = { enabled = true, path = path },
        }
        local plugin = {
            config = config,
            saveConfig = function() saved = saved + 1 end,
        }
        _G.__ZEN_UI_PLUGIN = plugin
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function() return exists and "file" or nil end,
        })
        ZenSpec.replace("ui/widget/notification", {
            new = function(_self, opts) return opts end,
        })
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, callback) scheduled[#scheduled + 1] = callback end,
            show = function() end,
        })
        ZenSpec.unload("common/ui/background")

        local Background = require("common/ui/background")
        Background.paintScreenRegion = function() return true end
        local tile = { background = nil }
        local root = { background = "white", tile }
        local menu = {
            dimen = { w = 100, h = 100 },
            root,
        }
        Background.applyToMenu(menu)

        menu:paintTo({}, 0, 0)
        assert.is_nil(root.background)
        assert.is_nil(tile.background)

        Background.setMissingLibraryBackgroundHandler(function()
            recoveries = recoveries + 1
            assert.is_nil(root.background)
            assert.is_nil(tile.background)
            return true
        end)
        exists = false
        menu:paintTo({}, 0, 0)
        assert.are.equal("", Background.library_path(plugin))

        assert.is_false(config.library_background.enabled)
        assert.are.equal(1, saved)
        assert.are.equal(1, #scheduled)
        assert.are.equal(0, recoveries)
        assert.is_nil(root.background)
        assert.is_nil(tile.background)

        scheduled[1]()

        assert.are.equal(1, recoveries)
        assert.is_nil(root.background)
        assert.is_nil(tile.background)
        assert.are.equal("", Background.library_path(plugin))
        assert.are.equal(1, saved)
        assert.are.equal(1, #scheduled)
    end)

    it("retries a deferred recovery after a temporary blocker and then stops", function()
        local recoveries = 0
        local saved = 0
        local notices = 0
        local scheduled = {}
        local path = "/library/background.jpg"
        local config = {
            library_background = { enabled = true, path = path },
        }
        local plugin = {
            config = config,
            saveConfig = function() saved = saved + 1 end,
        }
        _G.__ZEN_UI_PLUGIN = plugin
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function() return nil end,
        })
        ZenSpec.replace("ui/widget/notification", {
            new = function(_self, opts) return opts end,
        })
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, callback) scheduled[#scheduled + 1] = callback end,
            show = function() notices = notices + 1 end,
        })
        ZenSpec.unload("common/ui/background")

        local Background = require("common/ui/background")
        Background.setMissingLibraryBackgroundHandler(function()
            recoveries = recoveries + 1
            return recoveries > 1
        end)

        assert.are.equal("", Background.library_path(plugin))
        assert.are.equal("", Background.library_path(plugin))
        assert.are.equal(1, #scheduled)
        scheduled[1]()

        assert.are.equal(1, recoveries)
        assert.are.equal(1, notices)
        assert.are.equal(1, saved)

        assert.are.equal("", Background.library_path(plugin))
        assert.are.equal("", Background.library_path(plugin))
        assert.are.equal(2, #scheduled)
        scheduled[2]()

        assert.are.equal(2, recoveries)
        assert.are.equal(1, notices)
        assert.are.equal(1, saved)
        assert.are.equal("", Background.library_path(plugin))
        assert.are.equal(2, #scheduled)
    end)

    it("disables a configured background and notifies when its image is missing", function()
        local saved = 0
        local shown
        local notice_closes = 0
        local dirty
        local scheduled = {}
        local path = "/library/removed.jpg"
        local config = {
            library_background = { enabled = true, path = path },
        }
        local plugin = {
            config = config,
            saveConfig = function() saved = saved + 1 end,
        }
        _G.__ZEN_UI_PLUGIN = plugin
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(checked_path, attribute)
                assert.are.equal(path, checked_path)
                assert.are.equal("mode", attribute)
                return nil
            end,
        })
        ZenSpec.replace("ui/widget/notification", {
            new = function(_self, opts)
                opts.onCloseWidget = function()
                    notice_closes = notice_closes + 1
                    return "closed"
                end
                return opts
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, callback) scheduled[#scheduled + 1] = callback end,
            show = function(_self, widget) shown = widget end,
            setDirty = function(_self, widget, refresh)
                dirty = { widget, refresh }
            end,
        })
        ZenSpec.unload("common/ui/background")

        local Background = require("common/ui/background")
        assert.are.equal("", Background.library_path(plugin))

        assert.is_false(config.library_background.enabled)
        assert.are.equal(path, config.library_background.path)
        assert.are.equal(1, saved)
        assert.are.equal(1, #scheduled)
        assert.is_nil(shown)

        scheduled[1]()
        assert.are.equal(
            "Library background was disabled because the image file was not found.",
            shown.text
        )
        assert.are.equal("closed", shown:onCloseWidget())
        assert.are.equal(1, notice_closes)
        assert.are.equal(2, #scheduled)
        assert.is_nil(dirty)

        scheduled[2]()
        assert.are.same({ "all", "full" }, dirty)
        assert.are.equal("", Background.library_path(plugin))
        assert.are.equal(1, saved)
    end)
end)
