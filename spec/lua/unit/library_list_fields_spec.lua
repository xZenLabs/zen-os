describe("detailed list fields", function()
    it("preserves defaults and normalizes saved ordering without duplicates", function()
        local fields = require("common/library_list_fields")
        local defaults = require("config/defaults").browser_list_item_layout
        assert.are.same(defaults.order, fields.order())
        assert.is_true(fields.enabled(nil, "title"))
        assert.is_false(fields.enabled(nil, "filename"))
        assert.is_false(fields.enabled(nil, "filetype"))
        local config = { order = { "filename", "progress", "unknown", "title", "filename" },
            show = { title = false, filetype = true, progress = true } }
        local order = fields.order(config)
        assert.are.equal("filename", order[1])
        assert.are.equal("title", order[2])
        assert.are.equal(#defaults.order, #order)
        assert.is_false(fields.enabled(config, "title"))
        assert.is_true(fields.enabled(config, "filetype"))
        assert.is_true(fields.enabled(config, "pages"))
    end)
end)
