local _, ns = ...
local L = ns.L
local UI = ns.UI
local Selling = ns.Selling
local Colors = UI.Colors

-- Quick selling in the Trading Book tab of the auction house: the bags on the left,
-- the item being listed on the right. Choosing an item asks the auction house for its
-- lowest price, proposes one from it, and posting moves on to the next item.

local LIST_WIDTH = 372
local CARD_LEFT = LIST_WIDTH + 12
local CARD_PADDING = 14
local ICON_SIZE = 36
local LABEL_WIDTH = 160
local FIRST_ROW_TOP = -64
local ROW_STEP = 30
local BOX_HEIGHT = 22
local QUANTITY_WIDTH, MAX_WIDTH, PRICE_WIDTH = 70, 60, 120
local POST_WIDTH, POST_HEIGHT = 150, 26
local STEP_WIDTH, STEP_HEIGHT = 100, 22
local REFRESH_DELAY_SECONDS = 0.2

local POST_BUTTON, NEXT_BUTTON, PREVIOUS_BUTTON =
    "TradingBookQuickSellPost", "TradingBookQuickSellNext", "TradingBookQuickSellPrevious"
local SHORTCUTS = {
    SPACE = POST_BUTTON,
    ["SHIFT-SPACE"] = NEXT_BUTTON,
    BACKSPACE = PREVIOUS_BUTTON,
}

local view, listTable = nil, nil
local content, emptyText, icon, nameText, quantityBox, maxButton, priceBox, lowestText = nil, nil, nil, nil, nil, nil, nil, nil
local durations, depositText, totalText, warningText, postButton, nextButton, previousButton = nil, nil, nil, nil, nil, nil, nil

local active = false
local items = {}
local current = nil
local hours = nil
local searching = false
local lowest, priceFloor = nil, nil
-- The player typed a price, which no answer of the auction house replaces.
local priceEdited = false
-- A price that deserves a second look was presented once.
local armed = false

-- Fields ------------------------------------------------------------------------------

-- As ParseMoney reads it, spaces aside.
local function ReadPrice()
    return ns.Watch.ParseMoney((priceBox:GetText():gsub("%s+", "")))
end

local function ReadQuantity()
    return tonumber(quantityBox:GetText())
end

local function PriceText(copper)
    local gold = math.floor(copper / 10000)
    local silver = math.floor(copper % 10000 / 100)
    return (gold > 0 and gold .. "g" or "") .. ((silver > 0 or gold == 0) and silver .. "s" or "")
end

local function FindItem(key)
    for _, item in ipairs(items) do
        if item.key == key then
            return item
        end
    end
end

-- The key of the item a number of rows from the current one, as the list shows them.
local function NeighbourKey(offset)
    if not current then
        return nil
    end
    for index, row in ipairs(listTable.rows) do
        if row.key == current.key then
            local neighbour = listTable.rows[index + offset]
            return neighbour and neighbour.key
        end
    end
end

local function CanPostNow()
    if not current or (searching and not priceEdited) then
        return false
    end
    return Selling.CanPost(current, ReadQuantity(), ReadPrice(), hours)
end

local function UpdateDetail()
    if not view then
        return
    end
    content:SetShown(current ~= nil)
    emptyText:SetShown(current == nil)
    if not current then
        return
    end
    if searching then
        lowestText:SetText(L["Searching..."])
    else
        lowestText:SetText(lowest and ns.FormatExactMoney(lowest) or L["None on sale"])
    end

    local quantity, unitPrice = ReadQuantity(), ReadPrice()
    local deposit = quantity and quantity > 0 and Selling.GetDeposit(current, quantity, hours) or nil
    depositText:SetText(ns.FormatExactMoney(deposit))
    totalText:SetText(ns.FormatExactMoney(quantity and unitPrice and quantity * unitPrice or nil))
    maxButton:SetEnabled(quantity ~= Selling.GetPostLimit(current))

    local warning = unitPrice and Selling.GetPriceWarning(current, unitPrice, priceFloor)
    warningText:SetText(warning and (armed and warning .. " " .. L["Press again to confirm."] or warning) or "")

    postButton:SetEnabled(CanPostNow())
    postButton:SetText(armed and L["Confirm"] or L["Post"])
    nextButton:SetEnabled(NeighbourKey(1) ~= nil)
    previousButton:SetEnabled(NeighbourKey(-1) ~= nil)
end

-- Choosing an item ---------------------------------------------------------------------

local function OnSearchResult(found, isOwnLowest, floor)
    searching = false
    lowest, priceFloor = found, floor
    if found and not priceEdited then
        priceBox:SetText(PriceText(Selling.ProposePrice(found, isOwnLowest)))
    end
    UpdateDetail()
end

