describe("updater repository redirects", function()
    local original_https
    local original_ltn12
    local original_archiver
    local original_icon_item
    local original_logger
    local original_plugin_root
    local original_changelog
    local original_zen_screen
    local original_network_manager
    local original_trapper
    local original_uimanager
    local config
    local logs
    local network_up
    local release_body
    local requests
    local scheduled
    local asset_name
    local shown_screen

    before_each(function()
        original_https = package.loaded["ssl.https"]
        original_ltn12 = package.loaded["ltn12"]
        original_archiver = package.loaded["ffi/archiver"]
        original_icon_item = package.loaded["common/ui/icon_menu_item"]
        original_logger = package.loaded["common/zen_logger"]
        original_plugin_root = package.loaded["common/plugin_root"]
        original_changelog = package.loaded["config/changelog"]
        original_zen_screen = package.loaded["common/ui/zen_screen"]
        original_network_manager = package.loaded["ui/network/manager"]
        original_trapper = package.loaded["ui/trapper"]
        original_uimanager = package.loaded["ui/uimanager"]
        logs = {}
        network_up = true
        release_body = nil
        requests = {}
        scheduled = {}
        asset_name = "zenos.koplugin.zip"
        shown_screen = nil
        config = { updater = { update_channel = "stable" } }

        ZenSpec.replace("ffi/archiver", {})
        ZenSpec.replace("common/ui/icon_menu_item", {
            decorate = function(item) return item end,
        })
        ZenSpec.replace("common/plugin_root", "/plugins/zenos.koplugin")
        ZenSpec.replace("config/manager", {
            load = function() return config end,
            save = function() end,
        })
        ZenSpec.replace("config/changelog", {
            ["1.0.0"] = { "Oldest" },
            ["2.0.0"] = { "Second" },
            ["3.0.0"] = { "Third" },
            ["4.0.0"] = { "Fourth" },
            ["5.0.0"] = { "Fifth" },
            ["6.0.0"] = { "Newest **feature**" },
        })
        ZenSpec.replace("common/ui/zen_screen", {
            new = function(_self, values)
                values.update = function(screen, changes)
                    for key, value in pairs(changes) do screen[key] = value end
                end
                return values
            end,
        })
        ZenSpec.replace("common/zen_logger", {
            new = function()
                local updater_logger = {}
                for _i, level in ipairs({ "dbg", "info", "warn", "err" }) do
                    local log_level = level
                    updater_logger[log_level] = function(...)
                        local parts = {}
                        for i = 1, select("#", ...) do
                            parts[#parts + 1] = tostring(select(i, ...))
                        end
                        logs[#logs + 1] = { level = log_level, text = table.concat(parts, " ") }
                    end
                end
                return updater_logger
            end,
        })
        ZenSpec.replace("ui/network/manager", {
            isWifiOn = function() return network_up end,
        })
        ZenSpec.replace("ui/trapper", {
            wrap = function(_, fn) fn() end,
            dismissableRunInSubprocess = function(_, task)
                return true, task()
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function(_, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            unschedule = function() end,
            show = function(_self, screen) shown_screen = screen end,
        })
        ZenSpec.replace("ltn12", {
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
                requests[#requests + 1] = request.url
                assert.is_false(request.redirect)
                assert.are.equal("zenos.koplugin", request.headers["User-Agent"])
                if #requests == 1 then
                    return 1, 301, {
                        location = "https://api.github.com/repositories/1194031944/releases?per_page=100",
                    }, "HTTP/1.1 301 Moved Permanently"
                end
                request.sink(release_body or string.format([[
                    [{
                        "url":"https://api.github.com/repos/xZenLabs/zen-os-renamed/releases/12345",
                        "tag_name":"v999.0.0",
                        "prerelease":false,
                        "body":"Renamed repository release",
                        "published_at":"2026-07-12T00:00:00Z",
                        "assets":[{
                            "name":"%s",
                            "browser_download_url":"https://github.com/xZenLabs/zen-os-renamed/releases/download/v999.0.0/%s",
                            "digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                        }]
                    }]
                ]], asset_name, asset_name))
                return 1, 200, {}, "HTTP/1.1 200 OK"
            end,
        })
        ZenSpec.unload("modules/settings/zen_updater")
    end)

    after_each(function()
        package.loaded["ssl.https"] = original_https
        package.loaded["ltn12"] = original_ltn12
        package.loaded["ffi/archiver"] = original_archiver
        package.loaded["common/ui/icon_menu_item"] = original_icon_item
        package.loaded["common/zen_logger"] = original_logger
        package.loaded["common/plugin_root"] = original_plugin_root
        package.loaded["config/changelog"] = original_changelog
        package.loaded["common/ui/zen_screen"] = original_zen_screen
        package.loaded["ui/network/manager"] = original_network_manager
        package.loaded["ui/trapper"] = original_trapper
        package.loaded["ui/uimanager"] = original_uimanager
        ZenSpec.unload("modules/settings/zen_updater")
        ZenSpec.unload("config/manager")
    end)

    it("follows the GitHub API redirect and selects the canonical ZenOS asset", function()
        local updater = require("modules/settings/zen_updater")

        assert.are.equal("ok", updater.check_for_update())
        assert.are.equal(2, #requests)
        assert.are.equal(
            "https://api.github.com/repos/xZenLabs/zen-os/releases?per_page=100",
            requests[1]
        )
        assert.are.equal(
            "https://api.github.com/repositories/1194031944/releases?per_page=100",
            requests[2]
        )
        assert.are.equal("999.0.0", updater.latest_version())
        assert.is_true(updater.has_update())
    end)

    it("selects the compatibility asset while running from the legacy folder", function()
        asset_name = "zen_ui.koplugin.zip"
        ZenSpec.replace("common/plugin_root", "/plugins/zen_ui.koplugin")
        ZenSpec.unload("modules/settings/zen_updater")
        local updater = require("modules/settings/zen_updater")

        assert.are.equal("ok", updater.check_for_update())
        assert.are.equal("999.0.0", updater.latest_version())
        assert.is_true(updater.has_update())
    end)

    it("ignores alpha releases on the beta channel", function()
        config.updater.update_channel = "beta"
        release_body = string.format([[
            [{
                "tag_name":"v3.3.0-alpha1",
                "prerelease":true,
                "published_at":"2026-09-03T00:00:00Z",
                "assets":[{
                    "name":"%s",
                    "browser_download_url":"https://github.com/xZenLabs/zen-os/releases/download/v3.3.0-alpha1/%s",
                    "digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                }]
            },{
                "tag_name":"v3.3.0-beta7",
                "prerelease":true,
                "published_at":"2026-09-02T00:00:00Z",
                "assets":[{
                    "name":"%s",
                    "browser_download_url":"https://github.com/xZenLabs/zen-os/releases/download/v3.3.0-beta7/%s",
                    "digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                }]
            }]
        ]], asset_name, asset_name, asset_name, asset_name)
        local updater = require("modules/settings/zen_updater")

        assert.are.equal("ok", updater.check_for_update())
        assert.are.equal("3.3.0-beta7", updater.latest_version())
    end)

    it("clears the update marker after a version change is acknowledged", function()
        local updater = require("modules/settings/zen_updater")
        assert.are.equal("ok", updater.check_for_update())
        assert.is_true(updater.has_update())
        assert.is_true(config.updater.update_available)

        updater.clear_update_state(config)

        assert.is_false(updater.has_update())
        assert.is_nil(updater.latest_version())
        assert.is_false(config.updater.update_available)
    end)

    it("builds the changelog from the bundled file without a network request", function()
        local updater = require("modules/settings/zen_updater")

        updater.build_changelog_item().callback()

        assert.are.equal(0, #requests)
        assert.is_table(shown_screen)
        assert.is_truthy(shown_screen.scroll_text:find("v6.0.0", 1, true))
        assert.is_truthy(shown_screen.scroll_text:find("\u{2022} Newest", 1, true))
        assert.is_nil(shown_screen.scroll_text:find("v1.0.0", 1, true))
        assert.are.equal("Load more", shown_screen.button)

        shown_screen._on_button_action()

        assert.is_truthy(shown_screen.scroll_text:find("v1.0.0", 1, true))
        assert.is_false(shown_screen.button)
    end)

    it("logs one summary line for an automatic update check", function()
        local updater = require("modules/settings/zen_updater")

        updater.schedule_wakeup_check()
        assert.are.equal(0, #logs)
        assert.are.equal(1, #scheduled)

        scheduled[1].callback()

        assert.are.same({ {
            level = "info",
            text = "automatic update check status=ok has_update= true latest= 999.0.0",
        } }, logs)
    end)

    it("logs only the final automatic check result when the network stays down", function()
        network_up = false
        local updater = require("modules/settings/zen_updater")

        updater.schedule_wakeup_check()
        scheduled[1].callback()
        assert.are.equal(0, #logs)
        assert.are.equal(2, #scheduled)

        scheduled[2].callback()

        assert.are.same({ {
            level = "info",
            text = "automatic update check status=skipped reason=network_unavailable",
        } }, logs)
    end)
end)
