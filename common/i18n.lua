-- common/i18n.lua — ZenOS
-- Injects the plugin's .po translations into KOReader's GetText tables for
-- already-loaded code, then installs a composable outer wrapper for ZenOS
-- modules. This keeps another plugin's catalog from taking priority over
-- ZenOS while preserving that plugin's own previously captured wrapper.
--
-- USAGE: call i18n.install() early in main.lua (before menus are built).
-- The installation is process-wide; uninstall() is only for explicit teardown.

local logger = require("common/zen_logger").new("i18n")

local _dir = (debug.getinfo(1, "S").source:match("^@(.+/)") or "./")
local _translations = {}
local _contexts = {}

-- ---------------------------------------------------------------------------
-- Minimal .po parser — handles msgctxt, msgid, msgstr, multiline continuations
-- ---------------------------------------------------------------------------
local function parsePO(path)
    local f = io.open(path, "r")
    if not f then return nil end

    local translations = {}  -- [msgid] = msgstr
    local contexts     = {}  -- [msgctxt][msgid] = msgstr

    local ctx, id, str
    local in_id, in_str, in_ctx = false, false, false

    local function unescape(s)
        return s:gsub("\\n", "\n")
                :gsub("\\t", "\t")
                :gsub('\\"', '"')
                :gsub("\\\\", "\\")
    end

    local function flush()
        if id and id ~= "" and str and str ~= "" then
            if ctx and ctx ~= "" then
                if not contexts[ctx] then contexts[ctx] = {} end
                contexts[ctx][id] = str
            else
                translations[id] = str
            end
        end
        ctx, id, str = nil, nil, nil
        in_id, in_str, in_ctx = false, false, false
    end

    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line == "" or line:match("^#") then
            if line == "" then flush() end
        elseif line:match("^msgctxt%s+\"") then
            flush()
            ctx   = unescape(line:match('^msgctxt%s+"(.*)"') or "")
            in_ctx = true; in_id = false; in_str = false
        elseif line:match("^msgid%s+\"") then
            -- don't flush here if we just saw msgctxt; they belong together
            if not in_ctx then flush() end
            in_ctx = false
            id    = unescape(line:match('^msgid%s+"(.*)"') or "")
            in_id = true; in_str = false
        elseif line:match("^msgstr%s+\"") then
            str    = unescape(line:match('^msgstr%s+"(.*)"') or "")
            in_str = true; in_id = false; in_ctx = false
        elseif line:match('^"') then
            local cont = unescape(line:match('^"(.*)"') or "")
            if in_ctx and ctx  then ctx = ctx .. cont end
            if in_id  and id   then id  = id  .. cont end
            if in_str and str  then str = str .. cont end
        end
    end
    flush()
    f:close()

    local count = 0
    for _msgid in pairs(translations) do count = count + 1 end
    for _msgctxt in pairs(contexts) do count = count + 1 end

    return translations, contexts, count
end

-- ---------------------------------------------------------------------------
-- Language detection — mirrors KOReader's own priority order
-- ---------------------------------------------------------------------------
local function detectLang()
    local lang = G_reader_settings and G_reader_settings:readSetting("language")
    if type(lang) == "string" and lang ~= "" then return lang end
    local lc = os.getenv("LANG") or os.getenv("LC_ALL") or os.getenv("LC_MESSAGES") or ""
    lang = lc:match("^([a-zA-Z_]+)")
    return lang or "en"
end

-- ---------------------------------------------------------------------------
-- Load .po translations for a given language string
-- ---------------------------------------------------------------------------
local function usesEnglishSource(lang)
    return lang == "C" or lang == "POSIX"
        or lang == "en" or lang:match("^en_") ~= nil
end

local function loadTranslationsForLang(lang)
    if not lang or usesEnglishSource(lang) then return nil, nil end

    local function try(name)
        local path = _dir .. "../locales/" .. name .. ".po"
        local t, c, n = parsePO(path)
        if t and n and n > 0 then
            logger.info("loaded " .. path .. " — " .. n .. " entries")
            return t, c
        end
        logger.warn("no translations in " .. path)
        return nil, nil
    end

    local t, c = try(lang)
    if t then return t, c end

    -- fallback: language prefix only (e.g. "pt" for "pt_BR")
    local prefix = lang:match("^([a-zA-Z]+)")
    if prefix and prefix ~= lang then
        logger.warn("falling back from " .. lang .. " to " .. prefix)
        return try(prefix)
    end
    logger.warn("no .po file found for lang=" .. lang)
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- Inject ZenOS translations into the live GetText tables.
-- Called at startup and again after every changeLang().
-- ---------------------------------------------------------------------------
local function applyZenTranslations(GetText, lang)
    local translations, contexts = loadTranslationsForLang(lang)
    _translations = translations or {}
    _contexts = contexts or {}
    if not translations then
        if not lang or not usesEnglishSource(lang) then
            logger.warn("skipping injection — no translations for lang=" .. (lang or "nil"))
        end
        return
    end
    for msgid, msgstr in pairs(translations) do
        GetText.translation[msgid] = msgstr
    end
    for msgctxt, msgs in pairs(contexts or {}) do
        if not GetText.context[msgctxt] then
            GetText.context[msgctxt] = {}
        end
        for msgid, msgstr in pairs(msgs) do
            GetText.context[msgctxt][msgid] = msgstr
        end
    end
