local JSON = require("json")

describe("bug reporter labels", function()
    local channel
    local original_modules
    local original_reader_settings
    local payloads
    local UIManager
    local version

    local module_names = {
        "android",
        "common/restart",
        "common/utils",
        "common/zen_logger",
        "datastorage",
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
        })
        ZenSpec.replace("ui/uimanager", UIManager)
        ZenSpec.replace("common/restart", {})
        ZenSpec.replace("common/utils", {
            truncateUtf8Bytes = function(value) return value end,
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
        local flushed = false
        local restarted = false
        local settings = ZenSpec.memorySettings()
        settings.flush = function() flushed = true end
        _G.G_reader_settings = settings
        package.loaded["common/restart"].request = function() restarted = true end

        require("modules/settings/zen_bugreporter").show_dialog({})
        UIManager.widget.ok_callback()

        assert.is_true(settings:isTrue("debug"))
        assert.is_true(settings:isTrue("debug_verbose"))
        assert.is_true(flushed)
        assert.is_true(restarted)
    end)
end)
