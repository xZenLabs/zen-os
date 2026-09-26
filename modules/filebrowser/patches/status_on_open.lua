-- zen_ui: status_on_open patch
-- Marks new, on-hold, and explicit TBR books as reading when opened.

local function apply_status_on_open()
    local ok_util, filemanagerutil = pcall(require, "apps/filemanager/filemanagerutil")
    if not ok_util or type(filemanagerutil.openFile) ~= "function" then
        return
    end

    local _orig_openFile = filemanagerutil.openFile

    filemanagerutil.openFile = function(ui, file, caller_pre_callback, no_dialog)
        local DocSettings = require("docsettings")
        local BookList = require("ui/widget/booklist")
        local book_status = require("common/book_status")

        -- Safely open doc settings for this file, without creating sidecar files unnecessarily yet?
        -- Well, if it's being opened, it will create one anyway.
        local doc_settings = DocSettings:open(file)
        local summary = doc_settings:readSetting("summary") or {}
        local acknowledged = book_status.acknowledgeNewVersion(doc_settings)
        local was_tbr = false
        pcall(function()
            local TBRIndex = require("common/tbr_index")
            was_tbr = TBRIndex.isExplicit(file)
            if was_tbr then TBRIndex.setExplicit(file, false) end
        end)

        if was_tbr or not summary.status or summary.status == "new"
                or summary.status == "abandoned" then
            summary.status = "reading"
            filemanagerutil.saveSummary(doc_settings, summary)
            BookList.setBookInfoCacheProperty(file, "status", "reading")
            book_status.invalidate(file)
        elseif acknowledged and type(doc_settings.flush) == "function" then
            doc_settings:flush()
        end

        pcall(function()
            require("common/tbr_index").refreshPath(file, doc_settings)
        end)
        pcall(function()
            require("common/memory_policy").releaseForReader()
        end)

        if not ui then
            return require("apps/reader/readerui"):showReader(file)
        end
        return _orig_openFile(ui, file, caller_pre_callback, no_dialog)
    end
end

return apply_status_on_open
