describe("bottom status-bar pin control", function()
    local saved, saved_settings, PinFooter, Footer, screen, painted, color_screen, pins
    local names = { "modules/reader/pin_footer", "modules/reader/references", "device", "ui/font", "ui/geometry",
        "ui/size", "ui/uimanager", "gettext", "ffi/blitbuffer", "common/plugin_root", "common/utils",
        "common/ui/button_labels", "common/ui/color_icon_widget", "common/ui/color_text_widget",
        "common/reader_status_bar", "common/reader_themes", "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
        "apps/reader/modules/readerfooter", "apps/reader/modules/readerview" }

    before_each(function()
        saved = {}
        for _i, name in ipairs(names) do saved[name] = package.loaded[name] end
        saved_settings = G_reader_settings
        _G.G_reader_settings = { nilOrTrue = function() return true end }
        color_screen, pins = true, { "pin" }
        screen = { scaleBySize = function(_self, value) return value end, getHeight = function() return 800 end }
        ZenSpec.replace("device", { screen = screen, hasColorScreen = function() return color_screen end })
        ZenSpec.replace("ui/size", { radius = { window = 7 } })
        ZenSpec.replace("ui/font", { getFace = function(_self, name, size)
            return { realname = name, orig_size = size, size = screen:scaleBySize(size) }
        end })
        ZenSpec.replace("ui/geometry", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/uimanager", {})
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ffi/blitbuffer", { COLOR_BLACK = "black" })
        ZenSpec.replace("common/plugin_root", ZenSpec.root)
        ZenSpec.replace("common/utils", { resolveLocalIcon = function(dir, name) return dir .. name .. ".svg" end })
        ZenSpec.replace("common/ui/button_labels", { alignIcon = function() end })
        ZenSpec.replace("common/reader_status_bar", {})
        ZenSpec.replace("common/reader_themes", { getTextColor = function() end })
        ZenSpec.replace("modules/reader/references", { enabled = function() return true end,
            pinLocations = function() return pins end })
        local widget = { new = function(_self, spec)
            spec.getSize = function()
                return { w = spec.width or spec.face.size / 2, h = spec.height or spec.face.size }
            end
            return spec
        end }
        ZenSpec.replace("common/ui/color_icon_widget", widget)
        ZenSpec.replace("common/ui/color_text_widget", widget)
        ZenSpec.replace("ui/widget/horizontalspan", { new = function(_self, spec)
            spec.getSize = function() return { w = spec.width, h = 0 } end
            return spec
        end })
        ZenSpec.replace("ui/widget/horizontalgroup", { new = function(_self, spec)
            spec.getSize = function()
                local w, h = 0, 0
                for _i, child in ipairs(spec) do
                    local size = child:getSize()
                    w, h = w + size.w, math.max(h, size.h)
                end
                return { w = w, h = h }
            end
            spec.paintTo = function(_group, _bb, x, y) painted = { x = x, y = y } end
            spec.free = function() end
            return spec
        end })
        Footer = {
            getHeight = function(self) return self.vertical_frame:getSize().h + self.bottom_padding end,
            _updateFooterText = function(self) self._seen_width = self._saved_screen_width end,
            onCloseWidget = function() end,
            paintTo = function(self, bb, x)
                local height = self.vertical_frame:getSize().h + self.bottom_padding
                self.footer_content.dimen.y = 800 - height
                self.footer_container:paintTo(bb, x, self.footer_content.dimen.y)
            end,
            updateFooterContainer = function(self)
                self.footer_container = { dimen = { w = 600, h = self.height }, paintTo = function() end }
                self.footer_content = { dimen = { h = self.height + self.bottom_padding } }
                self.vertical_frame = {
                    getSize = function(frame)
                        frame.height = frame.height or self.footer_container.dimen.h
                        return { h = frame.height }
                    end,
                    resetLayout = function(frame) frame.height = nil end,
                }
            end,
        }
        ZenSpec.replace("apps/reader/modules/readerfooter", Footer)
        ZenSpec.replace("apps/reader/modules/readerview", { paintTo = function() end })
        ZenSpec.unload("modules/reader/pin_footer")
        PinFooter = require("modules/reader/pin_footer")
        PinFooter.apply()
    end)

    after_each(function()
        _G.G_reader_settings = saved_settings
        for _i, name in ipairs(names) do package.loaded[name] = saved[name] end
    end)

    it("keeps the icon size and outline padding consistent across footer heights and scales", function()
        local bb = { paintBorder = function() end }
        for _i, scale in ipairs({ 1, 2 }) do
            screen.scaleBySize = function(_self, value) return value * scale end
            for _j, font_size in ipairs({ 14, 28 }) do
                for _k, footer_height in ipairs({ 8, 14, 40 }) do
                    local footer = setmetatable({
                        settings = {}, ui = {}, view = { footer_visible = true },
                        height = footer_height * scale, horizontal_margin = 10 * scale, bottom_padding = scale,
                        footer_text_face = { size = font_size * scale },
                    }, { __index = Footer })
                    footer:updateFooterContainer()
                    footer.footer_container:paintTo(bb, 0, 100)
                    local box = footer._zen_pin_dimen
                    local label = footer._zen_pin_label
                    local height = (math.max(16, font_size) + 6) * scale
                    assert.equals(16 * scale, label[1].width)
                    assert.equals(16 * scale, label[1].height)
                    assert.equals(height, box.h)
                    assert.equals(math.max(footer.height, height), footer.footer_container.dimen.h)
                    assert.equals(100 + math.floor((footer.footer_container.dimen.h - height) / 2), box.y)
                    assert.equals(9 * scale, painted.x - box.x)
                    assert.equals(3 * scale, painted.y - box.y)
                    assert.equals(3 * scale, box.y + box.h - painted.y - label:getSize().h)
                end
            end
        end
    end)

    it("keeps monochrome icons compact while matching the footer font and fitting on screen", function()
        color_screen = false
        local bb = { paintBorder = function() end }
        for _i, scale in ipairs({ 1, 2 }) do
            screen.scaleBySize = function(_self, value) return math.ceil(value * scale) end
            for _j, font_size in ipairs({ 14, 28 }) do
                local face = { realname = "footer.ttf", orig_size = font_size, size = font_size * scale }
                local footer = setmetatable({
                    settings = {}, ui = {}, view = { footer_visible = true },
                    height = 14 * scale, horizontal_margin = 10 * scale, bottom_padding = scale,
                    footer_text_face = face,
                }, { __index = Footer })
                footer:updateFooterContainer()
                footer.footer_container:paintTo(bb, 0, 800 - footer.height)
                local box = footer._zen_pin_dimen
                local label = footer._zen_pin_label
                assert.equals(math.ceil(14 * scale), label[1].height)
                assert.equals(face.realname, label[3].face.realname)
                assert.equals(face, label[3].face)
                assert.equals(math.ceil(9 * 0.875 * scale), painted.x - box.x)
                assert.equals(math.ceil(3 * 0.875 * scale), painted.y - box.y)
                assert.is_true(box.y + box.h <= 800 - footer.bottom_padding)
                assert.is_true(painted.y + label:getSize().h < 800 - footer.bottom_padding)
                assert.equals(face, footer.footer_text_face)
            end
        end
    end)

    it("updates the count when the footer font changes", function()
        for _i, color in ipairs({ false, true }) do
            color_screen = color
            local footer = {
                settings = {}, ui = {}, view = { footer_visible = true }, horizontal_margin = 10,
                footer_text_face = { realname = "footer.ttf", orig_size = 14, size = 14 },
            }
            PinFooter.width(footer)
            local label = footer._zen_pin_label
            footer.footer_text_face = { realname = "footer.ttf", orig_size = 22, size = 22 }
            footer.settings.text_font_bold = true
            PinFooter.width(footer)
            assert.is_not.equal(label, footer._zen_pin_label)
            assert.equals(footer.footer_text_face, footer._zen_pin_label[3].face)
            assert.is_true(footer._zen_pin_label[3].bold)
        end
    end)

    it("refreshes cached footer and repaint heights when the first pin appears", function()
        local bb = { paintBorder = function() end }
        for _i, color in ipairs({ false, true }) do
            color_screen, pins = color, {}
            local footer = setmetatable({
                settings = {}, ui = {}, view = { footer_visible = true },
                height = 14, horizontal_margin = 10, bottom_padding = color and 6 or 1,
                footer_text_face = { realname = "footer.ttf", orig_size = 14, size = 14 },
            }, { __index = Footer })
            footer:updateFooterContainer()
            assert.equals(14 + footer.bottom_padding, footer:getHeight())
            footer:paintTo(bb, 0, 0)
            pins = { "pin" }
            footer:paintTo(bb, 0, 0)
            local box, region = footer._zen_pin_dimen, footer.footer_content.dimen
            assert.equals(PinFooter.height(footer) + footer.bottom_padding, region.h)
            assert.is_true(box.y >= region.y)
            assert.is_true(box.y + box.h <= region.y + region.h - footer.bottom_padding)
            assert.equals(800, region.y + region.h)
        end
    end)

    it("shrinks a text-less alongside progress bar so it stops before the pin", function()
        local footer = setmetatable({
            settings = { all_at_once = true, progress_bar_position = "alongside" },
            ui = {}, view = { footer_visible = true }, has_no_mode = true,
            height = 14, horizontal_margin = 10, bottom_padding = 1, _saved_screen_width = 600,
            footer_text_face = { realname = "footer.ttf", orig_size = 14, size = 14 },
        }, { __index = Footer })
        footer:updateFooterContainer()
        footer:_updateFooterText(true)
        -- Reserve only the box plus a short gap, not the full pin width.
        local box_w = footer._zen_pin_label:getSize().w + 2 * 9 * (color_screen and 1 or 0.875)
        assert.equals(600 - box_w - 8, footer._seen_width)
        assert.equals(600, footer._saved_screen_width)

        footer.has_no_mode = false
        footer:_updateFooterText(true)
        assert.equals(600, footer._seen_width)
    end)

    it("refreshes the whole previously painted footer when it hides", function()
        local bb = { paintBorder = function() end }
        screen.bb = bb
        local dirty = {}
        package.loaded["ui/uimanager"].setDirty = function(_self, widget, mode, region)
            dirty[#dirty + 1] = { widget = widget, mode = mode, region = region }
        end
        local dialog = {}
        local footer = setmetatable({
            settings = {}, ui = {}, view = { footer_visible = true, dialog = dialog },
            height = 14, horizontal_margin = 10, bottom_padding = 1,
            footer_text_face = { realname = "footer.ttf", orig_size = 14, size = 14 },
        }, { __index = Footer })
        footer:updateFooterContainer()
        footer:paintTo(bb, 0, 0)
        local painted_h = footer.footer_content.dimen.h
        assert.is_true(painted_h > footer.height + footer.bottom_padding)

        footer.view.footer_visible = false
        footer:_updateFooterText(true)
        assert.equals(1, #dirty)
        assert.equals(dialog, dirty[1].widget)
        assert.equals(painted_h, dirty[1].region.h)
        assert.equals(800, dirty[1].region.y + dirty[1].region.h)
        footer:_updateFooterText(true)
        assert.equals(1, #dirty)
    end)
end)
