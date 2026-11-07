describe("emulator test driver startup", function()
    it("acknowledges shutdown before closing widgets and quitting", function()
        local calls, reply_tick, quit_tick = {}, nil, nil
        local modules = {
            ["ui/widget/container/widgetcontainer"] = {
                extend = function(_self, spec) return spec end,
            },
            ["ui/event"] = { new = function(_self, name) return name end },
            ffi = {
                cdef = function() end,
                new = function() return {} end,
                string = function() return "" end,
                C = {
                    poll = function() return 1 end,
                    accept = function() return 7 end,
                    read = function() return 1 end,
                },
            },
            rapidjson = { decode = function() return { type = "shutdown" } end },
            ["ui/uimanager"] = {
                tickAfterNext = function(_self, callback) reply_tick = callback end,
                scheduleIn = function() end,
                broadcastEvent = function(_self, event) calls[#calls + 1] = event end,
                nextTick = function(_self, callback) quit_tick = callback end,
                quit = function() calls[#calls + 1] = "quit" end,
            },
        }
        local chunk = assert(loadfile(ZenSpec.root .. "/spec/python/zen_ui_test_driver.koplugin/main.lua"))
        setfenv(chunk, setmetatable({
            require = function(name) return modules[name] or require(name) end,
        }, { __index = _G }))
        local driver = chunk()
        driver.server_fd = 3
        driver.reply = function(_self, client, payload)
            assert.are.equal(7, client)
            assert.is_true(payload.ok)
            calls[#calls + 1] = "reply"
        end

        driver:pollServer()
        assert.same({}, calls)
        reply_tick()
        assert.same({ "reply", "Close" }, calls)
        quit_tick()
        assert.same({ "reply", "Close", "quit" }, calls)
    end)

    it("reports the file manager status origin from its titlebar layout", function()
        local title_bar = {
            dimen = { y = 20 },
            title_group = {
                { getSize = function() return { h = 6 } end },
                { dimen = { y = 0 } },
            },
        }
        local FileManager = { instance = { title_bar = title_bar } }
        local modules = {
            ["ui/widget/container/widgetcontainer"] = {
                extend = function(_self, spec) return spec end,
            },
            ["ui/event"] = {},
            rapidjson = {},
            ["ui/uimanager"] = {},
            ["apps/filemanager/filemanager"] = FileManager,
        }
        local chunk = assert(loadfile(ZenSpec.root .. "/spec/python/zen_ui_test_driver.koplugin/main.lua"))
        setfenv(chunk, setmetatable({
            require = function(name) return modules[name] or require(name) end,
        }, { __index = _G }))
        local driver = chunk()
        local status_y
        for index = 1, 100 do
            local name, value = debug.getupvalue(driver.handleCommand, index)
            if not name then break end
            if name == "filemanager_status_y" then status_y = value; break end
        end
        assert.is_function(status_y)
        assert.are.equal(26, status_y())

        title_bar.title_group[2] = { dimen = { y = 100 } }
        assert.are.equal(26, status_y())
        title_bar.dimen.y = 0
        assert.are.equal(6, status_y())
        FileManager.instance = nil
        assert.are.equal(0, status_y())
    end)

    it("waits for the startup repaint before accepting commands", function()
        local scheduled, started
        local modules = {
            ["ui/widget/container/widgetcontainer"] = {
                extend = function(_self, spec) return spec end,
            },
            ["ui/event"] = {},
            rapidjson = {},
            ["ui/uimanager"] = {
                tickAfterNext = function(_self, callback) scheduled = callback end,
            },
        }
        local chunk = assert(loadfile(ZenSpec.root .. "/spec/python/zen_ui_test_driver.koplugin/main.lua"))
        setfenv(chunk, setmetatable({
            require = function(name) return modules[name] or require(name) end,
            os = {
                getenv = function(name)
                    if name == "ZEN_UI_TESTING" then return "1" end
                    if name == "ZEN_UI_TEST_SOCKET" then return "/tmp/zen-test.sock" end
                end,
            },
        }, { __index = _G }))
        local driver = chunk()
        driver.startServer = function() started = true end

        driver:init()
        assert.is_nil(started)
        assert.is_function(scheduled)
        scheduled()
        assert.is_true(started)
    end)

    it("applies and reports exclusive accent navbar styles and label visibility", function()
        local plugin = { config = { navbar = {} } }
        local reinjected = 0
        local modules = {
            ["ui/widget/container/widgetcontainer"] = {
                extend = function(_self, spec) return spec end,
            },
            ["ui/event"] = {},
            rapidjson = {},
            ["ui/uimanager"] = { setDirty = function() end },
            pluginloader = { getPluginInstance = function() return plugin end },
        }
        local chunk = assert(loadfile(ZenSpec.root .. "/spec/python/zen_ui_test_driver.koplugin/main.lua"))
        setfenv(chunk, setmetatable({
            require = function(name) return modules[name] or require(name) end,
            os = { getenv = function() end },
            _G = { __ZEN_UI_REINJECT_FM_NAVBAR = function() reinjected = reinjected + 1 end },
        }, { __index = _G }))
        local driver = chunk()
        for _i, entry in ipairs({
            { "underline_above", false, true, true, false, false },
            { "underline_below", true, true, false, false, false },
            { "filled", true, false, false, true, false },
            { "outlined", false, false, false, false, true },
        }) do
            local response = driver:handleCommand{
                type = "showcase_navbar", params = { mode = "navbar_" .. entry[1] },
            }
            assert.is_true(response.ok, response.error)
            assert.same({
                tab_order = { "books", "authors", "tags", "history", "favorites", "series", "home" },
                show_icons = true, show_labels = entry[2],
                active_tab_use_accent = true, active_tab_underline = entry[3],
                underline_above = entry[4], active_tab_filled = entry[5],
                active_tab_outlined = entry[6], filled_background_opacity = 100,
            }, response.navbar)
        end
        assert.are.equal(4, reinjected)
        assert.same({ tab_order = { "home" }, show_icons = true, show_labels = false },
            driver:handleCommand{ type = "showcase_navbar", params = { mode = "default" } }.navbar)
    end)
end)
