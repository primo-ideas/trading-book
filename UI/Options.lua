local addonName, ns = ...
local L = ns.L
local UI = ns.UI

-- Trading Book's page in the game's options, under AddOns. Its settings read and write
-- the same saved values as the slash commands, so that both always agree.

-- The window's scale, in percent like the game's UI scale. The largest still fits the
-- window on a screen.
local SCALE_MIN, SCALE_MAX, SCALE_STEP = 50, 120, 5

-- The section where the player puts lists in an order of their own.
local ORDER_TEMPLATE = "TradingBookOrderSettingTemplate"
local ORDER_MARGIN = 16
local ORDER_INTRO_HEIGHT = 28
local ORDER_TITLE_HEIGHT = 22
local ORDER_ROW_HEIGHT = 24
local ORDER_ARROW_SIZE = 20
local ORDER_LIST_GAP = 18
local ORDER_COLUMN_GAP = 24
local ORDER_BUTTON_WIDTH, ORDER_BUTTON_HEIGHT = 170, 22
-- The sort arrow of the auction house points down; flipped, it points up.
local ARROW_ATLAS = "auctionhouse-ui-sortarrow"

local category = nil
local AddOrderSection
local settings = {}
local orderRefreshers = {}

local function ScalePercent(scale)
    local percent = math.floor(scale * 100 / SCALE_STEP + 0.5) * SCALE_STEP
    return math.max(SCALE_MIN, math.min(SCALE_MAX, percent))
end

local function FormatPercent(value)
    return ("%d%%"):format(math.floor(value + 0.5))
end

-- defaultValue: a value, or a function that returns it.
local function AddSetting(key, name, valueType, defaultValue, getValue, setValue)
    local setting = Settings.RegisterProxySetting(category, addonName .. "_" .. key, valueType, name,
        defaultValue, getValue, setValue)
    table.insert(settings, setting)
    return setting
end

-- Dropdown choices from a list of { key, label }.
local function KeyedOptions(list)
    return function()
        local container = Settings.CreateControlTextContainer()
        for _, option in ipairs(list) do
            container:Add(option.key, option.label)
        end
        return container:GetData()
    end
end

local function GameScalePercent()
    return ScalePercent(UI.GetGameScale())
end

