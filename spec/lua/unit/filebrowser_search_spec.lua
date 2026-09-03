describe("file browser search", function()
    local close_button, close_count, closed, dialog, input_widget

    before_each(function()
        dialog = nil
        closed = nil
        close_count = 0
        close_button = nil
        _G.__ZEN_UI_PLUGIN = { config = { features = { search = true } } }

        local FileManagerFileSearcher = {
            onShowFileSearch = function() end,
            isFileMatch = function() end,
            updateItemTable = function() end,
            onMenuHold = function() end,
            onShowSearchResults = function() end,
        }
        ZenSpec.replace("apps/filemanager/filemanagerfilesearcher", FileManagerFileSearcher)
        ZenSpec.replace("ui/widget/inputdialog", {
            onTap = function() end,
            new = function(_, spec)
                dialog = spec
                input_widget = {
                    name = "input",
                    keyboard = {
                        key_events = { Close = { { "Back" } } },
                    },
                }
                dialog._input_widget = input_widget
                dialog.title_bar = {}
                dialog.layout = { { input_widget } }
                dialog.selected = { x = 1, y = 1 }
                dialog.onShowKeyboard = function() end
                return dialog
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            close = function(_, widget)
                closed = widget
                close_count = close_count + 1
            end,
            show = function() end,
        })
        ZenSpec.replace("common/paths", { getHomeDir = function() return "/library" end })
        ZenSpec.replace("common/ui/zen_modal_close", {
            installDialog = function(target, callback)
                close_button = { file = "/zen-ui/icons/close.svg", callback = callback }
                target.title_bar.right_button = close_button
                table.insert(target.layout, 1, { close_button })
                target.selected.y = target.selected.y + 1
                return close_button
            end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("util", { stringLower = string.lower })
        ZenSpec.replace("document/documentregistry", { hasProvider = function() return false end })

        ZenSpec.unload("modules/filebrowser/patches/search")
        require("modules/filebrowser/patches/search")()
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = nil
        ZenSpec.unload("modules/filebrowser/patches/search")
    end)

    it("places a focusable bundled close button at the top right", function()
        local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
        FileManagerFileSearcher:onShowFileSearch()

        assert.is_nil(dialog.title_bar.left_button)
        assert.is_true(dialog.title_bar.right_button == close_button)
        assert.are.equal("/zen-ui/icons/close.svg", close_button.file)
        assert.is_true(dialog.layout[1][1] == close_button)
        assert.is_true(dialog.layout[2][1] == input_widget)
        assert.are.same({ x = 1, y = 2 }, dialog.selected)

        close_button.callback()
        assert.is_true(closed == dialog)
    end)

    it("closes the full dialog with hardware Back", function()
        local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
        FileManagerFileSearcher:onShowFileSearch()

        assert.is_function(dialog.onCloseDialog)
        assert.is_nil(input_widget.keyboard.key_events.Close)
        assert.are.same({ "Back" },
            input_widget.keyboard.key_events.ZenCloseFileSearchDialog[1])
        assert.are.equal("ZenCloseFileSearchDialog",
            input_widget.keyboard.key_events.ZenCloseFileSearchDialog.event)

        assert.is_true(input_widget.keyboard:onZenCloseFileSearchDialog())
        assert.is_true(closed == dialog)
        assert.are.equal(1, close_count)
    end)

    it("matches books but not folders with the same search text", function()
        local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")

        assert.is_true(FileManagerFileSearcher:isFileMatch(
            "Invincible Presents - Atom Eve 03.cbz",
            "/library/Invincible Presents - Atom Eve 03.cbz",
            "atom",
            true))
        assert.is_false(FileManagerFileSearcher:isFileMatch(
            "Invincible Presents - Atom Eve & Rex Splode",
            "/library/Invincible Presents - Atom Eve & Rex Splode",
            "atom"))
    end)
end)
