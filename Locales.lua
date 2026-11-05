local _, ns = ...

-- English strings are the keys, so enUS needs no file and a missing translation falls
-- back to English. Each file in Locales\ loads only for its own language.
local active = ns.Translation or {}

ns.L = setmetatable({}, {
    __index = function(_, key)
        return active[key] or key
    end,
})
