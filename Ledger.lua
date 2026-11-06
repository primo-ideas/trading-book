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

-- The price of one unit: listed for a listing, paid or received for a purchase or a
-- sale, before any fee. Nil when unknown.
function Ledger.UnitPrice(entry)
    if entry.kind == "sold" or entry.kind == "bought" then
        return (entry.gross or 0) / (entry.qty or 1)
    end
    return entry.unit
end

-- CSV ------------------------------------------------------------------------------

-- Amounts are in copper, so that no spreadsheet misreads a decimal separator.
local CSV_COLUMNS = { "date", "type", "item", "item_id", "quantity", "unit_price", "amount", "character", "other" }

local function CsvField(value)
    if value == nil then
        return ""
    end
    value = tostring(value)
    if value:find('[,"\r\n]') then
        return '"' .. (value:gsub('"', '""')) .. '"'
    end
    return value
end

-- The whole history, oldest first, with a header line.
function Ledger.ToCSV()
    local entries = {}
    for _, entry in ipairs(ns.db.ledger) do
        entries[#entries + 1] = entry
    end
    table.sort(entries, function(a, b)
        return a.t < b.t
    end)
    local lines = { table.concat(CSV_COLUMNS, ",") }
    for _, entry in ipairs(entries) do
        local unit = Ledger.UnitPrice(entry)
        local values = {
            date("%Y-%m-%d %H:%M", entry.t),
            entry.kind,
            entry.name,
            entry.itemID,
            entry.qty or 1,
            unit and math.floor(unit + 0.5),
            math.floor(ns.Stats.Net(entry) + 0.5),
            entry.char,
            entry.other,
        }
        local fields = {}
        for index = 1, #CSV_COLUMNS do
            fields[index] = CsvField(values[index])
        end
        lines[#lines + 1] = table.concat(fields, ",")
    end
    return table.concat(lines, "\n")
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
