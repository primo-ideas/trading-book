local _, ns = ...
local L = ns.L

-- A shopping list from the tracked recipes: their components, less what is already
-- held and what those recipes make themselves. An item being crafted is only on the
-- list when a tracked recipe needs it as a component.
--
-- Buying takes two steps, which the game requires from a click or a key press: asking
-- for the exact price of a quantity, then confirming it.
local Shopping = {}
ns.Shopping = Shopping

local MAX_CRAFTS = 999
-- What a sale brings once the auction house took its cut.
local AFTER_CUT = 0.95
local BIND_TYPE_RETURN = 14
local SALES_DAYS = 14
local SECONDS_PER_DAY = 86400
-- Prices up to this ratio of the lowest one still count as a good price.
local GOOD_PRICE_RATIO = 1.2
-- An average this far above the lowest price means buying deep into dearer auctions.
local PRICE_CLIMB_RATIO = 1.25
-- A price this far above an item's usual price deserves a second look.
local USUAL_PRICE_RATIO = 1.3

local COMMODITY_SORTS = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }

Shopping.STOCK_SCOPES = {
    { key = "character", label = L["This character and the Warband bank"] },
    { key = "account", label = L["Whole account"] },
}

Shopping.QUALITIES = {
    { key = "cheapest", label = L["The cheapest"] },
    { key = "highest", label = L["The highest quality"] },
}

-- Settings ---------------------------------------------------------------------------

function Shopping.GetStockScopeKey()
    return ns.db.ui.shoppingStock or Shopping.STOCK_SCOPES[1].key
end

function Shopping.SetStockScopeKey(key)
    ns.db.ui.shoppingStock = key ~= Shopping.STOCK_SCOPES[1].key and key or nil
    ns.Publish("SHOPPING_CHANGED")
end

function Shopping.GetQualityKey()
    return ns.db.ui.shoppingQuality or Shopping.QUALITIES[1].key
end

function Shopping.SetQualityKey(key)
    ns.db.ui.shoppingQuality = key ~= Shopping.QUALITIES[1].key and key or nil
    ns.Publish("SHOPPING_CHANGED")
end

-- How many times to craft each recipe, one by default. Zero leaves it off the list.
function Shopping.GetCrafts(key)
    local crafts = ns.db.ui.shoppingCrafts
    return crafts and crafts[key] or 1
end

local function StoreCrafts(key, count)
    local crafts = ns.db.ui.shoppingCrafts or {}
    crafts[key] = count ~= 1 and count or nil
    ns.db.ui.shoppingCrafts = next(crafts) and crafts or nil
end

function Shopping.SetCrafts(key, count)
    StoreCrafts(key, math.max(0, math.min(MAX_CRAFTS, math.floor(count))))
    ns.Publish("SHOPPING_CHANGED")
end

-- Recipes ----------------------------------------------------------------------------

local function ReadSlots(schematic)
    local slots = {}
    for _, slot in ipairs(schematic.reagentSlotSchematics) do
        local tiers = {}
        -- Basic: the components a craft cannot do without. A currency has no item.
        if slot.reagentType == Enum.CraftingReagentType.Basic then
            for _, reagent in ipairs(slot.reagents) do
                if reagent.itemID then
                    table.insert(tiers, reagent.itemID)
                end
            end
        end
        if #tiers > 0 then
            table.insert(slots, { tiers = tiers, quantity = slot.quantityRequired, variable = slot.variableQuantities })
        end
    end
    return slots
end

local function ReadRecipe(recipeID, isRecraft)
    local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, isRecraft)
    local key = recipeID .. (isRecraft and ":recraft" or "")
    return {
        key = key,
        recipeID = recipeID,
        isRecraft = isRecraft,
        name = schematic.name,
        icon = schematic.icon,
        outputItemID = schematic.outputItemID,
        -- The least a craft is sure to make.
        outputQuantity = schematic.quantityMin or 1,
        crafts = Shopping.GetCrafts(key),
        slots = ReadSlots(schematic),
    }
end

-- The tracked recipes, as { key, name, icon, outputItemID, outputQuantity, crafts, slots }.
function Shopping.GetRecipes()
    local recipes = {}
    for _, isRecraft in ipairs({ false, true }) do
        for _, recipeID in ipairs(C_TradeSkillUI.GetRecipesTracked(isRecraft)) do
            table.insert(recipes, ReadRecipe(recipeID, isRecraft))
        end
    end
    return recipes
