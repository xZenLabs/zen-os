local Device = require("device")
local logger = require("common/zen_logger").new("kobo_bluetooth")

local M = {}
local MTK_SERVICE = "com.kobo.mtk.bluedroid"
local ADAPTER = "/org/bluez/hci0"
local PROPERTIES = "org.freedesktop.DBus.Properties"
local SAGE_RFKILL = "/sys/devices/platform/bt/rfkill/rfkill0/state"
local SAGE_HCI_LOG = "/tmp/zenos-rtk-hciattach.log"
local SAGE_BLUEZ_LOG = "/tmp/zenos-bluetoothd.log"
local owned = false
local standby_locked = false
local pending
local discovery_kind, discovery_poll
local manager_scanning = false
local manager_scan_done
local cached_state, cached_at
local last_state_log
local last_availability_log
local last_plugin_source

local function supported_plugin(plugin, source)
    local bluetooth = type(plugin) == "table" and plugin.kobo_bluetooth
    if bluetooth and type(bluetooth.isDeviceSupported) == "function" then
        local ok, supported = pcall(bluetooth.isDeviceSupported, bluetooth)
        if ok and supported then
            if source ~= last_plugin_source then
                logger.info("kobo.koplugin lookup found via", source)
                last_plugin_source = source
            end
            return bluetooth
        end
    end
end

local function ui_plugin(ui, source)
    if type(ui) ~= "table" then return nil end
    return supported_plugin(ui.kobo, source .. ".kobo")
        or supported_plugin(ui.kobo_plugin, source .. ".kobo_plugin")
end

local function plugin_bluetooth()
    local ok_loader, loader = pcall(require, "pluginloader")
    if ok_loader and type(loader) == "table" and type(loader.getPluginInstance) == "function" then
        local ok_plugin, plugin = pcall(loader.getPluginInstance, loader, "kobo")
        if ok_plugin then
            local bluetooth = supported_plugin(plugin, "PluginLoader.kobo")
            if bluetooth then return bluetooth end
        end
    end
    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    local bluetooth = ok_reader and type(ReaderUI) == "table"
        and ui_plugin(ReaderUI.instance, "ReaderUI")
    if bluetooth then return bluetooth end
    local ok_manager, FileManager = pcall(require, "apps/filemanager/filemanager")
    bluetooth = ok_manager and type(FileManager) == "table"
        and ui_plugin(FileManager.instance, "FileManager")
    if bluetooth then return bluetooth end
    local zen = rawget(_G, "__ZEN_UI_PLUGIN")
    return ui_plugin(zen and zen.ui, "ZenUI")
end

local function kind()
    if not (Device.isKobo and Device:isKobo()) then return nil end
    if Device.model == "Kobo_io" then return "libra2" end
    if Device.model == "Kobo_goldfinch" then return "clara2e" end
    if Device.model == "Kobo_cadmus" then return "sage" end
    if Device.isMTK and Device:isMTK() then
        local file = io.open("/usr/share/dbus-1/system-services/" .. MTK_SERVICE .. ".service", "r")
        if file then
            file:close()
            return "mtk"
        end
    end
end

local function compact(output, limit)
    output = (output or ""):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
    limit = limit or 400
    return #output > limit and output:sub(1, limit) .. "..." or output
end

local function log_nickel_settings(context)
    local file = io.open("/mnt/onboard/.kobo/Kobo/Kobo eReader.conf", "r")
    if not file then
        logger.warn("Nickel Bluetooth settings unavailable context=", context)
        return
    end
    local values, in_section = {}, false
    for line in file:lines() do
        local section = line:match("^%s*%[([^]]+)%]%s*$")
        if section then
            in_section = section == "BluetoothSettings"
        elseif in_section then
            local key, value = line:match("^%s*([^=]+)%s*=%s*(.-)%s*$")
            if key then values[key] = value end
        end
    end
    file:close()
    logger.info("Nickel Bluetooth settings context=", context,
        "EnabledByUser=", tostring(values.EnabledByUser),
        "DeviceWithHIDPaired=", tostring(values.DeviceWithHIDPaired),
        "DefaultAudioDevice=", tostring(values.DefaultAudioDevice))
