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
end)
