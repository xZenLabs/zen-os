describe("Zen modal close button", function()
    local old_button

    before_each(function()
        old_button = nil
        ZenSpec.replace("device", {
            isTouchDevice = function() return false end,
            hasDPad = function() return true end,
            hasKeyboard = function() return false end,
        })
        ZenSpec.replace("common/plugin_root", "/zen-ui")
        ZenSpec.replace("common/utils", {
            resolveLocalIcon = function(dir, name) return dir .. name .. ".svg" end,
        })
        ZenSpec.replace("common/ui/zen_icon_button", {
            new = function(_, spec) return spec end,
        })
        ZenSpec.unload("common/ui/zen_modal_close")
    end)

    after_each(function()
        ZenSpec.unload("common/ui/zen_modal_close")
    end)

    local function new_title_bar()
        local title_bar = {
            clear = function(self)
                for i = #self, 1, -1 do self[i] = nil end
            end,
            init = function(self)
                old_button = {
                    width = 24,
                    height = 24,
                    padding = 4,
                    padding_top = 4,
                    padding_right = 4,
                    padding_bottom = 24,
                    padding_left = 48,
                    overlap_align = "right",
                    callback = self.right_icon_tap_callback,
                    allow_flash = self.right_icon_allow_flash,
                    free = function(button) button.freed = true end,
                }
                self.right_button = old_button
                self[1] = old_button
            end,
        }
        return title_bar
    end

    it("installs a file-backed close button on the right and makes it focusable", function()
        local input = { name = "input" }
        local dialog = {
            title_bar = new_title_bar(),
            layout = { { input } },
            selected = { x = 1, y = 1 },
            init = function() end,
        }
        local closed = false
        local ZenModalClose = require("common/ui/zen_modal_close")
        local close_button = ZenModalClose.installDialog(dialog, function() closed = true end)

        assert.is_nil(dialog.title_bar.left_button)
        assert.is_true(dialog.title_bar.right_button == close_button)
        assert.are.equal("/zen-ui/icons/close.svg", close_button.file)
        assert.are.equal("right", close_button.overlap_align)
        assert.is_true(close_button.allow_flash)
        assert.is_true(old_button.freed)
        assert.is_true(dialog.layout[1][1] == close_button)
        assert.is_true(dialog.layout[2][1] == input)
        assert.are.same({ x = 1, y = 2 }, dialog.selected)

        close_button.callback()
        assert.is_true(closed)
    end)

    it("restores the right close button when an input dialog reinitializes", function()
        local dialog = {
            title_bar = new_title_bar(),
            layout = { { name = "input" } },
            selected = { x = 1, y = 1 },
        }
        dialog.init = function(self)
            self.title_bar = new_title_bar()
            self.layout = { { name = "new-input" } }
            self.selected = { x = 1, y = 1 }
        end

        local ZenModalClose = require("common/ui/zen_modal_close")
        ZenModalClose.installDialog(dialog, function() end)
        dialog:init()

        assert.are.equal("/zen-ui/icons/close.svg", dialog.title_bar.right_button.file)
        assert.is_true(dialog.layout[1][1] == dialog.title_bar.right_button)
        assert.are.same({ x = 1, y = 2 }, dialog.selected)
    end)
end)