end

local function findGetTextState(GetText)
    local current = GetText
    local seen = {}
    while type(current) == "table" and not seen[current] do
        seen[current] = true
        if type(rawget(current, "translation")) == "table"
                and type(rawget(current, "context")) == "table" then
            return current
        end
        local mt = getmetatable(current)
        current = mt and type(mt.__index) == "table" and mt.__index or nil
    end

    if type(GetText) == "table" and type(GetText.translation) == "table"
            and type(GetText.context) == "table" then
        return GetText
    end
end

-- ---------------------------------------------------------------------------
-- install / uninstall
-- ---------------------------------------------------------------------------
local _installed       = false
local _gettext_state   = nil
local _change_methods  = nil
local _orig_changeLang = nil
local _patched_changeLang
local _gettext_wrapper = nil
local _wrapped_gettext  = nil

local function installWrapper(GetText)
    local wrapper = setmetatable({
        pgettext = function(msgctxt, msgid)
            local translated = _contexts[msgctxt] and _contexts[msgctxt][msgid]
            if translated then return translated end
            if type(GetText.pgettext) == "function" then
                return GetText.pgettext(msgctxt, msgid)
            end
            return GetText(msgid)
        end,
    }, {
        __call = function(_self, msgid)
            return _translations[msgid] or GetText(msgid)
        end,
        __index = GetText,
        __newindex = GetText,
    })
    _wrapped_gettext = GetText
    _gettext_wrapper = wrapper
    package.loaded["gettext"] = wrapper
end

local function install()
    if _installed then
        if not _gettext_state then return false end
        applyZenTranslations(_gettext_state, detectLang())
        return true
    end

    local GetText = package.loaded["gettext"]
    if not GetText then
        local ok, gt = pcall(require, "gettext")
        if not ok or not gt then
            logger.warn("cannot load gettext — translations disabled")
            return
        end
        GetText = gt
    end
    local gettext_state = findGetTextState(GetText)
    if not gettext_state then
        logger.warn("cannot find backing gettext tables — translations disabled")
        return false
    end
    _gettext_state = gettext_state

    -- Inject translations for the current language
    applyZenTranslations(gettext_state, detectLang())

    -- Keep ZenOS's catalog outermost for modules loaded after this point.
    -- Other plugins that already captured their own wrapper retain it.
    installWrapper(GetText)

    -- Patch changeLang so we re-inject after every language switch.
    -- GetText_mt.__index is the method table; we replace changeLang in-place.
    local mt = getmetatable(gettext_state)
    if mt and type(mt.__index) == "table"
            and type(mt.__index.changeLang) == "function" then
        local methods = mt.__index
        local orig_changeLang = methods.changeLang
        _change_methods = methods
        _orig_changeLang = orig_changeLang
        _patched_changeLang = function(new_lang)
            local result = orig_changeLang(new_lang)
            if result == false then
                logger.warn("changeLang failed for lang=" .. (new_lang or "nil"))
            end
            applyZenTranslations(gettext_state, new_lang)
            return result
        end
        methods.changeLang = _patched_changeLang
    else
        logger.warn("cannot patch changeLang — unexpected gettext metatable shape")
    end

    _installed = true
    logger.info("installed for lang=" .. (detectLang() or "?"))
    return true
end

local function refresh()
    if not _installed then
        install()
        return _installed
    end
    if not _gettext_state then return false end
    applyZenTranslations(_gettext_state, detectLang())
    return true
end

local function uninstall()
    if not _installed then return end
    if package.loaded["gettext"] == _gettext_wrapper then
        package.loaded["gettext"] = _wrapped_gettext
    end
    if _gettext_state and _change_methods and _orig_changeLang then
        if _change_methods.changeLang == _patched_changeLang then
            _change_methods.changeLang = _orig_changeLang
            -- Reload clean KOReader translations without ZenOS overlay
            _orig_changeLang(_gettext_state.current_lang)
        else
            logger.warn("uninstall — changeLang ownership changed")
        end
    else
        logger.warn("uninstall — missing saved state, may be partially installed")
    end
    _patched_changeLang = nil
    _orig_changeLang = nil
    _change_methods  = nil
    _gettext_state   = nil
    _gettext_wrapper = nil
    _wrapped_gettext  = nil
    _translations    = {}
    _contexts        = {}
    _installed       = false
    logger.info("uninstalled")
end

return {
    install   = install,
    refresh   = refresh,
    uninstall = uninstall,
    getLang   = detectLang,
}