local function Select(key)
    Selling.CancelSearch()
    current = key and FindItem(key) or nil
    searching, priceEdited, armed = false, false, false
    lowest, priceFloor = nil, nil
    if current then
        icon:SetTexture(current.icon)
        nameText:SetText(current.name)
        local color = current.quality and ITEM_QUALITY_COLORS[current.quality]
        if color then
            nameText:SetTextColor(color.r, color.g, color.b)
        end
        quantityBox:SetText(tostring(Selling.GetPostLimit(current)))
        hours = Selling.GetDefaultHours()
        durations.Select(hours)
        -- What is known until the auction house answers.
        local known = ns.Stats.GetUnitPrice(current.itemID)
        priceBox:SetText(known and PriceText(Selling.NormalizePrice(known)) or "")
        searching = true
        Selling.Search(current, OnSearchResult)
    end
    listTable:ApplySort()
    UpdateDetail()
end

local function Post()
    if not CanPostNow() then
        return
    end
    if not armed and Selling.GetPriceWarning(current, ReadPrice(), priceFloor) then
        armed = true
        UpdateDetail()
        return
    end
    Selling.Post(current, ReadQuantity(), ReadPrice(), hours)
    -- Worked out now: the item leaves the list once the server took it.
    Select(Selling.IsAutoNextEnabled() and NeighbourKey(1) or nil)
end

local function Step(offset)
    local key = NeighbourKey(offset)
    if key then
        Select(key)
    end
end

-- Bags ---------------------------------------------------------------------------------

local function RefreshList()
    if not view then
        return
    end
    items = Selling.GetBagItems()
    listTable:SetRows(items)
    if current then
        local fresh = FindItem(current.key)
        if not fresh then
            Select(nil)
            return
        end
        current = fresh
        local limit = Selling.GetPostLimit(current)
        if (ReadQuantity() or 0) > limit then
            quantityBox:SetText(tostring(limit))
        end
    end
    UpdateDetail()
end

local function RequestRefreshList()
    if active then
        ns.Debounce("quickSellBags", REFRESH_DELAY_SECONDS, RefreshList)
    end
end

ns.OnEvent("BAG_UPDATE_DELAYED", RequestRefreshList)
-- An item locks as it leaves for the auction house, and unlocks if the listing fails.
ns.OnEvent("ITEM_LOCK_CHANGED", RequestRefreshList)

ns.OnEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", UpdateDetail)
ns.OnEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_SENT", UpdateDetail)
ns.Subscribe("SELL_STATE_CHANGED", UpdateDetail)

-- Shortcuts ----------------------------------------------------------------------------

-- Key bindings cannot change in combat, so they wait for it to end.
local function ApplyShortcuts()
    if not view or InCombatLockdown() then
        return
    end
    ClearOverrideBindings(view)
    if active and Selling.AreShortcutsEnabled() then
        for key, button in pairs(SHORTCUTS) do
            SetOverrideBinding(view, false, key, "CLICK " .. button .. ":LeftButton")
        end
    end
end

ns.OnEvent("PLAYER_REGEN_ENABLED", ApplyShortcuts)
ns.Subscribe("SELL_SHORTCUTS_CHANGED", ApplyShortcuts)

-- Whether the view is on screen: it follows the bags and holds the keys only then.
function UI.SetQuickSellActive(isActive)
    if active == isActive then
        return
    end
    active = isActive
    if active then
        RefreshList()
        if current then
            Select(current.key) -- Prices may have moved in the meantime.
        end
    else
        Selling.CancelSearch()
        Selling.StopMultisell()
        searching = false
    end
    ApplyShortcuts()
end

-- View ---------------------------------------------------------------------------------

local function CreateLabel(rowTop, text)
    local label = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", content, "TOPLEFT", 0, rowTop - 5)
    label:SetWidth(LABEL_WIDTH)
    label:SetJustifyH("LEFT")
    label:SetText(text)
    return label
end

local function CreateValue(rowTop)
    local value = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    value:SetPoint("TOPLEFT", content, "TOPLEFT", LABEL_WIDTH, rowTop - 5)
    value:SetPoint("RIGHT", content, "RIGHT")
    value:SetJustifyH("LEFT")
    return value
end

local function CreateBox(rowTop, width, onEdit)
    local box = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    box:SetSize(width, BOX_HEIGHT)
    -- The template's border reaches a few pixels left of the box.
    box:SetPoint("TOPLEFT", content, "TOPLEFT", LABEL_WIDTH + 6, rowTop)
    box:SetAutoFocus(false)
    box:SetScript("OnTextChanged", function(_, userInput)
        if userInput then
            onEdit()
        end
    end)
    box:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        Post()
    end)
    box:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    return box
end

local function CreateButton(name, text, width, height, onClick)
    local button = CreateFrame("Button", name, content, "UIPanelButtonTemplate")
    button:SetSize(width, height)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

