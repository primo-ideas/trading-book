local addonName, ns = ...
local L = ns.L
local UI = ns.UI

-- Trading Essentials's page in the game's options, under AddOns. Its controls read and write
-- the same saved values as the slash commands, so that both always agree.
--
-- The page is one frame of Trading Essentials's own (a canvas), with its own controls. The
-- game's settings objects and their list rows must not be used: the options panel
-- reads every registered setting when an action button is clicked, and reuses its
-- rows for the game's own options, so Trading Essentials's values would taint them and get
-- actions blocked, such as using an item or searching the key bindings.

-- The window's scale, in percent like the game's UI scale. The largest still fits the
-- window on a screen.
local SCALE_MIN, SCALE_MAX, SCALE_STEP = 50, 120, 5

-- Page, after the options panel's own layout: a title, a button, a divider, then
-- one row per setting, its label on the left half, its control from the middle.
local TITLE_LEFT, TITLE_TOP = 7, -22
local DEFAULTS_WIDTH, DEFAULTS_HEIGHT = 120, 22
local DEFAULTS_RIGHT, DEFAULTS_TOP = -16, -18
local DIVIDER_TOP = -50
local LIST_TOP = -58
local SCROLL_BAR_SPACE = 20
local ROW_HEIGHT = 34
local LABEL_LEFT = 24
local CHILD_INDENT = 16
local LABEL_GAP = 12
local CONTROL_OFFSET = -40 -- From the middle of the page.
local DROPDOWN_WIDTH = 220
-- The gold of GameFontNormal, and grey for a setting that cannot change for now.
local LABEL_COLOR = { 1, 0.82, 0 }
local DISABLED_COLOR = { 0.5, 0.5, 0.5 }
local SLIDER_WIDTH = 220
local SECTION_GAP = 12
local SECTION_HEIGHT = 30
local PAGE_BOTTOM = 24

-- The section where the player puts lists in an order of their own.
local ORDER_MARGIN = 16
local ORDER_INTRO_HEIGHT = 28
local ORDER_TITLE_HEIGHT = 22
local ORDER_ROW_HEIGHT = 24
local ORDER_ARROW_SIZE = 20
local ORDER_LIST_GAP = 18
local ORDER_COLUMN_GAP = 16
local ORDER_BUTTON_WIDTH, ORDER_BUTTON_HEIGHT = 170, 22
-- The sort arrow of the auction house points down; flipped, it points up.
local ARROW_ATLAS = "auctionhouse-ui-sortarrow"

local category = nil
local page, content = nil, nil
local controls = {}
local orderRefreshers = {}
-- Set while the controls show the saved values, whose changes then come from the
-- addon rather than from the player.
local refreshing = false

local function ScalePercent(scale)
    local percent = math.floor(scale * 100 / SCALE_STEP + 0.5) * SCALE_STEP
    return math.max(SCALE_MIN, math.min(SCALE_MAX, percent))
end

local function FormatPercent(value)
    return ("%d%%"):format(math.floor(value + 0.5))
end

local function GameScalePercent()
    return ScalePercent(UI.GetGameScale())
end

-- A list of { key, label } as choices.
local function KeyedChoices(list)
    return function()
        local choices = {}
        for _, option in ipairs(list) do
            table.insert(choices, { value = option.key, label = option.label })
        end
        return choices
    end
end

