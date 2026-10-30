describe("reader controls buttons", function()
    local Buttons
    before_each(function()
        ZenSpec.replace("device", { isTouchDevice = function() return true end })
        ZenSpec.unload("modules/menu/reader_controls/buttons")
        Buttons = require("modules/menu/reader_controls/buttons")
    end)

    it("adds built-ins once and preserves existing custom buttons", function()
        local custom = { id = "al_1", type = "action", label = "Custom", action = {} }
        local config = { reader_controls = { entries = { custom }, next_id = 1, open_first = false } }
        local cfg = Buttons.ensure(config)
        assert.are.equal(15, #cfg.entries)
        assert.are.equal("book_info", cfg.entries[1].control)
        assert.are.equal("settings_brush", Buttons.icon(cfg.entries[10]))
        for _i, entry in ipairs(Buttons.defaults()) do
            assert.is_nil(entry.icon)
            assert.is_nil(entry.icon_override)
            assert.is_string(Buttons.icon(entry))
        end
        assert.are.equal(custom, cfg.entries[15])
        assert.is_false(cfg.open_first)
        assert.are.equal(15, #Buttons.ensure(config).entries)
    end)

    it("keeps deleted and edited built-ins after loading the saved list", function()
        local config = {}
        local cfg = Buttons.ensure(config)
        table.remove(cfg.entries, 2)
        cfg.entries[3].label = "Layout"
        Buttons.setIcon(cfg.entries[3], "info")
        local copy = require("util").tableDeepCopy(config)
        local restored = Buttons.ensure(copy)
        assert.are.equal(13, #restored.entries)
        assert.are.equal("page", restored.entries[3].control)
        assert.are.equal("Layout", restored.entries[3].label)
        assert.are.equal("info", Buttons.icon(restored.entries[3]))
        assert.is_nil(restored.open_first)
        restored.entries = {}
        assert.are.same({}, Buttons.visible(copy, "copt"))
    end)

    it("replaces the old Highlights button with Search once without touching custom actions", function()
        local entries = Buttons.defaults()
        table.remove(entries, 2)
        entries[7] = { id = "reader_highlights", type = "reader_control", control = "highlights", enabled = false }
        local custom = { id = "custom_highlight", type = "action", label = "Highlight", action = {} }
        entries[#entries + 1] = custom
        local config = { reader_controls = { entries = entries, buttons_initialized = true, book_info_actions = true } }
        local cfg = Buttons.ensure(config)
        assert.are.equal("search", cfg.entries[8].control)
        assert.are.equal("quick_search", Buttons.icon(cfg.entries[8]))
        assert.are.equal(custom, cfg.entries[15])
        table.remove(cfg.entries, 8)
        assert.are.equal(14, #Buttons.ensure(config).entries)
        for _i, entry in ipairs(cfg.entries) do assert.are_not.equal("highlights", entry.control) end
    end)

    it("respects ordering, toggles, and engine-specific document controls", function()
        local config = {}
        local cfg = Buttons.ensure(config)
        cfg.entries[2].enabled = false
        cfg.entries[4], cfg.entries[10] = cfg.entries[10], cfg.entries[4]
        local reflowable = Buttons.visible(config, "copt")
        assert.are.equal(4, #reflowable)
        assert.are.equal("themes", reflowable[2].control)
        for _i, entry in ipairs(reflowable) do assert.are_not.equal("document", entry.control) end
        local fixed = Buttons.visible(config, "kopt")
        assert.are.equal(5, #fixed)
        for _i, entry in ipairs(fixed) do assert.are_not.equal("themes", entry.control) end
    end)

    it("uses current named defaults without rewriting saved icon names", function()
        local config = {}
        local entries = Buttons.ensure(config).entries
        assert.are.equal(require("modules/reader/page_browser_tabs").list({}, { rolling = {} })[2].icon, Buttons.icon(entries[2]))
        assert.are.equal(require("modules/reader/page_browser_tabs").list({}, nil, true)[3].icon,
            Buttons.icon(entries[7]))
        assert.are.equal(require("modules/reader/page_browser_tabs").list({}, nil, true)[8].icon, Buttons.icon(entries[14]))
        local defaults = {
            { 2, "appbar.textsize", "font" }, { 4, "appbar.pageview", "page" },
            { 5, "book_closed", "document" }, { 9, "bookshelf", "profiles" }, { 12, "grid_slide", "coverflow" },
            { 7, "bookmark", "bookmark_outline" },
            { 10, "paint_palette", "settings_brush" }, { 14, "swap_horizontal", "history" },
        }
        for _i, default in ipairs(defaults) do entries[default[1]].icon = default[2] end
        Buttons.ensure(config)
        for _i, default in ipairs(defaults) do
            local entry = entries[default[1]]
            assert.are.equal(default[2], entry.icon)
            assert.are.equal(default[3], Buttons.icon(entry))
            Buttons.setIcon(entry, "custom_icon")
        end
        local restored = Buttons.ensure(require("util").tableDeepCopy(config)).entries
        for _i, default in ipairs(defaults) do
            local entry = restored[default[1]]
            assert.are.equal("custom_icon", Buttons.icon(entry))
            Buttons.setIcon(entry, default[3])
            assert.is_nil(entry.icon_override)
            assert.are.equal(default[3], Buttons.icon(entry))
        end
        local action = { type = "action", control = "themes", icon = "paint_palette" }
        assert.are.equal("paint_palette", Buttons.icon(action))
        Buttons.setIcon(action, "info")
        assert.are.equal("info", action.icon)
        assert.is_nil(action.icon_override)
    end)

    it("shows at most eight eligible controls in saved order without deleting overflow", function()
        local config = {}
        local cfg = Buttons.ensure(config)
        for _i, entry in ipairs(cfg.entries) do entry.enabled = true end
        local custom = { type = "action", id = "custom", icon = "info" }
        table.insert(cfg.entries, 1, custom)
        local original = require("util").tableDeepCopy(cfg.entries)
        local function controls(group)
            local ids = {}
            for _i, entry in ipairs(Buttons.visible(config, group)) do ids[#ids + 1] = entry.control or entry.id end
            return ids
        end
        assert.are.same({ "custom", "book_info", "font", "page", "toc", "bookmarks", "search", "profiles" }, controls("copt"))
        assert.are.same({ "custom", "book_info", "contrast", "page", "document", "toc", "bookmarks", "search" },
            controls("kopt"))
        assert.are.same(original, cfg.entries)
    end)

    it("checks the eight-control limit for every engine a button supports", function()
        local config = {}
        local entries = Buttons.ensure(config).entries
        local font, contrast, profiles = entries[2], entries[3], entries[9]
        for _i, index in ipairs({ 6, 7, 8 }) do entries[index].enabled = true end
        local custom = { type = "action" }
        assert.is_false(Buttons.canEnable(config, profiles))
        assert.is_false(Buttons.canEnable(config, custom))
        font.enabled = false
        assert.is_true(Buttons.canEnable(config, font))
        assert.is_false(Buttons.canEnable(config, profiles))
        contrast.enabled = false
        assert.is_true(Buttons.canEnable(config, contrast))
        assert.is_true(Buttons.canEnable(config, profiles))
        assert.is_true(Buttons.canEnable(config, custom))
        profiles.enabled = true
        assert.is_false(Buttons.canEnable(config, font))
        assert.is_false(Buttons.canEnable(config, contrast))
    end)

    it("defaults page chevrons to non-touch devices and preserves explicit choices", function()
        for _i, touch in ipairs({ true, false }) do
            ZenSpec.replace("device", { isTouchDevice = function() return touch end })
            local config = {}
            assert.are.equal(not touch, Buttons.ensure(config).show_page_chevrons)
            config.reader_controls.show_page_chevrons = touch
            assert.are.equal(touch, Buttons.ensure(config).show_page_chevrons)
        end
    end)

    it("keeps Profiles and Vocabulary builder off by default and preserves saved enabling", function()
        for control, index in pairs({ profiles = 9, vocabulary = 11 }) do
            local config = {}
            local entry = Buttons.ensure(config).entries[index]
            assert.are.equal(control, entry.control)
            assert.is_false(entry.enabled)
            for _i, group in ipairs({ "copt", "kopt" }) do
                for _j, visible in ipairs(Buttons.visible(config, group)) do
                    assert.are_not.equal(control, visible.control)
                end
            end
            entry.enabled = true
            local restored = Buttons.ensure(require("util").tableDeepCopy(config))
            assert.is_true(restored.entries[index].enabled)
        end
    end)

    it("defaults legacy Profiles entries without an explicit visibility setting to off", function()
        local config = {}
        local profiles = Buttons.ensure(config).entries[9]
        profiles.enabled = nil
        local restored = Buttons.ensure(require("util").tableDeepCopy(config))
        assert.is_false(restored.entries[9].enabled)
        profiles.enabled = true
        assert.is_true(Buttons.ensure(config).entries[9].enabled)
    end)

    it("keeps Page Browser off by default and persists enabling it", function()
        local config = {}
        local cfg = Buttons.ensure(config)
        local browser
        for _i, entry in ipairs(cfg.entries) do
            if entry.control == "page_browser" then browser = entry end
        end
        assert.are.equal("page_browser", browser.control)
        assert.is_false(browser.enabled)
        for _i, entry in ipairs(Buttons.visible(config, "copt")) do
            assert.are_not.equal("page_browser", entry.control)
        end
        cfg.entries[5].enabled = false
        browser.enabled = true
        local visible = Buttons.visible(config, "copt")
        assert.are.equal(browser, visible[#visible - 1])
        local restored = Buttons.ensure(require("util").tableDeepCopy(config))
        for _i, entry in ipairs(restored.entries) do
            if entry.control == "page_browser" then assert.is_true(entry.enabled) end
        end
    end)

    it("adds missing menu buttons to saved lists once", function()
        local config = { reader_controls = { entries = {}, buttons_initialized = true,
            annotations_merged = true, contrast_split = true, book_switcher_added = true } }
        local cfg = Buttons.ensure(config)
        assert.are.equal(3, #cfg.entries)
        local vocab = cfg.entries[1]
        assert.are.equal("vocabulary", vocab.control)
        assert.are.equal("Vocabulary builder", vocab.label)
        assert.are.equal("tab_vocab", Buttons.icon(vocab))
        assert.is_false(vocab.enabled)
        assert.are.equal("page_browser", cfg.entries[2].control)
        assert.is_false(cfg.entries[2].enabled)
        assert.are.equal("koreader_menu", cfg.entries[3].control)
        assert.is_false(cfg.entries[3].enabled)
        assert.are.equal(3, #Buttons.ensure(config).entries)
        table.remove(cfg.entries, 2)
        assert.are.equal(2, #Buttons.ensure(require("util").tableDeepCopy(config)).entries)
    end)

    it("preserves existing menu buttons and their customizations during migration", function()
        local custom = { id = "al_1", type = "action", label = "Custom", action = {} }
        local browser = { id = "reader_page_browser", type = "reader_control", control = "page_browser",
            label = "Browse", icon_override = "info", enabled = true }
        local vocab = { id = "reader_vocabulary", type = "reader_control", control = "vocabulary",
            label = "Words", icon_override = "bookmark", enabled = false }
        local config = { reader_controls = { entries = { custom, browser, vocab }, buttons_initialized = true,
            annotations_merged = true, contrast_split = true, book_switcher_added = true } }
        local cfg = Buttons.ensure(config)
        assert.are.same({ custom, browser, vocab, { id = "reader_koreader_menu", type = "reader_control",
            control = "koreader_menu", label = "KOReader reader menu", enabled = false } }, cfg.entries)
        assert.are.equal(4, #Buttons.ensure(require("util").tableDeepCopy(config)).entries)
    end)

    it("keeps the KOReader bottom menu button disabled by default", function()
        local config = {}
        local cfg = Buttons.ensure(config)
        local menu = cfg.entries[#cfg.entries - 1]
        assert.are.equal("koreader_menu", menu.control)
        assert.are.equal("KOReader reader menu", menu.label)
        assert.is_false(menu.enabled)
        for _i, entry in ipairs(Buttons.visible(config, "copt")) do
            assert.are_not.equal("koreader_menu", entry.control)
        end
        cfg.entries[5].enabled = false
        menu.enabled = true
        local fixed = Buttons.visible(config, "kopt")
        assert.are.equal(menu, fixed[#fixed - 1])
    end)

    it("keeps Font and Contrast independent and visible only for their document engines", function()
        local config = {}
        local cfg = Buttons.ensure(config)
        cfg.entries[1].enabled = false
        local font, contrast = cfg.entries[2], cfg.entries[3]
        assert.are.equal("contrast", contrast.control)
        assert.are.equal("Contrast", contrast.label)
        assert.are.equal("appbar.contrast", Buttons.icon(contrast))
        assert.are.equal(font, Buttons.visible(config, "copt")[1])
        assert.are.equal(contrast, Buttons.visible(config, "kopt")[1])
        for _i, entry in ipairs(Buttons.visible(config, "copt")) do
            assert.are_not.equal("contrast", entry.control)
        end
        for _i, entry in ipairs(Buttons.visible(config, "kopt")) do
            assert.are_not.equal("font", entry.control)
        end
        font.enabled = false
        assert.are.equal(contrast, Buttons.visible(config, "kopt")[1])
        contrast.label, contrast.icon_override, contrast.enabled = "Images", "custom_color", false
        assert.are.equal("page", Buttons.visible(config, "kopt")[1].control)
        assert.are.equal("Font", font.label)
        assert.are.equal("font", Buttons.icon(font))
    end)

    it("splits a legacy Font button once while preserving its fixed-layout preferences", function()
        local font = { id = "reader_font", type = "reader_control", control = "font",
            label = "Appearance", icon_override = "custom_color", enabled = false }
        local custom = { id = "al_1", type = "action", label = "Custom", action = {} }
        local config = { reader_controls = { entries = { custom, font },
            buttons_initialized = true, annotations_merged = true, menu_buttons_added = true, book_switcher_added = true } }
        local cfg = Buttons.ensure(config)
        assert.are.same({ custom, font, cfg.entries[3] }, cfg.entries)
        local contrast = cfg.entries[3]
        assert.are.equal("reader_contrast", contrast.id)
        assert.are.equal("contrast", contrast.control)
        assert.are.equal("Appearance", contrast.label)
        assert.are.equal("custom_color", Buttons.icon(contrast))
        assert.is_false(contrast.enabled)
        contrast.enabled = true
        assert.is_false(font.enabled)
        assert.are.equal(3, #Buttons.ensure(config).entries)
        table.remove(cfg.entries, 3)
        assert.are.equal(2, #Buttons.ensure(require("util").tableDeepCopy(config)).entries)
    end)

    it("keeps Contrast disabled when the legacy Font button was removed", function()
        local config = { reader_controls = { entries = {},
            buttons_initialized = true, annotations_merged = true, menu_buttons_added = true, book_switcher_added = true } }
        local cfg = Buttons.ensure(config)
        assert.are.equal("contrast", cfg.entries[1].control)
        assert.is_false(cfg.entries[1].enabled)
        assert.are.same({}, Buttons.visible(config, "kopt"))
    end)

    it("keeps the Contrast icon when splitting a Font button using either default icon", function()
        for _i, icon in ipairs({ "appbar.textsize", "font" }) do
            local config = { reader_controls = { entries = {
                { type = "reader_control", control = "font", icon = icon },
            }, buttons_initialized = true, annotations_merged = true, menu_buttons_added = true, book_switcher_added = true } }
            local entries = Buttons.ensure(config).entries
            assert.are.equal("font", Buttons.icon(entries[1]))
            assert.are.equal("appbar.contrast", Buttons.icon(entries[2]))
        end
    end)

    it("turns off Search, Bookmarks and TOC buttons once and opens Book info first", function()
        local custom = { id = "custom", type = "action", label = "Custom", action = {} }
        local moved = { search = true, bookmarks = true, toc = true }
        local entries = Buttons.defaults()
        for _i, entry in ipairs(entries) do if moved[entry.control] then entry.enabled = nil end end
        table.insert(entries, 2, custom)
        local config = { reader_controls = { entries = entries, buttons_initialized = true, annotations_merged = true,
            contrast_split = true, menu_buttons_added = true, book_switcher_added = true } }
        local cfg = Buttons.ensure(config)
        assert.are.equal("book_info", cfg.entries[1].control)
        assert.are.equal("font", cfg.entries[2].control)
        assert.are.equal(custom, cfg.entries[3])
        local toc
        for _i, entry in ipairs(cfg.entries) do
            if moved[entry.control] then assert.is_false(entry.enabled) end
            if entry.control == "toc" then toc = entry end
        end
        assert.are.equal(15, #cfg.entries)
        toc.enabled = true
        cfg.entries[1], cfg.entries[2] = cfg.entries[2], cfg.entries[1]
        local restored = Buttons.ensure(require("util").tableDeepCopy(config)).entries
        assert.are.equal("font", restored[1].control)
        assert.is_true(restored[7].enabled)
        assert.are.equal("toc", restored[7].control)
    end)

    it("enables the book switcher by default for both engines and preserves disabling it", function()
        local config = {}
        local cfg = Buttons.ensure(config)
        local switcher = cfg.entries[#cfg.entries]
        assert.are.equal("book_switcher", switcher.control)
        assert.are.equal("Book switcher", switcher.label)
        assert.are.equal("history", Buttons.icon(switcher))
        for _i, group in ipairs({ "copt", "kopt" }) do
            local entries = Buttons.visible(config, group)
            assert.are.equal(switcher, entries[#entries])
        end
        switcher.enabled = false
        local restored = require("util").tableDeepCopy(config)
        assert.is_false(Buttons.ensure(restored).entries[#cfg.entries].enabled)
        for _i, entry in ipairs(Buttons.visible(restored, "copt")) do
            assert.are_not.equal("book_switcher", entry.control)
        end
    end)

    it("adds the book switcher to saved layouts once without duplicating or restoring deleted buttons", function()
        local custom = { id = "custom", type = "action", label = "Custom", action = {} }
        local config = { reader_controls = { entries = { custom }, buttons_initialized = true,
            annotations_merged = true, contrast_split = true, menu_buttons_added = true } }
        local cfg = Buttons.ensure(config)
        assert.are.equal(custom, cfg.entries[1])
        assert.are.equal(2, #cfg.entries)
        assert.are.equal("book_switcher", cfg.entries[2].control)
        assert.are_not.equal(false, cfg.entries[2].enabled)
        cfg.book_switcher_added = nil
        cfg.entries[2].label, cfg.entries[2].enabled = "Recent", false
        assert.are.equal(2, #Buttons.ensure(config).entries)
        assert.are.equal("Recent", cfg.entries[2].label)
        assert.is_false(cfg.entries[2].enabled)
        table.remove(cfg.entries, 2)
        assert.are.same({ custom }, Buttons.ensure(require("util").tableDeepCopy(config)).entries)
    end)
end)
