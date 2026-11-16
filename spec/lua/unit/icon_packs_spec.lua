require("ffi/loadlib")
local Archiver = require("ffi/archiver")
local lfs = require("libs/libkoreader-lfs")

describe("ZenOS icon packs", function()
    local IconPacks = require("common/icon_packs")
    local icons_root
    local packs_root

    local function remove_tree(path)
        local attr = lfs.symlinkattributes and lfs.symlinkattributes(path) or lfs.attributes(path)
        if not attr then return end
        if attr.mode ~= "directory" then
            os.remove(path)
            return
        end
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then remove_tree(path .. "/" .. entry) end
        end
        lfs.rmdir(path)
    end

    local function make_dir(path)
        if lfs.attributes(path, "mode") ~= "directory" then assert(lfs.mkdir(path)) end
    end

    local function write_file(path, content)
        local file = assert(io.open(path, "wb"))
        file:write(content)
        file:close()
    end

    local function read_file(path)
        local file = assert(io.open(path, "rb"))
        local content = file:read("*a")
        file:close()
        return content
    end

    local function pack_json(id, name)
        return string.format(
            [[{"schema_version":1,"id":"%s","name":"%s","version":"1.0.0"}]],
            id, name or id)
    end

    local function make_pack(id, icon_name, content)
        make_dir(packs_root)
        local path = packs_root .. "/" .. id
        make_dir(path)
        write_file(path .. "/pack.json", pack_json(id))
        write_file(path .. "/" .. (icon_name or "home") .. ".svg", content or "pack")
        return path
    end

    local function make_zip(filename, id, files)
        make_dir(packs_root)
        local path = packs_root .. "/" .. filename
        local source_root = icons_root .. "/zip-source"
        make_dir(source_root)
        local pack_root = source_root .. "/" .. id
        make_dir(pack_root)
        write_file(pack_root .. "/pack.json", pack_json(id))
        for name, content in pairs(files or { ["home.svg"] = "zip" }) do
            write_file(pack_root .. "/" .. name, content)
        end
        local command = string.format("cd %q && zip -q -r %q %q", source_root, path, id)
        assert.are.equal(0, os.execute(command))
        remove_tree(source_root)
        return path
    end

    local function fake_archiver(entries, contents, extraction_error)
        local reader_count = 0
        return {
            Reader = {
                new = function()
                    reader_count = reader_count + 1
                    local reader_number = reader_count
                    return {
                        open = function() return true end,
                        iterate = function()
                            local index = 0
                            return function()
                                index = index + 1
                                return entries[index]
                            end
                        end,
                        extractToMemory = function(_self, key)
                            return contents and contents[key]
                        end,
                        extractToPath = function(self)
                            if reader_number > 1 and extraction_error then
                                self.err = extraction_error
                                return false
                            end
                            return true
                        end,
                        close = function() end,
                    }
                end,
            },
        }
    end

    local function inspect_fake(entries, contents)
        make_dir(packs_root)
        local path = packs_root .. "/fake.zip"
        write_file(path, "zip")
        IconPacks._setArchiverForTests(fake_archiver(entries, contents))
        return IconPacks._inspectZip(path)
    end

    before_each(function()
        icons_root = os.tmpname()
        os.remove(icons_root)
        assert(lfs.mkdir(icons_root))
        packs_root = icons_root .. "/zen"
        IconPacks._resetForTests()
        IconPacks._setIconsRootForTests(icons_root)
    end)

    after_each(function()
        remove_tree(icons_root)
        IconPacks._resetForTests()
    end)

    it("creates and scans only the icons/zen folder", function()
        local outside = icons_root .. "/outside"
        make_dir(outside)
        write_file(outside .. "/pack.json", pack_json("outside"))
        write_file(outside .. "/home.svg", "outside")
        local inside = make_pack("inside")
        write_file(inside .. "/pack.json", pack_json("inside"):sub(1, -2) .. ',"color":true}')

        local scan = IconPacks.scan()

        assert.are.equal(packs_root, IconPacks.getPacksRoot())
        assert.are.equal(1, #scan.packs)
        assert.are.equal("inside", scan.packs[1].id)
        assert.is_true(scan.packs[1].color)
    end)

    it("validates the optional color flag in archive metadata", function()
        for _i, entry in ipairs({
            { field = "" },
            { field = ',"color":true', value = true },
            { field = ',"color":false', value = false },
            { field = ',"color":"true"', invalid = true },
            { field = ',"color":1', invalid = true },
        }) do
            local content = pack_json("flags"):sub(1, -2) .. entry.field .. "}"
            local metadata, err = inspect_fake({
                { path = "flags/pack.json", mode = "file", size = #content },
            }, { ["flags/pack.json"] = content })
            if entry.invalid then
                assert.is_nil(metadata)
                assert.matches("pack color must be a boolean", err, 1, true)
            else
                assert.is_nil(err)
                assert.are.equal(entry.value, metadata.color)
            end
        end
    end)

    it("returns absolute pack icon paths when KOReader uses a relative data directory", function()
        local DataStorage = require("datastorage")
        local data_dir = stub(DataStorage, "getDataDir", function() return "." end)
        local full_data_dir = stub(DataStorage, "getFullDataDir", function() return icons_root end)
        finally(function()
            data_dir:revert()
            full_data_dir:revert()
        end)
        make_dir(icons_root .. "/icons")
        packs_root = icons_root .. "/icons/zen"
        local selected = make_pack("selected", "home")
        IconPacks._setIconsRootForTests(nil)

        assert.are.equal(packs_root, IconPacks.getPacksRoot())
        IconPacks.initialize({
            features = { custom_icons_enabled = true },
            custom_icons = { active_pack = "selected" },
        })
        assert.are.equal(selected .. "/home.svg", IconPacks.resolve("home", ZenSpec.root .. "/icons/"))
    end)

    it("installs a valid ZIP and deletes it only after success", function()
        local zip_path = make_zip("sample.zip", "sample", { ["home.svg"] = "new" })

        local scan = IconPacks.scan()

        assert.are.equal(1, #scan.installed)
        assert.are.equal("sample", scan.installed[1].id)
        assert.is_nil(lfs.attributes(zip_path, "mode"))
        assert.are.equal("new", read_file(packs_root .. "/sample/home.svg"))
    end)

    it("atomically replaces an existing pack", function()
        local installed = make_pack("replace-me", "home", "old")
        local zip_path = make_zip("replacement.zip", "replace-me", { ["home.svg"] = "new" })

        local scan = IconPacks.scan()

        assert.are.equal(0, #scan.errors)
        assert.are.equal("new", read_file(installed .. "/home.svg"))
        assert.is_nil(lfs.attributes(zip_path, "mode"))
        assert.is_nil(lfs.attributes(packs_root .. "/.zen-backup-replace-me", "mode"))
    end)

    it("restores the installed pack and retains the ZIP when activation fails", function()
        local installed = make_pack("rollback", "home", "old")
        local zip_path = make_zip("rollback.zip", "rollback", { ["home.svg"] = "new" })
        IconPacks._setRenameForTests(function(source, destination)
            if source:find("/.zen%-stage%-rollback/rollback$", 1) then return nil end
            return os.rename(source, destination)
        end)

        local scan = IconPacks.scan()

        assert.are.equal(1, #scan.errors)
        assert.are.equal("old", read_file(installed .. "/home.svg"))
        assert.are.equal("file", lfs.attributes(zip_path, "mode"))
    end)

    it("rejects traversal entries without touching the installed pack", function()
        local installed = make_pack("safe", "home", "old")
        local zip_path = packs_root .. "/unsafe.zip"
        local writer = Archiver.Writer:new()
        assert(writer:open(zip_path, "zip"))
        assert(writer:addFileFromMemory("safe/pack.json", pack_json("safe")))
        assert(writer:addFileFromMemory("safe/../escape.svg", "unsafe"))
        writer:close()

        local scan = IconPacks.scan()

        assert.are.equal(1, #scan.errors)
        assert.are.equal("old", read_file(installed .. "/home.svg"))
        assert.are.equal("file", lfs.attributes(zip_path, "mode"))
        assert.is_nil(lfs.attributes(icons_root .. "/escape.svg", "mode"))
    end)

    it("rejects multiple roots, unsafe ids, malformed metadata, and links", function()
        local metadata_path = "safe/pack.json"
        local valid_metadata = { [metadata_path] = pack_json("safe") }
        local metadata_entry = { path = metadata_path, mode = "file", size = #valid_metadata[metadata_path] }

        local err = select(2, inspect_fake({
            metadata_entry,
            { path = "other/home.svg", mode = "file", size = 1 },
        }, valid_metadata))
        assert.matches("exactly one pack folder", err, 1, true)

        err = select(2, inspect_fake({
            { path = "bad id/pack.json", mode = "file", size = 2 },
        }, { ["bad id/pack.json"] = "{}" }))
        assert.matches("exactly one pack folder", err, 1, true)

        err = select(2, inspect_fake({ metadata_entry }, { [metadata_path] = "{" }))
        assert.matches("pack.json is malformed", err, 1, true)

        err = select(2, inspect_fake({
            metadata_entry,
            { path = "safe/link.svg", mode = "link", size = 0 },
        }, valid_metadata))
        assert.matches("unsafe entry", err, 1, true)

        err = select(2, inspect_fake({
            metadata_entry,
            { path = "safe/bad name.svg", mode = "file", size = 1 },
        }, valid_metadata))
        assert.matches("unsafe icon filename", err, 1, true)

        err = select(2, inspect_fake({
            metadata_entry,
            { path = "safe/PACK.JSON", mode = "file", size = 2 },
        }, valid_metadata))
        assert.matches("conflicting paths", err, 1, true)

        err = select(2, inspect_fake({
            metadata_entry,
            { path = "safe//home.svg", mode = "file", size = 1 },
        }, valid_metadata))
        assert.matches("unsafe entry", err, 1, true)
    end)

    it("enforces archive entry, count, expanded, and ZIP limits", function()
        local metadata_path = "limits/pack.json"
        local metadata = pack_json("limits")
        local base = { { path = metadata_path, mode = "file", size = #metadata } }
        local contents = { [metadata_path] = metadata }

        local entries = { base[1], { path = "limits/huge.svg", mode = "file", size = 5 * 1024 * 1024 + 1 } }
        local err = select(2, inspect_fake(entries, contents))
        assert.matches("5 MiB", err, 1, true)

        entries = { base[1] }
        for index = 1, 11 do
            entries[#entries + 1] = {
                path = "limits/icon" .. index .. ".svg",
                mode = "file",
                size = 5 * 1024 * 1024,
            }
        end
        err = select(2, inspect_fake(entries, contents))
        assert.matches("50 MiB", err, 1, true)

        entries = { base[1] }
        for index = 1, 512 do
            entries[#entries + 1] = { path = "limits/dir" .. index .. "/", mode = "directory", size = 0 }
        end
        err = select(2, inspect_fake(entries, contents))
        assert.matches("512 entries", err, 1, true)

        local oversized = packs_root .. "/oversized.zip"
        local file = assert(io.open(oversized, "wb"))
        assert(file:seek("set", 25 * 1024 * 1024))
        file:write("x")
        file:close()
        err = select(2, IconPacks._inspectZip(oversized))
        assert.matches("25 MiB", err, 1, true)
    end)

    it("retains the old pack and ZIP when extraction fails", function()
        local installed = make_pack("extract-failure", "home", "old")
        local zip_path = packs_root .. "/extract-failure.zip"
        write_file(zip_path, "zip")
        local metadata_path = "extract-failure/pack.json"
        local metadata = pack_json("extract-failure")
        local entries = {
            { path = metadata_path, mode = "file", size = #metadata },
            { path = "extract-failure/home.svg", mode = "file", size = 3 },
        }
        IconPacks._setArchiverForTests(fake_archiver(
            entries, { [metadata_path] = metadata }, "forced extraction failure"))

        local scan = IconPacks.scan()

        assert.are.equal(1, #scan.errors)
        assert.are.equal("old", read_file(installed .. "/home.svg"))
        assert.are.equal("file", lfs.attributes(zip_path, "mode"))
    end)

    it("recovers interrupted backups and removes stale staging folders", function()
        make_dir(packs_root)
        local backup = packs_root .. "/.zen-backup-recovered"
        make_dir(backup)
        write_file(backup .. "/pack.json", pack_json("recovered"))
        write_file(backup .. "/home.svg", "old")
        local stage = packs_root .. "/.zen-stage-stale"
        make_dir(stage)
        write_file(stage .. "/partial", "partial")

        local scan = IconPacks.scan()

        assert.are.equal(1, #scan.packs)
        assert.are.equal("recovered", scan.packs[1].id)
        assert.is_nil(lfs.attributes(backup, "mode"))
        assert.is_nil(lfs.attributes(stage, "mode"))
    end)

    it("uses every safe selected-pack ID, loose icons, and bundled fallbacks", function()
        local plugin_icons = ZenSpec.root .. "/icons/"
        local selected = make_pack("selected", "home", "selected")
        write_file(selected .. "/zen_ui.svg", "any safe name")
        write_file(selected .. "/more_vertical.svg", "any safe name")
        write_file(selected .. "/zen.plus.svg", "any safe name")
        write_file(selected .. "/quick_wifi.svg", "any safe name")
        write_file(selected .. "/my_custom_tab.svg", "any safe name")
        write_file(icons_root .. "/home.svg", "loose")
        write_file(icons_root .. "/library.svg", "loose but unselected")

        IconPacks.initialize({
            features = { custom_icons_enabled = true },
            custom_icons = { active_pack = "selected" },
        })
        assert.are.equal(selected .. "/home.svg", IconPacks.resolve("home", plugin_icons))
        assert.are.equal(selected .. "/zen_ui.svg", IconPacks.resolve("zen_ui", plugin_icons))
        assert.are.equal(selected .. "/more_vertical.svg",
            IconPacks.resolve("more_vertical", plugin_icons))
        assert.are.equal(selected .. "/zen.plus.svg", IconPacks.resolve("zen.plus", plugin_icons))
        assert.are.equal(selected .. "/my_custom_tab.svg",
            IconPacks.resolve("my_custom_tab", plugin_icons))
        assert.are.equal(selected .. "/quick_wifi.svg",
            IconPacks.resolve("quick_wifi", plugin_icons))
        assert.are.equal(plugin_icons .. "library.svg",
            IconPacks.resolve("library", plugin_icons))

        IconPacks.initialize({
            features = { custom_icons_enabled = true },
            custom_icons = { active_pack = "" },
        })
        assert.are.equal(icons_root .. "/home.svg", IconPacks.resolve("home", plugin_icons))

        IconPacks.initialize({
            features = { custom_icons_enabled = false },
            custom_icons = { active_pack = "selected" },
        })
        assert.are.equal(plugin_icons .. "home.svg", IconPacks.resolve("home", plugin_icons))
        assert.is_nil(IconPacks._getResolvedPathForTests("bookmark"))
        assert.are.equal(plugin_icons .. "plus.svg", IconPacks.resolve("plus", plugin_icons))
    end)

    it("defers pack validation at boot unless ZIPs or interrupted installs are pending", function()
        local selected = make_pack("selected", "home", "selected")
        write_file(selected .. "/home.png", "png loses to svg")
        make_pack("other")
        local config = { features = { custom_icons_enabled = true }, custom_icons = { active_pack = "selected" } }
        local original_dir = lfs.dir
        local listed = {}
        lfs.dir = function(path)
            listed[#listed + 1] = path
            return original_dir(path)
        end
        local ok, err = pcall(function()
            IconPacks.initialize(config)
            assert.are.same({ packs_root, selected }, listed)
            assert.are.equal(selected .. "/home.svg", IconPacks._getResolvedPathForTests("home"))
            assert.are.equal(selected, IconPacks.getActivePackDirectory())
            assert.are.equal(2, #IconPacks.getLastScan().packs)

            IconPacks._resetForTests()
            IconPacks._setIconsRootForTests(icons_root)
            make_dir(packs_root .. "/.zen-stage-other")
            IconPacks.initialize(config)
            assert.is_nil(lfs.attributes(packs_root .. "/.zen-stage-other", "mode"))
        end)
        lfs.dir = original_dir
        assert(ok, err)
    end)

    it("rejects an active pack with unsafe icon names at boot", function()
        local selected = make_pack("selected")
        write_file(selected .. "/bad name.svg", "unsafe")
        IconPacks.initialize({ features = { custom_icons_enabled = true }, custom_icons = { active_pack = "selected" } })
        assert.is_nil(IconPacks.getActivePackDirectory())
        assert.is_nil(IconPacks._getResolvedPathForTests("home"))
    end)

    it("memoizes resolve lookups until the icon map is rebuilt", function()
        local plugin_icons = icons_root .. "/plugin/"
        make_dir(plugin_icons)
        IconPacks.initialize({ features = { custom_icons_enabled = false } })
        assert.is_nil(IconPacks.resolve("late_icon", plugin_icons))
        write_file(plugin_icons .. "late_icon.svg", "late")
        assert.is_nil(IconPacks.resolve("late_icon", plugin_icons))
        IconPacks.initialize({ features = { custom_icons_enabled = false } })
        assert.are.equal(plugin_icons .. "late_icon.svg", IconPacks.resolve("late_icon", plugin_icons))
        os.remove(plugin_icons .. "late_icon.svg")
        assert.are.equal(plugin_icons .. "late_icon.svg", IconPacks.resolve("late_icon", plugin_icons))
    end)

    it("themes control icons with SVG and PNG fallbacks", function()
        local plugin_icons = ZenSpec.root .. "/icons/"
        local names = {
            "airplane", "annotations", "app_menu", "book_open", "bookmark_outline", "brightness", "calendar", "flame",
            "library_shelves", "lookup_ai", "lookup_extend", "moon_outline", "network", "quick_battery", "quick_nightmode",
            "view_carousel_outline", "warmth", "zen_ui_update",
        }
        local selected = make_pack("selected")
        for _i, name in ipairs(names) do
            write_file(selected .. "/" .. name .. ".png", "custom PNG")
            write_file(icons_root .. "/" .. name .. ".svg", "loose SVG")
        end
        local utils = require("common/utils")
        for _i, entry in ipairs({
            { enabled = true, pack = "selected", dir = selected .. "/", ext = ".png" },
            { enabled = true, pack = "", dir = icons_root .. "/", ext = ".svg" },
            { enabled = false, pack = "selected", dir = plugin_icons, ext = ".svg" },
        }) do
            IconPacks.initialize({
                features = { custom_icons_enabled = entry.enabled },
                custom_icons = { active_pack = entry.pack },
            })
            for _j, name in ipairs(names) do
                assert.are.equal(entry.dir .. name .. entry.ext, utils.resolveIcon(plugin_icons, name))
            end
        end
    end)

    it("falls back to KOReader icons when neither the pack nor Zen supplies them", function()
        local plugin_icons = ZenSpec.root .. "/icons/"
        local stock_icons = lfs.currentdir() .. "/resources/icons/"
        local utils = require("common/utils")
        IconPacks.initialize({ features = { custom_icons_enabled = false } })

        assert.are.equal(stock_icons .. "mdlight/star.empty.svg", utils.resolveIcon(plugin_icons, "star.empty"))
        assert.are.equal(stock_icons .. "mdlight/star.full.svg", utils.resolveIcon(plugin_icons, "star.full"))
        assert.are.equal(stock_icons .. "icon-not-found.svg", utils.resolveIcon(plugin_icons, "icon-not-found"))
        assert.is_nil(utils.resolveIcon(plugin_icons, "zen_missing_test_icon"))

        local selected = make_pack("selected", "star.full", "custom star")
        IconPacks.initialize({
            features = { custom_icons_enabled = true },
            custom_icons = { active_pack = "selected" },
        })
        assert.are.equal(selected .. "/star.full.svg", utils.resolveIcon(plugin_icons, "star.full"))
        assert.are.equal(stock_icons .. "mdlight/star.empty.svg", utils.resolveIcon(plugin_icons, "star.empty"))
    end)

    it("preserves custom icon colors and transparency at night when inversion is disabled", function()
        local Blitbuffer = require("ffi/blitbuffer")
        local screen = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleByDPI = function(_self, size) return size end,
            scaleBySize = function(_self, size) return size end,
        }
        ZenSpec.replace("device", { screen = screen })
        ZenSpec.replace("ui/uimanager", {})
        ZenSpec.replace("document/documentregistry", { isImageFile = function() return true end })
        ZenSpec.unload("ui/widget/iconwidget")
        ZenSpec.unload("ui/widget/imagewidget")
        ZenSpec.unload("ui/renderimage")
        _G.G_defaults = ZenSpec.memorySettings({ DGENERIC_ICON_SIZE = 2 })
        local IconWidget = require("ui/widget/iconwidget")
        local svg = [[<svg xmlns="http://www.w3.org/2000/svg" width="3" height="1">
            <rect width="1" height="1" fill="#204060"/></svg>]]
        local selected = make_pack("selected", "home", svg)
        write_file(icons_root .. "/home.svg", svg)
        local config = {
            features = { custom_icons_enabled = true },
            custom_icons = { active_pack = "selected" },
        }
        ZenSpec.replace("config/manager", { get = function() return config end })
        local source = Blitbuffer.new(3, 1, Blitbuffer.TYPE_BBRGB32)
        local color = Blitbuffer.ColorRGB32(32, 64, 96, 255)
        source:setPixel(0, 0, color)
        source:setPixel(2, 0, Blitbuffer.ColorRGB32(0, 0, 0, 0))
        local background = Blitbuffer.ColorRGB32(40, 80, 120, 255)
        local bb = Blitbuffer.new(5, 3, Blitbuffer.TYPE_BBRGB32)
        screen.bb = bb
        finally(function() source:free(); bb:free() end)

        for _i, pack_id in ipairs({ "selected", "" }) do
            config.custom_icons.active_pack = pack_id
            IconPacks.initialize({
                features = config.features, custom_icons = { active_pack = pack_id },
            })
            local custom_path = pack_id == "selected" and selected .. "/home.svg" or icons_root .. "/home.svg"
            for _j, entry in ipairs({ { icon = "home" }, { icon = ZenSpec.root .. "/icons/home.svg" },
                    { file = custom_path, alpha = false },
                    { file = ZenSpec.root .. "/icons/home.svg", fallback = true } }) do
                local loaded = IconWidget:new{
                    icon = entry.icon, file = entry.file, width = 3, height = 1,
                    alpha = entry.alpha, file_do_cache = false,
                }
                finally(function() loaded:free() end)
                loaded:getSize()
                if entry.icon then assert.are.equal(custom_path, loaded.file) end
                assert.are.equal(entry.fallback and 255 or 0,
                    loaded._bb:getPixel(2, 0):getColorRGB32().alpha)
                local icon = IconWidget:new{
                    icon = entry.icon, file = entry.file, width = 3, height = 1,
                    alpha = true, _bb = source, _offset_x = 0, _offset_y = 0,
                }
                for _k, option in ipairs({ {}, { value = false }, { value = true } }) do
                    config.custom_icons.invert_with_dark_mode = option.value
                    for _n, night in ipairs({ false, true, false }) do
                        screen.night_mode = night
                        local preserve = not entry.fallback and option.value == false
                        for _a, straight in ipairs({ true, false }) do
                            icon._is_straight_alpha = straight
                            source:setPixel(1, 0, straight and Blitbuffer.ColorRGB32(32, 64, 96, 128)
                                or Blitbuffer.ColorRGB32(16, 32, 48, 128))
                            for _b, inverse in ipairs(night and preserve and { 0, 1 } or { 0 }) do
                                bb:setInverse(inverse)
                                bb:paintRectRGB32(0, 0, 5, 3, background)
                                icon:paintTo(bb, 1, 1)
                                assert.are.equal(inverse, bb:getInverse())
                                bb:setInverse(0)
                                local function visible(x, y)
                                    local pixel = bb:getPixel(x, y):getColorRGB32()
                                    return night and inverse == 0 and pixel:invert() or pixel
                                end
                                local glyph = night and not preserve and color:invert() or color
                                local bg = night and background:invert() or background
                                assert.are.equal(tostring(glyph), tostring(visible(1, 1)))
                                assert.are.equal(tostring(bg), tostring(visible(3, 1)))
                                assert.are.equal(tostring(bg), tostring(visible(0, 0)))
                                local blend = bg:getColorRGB32()
                                blend:blend(Blitbuffer.ColorRGB32(glyph.r, glyph.g, glyph.b, 128))
                                local pixel = visible(2, 1)
                                assert.is_true(math.abs(blend.r - pixel.r) <= 1,
                                    string.format("night=%s straight=%s inverse=%d: %s vs %s",
                                        tostring(night), tostring(straight), inverse, tostring(pixel), tostring(blend)))
                                assert.is_true(math.abs(blend.g - pixel.g) <= 1)
                                assert.is_true(math.abs(blend.b - pixel.b) <= 1)
                                assert.are.equal(tostring(color), tostring(source:getPixel(0, 0)))
                            end
                        end
                    end
                end
            end
        end

        config.custom_icons.invert_with_dark_mode = false
        for _i, entry in ipairs({
            { rgb = { 0, 0, 0 }, dark = true },
            { rgb = { 48, 48, 48 }, dark = true },
            { rgb = { 64, 64, 64 }, dark = true, alpha = 2 },
            { rgb = { 20, 25, 30 }, dark = true },
            { rgb = { 65, 65, 65 } },
            { rgb = { 32, 64, 96 } },
        }) do
            local r, g, b = unpack(entry.rgb)
            local alpha = entry.alpha or 128
            local glyph_color = Blitbuffer.ColorRGB32(r, g, b, 255)
            for _j, straight in ipairs({ true, false }) do
                local image = Blitbuffer.new(3, 1, Blitbuffer.TYPE_BBRGB32)
                finally(function() image:free() end)
                image:setPixel(0, 0, glyph_color)
                image:setPixel(1, 0, straight and Blitbuffer.ColorRGB32(r, g, b, alpha)
                    or Blitbuffer.ColorRGB32(math.floor((r * alpha + 127) / 255),
                        math.floor((g * alpha + 127) / 255), math.floor((b * alpha + 127) / 255), alpha))
                image:setPixel(2, 0, Blitbuffer.ColorRGB32(255, 255, 255, 0))
                local icon = IconWidget:new{
                    file = icons_root .. "/home.svg", width = 3, height = 1,
                    _bb = image, _offset_x = 0, _offset_y = 0, _is_straight_alpha = straight,
                }
                for _k, night in ipairs({ false, true, false }) do
                    screen.night_mode = night
                    for _n, inverse in ipairs(night and { 0, 1 } or { 0 }) do
                        bb:setInverse(inverse)
                        bb:paintRectRGB32(0, 0, 5, 3, background)
                        icon:paintTo(bb, 1, 1)
                        assert.are.equal(inverse, bb:getInverse())
                        bb:setInverse(0)
                        local function visible(x, y)
                            local pixel = bb:getPixel(x, y):getColorRGB32()
                            return night and inverse == 0 and pixel:invert() or pixel
                        end
                        local glyph = night and entry.dark and glyph_color:invert() or glyph_color
                        local bg = night and background:invert() or background
                        assert.are.equal(tostring(glyph), tostring(visible(1, 1)))
                        assert.are.equal(tostring(bg), tostring(visible(3, 1)))
                        assert.are.equal(tostring(bg), tostring(visible(0, 0)))
                        local blend = bg:getColorRGB32()
                        blend:blend(Blitbuffer.ColorRGB32(glyph.r, glyph.g, glyph.b, alpha))
                        local edge = visible(2, 1)
                        assert.is_true(math.abs(blend.r - edge.r) <= 1)
                        assert.is_true(math.abs(blend.g - edge.g) <= 1)
                        assert.is_true(math.abs(blend.b - edge.b) <= 1)
                    end
                end
            end
        end
    end)

    it("excludes hidden files from every icon picker directory", function()
        local plugin_root = icons_root .. "/plugin"
        make_dir(plugin_root)
        make_dir(plugin_root .. "/icons")
        for _i, dir in ipairs({ icons_root, plugin_root .. "/icons" }) do
            write_file(dir .. "/home.svg", "icon")
            write_file(dir .. "/._home.svg", "macOS metadata")
            write_file(dir .. "/.hidden.svg", "hidden")
            write_file(dir .. "/home.bak.svg", "backup")
        end
        IconPacks.initialize({ features = { custom_icons_enabled = false } })
        local home
        for _i, item in ipairs(require("common/utils").getIconPickerList(plugin_root)) do
            assert.are_not.equal(".", item.name:sub(1, 1))
            assert.are_not.equal("home.bak", item.name)
            if item.name == "home" then home = item end
        end
        assert.are.equal(plugin_root .. "/icons/home.svg", home.file)
    end)

    it("accepts preferred suggestions only by names in picker directories", function()
        IconPacks.initialize({
            features = { custom_icons_enabled = false },
            custom_icons = { active_pack = "" },
        })
        local utils = require("common/utils")

        assert.are.equal("zenfm", utils.suggestIcon(
            ZenSpec.root, "ZenFM", "lightning", false,
            "/plugins/zenfm.koplugin/icons/zenfm.svg"))
        assert.are.equal("lightning", utils.suggestIcon(
            ZenSpec.root, "Qzxvplm", "lightning", false,
            "/plugins/zenfm.koplugin/icons/plugin_only_qzxvplm.svg"))
    end)

    it("strips current and legacy Zen action prefixes", function()
        local utils = require("common/utils")

        assert.are.equal("Open folder", utils.stripZenPrefix("ZenOS: Open folder"))
        assert.are.equal("Home", utils.stripZenPrefix("Zen UI - Home"))
        assert.are.equal("KOReader menu", utils.stripZenPrefix("KOReader menu"))
    end)

    it("keeps custom icons and the active pack disabled by default", function()
        local defaults = require("config/defaults")
        assert.is_false(defaults.features.custom_icons_enabled)
        assert.are.equal("", defaults.custom_icons.active_pack)
        assert.is_true(defaults.custom_icons.invert_with_dark_mode)
    end)

    it("accepts only safe pack ids", function()
        assert.is_true(IconPacks.isSafeId("my-pack_2.0"))
        assert.is_false(IconPacks.isSafeId("../pack"))
        assert.is_false(IconPacks.isSafeId("/pack"))
        assert.is_false(IconPacks.isSafeId("pack name"))
        assert.is_false(IconPacks.isSafeId("_zen_settings_tab"))
    end)
end)