-- The settings, in the order of the page. kind: checkbox, dropdown or slider.
-- default: a value, or a function that returns it. parent: the setting that must be
-- on for this one to be usable.
local function DefineControls()
    local hourChoices = function()
        local choices = {}
        for _, hours in ipairs(ns.Selling.HOURS) do
            table.insert(choices, { value = hours, label = L["%d h"]:format(hours) })
        end
        return choices
    end
    local ownScale = {
        kind = "checkbox", name = L["Custom window scale"], default = false,
        tooltip = L["Replaces the game's UI scale for the window: it keeps its size when the game's scale changes."],
        -- A scale of its own starts from the game's, so that turning it on changes nothing yet.
        get = function() return UI.GetWindowScale() ~= nil end,
        set = function(value) UI.SetWindowScale(value and GameScalePercent() / 100 or nil) end,
    }
    return {
        { kind = "checkbox", name = L["Minimap icon"], default = true,
            tooltip = L["Shows Trading Essentials's icon on the edge of the minimap."],
            get = UI.IsMinimapButtonShown, set = UI.SetMinimapButtonShown },
        { kind = "checkbox", name = L["Item tooltips"], default = true,
            tooltip = L["Adds what the account holds of an item and what it sold for to the item's tooltip."],
            get = UI.IsItemTooltipShown, set = UI.SetItemTooltipShown },
        { kind = "checkbox", name = L["Mail summary"], default = true,
            tooltip = L["When you leave the mailbox, sums up in the chat the sales, purchases and expiries collected."],
            get = ns.Mail.IsSummaryEnabled, set = ns.Mail.SetSummaryEnabled },
        { kind = "dropdown", name = L["Sale duration"], default = ns.Selling.DEFAULT_HOURS, choices = hourChoices,
            tooltip = L["How long auctions last when quick selling from the Trading Essentials tab of the auction house."],
            get = ns.Selling.GetDefaultHours, set = ns.Selling.SetDefaultHours },
        { kind = "dropdown", name = L["Proposed price"], default = ns.Selling.PRICINGS[1].key,
            choices = KeyedChoices(ns.Selling.PRICINGS),
            tooltip = L["The price quick selling proposes, against the lowest one on sale."],
            get = ns.Selling.GetPricingKey, set = ns.Selling.SetPricingKey },
        { kind = "checkbox", name = L["Next item after posting"], default = true,
            tooltip = L["Moves on to the next item of the list once an item is posted."],
            get = ns.Selling.IsAutoNextEnabled, set = ns.Selling.SetAutoNextEnabled },
        { kind = "checkbox", name = L["Trading Essentials tab keys"], default = true,
            tooltip = L["In the Trading Essentials tab of the auction house, Space posts or buys, Shift-Space goes to the next item and Backspace to the previous one."],
            get = ns.Selling.AreShortcutsEnabled, set = ns.Selling.SetShortcutsEnabled },
        { kind = "dropdown", name = L["Stock counted for purchases"], default = ns.Shopping.STOCK_SCOPES[1].key,
            choices = KeyedChoices(ns.Shopping.STOCK_SCOPES),
            tooltip = L["What is subtracted from the components to buy."],
            get = ns.Shopping.GetStockScopeKey, set = ns.Shopping.SetStockScopeKey },
        { kind = "dropdown", name = L["Component quality"], default = ns.Shopping.QUALITIES[1].key,
            choices = KeyedChoices(ns.Shopping.QUALITIES),
            tooltip = L["Which quality of a component the shopping list buys."],
            get = ns.Shopping.GetQualityKey, set = ns.Shopping.SetQualityKey },
        ownScale,
        -- While the window follows the game, the slider shows the game's scale, greyed out.
        { kind = "slider", name = L["Window scale"], default = GameScalePercent, parent = ownScale,
            tooltip = L["The window's size, in percent like the game's UI scale."],
            get = function() return ScalePercent(UI.GetWindowScale() or UI.GetGameScale()) end,
            set = function(value)
                if UI.GetWindowScale() then
                    UI.SetWindowScale(ScalePercent(value / 100) / 100)
                end
            end },
    }
end

local function DefaultOf(control)
    if type(control.default) == "function" then
        return control.default()
    end
    return control.default
end

-- Shows the saved values, and greys out what depends on a setting turned off.
local function RefreshControls()
    if not page then
        return
    end
    refreshing = true
    for _, control in ipairs(controls) do
        local value = control.get()
        local enabled = control.parent == nil or control.parent.get()
        if control.kind == "checkbox" then
            control.widget:SetChecked(value)
        elseif control.kind == "dropdown" then
            control.widget:GenerateMenu()
        else
            control.widget:SetValue(value)
            control.widget:SetEnabled(enabled)
        end
        if enabled then
            control.label:SetTextColor(LABEL_COLOR[1], LABEL_COLOR[2], LABEL_COLOR[3])
        else
            control.label:SetTextColor(DISABLED_COLOR[1], DISABLED_COLOR[2], DISABLED_COLOR[3])
        end
    end
    refreshing = false
end

local function Change(control, value)
    if refreshing or control.get() == value then
        return
    end
    control.set(value)
    RefreshControls()
end

