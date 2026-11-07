describe("reader controls book info", function()
    local BookInfo
    local shown

    before_each(function()
        shown = nil
        ZenSpec.replace("common/ui/zen_arrange_list", { show = function(options) shown = options end })
        ZenSpec.unload("modules/menu/reader_controls/book_info")
        BookInfo = require("modules/menu/reader_controls/book_info")
    end)

    it("normalizes order and enabled fields", function()
        local info = BookInfo.normalize{
            order = { "pages", "unknown", "pages", "read_time" },
            enabled = { read_time = false, time_remaining = "invalid", pages = false, unknown = false },
        }
        assert.are.same({
            "pages", "read_time", "time_remaining", "pages_today", "time_today", "progress",
        }, info.order)
        assert.are.same({
            read_time = false, time_remaining = true, pages_today = false,
            time_today = false, pages = false, progress = true,
        }, info.enabled)
        assert.are.same(BookInfo.ORDER, BookInfo.normalize(nil).order)
    end)

    it("stores fields under reader controls and edits them from settings", function()
        local config = {}
        local saves = 0
        local item = BookInfo.settingsItem(config, function() saves = saves + 1 end)
        assert.are.equal("Book info \u{25B8}", item.text)
        item.callback()
        assert.are.equal("Book info", shown.title)
        assert.are.equal("Read time", shown.item_table[1].text)
        assert.is_true(shown.item_table[1].checked_func())
        shown.item_table[1].callback()
        assert.is_false(config.reader_controls.book_info.enabled.read_time)
        shown.item_table[1], shown.item_table[6] = shown.item_table[6], shown.item_table[1]
        shown.callback()
        assert.are.same({
            "progress", "time_remaining", "pages_today", "time_today", "pages", "read_time",
        }, config.reader_controls.book_info.order)
        assert.are.equal(2, saves)
    end)
end)
