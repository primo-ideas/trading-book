local _, ns = ...
local L = ns.L

-- Selling from the bags in a few clicks: what can be listed, the price to propose
-- from what is on sale now, and the listing itself. The game only accepts a listing
-- from a click or a key press, so Post must never run from a timer or an event.
local Selling = {}
ns.Selling = Selling

local DEFAULT_HOURS = 48
local DURATION_BY_HOURS = { [12] = 1, [24] = 2, [48] = 3 }
local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD = 10000
-- What a sale brings once the auction house took its cut.
local AFTER_CUT = 0.95
local SELL_PRICE_RETURN = 11
-- A commodity's usual price is read at this share of what is on sale, so that a few
-- cheap units do not set it. Below this ratio of it, a price looks like a mistake.
local USUAL_PRICE_SHARE = 0.2
local USUAL_PRICE_MAX_QUANTITY = 5000
local LOW_PRICE_RATIO = 0.5

local COMMODITY_SORTS = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
local ITEM_SORTS = { { sortOrder = Enum.AuctionHouseSortOrder.Buyout, reverseSort = false } }

Selling.HOURS = { 12, 24, 48 }
Selling.DEFAULT_HOURS = DEFAULT_HOURS

Selling.PRICINGS = {
    { key = "same", label = L["Same price"], Apply = function(price) return price end },
    { key = "silver", label = L["1 silver less"], Apply = function(price) return price - COPPER_PER_SILVER end },
    { key = "gold", label = L["1 gold less"], Apply = function(price) return price - COPPER_PER_GOLD end },
    { key = "percent1", label = L["1% less"], Apply = function(price) return price * 0.99 end },
    { key = "percent5", label = L["5% less"], Apply = function(price) return price * 0.95 end },
    { key = "percent10", label = L["10% less"], Apply = function(price) return price * 0.9 end },
}

-- Settings ---------------------------------------------------------------------------

function Selling.GetDefaultHours()
    return ns.db.ui.sellHours or DEFAULT_HOURS
end

function Selling.SetDefaultHours(hours)
    ns.db.ui.sellHours = hours ~= DEFAULT_HOURS and hours or nil
end

function Selling.GetPricingKey()
    return ns.db.ui.sellPricing or Selling.PRICINGS[1].key
end

function Selling.SetPricingKey(key)
    ns.db.ui.sellPricing = key ~= Selling.PRICINGS[1].key and key or nil
end

function Selling.IsAutoNextEnabled()
    return not ns.db.ui.noSellAutoNext
end

function Selling.SetAutoNextEnabled(enabled)
    ns.db.ui.noSellAutoNext = not enabled or nil
end

function Selling.AreShortcutsEnabled()
    return not ns.db.ui.noSellShortcuts
end

function Selling.SetShortcutsEnabled(enabled)
    ns.db.ui.noSellShortcuts = not enabled or nil
    ns.Publish("SELL_SHORTCUTS_CHANGED")
end

-- Prices -----------------------------------------------------------------------------

-- The game silently refuses a price with copper in it, or under one silver.
function Selling.NormalizePrice(price)
    return math.max(COPPER_PER_SILVER, math.ceil(price / COPPER_PER_SILVER) * COPPER_PER_SILVER)
end

-- The price to propose against the lowest one on sale. One's own lowest price needs
-- no undercutting.
function Selling.ProposePrice(lowest, isOwnLowest)
    if isOwnLowest then
        return Selling.NormalizePrice(lowest)
    end
    for _, pricing in ipairs(Selling.PRICINGS) do
        if pricing.key == Selling.GetPricingKey() then
            return Selling.NormalizePrice(pricing.Apply(lowest))
        end
    end
    return Selling.NormalizePrice(lowest)
end

-- Why a price deserves a second look, or nil. floor: the price under which a commodity
-- looks like a mistake, when known.
function Selling.GetPriceWarning(item, unitPrice, floor)
    local vendorPrice = select(SELL_PRICE_RETURN, C_Item.GetItemInfo(item.link))
    if vendorPrice and vendorPrice > 0 and unitPrice * AFTER_CUT < vendorPrice then
        return L["Below the vendor price"]
    end
    if floor and unitPrice <= floor then
        return L["Unusually low price"]
    end