-- Every setting back to its default, the order of the lists too: the page's Defaults
-- button, and the options panel's own when it resets everything.
local function RestoreDefaults()
    for _, control in ipairs(controls) do
        local value = DefaultOf(control)
        if control.get() ~= value then
            control.set(value)
        end
    end
    if ns.db.ui.order ~= nil then
        UI.ResetOrders()
    end
    RefreshControls()
end

-- Controls ------------------------------------------------------------------------

local function ShowRowTooltip(row)
    GameTooltip:SetOwner(row, "ANCHOR_TOPLEFT")
    GameTooltip:SetText(row.control.name, 1, 1, 1)
    GameTooltip:AddLine(row.control.tooltip, nil, nil, nil, true)
    GameTooltip:Show()
end

local function CreateCheckbox(row, control)
    local box = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    box:SetPoint("LEFT", row, "CENTER", CONTROL_OFFSET, 0)
    box:SetScript("OnClick", function(self)
        Change(control, self:GetChecked() and true or false)
    end)
    return box
end

local function CreateDropdown(row, control)
    local dropdown = CreateFrame("DropdownButton", nil, row, "WowStyle1DropdownTemplate")
    dropdown:SetPoint("LEFT", row, "CENTER", CONTROL_OFFSET, 0)
    dropdown:SetWidth(DROPDOWN_WIDTH)
    local function IsSelected(value)
        return control.get() == value
    end
    local function Select(value)
        Change(control, value)
    end
    dropdown:SetupMenu(function(_, rootDescription)
        for _, choice in ipairs(control.choices()) do
            rootDescription:CreateRadio(choice.label, IsSelected, Select, choice.value)
        end
    end)
    return dropdown
end

local function CreateSlider(row, control)
    local slider = CreateFrame("Frame", nil, row, "MinimalSliderWithSteppersTemplate")
    slider:SetPoint("LEFT", row, "CENTER", CONTROL_OFFSET, 0)
    slider:SetWidth(SLIDER_WIDTH)
    slider:Init(control.get(), SCALE_MIN, SCALE_MAX, (SCALE_MAX - SCALE_MIN) / SCALE_STEP,
        { [MinimalSliderWithSteppersMixin.Label.Right] = FormatPercent })
    slider:RegisterCallback(MinimalSliderWithSteppersMixin.Event.OnValueChanged, function(_, value)
        Change(control, ScalePercent(value / 100))
    end, row)
    return slider
end

local CREATORS = { checkbox = CreateCheckbox, dropdown = CreateDropdown, slider = CreateSlider }

local function CreateRow(parent, control, top)
    local row = CreateFrame("Frame", nil, parent)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, top)
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, top)
    row:SetHeight(ROW_HEIGHT)
    row.control = control
    -- Hovering explains the setting, without catching the clicks.
    row:SetMouseMotionEnabled(true)
    row:SetScript("OnEnter", ShowRowTooltip)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    local indent = control.parent and CHILD_INDENT or 0
    local label = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("LEFT", row, "LEFT", LABEL_LEFT + indent, 0)
    label:SetPoint("RIGHT", row, "CENTER", CONTROL_OFFSET - LABEL_GAP, 0)
    label:SetJustifyH("LEFT")
    label:SetMaxLines(2)
    label:SetText(control.name)
    control.label = label
    control.widget = CREATORS[control.kind](row, control)
    return row
end

-- Order section -------------------------------------------------------------------

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

