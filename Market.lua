local _, ns = ...
local L = ns.L

-- Prices read from the auction house itself, for when Auctionator is missing or has
-- no data. One request replicates every auction of the realm, which the game allows
-- every 15 minutes. Each item keeps its lowest buyout per unit and the quantity on
-- sale, and the items the account deals in also keep one price a day, for the trend.
local Market = {}
ns.Market = Market

local SCAN_INTERVAL_SECONDS = 15 * 60
local ANSWER_TIMEOUT_SECONDS = 60
-- After the owned auctions are requested, once the auction house UI has settled.
local AUTO_SCAN_DELAY_SECONDS = 2
local ENTRIES_PER_FRAME = 2000
local KEEP_DAYS = 30
local CHANGE_MIN_DAYS = 7
local AUCTIONATOR_SAMPLE = 50
local SECONDS_PER_DAY = 86400
local SOLD = 1
-- Every caged pet shares this item, so its lowest price says nothing about any of them.
local PET_CAGE_ITEM_ID = 82800

-- Positions in a saved price: a realm holds tens of thousands of them.
local PRICE, QUANTITY, SEEN = 1, 2, 3

local auctionHouseOpen = false
local state = nil -- nil, "waiting" for the server or "reading" its answer
local scan = nil
local realmKey = nil

-- Connected realms share one auction house, so they share their prices. The list
-- may leave the player's own realm out, which is added so that every realm of the
-- group finds the same key.
local function RealmKey()
    local realms = { GetNormalizedRealmName() or GetRealmName() }
    for _, realm in ipairs(GetAutoCompleteRealms()) do
        table.insert(realms, realm)
    end
    table.sort(realms)
    return realms[1]
end

local function RealmData(create)
    realmKey = realmKey or RealmKey()
    local realms = ns.db.market.realms
    if not realms[realmKey] and create then
        realms[realmKey] = { items = {}, history = {} }
    end
    return realms[realmKey]
end

-- Prices ----------------------------------------------------------------------------

-- { price, quantity, seenAt, scannedAt } for an item of this realm's auction house,
-- or nil when no scan ever saw it. quantity is what is on sale since the latest scan.
function Market.GetItem(itemID)
    local data = RealmData()
    local saved = data and data.items[itemID]
    if not saved then
        return nil
    end
    local current = saved[SEEN] >= data.scannedAt
    return {
        price = saved[PRICE],
        quantity = current and saved[QUANTITY] or 0,
        seenAt = saved[SEEN],
        scannedAt = data.scannedAt,
    }
end

-- The change of the current price against the latest daily price at least a week
-- old, and that day's time. Nil without such a price, or when the item is no longer
-- on sale.
function Market.GetChange(itemID)
    local data = RealmData()
    local saved = data and data.items[itemID]
    local history = data and data.history[itemID]
    if not (saved and history) or saved[SEEN] < data.scannedAt then
        return nil
    end
    local limit = ns.DayKey(time() - CHANGE_MIN_DAYS * SECONDS_PER_DAY)
    local referenceDay = nil
    for day in pairs(history) do
        if day <= limit and (not referenceDay or day > referenceDay) then
            referenceDay = day
        end
    end
    if not referenceDay then
        return nil
    end
    local reference = history[referenceDay]
    return (saved[PRICE] - reference) / reference, ns.DayKeyToTime(referenceDay)
end

-- Auctionator scans by itself. It only counts as having data when it prices some of
-- the items the account has dealt in.
function Market.AuctionatorHasData()
    local checked = 0
    for itemID in pairs(ns.db.items) do
        if ns.Stats.GetAuctionatorPrice(itemID) then
            return true
        end
        checked = checked + 1
        if checked >= AUCTIONATOR_SAMPLE then
            break
        end
    end
    return false
end

-- Scanning --------------------------------------------------------------------------

local function Prune(data, now)
    local oldest = now - KEEP_DAYS * SECONDS_PER_DAY
    for itemID, saved in pairs(data.items) do
        if saved[SEEN] < oldest then
            data.items[itemID] = nil
        end
    end
    local oldestDay = ns.DayKey(oldest)
    for itemID, history in pairs(data.history) do
        for day in pairs(history) do
            if day < oldestDay then
                history[day] = nil
            end
        end
        if next(history) == nil then
            data.history[itemID] = nil
        end
    end
