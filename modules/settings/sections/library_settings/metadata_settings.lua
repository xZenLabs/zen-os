local UIManager = require("ui/uimanager")
local icons = require("common/inline_icon_map")
local IconItem = require("common/ui/icon_menu_item")
local HardcoverStore = require("config/hardcover_token")
local GoogleBooksStore = require("config/google_books_key")
local _ = require("gettext")

local M = {}
local TOKEN_URL = "https://hardcover.app/account/api"

local function masked_credential(value)
    if value == "" then return _("Not set") end
    if #value <= 4 then return "••••" end
    return "••••" .. value:sub(-4)
end

function M.build(ctx)
    local config = ctx.config or {}
    local plugin = ctx.plugin
    if type(config.metadata) ~= "table" then config.metadata = {} end
    local metadata = config.metadata

    local function save(touchmenu_instance)
        if plugin then plugin:saveConfig() end
        if touchmenu_instance then touchmenu_instance:updateItems() end
    end

    local function edit_credential(store, copy, touchmenu_instance)
        local InputDialog = require("ui/widget/inputdialog")
        local dlg
        dlg = InputDialog:new{
            title = copy.title,
            description = copy.description,
            input = store.get(),
            text_type = "password",
            buttons = {{
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dlg) end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = store.clean(dlg:getInputText())
                        if not value then
                            UIManager:show(require("ui/widget/infomessage"):new{
                                text = copy.invalid,
                            })
                            return
                        end
                        if not store.save(value) then
                            UIManager:show(require("ui/widget/infomessage"):new{
                                text = _("Metadata could not be saved."),
                            })
                            return
                        end
                        UIManager:close(dlg)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                },
            }},
        }
        UIManager:show(dlg)
        dlg:onShowKeyboard()
    end

    local function credential_items(store, copy)
        return {
            {
                text_func = function()
                    return copy.label .. " " .. masked_credential(store.get())
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    edit_credential(store, copy, touchmenu_instance)
                end,
            },
            {
                text = copy.clear,
                enabled_func = function() return store.get() ~= "" end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = copy.confirm,
                        ok_text = _("Clear"),
                        ok_callback = function()
                            if not store.clear() then
                                UIManager:show(require("ui/widget/infomessage"):new{
                                    text = copy.clear_failed,
                                })
                            end
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
        }
    end

    local hardcover_items = credential_items(HardcoverStore, {
        title = _("Hardcover API token"),
        description = _("Use a token limited to read:catalog. It is stored locally as plain text and is never logged."),
        invalid = _("Enter a valid Hardcover token without spaces."),
        label = _("Hardcover API token:"),
        clear = _("Clear Hardcover token"),
        confirm = _("Clear the saved Hardcover API token?"),
        clear_failed = _("The Hardcover token could not be cleared."),
    })
    hardcover_items[#hardcover_items + 1] = {
        text = _("Show Hardcover token-page QR code"),
        callback = function()
            local Device = require("device")
            local QRMessage = require("ui/widget/qrmessage")
            UIManager:show(QRMessage:new{
                text = TOKEN_URL,
                width = Device.screen:getWidth(),
                height = Device.screen:getHeight(),
            })
        end,
    }
    hardcover_items[#hardcover_items + 1] = {
        text = _("Open Hardcover token page"),
        callback = function() require("device"):openLink(TOKEN_URL) end,
    }

    local google_items = credential_items(GoogleBooksStore, {
        title = _("Google Books API key"),
        description = _("The key is stored locally as plain text and is never logged."),
        invalid = _("Enter a valid Google Books API key without spaces."),
        label = _("Google Books API key:"),
        clear = _("Clear Google Books API key"),
        confirm = _("Clear the saved Google Books API key?"),
        clear_failed = _("The Google Books API key could not be cleared."),
    })

    local function provider_item(name, key, sub_items)
        local item = {
            text = name,
            checked_func = function() return metadata[key] ~= false end,
        }
        local function toggle(touchmenu_instance)
            metadata[key] = metadata[key] == false
            save(touchmenu_instance)
        end
        if sub_items then
            item.checkmark_callback = toggle
            item.sub_item_table = sub_items
        else
            item.callback = toggle
        end
        return item
    end

    local item = {
        text = _("Metadata"),
        _zen_metadata_settings = true,
        sub_item_table = {
            provider_item(_("Hardcover"), "hardcover_enabled", hardcover_items),
            provider_item(_("Google Books"), "google_books_enabled", google_items),
            provider_item(_("Open Library"), "open_library_enabled"),
            {
                text = _("Match selection"),
                sub_item_table = {
                    {
                        text = _("Auto-pick best match"),
                        radio = true,
                        checked_func = function()
                            return metadata.hardcover_auto_match ~= false
                        end,
                        callback = function(touchmenu_instance)
                            metadata.hardcover_auto_match = true
                            save(touchmenu_instance)
                        end,
                    },
                    {
                        text = _("Choose match manually"),
                        radio = true,
                        checked_func = function()
                            return metadata.hardcover_auto_match == false
                        end,
                        callback = function(touchmenu_instance)
                            metadata.hardcover_auto_match = false
                            save(touchmenu_instance)
                        end,
                    },
                },
            },
            {
                text = _("Keep an EPUB metadata backup"),
                checked_func = function() return metadata.epub_backup == true end,
                callback = function(touchmenu_instance)
                    metadata.epub_backup = metadata.epub_backup ~= true
                    save(touchmenu_instance)
                end,
            },
        },
    }
    return IconItem.decorate(item, icons.edit)
end

M.cleanToken = HardcoverStore.clean
M.cleanGoogleKey = GoogleBooksStore.clean
M.maskedToken = masked_credential

return M