-- The order lists, from top down to the page. Returns how tall they are.
local function BuildOrderSection(parent, top)
    local intro = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", parent, "TOPLEFT", ORDER_MARGIN, top)
    intro:SetPoint("RIGHT", parent, "RIGHT", -ORDER_MARGIN, 0)
    intro:SetHeight(ORDER_INTRO_HEIGHT)
    intro:SetJustifyH("LEFT")
    intro:SetJustifyV("TOP")
    intro:SetText(L["Put the window's tabs, the blocks of item tooltips and the Stats tiles in the order you like."])

    local leftLists, rightLists, columnsHeight = SplitLists()
    local columnsTop = top - ORDER_INTRO_HEIGHT - ORDER_LIST_GAP
    local left = CreateFrame("Frame", nil, parent)
    left:SetPoint("TOPLEFT", parent, "TOPLEFT", ORDER_MARGIN, columnsTop)
    left:SetPoint("RIGHT", parent, "CENTER", -ORDER_COLUMN_GAP / 2, 0)
    left:SetHeight(columnsHeight)
    local right = CreateFrame("Frame", nil, parent)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", ORDER_COLUMN_GAP, 0)
    right:SetPoint("RIGHT", parent, "RIGHT", -ORDER_MARGIN, 0)
    right:SetHeight(columnsHeight)

    for _, column in ipairs({ { frame = left, lists = leftLists }, { frame = right, lists = rightLists } }) do
        local height = 0
        for _, list in ipairs(column.lists) do
            local box = CreateOrderList(parent, list)
            box:SetPoint("TOPLEFT", column.frame, "TOPLEFT", 0, -height)
            box:SetPoint("TOPRIGHT", column.frame, "TOPRIGHT", 0, -height)
            height = height + box:GetHeight() + ORDER_LIST_GAP
        end
    end

    local reset = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    reset:SetSize(ORDER_BUTTON_WIDTH, ORDER_BUTTON_HEIGHT)
    reset:SetPoint("TOPLEFT", left, "BOTTOMLEFT", 0, 0)
    reset:SetText(L["Default order"])
    reset:SetScript("OnClick", UI.ResetOrders)
    table.insert(orderRefreshers, function()
        reset:SetEnabled(ns.db.ui.order ~= nil)
    end)
    return ORDER_INTRO_HEIGHT + ORDER_LIST_GAP + columnsHeight + ORDER_BUTTON_HEIGHT
end

-- Page ----------------------------------------------------------------------------

local function CreateSectionHeader(parent, text, top)
    local header = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", ORDER_MARGIN, top - SECTION_GAP)
    header:SetText(text)
    return SECTION_GAP + SECTION_HEIGHT
end

-- The scroll child needs a width of its own: the page's, once the panel has sized it.
local function FitContent(scroll)
    local width = scroll:GetWidth()
    if width and width > 0 then
        content:SetWidth(width)
    end
end

local function CreatePage()
    page = CreateFrame("Frame")
    page:Hide()

    local title = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightHuge")
    title:SetPoint("TOPLEFT", page, "TOPLEFT", TITLE_LEFT, TITLE_TOP)
    title:SetText("Trading Essentials")

    local defaults = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    defaults:SetSize(DEFAULTS_WIDTH, DEFAULTS_HEIGHT)
    defaults:SetPoint("TOPRIGHT", page, "TOPRIGHT", DEFAULTS_RIGHT, DEFAULTS_TOP)
    defaults:SetText(DEFAULTS) -- The game's own word, translated.
    defaults:SetScript("OnClick", RestoreDefaults)

    local divider = page:CreateTexture(nil, "ARTWORK")
    divider:SetAtlas("Options_HorizontalDivider", true)
    divider:SetPoint("TOP", page, "TOP", 0, DIVIDER_TOP)

    local scroll = CreateFrame("ScrollFrame", nil, page, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", page, "TOPLEFT", 0, LIST_TOP)
    scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -SCROLL_BAR_SPACE, 0)
    content = CreateFrame("Frame", nil, scroll)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", FitContent)

    controls = DefineControls()
    local top = 0
    for _, control in ipairs(controls) do
        CreateRow(content, control, -top)
        top = top + ROW_HEIGHT
    end
    top = top + CreateSectionHeader(content, L["Order"], -top)
    top = top + BuildOrderSection(content, -top)
    content:SetHeight(top + PAGE_BOTTOM)

    page:SetScript("OnShow", function()
        FitContent(scroll)
        RefreshControls()
        RefreshOrderPage()
    end)
    -- Called by the options panel: when it shows the page, and when it resets everything.
    page.OnRefresh = function()
        RefreshControls()
        RefreshOrderPage()
    end
    page.OnDefault = RestoreDefaults
end

ns.Subscribe("ORDER_CHANGED", RefreshOrderPage)

-- Shows a change made elsewhere, such as by a slash command, if the page is open.
function UI.RefreshSettings()
    RefreshControls()
end

function UI.OpenSettings()
    Settings.OpenToCategory(category:GetID())
end

ns.OnEvent("ADDON_LOADED", function(name)
    if name == addonName then
        CreatePage()
        category = Settings.RegisterCanvasLayoutCategory(page, "Trading Essentials")
        Settings.RegisterAddOnCategory(category)
    end
end)
