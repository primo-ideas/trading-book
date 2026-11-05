local _, ns = ...

-- The ledger is the account-wide history of auction activity. Entry fields:
--   kind     "post" | "sold" | "bought" | "expired" | "cancel"
--   t, char  when it happened, and on which character
--   itemID, name, link, qty
--   gross    sold: sale price (total); bought: price paid (total)
--   cut      sold: auction house commission
--   deposit  post: deposit paid; sold: deposit refunded
--   unit     post: listed unit price
--   cost     cancel: cost of cancelling
--   other    sold: buyer; bought: seller
local Ledger = {}
ns.Ledger = Ledger

local MAX_ENTRIES = 20000

function Ledger.Add(entry)
    entry.t = entry.t or time()
    entry.char = entry.char or ns.playerKey
    table.insert(ns.db.ledger, entry)
    ns.Publish("LEDGER_CHANGED")
    return entry
end

function Ledger.Remove(entry)
    local ledger = ns.db.ledger
    for i = #ledger, 1, -1 do
        if ledger[i] == entry then
            table.remove(ledger, i)
            ns.Publish("LEDGER_CHANGED")
            return true
        end
    end
    return false
end

function Ledger.Prune()
    local ledger = ns.db.ledger
    local excess = #ledger - MAX_ENTRIES
    if excess <= 0 then
        return
    end
    local kept = {}
    for i = excess + 1, #ledger do
        kept[#kept + 1] = ledger[i]
    end
    ns.db.ledger = kept
end
