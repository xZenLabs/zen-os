describe("file manager status bar visibility", function()
    local FileManager
    local UIManager
    local NetworkMgr
    local original_modules
    local original_plugin
    local original_status_builder
    local created_text_widgets

    local function replace(name, module)
        original_modules[name] = { value = package.loaded[name] }
        ZenSpec.replace(name, module)
    end

    local function replace_upvalue(fn, target, replacement)
        for index = 1, 40 do
            local name = debug.getupvalue(fn, index)
            if not name then break end
            if name == target then
                debug.setupvalue(fn, index, replacement)
                return true
            end
        end
        return false
    end

    local function get_upvalue(fn, target)
        for index = 1, 40 do
            local name, value = debug.getupvalue(fn, index)
            if not name then break end
            if name == target then return value end
        end
    end

    before_each(function()
        FileManager = {}
        UIManager = { _window_stack = {} }
        original_modules = {}
        original_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        original_status_builder = rawget(_G, "__ZENOS_BUILD_STATUS_ROW")
        created_text_widgets = {}

        replace("ui/bidi", {})
        replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
                scaleBySize = function(_, value) return value end,
            },
        })
        replace("apps/filemanager/filemanager", FileManager)
        replace("ui/font", {
            sizemap = { xx_smallinfofont = 14 },
            getFace = function(_, _name, size) return { size = size } end,
        })
        replace("ui/geometry", {})
        replace("ui/widget/horizontalgroup", {
            new = function(_, values) return values or {} end,
        })
        replace("ui/widget/horizontalspan", {})
        replace("ui/widget/container/leftcontainer", {})
        NetworkMgr = {
            wifi_on = true,
            connected = true,
            isWifiOn = function(self) return self.wifi_on end,
            isConnected = function(self) return self.connected end,
        }
        replace("ui/network/manager", NetworkMgr)
        replace("ui/widget/overlapgroup", {})
        replace("ui/widget/container/rightcontainer", {})
        local TextWidget = {}
        function TextWidget:new(values)
            created_text_widgets[#created_text_widgets + 1] = values
            return values
        end
        function TextWidget:extend()
            return setmetatable({}, { __index = self })
        end
        replace("ui/widget/textwidget", TextWidget)
        replace("ui/widget/imagewidget", {
            new = function(_, values) return values end,
        })
        replace("ui/uimanager", UIManager)
        replace("ffi/blitbuffer", {
            ColorRGB32 = function() return 0 end,
            COLOR_DARK_GRAY = 0,
        })
        replace("ui/widget/linewidget", {})
        replace("ui/size", {})
        replace("ui/widget/verticalgroup", {})
        replace("common/clock_timer", {})
        replace("modules/filebrowser/patches/library_font", {
            getFace = function(size) return { size = size } end,
        })
        replace("common/date_format", {
            format = function() return "August 8th" end,
        })
        replace("common/utils", { deepcopy = function(value) return value end })
        replace("common/paths", {})
        replace("common/shared_state", {
            register = function() end,
            registerLoader = function() end,
        })
        replace("common/status_bar_registry", {})
        replace("common/ui/background", {})
        replace("common/bluetooth", {})
        replace("common/inline_icon_map", {})
        replace("ui/rendertext", {})
        replace("gettext", setmetatable({
            pgettext = function(_, text) return text end,
        }, {
            __call = function(_, text) return text end,
        }))
        replace("common/zen_logger", {
            new = function()
                return { dbg = function() end, info = function() end, warn = function() end }
            end,
        })
        replace("ui/widget/menu", {})
        replace("ui/widget/touchmenu", {})
        original_modules["common/ui/color_text_widget"] = {
            value = package.loaded["common/ui/color_text_widget"],
        }
        ZenSpec.unload("common/ui/color_text_widget")
        original_modules["modules/filebrowser/patches/status_bar"] = {
            value = package.loaded["modules/filebrowser/patches/status_bar"],
        }
        ZenSpec.unload("modules/filebrowser/patches/status_bar")
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { status_bar = true },
                status_bar = {},
            },
        }
    end)

    after_each(function()
        for name, saved in pairs(original_modules) do
            package.loaded[name] = saved.value
        end
        _G.__ZEN_UI_PLUGIN = original_plugin
        _G.__ZENOS_BUILD_STATUS_ROW = original_status_builder
    end)

    it("renders the configured date item", function()
        local status_api
        local SharedState = require("common/shared_state")
        SharedState.register = function(_plugin, api) status_api = api end
        require("modules/filebrowser/patches/status_bar")()

        local build_group = get_upvalue(status_api.buildStatusRow, "_buildGroup")
        local group = build_group({ "date" }, { size = 14 }, false)

        assert.are.equal(1, #group)
        assert.are.equal("August 8th", group[1].text)
        assert.are.equal("August 8th", created_text_widgets[1].text)
    end)

    it("keeps the patch active with empty status items", function()
        _G.__ZEN_UI_PLUGIN.config.status_bar = {
            left_order = {}, center_order = {}, right_order = {},
        }

        require("modules/filebrowser/patches/status_bar")()

        assert.is_true(_G.__ZEN_UI_PLUGIN.config.features.status_bar)
        assert.are.same({}, _G.__ZEN_UI_PLUGIN.config.status_bar.left_order)
        assert.are.same({}, _G.__ZEN_UI_PLUGIN.config.status_bar.center_order)
        assert.are.same({}, _G.__ZEN_UI_PLUGIN.config.status_bar.right_order)
        assert.is_function(FileManager._updateStatusBar)
        assert.is_function(_G.__ZENOS_BUILD_STATUS_ROW)
    end)

    it("only hides Wi-Fi when it is fully off", function()
        local status_api
        local SharedState = require("common/shared_state")
        SharedState.register = function(_plugin, api) status_api = api end
        _G.__ZEN_UI_PLUGIN.config.status_bar.wifi_hide_when_off = true
        require("modules/filebrowser/patches/status_bar")()

        local build_group = get_upvalue(status_api.buildStatusRow, "_buildGroup")

        NetworkMgr.wifi_on = false
        assert.is_nil(build_group({ "wifi" }, { size = 14 }, false))

        _G.__ZEN_UI_PLUGIN.config.status_bar.wifi_hide_when_off = false
        local off = build_group({ "wifi" }, { size = 14 }, false)
        assert.are.equal("\u{ECA9}", off[1].text)

        _G.__ZEN_UI_PLUGIN.config.status_bar.wifi_hide_when_off = true
        NetworkMgr.wifi_on = true
        NetworkMgr.connected = false
        local connecting = build_group({ "wifi" }, { size = 14 }, false)
        assert.are.equal("\u{ECA8}", connecting[1].text)
        assert.is_not_nil(connecting[1].fgcolor)

        NetworkMgr.connected = true
        local connected = build_group({ "wifi" }, { size = 14 }, false)
        assert.are.equal("\u{ECA8}", connected[1].text)
        assert.is_nil(connected[1].fgcolor)
    end)

    it("does not repaint behind a Home page that hides its status bar", function()
        require("modules/filebrowser/patches/status_bar")()
        UIManager._window_stack = {
            { widget = { _zen_home_show_status_bar = false } },
            { widget = { toast = true, invisible = true } },
        }

        local existing_row = {}
        local title_group = { {}, existing_row }
        FileManager.title_bar = { title_group = title_group }
        FileManager:_updateStatusBar()

        assert.are.equal(existing_row, title_group[2])
    end)

    it("builds hidden status rows without repainting them over the top widget", function()
        require("modules/filebrowser/patches/status_bar")()

        local repaint_count = 0
        local next_row = { getSize = function() return { h = 1 } end }
        assert.is_true(replace_upvalue(FileManager._updateStatusBar,
            "createStatusRow", function() return next_row end))
        assert.is_true(replace_upvalue(FileManager._updateStatusBar,
            "repaintTitleBar", function() repaint_count = repaint_count + 1 end))

        local function item()
            return { getSize = function() return { h = 1 } end }
        end
        local title_group = { item(), item(), item(), item() }
        function title_group:resetLayout() end
        FileManager.title_bar = {
            title_group = title_group,
            titlebar_height = 2,
            width = 600,
            button_padding = 0,
        }
        FileManager.instance = FileManager
        UIManager._window_stack = { { widget = FileManager } }

        FileManager.invisible = true
        FileManager:_updateStatusBar()
        assert.are.equal(next_row, title_group[2])
        assert.are.equal(0, repaint_count)

        FileManager.invisible = nil
        FileManager:_updateStatusBar()
        assert.are.equal(1, repaint_count)

        UIManager._window_stack[#UIManager._window_stack + 1] = { widget = {} }
        FileManager:_updateStatusBar()
        assert.are.equal(1, repaint_count)
    end)

    it("builds the setup row without an extra titlebar repaint", function()
        local next_tick
        local repaint_count = 0
        _G.__ZEN_UI_PLUGIN.config.status_bar.hide_browser_bar = false
        FileManager.setupLayout = function() end
        FileManager.updateTitleBarPath = function(self, path) self.updated_path = path end
        UIManager.nextTick = function(_self, callback) next_tick = callback end
        require("common/clock_timer").subscribe = function() end
        require("modules/filebrowser/patches/status_bar")()

        local next_row = { getSize = function() return { h = 1 } end }
        assert.is_true(replace_upvalue(FileManager._updateStatusBar,
            "createStatusRow", function() return next_row end))
        assert.is_true(replace_upvalue(FileManager._updateStatusBar,
            "repaintTitleBar", function() repaint_count = repaint_count + 1 end))

        local function item()
            return { getSize = function() return { h = 1 } end }
        end
        local title_group = { item(), item(), item(), item() }
        function title_group:resetLayout() end
        FileManager.title_bar = {
            title_group = title_group,
            titlebar_height = 4,
            width = 600,
            button_padding = 0,
        }
        FileManager.file_chooser = { path = "/library" }
        FileManager.instance = FileManager
        UIManager._window_stack = { { widget = FileManager } }

        FileManager:setupLayout()
        assert.are.equal(next_row, title_group[2])
        assert.are.equal(0, repaint_count)

        next_tick()
        assert.are.equal("/library", FileManager.updated_path)
        assert.are.equal(0, repaint_count)

        FileManager:_updateStatusBar()
        assert.are.equal(1, repaint_count)
    end)

    it("routes the real-folder chevron through onFolderUp", function()
        local status_api
        local back_callback
        ZenSpec.replace("common/paths", {
            getHomeDir = function() return "/library" end,
            normPath = function(path) return path end,
            isHomeLocked = function() return true end,
        })
        ZenSpec.replace("common/shared_state", {
            register = function(_plugin, api) status_api = api end,
            registerLoader = function() end,
        })
        ZenSpec.replace("ui/widget/button", {
            new = function(_, options)
                back_callback = options.callback
                error("back callback captured")
            end,
        })
        UIManager.scheduleIn = function(_, _, callback) callback() end

        require("modules/filebrowser/patches/status_bar")()

        local folder_up_calls = 0
        local direct_change_calls = 0
        local file_manager = {
            file_chooser = {
                item_table = {},
                onFolderUp = function() folder_up_calls = folder_up_calls + 1 end,
                changeToPath = function() direct_change_calls = direct_change_calls + 1 end,
            },
        }
        local ok = pcall(status_api.createStatusRow, "/library/folder", file_manager)
        assert.is_false(ok)
        assert.is_function(back_callback)
        back_callback()

        assert.are.equal(1, folder_up_calls)
        assert.are.equal(0, direct_change_calls)
    end)

    it("clears restored item focus when the chevron navigates with underlines hidden", function()
        local status_api
        local back_callback
        _G.__ZEN_UI_PLUGIN.config.features.browser_hide_underline = true
        ZenSpec.replace("common/paths", {
            getHomeDir = function() return "/library" end,
            normPath = function(path) return path end,
            isHomeLocked = function() return true end,
        })
        ZenSpec.replace("common/shared_state", {
            register = function(_plugin, api) status_api = api end,
            registerLoader = function() end,
        })
        ZenSpec.replace("ui/widget/button", {
            new = function(_, options)
                back_callback = options.callback
                error("back callback captured")
            end,
        })
        UIManager.scheduleIn = function(_, _, callback) callback() end

        require("modules/filebrowser/patches/status_bar")()

        local unfocus_calls = 0
        local focused_item = {
            onUnfocus = function() unfocus_calls = unfocus_calls + 1 end,
        }
        local file_chooser = {
            item_table = {},
            itemnumber = 4,
            prev_itemnumber = 4,
            selected = { x = 1, y = 1 },
            layout = { { focused_item } },
            onFolderUp = function() end,
        }
        local ok = pcall(status_api.createStatusRow, "/library/folder", {
            file_chooser = file_chooser,
        })
        assert.is_false(ok)
        back_callback()

        assert.are.equal(1, unfocus_calls)
        assert.is_nil(file_chooser.itemnumber)
        assert.is_nil(file_chooser.prev_itemnumber)
    end)

    it("hides back at the Folder tab root and shows it in descendants", function()
        local status_api
        local back_buttons = 0
        _G.__ZEN_UI_PLUGIN.config.features.navbar = true
        _G.__ZEN_UI_PLUGIN.config.navbar = {
            show_tabs = { folder = true },
            folder_path = "/library/Fiction/",
        }
        _G.__ZEN_UI_PLUGIN.config.status_bar = {
            left_order = {}, center_order = {}, right_order = {},
        }
        ZenSpec.replace("common/paths", {
            getHomeDir = function() return "/library" end,
            normPath = function(path) return path end,
            isHomeLocked = function() return false end,
        })
        ZenSpec.replace("common/shared_state", {
            register = function(_plugin, api) status_api = api end,
            registerLoader = function() end,
        })
        ZenSpec.replace("ui/widget/button", {
            new = function()
                back_buttons = back_buttons + 1
                return { label_widget = {}, frame = {} }
            end,
        })

        require("modules/filebrowser/patches/status_bar")()
        assert.is_true(replace_upvalue(status_api.createStatusRow,
            "_buildGroup", function() error("row build stopped") end))

        local file_manager = { file_chooser = { item_table = {} } }
        assert.is_false(pcall(status_api.createStatusRow,
            "/library/Fiction", file_manager))
        assert.are.equal(0, back_buttons)

        assert.is_false(pcall(status_api.createStatusRow,
            "/library/Fiction/Series", file_manager))
        assert.are.equal(1, back_buttons)
    end)
end)
