-- Shared constant tables used across multiple modules.
-- Labels are plain English; callers apply _() for translation.
local M = {}

-- Separator presets for status bars (key = config value, label = display name).
-- Values are bar-specific and defined locally in each patch.
M.SEPARATOR_PRESETS = {
    { key = "dot",         label = "Middle dot"         },
    { key = "bar",         label = "Vertical bar"       },
    { key = "dash",        label = "Dash"               },
    { key = "bullet",      label = "Bullet"             },
    { key = "space",       label = "Space only"         },
    { key = "small-space", label = "Space only (small)" },
    { key = "none",        label = "No separator"       },
    { key = "custom",      label = "Custom"             },
}

M.FILEMANAGER_MINUTE_STATUS_ITEMS = { "time", "date", "battery", "disk", "ram" }

return M
