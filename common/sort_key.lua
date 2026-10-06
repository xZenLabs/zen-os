local UTF8_CHAR = "[%z\1-\127\194-\244][\128-\191]*"
local LATIN = {
    a = "àáâãäåāăąǎǟǡǻȁȃȧḁạảấầẩẫậắằẳẵặ",
    b = "ḃḅḇ",
    c = "çćĉċčḉ",
    d = "ďđḋḍḏḑḓ",
    e = "èéêëēĕėęěȅȇȩḕḗḙḛḝẹẻẽếềểễệ",
    f = "ḟ",
    g = "ĝğġģǧǵḡ",
    h = "ĥȟḣḥḧḩḫẖ",
    i = "ìíîïĩīĭįǐȉȋḭḯỉị",
    j = "ĵǰ",
    k = "ķǩḱḳḵ",
    l = "ĺļľłḷḹḻḽ",
    m = "ḿṁṃ",
    n = "ñńņňǹṅṇṉṋ",
    o = "òóôõöøōŏőơǒǫǭȍȏȫȭȯȱṍṏṑṓọỏốồổỗộớờởỡợ",
    p = "ṕṗ",
    r = "ŕŗřȑȓṙṛṝṟ",
    s = "śŝşšșṡṣṥṧṩ",
    t = "ţťțṫṭṯṱẗ",
    u = "ùúûüũūŭůűųưǔǖǘǚǜȕȗṳṵṷṹṻụủứừửữự",
    v = "ṽṿ",
    w = "ŵẁẃẅẇẉẘ",
    x = "ẋẍ",
    y = "ýÿŷȳẏẙỳỵỷỹ",
    z = "źżžẑẓẕ",
}
local folds = {}
for letter, chars in pairs(LATIN) do
    for char in chars:gmatch(UTF8_CHAR) do folds[char] = letter end
end

return function(value)
    local text = tostring(value or "")
    if not text:find("[\128-\255]") then return text:lower() end
    local Utf8Proc = require("ffi/utf8proc")
    if not select(2, Utf8Proc.count(text)) then return text:lower() end
    local latin = false
    return (Utf8Proc.lowercase(text):gsub(UTF8_CHAR, function(char)
        if latin and char >= "\u{0300}" and char <= "\u{036F}" then return "" end
        local folded = folds[char] or char
        latin = folded:match("^[a-z]$") ~= nil
        return folded
    end))
end
