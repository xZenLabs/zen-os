require("ffi/loadlib")
describe("filebrowser natural title sort patch", function()
    local BookList
    local fallback_calls

    before_each(function()
        fallback_calls = 0
        BookList = {
            collates = {
                title = {
                    init_sort_func = function()
                        return function(a, b)
                            fallback_calls = fallback_calls + 1
                            return a.path < b.path
                        end
                    end,
                },
            },
        }
        ZenSpec.replace("ui/widget/booklist", BookList)
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.unload("modules/filebrowser/patches/add_sort_title_natural")
        require("modules/filebrowser/patches/add_sort_title_natural")()
    end)

    it("adds natural numeric ordering after removing leading articles", function()
        local less = BookList.collates.title_natural.init_sort_func()
        local items = {
            { doc_props = { display_title = "The Volume 10" } },
            { doc_props = { display_title = "Volume 2" } },
            { doc_props = { display_title = "Volume 1" } },
        }

        table.sort(items, less)

        assert.are.equal("Volume 1", items[1].doc_props.display_title)
        assert.are.equal("Volume 2", items[2].doc_props.display_title)
        assert.are.equal("The Volume 10", items[3].doc_props.display_title)
        assert.are.equal("Title natural", BookList.collates.title_natural.text)
    end)

    it("loads document properties through the collation item hook", function()
        local requested_path
        local item = { path = "/books/volume-2.epub" }
        local ui = {
            bookinfo = {
                getDocProps = function(_, path)
                    requested_path = path
                    return { display_title = "Volume 2" }
                end,
            },
        }

        BookList.collates.title_natural.item_func(item, ui)

        assert.are.equal(item.path, requested_path)
        assert.are.same({ display_title = "Volume 2" }, item.doc_props)
    end)

    it("patches regular title sorting and retains its tie breaker", function()
        local less = BookList.collates.title.init_sort_func()
        local first = {
            path = "/books/a.epub",
            doc_props = { display_title = "The Archive" },
        }
        local second = {
            path = "/books/b.epub",
            doc_props = { title = "Archive" },
        }

        assert.is_true(less(first, second))
        assert.are.equal(1, fallback_calls)

        local later = { path = "/books/c.epub", text = "The Zebra" }
        assert.is_true(less(second, later))
        assert.are.equal(1, fallback_calls)
    end)

    it("does not wrap regular title sorting more than once", function()
        require("modules/filebrowser/patches/add_sort_title_natural")()
        local less = BookList.collates.title.init_sort_func()

        assert.is_true(less(
            { path = "a", doc_props = { title = "The Same" } },
            { path = "b", doc_props = { title = "Same" } }
        ))
        assert.are.equal(1, fallback_calls)
    end)

    it("sorts accented titles with their base letters in both collations", function()
        for _i, mode in ipairs({ "title", "title_natural" }) do
            local items = {
                { path = "z", doc_props = { display_title = "Zulu" } },
                { path = "t", doc_props = { display_title = "Ținut" } },
                { path = "c", doc_props = { display_title = "The Čapek" } },
                { path = "d", doc_props = { display_title = "Delta" } },
            }
            table.sort(items, BookList.collates[mode].init_sort_func())
            assert.are.equal("The Čapek", items[1].doc_props.display_title)
            assert.are.equal("Delta", items[2].doc_props.display_title)
            assert.are.equal("Ținut", items[3].doc_props.display_title)
            assert.are.equal("Zulu", items[4].doc_props.display_title)
        end
    end)
end)