end

-- A component's quality can change how many a craft takes.
local function SlotQuantity(slot, itemID)
    for _, variable in ipairs(slot.variable or {}) do
        if variable.reagent.itemID == itemID then
            return variable.quantity
        end
    end
    return slot.quantity
end

local function UnitPrice(itemID)
    return (ns.Stats.GetUnitPrice(itemID))
end

-- Which quality of a component to buy.
local function ChooseTier(tiers)
    if Shopping.GetQualityKey() == "highest" then
        return tiers[#tiers]
    end
    local chosen, lowest = tiers[1], nil
    for _, itemID in ipairs(tiers) do
        local price = UnitPrice(itemID)
        if price and (not lowest or price < lowest) then
            chosen, lowest = itemID, price
        end
    end
    return chosen
end

-- Bound items never reach the auction house. Unknown until the item has loaded.
local function IsBound(itemID)
    local bindType = select(BIND_TYPE_RETURN, C_Item.GetItemInfo(itemID))
    return bindType ~= nil and bindType ~= Enum.ItemBind.None and bindType ~= Enum.ItemBind.OnEquip
        and bindType ~= Enum.ItemBind.OnUse
end

-- What a craft is worth once sold, less its components, or nil without the prices.
function Shopping.GetEconomics(recipe)
    local cost = 0
    for _, slot in ipairs(recipe.slots) do
        local itemID = ChooseTier(slot.tiers)
        if not IsBound(itemID) then
            local price = UnitPrice(itemID)
            if not price then
                return nil
            end
            cost = cost + price * SlotQuantity(slot, itemID)
        end
    end
    local sale = recipe.outputItemID and UnitPrice(recipe.outputItemID)
    if not sale then
        return cost, nil, nil
    end
    local value = sale * recipe.outputQuantity * AFTER_CUT
    return cost, value, value - cost
end

-- The list ---------------------------------------------------------------------------

-- What can be counted on, across the qualities of a component.
local function HeldCount(tiers)
    local held = 0
    for _, itemID in ipairs(tiers) do
        local row = ns.Stockpile.GetItemRow(itemID)
        if row then
            if Shopping.GetStockScopeKey() == "account" then
                held = held + row.bags + row.bank + row.mail + row.warband
            else
                local own = row.characters[ns.playerKey] or {}
                held = held + (own.bags or 0) + (own.bank or 0) + (own.mail or 0) + row.warband
            end
        end
    end
    return held
end

-- A recraft improves an item already made: it adds none to the stock.
local function Makes(recipe, itemID)
    return not recipe.isRecraft and recipe.outputItemID == itemID
end

local function ProducedCount(tiers, recipes)
    local produced = 0
    for _, recipe in ipairs(recipes) do
        for _, itemID in ipairs(tiers) do
            if Makes(recipe, itemID) then
                produced = produced + recipe.crafts * recipe.outputQuantity
            end
        end
    end
    return produced
end

local function RequestUnloaded(itemID)
    if not C_Item.GetItemInfo(itemID) then
        C_Item.RequestLoadItemDataByID(itemID)
    end
end

-- What a unit costs to craft with the tracked recipes that make it, the cheapest of
-- them, or nil when none does or a price is missing.
local function CraftUnitCost(tiers, recipes)
    local best = nil
    for _, recipe in ipairs(recipes) do
        for _, itemID in ipairs(tiers) do
            if Makes(recipe, itemID) then
                local cost = Shopping.GetEconomics(recipe)
                if cost then
                    local unit = cost / recipe.outputQuantity
                    best = best and math.min(best, unit) or unit
                end
            end
        end
    end
    return best
end

-- What a unit of an item costs to craft with the tracked recipes, from
-- Shopping.GetRecipes(), or nil.
function Shopping.GetCraftCost(itemID, recipes)
    return CraftUnitCost({ itemID }, recipes)
end

-- One row per component, as { key, itemID, name, need, held, produced, have, buy, unit,
-- cost, craftUnit, recipes }. Stacks of every quality of a component count towards it.
function Shopping.GetList(recipes)
    local rows, byKey = {}, {}
    for _, recipe in ipairs(recipes) do
        if recipe.crafts > 0 then
            for _, slot in ipairs(recipe.slots) do
                local key = slot.tiers[1]
                local row = byKey[key]
                if not row then
                    local itemID = ChooseTier(slot.tiers)
                    RequestUnloaded(itemID)
                    -- Known items keep a daily price, which gives their usual price.
                    ns.RememberItem(itemID)
                    if not IsBound(itemID) then
                        row = { key = key, itemID = itemID, tiers = slot.tiers, need = 0, recipes = {} }
                        byKey[key] = row
                        table.insert(rows, row)
                    end
                end
                if row then
                    row.need = row.need + recipe.crafts * SlotQuantity(slot, row.itemID)
                    row.recipes[recipe.name] = true
                end
            end
        end
    end
    for _, row in ipairs(rows) do
        row.name = ns.GetItemDetails(row.itemID)
        row.held = HeldCount(row.tiers)
        row.produced = ProducedCount(row.tiers, recipes)
        row.have = row.held + row.produced
        row.buy = math.max(0, row.need - row.have)
        row.unit = UnitPrice(row.itemID)
        row.cost = row.unit and row.unit * row.buy or nil
        row.craftUnit = CraftUnitCost(row.tiers, recipes)
    end
    return rows
end

-- What the list costs at the known prices, and how many rows have none.
function Shopping.GetTotal(rows)
    local total, unpriced = 0, 0
    for _, row in ipairs(rows) do
        if row.buy > 0 then
            if row.cost then
                total = total + row.cost
            else
                unpriced = unpriced + 1
            end
        end
    end
    return total, unpriced
end

-- How many crafts make up a week of recent sales, beyond what is already in stock, or
-- nil for an item that did not sell lately, or for a recraft, which restocks nothing.
function Shopping.SuggestCrafts(recipe, sold)
    local units = not recipe.isRecraft and recipe.outputItemID and sold[recipe.outputItemID]
    if not units then
        return nil
    end
    local row = ns.Stockpile.GetItemRow(recipe.outputItemID)
    local missing = units * 7 / SALES_DAYS - (row and row.total or 0)
    return math.max(0, math.ceil(missing / recipe.outputQuantity))
end

function Shopping.GetRecentSales()
    return ns.Stats.GetSoldQuantities(time() - SALES_DAYS * SECONDS_PER_DAY)
end

-- Sets the crafts of the recipes that have recent sales. Returns how many it set.
function Shopping.ApplySalesSuggestions(recipes)
    local sold = Shopping.GetRecentSales()
    local applied = 0
    for _, recipe in ipairs(recipes) do
        local suggested = Shopping.SuggestCrafts(recipe, sold)
        if suggested then
            StoreCrafts(recipe.key, math.min(MAX_CRAFTS, suggested))
            applied = applied + 1
        end
    end
    if applied > 0 then
        ns.Publish("SHOPPING_CHANGED")
    end
    return applied
end

-- Search and quote ----------------------------------------------------------------------

local search = nil

-- onResult(isCommodity, itemKey) comes once the auction house answered, with the key
-- the results of an item sold by the unit are read with.
function Shopping.Search(itemID, onResult)
    search = { itemID = itemID, onResult = onResult }
    ns.Market.SendQuery(function()
        -- Separately from one's own auctions, which cannot be bought.
        C_AuctionHouse.SendSearchQuery(C_AuctionHouse.MakeItemKey(itemID), COMMODITY_SORTS, true)
    end)
end

function Shopping.CancelSearch()
    search = nil
    ns.Market.CancelQuery()
end

local function Answer(isCommodity, itemKey)
    local onResult = search.onResult
    Shopping.CancelSearch()
    onResult(isCommodity, itemKey)
end

ns.OnEvent("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
    if search and search.itemID == itemID then
        Answer(true)
    end
end)

ns.OnEvent("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
    if search and search.itemID == itemKey.itemID then
        Answer(false, itemKey)
    end
end)

-- What a quantity would cost from the latest answer, the cheapest auctions first, as
-- { lowest, average, total, bought, onSale, goodQuantity }.
function Shopping.GetQuote(itemID, quantity)
    local quote = { total = 0, bought = 0, onSale = 0, goodQuantity = 0 }
    for index = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
        local result = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, index)
        if result and not result.containsOwnerItem then
            quote.lowest = quote.lowest or result.unitPrice
            quote.onSale = quote.onSale + result.quantity
            if result.unitPrice <= quote.lowest * GOOD_PRICE_RATIO then
                quote.goodQuantity = quote.goodQuantity + result.quantity
            end
            local taken = math.min(result.quantity, quantity - quote.bought)
            if taken > 0 then
                quote.total = quote.total + taken * result.unitPrice
                quote.bought = quote.bought + taken
            end
        end
    end
    quote.average = quote.bought > 0 and quote.total / quote.bought or nil
    return quote
