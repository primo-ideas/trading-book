local _, ns = ...

local Stats = {}
ns.Stats = Stats

local SALE_PRICE_WINDOW_DAYS = 90
local SECONDS_PER_DAY = 86400

-- Cash effect of a ledger entry. Sale deposits come back with the payment, so
-- deposits are paid on "post" and refunded on "sold".
function Stats.Net(entry)
    if entry.kind == "sold" then
        return (entry.gross or 0) + (entry.deposit or 0) - (entry.cut or 0)
    elseif entry.kind == "bought" then
        return -(entry.gross or 0)
    elseif entry.kind == "post" then
        return -(entry.deposit or 0)
    elseif entry.kind == "cancel" then
        return -(entry.cost or 0)
    end
    return 0
end

local function Matches(entry, options)
    return (not options.since or entry.t >= options.since)
        and (not options.char or entry.char == options.char)
end

local function ItemBucket(items, entry)
    local key = entry.itemID or entry.name
    if not key then
        return nil
    end
    local bucket = items[key]
    if not bucket then
        bucket = {
            itemID = entry.itemID, name = entry.name, soldQty = 0, gross = 0,
            boughtQty = 0, pricedBoughtQty = 0, spent = 0, net = 0,
        }
        items[key] = bucket
    end
    return bucket
end

-- options: since (timestamp), char (character key). unpricedPurchases counts the
-- purchases left out of the totals, as what they cost is not known.
function Stats.Summarize(options)
    options = options or {}
    local summary = {
        gross = 0, cut = 0, depositsPaid = 0, depositsRefunded = 0, cancelCosts = 0,
        spent = 0, net = 0, soldQty = 0, expiredQty = 0, cancelledQty = 0, unpricedPurchases = 0, items = {},
    }
    for _, entry in ipairs(ns.db.ledger) do
        if Matches(entry, options) then
            local net = Stats.Net(entry)
            local quantity = entry.qty or 1
            local bucket = ItemBucket(summary.items, entry)
            summary.net = summary.net + net
            if bucket then
                bucket.net = bucket.net + net
            end
            if entry.kind == "sold" then
                summary.gross = summary.gross + (entry.gross or 0)
                summary.cut = summary.cut + (entry.cut or 0)
                summary.depositsRefunded = summary.depositsRefunded + (entry.deposit or 0)
                summary.soldQty = summary.soldQty + quantity
                if bucket then
                    bucket.soldQty = bucket.soldQty + quantity
                    bucket.gross = bucket.gross + (entry.gross or 0)
                end
            elseif entry.kind == "bought" then
                local unpriced = ns.Ledger.IsPriceUnknown(entry)
                summary.spent = summary.spent + (entry.gross or 0)
                if unpriced then
                    summary.unpricedPurchases = summary.unpricedPurchases + 1
                end
                if bucket then
                    bucket.boughtQty = bucket.boughtQty + quantity
                    bucket.spent = bucket.spent + (entry.gross or 0)
                    -- The average purchase price only spreads what is known.
                    if not unpriced then
                        bucket.pricedBoughtQty = bucket.pricedBoughtQty + quantity
                    end
                end
            elseif entry.kind == "post" then
                summary.depositsPaid = summary.depositsPaid + (entry.deposit or 0)
            elseif entry.kind == "cancel" then
                summary.cancelCosts = summary.cancelCosts + (entry.cost or 0)
                summary.cancelledQty = summary.cancelledQty + quantity
            elseif entry.kind == "expired" then
                summary.expiredQty = summary.expiredQty + quantity
            end
        end
    end

    summary.fees = summary.cut + summary.depositsPaid - summary.depositsRefunded + summary.cancelCosts
    local ended = summary.soldQty + summary.expiredQty + summary.cancelledQty
    summary.sellThrough = ended > 0 and (summary.soldQty / ended) or nil
    return summary
end

-- Time ----------------------------------------------------------------------

local function StartOfDay(t)
    local d = date("*t", t)
    return time({ year = d.year, month = d.month, day = d.day, hour = 0, min = 0, sec = 0 })
end
Stats.StartOfDay = StartOfDay

-- Measured between midnights, offset to noon so that a 23 or 25 hour day from a
-- clock change still rounds to the right number of days.
local function DaysSince(startMidnight, t)
    return math.floor((StartOfDay(t) + SECONDS_PER_DAY / 2 - startMidnight) / SECONDS_PER_DAY)
