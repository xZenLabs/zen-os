-- Button mappings for HID input devices (Bluetooth remotes, gamepads, keyboards).
-- config.hid_keys[address] = { { code, reader = <dispatcher actions>, library = ..., keys = { reader = <key name> } } }
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
local paths, addresses = {}, {} -- open uhid nodes, oldest first; path -> address candidates
local active = {} -- code -> binding; the newest connected device wins a clash
local key_codes = {}
local capture, capture_timer, swallow

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

function M.refresh()
    active = {}
    local bindings = store()
    for _i, path in ipairs(paths) do
        local list = bindings[addresses[path][1]] or bindings[addresses[path][2]]
        for _j, binding in ipairs(list or {}) do active[binding.code] = binding end
    end
end

function M.save()
    require("config/manager").save(config())
    M.refresh()
end

function M.list(address)
    return store()[address] or {}
end

function M.add(address, code)
    local bindings = store()
    bindings[address] = bindings[address] or {}
    for _i, binding in ipairs(bindings[address]) do
        if binding.code == code then return binding end
    end
    local binding = { code = code }
    table.insert(bindings[address], binding)
    return binding
end

function M.remove(address, binding)
    local bindings = store()
    for index, candidate in ipairs(bindings[address] or {}) do
        if candidate == binding then table.remove(bindings[address], index) break end
    end
    if bindings[address] and #bindings[address] == 0 then bindings[address] = nil end
end

-- The common action a single-action assignment matches, nil for anything else.
function M.preset(screen, actions)
    if type(actions) ~= "table" or require("dispatcher"):_itemsCount(actions) ~= 1 then return nil end
    for _i, preset in ipairs(M.COMMON[screen]) do
        if actions[preset[1]] == preset[2] then return preset end
    end
end

-- What a binding does on a screen, nil when unassigned.
function M.label(binding, screen)
    local key = binding.keys and binding.keys[screen]
    if key then
        for _i, entry in ipairs(M.KEYS) do
            if entry[1] == key then return entry[2] end
        end
        return key
    end
    local actions = binding[screen]
    local Dispatcher = require("dispatcher")
    if type(actions) ~= "table" or Dispatcher:_itemsCount(actions) == 0 then return nil end
    local preset = M.preset(screen, actions)
    return preset and preset[3] or Dispatcher:menuTextFunc(actions)
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
    local actions = binding[screen]
    if type(actions) ~= "table" or next(actions) == nil then return end
    ev.code = 0
    if ev.value ~= 1 then return end
    UIManager:nextTick(function()
        local ok, err = pcall(function() require("dispatcher"):execute(actions) end)
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
function M._connect(path, uniq)
    forget(path)
    paths[#paths + 1] = path
    addresses[path] = { uniq, (uniq:gsub("(%x%x):(%x%x):(%x%x):(%x%x):(%x%x):(%x%x)", "%6:%5:%4:%3:%2:%1")) }
    M.refresh()
end

-- KOReader only opens keyboards itself; a remote's node is opened here.
-- The uevent beats udev creating the node, so a failed open is retried briefly.
function M.onInsert(path, attempt)
    local input = Device.input
    local node = type(path) == "string" and path:match("/(event%d+)$")
    if not (node and input and type(input.open) == "function") then return end
    local sysfs = require("ffi/util").realpath("/sys/class/input/" .. node)
    if not (sysfs and sysfs:find("/uhid/", 1, true)) then return end
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
    M._connect(path, uniq)
end

function M.onRemove(path)
    if not addresses[path] then return end
    local input = Device.input
    if (input.opened_devices or {})[path] then pcall(input.close, input, path) end
    forget(path)
    M.refresh()
end

function M.init()
    local input = Device.input
    if not M.supported() or input._zen_hid_keys_hook then return end
    input._zen_hid_keys_hook = true
    input:registerEventAdjustHook(hook)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes("/sys/class/input", "mode") ~= "directory" then return end
    for node in lfs.dir("/sys/class/input") do
        if node:match("^event%d+$") then M.onInsert("/dev/input/" .. node) end
    end
end

return M
