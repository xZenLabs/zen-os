describe("navigation button model", function()
    local original_plugin
    local calls

    before_each(function()
        original_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        _G.__ZEN_UI_PLUGIN = { marker = "zen" }
        calls = {}
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("common/library_destination", {
            folderLabel = function(path) return path:match("([^/]+)$") or path end,
        })
        ZenSpec.replace("common/dispatch_action", {
            onShowZenUIFolder = function(plugin, folder)
                calls[#calls + 1] = { kind = "folder", plugin = plugin, value = folder }
                return true
            end,
            onShowZenUITag = function(plugin, tag)
                calls[#calls + 1] = { kind = "tag", plugin = plugin, value = tag }
                return true
            end,
        })
        ZenSpec.unload("common/nav_button_model")
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = original_plugin
    end)

    it("executes independent folder and tag destinations", function()
        local Model = require("common/nav_button_model")
        local fiction = { type = "folder", folder = "/library/Fiction" }
        local nonfiction = { type = "folder_shortcut", folder = "/library/Nonfiction" }
        local science = { type = "tag", tag = "Science" }

        assert.is_true(Model.execute(fiction))
        assert.is_true(Model.execute(nonfiction))
        assert.is_true(Model.execute(science))

        assert.are.same({
            { kind = "folder", plugin = _G.__ZEN_UI_PLUGIN, value = "/library/Fiction" },
            { kind = "folder", plugin = _G.__ZEN_UI_PLUGIN, value = "/library/Nonfiction" },
            { kind = "tag", plugin = _G.__ZEN_UI_PLUGIN, value = "Science" },
        }, calls)
        assert.are.equal("Fiction", Model.label(nil, fiction))
        assert.are.equal("Nonfiction", Model.label(nil, nonfiction))
        assert.are.equal("Science", Model.label(nil, science))
    end)

    it("exposes filter statuses as strip sources with their status names", function()
        local Model = require("common/nav_button_model")
        assert.same({
            { key = "new", label = "Unread" },
            { key = "reading", label = "Reading" },
            { key = "tbr", label = "To Be Read" },
            { key = "abandoned", label = "On hold" },
            { key = "complete", label = "Finished" },
        }, Model.statuses())

        local finished = { type = "status", status = "complete" }
        assert.is_true(Model.isSource(finished))
        assert.same({ kind = "status", value = "complete" },
            Model.sourceDescriptor(finished))
        assert.are.equal("Finished", Model.label(nil, finished))
    end)
end)
