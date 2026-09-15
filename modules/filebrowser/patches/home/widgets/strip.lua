local shared = require("modules/filebrowser/patches/home/widgets/strip_common")
local _ = require("gettext")

return {
    id = "strip",
    label = _("Book strip"),
    size = shared.SIZE,
    preferredHeight = function(ctx)
        return shared.preferred_height(ctx.width, ctx.module_cfg)
    end,
    preferredInsets = function(ctx)
        return shared.preferred_insets(ctx.width, ctx.module_cfg)
    end,
    build = function(ctx)
        return shared.build_strip(ctx)
    end,
}