end

local function succeeded(ok, code)
    return ok == true or ok == 0 or code == 0
end

local function command_ok(command, operation)
    logger.info("command start operation=", operation, "command=", command,
        "reply=process-output-between-command-logs")
    local ok, reason, code = os.execute(command)
    local success = succeeded(ok, code)
    local log = success and logger.info or logger.warn
    log("command result operation=", operation, "success=", tostring(success),
        "status=", tostring(ok), "reason=", tostring(reason), "code=", tostring(code))
    return success
end

local function query(command, operation, verbose)
    if verbose then logger.info("query start operation=", operation) end
    local pipe = io.popen(command .. " 2>&1", "r")
    if not pipe then
        logger.warn("query open failed operation=", operation)
        return nil
    end
    local output = pipe:read("*a") or ""
    local ok, reason, code = pipe:close()
    if verbose then
        logger.info("query result operation=", operation, "bytes=", #output,
            "status=", tostring(ok), "reason=", tostring(reason), "code=", tostring(code))
        if output == "" or output:find("Error", 1, true) then
            logger.warn("query diagnostic operation=", operation, "output=", compact(output))
        end
    end
    return output
end

local function query_bool(command, operation, verbose)
    local output = query(command, operation, verbose)
    if not output then return nil end
    local value
    if output:find("boolean true", 1, true) then value = true end
    if output:find("boolean false", 1, true) then value = false end
    if verbose then
        local log = value == nil and logger.warn or logger.info
        log("boolean query operation=", operation, "value=", tostring(value),
            "output=", compact(output))
    end
    return value
end

local function destination(device_kind)
    return device_kind == "mtk" and MTK_SERVICE or "org.bluez"
end

local function dbus(device_kind, path, method, args)
    return "dbus-send --system --print-reply --reply-timeout=10000 --dest="
        .. destination(device_kind) .. " " .. path .. " " .. method .. (args or "")
end

local function property(device_kind, value)
    return dbus(device_kind, ADAPTER, PROPERTIES .. "." .. (value == nil and "Get" or "Set"),
        " string:org.bluez.Adapter1 string:Powered"
        .. (value == nil and "" or " variant:boolean:" .. tostring(value)))
end

local function log_adapter(device_kind, context)
    local output = query(dbus(device_kind, ADAPTER, PROPERTIES .. ".GetAll",
        " string:org.bluez.Adapter1"), "adapter-properties-" .. context, true)
    if output then
        logger.info("adapter snapshot context=", context, "kind=", device_kind,
            "data=", compact(output, 1600))
    end
end

