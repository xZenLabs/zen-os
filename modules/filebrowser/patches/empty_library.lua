local function apply_empty_library()
    local FileChooser = require("ui/widget/filechooser")
    if FileChooser._zen_empty_library_patched then return end
    FileChooser._zen_empty_library_patched = true

    local Button = require("ui/widget/button")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local Size = require("ui/size")
    local ZenButton = require("common/ui/zen_button")
    local paths = require("common/paths")
    local _ = require("gettext")
    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    local orig_updatePageInfo = FileChooser.updatePageInfo

    function FileChooser:updatePageInfo(...)
        local empty = self.name == "filemanager" and paths.isHomeRoot(self.path)
        if empty then
            for _i, item in ipairs(self.item_table) do
                if not item.is_go_up then empty = false; break end
            end
        end
        if empty then
            local width = self.inner_dimen and self.inner_dimen.w or self.width
            local button = Button:new{
                text = _("Set home folder"),
                max_width = width,
                bordersize = 0,
                radius = 0,
                padding_h = Size.padding.large,
                show_parent = self.show_parent,
                callback = function()
                    require("modules/settings/zen_settings_page").show(plugin, { path = {
                        { key = "_zen_settings_root", value = "library" },
                        { key = "text", value = _("Folders") },
                        { key = "text", value = _("Home folder") },
                    } })
                end,
            }
            button.frame.paintTo = function(frame, bb, x, y)
                frame.dimen = Geom:new{ x = x, y = y, w = button.dimen.w, h = button.dimen.h }
                local paint = frame.invert and ZenButton.paintOutlined or ZenButton.paintFilled
                paint(bb, x, y, button.dimen.w, button.dimen.h, button.text, button.text_font_size)
            end
            local content = VerticalGroup:new{
                TextBoxWidget:new{
                    text = _("No books found"),
                    face = Font:getFace("smallinfofont"),
                    width = width,
                    alignment = "center",
                },
                VerticalSpan:new{ width = Size.padding.large },
                button,
            }
            local height = self.available_height or self.inner_dimen.h - self.others_height
            table.insert(self.item_group, CenterContainer:new{
                dimen = Geom:new{
                    w = width,
                    h = math.max(content:getSize().h, height - self.item_group:getSize().h),
                },
                content,
            })
            self.item_group:resetLayout()
            table.insert(self.layout, { button })
        end
        return orig_updatePageInfo(self, ...)
    end
end

return apply_empty_library
