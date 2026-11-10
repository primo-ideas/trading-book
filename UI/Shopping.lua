local _, ns = ...
local L = ns.L
local UI = ns.UI
local Shopping = ns.Shopping
local Colors = UI.Colors

-- The shopping list in the Trading Book tab of the auction house: the tracked recipes
-- and how many times to craft them on the left, what they need on the right, and
-- buying it one component after the other.

local LEFT_WIDTH = 300
local RIGHT_LEFT = LEFT_WIDTH + 12
local TITLE_HEIGHT = 20
local STRIP_HEIGHT = 72
local CONTROL_HEIGHT = 22
local STEP_BUTTON_WIDTH = 24
local CRAFTS_WIDTH = 44
local LABEL_WIDTH = 70
local QUANTITY_WIDTH = 60
local GOOD_WIDTH = 130
local BUY_WIDTH, BUY_HEIGHT = 130, 26
local STEP_WIDTH = 84
local REFRESH_DELAY_SECONDS = 0.2

local BUY_BUTTON, NEXT_BUTTON, PREVIOUS_BUTTON =
    "TradingBookShoppingBuy", "TradingBookShoppingNext", "TradingBookShoppingPrevious"
local SHORTCUTS = {
    SPACE = BUY_BUTTON,
    ["SHIFT-SPACE"] = NEXT_BUTTON,
    BACKSPACE = PREVIOUS_BUTTON,
}

local view, recipeTable, listTable = nil, nil, nil
local craftsBox, totalText, infoText, warningText, quantityBox, goodButton, buyButton, nextButton, previousButton

local active = false
local recipes, rows = {}, {}
local selectedRecipe = nil
local current = nil
-- "idle", "searching", "ready", "pricing" (asked for the exact price), "priced", "buying".
local state = "idle"
local isCommodity = true
-- For an item sold by the unit: the auction to buy next.
local auction = nil
local pricedTotal = nil
-- A quantity that deserves a second look was presented once.
local armed = false

local Refresh

-- Fields -------------------------------------------------------------------------------

local function ReadQuantity()
    return tonumber(quantityBox:GetText())
end

local function FindRow(key)
    for _, row in ipairs(rows) do
        if row.key == key then
            return row
        end
    end
end

-- The row a number of steps from the current one, as the list shows them. wanted only
-- keeps the rows with something to buy.
local function NeighbourKey(offset, wanted)
    if not current then
        return nil
    end
    local index
    for position, row in ipairs(listTable.rows) do
        if row.key == current.key then
            index = position
        end
    end
    while index do
        index = index + offset
        local row = listTable.rows[index]
        if not row then
            return nil
        end
        if not wanted or row.buy > 0 then
            return row.key
        end
    end
end

local function CurrentQuote()
    return Shopping.GetQuote(current.itemID, ReadQuantity() or 0)
end

local function CanBuy(quote)
    local quantity = ReadQuantity()
    if not (C_AuctionHouse.IsThrottledMessageSystemReady() and quantity ~= nil and quantity > 0) then
        return false
    end
    if not isCommodity then
        return auction ~= nil and GetMoney() >= auction.buyoutAmount
    end
    return quantity <= quote.onSale and GetMoney() >= quote.total
end

-- Why buying deserves a second look, or nil.
local function CurrentWarning(quote)
    if isCommodity then
        return Shopping.GetQuoteWarning(quote, current.itemID)
    end
    return auction and Shopping.GetUsualPriceWarning(current.itemID, auction.buyoutAmount / auction.quantity)
end

-- A component a tracked recipe makes for less than it sells for.
local function CraftHint(unitPrice)
    if current.craftUnit and unitPrice and current.craftUnit < unitPrice then
        return L["Cheaper to craft: %s each"]:format(ns.FormatMoney(current.craftUnit))
    end
end

local function ShowWarning(warning, hint)
    local color = warning and Colors.loss or Colors.gain
    warningText:SetTextColor(color[1], color[2], color[3])
    warningText:SetText(warning or hint or "")
end

local function UpdateRecipeControls()
    local recipe = selectedRecipe
    if recipe and not craftsBox:HasFocus() then
        craftsBox:SetText(tostring(recipe.crafts))
    elseif not recipe then
        craftsBox:SetText("")
    end
end

