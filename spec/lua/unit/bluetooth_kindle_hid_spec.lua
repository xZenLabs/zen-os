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

    it("ignores truncated captures", function()
        assert.are.same({}, Hid.parseSnoop(header .. record("042fff01" .. gamepad):sub(1, 30)))
        assert.are.same({}, Hid.parseSnoop(""))
    end)
end)