local function RegisterSettings()
    local layout
    category, layout = Settings.RegisterVerticalLayoutCategory("Trading Book")

    local minimap = AddSetting("MinimapIcon", L["Minimap icon"], Settings.VarType.Boolean, true,
        UI.IsMinimapButtonShown, UI.SetMinimapButtonShown)
    Settings.CreateCheckbox(category, minimap, L["Shows Trading Book's icon on the edge of the minimap."])

    local tooltip = AddSetting("ItemTooltip", L["Item tooltips"], Settings.VarType.Boolean, true,
        UI.IsItemTooltipShown, UI.SetItemTooltipShown)
    Settings.CreateCheckbox(category, tooltip,
        L["Adds what the account holds of an item and what it sold for to the item's tooltip."])

    local mailSummary = AddSetting("MailSummary", L["Mail summary"], Settings.VarType.Boolean, true,
        ns.Mail.IsSummaryEnabled, ns.Mail.SetSummaryEnabled)
    Settings.CreateCheckbox(category, mailSummary,
        L["When you leave the mailbox, sums up in the chat the sales, purchases and expiries collected."])

    local sellHours = AddSetting("SellHours", L["Sale duration"], Settings.VarType.Number, ns.Selling.DEFAULT_HOURS,
        ns.Selling.GetDefaultHours, ns.Selling.SetDefaultHours)
    Settings.CreateDropdown(category, sellHours, function()
        local container = Settings.CreateControlTextContainer()
        for _, hours in ipairs(ns.Selling.HOURS) do
            container:Add(hours, L["%d h"]:format(hours))
        end
        return container:GetData()
    end, L["How long auctions last when quick selling from the Trading Book tab of the auction house."])

    local sellPricing = AddSetting("SellPricing", L["Proposed price"], Settings.VarType.String, ns.Selling.PRICINGS[1].key,
        ns.Selling.GetPricingKey, ns.Selling.SetPricingKey)
    Settings.CreateDropdown(category, sellPricing, KeyedOptions(ns.Selling.PRICINGS),
        L["The price quick selling proposes, against the lowest one on sale."])

    local sellNext = AddSetting("SellAutoNext", L["Next item after posting"], Settings.VarType.Boolean, true,
        ns.Selling.IsAutoNextEnabled, ns.Selling.SetAutoNextEnabled)
    Settings.CreateCheckbox(category, sellNext, L["Moves on to the next item of the list once an item is posted."])

    local sellKeys = AddSetting("SellShortcuts", L["Trading Book tab keys"], Settings.VarType.Boolean, true,
        ns.Selling.AreShortcutsEnabled, ns.Selling.SetShortcutsEnabled)
    Settings.CreateCheckbox(category, sellKeys,
        L["In the Trading Book tab of the auction house, Space posts or buys, Shift-Space goes to the next item and Backspace to the previous one."])

    local stockScope = AddSetting("ShoppingStock", L["Stock counted for purchases"], Settings.VarType.String,
        ns.Shopping.STOCK_SCOPES[1].key, ns.Shopping.GetStockScopeKey, ns.Shopping.SetStockScopeKey)
    Settings.CreateDropdown(category, stockScope, KeyedOptions(ns.Shopping.STOCK_SCOPES),
        L["What is subtracted from the components to buy."])

    local quality = AddSetting("ShoppingQuality", L["Component quality"], Settings.VarType.String,
        ns.Shopping.QUALITIES[1].key, ns.Shopping.GetQualityKey, ns.Shopping.SetQualityKey)
    Settings.CreateDropdown(category, quality, KeyedOptions(ns.Shopping.QUALITIES),
        L["Which quality of a component the shopping list buys."])

    -- A scale of its own starts from the game's, so that turning it on changes nothing yet.
    local ownScale = AddSetting("OwnScale", L["Custom window scale"], Settings.VarType.Boolean, false,
        function()
            return UI.GetWindowScale() ~= nil
        end,
        function(value)
            UI.SetWindowScale(value and GameScalePercent() / 100 or nil)
        end)
    local ownScaleControl = Settings.CreateCheckbox(category, ownScale,
        L["Replaces the game's UI scale for the window: it keeps its size when the game's scale changes."])

    -- While the window follows the game, the slider shows the game's scale and changes
    -- nothing: restoring the defaults, which sets it too, must not give the window a
    -- scale of its own again.
    local scale = AddSetting("Scale", L["Window scale"], Settings.VarType.Number, GameScalePercent,
        function()
            return ScalePercent(UI.GetWindowScale() or UI.GetGameScale())
        end,
        function(value)
            if UI.GetWindowScale() then
                UI.SetWindowScale(value / 100)
            end
        end)
    local options = Settings.CreateSliderOptions(SCALE_MIN, SCALE_MAX, SCALE_STEP)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, FormatPercent)
    local scaleControl = Settings.CreateSlider(category, scale, options,
        L["The window's size, in percent like the game's UI scale."])
    scaleControl:SetParentInitializer(ownScaleControl, function()
        return ownScale:GetValue()
    end)

    AddOrderSection(layout)
    Settings.RegisterAddOnCategory(category)
end

-- Order section ------------------------------------------------------------------

