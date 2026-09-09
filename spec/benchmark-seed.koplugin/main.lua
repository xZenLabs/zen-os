local UIManager = require("ui/uimanager")
local Seed = require("ui/widget/container/widgetcontainer"):extend{ name = "zen_perf_seed" }

function Seed:init()
    UIManager:nextTick(function()
        local BookInfoManager = require("bookinfomanager")
        BookInfoManager:terminateBackgroundJobs()
        for path in io.lines(assert(os.getenv("ZEN_PERF_SEED_BOOKS"))) do
            assert(BookInfoManager:extractBookInfo(path, {
                max_cover_w = 1236, max_cover_h = 1648,
            }), path)
        end
        BookInfoManager:closeDbConnection()
        print("ZEN_PERF_SEED_COMPLETE")
        UIManager:quit()
    end)
end

return Seed
