describe("emulator test driver startup", function()
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
end)
