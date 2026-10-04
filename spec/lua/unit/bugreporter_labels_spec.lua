local JSON = require("json")
local lfs = require("lfs")

describe("bug reporter labels", function()
    local channel
    local original_modules
    local original_reader_settings
    local payloads
    local UIManager
    local upload_fails
    local version

    local module_names = {
        "android",
        "common/restart",
        "common/utils",
        "common/zen_logger",
        "datastorage",
        "dbg",
        "gettext",
        "ltn12",
        "modules/settings/zen_bugreporter",
        "modules/settings/zen_settings_utils",
        "modules/settings/zen_updater",
        "ssl.https",
        "ui/uimanager",
        "ui/widget/confirmbox",
        "ui/widget/infomessage",
    }

    before_each(function()
        original_reader_settings = _G.G_reader_settings
        original_modules = {}
        for _i, name in ipairs(module_names) do
            original_modules[name] = package.loaded[name]
        end

        channel = "stable"
        version = "1.0.0"
        payloads = {}
        upload_fails = false
        UIManager = {
            show = function(self, widget) self.widget = widget end,
            close = function(self, widget) self.closed_widget = widget end,
            tickAfterNext = function(self, callback) self.submit_callback = callback end,
        }
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("common/zen_logger", {
            new = function()
                return { dbg = function() end, warn = function() end }
            end,
            redactNetworkLog = require("common/zen_logger").redactNetworkLog,
        })
        ZenSpec.replace("ui/uimanager", UIManager)
        ZenSpec.replace("common/restart", {})
        ZenSpec.replace("common/utils", {
            truncateUtf8Bytes = function(value) return value end,
            utf8SafeSuffix = function(value, max_bytes) return value:sub(-max_bytes) end,
        })
        ZenSpec.replace("modules/settings/zen_updater", {
            get_channel = function() return channel end,
        })
        ZenSpec.replace("ui/widget/infomessage", {
            new = function(_, props) return props end,
        })
        ZenSpec.replace("ui/widget/confirmbox", {
            new = function(_, props) return props end,
        })
        ZenSpec.replace("modules/settings/zen_settings_utils", {
            get_plugin_version = function() return version end,
            get_koreader_version = function() return "2026.01" end,
            get_device_model_name = function() return "Test device" end,
            get_device_firmware_display = function() return "n/a" end,
            get_device_language = function() return "en" end,
        })
        ZenSpec.replace("datastorage", {
            getDataDir = function() return "/__zen_bugreporter_missing__" end,
        })
        ZenSpec.replace("android", {})
        ZenSpec.replace("ltn12", {
            source = {
                string = function(payload) return payload end,
            },
            sink = {
                table = function(target)
                    return function(chunk)
                        if chunk then target[#target + 1] = chunk end
                        return 1
                    end
                end,
            },
        })
        ZenSpec.replace("ssl.https", {
            request = function(request)
                payloads[#payloads + 1] = JSON.decode(request.source)
                if upload_fails and request.url:sub(-6) == "upload" then return 1, 500 end
                request.sink('{"url":"https://github.com/example/issue/1"}')
                return 1, 201
            end,
        })
        ZenSpec.unload("modules/settings/zen_bugreporter")
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do
            package.loaded[name] = original_modules[name]
        end
        ZenSpec.unload("modules/settings/zen_bugreporter")
        _G.G_reader_settings = original_reader_settings
    end)

    local function submit()
        require("modules/settings/zen_bugreporter")._do_submit(
            { plugin = {} }, "Title", "Description", ""
        )
        UIManager.submit_callback()
        return payloads[#payloads]
    end

    it("renders a notice before submitting the report", function()
        require("modules/settings/zen_bugreporter")._do_submit(
            { plugin = {} }, "Title", "Description", ""
        )

        assert.are.equal("Submitting report…", UIManager.widget.text)
        assert.are.equal(0, #payloads)

        UIManager.submit_callback()

        assert.are.equal(1, #payloads)
    end)

    it("keeps earlier network diagnostics within a bounded crash log", function()
        local data_dir = os.tmpname()
        os.remove(data_dir)
        assert.is_true(lfs.mkdir(data_dir))
        local log_path = data_dir .. "/crash.log"
        local file = assert(io.open(log_path, "wb"))
        file:write("old crash\n", "DEBUG ZenOS: [network_switcher] Kobo connection result\n",
            string.rep("x", 600000), "recent crash\n")
        file:close()
        package.loaded.datastorage.getDataDir = function() return data_dir end

        submit()

        local uploaded = payloads[1].log
        assert.is_true(uploaded:find("[earlier network diagnostics]", 1, true) == 1)
        assert.is_truthy(uploaded:find("Kobo connection result", 1, true))
        assert.is_nil(uploaded:find("old crash", 1, true))
        assert.are.equal("recent crash\n", uploaded:sub(-13))
        assert.is_true(#uploaded < 512100)
        os.remove(log_path)
        lfs.rmdir(data_dir)
    end)

    it("omits network identifiers from uploads and the inline fallback", function()
        local data_dir = os.tmpname()
        os.remove(data_dir)
        assert.is_true(lfs.mkdir(data_dir))
        local log_path = data_dir .. "/crash.log"
        local file = assert(io.open(log_path, "wb"))
        file:write('DEBUG NetworkMgr: lease_ssid set to Private Wi-Fi after async restore\n',
            string.rep("x", 600000), "\n",
            'DEBUG WpaSupplicant:getCurrentNetwork: Connected network: {\n',
            '  ssid = [[Private Wi-Fi\nMY HOME NETWORK]],\n',
            '  password = "secret",\n',
            '}\n',
            'DEBUG NetworkMgr: interface wlan0 is up @ 10.0.0.86\n',
            'DEBUG NetworkMgr: interface wlan0 is up @ fe80::1234%wlan0\n',
            'DEBUG NetworkMgr: interface wlan0 is up @ 2001:db8:0:0:0:0:0:1\n',
            'DEBUG ZenOS: [network_switcher] active network ssid= Private Wi-Fi\n',
            'DEBUG profile: {"ssid": "Private Wi-Fi"}\n',
            'DEBUG NetworkMgr: socket.udp.setpeername: Network is unreachable\n',
            'DEBUG ZenOS: [network_switcher] connection verified ip_assigned= true\n')
        file:close()
        package.loaded.datastorage.getDataDir = function() return data_dir end

        for _i, fallback in ipairs({ false, true }) do
            payloads = {}
            upload_fails = fallback
            local issue = submit()
            local log = fallback and issue.body or payloads[1].log
            for _j, value in ipairs({ "Private Wi-Fi", "MY HOME NETWORK", "secret", "10.0.0.86",
                    "fe80::1234", "2001:db8:0:0:0:0:0:1" }) do
                assert.is_nil(log:find(value, 1, true))
            end
            assert.is_truthy(log:find("Network is unreachable", 1, true))
            assert.is_truthy(log:find("connection verified ip_assigned= true", 1, true))
        end
        os.remove(log_path)
        lfs.rmdir(data_dir)
    end)

    it("retains Bluetooth failures before Wi-Fi and keyboard chatter in both report paths", function()
        local data_dir = os.tmpname()
        os.remove(data_dir)
        assert.is_true(lfs.mkdir(data_dir))
        local log_path = data_dir .. "/crash.log"
        local file = assert(io.open(log_path, "wb"))
        file:write("INFO ZenOS: [bluetooth] power request complete success= true\n",
            "INFO ZenOS: [kobo_bluetooth] command start operation= manager-connect\n",
            "Error org.bluez.Error.Failed: br-connection-profile-unavailable\n",
            "WARN ZenOS: [kobo_bluetooth] command result operation= manager-connect success= false\n",
            string.rep("DEBUG NetworkMgr: interface is not operational yet\n", 1600),
            string.rep("DEBUG ZenOS: [responsive_keyboard] keyboard contact\n", 13000),
            "recent crash\n")
        file:close()
        package.loaded.datastorage.getDataDir = function() return data_dir end

        for _i, fallback in ipairs({ false, true }) do
            payloads = {}
            upload_fails = fallback
            local issue = submit()
            local log = fallback and issue.body or payloads[1].log
            assert.is_truthy(log:find("[earlier bluetooth diagnostics]", 1, true))
            assert.is_truthy(log:find("power request complete success= true", 1, true))
            assert.is_truthy(log:find("manager-connect success= false", 1, true))
            assert.is_truthy(log:find("br-connection-profile-unavailable", 1, true))
            assert.is_truthy(log:find("recent crash", 1, true))
            if not fallback then assert.is_true(#log < 512200) end
        end
        os.remove(log_path)
        lfs.rmdir(data_dir)
    end)

    it("uploads a complete smaller log and retains Bluetooth in its inline fallback", function()
        local data_dir = os.tmpname()
        os.remove(data_dir)
        assert.is_true(lfs.mkdir(data_dir))
        local log_path = data_dir .. "/crash.log"
        local contents = "original crash\n"
            .. string.rep("INFO ZenOS: [bluetooth] connection diagnostic\n", 600)
            .. string.rep("x", 470000) .. "recent crash\n"
        local file = assert(io.open(log_path, "wb"))
        file:write(contents)
        file:close()
        package.loaded.datastorage.getDataDir = function() return data_dir end

        submit()
        assert.are.equal(contents, payloads[1].log)
        upload_fails = true
        local issue = submit()
        assert.is_truthy(issue.body:find("[earlier bluetooth diagnostics]", 1, true))
        assert.is_truthy(issue.body:find("connection diagnostic", 1, true))
        assert.is_truthy(issue.body:find("recent crash", 1, true))
        os.remove(log_path)
        lfs.rmdir(data_dir)
    end)

    it("adds the beta label on the beta update channel", function()
        channel = "beta"
        assert.are.same({ "bug", "beta" }, submit().labels)
    end)

    it("adds the beta label for an alpha version on the stable update channel", function()
        version = "1.0.0-alpha1"
        assert.are.same({ "bug", "beta" }, submit().labels)
    end)

    it("keeps stable-channel reports labeled only as bugs", function()
        assert.are.same({ "bug" }, submit().labels)
    end)

    it("enables both KOReader debug flags before restarting", function()
        local debug_calls = {}
        local flushed = false
        local restarted = false
        local settings = ZenSpec.memorySettings()
        settings.flush = function() flushed = true end
        _G.G_reader_settings = settings
        ZenSpec.replace("dbg", {
            turnOn = function() debug_calls[#debug_calls + 1] = "on" end,
            setVerbose = function(_self, enabled)
                debug_calls[#debug_calls + 1] = enabled and "verbose" or "quiet"
            end,
        })
        package.loaded["common/restart"].request = function() restarted = true end

        require("modules/settings/zen_bugreporter").show_dialog({})
        UIManager.widget.ok_callback()

        assert.is_true(settings:isTrue("debug"))
        assert.is_true(settings:isTrue("debug_verbose"))
        assert.same({ "on", "verbose" }, debug_calls)
        assert.is_true(flushed)
        assert.is_true(restarted)
    end)
end)
