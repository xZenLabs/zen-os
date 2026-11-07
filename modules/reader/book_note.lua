local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local M = {}

function M.path(book)
    if type(book) ~= "string" or book == "" then return nil end
    local sidecar = DocSettings:findSidecarFile(book, true)
    local directory = sidecar and sidecar:match("^(.*)/[^/]+$") or DocSettings:getSidecarDir(book)
    return directory .. "/zen-note.txt"
end

function M.read(book)
    local path = M.path(book)
    if not path then return nil, "invalid book path" end
    local attributes = lfs.symlinkattributes(path)
    if not attributes then return "", nil, path end
    if attributes.mode ~= "file" then return nil, "book note is not a regular file" end
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local text, read_err = file:read("*a")
    file:close()
    return text, read_err, path, attributes.modification
end

function M.save(book, text, expected)
    if type(text) ~= "string" then return nil, "invalid note text" end
    local current, err, path = M.read(book)
    if current == nil then return nil, err end
    if expected ~= nil and current ~= expected then return nil, "book note changed outside the editor" end
    local directory = path:match("^(.*)/[^/]+$")
    if not util.makePath(directory) then return nil, "could not create book metadata folder" end
    local temporary = path .. ".zen-write"
    if lfs.symlinkattributes(temporary) then return nil, "book note temporary file already exists" end
    local file, open_err = io.open(temporary, "wb")
    if not file then return nil, open_err end
    local wrote, write_err = file:write(text)
    local flushed, flush_err
    if wrote then flushed, flush_err = file:flush() end
    local synced, sync_err
    if flushed then synced, sync_err = require("ffi/util").fsyncOpenedFile(file, true) end
    local closed, close_err = file:close()
    if not wrote or synced ~= true or not closed then
        os.remove(temporary)
        return nil, write_err or flush_err or sync_err or close_err
    end
    local replaced, replace_err = os.rename(temporary, path)
    if not replaced then os.remove(temporary); return nil, replace_err end
    return require("ffi/util").fsyncDirectory(directory)
end

function M.delete(book, expected)
    local current, err, path = M.read(book)
    if current == nil then return nil, err end
    if expected ~= nil and current ~= expected then return nil, "book note changed outside the editor" end
    if not lfs.symlinkattributes(path) then return true end
    return os.remove(path)
end

function M.install()
    if DocSettings._zen_book_note_location then return end
    DocSettings._zen_book_note_location = true
    local update_location = DocSettings.updateLocation
    DocSettings.updateLocation = function(source, destination, copy)
        local text, read_err, source_path = M.read(source)
        local exists = source_path and lfs.attributes(source_path, "mode") == "file"
        local result = update_location(source, destination, copy)
        if not read_err and text and exists and destination
                and lfs.attributes(destination, "mode") == "file" then
            local target = M.path(destination)
            if target ~= source_path then
                local saved, err
                if not lfs.symlinkattributes(target) then saved, err = M.save(destination, text, "") end
                if saved and not copy then
                    if os.remove(source_path) then
                        DocSettings.removeSidecarDir(source_path:match("^(.*)/[^/]+$"))
                    end
                elseif not saved then
                    require("logger").warn("ZenOS book note kept at", source_path, err or "destination already has a note")
                end
            end
        end
        return result
    end
end

function M.show(book, on_saved)
    local UIManager = require("ui/uimanager")
    local _ = require("gettext")
    local function show_error(err)
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("Could not save book note.") .. "\n" .. tostring(err),
        })
    end
    local original, err = M.read(book)
    if original == nil then show_error(err); return end
    local dialog
    dialog = require("ui/widget/inputdialog"):new{
        title = _("Book note"), description = book:match("([^/]+)$"),
        input = original, input_type = "text", allow_newline = true,
        text_height = math.floor(require("device").screen:getHeight() * 0.25),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local saved, save_err = M.save(book, dialog:getInputText(), original)
                if not saved then show_error(save_err); return end
                UIManager:close(dialog)
                if on_saved then on_saved() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return M
