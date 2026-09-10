local lfs = require("libs/libkoreader-lfs")

describe("incompatible plugin and patch check", function()
    local original_modules
    local original_plugin
    local original_settings
    local original_ptutil
    local original_sui_core
    local original_vos
    local original_quickmenu
    local original_burrow_util
    local original_qui_utils
    local original_readermenuredesign_installer
    local original_custom_shortcut_manager
    local original_suntime
    local original_appearance_setting
    local UIManager
    local settings
    local logs
    local data_dir
    local patch_dir

    local patch_files = {
        "2---stretched-covers.lua",
        "2--disable-all-CB-widgets.lua",
        "2--disable-all-PT-widgets.lua",
        "2--rounded-covers.lua",
        "2--stretched-rounded-covers.lua",
        "2-navbar-vos.lua",
        "2-new-collections-star.lua",
        "2-new-progress-bar-colored.lua",
        "2-new-progress-bar.lua",
        "2-pages-badge.lua",
        "2-percent-badge.lua",
        "2-rounded-folder-covers.lua",
        "2-series-indicator.lua",
        "20-faded-finished-books.lua",
        "2-quick-settings.lua",
        "2-automatic-book-series.lua",
        "2-ui-font.lua",
        "2-custom-navbar.lua",
        "2-page-scrubber.lua",
        "2-browser-double-tap.lua",
        "2-browser-hide-underline.lua",
        "2-browser-up-folder.lua",
        "2-coverimage-eink-optimize.lua",
        "2-disable-top-menu-zones.lua",
        "2-filemanager-titlebar.lua",
        "2-menu-size.lua",
        "2-new-status-icons.lua",
        "2-screensaver-chapter.lua",
        "2-screensaver-cover.lua",
        "2-series-badge-numbered.lua",
        "2-statusbar-better-compact.lua",
        "2-statusbar-cycle-presets.lua",
    }

    local module_names = {
        "common/zen_logger",
        "userpatch",
        "datastorage",
        "ui/uimanager",
        "gettext",
        "ui/widget/confirmbox",
        "ui/widget/infomessage",
        "ui/event",
    }

    before_each(function()
        original_modules = {}
        for _i, name in ipairs(module_names) do
            original_modules[name] = package.loaded[name]
        end
        original_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        original_settings = _G.G_reader_settings
        original_ptutil = package.loaded["ptutil"]
        original_sui_core = package.loaded["sui_core"]
        original_vos = package.loaded["modules/vos"]
        original_quickmenu = package.loaded["quickmenu"]
        original_burrow_util = package.loaded["burrow_util"]
        original_qui_utils = package.loaded["qui_utils"]
        original_readermenuredesign_installer = package.loaded["readermenuredesign_installer"]
        original_custom_shortcut_manager = package.loaded["custom_shortcut_manager"]
        original_suntime = package.loaded["suntime"]
        original_appearance_setting = package.loaded["lib/setting"]
        package.loaded["ptutil"] = nil
        package.loaded["sui_core"] = nil
        package.loaded["modules/vos"] = nil
        package.loaded["quickmenu"] = nil
        package.loaded["burrow_util"] = nil
        package.loaded["qui_utils"] = nil
        package.loaded["readermenuredesign_installer"] = nil
        package.loaded["custom_shortcut_manager"] = nil
        package.loaded["suntime"] = nil
        package.loaded["lib/setting"] = nil
        _G.__ZEN_UI_PLUGIN = nil
        data_dir = os.tmpname()
        os.remove(data_dir)
        assert.is_true(lfs.mkdir(data_dir))
        patch_dir = data_dir .. "/patches"
        assert.is_true(lfs.mkdir(patch_dir))
        settings = {
            disabled = {},
            saves = 0,
            flushes = 0,
            readSetting = function(self, key)
                if key == "plugins_disabled" then return self.disabled end
                if key == "extra_plugin_paths" then return self.extra_plugin_paths end
            end,
            saveSetting = function(self, key, value)
                self.saves = self.saves + 1
                self.saved_key = key
                self.disabled = value
            end,
            flush = function(self) self.flushes = self.flushes + 1 end,
        }
        _G.G_reader_settings = settings
        logs = { dbg = {}, info = {}, warn = {} }
        ZenSpec.replace("common/zen_logger", {
            new = function()
                local logger = {}
                for _i, level in ipairs({ "dbg", "info", "warn" }) do
                    logger[level] = function(...)
                        logs[level][#logs[level] + 1] = { ... }
                    end
                end
                return logger
            end,
        })
        ZenSpec.replace("datastorage", {
            getDataDir = function() return data_dir end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/widget/confirmbox", {
            new = function(_, spec) return spec end,
        })
        ZenSpec.replace("ui/widget/infomessage", {
            new = function(_, spec) return spec end,
        })
        ZenSpec.replace("ui/event", { new = function(_, name) return { name = name } end })
        UIManager = {
            scheduled = {},
            shown = {},
            scheduleIn = function(self, delay, callback)
                self.scheduled[#self.scheduled + 1] = { delay = delay, callback = callback }
            end,
            show = function(self, widget) self.shown[#self.shown + 1] = widget end,
            broadcastEvent = function() end,
        }
        ZenSpec.replace("ui/uimanager", UIManager)
        ZenSpec.unload("modules/filebrowser/patches/incompatible_plugins_check")
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do
            package.loaded[name] = original_modules[name]
        end
        package.loaded["ptutil"] = original_ptutil
        package.loaded["sui_core"] = original_sui_core
        package.loaded["modules/vos"] = original_vos
        package.loaded["quickmenu"] = original_quickmenu
        package.loaded["burrow_util"] = original_burrow_util
        package.loaded["qui_utils"] = original_qui_utils
        package.loaded["readermenuredesign_installer"] = original_readermenuredesign_installer
        package.loaded["custom_shortcut_manager"] = original_custom_shortcut_manager
        package.loaded["suntime"] = original_suntime
        package.loaded["lib/setting"] = original_appearance_setting
        _G.__ZEN_UI_PLUGIN = original_plugin
        _G.G_reader_settings = original_settings
        for _i, filename in ipairs(patch_files) do
            os.remove(patch_dir .. "/" .. filename)
            os.remove(patch_dir .. "/" .. filename .. ".disabled")
        end
        lfs.rmdir(patch_dir)
        lfs.rmdir(data_dir)
        ZenSpec.unload("modules/filebrowser/patches/incompatible_plugins_check")
    end)

    it("disables all known incompatible user patches and requests a restart", function()
        for _i, filename in ipairs(patch_files) do
            local file = assert(io.open(patch_dir .. "/" .. filename, "w"))
            file:close()
        end
        ZenSpec.replace("userpatch", {
            execution_status = {
                ["2-quick-settings.lua"] = true,
                ["2-automatic-book-series.lua"] = false,
                ["2-ui-font.lua"] = true,
                ["2-custom-navbar.lua"] = true,
            },
        })

        assert.is_true(require("modules/filebrowser/patches/incompatible_plugins_check")())
        for _i, filename in ipairs(patch_files) do
            assert.is_nil(lfs.attributes(patch_dir .. "/" .. filename, "mode"))
            assert.are.equal("file", lfs.attributes(patch_dir .. "/" .. filename .. ".disabled", "mode"))
        end
        assert.are.equal("plugins_disabled", settings.saved_key)
        assert.are.equal(1, settings.flushes)
        assert.are.equal(1, #UIManager.scheduled)
        assert.are.equal(0, #logs.info)
        assert.are.equal(1, #logs.warn)
        assert.are.equal("Incompatible plugins or patches detected", logs.warn[1][1])

        UIManager.scheduled[1].callback()
        assert.are.equal(
            "Incompatible plugins and patches have been disabled:\n"
                .. table.concat(patch_files, "\n"),
            UIManager.shown[1].text)
    end)

    it("blocks Project: Title when it self-disables because CoverBrowser is enabled", function()
        package.loaded["ptutil"] = { loaded = true }
        ZenSpec.replace("userpatch", { execution_status = {} })

        assert.is_true(require("modules/filebrowser/patches/incompatible_plugins_check")())
        assert.are.equal(0, settings.flushes)
        assert.are.equal(1, #UIManager.scheduled)
        assert.are.equal("Incompatible plugins or patches detected", logs.warn[1][1])

        UIManager.scheduled[1].callback()
        assert.are.equal(
            "Project: Title is not compatible with ZenOS.\n\n"
                .. "Please delete the Project: Title plugin from your plugins folder and restart KOReader.",
            UIManager.shown[1].text)
    end)

    it("disables an enabled incompatible patch before execution status is recorded", function()
        local file = assert(io.open(patch_dir .. "/2-quick-settings.lua", "w"))
        file:close()
        ZenSpec.replace("userpatch", {
            execution_status = {},
            arePatchesDisabled = function() return false end,
        })

        assert.is_true(require("modules/filebrowser/patches/incompatible_plugins_check")())
        assert.is_nil(lfs.attributes(patch_dir .. "/2-quick-settings.lua", "mode"))
        assert.are.equal("file",
            lfs.attributes(patch_dir .. "/2-quick-settings.lua.disabled", "mode"))
        assert.are.equal(1, settings.flushes)
        assert.are.equal(1, #UIManager.scheduled)
    end)

    it("ignores incompatible user patches when user patches are disabled", function()
        local file = assert(io.open(patch_dir .. "/2-quick-settings.lua", "w"))
        file:close()
        ZenSpec.replace("userpatch", {
            execution_status = {},
            arePatchesDisabled = function() return true end,
        })

        assert.is_false(require("modules/filebrowser/patches/incompatible_plugins_check")())
        assert.are.equal("file", lfs.attributes(patch_dir .. "/2-quick-settings.lua", "mode"))
        assert.are.equal(0, settings.flushes)
        assert.are.same({}, UIManager.scheduled)
        assert.are.equal(1, #logs.info)
        assert.are.equal(0, #logs.warn)
        assert.are.equal("No incompatible plugins or patches detected", logs.info[1][1])
    end)

    it("disables Appearance when its settings module is loaded", function()
        local root = assert(os.getenv("ZEN_UI_ROOT"))
        package.loaded["lib/setting"] = assert(loadfile(
            root .. "/spec/lua/fixtures/appearance.koplugin/lib/setting.lua"))()
        ZenSpec.replace("userpatch", { execution_status = {} })

        assert.is_true(require("modules/filebrowser/patches/incompatible_plugins_check")())
        assert.is_true(settings.disabled.appearance)
        assert.are.equal(1, settings.flushes)

        UIManager.scheduled[1].callback()
        assert.are.equal(
            "Incompatible plugins and patches have been disabled:\nAppearance",
            UIManager.shown[1].text)
    end)

    it("records installed incompatible plugins before their main modules load", function()
        local plugins_dir = data_dir .. "/plugins"
        local simpleui_dir = plugins_dir .. "/simpleui.koplugin"
        local vos_dir = plugins_dir .. "/vos.koplugin"
        local quickmenu_dir = plugins_dir .. "/quickmenu.koplugin"
        local appearance_dir = plugins_dir .. "/appearance.koplugin"
        local burrow_dir = plugins_dir .. "/burrow.koplugin"
        local quickui_dir = plugins_dir .. "/quickui.koplugin"
        local reader_menu_dir = plugins_dir .. "/zzz-readermenuredesign.koplugin"
        local shortcuts_toolbar_dir = plugins_dir .. "/shortcutstoolbar.koplugin"
        assert.is_true(lfs.mkdir(plugins_dir))
        assert.is_true(lfs.mkdir(simpleui_dir))
        assert.is_true(lfs.mkdir(vos_dir))
        assert.is_true(lfs.mkdir(quickmenu_dir))
        assert.is_true(lfs.mkdir(appearance_dir))
        assert.is_true(lfs.mkdir(burrow_dir))
        assert.is_true(lfs.mkdir(quickui_dir))
        assert.is_true(lfs.mkdir(reader_menu_dir))
        assert.is_true(lfs.mkdir(shortcuts_toolbar_dir))
        settings.extra_plugin_paths = { plugins_dir }
        ZenSpec.replace("userpatch", { execution_status = {} })

        assert.is_true(require("modules/filebrowser/patches/incompatible_plugins_check")())
        assert.is_true(settings.disabled.simpleui)
        assert.is_true(settings.disabled.vos)
        assert.is_true(settings.disabled.quickmenu)
        assert.is_true(settings.disabled.appearance)
        assert.is_true(settings.disabled.burrow)
        assert.is_true(settings.disabled.quickui)
        assert.is_true(settings.disabled["zzz-readermenuredesign"])
        assert.is_true(settings.disabled.shortcutstoolbar)
        assert.are.equal(1, settings.flushes)

        UIManager.scheduled[1].callback()
        assert.are.equal(
            "Incompatible plugins and patches have been disabled:\n"
                .. "Simple UI\nVisual Overhaul Suite (VOS)\nQuickMenu\nAppearance\n"
                .. "Burrow\nQuickUI\nReader Menu Redesign\nShortcuts Toolbar",
            UIManager.shown[1].text)

        lfs.rmdir(simpleui_dir)
        lfs.rmdir(vos_dir)
        lfs.rmdir(quickmenu_dir)
        lfs.rmdir(appearance_dir)
        lfs.rmdir(burrow_dir)
        lfs.rmdir(quickui_dir)
        lfs.rmdir(reader_menu_dir)
        lfs.rmdir(shortcuts_toolbar_dir)
        lfs.rmdir(plugins_dir)
    end)

    it("does not restart for an installed plugin that is already disabled", function()
        local plugins_dir = data_dir .. "/plugins"
        local reader_menu_dir = plugins_dir .. "/zzz-readermenuredesign.koplugin"
        assert.is_true(lfs.mkdir(plugins_dir))
        assert.is_true(lfs.mkdir(reader_menu_dir))
        settings.extra_plugin_paths = plugins_dir
        settings.disabled["zzz-readermenuredesign"] = true
        ZenSpec.replace("userpatch", { execution_status = {} })

        assert.is_false(require("modules/filebrowser/patches/incompatible_plugins_check")())
        assert.are.equal(0, settings.flushes)
        assert.are.same({}, UIManager.scheduled)

        lfs.rmdir(reader_menu_dir)
        lfs.rmdir(plugins_dir)
    end)

    it("does not mistake another plugin's settings module for Appearance", function()
        package.loaded["lib/setting"] = { get = function() end }
        ZenSpec.replace("userpatch", { execution_status = {} })

        assert.is_false(require("modules/filebrowser/patches/incompatible_plugins_check")())
        assert.is_nil(settings.disabled.appearance)
        assert.are.equal(0, settings.flushes)
    end)

    it("disables auto warmth for light/dark frontlight values", function()
        package.loaded["suntime"] = { loaded = true }
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = {},
                brightness_schedule = { use_mode_values = true },
            },
        }
        ZenSpec.replace("userpatch", { execution_status = {} })

        assert.is_true(require("modules/filebrowser/patches/incompatible_plugins_check")())
        assert.is_true(settings.disabled.autowarmth)
        assert.are.equal(1, settings.flushes)
    end)
end)
