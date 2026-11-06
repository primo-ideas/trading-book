local _, ns = ...
local L = ns.L

-- Tracks listings and cancellations as they happen, and keeps a per-character
-- copy of owned auctions so they can be shown away from the auction house.
local Auctions = {}
ns.Auctions = Auctions

local PENDING_TTL_SECONDS = 60
local DURATION_HOURS = { 12, 24, 48 }
local OWNED_SORTS = { { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false } }

local pendingPosts = {}
local pendingCancels = {}
local auctionHouseOpen = false

local function DropStale(pending)
    local cutoff = time() - PENDING_TTL_SECONDS
    for i = #pending, 1, -1 do
        if pending[i].at < cutoff then
            table.remove(pending, i)
        end
    end
end

local function DescribeLocation(location)
    if not (location and C_Item.DoesItemExist(location)) then
        return nil
    end
    local itemID = C_Item.GetItemID(location)
    local name = C_Item.GetItemName(location)
    ns.RememberItem(itemID, name, C_Item.GetItemQuality(location), C_Item.GetItemIconByID(itemID))
    return itemID, name, C_Item.GetItemLink(location)
end

-- Listings ------------------------------------------------------------------

-- A post call does not mean the auction exists: the server can refuse it, and
-- the player can back out of a price warning. It is only recorded once created.
hooksecurefunc(C_AuctionHouse, "PostItem", function(location, duration, quantity, bid, buyout)
    local itemID, name, link = DescribeLocation(location)
    table.insert(pendingPosts, {
        itemID = itemID,
        name = name,
        link = link,
        qty = quantity,
        unit = buyout or bid,
        deposit = itemID and C_AuctionHouse.CalculateItemDeposit(location, duration, quantity),
        duration = duration,
        at = time(),
    })
end)

hooksecurefunc(C_AuctionHouse, "PostCommodity", function(location, duration, quantity, unitPrice)
    local itemID, name, link = DescribeLocation(location)
    table.insert(pendingPosts, {
        itemID = itemID,
        name = name,
        link = link,
        qty = quantity,
        unit = unitPrice,
        deposit = itemID and C_AuctionHouse.CalculateCommodityDeposit(itemID, duration, quantity),
        duration = duration,
        at = time(),
    })
end)

hooksecurefunc(C_AuctionHouse, "CancelSell", function()
    wipe(pendingPosts)
end)

-- Posting several non-stackable items creates one auction each, but the single
-- post call already covers the whole quantity: later creations find nothing pending.
ns.OnEvent("AUCTION_HOUSE_AUCTION_CREATED", function(auctionID)
    DropStale(pendingPosts)
    local post = table.remove(pendingPosts, 1)
    if not post then
        return
    end
    ns.Ledger.Add({
        kind = "post",
        itemID = post.itemID,
        name = post.name,
        link = post.link,
        qty = post.qty,
        unit = post.unit,
        deposit = post.deposit or 0,
    })
    table.insert(ns.GetCharacter().auctions, {
        auctionID = auctionID,
        itemID = post.itemID,
        name = post.name,
        link = post.link,
        qty = post.qty,
        unit = post.unit,
        expiresAt = time() + (DURATION_HOURS[post.duration] or 48) * 3600,
    })
    ns.Publish("AUCTIONS_CHANGED")
end)

ns.OnEvent("AUCTION_HOUSE_SHOW_ERROR", function()
    wipe(pendingPosts)
    wipe(pendingCancels)
end)

-- Cancellations -------------------------------------------------------------

local function FindOwned(auctionID)
    local auctions = ns.GetCharacter().auctions
    for index, auction in ipairs(auctions) do
        if auction.auctionID == auctionID then
            return auction, index
        end
    end
end

hooksecurefunc(C_AuctionHouse, "CancelAuction", function(auctionID)
    table.insert(pendingCancels, {
        auctionID = auctionID,
        cost = C_AuctionHouse.GetCancelCost(auctionID),
        at = time(),
    })
end)

ns.OnEvent("AUCTION_CANCELED", function(auctionID)
    DropStale(pendingCancels)
    for index, pending in ipairs(pendingCancels) do
        if pending.auctionID == auctionID then
            table.remove(pendingCancels, index)
            local auction, ownedIndex = FindOwned(auctionID)
            ns.Ledger.Add({
                kind = "cancel",
                itemID = auction and auction.itemID,
                name = auction and auction.name,
                link = auction and auction.link,
                qty = auction and auction.qty or 1,
                cost = pending.cost or 0,
            })
            if ownedIndex then
                table.remove(ns.GetCharacter().auctions, ownedIndex)
            end
            ns.Publish("AUCTIONS_CHANGED")
            return
        end
    end
end)

-- Owned auctions ------------------------------------------------------------