local function UpdateDetail()
    if not view then
        return
    end
    infoText:SetText("")
    warningText:SetText("")
    goodButton:Hide()
    buyButton:SetText(L["Buy"])
    local enabled = false

    if current then
        if state == "searching" then
            infoText:SetText(L["Searching..."])
        elseif not isCommodity then
            if not auction then
                infoText:SetText(L["None on sale"])
            else
                infoText:SetText(L["Cheapest: %s for %s"]:format(BreakUpLargeNumbers(auction.quantity),
                    ns.FormatMoney(auction.buyoutAmount)))
                ShowWarning(CurrentWarning(), CraftHint(auction.buyoutAmount / auction.quantity))
                if state == "priced" then
                    infoText:SetText(L["Exact total: %s"]:format(ns.FormatExactMoney(pricedTotal)))
                    buyButton:SetText(L["Confirm"])
                    enabled = true
                elseif state == "ready" then
                    enabled = CanBuy()
                    if armed then
                        buyButton:SetText(L["Confirm"])
                    end
                end
            end
        else
            local quote, quantity = CurrentQuote(), ReadQuantity() or 0
            if not quote.lowest then
                infoText:SetText(L["None on sale"])
            else
                if quote.average then
                    infoText:SetText(L["Lowest %s, average %s, total %s"]:format(ns.FormatMoney(quote.lowest),
                        ns.FormatMoney(quote.average), ns.FormatMoney(quote.total)))
                else
                    infoText:SetText(ns.FormatMoney(quote.lowest))
                end
                local warning = CurrentWarning(quote)
                if quantity > quote.onSale then
                    warning = L["Only %s on sale"]:format(BreakUpLargeNumbers(quote.onSale))
                end
                ShowWarning(warning, CraftHint(quote.lowest))
                if quote.goodQuantity < quantity then
                    goodButton:SetText(L["Good price: %s"]:format(BreakUpLargeNumbers(quote.goodQuantity)))
                    goodButton:Show()
                end
                if state == "priced" then
                    infoText:SetText(L["Exact total: %s"]:format(ns.FormatExactMoney(pricedTotal)))
                    buyButton:SetText(L["Confirm"])
                    enabled = true
                elseif state == "ready" then
                    enabled = CanBuy(quote)
                    if armed then
                        buyButton:SetText(L["Confirm"])
                    end
                end
            end
        end
    end
    buyButton:SetEnabled(enabled)
    nextButton:SetEnabled(NeighbourKey(1) ~= nil)
    previousButton:SetEnabled(NeighbourKey(-1) ~= nil)
end

-- Choosing a component ------------------------------------------------------------------

local function SearchCurrent()
    state, armed, auction = "searching", false, nil
    Shopping.Search(current.itemID, function(commodity, itemKey)
        isCommodity = commodity
        auction = not commodity and Shopping.GetCheapestAuction(itemKey) or nil
        state = "ready"
        if commodity then
            local onSale = CurrentQuote().onSale
            -- No more than can be bought, unless nothing is on sale at all.
            if onSale > 0 and (ReadQuantity() or 0) > onSale then
                quantityBox:SetText(tostring(onSale))
            end
        end
        UpdateDetail()
    end)
end

local function Select(key)
    Shopping.CancelPurchase()
    Shopping.CancelSearch()
    current = key and FindRow(key) or nil
    state, armed, pricedTotal = "idle", false, nil
    isCommodity, auction = true, nil
    if current then
        quantityBox:SetText(tostring(current.buy))
        SearchCurrent()
    else
        quantityBox:SetText("")
    end
    listTable:ApplySort()
    UpdateDetail()
end

local function OnPurchaseDone(succeeded)
    if not current then
        return
    end
    if succeeded then
        Select(NeighbourKey(1, true))
    else
        SearchCurrent()
        UpdateDetail()
    end
end

-- One auction of an item sold by the unit is bought; more of it may be wanted still.
local function OnAuctionBought(succeeded)
    if not current then
        return
    end
    local remaining = (ReadQuantity() or 0) - (auction and auction.quantity or 0)
    if succeeded and remaining <= 0 then
        Select(NeighbourKey(1, true))
        return
    end
    if succeeded then
        quantityBox:SetText(tostring(remaining))
    end
    SearchCurrent()
    UpdateDetail()
end