end

-- Bags -------------------------------------------------------------------------------

local function IsEquipment(link)
    local classID = select(6, C_Item.GetItemInfoInstant(link))
    return classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor
end

-- Commodities are one item whatever their stack. Other items differ by level and
-- suffix, and sell separately.
local function ListingKey(itemKey, isCommodity)
    if isCommodity then
        return tostring(itemKey.itemID)
    end
    return table.concat({
        itemKey.itemID, itemKey.itemLevel or 0, itemKey.itemSuffix or 0, itemKey.battlePetSpeciesID or 0,
    }, ":")
end

local function ReadSlot(bagID, slot)
    local info = C_Container.GetContainerItemInfo(bagID, slot)
    -- Locked: on its way to the auction house, or held by the cursor.
    if not info or info.isBound or info.isLocked then
        return nil
    end
    -- Junk is not worth listing, apart from gear that collectors buy for its look.
    if info.quality == Enum.ItemQuality.Poor and not IsEquipment(info.hyperlink) then
        return nil
    end
    local location = ItemLocation:CreateFromBagAndSlot(bagID, slot)
    if not (C_Item.DoesItemExist(location) and C_AuctionHouse.IsSellItemValid(location, false)) then
        return nil
    end
    local status = C_AuctionHouse.GetItemCommodityStatus(location)
    if status == Enum.ItemCommodityStatus.Unknown then
        return nil -- Not loaded yet: the next bag update brings it.
    end
    return info, location, status == Enum.ItemCommodityStatus.Commodity
end

-- What the bags hold that can be listed, one entry per kind of item, as
-- { key, itemID, itemKey, location, count, qty, link, name, icon, quality, isCommodity }.
function Selling.GetBagItems()
    local items, byKey = {}, {}
    for _, bagID in ipairs(ns.Stockpile.BAG_IDS) do
        for slot = 1, C_Container.GetContainerNumSlots(bagID) do
            local info, location, isCommodity = ReadSlot(bagID, slot)
            if info then
                local itemKey = C_AuctionHouse.GetItemKeyFromItem(location)
                local key = ListingKey(itemKey, isCommodity)
                local item = byKey[key]
                if item then
                    item.count = item.count + info.stackCount
                    item.qty = item.count
                else
                    local name = info.itemName
                    if not isCommodity and (itemKey.itemLevel or 0) > 0 then
                        name = ("%s (%d)"):format(name, itemKey.itemLevel)
                    end
                    item = {
                        key = key, itemID = info.itemID, itemKey = itemKey, location = location,
                        count = info.stackCount, qty = info.stackCount, link = info.hyperlink, name = name,
                        icon = info.iconFileID, quality = info.quality, isCommodity = isCommodity,
                    }
                    byKey[key] = item
                    table.insert(items, item)
                    ns.RememberItem(info.itemID, info.itemName, info.quality, info.iconFileID)
                end
            end
        end
    end
    return items
end

-- Search -----------------------------------------------------------------------------

-- One search at a time: choosing another item replaces it.
local search = nil

-- onResult(lowest, isOwnLowest, floor) comes once the auction house answered, with a
-- nil lowest when nothing is on sale.
function Selling.Search(item, onResult)
    search = { item = item, onResult = onResult }
    ns.Market.SendQuery(function()
        if item.isCommodity then
            C_AuctionHouse.SendSearchQuery(C_AuctionHouse.MakeItemKey(item.itemID), COMMODITY_SORTS, true)
        else
            C_AuctionHouse.SendSellSearchQuery(item.itemKey, ITEM_SORTS, true)
        end
    end)
end

function Selling.CancelSearch()
    search = nil
    ns.Market.CancelQuery()
end

local function Answer(lowest, isOwnLowest, floor)
    local onResult = search.onResult
    Selling.CancelSearch()
    onResult(lowest, isOwnLowest, floor)
end

