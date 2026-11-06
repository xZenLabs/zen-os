-- Displays a slim 3-2-1 countdown bar at the bottom of the screen, then
-- takes a screenshot and shows the standard save dialog.
-- Uses toast = true so UIManager never stops event propagation at this widget;
-- taps/swipes pass through to the UI below.
--
-- Usage:
--   require("modules/menu/patches/countdown_screenshot").run(seconds)

local BD               = require("ui/bidi")
local Blitbuffer       = require("ffi/blitbuffer")
local ButtonDialog     = require("ui/widget/buttondialog")
local CenterContainer  = require("ui/widget/container/centercontainer")
local DataStorage      = require("datastorage")
local Device           = require("device")
local Font             = require("ui/font")
local FrameContainer   = require("ui/widget/container/framecontainer")
local Geom             = require("ui/geometry")
local logger           = require("common/zen_logger").new("countdown_screenshot")
local TextWidget       = require("ui/widget/textwidget")
local UIManager        = require("ui/uimanager")
local WidgetContainer  = require("ui/widget/container/widgetcontainer")
local Screen           = Device.screen
local util             = require("util")
local _                = require("gettext")
local icons            = require("common/inline_icon_map")
local zen_utils        = require("common/utils")

local M = {}

-- Returns the LocalSend plugin instance if loaded, nil otherwise.
local function getLocalsendPlugin()
    local ok_f, FM = pcall(require, "apps/filemanager/filemanager")
    local ok_r, RU = pcall(require, "apps/reader/readerui")
    local ui = (ok_f and FM.instance) or (ok_r and RU.instance)
    return ui and ui.localsend or nil
end

-- Slim passthrough bar pinned to the bottom of the screen.
-- toast = true tells UIManager to forward events through this widget
-- without stopping propagation, so taps/swipes still reach the UI below.
local CountdownBar = WidgetContainer:extend{ toast = true }

function CountdownBar:init()
    local screen_w = Screen:getWidth()
    -- Match the zen status bar height (icon_size from status_bar.lua)
    local bar_h    = Screen:scaleBySize(35)
    self.dimen = Geom:new{ x = 0, y = 0, w = screen_w, h = bar_h }
    self[1] = FrameContainer:new{
        width      = screen_w,
        height     = bar_h,
        background = Blitbuffer.COLOR_BLACK,
        bordersize = 0,
        padding    = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = bar_h },
            TextWidget:new{
                text    = self.count,
                face    = Font:getFace("infofont", Screen:scaleBySize(13)),
                fgcolor = Blitbuffer.COLOR_WHITE,
            },
        },
    }
end

local function safe_filename_part(text)
    if type(text) ~= "string" then return nil end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil end
    text = text:gsub("[/\\:*?\"<>|]", "_"):gsub("%s+", "_")
    text = text:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
    text = text:gsub("%%", "%%%%")
    if text == "" then return nil end
    return zen_utils.truncateUtf8Bytes(text, 80)
end

local function get_screenshot_context_name()
    local ok_r, RU = pcall(require, "apps/reader/readerui")
    local reader = ok_r and RU.instance
    local props = reader and reader.doc_props
    local title = props and props.title
    if title and title ~= "" then return title end
    return rawget(_G, "__ZEN_UI_ACTIVE_TAB_LABEL")
end