local function log_processes(device_kind, context)
    local output = query("ps", "process-snapshot-" .. context, true)
    if not output then return end
    local matches = {}
    for line in output:gmatch("[^\r\n]+") do
        local lower = line:lower()
        if lower:find("mtkbtd", 1, true) or lower:find("btservice", 1, true)
                or lower:find("bluetoothd", 1, true) or lower:find("rtk_hciattach", 1, true)
                or lower:find("wpa_supplicant", 1, true) then
            matches[#matches + 1] = compact(line, 300)
        end
    end
    local log = #matches > 0 and logger.info or logger.warn
    log("Bluetooth process snapshot context=", context, "kind=", device_kind,
        "matches=", #matches, "data=", #matches > 0 and table.concat(matches, " | ") or "none")
end

local function log_sage_daemons(context)
    for _i, path in ipairs({ SAGE_HCI_LOG, SAGE_BLUEZ_LOG }) do
        local output = query("tail -n 80 " .. path, "sage-log-" .. tostring(_i) .. "-" .. context, true)
        logger.info("Sage daemon log context=", context, "path=", path,
            "data=", compact(output, 2400))
    end
end

local function parse_devices(output)
    local devices, device, property_name = {}, nil, nil
    local function finish_device()
        if device then
            device.address = device.address or device.path:match("/dev_(.+)$"):gsub("_", ":")
            device.id = device.path
            device.name = device.name or device.address
            devices[#devices + 1] = device
        end
    end
    for line in (output or ""):gmatch("[^\r\n]+") do
        local next_path = line:match('object path "(/org/bluez/hci0/dev_[%w_]+)"')
        if next_path then
            finish_device()
            device = { path = next_path }
            property_name = nil
        elseif device then
            for _i, name in ipairs({ "Address", "Name", "Paired", "Connected", "Trusted", "RSSI" }) do
                if line:find('string "' .. name .. '"', 1, true) then
                    property_name = name
                    break
                end
            end
            if property_name == "Address" or property_name == "Name" then
                local value = line:match('variant%s+string%s+"([^"]*)"')
                if value then device[property_name:lower()] = value end
            elseif property_name == "RSSI" then
                local value = line:match("variant%s+int16%s+(-?%d+)")
                if value then device.rssi = tonumber(value) end
            elseif property_name then
                local value = line:match("variant%s+boolean%s+(%w+)")
                if value then device[property_name:lower()] = value == "true" end
            end
            if line:find("variant", 1, true) then
                property_name = nil
            end
        end
    end
    finish_device()
    return devices
end

local function reconnect_paired(device_kind, attempted, poll)
    local output = query(dbus(device_kind, "/", "org.freedesktop.DBus.ObjectManager.GetManagedObjects"),
        "managed-objects-poll-" .. tostring(poll), true)
    if not output then return end
    local devices = parse_devices(output)
    local total, paired_count, connected_count, launched = 0, 0, 0, 0
    for _i, device in ipairs(devices) do
        total = total + 1
        if device.paired then paired_count = paired_count + 1 end
        if device.connected then connected_count = connected_count + 1 end
        logger.info("device snapshot poll=", poll, "path=", device.path,
            "address=", device.address, "name=", device.name,
            "paired=", tostring(device.paired), "connected=", tostring(device.connected),
            "trusted=", tostring(device.trusted), "rssi=", tostring(device.rssi))
        if device.paired and not device.connected and not attempted[device.path] then
            attempted[device.path] = true
            local command = dbus(device_kind, device.path, "org.bluez.Device1.Connect")
            logger.info("connect command path=", device.path, "command=", command,
                "reply=asynchronous-process-output")
            local ok, reason, code = os.execute(command .. " 2>&1 &")
            local success = succeeded(ok, code)
            launched = launched + (success and 1 or 0)
            local log = success and logger.info or logger.warn
            log("connect launch path=", device.path, "success=", tostring(success),
                "status=", tostring(ok), "reason=", tostring(reason), "code=", tostring(code))
        end
    end
    if total == 0 then
        logger.warn("discovery poll found no device objects poll=", poll,
            "output=", compact(output, 800))
    end
    logger.info("discovery poll summary poll=", poll, "kind=", device_kind,
        "devices=", total, "paired=", paired_count, "connected=", connected_count,
        "connects_launched=", launched)
end

local function release_standby(reason)
    if not standby_locked then return end
    require("ui/uimanager"):allowStandby()
    standby_locked = false
    logger.info("standby allowed", reason or "reconnect-complete")
end

local function stop_discovery()
    local device_kind = discovery_kind
    if not device_kind then
        release_standby()
        return true
    end
    local UIManager = require("ui/uimanager")
    local poll = discovery_poll
    local cancelled = manager_scanning and manager_scan_done
    discovery_kind, discovery_poll = nil, nil
    manager_scanning = false
    manager_scan_done = nil
    if poll then UIManager:unschedule(poll) end
    local stop_command = dbus(device_kind, ADAPTER, "org.bluez.Adapter1.StopDiscovery")
    local success = command_ok(stop_command, "discovery-stop")
    if not success then success = command_ok(stop_command, "discovery-stop-retry") end
    logger.info("discovery stopped kind=", device_kind, "success=", tostring(success))
    log_adapter(device_kind, "after-discovery-stop")
    if device_kind == "sage" then log_sage_daemons("after-discovery-stop") end
    release_standby()
    if cancelled then cancelled(false, "Cancelled.") end
    return success
end

function M.getDeviceList()
    local device_kind = kind()
    if not device_kind then return nil, "Bluetooth device management is unavailable on this Kobo." end
    local output = query(dbus(device_kind, "/", "org.freedesktop.DBus.ObjectManager.GetManagedObjects"),
        "manager-devices")
    if not output or output:find("Error", 1, true) then
        return nil, "Could not read Bluetooth devices."
    end
    return parse_devices(output)
end

function M.startScan(done)
    local device_kind = kind()
    if not device_kind then done(false, "Bluetooth device management is unavailable on this Kobo."); return end
    stop_discovery()
    if not command_ok(dbus(device_kind, ADAPTER, "org.bluez.Adapter1.StartDiscovery"),
            "manager-discovery-start") then
        done(false, "Could not start Bluetooth discovery.")
        return
    end
    local UIManager = require("ui/uimanager")
    discovery_kind = device_kind
    manager_scanning = true
    manager_scan_done = done
    discovery_poll = function()
        if not manager_scanning then return end
        manager_scanning = false
        manager_scan_done = nil
        local stopped = stop_discovery()
        done(stopped, stopped and nil or "Could not stop Bluetooth discovery.")
    end
    UIManager:scheduleIn(10, discovery_poll)
end

function M.stopScan()
    if manager_scanning then stop_discovery() end
end

function M.deviceAction(action, device)
    local device_kind = kind()
    if not device_kind then return false, "Bluetooth device management is unavailable on this Kobo." end
    local path = device and device.path
    if type(path) ~= "string" or not path:match("^/org/bluez/hci0/dev_[%x_]+$") then
        return false, "Invalid Bluetooth device."
    end
    local command
    if action == "forget" then
        command = dbus(device_kind, ADAPTER, "org.bluez.Adapter1.RemoveDevice",
            " objpath:" .. path)
    elseif action == "pair" or action == "connect" or action == "disconnect" then
        command = dbus(device_kind, path, "org.bluez.Device1."
            .. action:sub(1, 1):upper() .. action:sub(2))
    else
        return false, "Unsupported Bluetooth action."
    end
    if not command_ok(command, "manager-" .. action) then
        return false, "Bluetooth " .. action .. " failed."
    end
    return true
end

local function start_reconnect(device_kind)
    stop_discovery()
    local UIManager = require("ui/uimanager")
    UIManager:preventStandby()
    standby_locked = true
    logger.info("standby prevented during reconnect")
    local attempted = {}
    if not command_ok(dbus(device_kind, ADAPTER, "org.bluez.Adapter1.StartDiscovery"),
            "discovery-start") then
        logger.warn("Bluetooth discovery failed", device_kind)
        reconnect_paired(device_kind, attempted, 0)
        release_standby("reconnect-failed")
        return
    end

    logger.info("Bluetooth discovery started", device_kind)
    log_adapter(device_kind, "after-discovery-start")
    discovery_kind = device_kind
    local polls = 0
    discovery_poll = function()
        if discovery_kind ~= device_kind then
            logger.info("discovery poll skipped reason=stale kind=", device_kind)
            return
        end
        polls = polls + 1
        logger.info("discovery poll start poll=", polls, "max=10 kind=", device_kind)
        reconnect_paired(device_kind, attempted, polls)
        if polls < 10 then
            logger.info("discovery poll scheduled next_poll=", polls + 1, "delay_s=1")
            UIManager:scheduleIn(1, discovery_poll)
        else
            local attempted_count = 0
            for _path in pairs(attempted) do attempted_count = attempted_count + 1 end
            logger.info("discovery window complete polls=", polls,
                "connects_attempted=", attempted_count)
            stop_discovery()
        end
    end
    discovery_poll()
end

local function read_state(device_kind, verbose)
    local owner = query_bool("dbus-send --system --print-reply --reply-timeout=1500"
        .. " --dest=org.freedesktop.DBus /org/freedesktop/DBus"
        .. " org.freedesktop.DBus.NameHasOwner string:" .. destination(device_kind),
        "service-owner-" .. device_kind, verbose)
    local powered
    if owner == false then
        powered = false
    elseif owner then
        powered = query_bool(property(device_kind), "adapter-powered-" .. device_kind, verbose)
    end
    local signature = device_kind .. ":" .. tostring(owner) .. ":" .. tostring(powered)
    if verbose or signature ~= last_state_log then
        local log = (owner == nil or (powered == nil and owner ~= false)) and logger.warn or logger.info
        log("state snapshot kind=", device_kind, "destination=", destination(device_kind),
            "owner=", tostring(owner), "powered=", tostring(powered))
        last_state_log = signature
    end
    return powered
end

local function emit(enabled)
    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    logger.info("broadcast BluetoothStateChanged state=", tostring(enabled))
    UIManager:broadcastEvent(Event:new("BluetoothStateChanged", { state = enabled }))
end

local function power(device_kind, enabled)
    logger.info("power sequence start kind=", device_kind, "requested=", tostring(enabled))
    if device_kind == "mtk" then
        if enabled and not command_ok(dbus("mtk", "/", "com.kobo.bluetooth.BluedroidManager1.On"),
                "mtk-manager-on") then
            return false
        end
        if not command_ok(property("mtk", enabled), enabled and "mtk-adapter-power-on"
                or "mtk-adapter-power-off") then
            if enabled then
                command_ok(dbus("mtk", "/", "com.kobo.bluetooth.BluedroidManager1.Off"),
                    "mtk-manager-rollback-off")
            end
            return false
        end
        return enabled or command_ok(dbus("mtk", "/", "com.kobo.bluetooth.BluedroidManager1.Off"),
            "mtk-manager-off")
    end

    if device_kind == "sage" then
        local function stop_stack(operation)
            return command_ok("hciconfig hci0 down 2>/dev/null; "
                .. "killall bluetoothd 2>/dev/null; killall rtk_hciattach 2>/dev/null; "
                .. "i=0; while [ $i -lt 30 ] && (pgrep bluetoothd >/dev/null"
                .. " || pgrep rtk_hciattach >/dev/null); do sleep 0.1; i=$((i+1)); done; "
                .. "echo 0 > " .. SAGE_RFKILL, operation)
        end
        local function start_step(command, operation)
            if command_ok(command, operation) then return true end
            stop_stack("sage-start-rollback")
            return false
        end
        if enabled then
            if not start_step("killall rtk_hciattach 2>/dev/null; killall bluetoothd 2>/dev/null; "
                    .. "hciconfig hci0 down 2>/dev/null; true", "sage-stack-reset") then return false end
            if not start_step("echo 0 > " .. SAGE_RFKILL .. " && sleep 1 && echo 1 > "
                    .. SAGE_RFKILL, "sage-radio-power-cycle") then return false end
            if not start_step("/sbin/rtk_hciattach -n -s 115200 /dev/ttyS1 rtk_h5"
                    .. " > " .. SAGE_HCI_LOG .. " 2>&1 &", "sage-hci-attach") then return false end
            if not start_step("i=0; while [ $i -lt 50 ] && [ ! -e /sys/class/bluetooth/hci0 ]; "
                    .. "do sleep 0.1; i=$((i+1)); done; test -e /sys/class/bluetooth/hci0",
                    "sage-hci-wait") then return false end
            if not start_step("hciconfig hci0 up", "sage-hci-up") then return false end
            if not start_step("setsid /libexec/bluetooth/bluetoothd -n -d"
                    .. " > " .. SAGE_BLUEZ_LOG .. " 2>&1 &", "sage-bluetoothd-start") then return false end
            if not start_step("i=0; while [ $i -lt 50 ] && ! " .. property("sage")
                    .. " >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done",
                    "sage-adapter-wait") then return false end
            if not start_step(property("sage", true), "sage-adapter-power-on") then return false end
            return start_step("hciconfig hci0 2>/dev/null | grep -q 'UP RUNNING'",
                "sage-hci-verify")
        end

        local adapter_off = command_ok(property("sage", false), "sage-adapter-power-off")
        local stack_off = stop_stack("sage-stack-stop")
        return adapter_off and stack_off
    end

    local hci_process = device_kind == "clara2e" and "hciattach" or "rtk_hciattach"
    local hci_attach = device_kind == "clara2e"
        and "/sbin/hciattach -p ttymxc1 any 1500000 flow -t 20"
        or "/sbin/rtk_hciattach -s 115200 ttymxc1 rtk_h5"
    if enabled then
        if not command_ok("grep -q '^sdio_bt_pwr ' /proc/modules"
                .. " || insmod /drivers/mx6sll-ntx/wifi/sdio_bt_pwr.ko",
                device_kind .. "-load-power-module") then return false end
        if not command_ok("pgrep " .. hci_process .. " >/dev/null"
                .. " || " .. hci_attach .. " >/dev/null 2>&1",
                device_kind .. "-hci-attach") then return false end
        if not command_ok("pgrep bluetoothd >/dev/null"
                .. " || ( /libexec/bluetooth/bluetoothd >/dev/null 2>&1 & )",
                device_kind .. "-bluetoothd-start") then return false end
        if not command_ok("i=0; while [ $i -lt 50 ] && ! " .. property(device_kind)
                .. " >/dev/null 2>&1; do sleep 0.1; i=$((i+1)); done",
                device_kind .. "-adapter-wait") then return false end
        return command_ok(property(device_kind, true), device_kind .. "-adapter-power-on")
    end

    if not command_ok(property(device_kind, false), device_kind .. "-adapter-power-off") then return false end
    return command_ok("killall bluetoothd " .. hci_process .. " 2>/dev/null; "
        .. "i=0; while [ $i -lt 30 ] && (pgrep bluetoothd >/dev/null"
        .. " || pgrep " .. hci_process .. " >/dev/null); do sleep 0.1; i=$((i+1)); done; "
        .. "rmmod sdio_bt_pwr 2>/dev/null; true", device_kind .. "-stack-stop")
end

function M.isAvailable()
    local plugin = plugin_bluetooth()
    local device_kind = kind()
    local available = plugin ~= nil or device_kind ~= nil
    local signature = table.concat({ tostring(available), tostring(plugin ~= nil), tostring(device_kind) }, ":")
    if signature ~= last_availability_log then
        logger.info("availability available=", tostring(available),
            "source=", plugin and "kobo.koplugin" or device_kind and "native" or "none",
            "kind=", tostring(device_kind), "model=", tostring(Device.model))
        last_availability_log = signature
    end
    return available
end

function M.getState()
    local plugin = plugin_bluetooth()
    if plugin then return plugin:isBluetoothEnabled() end
    local device_kind = kind()
    if not device_kind then return nil end
    local now = os.time()
    if cached_at and now - cached_at < 2 then return cached_state end
    cached_state = read_state(device_kind, false)
    cached_at = now
    return cached_state
end

function M.setEnabled(enabled, complete)
    local callback_started = false
    local function finish_callback(success, from_plugin)
        if callback_started then return end
        callback_started = true
        if not complete then
            if success and from_plugin then emit(enabled) end
            return
        end
        if not success then complete(false); return end
        local UIManager = require("ui/uimanager")
        local attempts = 0
        local check
        check = function()
            attempts = attempts + 1
            cached_at = nil
            if M.getState() == enabled then
                if from_plugin then emit(enabled) end
                complete(true)
            elseif attempts >= 10 then
                complete(false)
            else
                UIManager:scheduleIn(0.5, check)
            end
        end
        check()
    end
    local plugin = plugin_bluetooth()
    if plugin then
        logger.info("delegating power request to kobo.koplugin requested=", tostring(enabled),
            "model=", tostring(Device.model))
        local UIManager = require("ui/uimanager")
        local timeout, finished
        local function plugin_done(success)
            if finished then return end
            finished = true
            if timeout then UIManager:unschedule(timeout) end
            finish_callback(success, true)
        end
        if enabled then
            if complete then
                timeout = function() plugin_done(false) end
                UIManager:scheduleIn(15, timeout)
            end
            local ok, result = pcall(plugin.turnBluetoothOn, plugin, false,
                function() plugin_done(true) end)
            if not ok or result == false then
                logger.warn("kobo.koplugin Bluetooth power-on failed", tostring(result))
                plugin_done(false)
                return false
            end
            return true
        end
        local ok, result = pcall(plugin.turnBluetoothOff, plugin, false)
        local success = ok and result ~= false
        if not success then logger.warn("kobo.koplugin Bluetooth power-off failed", tostring(result)) end
        plugin_done(success)
        return success
    end
    local device_kind = kind()
    logger.info("power request requested=", tostring(enabled), "model=", tostring(Device.model),
        "model_name=", tostring(Device.model_name), "kind=", tostring(device_kind),
        "is_kobo=", tostring(Device.isKobo and Device:isKobo()),
        "is_mtk=", tostring(Device.isMTK and Device:isMTK()),
        "firmware=", tostring(Device.firmware_version or Device.firmware_rev or Device.firmware),
        "koreader=", tostring(rawget(_G, "KO_VERSION")),
        "owned=", tostring(owned), "pending=", tostring(pending ~= nil),
        "discovery_active=", tostring(discovery_kind ~= nil),
        "nickel_persistent_setting=unchanged")
    log_nickel_settings("power-request")
    if not device_kind then
        logger.warn("power request rejected reason=unsupported-device")
        return false
    end
    if pending then
        logger.warn("power request rejected reason=request-pending")
        return false
    end
    local state = M.getState()
    logger.info("power request current state=", tostring(state), "requested=", tostring(enabled))
    if state == nil then
        logger.warn("power request rejected reason=state-unavailable kind=", device_kind)
        return false
    end
    local UIManager = require("ui/uimanager")
    if state == enabled then
        logger.info("power request no-op reason=already-in-state state=", tostring(state))
        if not enabled and owned then
            owned = false
            release_standby("already-off")
        end
        finish_callback(true)
        return true
    end

    local function finish()
        logger.info("power request executing kind=", device_kind, "requested=", tostring(enabled))
        if not enabled then stop_discovery() end
        local success = power(device_kind, enabled)
        cached_at = nil
        local verified = read_state(device_kind, true)
        cached_state, cached_at = verified, os.time()
        logger.info("power request result kind=", device_kind, "requested=", tostring(enabled),
            "command_success=", tostring(success), "verified_state=", tostring(verified))
        log_processes(device_kind, enabled and "after-power-on" or "after-power-off")
        if device_kind == "sage" then
            log_sage_daemons(enabled and "after-power-on" or "after-power-off")
        end
        if success and verified ~= enabled then
            logger.warn("power verification mismatch requested=", tostring(enabled),
                "verified_state=", tostring(verified))
        end
        if success then
            if enabled then
                owned = true
                start_reconnect(device_kind)
            elseif owned then
                owned = false
                release_standby("power-off")
            end
            emit(enabled)
        else
            logger.warn("Bluetooth power request failed", device_kind, tostring(enabled))
            if not enabled and owned and read_state(device_kind, true) == false then
                owned = false
                release_standby("fallback-shutdown")
                emit(false)
            end
        end
        logger.info("power request callback present=", tostring(complete ~= nil),
            "success=", tostring(success))
        finish_callback(success)
        return success
    end

    if device_kind == "mtk" and enabled then
        local NetworkMgr = require("ui/network/manager")
        local wifi_on = NetworkMgr:isWifiOn()
        logger.info("MTK Wi-Fi prerequisite wifi_on=", tostring(wifi_on))
        if not wifi_on then
            logger.info("MTK Wi-Fi restore requested delay_s=1")
            NetworkMgr:restoreWifiAsync()
            pending = function()
                logger.info("MTK Wi-Fi delay complete; starting Bluetooth power sequence")
                pending = nil
                finish()
                logger.info("MTK temporary Wi-Fi disable requested")
                NetworkMgr:disableWifi(nil, false)
            end
            UIManager:scheduleIn(1, pending)
            return true
        end
    end
    return finish()
end

function M.onSuspend()
    logger.info("suspend cleanup pending=", tostring(pending ~= nil),
        "discovery_active=", tostring(discovery_kind ~= nil), "owned=", tostring(owned))
    stop_discovery()
    if pending then
        require("ui/uimanager"):unschedule(pending)
        pending = nil
        logger.info("cancelled pending MTK power request; disabling temporary Wi-Fi")
        require("ui/network/manager"):disableWifi(nil, false)
    end
    if owned then
        cached_at = nil
        logger.info("suspend cleanup powering Bluetooth off")
        M.setEnabled(false)
    end
    logger.info("suspend cleanup complete owned=", tostring(owned))
end

return M
