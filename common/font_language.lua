-- Intersection of the advertised coverage for all bundled Hyperreadable faces.
local M = {}

local SUPPORTED_LANGUAGES = {
    aa = true, agr = true, an = true, ay = true, ayc = true, bem = true,
    bi = true, br = true, bs = true, ch = true, co = true, crh = true,
    cs = true, csb = true, cy = true, da = true, de = true, dsb = true,
    en = true, es = true, et = true, eu = true, fi = true, fil = true,
    fj = true, fo = true, fr = true, fur = true, fy = true, gd = true,
    gl = true, gv = true, ho = true, hr = true, hsb = true,
    ht = true, hu = true, ia = true, id = true, ie = true, io = true,
    is = true, it = true, jv = true, kj = true, kwm = true, lb = true,
    li = true, lij = true, lt = true, mfe = true, mg = true, mjw = true,
    ms = true, mt = true, nb = true, nds = true, ng = true, nl = true,
    nn = true, no = true, nr = true, nso = true, ny = true, oc = true,
    om = true, pl = true, pt = true, rm = true, rn = true, ro = true,
    rw = true, sc = true, sg = true, sk = true, sl = true, sma = true,
    smj = true, sn = true, so = true, sq = true, ss = true, st = true,
    su = true, sv = true, sw = true, tk = true, tl = true, tn = true,
    tpi = true, tr = true, ts = true, unm = true, uz = true, vo = true,
    vot = true, wa = true, wae = true, wen = true, xh = true, yap = true,
    yuw = true, za = true, zu = true,
    ku_tr = true, pap_an = true, pap_aw = true,
}

local WHOLE_WORD_SEARCH_LANGUAGES = {
    ca = true, cs = true, da = true, de = true, en = true, eo = true,
    es = true, eu = true, fi = true, fr = true, ga = true, gl = true,
    hr = true, hu = true, it = true, lt = true, lv = true, nb = true,
    nl = true, pl = true, pt = true, ro = true, sk = true, sl = true,
    sv = true,
}

local function configured_language(settings)
    settings = settings or rawget(_G, "G_reader_settings")
    if settings and type(settings.readSetting) == "function" then
        local language = settings:readSetting("language")
        if type(language) == "string" and language ~= "" then return language end
    end
    return rawget(_G, "DLANGUAGE")
        or os.getenv("LANG") or os.getenv("LC_ALL") or os.getenv("LC_MESSAGES")
end

local function normalized_language(settings)
    local language = configured_language(settings)
    if type(language) ~= "string" or language == "" then return nil end
    return language:lower():gsub("%..*$", ""):gsub("@.*$", ""):gsub("-", "_")
end

function M.supportsBundledFonts(settings)
    local language = normalized_language(settings)
    if not language then return true end
    if language == "c" or language == "posix" then return true end

    if SUPPORTED_LANGUAGES[language] then return true end
    local code = language:match("^([a-z]+)")
    return code ~= nil and SUPPORTED_LANGUAGES[code] == true
end

function M.supportsWholeWordSearch(settings)
    local language = normalized_language(settings)
    if not language or language == "c" or language == "posix" then return true end

    local code = language:match("^([a-z]+)")
    return WHOLE_WORD_SEARCH_LANGUAGES[code] == true
end

return M