local function get_top_widget_name()
    local stack = UIManager._window_stack
    local top = stack and stack[#stack]
    local widget = top and top.widget
    return tostring(widget and (widget.name or widget.id or widget.class or widget) or "nil")
end

local function get_device_name()
    return tostring(Device.model or Device.model_name or Device.device_model
        or Device.product or Device.name or "unknown")
end

-- Screen:shot reads the framebuffer; flush pending paints without an e-ink flash.
local function repaint_before_screenshot()
    local ok, err = pcall(function() UIManager:forceRePaint() end)
    if not ok then
        logger.dbg("forceRePaint before shot failed:", err)
    end
end

local function show_save_dialog(screenshot_name)
    local dialog
    -- Each button in its own row so all render at equal full width.
    local buttons = {
        {
            {
                text     = icons.display .. "  " .. _("View"),
                align    = "left",
                callback = function()
                    local ImageViewer = require("ui/widget/imageviewer")
                    UIManager:show(ImageViewer:new{
                        file            = screenshot_name,
                        modal           = true,
                        with_title_bar  = false,
                        buttons_visible = true,
                    })
                end,
            },
        },
    }
    --[[ Set as wallpaper (disabled)
    if Device:supportsScreensaver() then
        table.insert(buttons, {
            {
                text = icons.wallpaper .. "  " .. _("Set as wallpaper"),
                callback = function()
                    G_reader_settings:saveSetting("screensaver_type", "document_cover")
                    G_reader_settings:saveSetting("screensaver_document_cover", screenshot_name)
                    UIManager:close(dialog)
                end,
            },
        })
    end
    --]]
    local ls = getLocalsendPlugin()
    if ls then
        table.insert(buttons, {
            {
                text     = icons.send .. "  " .. _("Send with LocalSend"),
                align    = "left",
                callback = function()
                    UIManager:close(dialog)
                    ls:openFirewall()
                    -- Use the already-loaded sender module directly to pass the
                    -- filepath, bypassing the no-arg wrapper LocalSend:showFileSendFlow().
                    local lssender = package.loaded["localsend_sender"]
                    if lssender then
                        lssender.showFileSendFlow(ls, screenshot_name)
                    end
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text     = icons.delete .. "  " .. _("Delete"),
            align    = "left",
            callback = function()
                os.remove(screenshot_name)
                UIManager:close(dialog)
            end,
        },
    })
    dialog = ButtonDialog:new{
        title   = _("Screenshot saved to:") .. "\n\n" .. BD.filepath(screenshot_name) .. "\n",
        modal   = true,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- Run the countdown, take the screenshot, then show the save dialog.
function M.run(seconds)
    seconds = tonumber(seconds) or 3
    seconds = math.max(0, math.min(10, math.floor(seconds)))
    local current_bar

    local function close_bar()
        if current_bar then
            UIManager:close(current_bar, "ui", current_bar.dimen)
            current_bar = nil
        end
    end

    local function do_shot()
        close_bar()
        UIManager:scheduleIn(0.05, function()
            repaint_before_screenshot()
            local screenshot_dir = DataStorage:getFullDataDir() .. "/screenshots"
            util.makePath(screenshot_dir)
            local context_name = get_screenshot_context_name()
            local prefix = safe_filename_part(context_name)
            local pattern = prefix and (screenshot_dir .. "/" .. prefix .. "_Screenshot_%Y-%m-%d_%H%M%S.png")
                or (screenshot_dir .. "/Screenshot_%Y-%m-%d_%H%M%S.png")
            local name = os.date(pattern)
            logger.dbg("taking shot",
                "file=", name,
                "context=", tostring(context_name),
                "active_tab_label=", tostring(rawget(_G, "__ZEN_UI_ACTIVE_TAB_LABEL")),
                "top_widget=", get_top_widget_name(),
                "device=", get_device_name(),
                "screen=", tostring(Screen:getWidth()) .. "x" .. tostring(Screen:getHeight()))
            Screen:shot(name)
            logger.dbg("saved", name)
            show_save_dialog(name)
        end)
    end

    local function show_count(n, next_fn)
        close_bar()
        current_bar = CountdownBar:new{ count = tostring(n) }
        UIManager:show(current_bar)
        UIManager:setDirty(current_bar, "ui")
        UIManager:scheduleIn(1, next_fn)
    end

    local function step(n)
        if n <= 0 then
            do_shot()
            return
        end
        show_count(n, function() step(n - 1) end)
    end

    step(seconds)
end

return M