end
Stats.DaysSince = DaysSince

-- Midnight at the start of a period that includes today, or nil for "all time".
function Stats.PeriodStart(days)
    if not days or days <= 0 then
        return nil
    end
    local d = date("*t", time())
    return time({ year = d.year, month = d.month, day = d.day - (days - 1), hour = 0, min = 0, sec = 0 })
end

-- Series --------------------------------------------------------------------

-- Splits the period into at most maxBars equal buckets, including empty ones so
-- that the time axis stays continuous. Returns the bars and the bucket length in days.
function Stats.BuildSeries(options, maxBars)
    local matching = {}
    local earliest
    for _, entry in ipairs(ns.db.ledger) do
        if Matches(entry, options) then
            matching[#matching + 1] = entry
            earliest = math.min(earliest or entry.t, entry.t)
        end
    end
    if not options.since and not earliest then
        return {}, 1
    end

    local start = StartOfDay(options.since or earliest)
    local dayCount = DaysSince(start, time()) + 1
    local bucketDays = math.max(1, math.ceil(dayCount / maxBars))
    local bars = {}
    for i = 1, math.ceil(dayCount / bucketDays) do
        local firstDay = (i - 1) * bucketDays
        bars[i] = {
            from = start + firstDay * SECONDS_PER_DAY + SECONDS_PER_DAY / 2,
            to = start + math.min(firstDay + bucketDays, dayCount) * SECONDS_PER_DAY - SECONDS_PER_DAY / 2,
            net = 0, gross = 0, spent = 0,
        }
    end
    for _, entry in ipairs(matching) do
        local bar = bars[math.floor(DaysSince(start, entry.t) / bucketDays) + 1]
        if bar then
            bar.net = bar.net + Stats.Net(entry)
            if entry.kind == "sold" then
                bar.gross = bar.gross + (entry.gross or 0)
            elseif entry.kind == "bought" then
                bar.spent = bar.spent + (entry.gross or 0)
            end
        end
    end
    return bars, bucketDays
end

-- Pricing -------------------------------------------------------------------

local saleStats = nil

ns.Subscribe("LEDGER_CHANGED", function()
    saleStats = nil
end)

-- Per item: the average unit price over the recent window, and the latest sale ever.
-- Sales are dated from their mail, so the ledger is not in date order.
local function BuildSaleStats()
    local cutoff = time() - SALE_PRICE_WINDOW_DAYS * SECONDS_PER_DAY
    local totals = {}
    for _, entry in ipairs(ns.db.ledger) do
        if entry.kind == "sold" and entry.itemID then
            local total = totals[entry.itemID] or { gross = 0, qty = 0 }
            totals[entry.itemID] = total
            if entry.t >= cutoff then
                total.gross = total.gross + (entry.gross or 0)
                total.qty = total.qty + (entry.qty or 1)
            end
            if not total.last or entry.t >= total.last.t then
                total.last = entry
            end
        end
    end
    local stats = {}
    for id, total in pairs(totals) do
        stats[id] = {
            average = total.qty > 0 and total.gross / total.qty or nil,
            last = total.last,
        }
    end
    return stats
end

-- { average, last } for an item, or nil when it was never sold. average is nil
-- when no sale falls within the window, and last is a ledger entry.
function Stats.GetSaleStats(itemID)
    saleStats = saleStats or BuildSaleStats()
    return saleStats[itemID]
end

local function AverageSalePrice(itemID)
    local stats = Stats.GetSaleStats(itemID)
    return stats and stats.average
end

-- Auctionator's price for an item, if it is installed and knows one.
function Stats.GetAuctionatorPrice(itemID)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if api and api.GetAuctionPriceByItemID then
        local ok, price = pcall(api.GetAuctionPriceByItemID, "TradingBook", itemID)
        if ok and price then
            return price
        end
    end
end

-- Current unit value of an item, where it comes from ("auctionator", "scan" or
-- "sales"), and for a scan when the item was last seen on sale.
function Stats.GetUnitPrice(itemID)
    local price = Stats.GetAuctionatorPrice(itemID)
    if price then
        return price, "auctionator"
    end
    local market = ns.Market.GetItem(itemID)
    if market then
        return market.price, "scan", market.seenAt
    end
    local average = AverageSalePrice(itemID)
    if average then
        return average, "sales"
    end
end
