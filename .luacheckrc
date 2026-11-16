unused_args = false
std = "luajit"
self = false

globals = {
    "G_reader_settings",
    "G_defaults",
    "ZenSpec",
    "table.pack",
    "table.unpack",
}

read_globals = {
    "_ENV",
}

exclude_files = {
    "dist/**",
}

-- Keep long-line cleanup incremental and allow intentional throwaway
-- locals like _i/_j (we avoid bare _ to keep gettext _() safe).
ignore = {
    "211/_.*", -- Unused local variable
    "231/_.*", -- Local variable is set but never accessed
    "631",    -- Line is too long
    "dummy",
}