end

local function Finish()
    local now = time()
    local data = RealmData(true)
    local today = ns.DayKey(now)
    local count = 0
    for itemID, item in pairs(scan.items) do
        item[PRICE] = math.floor(item[PRICE] + 0.5)
        item[SEEN] = now
        data.items[itemID] = item
        if ns.db.items[itemID] then
            data.history[itemID] = data.history[itemID] or {}
            data.history[itemID][today] = item[PRICE]
        end
        count = count + 1
    end
    data.scannedAt = now
    Prune(data, now)
    state, scan = nil, nil
    ns.Print(L["Auction house scanned: %s items priced."]:format(BreakUpLargeNumbers(count)))
    ns.Publish("MARKET_CHANGED")
end

-- A few thousand auctions a frame, so that the game does not freeze.
local function ReadSome()
    if state ~= "reading" then
        return
    end
    local last = math.min(scan.index + ENTRIES_PER_FRAME, scan.total) - 1
    for index = scan.index, last do
        local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, saleStatus, itemID =
            C_AuctionHouse.GetReplicateItemInfo(index)
        -- Auctions without a buyout only take bids, and give no price.
        if itemID and itemID ~= PET_CAGE_ITEM_ID and count and count > 0 and buyout and buyout > 0
            and saleStatus ~= SOLD then
            local unit = buyout / count
            local item = scan.items[itemID]
            if item then
                item[PRICE] = math.min(item[PRICE], unit)
                item[QUANTITY] = item[QUANTITY] + count
            else
                scan.items[itemID] = { unit, count }
            end
        end
    end
    scan.index = last + 1
    if scan.index >= scan.total then
        Finish()
    else
        C_Timer.After(0, ReadSome)
    end
end

function Market.NextScanAt()
    return (ns.db.market.requestedAt or 0) + SCAN_INTERVAL_SECONDS
end

-- byHand: asked for by the player, who is then told what happens. Returns whether
-- a scan was requested.
function Market.Scan(byHand)
    if state == "waiting" and time() - scan.requestedAt > ANSWER_TIMEOUT_SECONDS then
        state, scan = nil, nil -- The server never answered.
    end
    local message = nil
    if state then
        message = L["Scanning the auction house..."]
    elseif not auctionHouseOpen then
        message = L["Open the auction house to scan it."]
    elseif Market.NextScanAt() > time() then
        message = L["The auction house can be scanned again in %s."]:format(
            ns.FormatDuration(Market.NextScanAt() - time()))
    end
    if message then
        if byHand then
            ns.Print(message)
        end
        return false
    end

    ns.db.market.requestedAt = time()
    state = "waiting"
    scan = { requestedAt = time(), byHand = byHand }
    C_AuctionHouse.ReplicateItems()
    if byHand then
        ns.Print(L["Scanning the auction house..."])
    end
    return true
end

function Market.IsAutoScanEnabled()
    return not ns.db.ui.noAutoScan
end

function Market.SetAutoScanEnabled(enabled)
    ns.db.ui.noAutoScan = not enabled or nil
end

ns.OnEvent("REPLICATE_ITEM_LIST_UPDATE", function()
    if state ~= "waiting" then
        return
    end
    state = "reading"
    scan.index, scan.total, scan.items = 0, C_AuctionHouse.GetNumReplicateItems(), {}
    ReadSome()
end)

ns.OnEvent("AUCTION_HOUSE_SHOW", function()
    auctionHouseOpen = true
    if Market.IsAutoScanEnabled() and not Market.AuctionatorHasData() then
        C_Timer.After(AUTO_SCAN_DELAY_SECONDS, function()
            if auctionHouseOpen then
                Market.Scan(false)
            end
        end)
    end
end)

-- The answer may not outlive the auction house window, so a scan in progress is
-- dropped and the previous prices stay.
ns.OnEvent("AUCTION_HOUSE_CLOSED", function()
    auctionHouseOpen = false
    if state and (state == "reading" or scan.byHand) then
        ns.Print(L["The auction house scan stopped as the auction house closed."])
    end
    state, scan = nil, nil
end)
