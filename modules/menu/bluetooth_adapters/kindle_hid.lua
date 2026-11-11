-- Classic HID (gamepads, keyboards, page turners) on the stock ACE stack.
-- btfd bonds them fine but hides them from discovery and only knows audio connects.
local lfs = require("libs/libkoreader-lfs")
local logger = require("common/zen_logger").new("bluetooth_kindle_hid")

local M = {}
local CLI = "/usr/bin/ace_bt_cli"
local SNOOP = "/mnt/us/bt_snoop_log" -- BtSnoopFileName in bt_stack.conf
local BT_CONFIG = "/var/local/zbluetooth/bt_config.conf"
local DMCC = "/usr/bin/dmcc.sh"
local PRE_GM = "/PRE_GM_DEBUGGING_FEATURES_ENABLED__REMOVE_AT_GMC"
local SYSTEM_FILES = {
    ["/usr/local/bin/dev_is_keyboard.sh"] = [[
#!/bin/sh
DEVICE=$1
if evtest info $DEVICE | grep -q 'Event type 1 (Key)'; then
  if evtest info $DEVICE | grep -q 'Event code 16 (Q)'; then
    # Key support alone would also tag the touchscreen as a keyboard
    echo ID_INPUT=1
    echo ID_INPUT_KEY=1
    echo ID_INPUT_KEYBOARD=1
  fi
fi
]],
    ["/etc/udev/rules.d/99-bt-keyboard.rules"] = [[
KERNEL=="uhid", MODE="0660", GROUP="bluetooth"
ACTION=="add", SUBSYSTEM=="input", IMPORT+="/usr/local/bin/dev_is_keyboard.sh %N"
]],
}

local function exists(path) return lfs.attributes(path, "mode") ~= nil end

local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("*a")
    file:close()
    return data
end

local function run(command)
    local ok, _how, code = os.execute(command .. " >/dev/null 2>&1")
    return ok == true or ok == 0 or code == 0
end

-- ace_bt_cli spins on stdin EOF: always send exit, bound it with timeout.
local function cli(command, after)
    os.execute("( ( echo " .. command .. "; sleep 1; echo exit ) | timeout 5 " .. CLI
        .. "; " .. (after or ":") .. " ) >/dev/null 2>&1 &")
end

-- ACE stack + uhid only: the system changes white-screen older (BSA) Kindles.
function M.isSupported()
    return exists(CLI) and exists("/dev/uhid")
end

