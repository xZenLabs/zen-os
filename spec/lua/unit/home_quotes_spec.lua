describe("home quotes", function()
    local dofile_stub
    local HomeQuotes
    local state
    local book_mode
    local directory_entries
    local directory_path
    local sidecar_stat
    local flushes

    before_each(function()
        state = ZenSpec.memorySettings()
        flushes = 0
        state.flush = function() flushes = flushes + 1 end
        book_mode = "directory"
        directory_entries = { ".", ".." }
        directory_path = nil
        sidecar_stat = nil
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(path, field)
                if path:match("%.lua$") and field == "mode" then return "file" end
                if path:match("%.sdr/") then
                    if sidecar_stat then return sidecar_stat end
                    return "directory"
                end
                if path:match("^/books/") and field == "mode" then return book_mode end
                return "directory"
            end,
            dir = function(path)
                directory_path = path
                local index = 0
                return function()
                    index = index + 1
                    return directory_entries[index]
                end
            end,
            mkdir = function() return true end,
        })
        ZenSpec.replace("config/preset_store", {
            rootDir = function() return "/tmp/zen-ui-spec" end,
        })
        ZenSpec.replace("luasettings", {
            open = function() return state end,
        })
        ZenSpec.replace("modules/filebrowser/patches/home/quote_list", {
            { text = "Default quote", author = "Default author" },
        })
        dofile_stub = stub(_G, "dofile")
        ZenSpec.unload("modules/filebrowser/patches/home/home_quotes")
        HomeQuotes = require("modules/filebrowser/patches/home/home_quotes")
    end)

    after_each(function()
        dofile_stub:revert()
    end)

    it("uses only the default list when no sources are configured", function()
        assert.are.same({
            { text = "Default quote", author = "Default author" },
        }, HomeQuotes.getQuotes())
        assert.stub(dofile_stub).was_not_called()
    end)

    it("supports plain, legacy, and title-bearing custom quotes", function()
        dofile_stub.returns({
            "Plain quote",
            { text = "Legacy quote", author = "Legacy author" },
            {
                text = "Enhanced quote",
                author = "Enhanced author",
                title = "Enhanced title",
            },
        })

        assert.are.same({
            {
                text = "Plain quote",
                author = "",
                title = "",
                attribution = "",
            },
            {
                text = "Legacy quote",
                author = "Legacy author",
                title = "",
                attribution = "Legacy author",
            },
            {
                text = "Enhanced quote",
                author = "Enhanced author",
                title = "Enhanced title",
                attribution = "Enhanced author,  Enhanced title",
            },
        }, HomeQuotes.getQuotes({ sources = { custom = true } }))
    end)

    it("discovers named quote files and combines selected lists", function()
        directory_entries = {
            ".", "..", "quotes.lua", "wisdom.lua", "home.lua", "notes.txt",
        }
        dofile_stub.invokes(function(path)
            if path == "/tmp/zen-ui-spec/quotes/home.lua" then
                return { settings = {} }
            end
            return { path:match("([^/]+)%.lua$") }
        end)

        assert.are.same({ "quotes.lua", "wisdom.lua" }, HomeQuotes.listFiles())
        assert.are.equal("/tmp/zen-ui-spec/quotes", directory_path)
        assert.are.same({
            { text = "quotes", author = "", title = "", attribution = "" },
            { text = "wisdom", author = "", title = "", attribution = "" },
        }, HomeQuotes.getQuotes({
            sources = { custom = true },
            custom_files = {
                ["../outside.lua"] = true,
                ["quotes.lua"] = true,
                ["wisdom.lua"] = true,
            },
        }))
        assert.stub(dofile_stub).was_called_with(
            "/tmp/zen-ui-spec/quotes/wisdom.lua")
    end)

    it("combines selected sources", function()
        dofile_stub.returns({ { text = "Custom quote", author = "Custom author" } })

        local quotes = HomeQuotes.getQuotes({
            sources = { default = true, custom = true },
        })
        assert.are.equal("Default quote", quotes[1].text)
        assert.are.equal("Custom quote", quotes[2].text)
    end)

    it("falls back to defaults when selected sources are empty", function()
        dofile_stub.returns({})

        assert.are.same({
            { text = "Default quote", author = "Default author" },
        }, HomeQuotes.getQuotes({ sources = { custom = true } }))
    end)

    it("keeps a daily quote stable and advances a shuffled deck on refresh", function()
        dofile_stub.returns({
            "First",
            "Second",
            "Third",
        })
        local config = { sources = { custom = true } }

        local daily = HomeQuotes.selectQuote(config, "daily")
        assert.are.equal(daily.text, HomeQuotes.selectQuote(config, "daily").text)

        local refresh_two = HomeQuotes.selectQuote(config, "refresh")
        local refresh_three = HomeQuotes.selectQuote(config, "refresh")
        assert.are_not.equal(daily.text, refresh_two.text)
        assert.are_not.equal(daily.text, refresh_three.text)
        assert.are_not.equal(refresh_two.text, refresh_three.text)
    end)

    it("does not skip again after a manual swipe rebuild", function()
        dofile_stub.returns({
            "First",
            "Second",
            "Third",
        })
        local config = { sources = { custom = true } }
        HomeQuotes.selectQuote(config, "refresh")
        local stepped = HomeQuotes.stepQuote(config, 1)

        assert.are.equal(stepped.text, HomeQuotes.selectQuote(config, "refresh").text)
    end)

    it("does not rewrite an unchanged daily quote state", function()
        dofile_stub.returns({ "First", "Second" })
        local config = { sources = { custom = true } }

        local first, first_perf = HomeQuotes.selectQuote(config, "daily")
        local initial_flushes = flushes
        local second, second_perf = HomeQuotes.selectQuote(config, "daily")

        assert.are.equal(first.text, second.text)
        assert.are.equal(1, first_perf.state_writes)
        assert.are.equal(0, second_perf.state_writes)
        assert.are.equal(initial_flushes, flushes)
    end)

    it("collects annotation quotes from book sidecars", function()
        local open_calls = 0
        book_mode = "file"
        sidecar_stat = { modification = 1000, size = 128 }
        ZenSpec.replace("readhistory", {
            hist = {
                { file = "/books/annotated.epub" },
                { file = "/books/plain.epub" },
            },
        })
        ZenSpec.replace("docsettings", {
            findSidecarFile = function(_, file)
                if file:match("plain") then return nil end
                return file .. ".sdr/metadata.epub.lua"
            end,
            openSettingsFile = function(file)
                assert.are.equal(
                    "/books/annotated.epub.sdr/metadata.epub.lua", file)
                open_calls = open_calls + 1
                return { data = {
                    doc_props = { title = "Annotated", authors = "Writer" },
                    highlight = {
                        ["12"] = {
                            { drawer = "x", text = "A marked line", pos0 = 5 },
                        },
                    },
                } }
            end,
        })

        local quotes, perf = HomeQuotes.getQuotes({ sources = { annotations = true } })

        assert.are.equal(1, #quotes)
        assert.are.equal("A marked line", quotes[1].text)
        assert.are.equal("Annotated,  Writer", quotes[1].attribution)
        assert.are.equal("/books/annotated.epub", quotes[1].filepath)
        assert.are.equal(12, quotes[1].page)
        assert.is_true(quotes[1].is_annotation)
        assert.are.equal(2, perf.annotation_books)
        assert.are.equal(1, perf.sidecar_cache_misses)
    end)

    it("reuses parsed sidecar annotations on a later scan", function()
        local open_calls = 0
        book_mode = "file"
        sidecar_stat = { modification = 1000, size = 128 }
        ZenSpec.replace("readhistory", {
            hist = { { file = "/books/annotated.epub" } },
        })
        ZenSpec.replace("docsettings", {
            findSidecarFile = function(_, file)
                return file .. ".sdr/metadata.epub.lua"
            end,
            openSettingsFile = function(file)
                assert.are.equal(
                    "/books/annotated.epub.sdr/metadata.epub.lua", file)
                open_calls = open_calls + 1
                return { data = {
                    doc_props = { title = "Annotated", authors = "Writer" },
                    annotations = {
                        { drawer = "x", text = "First note", pos0 = 1 },
                    },
                } }
            end,
        })

        HomeQuotes.getQuotes({ sources = { annotations = true } })
        local parsed = open_calls

        HomeQuotes.invalidateAnnotations()
        local quotes, perf = HomeQuotes.getQuotes({ sources = { annotations = true } })

        assert.are.equal(1, #quotes)
        assert.are.equal(parsed, open_calls)
        assert.are.equal(1, perf.sidecar_cache_hits)
    end)
end)
