local function apply_add_sort_title_natural()
    local BookList = require("ui/widget/booklist")
    local title_sort = require("common/title_sort")
    local _ = require("gettext")

    local title_collate = BookList.collates.title
    if title_collate and not title_collate._zen_article_sort_patched then
        local orig_init_sort_func = title_collate.init_sort_func
        title_collate.init_sort_func = function(...)
            local fallback = type(orig_init_sort_func) == "function"
                and orig_init_sort_func(...) or nil
            return function(a, b)
                local ad = a and a.doc_props or {}
                local bd = b and b.doc_props or {}
                local at = ad.display_title or ad.title
                    or (a and (a.text or a.path or a.file)) or ""
                local bt = bd.display_title or bd.title
                    or (b and (b.text or b.path or b.file)) or ""
                local ak = title_sort.key(at):lower()
                local bk = title_sort.key(bt):lower()
                if ak == bk and fallback then return fallback(a, b) end
                return ak < bk
            end
        end
        title_collate._zen_article_sort_patched = true
    end

    BookList.collates.title_natural = {
        text = _("Title natural"),
        menu_order = 100,
        item_func = function(item, ui)
            local doc_props = ui.bookinfo:getDocProps(item.path or item.file)
            item.doc_props = doc_props
        end,
        init_sort_func = function()
            return function(a, b)
                local at = a and a.doc_props and a.doc_props.display_title or ""
                local bt = b and b.doc_props and b.doc_props.display_title or ""
                return title_sort.less(at, bt, true)
            end
        end,
    }
end

return apply_add_sort_title_natural