local function CreateArrow(parent, up, tooltip, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(ORDER_ARROW_SIZE, ORDER_ARROW_SIZE)
    button.Icon = button:CreateTexture(nil, "ARTWORK")
    button.Icon:SetAtlas(ARROW_ATLAS, true)
    button.Icon:SetPoint("CENTER", button, "CENTER")
    if up then
        button.Icon:SetTexCoord(0, 1, 1, 0)
    end
    local hover = button:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(1, 1, 1, 0.12)
    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(tooltip)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    return button
end

local function SetArrowEnabled(button, enabled)
    button:SetEnabled(enabled)
    button.Icon:SetAlpha(enabled and 1 or 0.25)
end

-- A list's title, then one row per item, with buttons to move it up or down.
local function CreateOrderList(parent, list)
    local box = CreateFrame("Frame", nil, parent)
    box:SetHeight(ORDER_TITLE_HEIGHT + #list.items * ORDER_ROW_HEIGHT)
    box.Title = box:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    box.Title:SetPoint("TOPLEFT", box, "TOPLEFT")
    box.Title:SetText(list.title)

    local rows = {}
    for index = 1, #list.items do
        local row = CreateFrame("Frame", nil, box)
        local top = -ORDER_TITLE_HEIGHT - (index - 1) * ORDER_ROW_HEIGHT
        row:SetPoint("TOPLEFT", box, "TOPLEFT", 0, top)
        row:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, top)
        row:SetHeight(ORDER_ROW_HEIGHT)
        if index % 2 == 0 then
            local stripe = row:CreateTexture(nil, "BACKGROUND")
            stripe:SetAllPoints()
            stripe:SetColorTexture(1, 1, 1, 0.04)
        end
        row.Down = CreateArrow(row, false, L["Move down"], function()
            UI.MoveInOrder(list.kind, row.key, 1)
        end)
        row.Down:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        row.Up = CreateArrow(row, true, L["Move up"], function()
            UI.MoveInOrder(list.kind, row.key, -1)
        end)
        row.Up:SetPoint("RIGHT", row.Down, "LEFT", -2, 0)
        row.Label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        row.Label:SetPoint("LEFT", row, "LEFT", 6, 0)
        row.Label:SetPoint("RIGHT", row.Up, "LEFT", -6, 0)
        row.Label:SetJustifyH("LEFT")
        row.Label:SetWordWrap(false)
        rows[index] = row
    end

    table.insert(orderRefreshers, function()
        local keys = UI.GetOrder(list.kind)
        for index, row in ipairs(rows) do
            row.key = keys[index]
            row.Label:SetText(UI.GetOrderLabel(list.kind, row.key))
            SetArrowEnabled(row.Up, index > 1)
            SetArrowEnabled(row.Down, index < #keys)
        end
    end)
    return box
end

local function RefreshOrderPage()
    for _, refresh in ipairs(orderRefreshers) do
        refresh()
    end
end

-- The lists split in two columns: the longest on the right, the others on the left, one
-- under the other. Returns the lists of each column and the height of the taller one.
local function SplitLists()
    local lists = UI.GetOrderLists()
    local longest = lists[1]
    for _, list in ipairs(lists) do
        if #list.items > #longest.items then
            longest = list
        end
    end
    local left, right = {}, { longest }
    local leftHeight = 0
    for _, list in ipairs(lists) do
        if list ~= longest then
            table.insert(left, list)
            leftHeight = leftHeight + ORDER_TITLE_HEIGHT + #list.items * ORDER_ROW_HEIGHT + ORDER_LIST_GAP
        end
    end
    local rightHeight = ORDER_TITLE_HEIGHT + #longest.items * ORDER_ROW_HEIGHT + ORDER_LIST_GAP
    return left, right, math.max(leftHeight, rightHeight)
end

local function OrderHeight()
    local _, _, columnsHeight = SplitLists()
    return ORDER_INTRO_HEIGHT + ORDER_LIST_GAP + columnsHeight + ORDER_BUTTON_HEIGHT + ORDER_MARGIN
end

-- Fills the row of the options list that holds the order lists.
local function BuildOrderSection(row)
    local content = CreateFrame("Frame", nil, row)
    content:SetAllPoints()
    -- Above the row's own label area, which would catch the clicks on the arrows.
    content:SetFrameLevel(row:GetFrameLevel() + 5)

    local intro = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", content, "TOPLEFT", ORDER_MARGIN, 0)
    intro:SetPoint("RIGHT", content, "RIGHT", -ORDER_MARGIN, 0)
    intro:SetHeight(ORDER_INTRO_HEIGHT)
    intro:SetJustifyH("LEFT")
    intro:SetJustifyV("TOP")
    intro:SetText(L["Put the window's tabs, the blocks of item tooltips and the Stats tiles in the order you like."])

    local leftLists, rightLists, columnsHeight = SplitLists()
    local top = -ORDER_INTRO_HEIGHT - ORDER_LIST_GAP
    local left = CreateFrame("Frame", nil, content)
    left:SetPoint("TOPLEFT", content, "TOPLEFT", ORDER_MARGIN, top)
    left:SetPoint("RIGHT", content, "CENTER", -ORDER_COLUMN_GAP / 2, 0)
    left:SetHeight(columnsHeight)
    local right = CreateFrame("Frame", nil, content)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", ORDER_COLUMN_GAP, 0)
    right:SetPoint("RIGHT", content, "RIGHT", -ORDER_MARGIN, 0)
    right:SetHeight(columnsHeight)

    for _, column in ipairs({ { frame = left, lists = leftLists }, { frame = right, lists = rightLists } }) do
        local height = 0
        for _, list in ipairs(column.lists) do
            local box = CreateOrderList(content, list)
            box:SetPoint("TOPLEFT", column.frame, "TOPLEFT", 0, -height)
            box:SetPoint("TOPRIGHT", column.frame, "TOPRIGHT", 0, -height)
            height = height + box:GetHeight() + ORDER_LIST_GAP
        end
    end

    local reset = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    reset:SetSize(ORDER_BUTTON_WIDTH, ORDER_BUTTON_HEIGHT)
    reset:SetPoint("TOPLEFT", left, "BOTTOMLEFT", 0, 0)
    reset:SetText(L["Default order"])
    reset:SetScript("OnClick", UI.ResetOrders)
    table.insert(orderRefreshers, function()
        reset:SetEnabled(ns.db.ui.order ~= nil)
    end)
    content:SetScript("OnShow", RefreshOrderPage)
    return content
end

-- The order lists end Trading Book's page, under a header of their own, in one row of
-- the options list. That row comes from a template only Trading Book uses
-- (UI/OrderSetting.xml), so the list never hands it to another setting.
-- The rows already filled with the section, which the list shows again as it scrolls.
local builtRows = {}

AddOrderSection = function(layout)
    -- Its value only says whether an order of one's own is kept: the panel's Defaults
    -- button sets it back, which restores the default order.
    local setting = AddSetting("Order", L["Order"], Settings.VarType.Boolean, false,
        function()
            return ns.db.ui.order ~= nil
        end,
        function(value)
            if not value then
                UI.ResetOrders()
            end
        end)
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L["Order"]))
    local initializer = Settings.CreateElementInitializer(ORDER_TEMPLATE, { name = "", setting = setting })
    local baseInit = initializer.InitFrame
    function initializer:GetExtent()
        return OrderHeight()
    end
    function initializer:InitFrame(row)
        baseInit(self, row)
        -- The row's label and its tooltip area stay empty.
        if row.Tooltip then
            row.Tooltip:Hide()
        end
        if not builtRows[row] then
            builtRows[row] = BuildOrderSection(row)
        end
        RefreshOrderPage()
    end
    layout:AddInitializer(initializer)
end

ns.Subscribe("ORDER_CHANGED", RefreshOrderPage)

-- Shows a change made elsewhere, such as by a slash command, if the page is open.
function UI.RefreshSettings()
    for _, setting in ipairs(settings) do
        setting:NotifyUpdate()
    end
end

function UI.OpenSettings()
    Settings.OpenToCategory(category:GetID())
end

ns.OnEvent("ADDON_LOADED", function(name)
    if name == addonName then
        RegisterSettings()
    end
end)
