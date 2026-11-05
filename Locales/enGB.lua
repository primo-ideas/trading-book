if GetLocale() ~= "enGB" then return end

local _, ns = ...

-- Same words as the keys: only the order of day and month differs.
ns.Translation = {
    ["%m/%d"] = "%d/%m",
}
