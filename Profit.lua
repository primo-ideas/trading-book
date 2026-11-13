local _, ns = ...
local L = ns.L

-- What each item really earns and how well it sells, deduced from the ledger, the
-- purchases and the tracked recipes:
-- - its profit: sales after the cut, less the deposits and cancellations lost on it,
--   less what the units sold cost, bought on the auction house or crafted;
-- - how much of what was listed sold, and how long a sale took after its listing;
-- - and from all that, a word of advice.
local Profit = {}
ns.Profit = Profit

local SECONDS_PER_DAY = 86400
-- The longest an auction lasts, and a little for the sale's mail.
local LISTING_MAX_SECONDS = 49 * 3600
-- An item's advice about how it sells waits for this many units to have ended.
local ADVICE_MIN_ENDED = 4
local SLOW_SELL_THROUGH = 0.3
local GOOD_SELL_THROUGH = 0.7
-- Lost fees this large a share of what an item brought deserve a word.
local FEES_SHARE = 0.25
local TOOLTIP_DAYS = 90

Profit.ADVICE = {
    unsold = { label = L["Unsold"], text = L["Did not sell in this period: its deposits are lost."], bad = true },
    loss = { label = L["Loss"], text = L["Sells for less than it costs, fees included."], bad = true },
    slow = { label = L["Slow"], text = L["Rarely sells: lower its price, or stop listing it."], bad = true },
    fees = { label = L["Fees"], text = L["Lost deposits and cancellations eat a large share of what it brings."], bad = true },
    good = { label = L["Good"], text = L["Sells well and earns money: worth restocking."] },
}

-- The key an entry's item is counted under, the same as the Stats summary's.
local function ItemKey(entry)
    return entry.itemID or entry.name
end

-- What a unit of each item cost on the auction house, on average over every priced
-- purchase: stock bought before the period still cost what it cost.
local function PurchaseCosts()
    local totals = {}
    for _, entry in ipairs(ns.db.ledger) do
        if entry.kind == "bought" and entry.itemID and not ns.Ledger.IsPriceUnknown(entry) then
            local total = totals[entry.itemID] or { spent = 0, qty = 0 }
            totals[entry.itemID] = total
            total.spent = total.spent + entry.gross
            total.qty = total.qty + (entry.qty or 1)
        end
    end
    local costs = {}
    for itemID, total in pairs(totals) do
        if total.qty > 0 then
            costs[itemID] = total.spent / total.qty
        end
    end
    return costs
end

-- The listings of each item on each character, in time order.
local function ListingTimes()
    local listings = {}
    for _, entry in ipairs(ns.db.ledger) do
        if entry.kind == "post" and entry.itemID then
            local key = entry.itemID .. "|" .. (entry.char or "")
            listings[key] = listings[key] or {}
            table.insert(listings[key], entry.t)
        end
    end
    for _, times in pairs(listings) do
        table.sort(times)
    end
    return listings
end

-- How long a sale took after its listing: the latest listing of that item on that
-- character before the sale, which an auction cannot outlast. nil when none fits.
local function TimeToSell(listings, sale)
    local times = sale.itemID and listings[sale.itemID .. "|" .. (sale.char or "")]
    if not times then
        return nil
    end
    for index = #times, 1, -1 do
        local delay = sale.t - times[index]
        if delay >= 0 then
            return delay <= LISTING_MAX_SECONDS and delay or nil
        end
    end
end

local function Advise(item)
    local ended = item.soldQty + item.expiredQty + item.cancelledQty
    if item.soldQty == 0 then
        return item.feesLost > 0 and "unsold" or nil
    elseif item.profit < 0 then
        return "loss"
    elseif ended >= ADVICE_MIN_ENDED and item.sellThrough < SLOW_SELL_THROUGH then
        return "slow"
    elseif item.feesLost > item.proceeds * FEES_SHARE then
        return "fees"
    elseif ended >= ADVICE_MIN_ENDED and item.sellThrough >= GOOD_SELL_THROUGH then
        return "good"
    end
