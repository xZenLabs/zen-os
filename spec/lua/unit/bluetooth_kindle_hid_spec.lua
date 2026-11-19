describe("Kindle HID discovery capture", function()
    local Hid = require("modules/menu/bluetooth_adapters/kindle_hid")

    local function record(hex)
        local packet = hex:gsub("%x%x", function(byte) return string.char(tonumber(byte, 16)) end)
        return string.rep("\0", 4) .. string.char(0, 0, 0, #packet) .. string.rep("\0", 16) .. packet
    end
    local header = "btsnoop\0" .. string.rep("\0", 8)
    local gamepad = "7c186feab698" -- 98:B6:EA:6F:18:7C

    it("lists peripherals with EIR name and RSSI, skipping other classes", function()
        local devices = Hid.parseSnoop(header
            .. record("01010405338b9e0800") -- inquiry command
            .. record("042fff01" .. gamepad .. "0202080500d074dd160947756c694b697420436f6e74726f6c6c6572205857000000")
            .. record("042fff01" .. gamepad .. "0202080500d074d00000") -- repeat, stronger
            .. record("04220f01aabbccddeeff010004042400d074c8")) -- headphones
        assert.are.same({
            { address = "98:B6:EA:6F:18:7C", name = "GuliKit Controller XW", rssi = -48, hid = true },
        }, devices)
    end)

    it("names legacy inquiry results from the remote name event", function()
        local devices = Hid.parseSnoop(header
            .. record("04020f01" .. gamepad .. "02000040250000d0")
            .. record("0407ff00" .. gamepad .. "506164000000"))
        assert.are.same({ { address = "98:B6:EA:6F:18:7C", name = "Pad", hid = true } }, devices)
    end)

    it("lists BLE devices advertising HID, naming them from a later report", function()
        local pad, speaker, ring = "e2bb9fd76af4", "0102030405aa", "0605040302bb"
        local devices = Hid.parseSnoop(header
            .. record("043eff02010000" .. pad .. "0702010603031218d0")
            .. record("043eff02010000" .. speaker .. "0c0303befe0709426f73652020c4")
            .. record("043eff02010400" .. pad .. "0504095061" .. "64df")
            -- two reports in one event; appearance 0x03C1 on a random address
            .. record("043eff0202" .. "0001" .. ring .. "040319c103b0" .. "0000" .. speaker .. "00c0"))
        assert.are.same({
            { address = "F4:6A:D7:9F:BB:E2", name = "Pad", rssi = -33, hid = true, le = true },
            { address = "BB:02:03:04:05:06", rssi = -80, hid = true, le = true },
        }, devices)
    end)

    it("ignores truncated captures", function()
        assert.are.same({}, Hid.parseSnoop(header .. record("042fff01" .. gamepad):sub(1, 30)))
        assert.are.same({}, Hid.parseSnoop(""))
    end)

    it("finishes HCI commands and cleanup before a capture can restart", function()
        local snoop = "/mnt/us/bt_snoop_log"
        local path = os.tmpname()
        local execute, open = os.execute, io.open
        local execute_stub = stub(os, "execute", function(command)
            -- Exercise the real shell pipeline with a local stand-in for ace_bt_cli.
            if command:find("enableHCI", 1, true) or command:find("disableHCI", 1, true) then
                command = command:gsub("/usr/bin/ace_bt_cli", "cat"):gsub(snoop, path)
                return execute(command)
            end
            return 0 -- no BLE scan on the test host
        end)
        local remove_stub = stub(os, "remove", function(target)
            assert.equals(snoop, target)
            return execute("rm -f " .. path) == 0
        end)
        local open_stub = stub(io, "open", function(target, mode)
            return open(target == snoop and path or target, mode)
        end)
        local ok, err = pcall(function()
            Hid.startCapture()
            local file = assert(open(path, "w"))
            file:write(header)
            file:close()
            assert.same({}, Hid.finishCapture())
            local remaining = open(path, "r")
            if remaining then remaining:close() end
            assert.is_nil(remaining) -- shutdown cleanup completed before returning
            Hid.startCapture()
        end)
        open_stub:revert()
        remove_stub:revert()
        execute_stub:revert()
        os.remove(path)
        assert.is_true(ok, tostring(err))
    end)

    describe("one-time system setup", function()
        local lfs = require("libs/libkoreader-lfs")
        local RULES, HELPER = "/etc/udev/rules.d/99-bt-keyboard.rules", "/usr/local/bin/dev_is_keyboard.sh"
        local FLAG, DMCC = "/PRE_GM_DEBUGGING_FEATURES_ENABLED__REMOVE_AT_GMC", "/usr/bin/dmcc.sh"
        local originals, files, commands, fail

        before_each(function()
            originals = { open = io.open, execute = os.execute, remove = os.remove, attributes = lfs.attributes }
            files = { ["/usr/bin/ace_bt_cli"] = "", ["/dev/uhid"] = "" }
            commands, fail = {}, {}
            lfs.attributes = function(path) return files[path] and "file" or nil end
            io.open = function(path, mode) -- luacheck: ignore
                if path:sub(1, 1) ~= "/" then return originals.open(path, mode) end
                if mode == "rb" and not files[path] then return nil end
                if fail[path] then return nil end
                return {
                    read = function() return files[path] end,
                    write = function(_self, content) files[path] = content; return true end,
                    close = function() end,
                }
            end
            os.execute = function(command) -- luacheck: ignore
                commands[#commands + 1] = command
                for pattern in pairs(fail) do
                    if command:find(pattern, 1, true) then return 1 end
                end
                if command:find("sed -i", 1, true) then
                    files[DMCC] = command:find("if ! \\(", 1, true) and files[DMCC]:gsub("\nif ! %[", "\nif [")
                        or files[DMCC]:gsub("\nif %[", "\nif ! [")
                end
                return 0
            end
            os.remove = function(path) files[path] = nil; return true end -- luacheck: ignore
        end)

        after_each(function()
            io.open, os.execute, os.remove = originals.open, originals.execute, originals.remove -- luacheck: ignore
            lfs.attributes = originals.attributes
        end)

        local function ran(text)
            for _i, command in ipairs(commands) do
                if command:find(text, 1, true) then return true end
            end
            return false
        end

        it("applies once and then reports the Kindle as set up", function()
            files[FLAG], files[DMCC] = "", '#!/bin/sh\nif ! [ -e "' .. FLAG .. '" ]; then exit; fi\n'
            assert.is_false(Hid.isSetUp())
            assert.is_true(Hid.setup())
            assert.is_true(Hid.isSetUp())
            assert.is_truthy(files[RULES] and files[HELPER] and files["/mnt/us/DISABLE_CORE_DUMP"])
            assert.is_truthy(files[DMCC]:find('\nif [ -e "', 1, true))
            assert.is_true(ran("mntroot ro"))

            commands = {}
            assert.is_true(Hid.setup())
            assert.are.same({}, commands)
        end)

        it("restores stock files when a step fails", function()
            local stock = '#!/bin/sh\nif ! [ -e "' .. FLAG .. '" ]; then exit; fi\n'
            files[FLAG], files[DMCC], files[RULES] = "", stock, "user rule\n"
            fail["chmod +x"] = true
            assert.is_false(Hid.setup())
            assert.are.equal("user rule\n", files[RULES])
            assert.is_nil(files[HELPER])
            assert.is_nil(files["/mnt/us/DISABLE_CORE_DUMP"])
            assert.are.equal(stock, files[DMCC])
            assert.is_true(ran("mntroot ro"))
            assert.is_false(Hid.isSetUp())
        end)

        it("changes nothing when root cannot be remounted or the Kindle is unsupported", function()
            fail["mntroot rw"] = true
            assert.is_false(Hid.setup())
            assert.is_nil(files[RULES])
            assert.is_nil(files["/mnt/us/DISABLE_CORE_DUMP"])

            files["/dev/uhid"], commands = nil, {}
            assert.is_false(Hid.isSupported())
            assert.is_false(Hid.setup())
            assert.are.same({}, commands)
        end)
    end)
end)
