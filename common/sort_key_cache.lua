-- Keep each cache local to one sort so language and metadata changes take effect.
return function(key_func)
    local keys = {}
    return function(value)
        value = tostring(value or "")
        local key = keys[value]
        if key == nil then
            key = key_func(value)
            keys[value] = key
        end
        return key
    end
end
