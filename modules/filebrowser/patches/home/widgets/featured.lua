local shared = require("modules/filebrowser/patches/home/widgets/featured_common")
local _ = require("gettext")

return {
    id = "featured",
    label = _("Featured book"),
    size = shared.SIZE,
    -- Renders at any height (the cover scales), so it may be squeezed when
    -- the Home does not fit every widget at its preferred height.
    elastic = true,
    preferredHeight = function(ctx)
        return shared.preferred_height(ctx.width, ctx.module_cfg, ctx.data)
    end,
    preferredInsets = function(ctx)
        return shared.preferred_insets(ctx.width, ctx.module_cfg, ctx.data)
    end,
    build = function(ctx)
        return shared.build(ctx)
    end,
}