end

-- Why a unit price deserves a second look against the item's usual price, or nil.
function Shopping.GetUsualPriceWarning(itemID, unitPrice)
    local usual = ns.Market.GetUsualPrice(itemID)
    if usual and unitPrice > usual * USUAL_PRICE_RATIO then
        return L["Dearer than usual: %s"]:format(ns.FormatPercent(unitPrice / usual - 1, true))
    end
end

-- Why a quantity deserves a second look, or nil.
function Shopping.GetQuoteWarning(quote, itemID)
    if quote.average and quote.average > quote.lowest * PRICE_CLIMB_RATIO then
        return L["The price climbs with the quantity"]
    end
    return quote.lowest and Shopping.GetUsualPriceWarning(itemID, quote.lowest)
end

-- An item sold by the unit: the cheapest auction with a buyout, one's own aside.
function Shopping.GetCheapestAuction(itemKey)
    local cheapest = nil
    for index = 1, C_AuctionHouse.GetNumItemSearchResults(itemKey) do
        local result = C_AuctionHouse.GetItemSearchResultInfo(itemKey, index)
        if result and result.buyoutAmount and not result.containsOwnerItem
            and (not cheapest or result.buyoutAmount < cheapest.buyoutAmount) then
            cheapest = result
        end
    end
    return cheapest
