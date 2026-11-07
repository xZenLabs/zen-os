describe("glyph icons", function()
    local saved_modules
    local dependencies = {
        "ui/widget/container/centercontainer",
        "device",
        "ui/geometry",
        "ui/widget/horizontalgroup",
        "ui/widget/horizontalspan",
        "ui/widget/iconwidget",
        "ui/widget/textwidget",
        "common/plugin_root",
        "ui/widget/buttondialog",
        "common/utils",
        "common/ui/glyph_icons",
    }

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(dependencies) do
            saved_modules[name] = package.loaded[name] or false
        end
        for kind, name in pairs({
            center = "ui/widget/container/centercontainer", geom = "ui/geometry",
            group = "ui/widget/horizontalgroup", span = "ui/widget/horizontalspan",
            icon = "ui/widget/iconwidget", text = "ui/widget/textwidget",
        }) do
            ZenSpec.replace(name, {
                new = function(_self, o)
                    o.kind = kind
                    return o
                end,
            })
        end
        ZenSpec.replace("device", {
            screen = { scaleBySize = function(_self, value) return value end },
        })
        ZenSpec.replace("common/plugin_root", "/zen")
        ZenSpec.replace("common/utils", {})
        ZenSpec.unload("common/ui/glyph_icons")
    end)

    after_each(function()
        for name, original in pairs(saved_modules) do
            package.loaded[name] = original or nil
        end
    end)

    it("maps each glyph to one bundled SVG icon", function()
        local GlyphIcons = require("common/ui/glyph_icons")
        local glyphs = require("common/inline_icon_map")
        local by_glyph = {}
        for key, name in pairs(GlyphIcons.SVG) do
            assert.is_not_nil(glyphs[key], key)
            local file = io.open(ZenSpec.root .. "/icons/" .. name .. ".svg", "r")
            assert.is_not_nil(file, name)
            file:close()
            local previous = by_glyph[glyphs[key]]
            assert.is_true(previous == nil or previous == name, key)
            by_glyph[glyphs[key]] = name
        end
    end)

    it("aligns button dialog glyphs and renders mapped ones as pack-resolved icons", function()
        local resolved = {}
        package.loaded["common/utils"].resolveIcon = function(dir, name)
            resolved[#resolved + 1] = name
            return dir .. name .. ".svg"
        end
        local glyphs = require("common/inline_icon_map")
        local function button(text, enabled, align)
            return {
                text = text, enabled = enabled, align = align,
                label_widget = { face = { size = 20 }, free = function() end },
                label_container = { dimen = { w = 200, h = 40 } },
            }
        end
        local centered = button("Cancel", true)
        local rows = {
            { button(glyphs.reading .. "  Read now", true) },
            { button(glyphs.download .. "  Download", false) },
            { button(glyphs.check .. "  Done", true) },
            { button("Plain", true, "left") },
            { centered },
            { button(glyphs.edit .. "  Edit  " .. glyphs.arrow_right, true) },
        }
        local dialog = { buttontable = { buttons_layout = rows } }

        local GlyphIcons = require("common/ui/glyph_icons")
        assert.are.equal(dialog, GlyphIcons.alignButtonIcons(dialog))
        GlyphIcons.alignButtonIcons({ buttontable = { buttons_layout = {
            { button(glyphs.reading .. "  Again", true) },
        } } })

        local function parts(row)
            local group = row[1].label_container[1]
            return group[1][1], group[3]
        end
        local icon, label = parts(rows[1])
        assert.are.same({ "icon", "/zen/icons/settings_book_open_variant.svg", false, "Read now" },
            { icon.kind, icon.file, icon.dim, label.text })
        icon = parts(rows[2])
        assert.are.same({ "icon", true }, { icon.kind, icon.dim })
        icon, label = parts(rows[3])
        assert.are.same({ "text", glyphs.check, "Done" }, { icon.kind, icon.text, label.text })
        icon, label = parts(rows[4])
        assert.are.same({ "span", "Plain" }, { icon.kind, label.text })
        assert.is_nil(centered.label_container[1])
        icon, label = parts(rows[6])
        local arrow = rows[6][1].label_container[1][5]
        assert.are.same({ "/zen/icons/settings_square_edit_outline.svg", "Edit",
            "/zen/icons/settings_chevron_right.svg" }, { icon.file, label.text, arrow.file })
    end)

    it("aligns ButtonDialogs with glyph buttons once installed", function()
        package.loaded["common/utils"].resolveIcon = function(dir, name) return dir .. name .. ".svg" end
        local glyphs = require("common/inline_icon_map")
        local function dialog(text)
            return { buttontable = { buttons_layout = { { {
                text = text, align = "left",
                label_widget = { face = { size = 20 }, free = function() end },
                label_container = { dimen = { w = 200, h = 40 } },
            } } } } }
        end
        local ButtonDialog = { init = function() end }
        ZenSpec.replace("ui/widget/buttondialog", ButtonDialog)

        local GlyphIcons = require("common/ui/glyph_icons")
        GlyphIcons.install()
        GlyphIcons.install()
        local with_icon, plain = dialog(glyphs.delete .. "  Delete"), dialog("Plain")
        ButtonDialog.init(with_icon)
        ButtonDialog.init(plain)

        local row = with_icon.buttontable.buttons_layout[1][1]
        assert.are.equal("/zen/icons/settings_delete_outline.svg", row.label_container[1][1][1].file)
        assert.is_nil(plain.buttontable.buttons_layout[1][1].label_container[1])
    end)
end)