ns.OnEvent("OWNED_AUCTIONS_UPDATED", function()
    local now = time()
    local list = {}
    for _, info in ipairs(C_AuctionHouse.GetOwnedAuctions()) do
        local itemID = info.itemKey and info.itemKey.itemID
        local link = info.itemLink
        local name = link and link:match("%[(.-)%]") or ns.GetItemDetails(itemID)
        ns.RememberItem(itemID, name, nil, itemID and C_Item.GetItemIconByID(itemID))
        table.insert(list, {
            auctionID = info.auctionID,
            itemID = itemID,
            name = name,
            link = link,
            qty = info.quantity,
            unit = info.buyoutAmount or info.bidAmount,
            sold = info.status == Enum.AuctionStatus.Sold or nil,
            expiresAt = info.timeLeftSeconds and (now + info.timeLeftSeconds) or nil,
        })
    end
    local character = ns.GetCharacter()
    character.auctions = list
    character.auctionsSyncedAt = now
    ns.Publish("AUCTIONS_CHANGED")
end)

ns.OnEvent("AUCTION_HOUSE_AUCTIONS_EXPIRED", function(auctionID)
    local _, index = FindOwned(auctionID)
    if index then
        table.remove(ns.GetCharacter().auctions, index)
        ns.Publish("AUCTIONS_CHANGED")
    end
end)

-- The owned list is only refreshed on request, and the default UI only asks
-- from its Auctions tab. A delay leaves the auction house UI time to initialise.
ns.OnEvent("AUCTION_HOUSE_SHOW", function()
    auctionHouseOpen = true
    C_Timer.After(1, function()
        if auctionHouseOpen then
            C_AuctionHouse.QueryOwnedAuctions(OWNED_SORTS)
        end
    end)
end)

ns.OnEvent("AUCTION_HOUSE_CLOSED", function()
    auctionHouseOpen = false
end)

-- A sale or expiry noticed through the mail ends the auction in our copy, which
-- otherwise stays stale until the next auction house visit. Mail does not name
-- the auction, so this matches on the item; the next sync corrects any mismatch.
function Auctions.Consume(itemID, quantity, includeSold)
    if not itemID then
        return
    end
    local auctions = ns.GetCharacter().auctions
    local remaining = quantity
    local function take(wantSold)
        for i = #auctions, 1, -1 do
            local auction = auctions[i]
            if remaining > 0 and auction.itemID == itemID and (auction.sold or false) == wantSold then
                local used = math.min(auction.qty, remaining)
                auction.qty = auction.qty - used
                remaining = remaining - used
                if auction.qty == 0 then
                    table.remove(auctions, i)
                end
            end
        end
    end
    if includeSold then
        take(true)
    end
    take(false)
    ns.Publish("AUCTIONS_CHANGED")
end

function Auctions.IsLive(auction, now)
    return not auction.expiresAt or auction.expiresAt > (now or time())
end

-- Returns every known auction not yet over, optionally for a single character.
function Auctions.GetAll(characterKey)
    local now = time()
    local rows = {}
    for key, character in pairs(ns.db.characters) do
        if not characterKey or key == characterKey then
            for _, auction in ipairs(character.auctions) do
                if Auctions.IsLive(auction, now) then
                    table.insert(rows, { auction = auction, char = key })
                end
            end
        end
    end
    return rows
end

-- Undercuts ---------------------------------------------------------------------

-- The account's auctions on sale on this realm's auction house that the latest scan
-- found a cheaper offer for, as { [auction] = lowest unit price }. The account's own
-- auctions do not undercut each other: an item is undercut when the lowest price on
-- sale is below the account's own lowest.
function Auctions.GetUndercut()
    local onSale = {}
    local ownLowest = {}
    for _, row in ipairs(Auctions.GetAll()) do
        local auction = row.auction
        if not auction.sold and auction.itemID and auction.unit and ns.Market.SharesAuctionHouse(row.char) then
            table.insert(onSale, auction)
            ownLowest[auction.itemID] = math.min(ownLowest[auction.itemID] or math.huge, auction.unit)
        end
    end
    local undercut = {}
    for _, auction in ipairs(onSale) do
        local market = ns.Market.GetItem(auction.itemID)
        if market and market.quantity > 0 and market.price < ownLowest[auction.itemID] then
            undercut[auction] = market.price
        end
    end
    return undercut
end

ns.Subscribe("MARKET_CHANGED", function()
    local count = 0
    for _ in pairs(Auctions.GetUndercut()) do
        count = count + 1
    end
    if count > 0 then
        ns.Print(L["Undercut auctions: %s. The Active list of the Auctions tab marks them."]:format(
            BreakUpLargeNumbers(count)))
    end
end)