local function CommodityFloor(itemID)
    local onSale = C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID)
    local target = math.min(USUAL_PRICE_MAX_QUANTITY, math.floor(onSale * USUAL_PRICE_SHARE))
    local seen = 0
    for index = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
        local result = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, index)
        seen = seen + result.quantity
        if seen >= target then
            return result.unitPrice * LOW_PRICE_RATIO
        end
    end
end

ns.OnEvent("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
    if not (search and search.item.isCommodity and search.item.itemID == itemID) then
        return
    end
    if C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID) == 0 then
        Answer(nil)
        return
    end
    local first = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
    local isOwnLowest = first.containsOwnerItem and first.owners[1] == "player"
    Answer(first.unitPrice, isOwnLowest, CommodityFloor(itemID))
end)

local function SameLevel(a, b)
    return a.itemID == b.itemID and (a.itemLevel or 0) == (b.itemLevel or 0) and (a.itemSuffix or 0) == (b.itemSuffix or 0)
end

ns.OnEvent("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
    if not (search and not search.item.isCommodity and SameLevel(search.item.itemKey, itemKey)) then
        return
    end
    for index = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) do
        local result = C_AuctionHouse.GetItemSearchResultInfo(itemKey, index)
        -- Auctions without a buyout only take bids, and give no price.
        if result and result.buyoutAmount then
            Answer(result.buyoutAmount, result.containsOwnerItem)
            return
        end
    end
    Answer(nil)
end)

-- Listing ----------------------------------------------------------------------------

function Selling.GetPostLimit(item)
    return math.min(C_AuctionHouse.GetAvailablePostCount(item.location), item.count)
end

function Selling.GetDeposit(item, quantity, hours)
    local duration = DURATION_BY_HOURS[hours]
    local deposit
    if item.isCommodity then
        deposit = C_AuctionHouse.CalculateCommodityDeposit(item.itemID, duration, quantity)
    else
        deposit = C_AuctionHouse.CalculateItemDeposit(item.location, duration, quantity)
    end
    return Selling.NormalizePrice(deposit or 0)
end

-- Several copies of an item that does not stack are listed one after the other, and
-- nothing else can be listed in the meantime.
local multisell = false

local function SetMultisell(inProgress)
    multisell = inProgress
    ns.Publish("SELL_STATE_CHANGED")
end

ns.OnEvent("AUCTION_MULTISELL_START", function()
    SetMultisell(true)
end)

ns.OnEvent("AUCTION_MULTISELL_UPDATE", function(posted, total)
    if posted == total then
        SetMultisell(false)
    end
end)

ns.OnEvent("AUCTION_MULTISELL_FAILURE", function()
    SetMultisell(false)
end)

-- Leaving the view stops what it started, as the game's own selling does.
function Selling.StopMultisell()
    if multisell then
        C_AuctionHouse.CancelSell()
        SetMultisell(false)
    end
end

-- Whether the game would take this listing right now.
function Selling.CanPost(item, quantity, unitPrice, hours)
    return not multisell
        and C_AuctionHouse.IsThrottledMessageSystemReady()
        and C_Item.DoesItemExist(item.location)
        and quantity ~= nil and quantity > 0 and quantity <= Selling.GetPostLimit(item)
        and unitPrice ~= nil and unitPrice >= COPPER_PER_SILVER and unitPrice % COPPER_PER_SILVER == 0
        and GetMoney() >= Selling.GetDeposit(item, quantity, hours)
end

-- When the game wants the listing confirmed, its own dialog reads it back from its
-- sell frames, which are not the ones in use here.
function Selling.Post(item, quantity, unitPrice, hours)
    local duration = DURATION_BY_HOURS[hours]
    if item.isCommodity then
        if C_AuctionHouse.PostCommodity(item.location, duration, quantity, unitPrice) then
            AuctionHouseFrame.CommoditiesSellFrame:CachePendingPost(item.location, duration, quantity, unitPrice)
        end
    elseif C_AuctionHouse.PostItem(item.location, duration, quantity, nil, unitPrice) then
        AuctionHouseFrame.ItemSellFrame:CachePendingPost(item.location, duration, quantity, nil, unitPrice)
    end
end
