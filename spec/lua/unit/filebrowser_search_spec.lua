describe("file browser search", function()
    local close_button, close_count, closed, dialog, input_widget, search_files, searched_paths, stock_calls

    before_each(function()
        dialog = nil
        closed = nil
        close_count = 0
        close_button = nil
        search_files = nil
        searched_paths = {}
        stock_calls = {}
        _G.__ZEN_UI_PLUGIN = { config = { features = { search = true } } }

        local FileManagerFileSearcher = {
            onShowFileSearch = function()
                stock_calls.show = (stock_calls.show or 0) + 1
                return "stock search"
            end,
            isFileMatch = function()
                stock_calls.match = (stock_calls.match or 0) + 1
                return "stock match"
            end,
            getList = function(self)
                local path = self.search_path
                searched_paths[#searched_paths + 1] = path
                return {}, { { "book.epub", path .. "/book.epub" } }, 0
            end,
            doSearch = function(self)
                search_files = select(2, self:getList())
            end,
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
        ZenSpec.replace("common/paths", {
            getHomeDir = function() return "/library" end,
            normPath = function(path) return path end,
        })
        ZenSpec.replace("ui/trapper", {
            wrap = function(_, callback) callback() end,
        })
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
        ZenSpec.unload("ui/trapper")
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

    it("searches every non-overlapping home folder", function()
        local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
        _G.__ZEN_UI_PLUGIN.config.additional_home_dirs = {
            "/extra", "/library/nested", "/extra",
        }
        FileManagerFileSearcher.ui = { coverbrowser = {} }
        FileManagerFileSearcher:onShowFileSearch()
        dialog.getInputText = function() return "egg" end

        dialog.buttons[1][1].callback()

        assert.are.same({ "/extra", "/library" }, searched_paths)
        assert.are.equal(2, #search_files)
    end)

    describe("book sources' books without a file", function()
        local calls

        before_each(function()
            calls = { results = {}, opened = {}, prepared = 0 }
            ZenSpec.replace("common/book_sources", {
                searchResults = function(searcher, path, text, found)
                    calls.results[#calls.results + 1] = { searcher = searcher, path = path, text = text,
                        found = found }
                    return { { "cloud.epub", path .. "/cloud.epub", { mode = "file" } } }
                end,
                prepareFolderIndex = function() calls.prepared = calls.prepared + 1 end,
                ownsWithoutFile = function(path) return path:find("cloud", 1, true) ~= nil end,
                docProps = function(path) return { title = "Cloud", display_title = "Cloud " .. path } end,
                open = function(path) calls.opened[#calls.opened + 1] = path return true end,
            })
        end)

        after_each(function()
            ZenSpec.unload("common/book_sources")
        end)

        it("adds them to each home folder's results, after the files found there", function()
            local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
            _G.__ZEN_UI_PLUGIN.config.additional_home_dirs = { "/extra" }
            FileManagerFileSearcher.ui = { coverbrowser = {} }
            FileManagerFileSearcher:onShowFileSearch()
            dialog.getInputText = function() return "egg" end

            dialog.buttons[1][1].callback()

            assert.are.equal(1, calls.prepared)
            assert.are.same({ "/extra/book.epub", "/extra/cloud.epub", "/library/book.epub",
                "/library/cloud.epub" }, (function()
                    local out = {}
                    for _i, entry in ipairs(search_files) do out[#out + 1] = entry[2] end
                    return out
                end)())
            assert.are.equal(2, #calls.results)
            assert.are.equal("/extra", calls.results[1].path)
            assert.are.equal("egg", calls.results[1].text)
            assert.are.same({ ["/extra/book.epub"] = true }, calls.results[1].found)
        end)

        it("keeps the files found when a source's results fail", function()
            package.loaded["common/book_sources"].searchResults = function() error("source failed") end
            local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
            FileManagerFileSearcher.ui = { coverbrowser = {} }
            FileManagerFileSearcher:onShowFileSearch()
            dialog.getInputText = function() return "egg" end
            dialog.buttons[1][1].callback()
            assert.are.equal(1, #search_files)
        end)

        it("gives them their metadata and opens them through their source", function()
            local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
            local stock_selected = {}
            FileManagerFileSearcher.onShowSearchResults = function(self)
                self.booklist_menu = {
                    _manager = self,
                    ui = self.ui,
                    onMenuSelect = function(_menu, item) stock_selected[#stock_selected + 1] = item.path end,
                    updateItems = function() end,
                }
            end
            ZenSpec.unload("modules/filebrowser/patches/search")
            require("modules/filebrowser/patches/search")()
            FileManagerFileSearcher.search_results = {
                { is_file = true, path = "/library/cloud.epub" },
                { is_file = true, path = "/library/book.epub" },
                { is_file = true, path = "/library/cloud-kept.epub", doc_props = { title = "Kept" } },
            }
            local searcher = setmetatable({ ui = {} }, { __index = FileManagerFileSearcher })

            searcher:onShowSearchResults(true)

            local results = FileManagerFileSearcher.search_results
            assert.are.equal("Cloud /library/cloud.epub", results[1].doc_props.display_title)
            assert.is_nil(results[2].doc_props)
            assert.are.equal("Kept", results[3].doc_props.title)

            local menu = searcher.booklist_menu
            assert.is_true(menu.onMenuSelect(menu, results[1]))
            menu.onMenuSelect(menu, results[2])
            assert.are.same({ "/library/cloud.epub" }, calls.opened)
            assert.are.same({ "/library/book.epub" }, stock_selected)
            searcher.selected_files = {}
            menu.onMenuSelect(menu, results[1])
            assert.are.same({ "/library/book.epub", "/library/cloud.epub" }, stock_selected)
            assert.are.equal(1, #calls.opened)
        end)
    end)

    describe("literal matching of the typed text", function()
        local BookSources, searcher

        before_each(function()
            -- The table Zen search took when it was applied.
            require("document/documentregistry").hasProvider = function() return true end
            ZenSpec.replace("ui/widget/filechooser", {
                show_hidden = false,
                show_dir = function() return true end,
                show_file = function() return true end,
            })
            ZenSpec.unload("common/book_sources")
            BookSources = require("common/book_sources")
            BookSources.register("spec_cloud", {
                library = true,
                books = function()
                    return {
                        { file = "/library/Dune Vol. 1.epub", info = {} },
                        { file = "/library/a1.epub", info = {} },
                    }
                end,
                owns = function(path) return path:sub(1, 9) == "/library/" end,
            })
            local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
            searcher = setmetatable({
                include_metadata = true,
                no_metadata_count = 0,
                ui = { bookinfo = { getDocProps = function(_self, path)
                    if path == "/library/a1.epub" then return { title = "Dune Vol. 1" } end
                    return { title = "Other" }
                end } },
            }, { __index = FileManagerFileSearcher })
        end)

        after_each(function()
            BookSources.unregister("spec_cloud")
            ZenSpec.unload("common/book_sources")
            ZenSpec.unload("ui/widget/filechooser")
            require("apps/filemanager/filemanagerfilesearcher").search_string = nil
        end)

        local function found(typed)
            local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
            FileManagerFileSearcher.search_string = typed
            local out = {}
            for _i, entry in ipairs(BookSources.searchResults(searcher, "/library", typed, {})) do
                out[#out + 1] = entry[2]
            end
            table.sort(out)
            return out
        end

        for _i, use_patterns in ipairs({ true, false, "absent" }) do
            for _j, substring in ipairs({ true, false }) do
                it(("finds names and metadata: use_patterns %s, %s matching"):format(
                        tostring(use_patterns), substring and "substring" or "whole-word"), function()
                    if use_patterns == "absent" then searcher.use_patterns = nil
                    else searcher.use_patterns = use_patterns end
                    _G.__ZEN_UI_PLUGIN.config.search = { substring = substring }
                    local both = { "/library/Dune Vol. 1.epub", "/library/a1.epub" }
                    -- File name (first book) and title (second book).
                    assert.are.same(both, found("Vol. 1"))
                    assert.are.same(both, found("Vol"))
                    -- "." is no wildcard.
                    assert.are.same({}, found("Vol.1"))
                    assert.are.same({}, found("V.l"))
                end)
            end
        end
    end)

    it("uses KOReader file search when Zen Search is disabled", function()
        local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
        _G.__ZEN_UI_PLUGIN.config.features.search = false

        assert.are.equal("stock search", FileManagerFileSearcher:onShowFileSearch())
        assert.are.equal("stock match", FileManagerFileSearcher:isFileMatch())
        assert.are.same({ show = 1, match = 1 }, stock_calls)
    end)
end)
