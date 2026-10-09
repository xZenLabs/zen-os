-- settings/zen_settings_utils.lua
-- Pure utility functions shared across ZenOS settings sections.
-- No dependency on plugin instance or config at module level.

local _ = require("gettext")
local UIManager = require("ui/uimanager")
local Device = require("device")

local M = {}

-- ---------------------------------------------------------------------------
-- Generic helpers
-- ---------------------------------------------------------------------------

function M.first_non_empty(...)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" and v ~= "" then
            return v
        end
    end
    return nil
end

function M.normalize_value(v)
    if type(v) == "number" then
        v = tostring(v)
    end
    if type(v) ~= "string" then
        return nil
    end
    v = v:match("^%s*(.-)%s*$")
    if v == "" then
        return nil
    end
    return v
end

function M.get_path(tbl, path)
    local node = tbl
    for _i, key in ipairs(path) do
        node = node and node[key]
    end
    return node
end

function M.set_path(tbl, path, value)
    local node = tbl
    for i = 1, #path - 1 do
        local key = path[i]
        if type(node[key]) ~= "table" then
            node[key] = {}
        end
        node = node[key]
    end
    node[path[#path]] = value
end

-- ---------------------------------------------------------------------------
-- Version / device detection
-- ---------------------------------------------------------------------------

function M.get_plugin_version(plugin)
    local config = plugin and plugin.config
    local value = M.first_non_empty(
        plugin and plugin.version,
        plugin and plugin._meta and plugin._meta.version,
        config and config._meta and config._meta.version
    )
    if value then
        return value
    end

    local ok_meta, meta = pcall(require, "_meta")
    if ok_meta and type(meta) == "table" then
        value = M.first_non_empty(meta.version)
        if value then
            return value
        end
    end

    -- Reliable fallback: load _meta.lua directly from this plugin's root.
    local plugin_root = require("common/plugin_root")
    if plugin_root then
        local ok_file, file_meta = pcall(dofile, plugin_root .. "/_meta.lua")
        if ok_file and type(file_meta) == "table" then
            value = M.first_non_empty(file_meta.version)
            if value then
                return value
            end
        end
    end

    return "dev"
end

function M.get_koreader_version()
    local ok_version, version_mod = pcall(require, "version")
    if ok_version then
        if type(version_mod) == "string" and version_mod ~= "" then
            return version_mod
        end
        if type(version_mod) == "table" then
            local value = M.first_non_empty(
                version_mod.version,
                version_mod.short,
                version_mod.git,
                version_mod.git_rev,
                version_mod.build,
                version_mod.tag
            )
            if value then
                return value
            end
        end
    end

    local value = M.first_non_empty(
        rawget(_G, "KOREADER_VERSION"),
        rawget(_G, "KO_VERSION"),
        rawget(_G, "GIT_REV")
    )
    return value or "unknown"
end

function M.get_device_model_name()
    local function call_device_method(name)
        if not (Device and type(Device[name]) == "function") then
            return nil
        end
        local ok, value = pcall(Device[name], Device)
        value = ok and M.normalize_value(value) or nil
        if value then
            return value
        end
        ok, value = pcall(Device[name])
        return ok and M.normalize_value(value) or nil
    end

    local value = M.normalize_value(M.first_non_empty(
        Device and Device.model,
        Device and Device.model_name,
        Device and Device.device_model,
        Device and Device.product,
        Device and Device.name,
        Device and Device.friendly_name,
        Device and Device.id,
        rawget(_G, "DEVICE_MODEL")
    ))
    if value then
        return value
    end

    value = call_device_method("getModel")
        or call_device_method("getModelName")
        or call_device_method("getDeviceModel")
        or call_device_method("getFriendlyName")
        or call_device_method("getDeviceName")
    if value then
        return value
    end

    if Device and Device.isAndroid and Device:isAndroid() then
        local ok_model, model = pcall(function()
            local pipe = io.popen("getprop ro.product.model 2>/dev/null")
            if not pipe then return nil end
            local out = pipe:read("*l")
            pipe:close()
            return M.normalize_value(out)
        end)
        local ok_mfr, mfr = pcall(function()
            local pipe = io.popen("getprop ro.product.manufacturer 2>/dev/null")
            if not pipe then return nil end
            local out = pipe:read("*l")
            pipe:close()
            return M.normalize_value(out)
        end)
        if ok_model and model then
            if ok_mfr and mfr and not model:lower():find(mfr:lower(), 1, true) then
                return mfr .. " " .. model
            end
            return model
        end
    end

    return "Device"
end

function M.get_device_firmware_info()
    if not Device then return "n/a", nil, nil end

    local function normalize_fw_value(v)
        return M.normalize_value(v)
    end

    local function read_first_line(path)
        local f = io.open(path, "r")
        if not f then return nil end
        local line = f:read("*l")
        f:close()
        return normalize_fw_value(line)
    end

    -- Try the generic KOReader API first (works on Kobo, Kindle, etc.)
    if type(Device.getFirmwareVersion) == "function" then
        local calls = {
            function() return Device:getFirmwareVersion() end,
            function() return Device.getFirmwareVersion(Device) end,
            function() return Device.getFirmwareVersion() end,
        }
        for _i, get_fw in ipairs(calls) do
            local ok, value = pcall(get_fw)
            value = ok and normalize_fw_value(value) or nil
            if value then
                return value, "Device FW", "Device FW"
            end
        end
    end

    -- Common device fields
    local value = M.first_non_empty(
        Device.firmware,
        Device.firmware_version,
        Device.firmware_rev,
        Device.fw_version,
        Device.fw,
        Device.softwareVersion,
        rawget(_G, "KINDLE_FIRMWARE_VERSION"),
        rawget(_G, "KINDLE_FW_VERSION")
    )
    value = normalize_fw_value(value)
    if value then
        return value, "Device FW", "Device FW"
    end

    -- Kindle-specific files
    if Device.isKindle and Device:isKindle() then
        value = read_first_line("/etc/prettyversion.txt")
        if value then return value, "prettyversion", "prettyversion" end
        value = read_first_line("/etc/version.txt")
        if value then return value, "version", "version" end
    end

    -- Kobo-specific file: "N/A,N/A,4.38.21908" -> last field is FW version
    if Device.isKobo and Device:isKobo() then
        local raw = read_first_line("/mnt/onboard/.kobo/version")
        if raw then
            value = raw:match("([^,]+)$") or raw
            value = normalize_fw_value(value)
            if value then return value, "version", "version" end
        end
    end

    return "n/a", nil, nil
end

function M.get_device_firmware_version()
    local fw = M.get_device_firmware_info()
    return fw
end

function M.get_device_firmware_display()
    local fw = M.get_device_firmware_version()
    if fw == "n/a" then
        return fw
    end
    return fw
end

function M.get_device_disk_usage()
    local util = require("util")
    local path = M.first_non_empty(Device.home_dir) or require("datastorage"):getFullDataDir()
    local ok, usage = pcall(util.diskUsage, path)
    if not ok or type(usage) ~= "table" or not usage.total or usage.total <= 0 or not usage.used then
        return nil
    end
    usage.available = usage.available or math.max(0, usage.total - usage.used)
    return usage
end

function M.get_device_ram_usage()
    -- calcFreeMem reserves allocation headroom; display the unadjusted kernel values.
    local meminfo = require("util").readFromFile("/proc/meminfo")
    if not meminfo then return nil end
    local memory = {}
    for key, value in meminfo:gmatch("([%w_]+):%s*(%d+)%s+kB") do
        memory[key] = tonumber(value) * 1024
    end
    local total = memory.MemTotal
    local available = memory.MemAvailable
    if not available and memory.MemFree then
        available = memory.MemFree + (memory.Buffers or 0) + (memory.Cached or 0)
    end
    if not total or total <= 0 or not available then return nil end
    available = math.min(total, math.max(0, available))
    return { total = total, used = total - available, available = available }
end

function M.get_device_cpu_info()
    local util = require("util")
    local fields, cpus = {}, {}
    for line in (util.readFromFile("/proc/cpuinfo") or ""):gmatch("[^\n]+") do
        local key, value = line:match("^%s*(.-)%s*:%s*(.-)%s*$")
        if key then
            fields[key] = fields[key] or value
            if key == "processor" and tonumber(value) then cpus[#cpus + 1] = tonumber(value) end
        end
    end
    local present = util.readFromFile("/sys/devices/system/cpu/present")
    if present then
        cpus = {}
        for first, last in present:gmatch("(%d+)%-?(%d*)") do
            for index = tonumber(first), tonumber(last) or tonumber(first) do
                cpus[#cpus + 1] = index
            end
        end
    end
    local info = {
        model = M.first_non_empty(fields.Hardware, fields["model name"], fields.Processor),
        cores = #cpus > 0 and #cpus or nil,
    }
    for _i, index in ipairs(cpus) do
        local path = "/sys/devices/system/cpu/cpu" .. index .. "/cpufreq/"
        local current = tonumber((util.readFromFile(path .. "cpuinfo_cur_freq")))
            or tonumber((util.readFromFile(path .. "scaling_cur_freq")))
        local maximum = tonumber((util.readFromFile(path .. "cpuinfo_max_freq")))
        if current and current > 0 then
            info.current_min_khz = math.min(info.current_min_khz or current, current)
            info.current_max_khz = math.max(info.current_max_khz or current, current)
        end
        if maximum and maximum > 0 then
            info.max_khz = math.max(info.max_khz or maximum, maximum)
        end
    end
    if not info.current_min_khz then
        local mhz = tonumber(fields["cpu MHz"])
        if mhz and mhz > 0 then
            info.current_min_khz, info.current_max_khz = mhz * 1000, mhz * 1000
        end
    end
    return info
end

function M.get_device_ip_address()
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then return nil end
    local ok_posix = pcall(require, "ffi/posix_h")
    if not ok_posix then return nil end

    local C = ffi.C
    local ok_network, NetworkMgr = pcall(require, "ui/network/manager")
    local interface = ok_network and NetworkMgr and NetworkMgr.interface or nil
    if not interface and ok_network and NetworkMgr and type(NetworkMgr.getNetworkInterfaceName) == "function" then
        local ok_interface, value = pcall(NetworkMgr.getNetworkInterfaceName, NetworkMgr)
        interface = ok_interface and value or nil
    end

    local ifaddrs = ffi.new("struct ifaddrs *[1]")
    if C.getifaddrs(ifaddrs) ~= 0 then return nil end

    local selected
    local fallback
    local ifa = ifaddrs[0]
    while ifa ~= nil do
        if ifa.ifa_addr ~= nil and ifa.ifa_addr.sa_family == C.AF_INET then
            local host = ffi.new("char[?]", C.NI_MAXHOST)
            local result = C.getnameinfo(
                ifa.ifa_addr,
                ffi.sizeof("struct sockaddr_in"),
                host,
                C.NI_MAXHOST,
                nil,
                0,
                C.NI_NUMERICHOST
            )
            local address = result == 0 and M.normalize_value(ffi.string(host)) or nil
            if address and address:sub(1, 4) ~= "127." then
                local name = ffi.string(ifa.ifa_name)
                if name == interface then
                    selected = address
                    break
                end
                fallback = fallback or address
            end
        end
        ifa = ifa.ifa_next
    end
    C.freeifaddrs(ifaddrs[0])
    return selected or fallback
end

function M.get_device_language()
    local lang_code
    local ok_gs, gs = pcall(function() return G_reader_settings end)
    if ok_gs and gs and type(gs.readSetting) == "function" then
        lang_code = M.normalize_value(gs:readSetting("language"))
    end
    lang_code = lang_code
        or M.normalize_value(rawget(_G, "DLANGUAGE"))
        or M.normalize_value(os.getenv("LANG") or os.getenv("LC_ALL") or os.getenv("LC_MESSAGES"))

    if not lang_code then return "unknown" end

    -- Resolve human-readable name via KOReader's Language module ("C" = English).
    local ok_lm, Language = pcall(require, "ui/language")
    if ok_lm and Language and type(Language.getLanguageName) == "function" then
        local name = Language:getLanguageName(lang_code)
        if name and name ~= lang_code then
            return name
        end
    end
    return "unknown"
end

-- ---------------------------------------------------------------------------
-- Navigation helpers
-- ---------------------------------------------------------------------------

function M.get_last_dir()
    return G_reader_settings:readSetting("lastdir") or "/"
end

function M.get_current_dir()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok and FileManager and FileManager.instance
    if fm and fm.file_chooser and fm.file_chooser.path then
        return fm.file_chooser.path
    end
    return M.get_last_dir()
end

function M.newImagePathChooser(options)
    local BookInfoManager = require("bookinfomanager")
    local mode = BookInfoManager:getSetting("filemanager_display_mode")
    local list = type(mode) == "string" and mode:sub(1, 5) == "list_"
    local CoverMenu = require("covermenu")
    local Layout = require(list and "listmenu" or "mosaicmenu")

    options.display_mode_type = list and "list" or "mosaic"
    options.updateItems = CoverMenu.updateItems
    options.onCloseWidget = CoverMenu.onCloseWidget
    options._recalculateDimen = Layout._recalculateDimen
    options._updateItemsBuildUI = Layout._updateItemsBuildUI
    options._do_cover_images = true
    options._do_hint_opened = false
    if list then
        options._do_filename_only = true
        options.files_per_page = require("common/cover_utils").getFilesPerPage()
    else
        options.nb_cols_portrait = BookInfoManager:getSetting("nb_cols_portrait") or 3
        options.nb_rows_portrait = BookInfoManager:getSetting("nb_rows_portrait") or 3
        options.nb_cols_landscape = BookInfoManager:getSetting("nb_cols_landscape") or 4
        options.nb_rows_landscape = BookInfoManager:getSetting("nb_rows_landscape") or 2
        options._do_center_partial_rows = false
    end
    return require("ui/widget/pathchooser"):new(options)
end

-- ---------------------------------------------------------------------------
-- Time / value picker dialogs
-- ---------------------------------------------------------------------------

function M.fmt_time(h, m)
    return string.format("%02d:%02d", h, m)
end

function M.show_time_picker(title, h, m, callback)
    UIManager:show(require("ui/widget/doublespinwidget"):new{
        title_text      = title,
        left_text       = _("Hour"),
        left_value      = h,
        left_min        = 0,
        left_max        = 23,
        left_step       = 1,
        left_hold_step  = 3,
        left_precision  = "%02d",
        right_text      = _("Minute"),
        right_value     = m,
        right_min       = 0,
        right_max       = 59,
        right_step      = 1,
        right_hold_step = 15,
        right_precision = "%02d",
        callback        = callback,
    })
end

function M.show_value_picker(title, value, callback, min, max)
    UIManager:show(require("common/ui/zen_slider_dialog"):new{
        title     = title,
        value     = value,
        value_min = min or 0,
        value_max = max or 24,
        callback  = callback,
    })
end

-- ---------------------------------------------------------------------------
-- Menu item factories
-- ---------------------------------------------------------------------------

--- Build a simple checked toggle item for a named feature flag.
-- @param feature   string key in config.features
-- @param enable_text  display text for the item
-- @param config    plugin config table
-- @param save_and_apply  function(feature) that saves + re-applies
function M.make_enable_feature_item(feature, enable_text, config, save_and_apply)
    return {
        text = enable_text,
        checked_func = function()
            return config.features[feature] == true
        end,
        callback = function()
            config.features[feature] = config.features[feature] ~= true
            save_and_apply(feature)
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Ordering helpers
-- ---------------------------------------------------------------------------

function M.order_items_by_text(item_table, preferred_order)
    local by_text = {}
    local ordered = {}
    local used = {}

    for _i, item in ipairs(item_table) do
        if type(item.text) == "string" and item.text ~= "" then
            if by_text[item.text] == nil then
                by_text[item.text] = item
            end
        end
    end

    for _i, text in ipairs(preferred_order) do
        local item = by_text[text]
        if item then
            table.insert(ordered, item)
            used[item] = true
        end
    end

    for _i, item in ipairs(item_table) do
        if not used[item] then
            table.insert(ordered, item)
        end
    end

    return ordered
end

function M.reorder_nested_items_by_text(item_table, target_text, preferred_order)
    for _i, item in ipairs(item_table) do
        if item.text == target_text and type(item.sub_item_table) == "table" then
            item.sub_item_table = M.order_items_by_text(item.sub_item_table, preferred_order)
            return true
        end
        if type(item.sub_item_table) == "table" then
            local found = M.reorder_nested_items_by_text(item.sub_item_table, target_text, preferred_order)
            if found then
                return true
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Color picker sub-menu builder
-- ---------------------------------------------------------------------------

--- Build a color-picker sub-menu item (text_func + sub_item_table).
--- opts fields:
---   label        string         prefix for the parent item text_func
---   get          function()     returns current {r,g,b} or nil
---   set          function(r,g,b) apply and save the new color
---   reset        function or nil  if provided, prepends a "Default" preset
---   default_text string         shown after label when get() is nil (default: "Default")
---   reset_text   string         text of the "Default" sub-item (defaults to default_text)
---   dialog_title string         InputDialog title
---   presets      table          list of {text, r, g, b}
---   enabled_func function or nil
function M.buildColorSubMenu(opts)
    local get          = opts.get
    local set          = opts.set
    local reset        = opts.reset
    local label        = opts.label
    local default_text = opts.default_text or _("Default")
    local reset_text   = opts.reset_text   or default_text
    local dialog_title = opts.dialog_title or _("Custom RGB")
    local presets      = opts.presets or {}

    local function fmt(c)
        return string.format("%d,%d,%d", c[1], c[2], c[3])
    end

    local sub_items = {}

    if reset then
        table.insert(sub_items, {
            text = reset_text,
            checked_func = function() return get() == nil end,
            callback = function() reset() end,
        })
    end

    for _i, p in ipairs(presets) do
        local pr, pg, pb = p.r, p.g, p.b
        table.insert(sub_items, {
            text = p.text,
            checked_func = function()
                local c = get()
                return type(c) == "table" and c[1] == pr and c[2] == pg and c[3] == pb
            end,
            callback = function() set(pr, pg, pb) end,
        })
    end

    table.insert(sub_items, {
        text_func = function()
            local c = get()
            if c then return _("Custom RGB") .. " (" .. fmt(c) .. ")" end
            return _("Custom RGB")
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local InputDialog = require("ui/widget/inputdialog")
            local c = get() or { 0, 0, 0 }
            local dlg
            dlg = InputDialog:new{
                title = dialog_title,
                input = fmt(c),
                hint = _("Format: R,G,B (0-255)"),
                buttons = {{
                    {
                        text = _("Cancel"),
                        id = "close",
                        callback = function() UIManager:close(dlg) end,
                    },
                    {
                        text = _("Set"),
                        is_enter_default = true,
                        callback = function()
                            local text = dlg:getInputText() or ""
                            local r, g, b = text:match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$")
                            if r and g and b then
                                set(
                                    math.max(0, math.min(255, tonumber(r))),
                                    math.max(0, math.min(255, tonumber(g))),
                                    math.max(0, math.min(255, tonumber(b)))
                                )
                                UIManager:close(dlg)
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end
                        end,
                    },
                }},
            }
            UIManager:show(dlg)
            dlg:onShowKeyboard()
        end,
    })

    local item = {
        text_func = function()
            local c = get()
            if c then return label .. fmt(c) end
            return label .. default_text
        end,
        sub_item_table = sub_items,
    }
    if opts.enabled_func then item.enabled_func = opts.enabled_func end
    return item
end

return M