end

-- Buying -------------------------------------------------------------------------------

local purchase = nil

-- onPriced(total) comes with the exact price, onDone(succeeded) when it is over.
function Shopping.StartPurchase(itemID, quantity, onPriced, onDone)
    purchase = { itemID = itemID, quantity = quantity, onPriced = onPriced, onDone = onDone }
    C_AuctionHouse.StartCommoditiesPurchase(itemID, quantity)
end

function Shopping.ConfirmPurchase()
    C_AuctionHouse.ConfirmCommoditiesPurchase(purchase.itemID, purchase.quantity)
end

-- An auction bought outright cannot be called back, so leaving only stops waiting for it.
local auctionPurchase = nil

function Shopping.CancelPurchase()
    if purchase then
        purchase = nil
        C_AuctionHouse.CancelCommoditiesPurchase()
    end
    if auctionPurchase then
        auctionPurchase.onDone = nil
    end
end

-- Buys one auction of an item sold by the unit, at its buyout. onDone(succeeded).
function Shopping.BuyAuction(itemID, auction, onDone)
    auctionPurchase = { auctionID = auction.auctionID, itemID = itemID, quantity = auction.quantity, onDone = onDone }
    C_AuctionHouse.PlaceBid(auction.auctionID, auction.buyoutAmount)
end

local function FinishAuctionPurchase(succeeded)
    local done = auctionPurchase
    auctionPurchase = nil
    if succeeded then
        ns.Stockpile.AddToMail(done.itemID, done.quantity)
    end
    if done.onDone then
        done.onDone(succeeded)
    end
end

ns.OnEvent("AUCTION_HOUSE_PURCHASE_COMPLETED", function(auctionID)
    if auctionPurchase and auctionPurchase.auctionID == auctionID then
        FinishAuctionPurchase(true)
    end
end)

ns.OnEvent("AUCTION_HOUSE_SHOW_ERROR", function()
    if auctionPurchase then
        FinishAuctionPurchase(false)
    end
end)

local function FinishPurchase(succeeded)
    if purchase then
        local onDone = purchase.onDone
        purchase = nil
        onDone(succeeded)
    end
end

ns.OnEvent("COMMODITY_PRICE_UPDATED", function(_, total)
    if purchase then
        purchase.onPriced(total)
    end
end)

ns.OnEvent("COMMODITY_PRICE_UNAVAILABLE", function()
    if purchase then
        C_AuctionHouse.CancelCommoditiesPurchase()
        FinishPurchase(false)
    end
end)

ns.OnEvent("COMMODITY_PURCHASE_SUCCEEDED", function()
    FinishPurchase(true)
end)

ns.OnEvent("COMMODITY_PURCHASE_FAILED", function()
    FinishPurchase(false)
end)

-- Whatever bought it, what is bought waits in the mail from now on.
ns.OnEvent("COMMODITY_PURCHASED", function(itemID, quantity)
    ns.Stockpile.AddToMail(itemID, quantity)
end)
