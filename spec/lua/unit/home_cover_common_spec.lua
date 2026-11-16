describe("home cover rendering", function()
    local allocations
    local old_plugin
    local render_request
    local release_request
    local generated_calls

    local function widget_class()
        return {
            new = function(_, values)
                values = values or {}
                values.dimen = values.dimen or {
                    x = 0, y = 0, w = values.width or 1, h = values.height or 1,
                }
                values.getSize = values.getSize or function(self) return self.dimen end
                values.paintTo = values.paintTo or function(self, _bb, x, y)
                    self.dimen.x, self.dimen.y = x, y
                end
                values.free = values.free or function() end
                return values
            end,
        }
    end

    before_each(function()
        allocations = {}
        render_request = nil
        release_request = nil
        generated_calls = 0
        old_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        _G.__ZEN_UI_PLUGIN = {
            config = { features = { browser_cover_rounded_corners = true } },
        }
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_BLACK = "black",
            COLOR_GRAY_6 = "gray6",
            COLOR_LIGHT_GRAY = "lightgray",
            new = function(width, height)
                allocations[#allocations + 1] = { width, height }
                return { blitFrom = function() end, free = function() end }
            end,
        })
        ZenSpec.replace("device", {
            screen = { scaleBySize = function(_, value) return value end },
        })
        ZenSpec.replace("ui/geometry", { new = function(_, values) return values end })
        for _i, name in ipairs({
            "ui/widget/container/centercontainer", "ui/widget/container/framecontainer",
            "ui/widget/imagewidget", "ui/widget/textboxwidget", "ui/widget/verticalgroup",
            "ui/widget/verticalspan", "ui/widget/widget",
        }) do
            ZenSpec.replace(name, widget_class())
        end
        ZenSpec.replace("ui/font", { getFace = function() return {} end })
        ZenSpec.replace("common/cover_utils", {
            BORDER_SIZE = 1,
            getRatio = function() return 2 / 3 end,
            fitDims = function(max_w, max_h, source_w, source_h)
                local scale = math.min(max_w / source_w, max_h / source_h)
                return math.floor(source_w * scale + 0.5),
                    math.floor(source_h * scale + 0.5)
            end,
            genCoverShared = function()
                generated_calls = generated_calls + 1
                return { free = function() end }, nil, nil, true, "generated"
            end,
            getEmptyPlaceholderText = function() return "Empty" end,
        })
        ZenSpec.replace("common/cover_render_cache", {
            get = function() end,
            getShared = function() end,
            renderShared = function(_, path, source, width, height)
                render_request = { path = path, width = width, height = height }
                return source, true
            end,
            releaseShared = function(_self, path, bb)
                release_request = { path = path, bb = bb }
                return true
            end,
            releaseOnFree = ZenSpec.releaseOnFree,
        })
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/cover_common")
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = old_plugin
    end)

    it("snapshots only four packed corner squares", function()
        local Cover = require("modules/filebrowser/patches/home/widgets/cover_common")
        local frame = Cover.make_cover_widget(
            { path = "/library/alpha.epub" }, 100, 150, { uniform = false })
        local target = {
            getType = function() return "bb8" end,
            blitFrom = function() end,
            paintRect = function() end,
        }

        frame:paintTo(target, 10, 20)

        assert.are.same({ { 32, 8 } }, allocations)
    end)

    it("reads the rounded-corner setting again when an existing cover repaints", function()
        local Cover = require("modules/filebrowser/patches/home/widgets/cover_common")
        local frame = Cover.make_cover_widget(
            { path = "/library/alpha.epub" }, 100, 150, { uniform = false })
        local target = {
            getType = function() return "bb8" end,
            blitFrom = function() end,
            paintRect = function() end,
        }

        _G.__ZEN_UI_PLUGIN.config.features.browser_cover_rounded_corners = false
        frame:paintTo(target, 10, 20)
        assert.are.same({}, allocations)

        _G.__ZEN_UI_PLUGIN.config.features.browser_cover_rounded_corners = true
        frame:paintTo(target, 10, 20)
        assert.are.same({ { 32, 8 } }, allocations)
    end)

    it("uses a gray border for a dimmed cover", function()
        local Cover = require("modules/filebrowser/patches/home/widgets/cover_common")
        local frame = Cover.make_cover_widget(
            { path = "/library/finished.epub" }, 100, 150, { uniform = false })
        local colors = {}
        local target = {
            paintRect = function(_self, _x, _y, _w, _h, color)
                colors[color] = true
            end,
        }

        _G.__ZEN_UI_PLUGIN.config.features.browser_cover_rounded_corners = false
        Cover.set_dimmed_border(frame, true)
        frame:paintTo(target, 10, 20)

        assert.is_true(colors.gray6)
        assert.is_nil(colors.black)
    end)

    it("keeps the corner radius fixed for smaller list covers", function()
        local Cover = require("modules/filebrowser/patches/home/widgets/cover_common")
        local target = {
            getType = function() return "bb8" end,
            blitFrom = function() end,
            paintRect = function() end,
        }
        local large = Cover.make_cover_widget(
            { path = "/library/large.epub" }, 100, 150)
        local small = Cover.make_cover_widget(
            { path = "/library/small.epub" }, 18, 28)

        large:paintTo(target, 10, 20)
        small:paintTo(target, 10, 20)

        assert.are.same({ { 32, 8 }, { 32, 8 } }, allocations)
    end)

    it("fits a non-uniform frame to the real cover aspect ratio", function()
        local Cover = require("modules/filebrowser/patches/home/widgets/cover_common")
        local frame, width, height = Cover.make_cover_widget({
            path = "/library/landscape.epub",
            cover_bb = {
                getWidth = function() return 120 end,
                getHeight = function() return 80 end,
            },
        }, 100, 150, { uniform = false })

        assert.are.equal(100, width)
        assert.are.equal(67, height)
        assert.are.equal(100, frame:getSize().w)
        assert.are.equal(67, frame:getSize().h)
        assert.are.same({
            path = "/library/landscape.epub", width = 100, height = 67,
        }, render_request)
    end)

    it("uses a cached real cover as a non-disposable image", function()
        local shared = { free = function() end }
        local releases = 0
        local RenderCache = require("common/cover_render_cache")
        RenderCache.getShared = function(_self, path, width, height)
            render_request = { path = path, width = width, height = height }
            return shared
        end
        RenderCache.releaseShared = function(_self, path, bb)
            releases = releases + 1
            release_request = { path = path, bb = bb }
            return true
        end
        local Cover = require("modules/filebrowser/patches/home/widgets/cover_common")
        local frame = Cover.make_cover_widget({
            path = "/library/cached.epub",
            cover_w = 600,
            cover_h = 900,
            has_real_cover = true,
        }, 100, 150, { uniform = false })
        local image = frame[1][1]

        assert.are.equal(shared, image.image)
        assert.is_false(image.image_disposable)
        assert.are.same({
            path = "/library/cached.epub", width = 100, height = 150,
        }, render_request)

        image:free()
        image:free()
        assert.are.same({ path = "/library/cached.epub", bb = shared }, release_request)
        assert.are.equal(1, releases)
    end)

    it("keeps a near-exact cached bitmap at its native size", function()
        local shared = {
            getWidth = function() return 100 end,
            getHeight = function() return 149 end,
            free = function() end,
        }
        local RenderCache = require("common/cover_render_cache")
        RenderCache.getShared = function() return shared end
        local Cover = require("modules/filebrowser/patches/home/widgets/cover_common")
        local frame = Cover.make_cover_widget({
            path = "/library/rounded.epub",
            cover_w = 600,
            cover_h = 900,
            has_real_cover = true,
        }, 100, 150, { uniform = false })

        assert.are.equal(100, frame[1][1].width)
        assert.are.equal(149, frame[1][1].height)
    end)

    it("reuses a compatible larger cached render without decoding the source", function()
        local compatible = { free = function() end }
        local RenderCache = require("common/cover_render_cache")
        RenderCache.get = function(_self, path, width, height)
            render_request = { path = path, width = width, height = height }
            return compatible
        end
        RenderCache.renderShared = function()
            error("compatible render should avoid source decoding")
        end
        local Cover = require("modules/filebrowser/patches/home/widgets/cover_common")
        local result = { Cover.make_cover_widget({
            path = "/library/compatible.epub",
            cover_w = 600,
            cover_h = 900,
            has_real_cover = true,
            is_cover_pending = true,
        }, 100, 150, { uniform = false }) }
        local frame, needs_hydration = result[1], result[4]
        local image = frame[1][1]

        assert.are.equal(compatible, image.image)
        assert.is_true(image.image_disposable)
        assert.is_false(needs_hydration)
        assert.are.same({
            path = "/library/compatible.epub", width = 100, height = 150,
        }, render_request)
    end)

    it("prefers an exact cached render and frees an unused supplied source", function()
        local shared = { free = function() end }
        local source_frees = 0
        local RenderCache = require("common/cover_render_cache")
        RenderCache.getShared = function() return shared end
        RenderCache.renderShared = function()
            error("exact render should avoid source scaling")
        end
        local Cover = require("modules/filebrowser/patches/home/widgets/cover_common")
        local frame = Cover.make_cover_widget({
            path = "/library/exact.epub",
            cover_w = 600,
            cover_h = 900,
            has_real_cover = true,
            cover_bb = { free = function() source_frees = source_frees + 1 end },
        }, 100, 150, { uniform = false })

        assert.are.equal(shared, frame[1][1].image)
        assert.are.equal(1, source_frees)
    end)

    it("uses one cheap generated fallback while a real cover is pending", function()
        local Cover = require("modules/filebrowser/patches/home/widgets/cover_common")
        local result = { Cover.make_cover_widget({
            path = "/library/pending.epub",
            cover_w = 600,
            cover_h = 900,
            is_cover_pending = true,
        }, 100, 150, { uniform = false }) }
        local frame, needs_hydration = result[1], result[4]
        local placeholder = frame[1][1]

        assert.is_not_nil(placeholder.image)
        assert.are.equal(100, placeholder.width)
        assert.are.equal(150, placeholder.height)
        assert.is_true(needs_hydration)
        assert.are.equal(1, generated_calls)
    end)
end)
