describe("button icon alignment", function()
    local saved_labels, saved_rendertext, Labels

    before_each(function()
        saved_labels = package.loaded["common/ui/button_labels"]
        saved_rendertext = package.loaded["ui/rendertext"]
        ZenSpec.unload("common/ui/button_labels")
        ZenSpec.replace("ui/rendertext", { sizeUtf8Text = function(_self, _x, _width, _face, text)
            assert.equals("Return to page 1", text)
            return { y_top = 14, y_bottom = 4 }
        end })
        Labels = require("common/ui/button_labels")
    end)

    after_each(function()
        package.loaded["common/ui/button_labels"] = saved_labels
        package.loaded["ui/rendertext"] = saved_rendertext
    end)

    it("matches the text's visible center for different font baselines", function()
        for _i, baseline in ipairs({ 18, 20, 22 }) do
            local painted_y
            local icon = { paintTo = function(_self, _bb, _x, y) painted_y = y end }
            local label = {
                getSize = function() return { h = 30 } end,
                getFittedText = function() return "Return to page 1" end,
                getBaseline = function() return baseline end,
            }
            Labels.alignIcon(icon, label)
            icon:paintTo({}, 10, 20)
            assert.equals(baseline, painted_y)
        end
    end)
end)
