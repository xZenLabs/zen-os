-- BookSources.searchResults copies parts of KOReader's FileSearcher:getList
-- (locals there): which folders its walk enters, the system folders it skips
-- and how it prepares the search text. This runs KOReader's real getList
-- (its UI dependencies stubbed) over a folder tree and checks that
-- searchResults agrees, so a KOReader change to the walk fails here when
-- ZenOS's pinned KOReader is updated.
describe("book sources in file search, against KOReader's getList", function()
    local lfs = require("libs/libkoreader-lfs")
    local BookSources, FileSearcher, FileChooser
    local root, made

    local FOLDERS = { "", "/sub", "/sub/deep", "/.hidden", "/.hidden/inner", "/excluded",
        "/excluded/inner", "/other" }

    local function mkdir(path)
        assert(lfs.mkdir(path))
        made[#made + 1] = path
    end

    local function touch(path)
        local f = assert(io.open(path, "w"))
        f:close()
        made[#made + 1] = path
    end

    local function stub(name, module) ZenSpec.replace(name, module or {}) end

    before_each(function()
        made = {}
        root = os.tmpname()
        os.remove(root)
        mkdir(root)
        for _i, folder in ipairs(FOLDERS) do
            if folder ~= "" then mkdir(root .. folder) end
            -- One file per folder: the folders the walk enters are those whose
            -- files it offers to isFileMatch.
            touch(root .. folder .. "/marker.epub")
        end

        stub("common/zen_logger", { now = function() return 0 end,
            new = function() return { warn = function() end } end })
        stub("common/book_sources_kindle", { books = function() return {} end })
        FileChooser = {
            show_hidden = false,
            show_unsupported = false,
            show_dir = function(_self, name) return name ~= "excluded" end,
            show_file = function() return true end,
        }
        stub("ui/widget/filechooser", FileChooser)
        stub("document/documentregistry", {
            hasProvider = function(_self, path) return path:match("%.epub$") ~= nil end,
        })
        for _i, name in ipairs({ "ui/bidi", "ui/widget/booklist", "ui/widget/buttondialog",
                "ui/widget/checkbutton", "ui/widget/confirmbox", "device",
                "apps/filemanager/filemanagerconverter", "ui/widget/infomessage",
                "ui/widget/inputdialog", "ui/uimanager", "apps/filemanager/filemanagerutil" }) do
            stub(name)
        end
        stub("ui/widget/container/inputcontainer", { extend = function(_self, t) return t end })
        stub("gettext", setmetatable({ ngettext = function(a) return a end },
            { __call = function(_self, text) return text end }))
        -- Real util and ffi/util (getList's string helpers), not another
        -- spec's stubs.
        require("ffi/loadlib")
        ZenSpec.unload("util")
        ZenSpec.unload("ffi/util")
        ZenSpec.unload("apps/filemanager/filemanagerfilesearcher")
        FileSearcher = require("apps/filemanager/filemanagerfilesearcher")

        ZenSpec.unload("common/book_sources")
        BookSources = require("common/book_sources")
        -- A cloud book in every folder of the tree, and one outside it.
        local catalog = { { file = root .. "-elsewhere/cloud.epub", info = {} } }
        for _i, folder in ipairs(FOLDERS) do
            catalog[#catalog + 1] = { file = root .. folder .. "/cloud.epub", info = {} }
        end
        BookSources.register("cloud", {
            library = true,
            books = function() return catalog end,
            owns = function() return true end,
        })
    end)

    after_each(function()
        for i = #made, 1, -1 do os.remove(made[i]) end
        for _i, name in ipairs({ "apps/filemanager/filemanagerfilesearcher", "common/book_sources",
                "ui/widget/filechooser", "document/documentregistry", "gettext" }) do
            ZenSpec.unload(name)
        end
    end)

    -- A searcher whose isFileMatch records what it's asked and matches all.
    local function searcher(options)
        local asked = { folders = {}, queries = {} }
        -- use_patterns as KOReader's FileSearcher has it (absent in v2026.07 and earlier).
        local s = setmetatable({ case_sensitive = false, include_metadata = false,
            include_content = false, no_metadata_count = 0 }, { __index = FileSearcher })
        for key, value in pairs(options) do s[key] = value end
        function s:isFileMatch(_name, fullpath, query, is_file)
            asked.queries[query] = true
            if is_file then asked.folders[fullpath:match("^(.*)/[^/]+$")] = true end
            return true
        end
        return s, asked
    end

    local function sorted(set)
        local out = {}
        for key in pairs(set) do out[#out + 1] = key end
        table.sort(out)
        return out
    end

    local function walked(options)
        local s, asked = searcher(options)
        FileSearcher.search_path = root
        FileSearcher.search_string = options.text or "*"
        s:getList()
        return asked
    end

    local function source_folders(options)
        local s, asked = searcher(options)
        local folders = {}
        for _i, entry in ipairs(BookSources.searchResults(s, root, options.text or "*", {})) do
            folders[entry[2]:match("^(.*)/[^/]+$")] = true
        end
        return folders, asked
    end

    for _i, case in ipairs({
        { name = "with subfolders", options = { include_subfolders = true } },
        { name = "without subfolders", options = { include_subfolders = false } },
        { name = "with hidden folders shown", options = { include_subfolders = true }, show_hidden = true },
    }) do
        it("searches the folders the walk enters, " .. case.name, function()
            FileChooser.show_hidden = case.show_hidden == true
            local walk = walked(case.options)
            local expected = sorted(walk.folders)
            assert.is_true(#expected >= 1)
            assert.are.same(expected, sorted((source_folders(case.options))))
        end)
    end

    for _i, case in ipairs({
        { text = "Moby Dick" },
        { text = "Mo?y*.EPUB" },
        { text = "Mo?y*.EPUB", use_patterns = true },
        { text = "a.b", use_patterns = true },
        { text = "*" },
    }) do
        it("prepares the search text as getList does: " .. case.text, function()
            local options = { include_subfolders = true, use_patterns = case.use_patterns, text = case.text }
            local walk = walked(options)
            local _folders, asked = source_folders(options)
            assert.are.same(sorted(walk.queries), sorted(asked.queries))
        end)
    end

    it("skips the system folders getList skips", function()
        local path = package.searchpath("apps/filemanager/filemanagerfilesearcher", package.path)
        local f = assert(io.open(assert(path), "r"))
        local source = f:read("*a")
        f:close()
        local block = assert(source:match("local sys_folders = (%b{})"), "getList's sys_folders")
        local skipped = {}
        for folder in block:gmatch('%["([^"]+)"%]%s*=%s*true') do skipped[#skipped + 1] = folder end
        assert.is_true(#skipped > 0)

        local catalog = { { file = "/mnt/onboard/kept.epub", info = {} } }
        for _i, folder in ipairs(skipped) do
            catalog[#catalog + 1] = { file = folder .. "/skipped.epub", info = {} }
        end
        BookSources.register("cloud", {
            library = true,
            books = function() return catalog end,
            owns = function() return true end,
        })
        FileChooser.show_dir = function() return true end
        local s = searcher({ include_subfolders = true })
        local found = {}
        for _i, entry in ipairs(BookSources.searchResults(s, "/", "*", {})) do found[#found + 1] = entry[2] end
        assert.are.same({ "/mnt/onboard/kept.epub" }, found)
    end)
end)
