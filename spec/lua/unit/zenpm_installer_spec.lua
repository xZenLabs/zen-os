describe("ZenPM installer asset selection", function()
    local Installer
    local original_logger
    local original_root
    local original_archiver
    local original_network_manager
    local original_confirmbox
    local original_trapper
    local original_uimanager
    local original_zen_screen

    before_each(function()
        original_logger = package.loaded["common/zen_logger"]
        original_root = package.loaded["common/plugin_root"]
        original_archiver = package.loaded["ffi/archiver"]
        original_network_manager = package.loaded["ui/network/manager"]
        original_confirmbox = package.loaded["ui/widget/confirmbox"]
        original_trapper = package.loaded["ui/trapper"]
        original_uimanager = package.loaded["ui/uimanager"]
        original_zen_screen = package.loaded["common/ui/zen_screen"]
        ZenSpec.replace("common/zen_logger", { new = function() return { info = function() end, warn = function() end } end })
        ZenSpec.replace("common/plugin_root", "/plugins/zenos.koplugin")
        ZenSpec.replace("ffi/archiver", {})
        ZenSpec.unload("modules/settings/zenpm_installer")
        Installer = require("modules/settings/zenpm_installer")
    end)

    after_each(function()
        package.loaded["common/zen_logger"] = original_logger
        package.loaded["common/plugin_root"] = original_root
        package.loaded["ffi/archiver"] = original_archiver
        package.loaded["ui/network/manager"] = original_network_manager
        package.loaded["ui/widget/confirmbox"] = original_confirmbox
        package.loaded["ui/trapper"] = original_trapper
        package.loaded["ui/uimanager"] = original_uimanager
        package.loaded["common/ui/zen_screen"] = original_zen_screen
        ZenSpec.unload("modules/settings/zenpm_installer")
    end)

    local function begin_download()
        local prompt
        local screen
        local scheduled

        ZenSpec.replace("ui/network/manager", { isWifiOn = function() return true end })
        ZenSpec.replace("ui/widget/confirmbox", {
            new = function(_self, values)
                prompt = values
                return values
            end,
        })
        ZenSpec.replace("common/ui/zen_screen", {
            new = function(_self, values)
                screen = values
                function screen:update(changes)
                    for key, value in pairs(changes) do self[key] = value end
                end
                function screen:onClose() self.closed = true end
                return screen
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            show = function() end,
            forceRePaint = function() end,
            nextTick = function(_self, callback) callback() end,
            scheduleIn = function(_self, delay, callback)
                scheduled = { delay = delay, callback = callback }
            end,
            unschedule = function() end,
        })
        ZenSpec.replace("ui/trapper", {
            wrap = function(_self, task)
                local co = coroutine.create(task)
                assert(coroutine.resume(co))
            end,
            dismissableRunInSubprocess = function()
                return coroutine.yield()
            end,
        })

        Installer.prompt_install({})
        prompt.ok_callback()
        return screen, scheduled
    end

    it("selects the 32-bit e-reader asset for reMarkable 2", function()
        assert.are.equal("ZenPM-koreader-ereader-%s.zip", Installer.select_assets("Linux", "arm"))
        assert.are.equal("ZenPM-koreader-ereader-%s.zip", Installer.select_assets("Linux", "arm32"))
        assert.are.equal("ZenPM-koreader-ereader-%s.zip", Installer.select_assets("Linux", "armv7l"))
    end)

    it("selects the ARM64 Linux asset for newer reMarkable models", function()
        assert.are.equal("ZenPM-koreader-linux-%s.zip", Installer.select_assets("Linux", "arm64"))
        assert.are.equal("ZenPM-koreader-linux-%s.zip", Installer.select_assets("Linux", "aarch64"))
    end)

    it("does not select an asset for unsupported architectures", function()
        assert.is_nil(Installer.select_assets("Linux", "x64"))
        assert.is_nil(Installer.select_assets("OSX", "arm64"))
        assert.is_nil(Installer.select_assets(nil, nil))
    end)

    it("matches release assets with the filename portion before the version", function()
        assert.are.equal("ZenPM-koreader-linux-", Installer.asset_prefix("ZenPM-koreader-linux-%s.zip"))
    end)

    it("accepts the official Linux release asset URL", function()
        local name = "ZenPM-koreader-linux-1.0.0-beta120.zip"
        assert.is_true(Installer.is_valid_asset_url(
            "https://github.com/xZenLabs/zen-pm/releases/download/v1.0.0-beta120/" .. name,
            name
        ))
    end)

    it("enables Wi-Fi before opening the install prompt", function()
        local checked_wifi = false
        local queued_callback
        ZenSpec.replace("ui/network/manager", {
            isWifiOn = function()
                checked_wifi = true
                return false
            end,
            runWhenOnline = function(_, callback)
                queued_callback = callback
            end,
        })

        Installer.prompt_install({})

        assert.is_true(checked_wifi)
        assert.is_function(queued_callback)
    end)

    it("allows cancelling a pending download", function()
        local screen = begin_download()

        assert.are.equal("Cancel", screen.button)
        screen._on_button_action()

        assert.is_true(screen.closed)
        assert.is_nil(screen._on_button_action)
    end)

    it("times out a pending download after one minute", function()
        local screen, scheduled = begin_download()

        assert.are.equal(60, scheduled.delay)
        scheduled.callback()

        assert.are.equal("Timeout", screen.subtitle)
        assert.are.equal("OK", screen.button)
        assert.is_true(screen.dismissable)
    end)
end)
