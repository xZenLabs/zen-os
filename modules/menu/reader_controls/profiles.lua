local Settings = require("modules/menu/reader_controls/settings")
local Themes = require("common/reader_themes")
local util = require("util")
local _ = require("gettext")

local M = {}
local BOOK_TYPES = {
    font_family_fonts = "table", css = "string", style_tweaks_enabled = "boolean", style_tweaks = "table",
    book_style_tweak = "string", book_style_tweak_enabled = "boolean", text_lang = "string",
    text_lang_embedded_langs = "boolean", hyphenation = "boolean", hyph_trust_soft_hyphens = "boolean",
    hyph_soft_hyphens_only = "boolean", hyph_force_algorithmic = "boolean", floating_punctuation = "number",
    txt_preformatted = "number", hide_nonlinear_flows = "boolean", partial_rerendering = "boolean",
    flipping_zoom_mode = "string", flipping_scroll_mode = "boolean",
}

function M.capture(reader, plugin, name, include_theme)
    reader:saveSettings()
    local profile = util.tableDeepCopy(reader.profiles:getProfileFromCurrentBookSettings(name))
    local snapshot = { version = 1, group = Settings.group(reader), values = {}, book = {} }
    local represented = {}
    for key in pairs(profile) do represented[key:gsub("^kopt_", "")] = true end
    for key in pairs(Settings.options(reader)) do
        local value = reader.document.configurable[key]
        if value ~= nil and not represented[key] and not key:find("fine_tune", 1, true) then
            snapshot.values[key] = util.tableDeepCopy(value)
        end
    end
    for key in pairs(BOOK_TYPES) do
        snapshot.book[key] = { value = util.tableDeepCopy(reader.doc_settings:readSetting(key)) }
    end
    if include_theme then snapshot.theme = Themes.capture(plugin) end
    profile.settings.zen_reader = snapshot
    return profile
end

local function valid_value(value, current)
    if type(value) ~= type(current) then return false end
    if type(value) == "number" then return value == value and math.abs(value) < math.huge end
    if type(value) ~= "table" then return type(value) == "string" or type(value) == "boolean" end
    for key, part in pairs(value) do
        if type(key) ~= "number" or not valid_value(part, current[key]) then return false end
    end
    return true
end

function M.restore(reader, plugin, snapshot)
    if type(snapshot) ~= "table" or snapshot.version ~= 1
            or snapshot.group ~= Settings.group(reader) then return false end
    for name, value in pairs(type(snapshot.values) == "table" and snapshot.values or {}) do
        if valid_value(value, reader.document.configurable[name]) then
            Settings.apply(reader, name, util.tableDeepCopy(value))
        end
    end
    for key, record in pairs(type(snapshot.book) == "table" and snapshot.book or {}) do
        if BOOK_TYPES[key] and type(record) == "table"
                and (record.value == nil or type(record.value) == BOOK_TYPES[key]) then
            reader.doc_settings:saveSetting(key, util.tableDeepCopy(record.value))
        end
    end
    -- Re-read only presentation modules; progress and annotations never enter the snapshot.
    for _i, name in ipairs({ "typography", "styletweak", "typeset" }) do
        local module = reader[name]
        if module and module.onReadSettings then
            module:onReadSettings(reader.doc_settings)
        end
    end
    if reader.font then
        reader.font.font_family_fonts = reader.doc_settings:readSetting("font_family_fonts") or {}
        if reader.font.updateFontFamilyFonts then reader.font:updateFontFamilyFonts() end
    end
    if reader.rolling then
        local hide = reader.doc_settings:readSetting("hide_nonlinear_flows")
        if hide ~= nil and hide ~= reader.rolling.hide_nonlinear_flows and reader.rolling.onToggleHideNonlinear then
            reader.rolling:onToggleHideNonlinear()
        end
        local partial = reader.doc_settings:readSetting("partial_rerendering")
        if partial ~= nil and reader.document.enablePartialRerendering then
            reader.rolling.partial_rerendering = partial
            reader.document:enablePartialRerendering(partial)
        end
    end
    if reader.paging then
        for _i, key in ipairs({ "flipping_zoom_mode", "flipping_scroll_mode" }) do
            local value = reader.doc_settings:readSetting(key)
            if value ~= nil then reader.paging[key] = value end
        end
    end
    if type(snapshot.theme) == "table" then Themes.restore(plugin, snapshot.theme) end
    return true
end

function M.install(plugin)
    local Dispatcher = require("dispatcher")
    if Dispatcher._zen_reader_profiles then return end
    Dispatcher._zen_reader_profiles = true
    local execute = Dispatcher.execute
    function Dispatcher:execute(actions, exec_props)
        local snapshot = actions and actions.settings and actions.settings.zen_reader
        local quickmenu = exec_props and exec_props.qm_show
        if quickmenu == nil then quickmenu = actions and actions.settings and actions.settings.show_as_quickmenu end
        local ReaderUI = package.loaded["apps/reader/readerui"]
        local reader = ReaderUI and ReaderUI.instance
        if not snapshot or quickmenu or actions.settings.execute_one_by_one or not reader then
            return execute(self, actions, exec_props)
        end
        if snapshot.group ~= Settings.group(reader) or snapshot.version ~= 1 then
            require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
                text = _("This reader profile is not compatible with the current document."),
            })
            return
        end
        -- One batched update so CRE re-renders once, not once per restored option.
        local UIManager = require("ui/uimanager")
        local Event = require("ui/event")
        UIManager:broadcastEvent(Event:new("BatchedUpdate"))
        local ok, result = pcall(function()
            M.restore(reader, plugin, snapshot)
            return execute(self, actions, exec_props)
        end)
        UIManager:broadcastEvent(Event:new("BatchedUpdateDone"))
        if not ok then error(result) end
        reader:saveSettings()
        return result
    end
end

return M
