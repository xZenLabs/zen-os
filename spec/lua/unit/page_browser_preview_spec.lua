describe("full-size page-browser preview", function()
    local Preview, saved_modules, buffers, rendered, document, ui, target
    local module_names = {
        "ffi/blitbuffer", "ui/geometry", "device", "ui/size", "ui/widget/widget",
        "modules/reader/page_browser_preview",
        "modules/reader/references",
    }

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(module_names) do saved_modules[name] = package.loaded[name] or false end
        local Widget = {}
        function Widget:extend(values) return setmetatable(values or {}, { __index = self }) end
        function Widget:new(values)
            local instance = self:extend(values)
            instance:init()
            return instance
        end
        buffers, rendered = {}, {}
        ZenSpec.replace("modules/reader/references", { paintPin = function() end })
        ZenSpec.replace("ui/widget/widget", Widget)
        ZenSpec.replace("ui/geometry", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/size", { border = { thick = 3 } })
        ZenSpec.replace("device", { screen = { bb = { getType = function() return "screen type" end } } })
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_WHITE = "white", COLOR_BLACK = "black",
            new = function(width, height, kind)
                local bb = { width = width, height = height, kind = kind, frees = 0 }
                function bb:fill(color) self.background = color end
                function bb:free() self.frees = self.frees + 1 end
                function bb:viewport(x, y, w, h)
                    return { copy = function()
                        local cropped = require("ffi/blitbuffer").new(w, h, kind)
                        cropped.source = { x, y, w, h }
                        return cropped
                    end }
                end
                buffers[#buffers + 1] = bb
                return bb
            end,
        })
        document = {
            position = 120,
            getCurrentPos = function(self) return self.position end,
            gotoPos = function(self, pos) self.position = pos end,
        }
        ui = {
            rolling = {}, document = document,
            view = {
                document = document,
                state = { page = 2, gamma = 1.7, zoom = 1.25, rotation = 90,
                    offset = { x = 11, y = 23 } },
                outer_page_color = "reader margin",
                visible_area = { x = 4, y = 8, w = 540, h = 720 },
                highlight_visible = true,
                highlight = { page_boxes = { original = true } },
                drawPageSurround = function(self, bb, x, y)
                    rendered[#rendered + 1] = { method = "surround", view = self, bb = bb, x = x, y = y }
                end,
                drawPageView = function(self, bb, x, y)
                    self.document.position = self.state.page * 100
                    rendered[#rendered + 1] = { method = "rolling", view = self, bb = bb,
                        x = x + self.state.offset.x, y = y + self.state.offset.y }
                end,
                drawSinglePage = function(self, bb, x, y)
                    rendered[#rendered + 1] = { method = "single", view = self, bb = bb,
                        x = x + self.state.offset.x, y = y + self.state.offset.y }
                end,
                drawSavedHighlight = function(self)
                    self.highlight.page_boxes.preview = true
                end,
            },
        }
        target = { blits = {} }
        function target:blitFrom(...) self.blits[#self.blits + 1] = { ... } end
        ZenSpec.unload("modules/reader/page_browser_preview")
        Preview = require("modules/reader/page_browser_preview")
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do package.loaded[name] = saved_modules[name] or nil end
    end)

    it("renders the reader's unscaled page and caches it without changing live state", function()
        local preview = Preview:new{ ui = ui, page = 7, width = 600, height = 800 }
        preview:paintTo(target, 20, 30)
        assert.are.equal(1, #buffers)
        assert.are.same({ 600, 800, "screen type", "reader margin" },
            { buffers[1].width, buffers[1].height, buffers[1].kind, buffers[1].background })
        assert.are.equal("surround", rendered[1].method)
        assert.are.equal("rolling", rendered[2].method)
        local view = rendered[2].view
        assert.are.equal(7, view.state.page)
        assert.are.equal(1.7, view.state.gamma)
        assert.are.equal(1.25, view.state.zoom)
        assert.are.equal(90, view.state.rotation)
        assert.are.same({ 11, 23 }, { rendered[2].x, rendered[2].y })
        assert.are.equal(ui.view.visible_area, view.visible_area)
        assert.are.equal(2, ui.view.state.page)
        assert.are.equal(120, document.position)
        assert.are.same({ original = true }, ui.view.highlight.page_boxes)
        assert.are.same({ buffers[1], 20, 30, 0, 0, 600, 800 }, target.blits[1])
        preview:paintTo(target, 5, 10)
        assert.are.equal(1, #buffers)
        assert.are.equal(2, #rendered)
        assert.are.same({ buffers[1], 5, 10, 0, 0, 600, 800 }, target.blits[2])
        assert.are.same({ x = 5, y = 10, w = 600, h = 800 }, preview.dimen)
    end)

    it("restores the EPUB position and frees an incomplete render when drawing fails", function()
        document.position = 0
        ui.view.drawPageView = function(self)
            self.document.position = 700
            error("page render failed", 0)
        end
        local preview = Preview:new{ ui = ui, page = 7, width = 600, height = 800 }
        assert.has_error(function() preview:paintTo(target, 0, 0) end, "page render failed")
        assert.are.equal(0, document.position)
        assert.are.equal(1, buffers[1].frees)
        assert.is_nil(preview.bb)
        assert.are.equal(0, #target.blits)
    end)

    it("uses the thumbnail pixel format instead of the framebuffer format when requested", function()
        local preview = Preview:new{ ui = ui, page = 7, width = 600, height = 800,
            bb_type = "thumbnail type" }
        preview:render()
        assert.are.equal("thumbnail type", preview.bb.kind)
        preview:free()
        assert.are.equal(1, buffers[1].frees)
    end)

    it("frees stale pages and rerenders with updated reader settings after invalidation", function()
        local preview = Preview:new{ ui = ui, page = 7, width = 600, height = 800 }
        preview:paintTo(target, 0, 0)
        preview:setPage(7)
        assert.are.equal(0, buffers[1].frees)
        preview:setPage(8)
        assert.are.equal(1, buffers[1].frees)
        assert.is_nil(preview.bb)
        preview:paintTo(target, 0, 0)
        assert.are.equal(8, rendered[4].view.state.page)
        ui.view.state.gamma = 2.5
        preview:invalidate()
        assert.are.equal(1, buffers[2].frees)
        preview:paintTo(target, 0, 0)
        assert.are.equal(2.5, rendered[6].view.state.gamma)
        preview:free()
        preview:free()
        assert.are.equal(1, buffers[3].frees)
        assert.is_nil(preview.bb)
    end)

    it("keeps the full-page settings preview free of pin overlays", function()
        local calls = {}
        package.loaded["modules/reader/references"].paintPin = function(...)
            calls[#calls + 1] = { ... }
        end
        local preview = Preview:new{ ui = ui, page = 7, width = 600, height = 800, top = 100 }
        preview:paintTo(target, 20, 30)
        preview:paintTo(target, 20, 30)
        assert.equals(1, #buffers)
        assert.equals(0, #calls)
    end)

    it("fits an entire pinned PDF page without borrowing the reader's crop or zoom", function()
        ui.rolling, ui.paging = nil, {}
        ui.view.highlight_visible, ui.view.page_scroll = false, true
        for _i, size in ipairs({ { w = 1200, h = 400 }, { w = 300, h = 1600 } }) do
            document.getPageDimensions = function(_self, page, zoom, rotation)
                assert.equals(9, page); assert.equals(1, zoom); assert.equals(90, rotation)
                return size
            end
            local preview = Preview:new{ ui = ui, page = 9, width = 600, height = 800, fit_page = true }
            preview:paintTo(target, 0, 0)
            local view = rendered[#rendered].view
            local width, height = size.w / 2, size.h / 2
            assert.equals(0.5, view.state.zoom)
            assert.same({ x = 0, y = 0 }, view.state.offset)
            assert.same({ x = 0, y = 0, w = width, h = height }, view.visible_area)
            assert.same({ width, height }, { buffers[#buffers].width, buffers[#buffers].height })
            assert.is_false(view.page_scroll)
        end
        assert.equals(1.25, ui.view.state.zoom)
        assert.same({ x = 11, y = 23 }, ui.view.state.offset)
        assert.is_true(ui.view.page_scroll)
    end)

    it("draws PDF pages with current contrast and offsets without navigating the document", function()
        ui.rolling = nil
        ui.view.highlight_visible = false
        document.getCurrentPos = function() error("PDF position was read") end
        document.gotoPos = function() error("PDF position was changed") end
        local preview = Preview:new{ ui = ui, page = 9, width = 600, height = 800 }
        preview:paintTo(target, 0, 0)
        assert.are.equal(2, #rendered)
        assert.are.equal("single", rendered[2].method)
        assert.are.equal(9, rendered[2].view.state.page)
        assert.are.equal(1.7, rendered[2].view.state.gamma)
        assert.are.same({ 11, 23 }, { rendered[2].x, rendered[2].y })
        assert.are.equal(2, ui.view.state.page)
        assert.are.equal(120, document.position)
    end)

    it("fits all EPUB image and text bounds while restoring the reading position", function()
        ui.view.highlight_visible = false
        document._drawn_images_count = 1
        document.getTextFromXPointers = function() return "Caption" end
        document.getPageXPointer = function(_self, page) return "xp:" .. page end
        document._document = { getWordBoxesFromPositions = function(_self, first, last, segments, images)
            assert.equals(900, document.position)
            assert.equals("xp:9", first); assert.equals("xp:10", last)
            assert.is_true(segments); assert.is_true(images)
            return { { x0 = 50, y0 = 100, x1 = 550, y1 = 700 },
                { x0 = 20, y0 = 80, x1 = 100, y1 = 110 } }
        end }
        local preview = Preview:new{ ui = ui, page = 9, width = 600, height = 800, fit_page = true }
        preview:render()
        assert.same({ 20, 80, 530, 620 }, preview.bb.source)
        assert.equals(1, buffers[1].frees)
        assert.equals(120, document.position)
        document.getPageXPointer = function(_self, page) return page == 9 and "xp:9" or "" end
        document._document.getTextFromPositions = function(_self, x0, y0, x1, y1, draw, segmented, images)
            assert.same({ 0, 0, 599, 799 }, { x0, y0, x1, y1 })
            assert.is_false(draw); assert.is_false(segmented); assert.is_true(images)
            return { pos0 = "xp:9", pos1 = "xp:10" }
        end
        preview:free()
        preview:render()
        assert.same({ 20, 80, 530, 620 }, preview.bb.source)
        assert.equals(120, document.position)
    end)

    it("uses a lone EPUB image at its original resolution and releases it with the preview", function()
        ui.view.highlight_visible = false
        document._drawn_images_count = 1
        document.getPageXPointer = function(_self, page) return "xp:" .. page end
        document.getTextFromXPointers = function(_self, first, last, draw)
            assert.equals("xp:9", first); assert.equals("xp:10", last); assert.is_false(draw)
            return "\n "
        end
        document._document = { getWordBoxesFromPositions = function()
            return {{ x0 = 50, y0 = 100, x1 = 550, y1 = 700 }}
        end }
        local image
        document.getImageFromPosition = function(_self, pos)
            assert.same({ x = 300, y = 400 }, pos)
            image = require("ffi/blitbuffer").new(1000, 1200, "screen type")
            return image
        end
        local preview = Preview:new{ ui = ui, page = 9, width = 600, height = 800, fit_page = true }
        preview:render()
        assert.equals(image, preview.bb)
        assert.is_true(preview.original_image)
        assert.equals(1, buffers[1].frees)
        assert.equals(120, document.position)
        preview:free()
        assert.equals(1, image.frees)
        assert.is_nil(preview.original_image)
    end)

    it("loads the held image without its heading or other images on the pinned page", function()
        ui.view.highlight_visible = false
        document._drawn_images_count = 2
        document.getPageXPointer = function(_self, page) return "xp:" .. page end
        document.getTextFromXPointers = function() return "Map" end
        document._document = { getWordBoxesFromPositions = function(_self, first, last, segments, images)
            assert.equals("xp:9/image[2]", first); assert.equals(first, last)
            assert.is_true(segments); assert.is_true(images)
            return {{ x0 = 50, y0 = 200, x1 = 550, y1 = 700 }}
        end }
        local image = require("ffi/blitbuffer").new(1000, 1000, "screen type")
        document.getImageFromPosition = function(_self, pos)
            assert.same({ x = 300, y = 450 }, pos)
            return image
        end
        local preview = Preview:new{ ui = ui, page = 9, width = 600, height = 800,
            fit_page = true, image_xpointer = "xp:9/image[2]" }
        preview:render()
        assert.equals(image, preview.bb)
        assert.is_true(preview.original_image)
        assert.equals(120, document.position)
        preview:free()
        assert.equals(1, image.frees)
    end)
end)
