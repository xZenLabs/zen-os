local applied = false

local function apply_kobo_bluetooth_fix()
    if applied then return end

    local Device = require("device")
    if not (Device.isKobo and Device:isKobo() and Device.isMTK and Device:isMTK()) then return end

    local UIManager = require("ui/uimanager")
    local logger = require("common/zen_logger").new("kobo_bluetooth_fix")
    -- MTK Bluetooth use can make Nickel restart panic, even with the radio off (#12739).
    local orig_quit = UIManager.quit
    UIManager.quit = function(self, exit_code, ...)
        if exit_code ~= false and (exit_code or self._exit_code or 0) == 0
                and not self._entered_poweroff_stage
                and require("modules/menu/bluetooth/kobo_bluetooth").needsRebootOnExit() then
            logger.info("Rebooting after MTK Bluetooth use for safe Nickel startup")
            return self.reboot_action()
        end
        return orig_quit(self, exit_code, ...)
    end
    applied = true
end

return apply_kobo_bluetooth_fix
