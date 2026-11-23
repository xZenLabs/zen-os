describe("restart notice", function()
    local original_modules
    local UIManager

    local module_names = {
        "gettext",
        "ui/event",
        "ui/uimanager",
        "ui/widget/infomessage",
    }

    before_each(function()
        original_modules = {}
        for _i, name in ipairs(module_names) do
            original_modules[name] = package.loaded[name]
        end

        UIManager = {
            events = {},
            show = function(self, widget) self.widget = widget end,
            tickAfterNext = function(self, callback) self.restart_callback = callback end,
            broadcastEvent = function(self, event) self.events[#self.events + 1] = event end,
        }
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/event", { new = function(_, name) return { name = name } end })
        ZenSpec.replace("ui/uimanager", UIManager)
        ZenSpec.replace("ui/widget/infomessage", { new = function(_, props) return props end })
        ZenSpec.unload("common/restart")
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do
            package.loaded[name] = original_modules[name]
        end
        ZenSpec.unload("common/restart")
    end)

    it("renders a notice before broadcasting the restart", function()
        require("common/restart").request()

        assert.are.equal("Restarting...", UIManager.widget.text)
        assert.are.equal(0, #UIManager.events)

        UIManager.restart_callback()

        assert.are.equal(1, #UIManager.events)
        assert.are.equal("Restart", UIManager.events[1].name)
    end)

    it("can restart without replacing an existing progress screen", function()
        require("common/restart").request{ show_notice = false }

        assert.is_nil(UIManager.widget)
        assert.are.equal(0, #UIManager.events)

        UIManager.restart_callback()

        assert.are.equal(1, #UIManager.events)
        assert.are.equal("Restart", UIManager.events[1].name)
    end)

    it("runs a custom action under the same notice instead of restarting", function()
        local ran = 0
        require("common/restart").request{ action = function() ran = ran + 1 end }

        assert.are.equal("Restarting...", UIManager.widget.text)
        UIManager.restart_callback()

        assert.are.equal(1, ran)
        assert.are.equal(0, #UIManager.events)
    end)
end)
