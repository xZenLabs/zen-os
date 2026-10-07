describe("mosaic layout preview", function()
    local saved
    local dependencies = {
        "gettext", "device", "ffi/blitbuffer", "ui/font", "ui/uimanager", "ui/geometry", "ui/gesturerange",
        "ui/widget/buttondialog", "ui/widget/textwidget", "ui/widget/verticalgroup", "ui/widget/verticalspan",
        "ui/widget/container/centercontainer", "ui/widget/container/widgetcontainer", "common/cover_utils",
        "common/ui/zen_slider", "common/ui/mosaic_layout_dialog",
    }
    before_each(function()
        saved = {}
        for _i, name in ipairs(dependencies) do saved[name] = package.loaded[name] end
        local widget = {}
        function widget:new(values) return setmetatable(values, { __index = self }) end
        function widget:extend(values) return setmetatable(values, { __index = self }) end
        function widget:getSize() return self.dimen end
        function widget:setText(text) self.text = text end
        function widget:getAddedWidgetAvailableWidth() return 360 end
        function widget:addWidget(content) self.content = content end
        function widget:onTapClose() end
        function widget:onClose() self.closed = true end
        for _i, name in ipairs(dependencies) do
            if name:find("ui/widget/", 1, true) then ZenSpec.replace(name, widget) end
        end
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("device", { screen = {
            getWidth = function() return 600 end, getHeight = function() return 800 end,
            scaleBySize = function(_self, value) return value end,
        } })
        ZenSpec.replace("ui/geometry", widget)
        ZenSpec.replace("ui/gesturerange", widget)
        ZenSpec.replace("ui/font", { getFace = function() return {} end })
        ZenSpec.replace("ui/uimanager", { setDirty = function() end })
        ZenSpec.replace("ffi/blitbuffer", { COLOR_WHITE = 1, COLOR_BLACK = 0, COLOR_LIGHT_GRAY = 2, COLOR_DARK_GRAY = 3 })
        ZenSpec.replace("common/cover_utils", { getRatio = function() return 2 / 3 end })
        -- Each dialog owns its gesture tables, as native ButtonDialog does.
        local button_dialog = widget:extend{}
        function button_dialog:new(values)
            values.ges_events = {}
            values.movable = {}
            return widget.new(self, values)
        end
        ZenSpec.replace("ui/widget/buttondialog", button_dialog)
        ZenSpec.unload("common/ui/zen_slider")
        ZenSpec.unload("common/ui/mosaic_layout_dialog")
    end)
    after_each(function()
        for _i, name in ipairs(dependencies) do package.loaded[name] = saved[name] end
    end)
    it("snaps to allowed stops, redraws covers, and saves only on Accept", function()
        local applied
        local dialog = require("common/ui/mosaic_layout_dialog").new{
            title = "Portrait", portrait = true, columns = 3, rows = 3,
            callback = function(columns, rows) applied = { columns, rows } end,
        }
        assert.are.equal(1, #dialog.buttons)
        assert.are.equal(2, #dialog.buttons[1])
        assert.are.same({ "Cancel", "Accept" }, { dialog.buttons[1][1].text, dialog.buttons[1][2].text })
        assert.are.same({ 2, 8 }, { dialog._sliders.rows.value_min, dialog._sliders.rows.value_max })
        local function cover_count()
            local covers = 0
            dialog._preview:paintTo({
                paintRect = function(_self, _x, _y, w, h, color)
                    assert.is_true(w > 0 and h > 0)
                    if color == 2 then covers = covers + 1 end
                end,
                paintBorder = function() end,
            }, 0, 0)
            return covers
        end
        assert.are.equal(9, cover_count())
        local cols, rows = dialog._sliders.columns, dialog._sliders.rows
        cols:applyPosition(360)
        rows:applyPosition(0)
        assert.are.same({ 8, 2 }, { cols:getValue(), rows:getValue() })
        assert.are.equal(16, cover_count())
        assert.is_nil(applied)
        rows:applyPosition(360)
        assert.are.equal(64, cover_count())
        dialog.buttons[1][2].callback()
        assert.are.same({ 8, 8 }, applied)
        assert.is_true(dialog.closed)

        local cancelled = require("common/ui/mosaic_layout_dialog").new{
            title = "Landscape", portrait = false, columns = 4, rows = 2,
            callback = function() error("Cancel must not save") end,
        }
        cancelled._sliders.columns:applyPosition(360)
        cancelled.buttons[1][1].callback()
        assert.is_true(cancelled.closed)
    end)
end)