-- Idempotent; touches the root filesystem only when something is missing.
function M.setup()
    if not M.isSupported() then return false end
    -- HID disconnects otherwise flood the userstore with core dumps
    for _i, name in ipairs({ "DISABLE_CORE_DUMP", "DISABLE_CORE_DUMP_ALERT" }) do
        local marker = io.open("/mnt/us/" .. name, "a")
        if marker then marker:close() end
    end
    local stale = {}
    for path, content in pairs(SYSTEM_FILES) do
        if read(path) ~= content then stale[#stale + 1] = path end
    end
    -- dmcc.sh only runs where the debug flag exists; invert its guard there.
    local dmcc = exists(PRE_GM) and (read(DMCC) or ""):find('\nif ! [ -e "' .. PRE_GM, 1, true) ~= nil
    if #stale == 0 and not dmcc then return true end
    if not run("mntroot rw") then
        logger.warn("setup: could not remount root read-write")
        return false
    end
    -- pcall: root must go back read-only whatever happens in between
    local done, ok = pcall(function()
        local ok = run("mkdir -p /usr/local/bin")
        for _i, path in ipairs(stale) do
            local file = io.open(path, "w")
            if file then
                ok = file:write(SYSTEM_FILES[path]) ~= nil and ok
                file:close()
            else
                ok = false
            end
        end
        ok = run("chmod +x /usr/local/bin/dev_is_keyboard.sh") and ok
        if dmcc then
            ok = run([[sed -i 's|^if ! \(\[ -e "/PRE_GM_DEBUGGING\)|if \1|' ]] .. DMCC) and ok
        end
        return ok
    end)
    if not done then logger.warn("setup: failed:", tostring(ok)) end
    ok = done and ok
    run("sync")
    if not run("mntroot ro") then
        logger.warn("setup: could not remount root read-only")
        ok = false
    end
    run("udevadm control --reload-rules")
    logger.info("setup:", ok and "applied" or "incomplete", "files=", #stale, "dmcc=", tostring(dmcc))
    return ok
end

-- Classic peripherals (major class 5) and BLE HID devices from a btsnoop capture.
function M.parseSnoop(data)
    local devices, by_address, le = {}, {}, {}
    local function address_at(i)
        local b = { data:byte(i, i + 5) }
        if #b < 6 then return nil end
        return string.format("%02X:%02X:%02X:%02X:%02X:%02X", b[6], b[5], b[4], b[3], b[2], b[1])
    end
    local function signed(byte) return byte and (byte > 127 and byte - 256 or byte) end
    local function list(device)
        if by_address[device.address] then return end
        by_address[device.address] = device
        devices[#devices + 1] = device
    end
    -- EIR / advertising data (length, type, value): sets the name, returns whether it marks HID.
    local function fields(device, field, stop)
        local hid = false
        while field < stop do
            local length, kind = data:byte(field, field + 1)
            if not length or length == 0 then break end
            if kind == 0x08 or kind == 0x09 then
                device.name = data:sub(field + 2, field + length)
            elseif kind == 0x19 then -- appearance 0x03C0-0x03C4
                local low, high = data:byte(field + 2, field + 3)
                hid = hid or (high == 0x03 and low ~= nil and low >= 0xC0 and low <= 0xC4)
            elseif kind == 0x02 or kind == 0x03 then -- 16-bit services, 0x1812
                for i = field + 2, field + length - 1, 2 do
                    hid = hid or (data:byte(i) == 0x12 and data:byte(i + 1) == 0x18)
                end
            end
            field = field + length + 1
        end
        return hid
    end
    local pos = 17 -- 16-byte file header
    while pos + 23 <= #data do
        local a, b, c, d = data:byte(pos + 4, pos + 7) -- included length
        local packet = pos + 24
        pos = packet + ((a * 256 + b) * 256 + c) * 256 + d
        if pos - 1 > #data then break end
        local event, body = data:byte(packet + 1), packet + 3
        if data:byte(packet) ~= 0x04 then event = nil end
        -- First response only; controllers report one device per event.
        local class_at = (event == 0x22 or event == 0x2F) and body + 10 or event == 0x02 and body + 11
        local address = (class_at or event == 0x07) and address_at(body + 1)
        if class_at and address and (data:byte(class_at) or 0) % 32 == 5 then
            local device = by_address[address] or { address = address, hid = true }
            list(device)
            if event ~= 0x02 then device.rssi = signed(data:byte(body + 14)) end
            if event == 0x2F then fields(device, body + 15, pos) end
        elseif event == 0x07 and by_address[address] and data:byte(body) == 0 then
            local name = data:sub(body + 7, pos - 1):match("^[^%z]+") -- remote name complete
            if name then by_address[address].name = name end
        elseif event == 0x3E and data:byte(body) == 0x02 then
            local report = body + 2 -- LE advertising: type, address type, address, length, data, RSSI
            for _n = 1, data:byte(body + 1) or 0 do
                local length, le_address = data:byte(report + 8), address_at(report + 2)
                local stop = length and report + 9 + length
                if not le_address or not stop or stop >= pos then break end
                -- Name and HID marker can come in separate reports.
                local device = le[le_address] or { address = le_address, hid = true, le = true }
                le[le_address] = device
                device.rssi = signed(data:byte(stop))
                if fields(device, report + 9, stop) then list(device) end
                report = stop + 1
            end
        end
    end
    return devices
end

-- Scans only once the beacon client is registered: an unregistered request is
-- queued under a dead session and then scans until btmanagerd restarts.
local LE_SCAN = [[
d=$(mktemp -d) && mkfifo "$d/in" || exit 1
timeout 16 ]] .. CLI .. [[ < "$d/in" > "$d/out" 2>&1 &
exec 3> "$d/in"
echo "ble regble" >&3; sleep 1
echo "ble registerbeacon" >&3; sleep 2
if grep -q "Beacon Client Registered Success" "$d/out"; then
    echo "ble startdefbeaconscan" >&3; sleep 8
    echo "ble stopbeaconscan" >&3; sleep 1
fi
echo exit >&3; exec 3>&-
wait; rm -rf "$d"
]]

-- The capture must be live before the inquiry starts; results arrive once.
-- The stock scan is classic-only, so a BLE scan runs alongside it.
function M.startCapture()
    os.remove(SNOOP)
    cli("enableHCI")
    os.execute("sh -c '" .. LE_SCAN .. "' >/dev/null 2>&1 &")
end

function M.finishCapture()
    local data = read(SNOOP)
    cli("disableHCI", "rm -f " .. SNOOP)
    return data and M.parseSnoop(data) or {}
end

-- Bonded devices from the stack's own store: address -> { hid, le }.
-- It keeps HID attributes for classic and BLE HID devices alike; DevType 2 is LE-only.
function M.bonded()
    local devices = {}
    for address, body in (read(BT_CONFIG) or ""):gmatch("%[(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%]([^%[]*)") do
        devices[address:upper()] = {
            hid = body:find("HidAttrMask = ", 1, true) ~= nil,
            le = body:match("DevType = (%d+)") == "2",
        }
    end
    return devices
end

return M
