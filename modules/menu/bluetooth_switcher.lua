local M = {}
local active_menu

function M.cancelScan()
    if not active_menu then return false end
    return active_menu.cancelScan()
end

function M.open(on_changed, settings_subpage, plugin)
    local Device = require("device")
    local Bluetooth = require("modules/menu/bluetooth/bluetooth")
    local Kindle = require("modules/menu/bluetooth_adapters/kindle")
    local Kobo = require("modules/menu/bluetooth_adapters/kobo")
    local PocketBook = require("modules/menu/bluetooth_adapters/pocketbook")
    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    local Menu = require("ui/widget/menu")
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local InfoMessage = require("ui/widget/infomessage")
    local Size = require("ui/size")
    local IconItem = require("common/ui/icon_menu_item")
    local SettingsTitleBar = require("common/ui/zen_settings_titlebar")
    local icons = require("common/inline_icon_map")
    local utils = require("common/utils")
    local T = require("ffi/util").template
    local _ = require("gettext")
    local plugin_root = require("common/plugin_root")
    local more_icon = utils.resolveIcon(plugin_root and plugin_root .. "/icons/",
        "app_menu")
    local backend = Kindle.isSupported(Device) and Kindle
        or Kobo.isSupported(Device) and Kobo
        or PocketBook.isSupported(Device) and PocketBook
    if not backend then
        UIManager:show(InfoMessage:new{text = _("Bluetooth device management is unavailable on this device.")})
        return false
    end
    local adapter = backend.new()
    local closed, busy, busy_device, busy_text, scanning = false, false, nil, nil, false
    local scan_sequence = 0
    local scan_warning
    local operation_error
    local devices = {}
    local menu, render, show_actions, start, offer_mapping, offer_unmapping
    IconItem.installMenuPatch()

    local function status_items(message)
        return {{
            text = message, _zen_settings_row = true,
            _zen_display_text = message, select_enabled = false,
        }}
    end
    local function show_status(message)
        if closed then return end
        menu:switchItemTable(nil, status_items(message))
        UIManager:forceRePaint()
    end
    local function notify_changed()
        UIManager:broadcastEvent(Event:new("BluetoothStateChanged"))
        if on_changed then on_changed() end
    end
    -- known_only: paired/connected devices ahead of a scan; a failed read stays quiet.
    local function load_devices(selected_address, known_only)
        if closed then return false end
        local list, err = adapter.getDeviceList(known_only)
        if not list then
            if not known_only then
                show_status(adapter.id ~= "kindle" and err or _("Could not read Bluetooth devices."))
            end
            return false
        end
        devices = list
        table.sort(devices, function(left, right)
            local left_rank = left.connected and 2 or left.paired and 1 or 0
            local right_rank = right.connected and 2 or right.paired and 1 or 0
            if left_rank ~= right_rank then return left_rank > right_rank end
            if left.rssi ~= right.rssi then
                return (tonumber(left.rssi) or -999) > (tonumber(right.rssi) or -999)
            end
            return (left.name or ""):lower() < (right.name or ""):lower()
        end)
        render(selected_address)
        return true
    end
    local function operate(action, device, follow_connect)
        if closed or busy then return end
        busy = true
        busy_device = device.address
        busy_text = (action == "connect" or follow_connect) and _("Connecting…") or _("Updating…")
        operation_error = nil
        render(device.address)
        adapter[action](device, function(ok, err)
            if closed then return end
            busy = false
            busy_device = nil
            if not ok then
                operation_error = {
                    address = device.address,
                    text = action == "connect" and _("Could not connect")
                        or err or T(_("Could not update %1."), device.name),
                }
                render(device.address)
                return
            end
            notify_changed()
            load_devices(device.address)
            if action == "forget" then return offer_unmapping(device) end
            if action ~= "connect" and not follow_connect then return end
            for _i, current in ipairs(devices) do
                if current.address == device.address then
                    if follow_connect and not current.connected then return operate("connect", current) end
                    return offer_mapping(current)
                end
            end
        end)
    end
    -- Transport and class where the adapter knows them: "BT", "BTLE", "BT HID", "BTLE HID".
    local function kind(device)
        if device.le == nil and not device.hid then return nil end
        return (device.le and "BTLE" or "BT") .. (device.hid and " HID" or "")
    end
    local function show_info(device)
        local status = device.connected and _("Connected")
            or device.paired and _("Paired") or _("Available")
        UIManager:show(InfoMessage:new{text = table.concat({
            _("Device") .. ": " .. device.name,
            _("Address") .. ": " .. device.address,
            _("Type") .. ": " .. (kind(device) or "—"),
            _("Status") .. ": " .. status,
            _("Signal") .. ": " .. (device.rssi and tostring(device.rssi) .. " dBm" or "—"),
        }, "\n")})
    end
    -- The Kindle HID setup only takes effect after a full device restart: no way out but the button.
    local function ask_hid_reboot()
        UIManager:show(ConfirmBox:new{
            text = _("A full device reboot is required."),
            dismissable = false,
            no_ok_button = true,
            cancel_text = _("Restart Kindle"),
            cancel_callback = adapter.reboot,
        })
    end
    -- Kindle HID devices need one-time system changes: ask first; a failed setup undoes itself.
    local function with_hid_setup(device, proceed)
        if not (device.hid and adapter.hidSetupNeeded) then return proceed() end
        if not adapter.hidSetupNeeded() then
            if adapter.hidRebootNeeded() then return ask_hid_reboot() end
            return proceed()
        end
        UIManager:show(ConfirmBox:new{
            text = _("Remotes and controllers need a one-time change to this Kindle's system files. Apply it now?"),
            ok_text = _("Apply"),
            ok_callback = function()
                if adapter.setupHid() then return ask_hid_reboot() end
                UIManager:show(InfoMessage:new{
                    text = _("Could not set up remotes and controllers. The changes were undone."),
                })
            end,
        })
    end
    local function pair(device)
        with_hid_setup(device, function() operate("pair", device, true) end)
    end
    -- Devices paired before the setup existed still get asked here. capture: straight to a button press.
    local function map_buttons(device, capture)
        with_hid_setup(device, function()
            require("modules/menu/bluetooth_keys").show(device, plugin, capture)
        end)
    end
    -- A remote does nothing until its buttons have actions: offered whenever one connects.
    offer_mapping = function(device)
        if not ((device.hid or device.le) and require("common/hid_keys").supported()) then return end
        UIManager:show(ConfirmBox:new{
            text = T(_("Assign actions to the buttons on %1?"), device.name),
            ok_text = _("Map buttons"),
            cancel_text = _("Not now"),
            ok_callback = function() map_buttons(device, true) end,
        })
    end
    -- Mappings outlive a forgotten device, ready for its next pairing, unless dropped here.
    offer_unmapping = function(device)
        local Keys = require("common/hid_keys")
        if #Keys.list(device.address) == 0 then return end
        UIManager:show(ConfirmBox:new{
            text = T(_("Forget the saved button mappings for %1 as well?"), device.name),
            ok_text = _("Forget"),
            cancel_text = _("Keep"),
            ok_callback = function()
                Keys.clear(device.address)
                Keys.save()
            end,
        })
    end
    show_actions = function(device)
        local dialog
        local buttons = {}
        local function add(icon, label, callback)
            buttons[#buttons + 1] = {{
                text = icon .. "  " .. label, align = "left",
                callback = function()
                    UIManager:close(dialog)
                    callback()
                end,
            }}
        end
        add(icons.details, _("Info"), function() show_info(device) end)
        if device.connected then
            add(icons.wifi_off, _("Disconnect"), function() operate("disconnect", device) end)
        elseif device.paired then
            add(icons.connect, _("Connect"), function() operate("connect", device) end)
        else
            add(icons.connect, _("Pair"), function() pair(device) end)
        end
        local Keys = require("common/hid_keys")
        if device.paired and Keys.supported()
                and (device.hid or device.connected and Keys.connected(device.address)) then
            add(icons.keyboard, _("Map buttons"), function() map_buttons(device) end)
        end
        if device.paired then
            add(icons.delete, _("Forget"), function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Forget Bluetooth device %1?"), device.name),
                    ok_text = _("Forget"),
                    ok_callback = function() operate("forget", device) end,
                })
            end)
        end
        dialog = ButtonDialog:new{
            title = device.name, buttons = buttons, width_factor = 0.5,
            anchor = function()
                for _i, row in ipairs(menu.item_group or {}) do
                    if row.entry and row.entry.device == device
                            and menu.dimen and menu.item_dimen then
                        local popup = dialog:getContentSize()
                        local inset = Size.padding.large + Size.padding.default
                        local border = menu.border_size or 0
                        local header_h = menu.title_bar and menu.title_bar:getSize().h or 0
                        local icon_size = IconItem.SETTINGS_CARET_SIZE
                        local icon_x = (menu.dimen.x or 0) + border
                            + menu.item_dimen.w - inset - icon_size
                        local icon_y = (menu.dimen.y or 0) + border + header_h
                            + (_i - 1) * menu.item_dimen.h
                            + math.floor((menu.item_dimen.h - icon_size) / 2)
                        return {
                            x = math.max(Size.padding.large,
                                icon_x + icon_size - popup.w - Size.padding.default),
                            y = icon_y, w = icon_size, h = icon_size,
                        }
                    end
                end
            end,
        }
        UIManager:show(dialog)
    end
    render = function(selected_address)
        if closed then return end
        local note = scanning and _("Searching for devices…") or scan_warning
        if #devices == 0 then
            show_status(note or _("No Bluetooth devices found."))
            return
        end
        local rows, selected_index = {}, nil
        for _i, device in ipairs(devices) do
            local status = device.connected and _("Connected")
                or device.paired and _("Paired") or _("Available")
            local detail = { status, kind(device), device.rssi and tostring(device.rssi) .. " dBm" or nil }
            for index = #detail, 1, -1 do
                if not detail[index] then table.remove(detail, index) end
            end
            local row = {
                text = device.name, device = device,
                _zen_settings_row = true,
                _zen_display_text = device.name,
                _zen_settings_breadcrumb = busy_device == device.address and busy_text
                    or operation_error and operation_error.address == device.address
                        and operation_error.text
                    or table.concat(detail, " · "),
                _zen_value_black = true,
                _zen_primary_bold = device.connected == true,
                _zen_has_submenu = device.connected == true,
                _zen_caret_icon = device.connected and more_icon or nil,
                icon_glyph = device.connected and icons.bluetooth_on or nil,
                callback = function()
                    if device.connected then
                        show_actions(device)
                    elseif device.paired then
                        operate("connect", device)
                    else
                        pair(device)
                    end
                end,
            }
            rows[#rows + 1] = row
            if device.address == selected_address then selected_index = #rows end
        end
        if note then rows[#rows + 1] = status_items(note)[1] end
        menu:switchItemTable(nil, rows, selected_index)
    end

    local function close_menu()
        if menu then return menu:onClose() end
    end
    local title_bar = SettingsTitleBar:new{
        back_callback = close_menu,
        back_hold_callback = function()
            return require("modules/settings/zen_settings_page").backToRoot() or close_menu()
        end,
        back_visible = settings_subpage == true,
        close_visible = settings_subpage ~= true,
        close_callback = close_menu, plugin = plugin,
        search_visible = false, title = _("Bluetooth devices"), title_full_width = true,
        action = {
            file = utils.resolveLocalIcon(plugin_root and plugin_root .. "/icons/", "quick_sync"),
            callback = function() start() end,
        },
        toggle = {
            value_func = function()
                local state = Bluetooth.getCachedState()
                if state ~= nil then return state end
                return Bluetooth.isEnabled()
            end,
            callback = function()
                if closed or busy then return end
                if not Bluetooth.isEnabled() then start(); return end
                busy = true
                Bluetooth.setEnabled(false, function(ok, err)
                    if closed then return end
                    busy = false
                    if not ok then
                        show_status(err or _("Could not change Bluetooth power."))
                        return
                    end
                    devices = {}
                    scan_warning = nil
                    notify_changed()
                    show_status(_("Off"))
                end)
            end,
        },
    }
    menu = Menu:new{
        name = "bluetooth_switcher", title = _("Bluetooth devices"),
        custom_title_bar = title_bar,
        item_table = status_items(_("Searching for devices…")),
        items_per_page = 8,
        items_font_size = IconItem.getSettingsFontSize(),
        items_mandatory_font_size = math.max(12, IconItem.getSettingsFontSize() - 4),
        is_borderless = true, is_popout = false,
        close_callback = function()
            title_bar:clearStatusRefresh()
            closed = true
            if active_menu == menu then active_menu = nil end
            adapter.close()
        end,
    }
    title_bar:clearStatusRefresh()
    title_bar.show_parent = menu
    title_bar:clear()
    title_bar:init()
    title_bar.root_icon.skip_paint = true
    if settings_subpage then
        menu.onCloseZenSettingsSubpages = close_menu
        local original_swipe = menu.onSwipe
        menu.onSwipe = function(self, arg, gesture)
            if gesture and gesture.direction == "east" and gesture.pos
                    and gesture.pos.x <= self.dimen.w * 0.33 then
                return self:onClose()
            end
            if original_swipe then return original_swipe(self, arg, gesture) end
        end
    end
    menu.onMenuSelect = function(self, row)
        if row.select_enabled == false then return true end
        self:onMenuChoice(row)
        return true
    end
    menu.onMenuHold = function(_self, row)
        if row and row.device then show_actions(row.device) end
        return true
    end
    menu.cancelScan = function()
        if closed or not scanning then return false end
        scanning = false
        scan_sequence = scan_sequence + 1
        if adapter.cancelScan then
            adapter.cancelScan()
        else
            adapter.close()
            adapter = backend.new()
        end
        render()
        return true
    end

    local function scan()
        if closed then return end
        scan_sequence = scan_sequence + 1
        local sequence = scan_sequence
        -- Known devices first, usable while the search runs. Kindle's discovered list is
        -- stale until the scan ends, so it starts from the paired and connected ones.
        local kindle = adapter.id == "kindle"
        if not load_devices(nil, kindle) then
            if not kindle then scanning = false; return end
            devices = {}
            render()
        end
        adapter.scan(function(ok, err)
            if closed or sequence ~= scan_sequence then return end
            scanning = false
            if ok then
                load_devices()
            else
                scan_warning = err or _("Bluetooth scan failed.")
                render()
            end
        end)
    end
    start = function()
        if closed or scanning or busy then return end
        scanning = true
        scan_warning = nil
        operation_error = nil
        if Bluetooth.isEnabled() then scan(); return end
        show_status(_("Turning on Bluetooth…"))
        Bluetooth.setEnabled(true, function(ok, err)
            if closed or not scanning then return end
            if not ok then
                scanning = false
                show_status(err or _("Could not turn on Bluetooth."))
                return
            end
            notify_changed()
            scan()
        end)
    end
    active_menu = menu
    UIManager:show(menu)
    UIManager:forceRePaint()
    UIManager:tickAfterNext(start)
    return true
end

return M
