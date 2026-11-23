-- Button mappings for HID input devices (Bluetooth remotes, gamepads, keyboards).
-- config.hid_keys[address] = { { code, reader = <dispatcher actions>, library = ...,
--     keys = { reader = <key name> }, entries = { library = <launcher entry> } } }
local Device = require("device")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local logger = require("common/zen_logger").new("hid_keys")

local M = {
    SCREENS = { "reader", "library" },
    -- Native key names: only handled where the device itself has keys.
    KEYS = {
        { "LPgFwd", _("Page forward") }, { "LPgBack", _("Page back") },
        { "Up", _("Up") }, { "Down", _("Down") }, { "Left", _("Left") }, { "Right", _("Right") },
        { "Press", _("Press") }, { "Back", _("Back") }, { "Menu", _("Menu") },
    },
    -- One-tap choices offered ahead of the full action list: { dispatcher action, value, label }.
    -- No label: the dispatcher's own title, so Zen actions read "ZenOS: …" as everywhere else.
    COMMON = {
        reader = {
            { "page_jmp", 1, _("Next page") }, { "page_jmp", -1, _("Previous page") },
            { "next_chapter", true, _("Next chapter") }, { "prev_chapter", true, _("Previous chapter") },
            { "zen_ui_show_toc", true }, { "zen_ui_show_book_switcher", true },
            { "zen_ui_show_reader_controls", true }, { "zen_ui_show_page_browser", true },
            { "toggle_bookmark", true, _("Toggle bookmark") },
            { "zen_ui_show_home", true },
        },
        library = {
            { "open_previous_document", true, _("Open previous document") },
            { "zen_ui_show_home", true }, { "zen_ui_show_library", true }, { "zen_ui_show_stats", true },
        },
    },
}
for _k, presets in pairs(M.COMMON) do
    presets[#presets + 1] = { "toggle_frontlight", true, _("Toggle frontlight") }
    presets[#presets + 1] = { "night_mode", true, _("Toggle night mode") }
    presets[#presets + 1] = { "full_refresh", true, _("Full screen refresh") }
end
local EV_KEY = 1
local RESCAN_GAPS = { 2, 3, 7 } -- seconds; a link after power-on can take the whole reconnect window
local paths, addresses = {}, {} -- open HID nodes, oldest first; path -> address candidates, sysfs device
local active = {} -- code -> binding; the newest connected device wins a clash
local key_codes = {}
local capture, capture_timer, swallow, rescan_timer

local function config()
    local Manager = require("config/manager")
    return Manager.get() or Manager.load()
end

local function store()
    local cfg = config()
    cfg.hid_keys = cfg.hid_keys or {}
    return cfg.hid_keys
end

function M.supported()
    return Device.input ~= nil and type(Device.input.registerEventAdjustHook) == "function"
end

function M.screen()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    return ReaderUI and ReaderUI.instance and "reader" or "library"
end

-- KOReader reads evdev nodes itself. Elsewhere (PocketBook's InkView) keys arrive without a device,
-- and opening a node there would restart the platform's input loop.
local function evdev()
    local input = Device.input
    return input ~= nil and type(input.open) == "function" and not (input.input and input.input.is_ffi)
end

function M.refresh()
    active = {}
    local bindings, lists = store(), {}
    if evdev() then
        for _i, path in ipairs(paths) do
            lists[#lists + 1] = bindings[addresses[path][1]] or bindings[addresses[path][2]]
        end
    else -- no device to tell apart: every mapping applies, in a stable order
        local known = {}
        for address in pairs(bindings) do known[#known + 1] = address end
        table.sort(known)
        for _i, address in ipairs(known) do lists[#lists + 1] = bindings[address] end
    end
    for _i, list in ipairs(lists) do
        for _j, binding in ipairs(list) do active[binding.code] = binding end
    end
end

function M.save()
    require("config/manager").save(config())
    M.refresh()
end

function M.list(address)
    return store()[address] or {}
end

-- The device's binding for a code; a new one is stored with its first assignment.
function M.add(address, code)
    for _i, binding in ipairs(M.list(address)) do
        if binding.code == code then return binding end
    end
    return { code = code }
end

function M.remove(address, binding)
    local bindings = store()
    for index, candidate in ipairs(bindings[address] or {}) do
        if candidate == binding then table.remove(bindings[address], index) break end
    end
    if bindings[address] and #bindings[address] == 0 then bindings[address] = nil end
end

-- Drops every mapping of a device.
function M.clear(address)
    store()[address] = nil
end

-- The common action a single-action assignment matches, nil for anything else.
function M.preset(screen, actions)
    if type(actions) ~= "table" or require("dispatcher"):_itemsCount(actions) ~= 1 then return nil end
    for _i, preset in ipairs(M.COMMON[screen]) do
        if actions[preset[1]] == preset[2] then return preset end
    end
end

-- What a binding does on a screen, and its kind: "keys", "common", "actions" or the entry type.
-- nil when unassigned.
function M.label(binding, screen)
    local key = binding.keys and binding.keys[screen]
    if key then
        for _i, entry in ipairs(M.KEYS) do
            if entry[1] == key then return entry[2], "keys" end
        end
        return key, "keys"
    end
    local entry = binding.entries and binding.entries[screen]
    if entry then return entry.label, entry.type end
    local actions = binding[screen]
    local Dispatcher = require("dispatcher")
    if type(actions) ~= "table" or Dispatcher:_itemsCount(actions) == 0 then return nil end
    local preset = M.preset(screen, actions)
    return preset and preset[3] or Dispatcher:menuTextFunc(actions), preset and "common" or "actions"
end

local function key_code(name)
    if key_codes[name] == nil then
        key_codes[name] = false
        for code, mapped in pairs(Device.input.event_map) do
            if mapped == name and type(code) == "number" then
                key_codes[name] = code
                break
            end
        end
    end
    return key_codes[name]
end

-- A screen holds one assignment: dispatcher "actions", a native key ("keys") or a launcher
-- entry ("entries"). Only a binding that does something stays stored.
function M.assign(address, binding, screen, field, value)
    binding[screen] = field == "actions" and value or nil
    for _i, name in ipairs({ "keys", "entries" }) do
        local slots = binding[name]
        if name == field then
            binding[name] = slots or {}
            binding[name][screen] = value
        elseif slots then
            slots[screen] = nil
            if next(slots) == nil then binding[name] = nil end
        end
    end
    local used = false
    for _i, name in ipairs(M.SCREENS) do used = used or M.label(binding, name) ~= nil end
    local bindings = store()
    for _i, stored in ipairs(bindings[address] or {}) do
        if stored == binding then
            if not used then M.remove(address, binding) end
            return
        end
    end
    if used then
        bindings[address] = bindings[address] or {}
        table.insert(bindings[address], binding)
    end
end

-- Synthetic device events and touch/stylus tool buttons are never remote buttons.
local function ignored(code)
    return code == 0 or code >= 10000 or (code >= 320 and code <= 335)
end

-- Code 0 maps to nothing in event_map, so a neutralised event is dropped.
local function hook(_input, ev)
    if ev.type ~= EV_KEY or ignored(ev.code) then return end
    local code = ev.code
    if swallow == code then
        -- A fresh press means the release was lost; stop swallowing.
        if ev.value ~= 1 then
            if ev.value == 0 then swallow = nil end
            ev.code = 0
            return
        end
        swallow = nil
    end
    if capture then
        if ev.value ~= 1 then return end
        local done = capture
        M.stopCapture()
        swallow = code
        ev.code = 0
        UIManager:nextTick(function() done(code) end)
        return
    end
    local binding = active[code]
    if not binding then return end
    local screen = M.screen()
    local key = binding.keys and binding.keys[screen]
    if key then
        ev.code = key_code(key) or 0 -- press, repeat and release all follow
        return
    end
    local entry, actions = binding.entries and binding.entries[screen], binding[screen]
    if not entry and (type(actions) ~= "table" or next(actions) == nil) then return end
    ev.code = 0
    if ev.value ~= 1 then return end
    UIManager:nextTick(function()
        local ok, err = pcall(function()
            if entry then return require("modules/menu/app_launcher/entry_action")(entry) end
            require("dispatcher"):execute(actions)
        end)
        if not ok then logger.warn("action failed for button", code, tostring(err)) end
    end)
end

-- The next button press calls done(code) once; done(nil) on timeout.
function M.capture(done, seconds)
    M.stopCapture()
    capture = done
    capture_timer = function()
        capture, capture_timer = nil, nil
        done(nil)
    end
    UIManager:scheduleIn(seconds or 10, capture_timer)
end

function M.stopCapture()
    if capture_timer then UIManager:unschedule(capture_timer) end
    capture, capture_timer = nil, nil
end

local function forget(path)
    for index, open_path in ipairs(paths) do
        if open_path == path then table.remove(paths, index) break end
    end
    addresses[path] = nil
end

-- Fluoride reports the address byte-reversed, BlueZ as is.
function M._connect(path, uniq, sysfs)
    forget(path)
    paths[#paths + 1] = path
    addresses[path] = {
        uniq, (uniq:gsub("(%x%x):(%x%x):(%x%x):(%x%x):(%x%x):(%x%x)", "%6:%5:%4:%3:%2:%1")), sysfs = sysfs,
    }
    M.refresh()
end

-- The sysfs device behind a Bluetooth HID node: uhid (Fluoride, BLE on BlueZ), or the kernel's
-- own HID under the adapter (classic on BlueZ), whose device id starts with bus 0005.
local function hid_device(path)
    local node = type(path) == "string" and path:match("/(event%d+)$")
    local sysfs = node and require("ffi/util").realpath("/sys/class/input/" .. node)
    if sysfs and (sysfs:find("/uhid/", 1, true) or sysfs:find("/0005:%x+:%x+%.%x+/")) then
        return sysfs, node
    end
end

-- KOReader only opens keyboards itself; a remote's node is opened here.
-- The uevent beats udev creating the node, so a failed open is retried briefly.
function M.onInsert(path, attempt)
    local input = Device.input
    local sysfs, node = hid_device(path)
    if not (sysfs and evdev()) then return end
    -- A device that went away leaves its dead fd mapped to the path, and open would be skipped.
    if (input.opened_devices or {})[path] then pcall(input.close, input, path) end
    local ok, err = pcall(input.open, input, path)
    if not ok then
        attempt = attempt or 1
        if attempt < 5 then
            UIManager:scheduleIn(0.5, function() M.onInsert(path, attempt + 1) end)
        else
            logger.warn("could not open", path, tostring(err))
        end
        return
    end
    local file = io.open("/sys/class/input/" .. node .. "/device/uniq")
    local uniq = file and (file:read("*l") or ""):upper() or ""
    if file then file:close() end
    logger.info("opened", path)
    M._connect(path, uniq, sysfs)
end

-- Whether an open HID node belongs to this address: proof of HID where the stack hides the class.
function M.connected(address)
    address = address:upper()
    for _path, candidates in pairs(addresses) do
        if candidates[1] == address or candidates[2] == address then return true end
    end
    return false
end

function M.onRemove(path)
    if not addresses[path] then return end
    local input = Device.input
    if (input.opened_devices or {})[path] then pcall(input.close, input, path) end
    forget(path)
    M.refresh()
end

-- Opens HID nodes that appeared and drops the ones that went. A reconnect reuses the node name
-- with a new sysfs device, so that is what tells a stale node from a live one.
function M.rescan()
    local lfs = require("libs/libkoreader-lfs")
    if not evdev() or lfs.attributes("/sys/class/input", "mode") ~= "directory" then return end
    local present = {}
    for node in lfs.dir("/sys/class/input") do
        local path = "/dev/input/" .. node
        local sysfs = hid_device(path)
        if sysfs then
            present[path] = true
            if not (addresses[path] and addresses[path].sysfs == sysfs) then M.onInsert(path) end
        end
    end
    for path in pairs(addresses) do
        if not present[path] then M.onRemove(path) end
    end
end

-- Kobo reports no hotplug for uhid nodes: look again once a link has had time to come up.
function M.rescanSoon()
    if not evdev() then return end
    if rescan_timer then UIManager:unschedule(rescan_timer) end
    local attempt = 1
    rescan_timer = function()
        M.rescan()
        attempt = attempt + 1
        if RESCAN_GAPS[attempt] then
            UIManager:scheduleIn(RESCAN_GAPS[attempt], rescan_timer)
        else
            rescan_timer = nil
        end
    end
    UIManager:scheduleIn(RESCAN_GAPS[1], rescan_timer)
end

function M.init()
    local input = Device.input
    if not M.supported() or input._zen_hid_keys_hook then return end
    input._zen_hid_keys_hook = true
    input:registerEventAdjustHook(hook)
    M.rescan()
    M.refresh()
end

return M