end

local function NewItem(entry)
    return {
        itemID = entry.itemID, name = entry.name, soldQty = 0, proceeds = 0, expiredQty = 0, cancelledQty = 0,
        depositsPaid = 0, depositsRefunded = 0, cancelCosts = 0, sellTime = 0, timedSales = 0,
    }
end

-- options: since (timestamp), char (character key). Per item key: { itemID, name,
-- soldQty, proceeds, feesLost, unitCost, costSource ("bought" or "crafted", nil when
-- neither, the units then counting as free), profit, unitProfit, sellThrough,
-- timeToSell (seconds, nil when unknown), advice (a key of Profit.ADVICE, or nil) }.
function Profit.Analyze(options)
    options = options or {}
    local listings = ListingTimes()
    local items = {}
    for _, entry in ipairs(ns.db.ledger) do
        local key = ItemKey(entry)
        if key and (not options.since or entry.t >= options.since)
            and (not options.char or entry.char == options.char) and entry.kind ~= "bought" then
            local item = items[key] or NewItem(entry)
            items[key] = item
            local quantity = entry.qty or 1
            if entry.kind == "sold" then
                item.soldQty = item.soldQty + quantity
                item.proceeds = item.proceeds + (entry.gross or 0) - (entry.cut or 0)
                item.depositsRefunded = item.depositsRefunded + (entry.deposit or 0)
                local delay = TimeToSell(listings, entry)
                if delay then
                    item.sellTime = item.sellTime + delay
                    item.timedSales = item.timedSales + 1
                end
            elseif entry.kind == "post" then
                item.depositsPaid = item.depositsPaid + (entry.deposit or 0)
            elseif entry.kind == "expired" then
                item.expiredQty = item.expiredQty + quantity
            elseif entry.kind == "cancel" then
                item.cancelledQty = item.cancelledQty + quantity
                item.cancelCosts = item.cancelCosts + (entry.cost or 0)
            end
        end
    end

    local purchases = PurchaseCosts()
    local recipes = ns.Shopping.GetRecipes()
    for _, item in pairs(items) do
        item.feesLost = math.max(0, item.depositsPaid - item.depositsRefunded) + item.cancelCosts
        if item.itemID and purchases[item.itemID] then
            item.unitCost, item.costSource = purchases[item.itemID], "bought"
        elseif item.itemID then
            local craft = ns.Shopping.GetCraftCost(item.itemID, recipes)
            if craft then
                item.unitCost, item.costSource = craft, "crafted"
            end
        end
        item.profit = item.proceeds - item.feesLost - (item.unitCost or 0) * item.soldQty
        item.unitProfit = item.soldQty > 0 and item.profit / item.soldQty or nil
        local ended = item.soldQty + item.expiredQty + item.cancelledQty
        item.sellThrough = ended > 0 and item.soldQty / ended or nil
        item.timeToSell = item.timedSales > 0 and item.sellTime / item.timedSales or nil
        item.advice = Advise(item)
    end
    return items
end

-- The sum of the items' profits.
function Profit.Total(items)
    local total = 0
    for _, item in pairs(items) do
        total = total + item.profit
    end
    return total
end

-- An item over the last 90 days on the whole account, for its tooltip, or nil when it
-- was neither listed nor sold.
local recent = nil

-- Craft costs follow the prices and the tracked recipes.
for _, message in ipairs({ "LEDGER_CHANGED", "MARKET_CHANGED", "AUCTIONATOR_PRICES_CHANGED", "SHOPPING_CHANGED" }) do
    ns.Subscribe(message, function()
        recent = nil
    end)
end
ns.OnEvent("TRACKED_RECIPE_UPDATE", function()
    recent = nil
end)

function Profit.GetRecent(itemID)
    recent = recent or Profit.Analyze({ since = time() - TOOLTIP_DAYS * SECONDS_PER_DAY })
    return recent[itemID]
end