local function Buy()
    if not current then
        return
    end
    if state == "priced" then
        state = "buying"
        if isCommodity then
            Shopping.ConfirmPurchase()
        else
            Shopping.BuyAuction(current.itemID, auction, OnAuctionBought)
        end
        UpdateDetail()
        return
    end
    local quote = CurrentQuote()
    if state ~= "ready" or not CanBuy(quote) then
        return
    end
    if not armed and CurrentWarning(quote) then
        armed = true
        UpdateDetail()
        return
    end
    if not isCommodity then
        -- Its buyout is the exact price: shown before buying, like the game's own.
        state, pricedTotal = "priced", auction.buyoutAmount
        UpdateDetail()
        return
    end
    state = "pricing"
    Shopping.StartPurchase(current.itemID, ReadQuantity(), function(total)
        state, pricedTotal = "priced", total
        UpdateDetail()
    end, OnPurchaseDone)
    UpdateDetail()
end

local function Step(offset)
    local key = NeighbourKey(offset)
    if key then
        Select(key)
    end
end

-- Data ---------------------------------------------------------------------------------

Refresh = function()
    if not (view and active) then
        return
    end
    recipes = Shopping.GetRecipes()
    local sold = Shopping.GetRecentSales()
    for _, recipe in ipairs(recipes) do
        recipe.cost, recipe.value, recipe.margin = Shopping.GetEconomics(recipe)
        recipe.sold = recipe.outputItemID and sold[recipe.outputItemID]
        recipe.suggested = Shopping.SuggestCrafts(recipe, sold)
    end
    local selectedKey = selectedRecipe and selectedRecipe.key
    selectedRecipe = recipes[1]
    for _, recipe in ipairs(recipes) do
        if recipe.key == selectedKey then
            selectedRecipe = recipe
        end
    end
    recipeTable:SetRows(recipes)
    UpdateRecipeControls()

    rows = Shopping.GetList(recipes)
    listTable:SetRows(rows)
    local total, unpriced = Shopping.GetTotal(rows)
    totalText:SetText(L["Total"] .. " " .. ns.FormatMoney(total) .. (unpriced > 0 and " +" or ""))

    if current then
        local fresh = FindRow(current.key)
        if fresh then
            current = fresh
            UpdateDetail()
        else
            Select(nil)
        end
    else
        UpdateDetail()
    end
end

local function RequestRefresh()
    if active then
        ns.Debounce("shoppingList", REFRESH_DELAY_SECONDS, Refresh)
    end
end

ns.OnEvent("TRACKED_RECIPE_UPDATE", RequestRefresh)
ns.OnEvent("ITEM_DATA_LOAD_RESULT", RequestRefresh)
ns.Subscribe("SHOPPING_CHANGED", RequestRefresh)
ns.Subscribe("STOCK_CHANGED", RequestRefresh)
ns.Subscribe("MARKET_CHANGED", RequestRefresh)
ns.Subscribe("AUCTIONATOR_PRICES_CHANGED", RequestRefresh)

ns.OnEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", UpdateDetail)
ns.OnEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_SENT", UpdateDetail)

-- Shortcuts ----------------------------------------------------------------------------

-- Key bindings cannot change in combat, so they wait for it to end.
local function ApplyShortcuts()
    if not view or InCombatLockdown() then
        return
    end
    ClearOverrideBindings(view)
    if active and ns.Selling.AreShortcutsEnabled() then
        for key, button in pairs(SHORTCUTS) do
            SetOverrideBinding(view, false, key, "CLICK " .. button .. ":LeftButton")
        end
    end
end

ns.OnEvent("PLAYER_REGEN_ENABLED", ApplyShortcuts)
ns.Subscribe("SELL_SHORTCUTS_CHANGED", ApplyShortcuts)

-- Whether the view is on screen: it follows its data and holds the keys only then.
function UI.SetShoppingActive(isActive)
    if active == isActive then
        return
    end
    active = isActive
    if active then
        Refresh()
        if current then
            Select(current.key) -- Prices may have moved in the meantime.
        end
    else
        Shopping.CancelPurchase()
        Shopping.CancelSearch()
        state, armed = "idle", false
    end
    ApplyShortcuts()
end

-- Tooltips -----------------------------------------------------------------------------

local function ShowRecipeTooltip(owner, recipe)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(recipe.name)
    UI.AddMoneyLine(L["Cost per craft"], recipe.cost)
    UI.AddMoneyLine(L["Value after the cut"], recipe.value)
    if recipe.sold then
        UI.AddValueLine(GameTooltip, L["Sold in 14 days"], BreakUpLargeNumbers(recipe.sold))
        UI.AddValueLine(GameTooltip, L["Suggested crafts"], BreakUpLargeNumbers(recipe.suggested))
    end
    GameTooltip:Show()
