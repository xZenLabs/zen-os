local function apply_browser_hide_up_folder()
    local BD = require("ui/bidi")
    local FileChooser = require("ui/widget/filechooser")
    local paths = require("common/paths")

    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if not zen_plugin or type(zen_plugin.config) ~= "table" then
        return
    end

    local function is_enabled()
        local features = zen_plugin.config and zen_plugin.config.features
        return type(features) == "table" and features.browser_hide_up_folder == true
    end

    local config_default = {
        hide_up_folder = true,
    }

    local function loadConfig()
        local config = zen_plugin.config.browser_hide_up_folder or {}
        for k, v in pairs(config_default) do
            if config[k] == nil then
                config[k] = v
            end
        end
        zen_plugin.config.browser_hide_up_folder = config
        return config
    end

    local config = loadConfig()

    local Icon = {
        home = "home",
        up = BD.mirroredUILayout() and "back.top.rtl" or "back.top",
    }

    function FileChooser:_changeLeftIcon(icon, func)
        local titlebar = self.title_bar
        if not titlebar or not titlebar.left_button then return end
        titlebar.left_icon = icon
        titlebar.left_icon_tap_callback = func
        titlebar.left_button:setIcon(icon)
        titlebar.left_button.callback = func
    end

    local orig_FileChooser_genItemTable = FileChooser.genItemTable
    local orig_FileChooser_changeToPath = FileChooser.changeToPath

    function FileChooser:changeToPath(path, ...)
        if self._zen_opening_archive_root ~= true then
            self._zen_direct_archive_root = nil
        end
        self._zen_opening_archive_root = nil
        return orig_FileChooser_changeToPath(self, path, ...)
    end

    function FileChooser:genItemTable(dirs, files, path)
        local item_table = orig_FileChooser_genItemTable(self, dirs, files, path)
        if self._dummy or self.name ~= "filemanager" or type(path) ~= "string" then
            return item_table
        end

        local normalized = paths.normPath(path:gsub("/*$", ""))
        local force_hide_at_root = normalized == self._zen_direct_archive_root
            or paths.isHomeRoot(path) and paths.isHomeLocked()

        local enabled = is_enabled()
        if not enabled and not force_hide_at_root then
            return item_table
        end

        local items = {}
        local is_sub_folder = false
        for _i, item in ipairs(item_table) do
            if item.path:find("\u{e257}/") then
                table.insert(items, item)
            elseif item.is_go_up or item.text:find("\u{2B06} ..") then
                -- hide when at locked/zen home root, or when the setting says to
                if force_hide_at_root or (enabled and config.hide_up_folder) then
                    if not force_hide_at_root then
                        is_sub_folder = true  -- deeper level: show back icon
                    end
                else
                    table.insert(items, item)
                end
            else
                table.insert(items, item)
            end
        end

        self._left_tap_callback = self._left_tap_callback or self.title_bar.left_icon_tap_callback
        if is_sub_folder then
            self:_changeLeftIcon(Icon.up, function() self:onFolderUp() end)
        else
            self:_changeLeftIcon(Icon.home, self._left_tap_callback)
        end
        return items
    end

end


return apply_browser_hide_up_folder