local function BuildCard(card)
    emptyText = card:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    emptyText:SetPoint("CENTER", card, "CENTER")
    emptyText:SetText(L["Choose an item to sell."])

    content = CreateFrame("Frame", nil, card)
    content:SetPoint("TOPLEFT", card, "TOPLEFT", CARD_PADDING, -CARD_PADDING)
    content:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -CARD_PADDING, CARD_PADDING)

    icon = content:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("TOPLEFT", content, "TOPLEFT")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    nameText = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    nameText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    nameText:SetPoint("RIGHT", content, "RIGHT")
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)

    local rowTop = FIRST_ROW_TOP
    CreateLabel(rowTop, L["Quantity"])
    quantityBox = CreateBox(rowTop, QUANTITY_WIDTH, function()
        armed = false
        UpdateDetail()
    end)
    quantityBox:SetNumeric(true)
    maxButton = CreateButton(nil, L["Max"], MAX_WIDTH, BOX_HEIGHT, function()
        quantityBox:SetText(tostring(Selling.GetPostLimit(current)))
        UpdateDetail()
    end)
    maxButton:SetPoint("LEFT", quantityBox, "RIGHT", 6, 0)

    rowTop = rowTop - ROW_STEP
    CreateLabel(rowTop, L["Unit price"])
    priceBox = CreateBox(rowTop, PRICE_WIDTH, function()
        priceEdited, armed = true, false
        UpdateDetail()
    end)

    rowTop = rowTop - ROW_STEP
    CreateLabel(rowTop, L["Lowest on the AH"])
    lowestText = CreateValue(rowTop)

    rowTop = rowTop - ROW_STEP
    CreateLabel(rowTop, L["Duration"])
    local options = {}
    for index, value in ipairs(Selling.HOURS) do
        options[index] = { value = value, label = L["%d h"]:format(value) }
    end
    durations = UI.CreateSegments(content, options, Selling.GetDefaultHours(), function(value)
        hours = value
        UpdateDetail()
    end)
    durations:SetPoint("TOPLEFT", content, "TOPLEFT", LABEL_WIDTH, rowTop)

    rowTop = rowTop - ROW_STEP - 6
    CreateLabel(rowTop, L["Deposit"])
    depositText = CreateValue(rowTop)

    rowTop = rowTop - ROW_STEP + 6
    CreateLabel(rowTop, L["Total"])
    totalText = CreateValue(rowTop)

    rowTop = rowTop - ROW_STEP
    warningText = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    warningText:SetPoint("TOPLEFT", content, "TOPLEFT", 0, rowTop)
    warningText:SetPoint("RIGHT", content, "RIGHT")
    warningText:SetJustifyH("LEFT")
    warningText:SetTextColor(Colors.loss[1], Colors.loss[2], Colors.loss[3])

    postButton = CreateButton(POST_BUTTON, L["Post"], POST_WIDTH, POST_HEIGHT, Post)
    postButton:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT")
    previousButton = CreateButton(PREVIOUS_BUTTON, L["Previous"], STEP_WIDTH, STEP_HEIGHT, function()
        Step(-1)
    end)
    previousButton:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT")
    nextButton = CreateButton(NEXT_BUTTON, L["Next"], STEP_WIDTH, STEP_HEIGHT, function()
        Step(1)
    end)
    nextButton:SetPoint("LEFT", previousButton, "RIGHT", 6, 0)
end

function UI.CreateQuickSellView(parent)
    view = CreateFrame("Frame", nil, parent)

    listTable = UI.CreateTable(view, {
        columns = {
            { key = "name", title = L["Item"], width = 270, item = true, ascendingFirst = true,
                sort = function(row) return row.name and row.name:lower() end },
            { key = "qty", title = L["Qty"], width = 50, align = "RIGHT",
                text = function(row) return ns.FormatCount(row.qty) end },
        },
        sort = { key = "name", ascending = true },
        onEnter = function(owner, row)
            UI.ShowItemTooltip(owner, row.itemID, row.link, row.name)
            GameTooltip:Show()
        end,
        onClick = function(_, row)
            Select(row.key)
        end,
        isSelected = function(row)
            return current ~= nil and row.key == current.key
        end,
    })
    listTable:SetPoint("TOPLEFT", view, "TOPLEFT")
    listTable:SetPoint("BOTTOMLEFT", view, "BOTTOMLEFT")
    listTable:SetWidth(LIST_WIDTH)

    local card = UI.CreateCard(view)
    card:SetPoint("TOPLEFT", view, "TOPLEFT", CARD_LEFT, 0)
    card:SetPoint("BOTTOMRIGHT", view, "BOTTOMRIGHT")
    BuildCard(card)
    UpdateDetail()
    return view
end
