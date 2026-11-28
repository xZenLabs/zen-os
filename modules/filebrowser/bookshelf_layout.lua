-- Original bookshelf extension for ZenOS alpha20.
local M = {}
local plugin_ref
function M.bind(plugin)
    if plugin then plugin_ref = plugin end
end
-- Migrate experimental layout defaults before reading the current configuration.
local function settings()
    local plugin = plugin_ref or rawget(_G, "__ZEN_UI_PLUGIN")
    local cfg = plugin and plugin.config and plugin.config.bookshelf_layout or {}
    if cfg.simplified_version ~= 12 then
        cfg.uniform_height = true
        cfg.mode = "covers"
        cfg.simplified_version = 12
    end
    cfg.mode = cfg.mode or "covers"
    return cfg
end
function M.enabled(menu)
    return settings().enabled == true and menu and (menu.name == "filemanager" or menu.name == "kindle_library")
        and menu._do_cover_images ~= false
end
function M.filter(menu, entries)
    local filter = settings().filter or "all"
    if not M.enabled(menu) or filter == "all" or type(entries) ~= "table" then return entries end
    local folder = require("modules/filebrowser/folder_cover")
    local status = require("common/book_status")
    local result = {}
    for _i, entry in ipairs(entries) do
        local path = entry.file or entry.path
        if not folder.isBook(entry) or type(path) ~= "string" then
            result[#result+1] = entry
        else
            local ok, data = pcall(status.getFileStatusData, path)
            if not ok or not data or (filter == "tbr" and data.display_status == "tbr")
                or (filter ~= "tbr" and data.effective_status == filter) then
                result[#result+1] = entry
            end
        end
    end
    return result
end
function M.entrySpine(entry, index)
    if not require("modules/filebrowser/folder_cover").isBook(entry) then return false end
    local cfg = settings()
    return cfg.mode == "spines" or (cfg.mode == "mixed" and not (M.cover_slots and M.cover_slots[index]))
end
function M.isSpine(item)
    return M.enabled(item.menu) and item._zen_is_book and M.entrySpine(item.entry, item.entry.idx or 1)
end
function M.spacing(menu)
    return require("device").screen:scaleBySize(3)
end
function M.sideMargin(menu)
    return math.floor(menu.inner_dimen.w * math.max(0,math.min(10,5))/100)
end
function M.innerPadding(menu) return require("device").screen:scaleBySize(12) end
function M.availableWidth(menu) return math.max(1,menu.inner_dimen.w-2*(M.sideMargin(menu)+M.innerPadding(menu))) end
function M.centered() return true end
function M.dimFinished()
    local plugin = plugin_ref or rawget(_G, "__ZEN_UI_PLUGIN")
    return plugin and plugin.config and (plugin.config.browser_cover_badges or {}).dim_finished_books == true
end
function M.uniformHeight() return settings().uniform_height ~= false end
-- Cache cover aspect ratios for the current layout pass; widths stay nominal
-- so variable book heights do not change shelf capacity.
function M.metrics(menu, entry, index)
    local cfg = settings()
    local path = entry.file or entry.path
    menu._shelf_metrics = menu._shelf_metrics or {}
    local cached = path and menu._shelf_metrics[path]
    if not cached then
        local meta
        if type(path)=="string" and require("modules/filebrowser/folder_cover").isBook(entry) then
            local ok, result = pcall(function() return require("bookinfomanager"):getBookInfo(path,false) end)
            if ok then meta=result end
        end
        local cw,ch=meta and tonumber(meta.cover_w),meta and tonumber(meta.cover_h)
        local ratio=cw and ch and cw>0 and ch>0 and cw/ch or 2/3
        cached={ratio=ratio}
        if path then menu._shelf_metrics[path]=cached end
    end
    local base=M.bookHeight(menu)
    local h=math.floor(base*(cfg.uniform_height and 1 or math.max(0.75,math.min(1,0.90*math.sqrt((2/3)/cached.ratio)))))
    if M.entrySpine(entry,index) then
        return math.max(12,math.floor(base*0.22)),h
    end
    local nominal = math.max(12,math.floor(base*2/3))
    if M.uniformHeight() then return nominal,base end
    local border = 2
    local natural_h = math.floor((nominal-2*border)/cached.ratio+0.5)+2*border
    return nominal,math.max(12,math.min(base, natural_h))
end
function M.width(menu,entry,index)
    local w=M.metrics(menu,entry,index)
    return math.min(M.availableWidth(menu),w)
end
-- Keep native fixed-count pagination; choose a count that fits every page.
function M.plan(menu, first, count)
    local rows, row, used = {}, nil, 0
    local margin = M.spacing(menu)
    local limit = M.availableWidth(menu)
    for i=first,first+count-1 do
        local entry = menu.item_table and menu.item_table[i]
        if not entry then break end
        local w = M.width(menu,entry,i)
        if not row or #row >= (menu._shelf_perrow or math.huge) then
            row={}; rows[#rows+1]=row; used=0
        end
        row[#row+1]={index=i,width=w}; used=used+w+margin
    end
    local nominal = menu._shelf_nominal_width or limit
    local anchor = math.max(0, math.floor((menu.inner_dimen.w-nominal)/2))
    for _i, cells in ipairs(rows) do
        local fixed, flexible, spine_count = 0, 0, 0
        for _i, cell in ipairs(cells) do
            cell.spine = M.entrySpine(menu.item_table[cell.index],cell.index)
            if cell.spine then flexible=flexible+cell.width; spine_count=spine_count+1
            else fixed=fixed+cell.width end
        end
        local gaps=(#cells-1)*margin
        local budget=math.max(1,nominal-gaps-fixed)
        local full=#cells==(menu._shelf_perrow or 0)
        if flexible>0 and flexible>budget then
            local factor=budget/flexible
            for _i, cell in ipairs(cells) do
                if cell.spine then cell.width=math.max(1,math.floor(cell.width*factor)) end
            end
        end
        local sum=gaps; for _i,cell in ipairs(cells) do sum=sum+cell.width end
        -- Only a geometry change or non-book entries should need this fallback.
        if sum>nominal then
            local factor=math.max(1,nominal-gaps)/math.max(1,sum-gaps)
            for _i,cell in ipairs(cells) do cell.width=math.max(1,math.floor(cell.width*factor)) end
            sum=gaps; for _i,cell in ipairs(cells) do sum=sum+cell.width end
        end
        -- Center complete rows; anchor incomplete rows to the full shelf origin.
        cells.offset=full and math.max(0,math.floor((menu.inner_dimen.w-sum)/2)) or anchor
    end
    return rows
end
function M.bookHeight(menu)
 local screen=require("device").screen
 local size=tonumber(settings().density_size) or 0
 return math.max(20,menu.item_height-screen:scaleBySize(19))
end
local function redraw(menu)
    local UI = require("ui/uimanager")
    UI:setDirty(menu.show_parent or menu, "ui")
    UI:setDirty("all", "ui")
end
function M.closePreview(menu, clear)
    local popup = menu._shelf_popup
    menu._shelf_popup = nil
    if clear then menu._shelf_selected = nil end
    if popup then require("ui/uimanager"):close(popup) end
end
function M.grid(menu, original, ...)
    if not M.enabled(menu) then return original(menu, ...) end
    local cfg = settings()
    menu._shelf_metrics = {}
    local cols = math.max(3, math.min(12, 5 + (tonumber(cfg.density_size) or 0)))
    local size = tonumber(cfg.density_size) or 0
    local rows = size > 0 and 4 or size < 0 and 2 or 3
    local screen = require("device").screen
    local landscape = screen:getWidth() > screen:getHeight()
    local old_perpage = menu.perpage
    local requested_page = menu.page or 1
    local old_first = (requested_page-1)*(old_perpage or 1)+1
    local rotated = menu._shelf_landscape ~= nil and menu._shelf_landscape ~= landscape
    local keys = {"nb_cols_portrait", "nb_rows_portrait", "nb_cols_landscape", "nb_rows_landscape"}
    local old = {}
    for _i, k in ipairs(keys) do old[k] = menu[k] end
    menu.nb_cols_portrait, menu.nb_rows_portrait = cols, rows
    menu.nb_cols_landscape, menu.nb_rows_landscape = cols+2, rows-1
    -- Borrow the native grid geometry without changing its saved layout settings.
    local ok, result = pcall(original, menu, ...)
    for _i, k in ipairs(keys) do menu[k] = old[k] end
    if not ok then error(result) end
    local maxrows = menu.nb_rows or (landscape and rows-1 or rows)
    menu._shelf_rows = maxrows
    local total = #(menu.item_table or {})
    M.cover_slots = {}
    local gap, limit, h = M.spacing(menu), M.availableWidth(menu), M.bookHeight(menu)
    local covers = size < 0 and 1 or size > 0 and 3 or 2
    local cw, sw = math.max(12,math.floor(h*2/3)), math.max(12,math.floor(h*0.22))
    -- Capacity uses nominal dimensions regardless of individual book variation.
    local n
    if cfg.mode == "spines" then n=math.floor((limit+gap)/(sw+gap))
    elseif cfg.mode == "covers" then n=math.floor((limit+gap)/(cw+gap))
    else
        if landscape then
            -- Scale the portrait mix by the number of nominal mixed groups that fit.
            local portrait_spines = size<0 and 4 or size>0 and 7 or 6
            local group_width = covers*(cw+gap)+portrait_spines*(sw+gap)
            covers = math.max(covers, math.floor(covers*(limit+gap)/group_width+0.5))
        end
        covers=math.max(1,math.min(covers,math.floor((limit+gap)/(cw+gap))))
        local spines=math.max(0,math.floor((limit+gap-covers*(cw+gap))/(sw+gap)))
        if not landscape then spines=math.min(size<0 and 4 or size>0 and 7 or 6,spines) end
        n=covers+spines
    end
    n=math.max(1,n)
    menu._shelf_perrow=n
    local nominal_covers=cfg.mode=="spines" and 0 or cfg.mode=="covers" and n or math.min(covers,n)
    menu._shelf_nominal_width=math.min(limit,nominal_covers*cw+(n-nominal_covers)*sw+(n-1)*gap)
    -- Seed each row independently so mixed cover positions stay stable on redraw.
    if cfg.mode == "mixed" or not cfg.mode then
        for first=1,total,n do
            local slots={}; for j=1,n do slots[j]=j end
            local seed=math.floor((first-1)/n)+17
            for j=n,2,-1 do
                seed=(seed*48271)%2147483647
                local k=seed%j+1; slots[j],slots[k]=slots[k],slots[j]
            end
            for j=1,math.min(covers,n) do M.cover_slots[first+slots[j]-1]=true end
        end
    end
    menu.perpage=n*maxrows
    menu.page_num=math.max(1,math.ceil(total/menu.perpage))
    -- Keep the previously visible first book on screen after rotation.
    if (rotated or (menu._shelf_landscape ~= nil and old_perpage ~= menu.perpage)) and old_perpage and old_perpage > 0 then
        menu.page = math.floor((old_first-1)/menu.perpage)+1
        M.closePreview(menu, true)
    else
        menu.page = requested_page
    end
    menu._shelf_landscape = landscape
    menu.page=math.max(1,math.min(menu.page or 1,menu.page_num))
    return result
end
local function openBook(path)
    local fm = require("apps/filemanager/filemanager").instance
    if fm then fm:openFile(path) else require("apps/reader/readerui"):showReader(path) end
end
local function showPreview(item)
    local menu, path = item.menu, item.filepath or item.entry.path or item.entry.file
    local UI = require("ui/uimanager")
    local Screen = require("device").screen
    local Geom = require("ui/geometry")
    local Input = require("ui/widget/container/inputcontainer")
    local Frame = require("ui/widget/container/framecontainer")
    local Gesture = require("ui/gesturerange")
    local BB = require("ffi/blitbuffer")
    local cfg = settings()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(8)
    local top, bottom = math.floor(sh*0.08), math.floor(sh*0.88)
    local d = item.dimen
    -- Place the preview on whichever side of the selected book has more room.
    local above, below = d.y-top-pad, bottom-d.y-(item.height or d.h)-pad
    local use_above = above > below
    local h = math.min(math.floor(sh*0.24), math.max(above,below))
    if h < Screen:scaleBySize(65) then
        require("logger").warn("Bookshelf preview: insufficient space", h, d.y, item.height)
        return
    end
    local w = math.floor(sw*78/100)
    local x = math.max(pad,math.min(sw-w-pad,d.x+math.floor(((item.width or d.w)-w)/2)))
    local y = use_above and d.y-pad-h or d.y+(item.height or d.h)+pad
    local plugin = plugin_ref or rawget(_G, "__ZEN_UI_PLUGIN")
    assert(type(plugin) == "table" and type(plugin.config) == "table", "Bookshelf: ZenOS plugin unavailable")
    -- home_page returns a patch initializer; requiring it registers the shared API loader.
    require("modules/filebrowser/patches/home_page")
    local Home = require("common/shared_state").get(plugin, "home")
    assert(type(Home) == "table" and type(Home.newDataProvider) == "function", "Bookshelf: Home data API unavailable")
    local provider = Home.newDataProvider(plugin.config, {}, {})
    -- Reuse the Home renderer, but supply the selected book instead of the featured one.
    function provider:getFeaturedBook(_, _, metadata_only)
        return self:getBook(path, metadata_only)
    end
    local widget = require("modules/filebrowser/patches/home/widgets/featured_common").build{
        width=w-4, height=h-4, data=provider,
        module_cfg={interactive=false,cover_width_percent=25,
            synopsis_lines=3,show_description=true},
    }
    local frame = Frame:new{width=w,height=h,padding=0,bordersize=2,background=BB.COLOR_WHITE,widget}
    local popup = Input:new{dimen=Geom:new{x=x,y=y,w=w,h=h}, modal=false,
        ges_events={ShelfTap={Gesture:new{ges="tap",range=Geom:new{x=0,y=0,w=sw,h=sh}}}, ShelfHold={Gesture:new{ges="hold",range=Geom:new{x=0,y=0,w=sw,h=sh}}}},frame}
    function popup:paintTo(bb)
        frame:paintTo(bb,x,y)
        self.dimen = Geom:new{x=x,y=y,w=w,h=h}
    end
    -- Route taps outside the preview back to shelf items or dismiss the selection.
    function popup:onShelfTap(arg, ges)
 ges=ges or arg
 if not ges or not ges.pos then return false end
        if self.dimen:contains(ges.pos) then return true end
        for _i, row in ipairs(menu.layout or {}) do
            for _i, other in ipairs(row) do
                if (other._zen_is_book or (other.entry and require("modules/filebrowser/folder_cover").isBook(other.entry))) and other.dimen and other.dimen:contains(ges.pos) then
                    return M.tap(other, not M.enabled(menu))
                end
            end
        end
        M.closePreview(menu,true); redraw(menu); return false
    end
    function popup:onShelfHold(arg, ges)
        ges=ges or arg
        if not ges or not ges.pos then return false end
        if self.dimen:contains(ges.pos) then return true end
        for _i, row in ipairs(menu.layout or {}) do
            for _i, other in ipairs(row) do
                if other.dimen and other.dimen:contains(ges.pos) then
                    M.closePreview(menu,true); redraw(menu)
                    return other:onHoldSelect()
                end
            end
        end
        M.closePreview(menu,true); redraw(menu); return true
    end
    function popup:onCloseWidget()
        if menu._shelf_popup==self then menu._shelf_popup=nil; menu._shelf_selected=nil end
        require("common/widget_resources").free(frame)
        redraw(menu)
    end
    menu._shelf_popup=popup
    UI:show(popup)
    UI:setDirty(popup, "ui", popup.dimen)
end
function M.tap(item, details)
    if not details and (not M.enabled(item.menu) or not item._zen_is_book) then return false end
    local menu, path = item.menu, item.filepath or item.entry.path or item.entry.file
    local UI = require("ui/uimanager")
    -- First tap selects and previews; tapping the same book again opens it.
    local same = menu._shelf_selected == path
    M.closePreview(menu,false)
    if same then
        menu._shelf_selected = nil
        menu:onMenuSelect(item.entry)
    else
        menu._shelf_selected = path
        redraw(menu)
        local ok, err = pcall(showPreview,item)
        if not ok then
            require("logger").warn("Bookshelf preview:",err)
            local Info = require("ui/widget/infomessage")
            UI:show(Info:new{text="Bookshelf preview error: " .. tostring(err), timeout=4})
        end
    end
    return true
end
-- Respect KOReader's color rendering preference, not a particular device model.
local function colorEnabled()
    return require("common/ui/accent").isSupported()
end
-- Sample a small grid and favor edge colors to approximate the binding color.
local function sampleCover(bb,x,y,w,h)
    local bins = {}
    for i=1,7 do for j=1,7 do
        local c=bb:getPixel(x+math.floor((w-1)*i/8),y+math.floor((h-1)*j/8)):getColorRGB32()
        local r,g,b=tonumber(c.r),tonumber(c.g),tonumber(c.b)
        local key=math.floor(r/48)*36+math.floor(g/48)*6+math.floor(b/48)
        local v=bins[key] or {0,0,0,0,0}
        local weight=(i==1 or i==7 or j==1 or j==7) and 2 or 1
        v[1],v[2],v[3],v[4]=v[1]+r*weight,v[2]+g*weight,v[3]+b*weight,v[4]+weight
        bins[key]=v
    end end
    local best,keybest
    for k,v in pairs(bins) do
        if not best or v[4]>best[4] or (v[4]==best[4] and k<keybest) then best,keybest=v,k end
    end
    return {math.floor(best[1]/best[4]+.5),math.floor(best[2]/best[4]+.5),math.floor(best[3]/best[4]+.5)}
end
-- Use luminance for grayscale conversion and contrasting title text.
local function palette(rgb, enabled)
    local BB=require("ffi/blitbuffer")
    local shade=math.floor(rgb[1]*.299+rgb[2]*.587+rgb[3]*.114+.5)
    return enabled and BB.ColorRGB32(rgb[1],rgb[2],rgb[3],255) or BB.Color8(shade),
        shade<128 and BB.COLOR_WHITE or BB.COLOR_BLACK
end
local function spineColor(item)
    if item._shelf_rgb then return item._shelf_rgb end
    local path=item.filepath or item.entry.path or item.entry.file
    if not path then return end
    local ok,info=pcall(function() return require("bookinfomanager"):getBookInfo(path,true) end)
    if not ok or not info or not info.cover_bb then return end
    local cover=info.cover_bb
    local success,rgb=pcall(sampleCover,cover,0,0,cover:getWidth(),cover:getHeight())
    -- Release the temporary cover buffer after sampling; retain only its RGB values.
    cover:free()
    if success then item._shelf_rgb=rgb; return rgb end
end

-- Paint a simulated back inside the already-rendered cover frame.
function M.paintBack(item, bb)
    if not M.enabled(item.menu) or not item._zen_is_book or M.isSpine(item)
        or item.menu._shelf_selected ~= item.filepath then return false end
    local frame = item._zen_cover_frame
    local d = frame and frame.dimen
    if not d then return false end
    local BB = require("ffi/blitbuffer")
    local common = require("modules/filebrowser/patches/home/widgets/cover_common")
    local b = math.max(1, frame.bordersize or common.BORDER_SIZE or 2)
    local x,y,w,h = d.x+b,d.y+b,d.w-2*b,d.h-2*b
    if w<12 or h<16 then return false end
    local bg,fg=palette(sampleCover(bb,x,y,w,h),colorEnabled())
    local r=common.rounded_enabled() and math.min(math.floor(w/4),require("device").screen:scaleBySize(8)) or 0
    for j=0,h-1 do
        local edge=math.min(j,h-1-j)
        local inset=edge<r and math.ceil(r-math.sqrt(math.max(0,r*r-(r-edge-0.5)^2))) or 0
        bb:paintRect(x+inset,y+j,w-2*inset,1,bg)
    end
    local margin=math.max(3,math.floor(w*0.15))
    local linew=w-2*margin
    local thick=math.max(1,math.floor(h/100))
    local Font = require("ui/font")
    local Text = require("ui/widget/textwidget")
    local title = item._shelf_title or item.text or ""
    local fs = math.max(5, math.min(math.floor(w*.14), require("device").screen:scaleBySize(11)))
    local lines = {title}
    local function measure(t, f)
        local p = Text:new{text=t,face=Font:getFace("cfont",f),padding=0}
        local size = p:getSize()
        local pw,ph = size.w,size.h
        p:free()
        return pw,ph
    end
    if measure(title,fs)>linew then
        local best,score
        for pos in title:gmatch("() %S") do
            local a,c=title:sub(1,pos-1),title:sub(pos+1)
            local v=math.max((measure(a,fs)), (measure(c,fs)))
            if not score or v<score then best,score={a,c},v end
        end
        if best then lines=best end
    end
    while fs>5 do
        local fits=true
        for _i,t in ipairs(lines) do
            local pw,ph=measure(t,fs)
            if pw>linew or ph*#lines>h*.25 then fits=false end
        end
        if fits then break end
        fs=fs-1
    end
    local ty=y+math.floor(h*.07)
    for _i,t in ipairs(lines) do
        local tw=Text:new{text=t,face=Font:getFace("cfont",fs),fgcolor=fg,padding=0,max_width=linew,truncate_with_ellipsis=true}
        local size=tw:getSize()
        if size.w<=linew and ty+size.h<=y+math.floor(h*.34) then
            tw:paintTo(bb,x+math.floor((w-size.w)/2),ty)
            ty=ty+size.h
        end
        tw:free()
    end
    -- Decorative text lines and barcode simulate a back cover, not actual book metadata.
    local lengths={1,.92,.98,.84,.65,0,.97,.89,1,.72}
    for i,f in ipairs(lengths) do
        if f>0 then bb:paintRect(x+margin,y+math.floor(h*(.36+(i-1)*.038)),math.max(1,math.floor(linew*f)),thick,fg) end
    end
    local bw,bh=math.max(5,math.floor(w*.36)),math.max(3,math.floor(h*.12))
    local bx,by=x+w-margin-bw,y+math.floor(h*.77)
    bb:paintRect(bx,by,bw,bh,BB.COLOR_WHITE)
    for i=1,bw-2,3 do
        bb:paintRect(bx+i,by+1,math.min(i%2+1,bw-i-1),math.max(1,bh-2),BB.COLOR_BLACK)
    end
    return true
end

function M.paintSpine(item, bb, x, y)
    local BB = require("ffi/blitbuffer")
    local Font = require("ui/font")
    local Text = require("ui/widget/textwidget")
    local screen = require("device").screen
    local idx = item.entry.idx or 1
    local selected = item.menu._shelf_selected == item.filepath
    local w, h = item.width, item.height
    local pad = math.max(2, screen:scaleBySize(7))
    local bottom = y+h
    local sw = w
    local _, natural_h = M.metrics(item.menu,item.entry,idx)
    local sh = math.min(h,natural_h)
    -- Shorten the selected spine to expose pages without changing its layout bounds.
    if selected then sh=math.max(1,sh-pad*2) end
    local sx = x+math.floor((w-sw)/2)
    local sy = bottom-sh
    local colors = {BB.COLOR_GRAY_4, BB.COLOR_GRAY_6, BB.COLOR_GRAY_5, BB.COLOR_BLACK}
    local bg = colors[idx%4+1]
    local fg = BB.COLOR_WHITE
    local enabled=colorEnabled()
    if enabled then
        local rgb=spineColor(item)
        if rgb then bg,fg=palette(rgb,true) end
    end
    local function rect(a,b,c,d,col) if c>0 and d>0 then bb:paintRect(a,b,c,d,col) end end
    if selected then
        local depth = math.min(pad*2, math.max(1,sy-y))
        for j=0,depth-1 do
            local inset = math.floor((depth-j)*sw/(depth*8))
            rect(sx+inset,sy-depth+j,sw-2*inset,1,BB.COLOR_WHITE)
            for k=0,sw-1,3 do
                local px=math.floor(inset+k*(sw-2*inset-1)/math.max(1,sw-1))
                rect(sx+px,sy-depth+j,1,1,BB.COLOR_GRAY_6)
            end
        end
    end
    for j=0,sh-1 do
        local inset = selected and math.floor(j*sw/(sh*9)) or 0
        if require("modules/filebrowser/patches/home/widgets/cover_common").rounded_enabled() then
            local r=math.min(math.floor(sw/4),screen:scaleBySize(8))
            local edge=math.min(j,sh-1-j)
            if edge<r then inset=math.max(inset,math.ceil(r-math.sqrt(math.max(0,r*r-(r-edge-0.5)^2)))) end
        end
        rect(sx+inset,sy+j,sw-2*inset,1,bg)
    end
    rect(sx+math.floor(sw/5),sy+pad,math.floor(sw*3/5),1,fg)
    rect(sx+math.floor(sw/5),bottom-pad,math.floor(sw*3/5),1,fg)
    local title = item._shelf_title or item.text or ""
    local fs=math.max(5,math.min(math.floor(sw*0.55),screen:scaleBySize(11)))
    local limit=math.max(1,sh-4*pad)
    while fs>5 do
        local probe=Text:new{text=title,face=Font:getFace("cfont",fs),padding=0}
        local fits=probe:getSize().w<=limit and probe:getSize().h<=sw-2
        probe:free()
        if fits then break end
        fs=fs-1
    end
    local tw=Text:new{text=title,face=Font:getFace("cfont",fs),fgcolor=fg,padding=0,max_width=limit,truncate_with_ellipsis=true}
    local size=tw:getSize()
    -- Render the title horizontally first, then rotate its pixels into the spine.
    local temp=BB.new(math.max(1,size.w),math.max(1,size.h),enabled and BB.TYPE_BBRGB32 or BB.TYPE_BB8)
    temp:fill(bg); tw:paintTo(temp,0,0)
    local rw,rh=math.min(size.h,sw-2),math.min(size.w,sh-2*pad)
    local dx,dy=sx+math.floor((sw-rw)/2),sy+math.floor((sh-rh)/2)
    for yy=0,rh-1 do for xx=0,rw-1 do
        bb:setPixel(dx+xx,dy+yy,temp:getPixel(size.w-1-yy,xx))
    end end
    temp:free(); tw:free()
    if M.dimFinished() and item._zen_effective_status=="complete" then bb:lightenRect(sx,sy,sw,sh,0.4) end
    if item.percent_finished and item.percent_finished>0 then
        rect(sx+2,bottom-3,math.floor((sw-4)*math.min(1,item.percent_finished)),2,fg)
    end
    local border= require("modules/filebrowser/patches/home/widgets/cover_common").BORDER_SIZE or 2
    local rounded=require("modules/filebrowser/patches/home/widgets/cover_common").rounded_enabled()
    for j=0,sh-1 do
        local inset=selected and math.floor(j*sw/(sh*9)) or 0
        if rounded then
            local r=math.min(math.floor(sw/4),screen:scaleBySize(8))
            local edge=math.min(j,sh-1-j)
            if edge<r then inset=math.max(inset,math.ceil(r-math.sqrt(math.max(0,r*r-(r-edge-0.5)^2)))) end
        end
        local span=sw-2*inset
        if j<border or j>=sh-border then rect(sx+inset,sy+j,span,1,BB.COLOR_BLACK)
        else
            rect(sx+inset,sy+j,border,1,BB.COLOR_BLACK)
            rect(sx+sw-inset-border,sy+j,border,1,BB.COLOR_BLACK)
        end
    end

end
-- Paint the shelf ledge after its books, keeping it independent of book widgets.
function M.decorateRow(container, width, height, row_index, menu)
    local BB = require("ffi/blitbuffer")
    local screen = require("device").screen
    local original = container.paintTo
    container.paintTo = function(self, bb, x, y)
        original(self, bb, x, y)
        local h = math.max(3, screen:scaleBySize(7))
        local inset = M.sideMargin(menu)
        local sy = y + height - h
        local function rect(dx, dy, w, hh, color)
            if w > 0 and hh > 0 then bb:paintRect(dx, dy, w, hh, color) end
        end
        rect(x+inset, sy, width-2*inset, 1, BB.COLOR_GRAY_6)
        rect(x+inset, sy+1, width-2*inset, h-2, BB.COLOR_BLACK)
        rect(x+inset, sy+h-1, width-2*inset, 1, BB.COLOR_GRAY_6)

    end
end
return M
