describe("Zen arrange list settings resume", function()
    local ArrangeList
    local shown_widgets
    local saved_modules
    local ui_manager

    local dependency_names = {
        "ffi/blitbuffer",
        "ui/bidi",
        "device",
        "ui/event",
        "ui/widget/container/bottomcontainer",
        "ui/widget/container/centercontainer",
        "ui/widget/checkmark",
        "ui/widget/container/framecontainer",
        "ui/geometry",
        "ui/gesturerange",
        "ui/widget/horizontalgroup",
        "ui/widget/horizontalspan",
        "ui/widget/iconwidget",
        "ui/widget/infomessage",
        "ui/widget/container/inputcontainer",
        "ui/widget/container/leftcontainer",
        "ui/widget/linewidget",
        "ui/widget/container/overlapgroup",
        "ui/widget/overlapgroup",
        "ui/widget/radiomark",
        "ui/widget/container/rightcontainer",
        "ui/size",
        "ui/widget/sortwidget",
        "ui/widget/textwidget",
        "ui/uimanager",
        "ui/widget/verticalgroup",
        "gettext",
        "common/ui/icon_menu_item",
        "common/ui/button_feedback",
        "common/ui/truncated_text_message",
        "common/ui/zen_settings_titlebar",
        "modules/global/patches/menu_top_swipe",
        "common/ui/zen_toggle",
        "common/ui/zen_pager",
        "common/utils",
        "common/arrange_state",
        "common/dispatcher_menu",
        "modules/settings/zen_settings_page",
    }

    local function class()
        local result = {}
        function result:extend(prototype)
            prototype = prototype or {}
            setmetatable(prototype, { __index = self })
            prototype.__index = prototype
            return prototype
        end
        return result
    end

    before_each(function()
        saved_modules = {}
        shown_widgets = {}
        for _i, name in ipairs(dependency_names) do
            saved_modules[name] = package.loaded[name] or false
        end

        local UIManager = {
            _refresh_func_stack = {},
            close = function(_self, widget)
                widget.closed = true
            end,
            nextTick = function(_self, callback)
                _self.next_tick_count = (_self.next_tick_count or 0) + 1
                callback()
            end,
            scheduleIn = function() end,
            setDirty = function() end,
            show = function(_self, widget)
                shown_widgets[#shown_widgets + 1] = widget
            end,
            unschedule = function() end,
        }
        ui_manager = UIManager
        local SortWidget = {}
        function SortWidget:new(instance)
            instance = instance or {}
            instance.ges_events = {}
            instance.key_events = {}
            instance.dimen = { x = 0, y = 0, w = 100, h = 100 }
            instance.pages = 1
            instance.selected = { x = 1, y = 1 }
            instance.show_page = 1
            instance._populateItems = function() end
            instance.onClose = function(widget)
                UIManager:close(widget)
                return true
            end
            return instance
        end

        ZenSpec.replace("ffi/blitbuffer", {})
        ZenSpec.replace("ui/bidi", {})
        ZenSpec.replace("device", {
            hasDPad = function() return false end,
            isTouchDevice = function() return false end,
        })
        ZenSpec.replace("ui/event", { new = function(_self, event) return event end })
        ZenSpec.replace("ui/widget/container/bottomcontainer", {})
        ZenSpec.replace("ui/widget/container/centercontainer", {})
        ZenSpec.replace("ui/widget/checkmark", {})
        ZenSpec.replace("ui/widget/container/framecontainer", {})
        ZenSpec.replace("ui/geometry", { new = function(_self, dimen) return dimen end })
        ZenSpec.replace("ui/gesturerange", { new = function(_self, opts) return opts end })
        ZenSpec.replace("ui/widget/horizontalgroup", {})
        ZenSpec.replace("ui/widget/horizontalspan", {})
        ZenSpec.replace("ui/widget/iconwidget", {})
        ZenSpec.replace("ui/widget/infomessage", { new = function(_self, opts) return opts end })
        ZenSpec.replace("ui/widget/container/inputcontainer", class())
        ZenSpec.replace("ui/widget/container/leftcontainer", {})
        ZenSpec.replace("ui/widget/linewidget", {})
        ZenSpec.replace("ui/widget/container/overlapgroup", {})
        ZenSpec.replace("ui/widget/overlapgroup", {})
        ZenSpec.replace("ui/widget/radiomark", {})
        ZenSpec.replace("ui/widget/container/rightcontainer", {})
        ZenSpec.replace("ui/size", { padding = { large = 1 } })
        ZenSpec.replace("ui/widget/sortwidget", SortWidget)
        ZenSpec.replace("ui/widget/textwidget", {})
        ZenSpec.replace("ui/uimanager", UIManager)
        ZenSpec.replace("ui/widget/verticalgroup", {})
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("common/ui/icon_menu_item", {})
        ZenSpec.replace("common/ui/button_feedback", { flash = function() end })
        ZenSpec.replace("common/ui/truncated_text_message", { show = function() end })
        ZenSpec.replace("common/ui/zen_settings_titlebar", {})
        ZenSpec.replace("modules/global/patches/menu_top_swipe", {
            getTapHeight = function() return 0 end,
        })
        ZenSpec.replace("common/ui/zen_toggle", {})
        ZenSpec.replace("common/ui/zen_pager", {})
        ZenSpec.replace("common/utils", {})
        ZenSpec.replace("common/arrange_state", {
            SUBMENU_CARET = " >",
            stripSubmenuCaret = function(text) return text end,
            stripValueSuffix = function(text) return text end,
        })
        ZenSpec.replace("common/dispatcher_menu", { flush = function() end })
        ZenSpec.replace("modules/settings/zen_settings_page", {
            claimArrangeRoute = function()
                return {
                    opener = { text = "Arrange" },
                    path = { "First", "Second" },
                }
            end,
        })
        _G.__ZEN_UI_SETTINGS_PAGE = {}
        ZenSpec.unload("common/ui/zen_arrange_list")
        ArrangeList = require("common/ui/zen_arrange_list")
    end)

    after_each(function()
        _G.__ZEN_UI_SETTINGS_PAGE = nil
        ZenSpec.unload("common/ui/zen_arrange_list")
        for _i, name in ipairs(dependency_names) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    it("renders only the resumed leaf and reveals parent menus on Back", function()
        ArrangeList.show{
            allow_arrange = false,
            item_table = {
                {
                    text = "First",
                    sub_item_table = {
                        {
                            text = "Second",
                            sub_item_table = {{ text = "Destination" }},
                        },
                    },
                },
            },
        }

        assert.are.equal(3, #shown_widgets)
        assert.is_true(shown_widgets[1].invisible)
        assert.is_true(shown_widgets[2].invisible)
        assert.are.equal("Second", shown_widgets[3].title)
        assert.is_false(shown_widgets[3].invisible)
        assert.is_nil(ui_manager.next_tick_count)
        assert.are.same({ "First", "Second" }, shown_widgets[3]._zen_settings_resume.path)

        shown_widgets[3]:onClose()
        assert.are.equal("First", shown_widgets[2].title)
        assert.is_false(shown_widgets[2].invisible)
        assert.is_true(shown_widgets[1].invisible)

        shown_widgets[2]:onClose()
        assert.are.equal(3, #shown_widgets)
        assert.is_false(shown_widgets[1].invisible)
    end)

    it("inherits an explicit settings route for a nested arrange page", function()
        local inherited = {
            opener = { text = "Widgets", occurrence = 1 },
            path = { "strip", "Controls" },
        }

        ArrangeList.show{
            settings_resume = inherited,
            item_table = {{ text = "Recent" }},
        }

        assert.are.equal(inherited, shown_widgets[1]._zen_settings_resume)
        assert.are.equal(inherited,
            shown_widgets[1]._zen_menu_proxy._zen_settings_resume)
    end)

    it("passes the menu proxy to SortWidget hold callbacks", function()
        local callback_host
        local item = {
            text = "General",
            hold_callback = function(menu)
                callback_host = menu
                menu:updateItems()
            end,
        }

        ArrangeList.show{
            allow_arrange = false,
            item_table = { item },
        }
        local picker = shown_widgets[1]

        item:hold_callback(function() end)

        assert.are.equal(picker._zen_menu_proxy, callback_host)
    end)

    it("shows help on root and nested widget setting holds without toggling", function()
        ZenSpec.unload("common/arrange_state")
        ZenSpec.unload("common/ui/zen_arrange_list")
        ArrangeList = require("common/ui/zen_arrange_list")
        local sort = package.loaded["ui/widget/sortwidget"]
        local original_new = sort.new
        sort.new = function(self, options)
            local picker = original_new(self, options)
            picker._populateItems = function(parent)
                parent.main_content = {}
                for index, item in ipairs(parent.item_table) do
                    parent.main_content[index] = {
                        item = item, index = index, show_parent = parent,
                        onTap = function(row)
                            if row.item.callback then row.item:callback() end
                            return true
                        end,
                        onHoldTouch = function(row)
                            if row.item.callback then row.item:callback() end
                            return true
                        end,
                    }
                end
            end
            return picker
        end
        local help = "When disabled, widget is read only and does not respond to taps, holds, or swipes"
        for _i, menu_mode in ipairs({ false, true }) do
            local active = true
            local item = {
                text = "Interactive", help_text = help,
                checked_func = function() return active end,
                callback = function() active = not active end,
            }
            local picker = ArrangeList.show{
                allow_arrange = false, menu_mode = menu_mode,
                item_table = { item, { text = "Widget", sub_item_table = { item } } },
            }
            local row = picker.main_content[1]
            local shown_count = #shown_widgets
            assert.is_true(row:onHoldTouch())
            assert.are.equal(shown_count + 1, #shown_widgets)
            assert.are.equal(help, shown_widgets[#shown_widgets].text)
            assert.is_true(active)
            row:onTap()
            assert.is_false(active)

            picker.main_content[2]:onTap()
            local submenu = shown_widgets[#shown_widgets]
            assert.are_not.equal(picker, submenu)
            row = submenu.main_content[1]
            assert.is_true(row:onHoldTouch())
            assert.are.equal(help, shown_widgets[#shown_widgets].text)
            assert.is_false(active)

            item.help_text_func = function(menu)
                assert.are.equal(submenu._zen_menu_proxy, menu)
                return "Dynamic help"
            end
            row._zen_settings_text_truncated = true
            assert.is_true(row:onHoldTouch())
            assert.are.equal("Dynamic help", shown_widgets[#shown_widgets].text)
            assert.is_false(active)

            local help_calls = 0
            item.help_text_func = function()
                help_calls = help_calls + 1
                return "Drag help"
            end
            local arrange = ArrangeList.show{ menu_mode = menu_mode, item_table = { item } }
            row = arrange.main_content[1]
            row._zen_settings_text_truncated = true
            shown_count = #shown_widgets
            assert.is_true(arrange._zen_arrange_enabled)
            assert.is_true(row:onHoldTouch())
            assert.are.equal(0, help_calls)
            assert.are.equal(shown_count, #shown_widgets)
            assert.is_false(active)
        end
    end)

    it("flashes the tapped row before opening root and nested submenus", function()
        local original_settings = G_reader_settings
        finally(function() _G.G_reader_settings = original_settings end)
        local flash_disabled = false
        _G.G_reader_settings = { isFalse = function(_self, key)
            assert.are.equal("flash_ui", key)
            return flash_disabled
        end }
        package.loaded["device"].screen = { isColorScreen = function() return false end }
        ZenSpec.unload("common/ui/button_feedback")
        ZenSpec.unload("common/arrange_state")
        ZenSpec.unload("common/ui/zen_arrange_list")
        ArrangeList = require("common/ui/zen_arrange_list")
        local sort = package.loaded["ui/widget/sortwidget"]
        local original_new = sort.new
        sort.new = function(self, options)
            local picker = original_new(self, options)
            picker._populateItems = function(parent)
                parent.main_content = {}
                for index, item in ipairs(parent.item_table) do
                    parent.main_content[index] = {
                        item = item, index = index, show_parent = parent,
                        onTap = function(row)
                            if row.item.callback then row.item:callback() end
                            return true
                        end,
                        _zen_arrange_row_frame = {
                            dimen = { x = 7, y = 19 + index * 20, w = 86, h = 20 },
                            invert = false,
                        },
                    }
                end
            end
            return picker
        end
        local events, inverted = {}, false
        require("common/ui/button_feedback").invert = function(region)
            assert.are.same({ x = 7, y = 39, w = 86, h = 20 }, region)
            inverted = not inverted
            events[#events + 1] = inverted and "highlight" or "restore"
        end
        ui_manager.setDirty = function(_self, widget, mode, region)
            if not widget then
                assert.are.same({ x = 7, y = 39, w = 86, h = 20 }, region)
                events[#events + 1] = mode
            end
        end
        ui_manager.forceRePaint = function()
            assert.is_true(inverted)
            events[#events + 1] = "paint"
        end
        ui_manager.yieldToEPDC = function() events[#events + 1] = "yield" end
        local original_show = ui_manager.show
        ui_manager.show = function(self, widget)
            assert.is_false(inverted)
            events[#events + 1] = "show"
            original_show(self, widget)
        end
        local first = {
            text = "First",
            sub_item_table = {{
                text = "Second",
                sub_item_table_func = function() return {{
                    text = "Third", _zen_settings_submenu = true, keep_menu_open = true,
                    callback = function() ui_manager:show({ title = "Destination" }) end,
                }} end,
            }},
        }
        local picker = ArrangeList.show{ item_table = { first }, menu_mode = true }
        local expected = { "highlight", "fast", "paint", "yield", "restore", "ui", "show" }
        for depth = 1, 3 do
            events = {}
            local row = shown_widgets[depth].main_content[1]
            assert.is_true(row:onTap())
            assert.are.same(expected, events)
            assert.is_false(row._zen_arrange_row_frame.invert)
        end

        local row = picker.main_content[1]
        first.checked_func = function() return false end
        first.checkmark_callback = function() events[#events + 1] = "toggle" end
        row.checkmark_widget = { dimen = { x = 70, y = 39, w = 20, h = 20 } }
        local toggle_gesture = { pos = { intersectWith = function() return true end } }
        package.loaded["ui/size"].padding.default = 1
        events = {}
        row:onTap(nil, toggle_gesture)
        assert.are.same({ "toggle" }, events)
        row._zen_arrange_handle = { dimen = {} }
        events = {}
        row:onTap(nil, toggle_gesture)
        assert.are.same({}, events)

        first.enabled = false
        events = {}
        picker.main_content[1]:onTap()
        assert.are.same({}, events)
        first.enabled = true
        flash_disabled = true
        events = {}
        picker.main_content[1]:onTap()
        assert.are.same({ "show" }, events)

        flash_disabled = false
        local callback_picker = ArrangeList.show{ allow_arrange = false, item_table = {{
            text = "Callback", _zen_settings_submenu = true,
            callback = function() ui_manager:show({ title = "Destination" }) end,
        }} }
        events = {}
        local focused_frame = callback_picker.main_content[1]._zen_arrange_row_frame
        focused_frame.invert = true
        callback_picker.main_content[1]:onTap()
        assert.are.same(expected, events)
        assert.is_true(focused_frame.invert)
    end)

    it("renders numeric radio selections and refreshes disabled execution options", function()
        local function widget(_self, options)
            options.getSize = function() return { w = 10, h = 10 } end
            options.isTruncated = function() return false end
            return options
        end
        for _i, name in ipairs({
            "ui/widget/checkmark", "ui/widget/radiomark",
            "ui/widget/container/framecontainer", "ui/widget/container/leftcontainer",
            "ui/widget/container/rightcontainer", "ui/widget/overlapgroup",
            "ui/widget/container/bottomcontainer", "ui/widget/linewidget",
            "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
            "ui/widget/textwidget", "ui/widget/verticalgroup",
        }) do
            package.loaded[name].new = widget
        end
        package.loaded["ui/bidi"].mirroredUILayout = function() return false end
        package.loaded["ffi/blitbuffer"].COLOR_DARK_GRAY = "gray"
        local size = package.loaded["ui/size"]
        size.padding = { fullscreen = 1, default = 1, large = 1 }
        size.border = { thin = 1 }
        size.line = { thin = 1 }
        local icons = package.loaded["common/ui/icon_menu_item"]
        icons.SETTINGS_TOGGLE_HEIGHT, icons.SETTINGS_TOGGLE_WIDTH = 10, 20
        icons.SETTINGS_ICON_WIDTH, icons.SETTINGS_CARET_SIZE = 10, 10
        icons.getItemFace = function() return { orig_size = 20 } end
        icons.getSettingsIconFace = icons.getItemFace
        icons.enableFullRowFocus = function() end

        local sort = package.loaded["ui/widget/sortwidget"]
        local original_new = sort.new
        sort.new = function(self, options)
            local picker = original_new(self, options)
            picker._populateItems = function(parent)
                parent.main_content = {}
                for _i, item in ipairs(parent.item_table) do
                    parent.main_content[#parent.main_content + 1] = {
                        item = item, width = 100, height = 20, show_parent = parent,
                    }
                end
            end
            return picker
        end
        local count, index = 1, nil
        local item = {
            text = "Execute one by one", radio = true,
            enabled_func = function() return count > 1 end,
            checked_func = function() return index end,
            callback = function() index = 1 end,
        }
        local picker = ArrangeList.show{
            menu_mode = true, allow_arrange = false, item_table = { item },
        }
        local function radio() return picker.main_content[1].checkmark_widget end
        assert.is_false(radio().enabled)
        assert.is_false(radio().checked)
        assert.is_true(item.dim)

        count = 2
        picker._zen_menu_proxy:updateItems()
        assert.is_true(radio().enabled)
        assert.is_not_true(item.dim)
        item:callback()
        assert.are.equal(1, index)
        assert.is_true(radio().checked)

        index = 2
        picker._zen_menu_proxy:updateItems()
        assert.is_true(radio().checked)
        count, index = 1, nil
        picker._zen_menu_proxy:updateItems()
        assert.is_false(radio().enabled)
        assert.is_false(radio().checked)
    end)

    it("restores descendants of a callback-backed settings leaf", function()
        local callback_parent
        require("modules/settings/zen_settings_page").claimArrangeRoute = function()
            return {
                opener = { text = "Arrange" },
                path = { "First", "Tabs", "TBR", "Order" },
            }
        end

        ArrangeList.show{
            allow_arrange = false,
            item_table = {
                {
                    text = "First",
                    sub_item_table = {
                        {
                            text = "Tabs",
                            _zen_settings_submenu = true,
                            keep_menu_open = true,
                            callback = function(parent)
                                callback_parent = parent
                                ArrangeList.show{
                                    settings_resume = {
                                        opener = parent._zen_settings_resume.opener,
                                        path = { "First", "Tabs" },
                                    },
                                    item_table = {
                                        {
                                            text = "TBR",
                                            sub_item_table = {
                                                {
                                                    text = "Order",
                                                    _zen_settings_submenu = true,
                                                    callback = function(order_parent)
                                                        ui_manager:show({
                                                            title = "Order",
                                                            settings_resume =
                                                                order_parent._zen_settings_resume,
                                                        })
                                                    end,
                                                },
                                            },
                                        },
                                    },
                                }
                            end,
                        },
                    },
                },
            },
        }

        assert.are.equal(5, #shown_widgets)
        assert.are.equal("Order", shown_widgets[5].title)
        assert.is_false(shown_widgets[2].invisible)
        assert.are.same({ "First" }, callback_parent._zen_settings_resume.path)
        assert.are.same({ "First", "Tabs", "TBR" },
            shown_widgets[5].settings_resume.path)
    end)

    it("does not reveal deferred parents while closing the whole arrange stack", function()
        local settings_parent = { _deferred_arrange_parent = true }
        require("modules/settings/zen_settings_page").claimArrangeRoute = function()
            return {
                opener = { text = "Arrange" },
                path = { "First", "Second" },
                deferred_parent = settings_parent,
            }
        end
        ArrangeList.show{
            allow_arrange = false,
            item_table = {
                {
                    text = "First",
                    sub_item_table = {
                        {
                            text = "Second",
                            sub_item_table = {{ text = "Destination" }},
                        },
                    },
                },
            },
        }

        shown_widgets[3]:_zen_arrange_close_all()

        assert.are.equal(3, #shown_widgets)
        assert.is_true(shown_widgets[1].invisible)
        assert.is_true(shown_widgets[2].invisible)
        assert.is_true(settings_parent._deferred_arrange_parent)
    end)

    it("reveals a deferred settings page after backing out of the arrange root", function()
        local settings_parent = { title = "Controls", _deferred_arrange_parent = true }
        settings_parent.invisible = true
        ui_manager:show(settings_parent)
        require("modules/settings/zen_settings_page").claimArrangeRoute = function()
            return {
                opener = { text = "Arrange" },
                path = { "First" },
                deferred_parent = settings_parent,
            }
        end
        ArrangeList.show{
            allow_arrange = false,
            item_table = {
                {
                    text = "First",
                    sub_item_table = {{ text = "Destination" }},
                },
            },
        }

        shown_widgets[3]:onClose()
        shown_widgets[2]:onClose()

        assert.are.equal(3, #shown_widgets)
        assert.are.equal(settings_parent, shown_widgets[1])
        assert.is_false(settings_parent.invisible)
    end)
end)