end

local function ShowRowTooltip(owner, row)
    UI.ShowItemTooltip(owner, row.itemID, nil, row.name)
    GameTooltip:AddLine(" ")
    UI.AddValueLine(GameTooltip, L["Need"], BreakUpLargeNumbers(row.need))
    UI.AddValueLine(GameTooltip, L["Held"], BreakUpLargeNumbers(row.held))
    if row.produced > 0 then
        UI.AddValueLine(GameTooltip, L["Made by your recipes"], BreakUpLargeNumbers(row.produced))
    end
    if row.craftUnit then
        UI.AddMoneyLine(L["Craft cost per unit"], row.craftUnit)
        UI.AddMoneyLine(L["Unit price"], row.unit)
    end
    local names = {}
    for name in pairs(row.recipes) do
        table.insert(names, name)
    end
    table.sort(names)
    GameTooltip:AddLine(table.concat(names, ", "), 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end

-- View ---------------------------------------------------------------------------------

local function CreateButton(parent, name, text, width, height, onClick)
    local button = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
    button:SetSize(width, height)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

local function CreateBox(parent, width, onEdit)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, CONTROL_HEIGHT)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetScript("OnTextChanged", function(_, userInput)
        if userInput then
            onEdit()
        end
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    return box
end

local function ChangeCrafts(delta)
    if selectedRecipe then
        Shopping.SetCrafts(selectedRecipe.key, selectedRecipe.crafts + delta)
    end
end

local function BuildRecipes(left)
    local title = left:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", left, "TOPLEFT")
    title:SetText(L["Tracked recipes"])

    recipeTable = UI.CreateTable(left, {
        columns = {
            { key = "name", title = L["Recipe"], width = 134, ascendingFirst = true,
                sort = function(row) return row.name and row.name:lower() end,
                text = function(row) return row.name end },
            { key = "crafts", title = "×", width = 30, align = "RIGHT",
                text = function(row) return BreakUpLargeNumbers(row.crafts) end },
            { key = "margin", title = L["Margin"], width = 86, align = "RIGHT",
                text = function(row) return ns.FormatSignedMoney(row.margin) end,
                color = function(row) return UI.ColorForAmount(row.margin) end },
        },
        -- The most profitable first.
        sort = { key = "margin", ascending = false },
        onEnter = ShowRecipeTooltip,
        onClick = function(_, row)
            selectedRecipe = row
            recipeTable:ApplySort()
            UpdateRecipeControls()
        end,
        isSelected = function(row)
            return selectedRecipe ~= nil and row.key == selectedRecipe.key
        end,
    })
    recipeTable:SetPoint("TOPLEFT", left, "TOPLEFT", 0, -TITLE_HEIGHT)
    recipeTable:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", 0, STRIP_HEIGHT)
    recipeTable.Empty:SetText(L["Track a recipe to see it here."])

    local label = left:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    label:SetPoint("BOTTOMLEFT", left, "BOTTOMLEFT", 0, 40)
    label:SetWidth(LABEL_WIDTH)
    label:SetJustifyH("LEFT")
    label:SetText(L["Crafts"])

    local minus = CreateButton(left, nil, "-", STEP_BUTTON_WIDTH, CONTROL_HEIGHT, function()
        ChangeCrafts(-1)
    end)
    minus:SetPoint("BOTTOMLEFT", left, "BOTTOMLEFT", LABEL_WIDTH, 34)
    craftsBox = CreateBox(left, CRAFTS_WIDTH, function()
        if selectedRecipe then
            Shopping.SetCrafts(selectedRecipe.key, tonumber(craftsBox:GetText()) or 0)
        end
    end)
    craftsBox:SetPoint("LEFT", minus, "RIGHT", 8, 0)
    local plus = CreateButton(left, nil, "+", STEP_BUTTON_WIDTH, CONTROL_HEIGHT, function()
        ChangeCrafts(1)
    end)
    plus:SetPoint("LEFT", craftsBox, "RIGHT", 4, 0)

    local suggest = CreateButton(left, nil, L["Based on my sales"], LEFT_WIDTH, BUY_HEIGHT - 4, function()
        Shopping.ApplySalesSuggestions(recipes)
    end)
    suggest:SetPoint("BOTTOMLEFT", left, "BOTTOMLEFT")
end

local function BuildList(right)
    local title = right:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", right, "TOPLEFT")
    title:SetText(L["To buy"])
    totalText = right:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    totalText:SetPoint("TOPRIGHT", right, "TOPRIGHT")

    listTable = UI.CreateTable(right, {
        columns = {
            { key = "name", title = L["Item"], width = 160, item = true, ascendingFirst = true,
                sort = function(row) return row.name and row.name:lower() end },
            { key = "need", title = L["Need"], width = 44, align = "RIGHT",
                text = function(row) return BreakUpLargeNumbers(row.need) end },
            { key = "have", title = L["Held"], width = 48, align = "RIGHT",
                text = function(row) return BreakUpLargeNumbers(row.have) end },
            { key = "buy", title = L["Buy"], width = 52, align = "RIGHT",
                text = function(row) return ns.FormatCount(row.buy) end,
                color = function(row) return row.buy == 0 and Colors.muted or nil end },
            { key = "unit", title = L["Unit price"], width = 84, align = "RIGHT",
                text = function(row) return ns.FormatMoney(row.unit) end },
        },
        sort = { key = "name", ascending = true },
        onEnter = ShowRowTooltip,
        onClick = function(_, row)
            Select(row.key)
        end,
        isSelected = function(row)
            return current ~= nil and row.key == current.key
        end,
    })
    listTable:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -TITLE_HEIGHT)
    listTable:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 0, STRIP_HEIGHT)
    listTable.Empty:SetText(L["Nothing to buy."])

    goodButton = CreateButton(right, nil, "", GOOD_WIDTH, CONTROL_HEIGHT, function()
        local quote = CurrentQuote()
        quantityBox:SetText(tostring(quote.goodQuantity))
        armed = false
        UpdateDetail()
    end)
    goodButton:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 0, 38)

    infoText = right:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    infoText:SetPoint("BOTTOMLEFT", right, "BOTTOMLEFT", 0, 50)
    infoText:SetPoint("RIGHT", goodButton, "LEFT", -6, 0)
    infoText:SetJustifyH("LEFT")
    infoText:SetWordWrap(false)
    warningText = right:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    warningText:SetPoint("BOTTOMLEFT", right, "BOTTOMLEFT", 0, 34)
    warningText:SetPoint("RIGHT", goodButton, "LEFT", -6, 0)
    warningText:SetJustifyH("LEFT")
    warningText:SetTextColor(Colors.loss[1], Colors.loss[2], Colors.loss[3])

    local label = right:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    label:SetPoint("BOTTOMLEFT", right, "BOTTOMLEFT", 0, 7)
    label:SetWidth(LABEL_WIDTH)
    label:SetJustifyH("LEFT")
    label:SetText(L["Quantity"])
    quantityBox = CreateBox(right, QUANTITY_WIDTH, function()
        armed = false
        UpdateDetail()
    end)
    quantityBox:SetPoint("BOTTOMLEFT", right, "BOTTOMLEFT", LABEL_WIDTH + 6, 2)

    buyButton = CreateButton(right, BUY_BUTTON, L["Buy"], BUY_WIDTH, BUY_HEIGHT, Buy)
    buyButton:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT")
    nextButton = CreateButton(right, NEXT_BUTTON, L["Next"], STEP_WIDTH, CONTROL_HEIGHT, function()
        Step(1)
    end)
    nextButton:SetPoint("RIGHT", buyButton, "LEFT", -6, 0)
    previousButton = CreateButton(right, PREVIOUS_BUTTON, L["Previous"], STEP_WIDTH, CONTROL_HEIGHT, function()
        Step(-1)
    end)
    previousButton:SetPoint("RIGHT", nextButton, "LEFT", -6, 0)
end

function UI.CreateShoppingView(parent)
    view = CreateFrame("Frame", nil, parent)
    local left = CreateFrame("Frame", nil, view)
    left:SetPoint("TOPLEFT", view, "TOPLEFT")
    left:SetPoint("BOTTOMLEFT", view, "BOTTOMLEFT")
    left:SetWidth(LEFT_WIDTH)
    local right = CreateFrame("Frame", nil, view)
    right:SetPoint("TOPLEFT", view, "TOPLEFT", RIGHT_LEFT, 0)
    right:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT")
    BuildRecipes(left)
    BuildList(right)
    UpdateDetail()
    return view
end
