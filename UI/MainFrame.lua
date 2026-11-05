local _, ns = ...
local L = ns.L
local UI = ns.UI

local WIDTH, HEIGHT = 960, 640
-- Where ButtonFrameTemplate places its Inset once the button bar is hidden.
local INSET_LEFT, INSET_RIGHT, INSET_TOP, INSET_BOTTOM = 4, 6, 60, 4
-- The portrait covers the top left corner of the window.
local TOOLBAR_LEFT = 66
local TOOLBAR_TOP = -30
local WINDOW_MARGIN = 14
local DROPDOWN_WIDTH = 170
local ICON = "Interface\\Icons\\INV_Misc_Coin_01"
local REFRESH_DELAY_SECONDS = 0.2
local ALL_CHARACTERS = ""

UI.CONTENT_WIDTH = WIDTH - INSET_LEFT - INSET_RIGHT - 2 * UI.PADDING
UI.CONTENT_HEIGHT = HEIGHT - INSET_TOP - INSET_BOTTOM - 2 * UI.PADDING

-- Tabs register themselves when their file loads; panes are only built on first show.
local tabs = {}
local frame = nil
local selectedTab = 1
local selectedCharacter = nil

-- tab: { key, title, Build = fn(pane, toolbar), Refresh = fn() }
function UI.RegisterTab(tab)
    table.insert(tabs, tab)
end

function UI.GetCharacterFilter()
    return selectedCharacter
end

local function RefreshSelected()
    if frame and frame:IsShown() then
        tabs[selectedTab].Refresh()
    end
end

local function SelectTab(index)
    selectedTab = index
    PanelTemplates_SetTab(frame, index)
    for i, tab in ipairs(tabs) do
        local selected = i == index
        if selected and not tab.built then
            tab.Build(tab.pane, tab.toolbar)
            tab.built = true
        end
        tab.pane:SetShown(selected)
        tab.toolbar:SetShown(selected)
    end
    RefreshSelected()
end

local function SavePosition()
    local point, _, relativePoint, x, y = frame:GetPoint()
    ns.db.ui.position = { point = point, relativePoint = relativePoint, x = x, y = y }
end

local function RestorePosition()
    local position = ns.db.ui.position
    frame:ClearAllPoints()
    if position then
        frame:SetPoint(position.point, UIParent, position.relativePoint, position.x, position.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER")
    end
end

-- The current character first, then the others by name.
local function SortedCharacters()
    local keys = {}
    for key in pairs(ns.db.characters) do
        if key ~= ns.playerKey then
            table.insert(keys, key)
        end
    end
    table.sort(keys)
    table.insert(keys, 1, ns.playerKey)
    return keys
end

local function CreateCharacterDropdown()
    local dropdown = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
    dropdown:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -WINDOW_MARGIN, TOOLBAR_TOP)
    dropdown:SetWidth(DROPDOWN_WIDTH)

    local function IsSelected(key)
        return key == (selectedCharacter or ALL_CHARACTERS)
    end
    local function Select(key)
        selectedCharacter = key ~= ALL_CHARACTERS and key or nil
        RefreshSelected()
    end
    dropdown:SetupMenu(function(_, rootDescription)
        rootDescription:CreateRadio(L["Whole account"], IsSelected, Select, ALL_CHARACTERS)
        for _, key in ipairs(SortedCharacters()) do
            rootDescription:CreateRadio(ns.ColoredCharacterName(key), IsSelected, Select, key)
        end
    end)
end

local function CreateMainFrame()
    frame = CreateFrame("Frame", "TradingBookMainFrame", UIParent, "ButtonFrameTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetTitle("Trading Book")
    frame:SetPortraitToAsset(ICON)
    ButtonFrameTemplate_HideButtonBar(frame)

    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    RestorePosition()
    table.insert(UISpecialFrames, "TradingBookMainFrame")
    CreateCharacterDropdown()

    local previous
    for index, tab in ipairs(tabs) do
        local button = CreateFrame("Button", "TradingBookMainFrameTab" .. index, frame, "PanelTabButtonTemplate")
        button:SetID(index)
        button:SetText(tab.title)
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 3, 0)
        else
            button:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 11, 2)
        end
        button:SetScript("OnClick", function()
            SelectTab(index)
        end)
        previous = button

        tab.toolbar = CreateFrame("Frame", nil, frame)
        tab.toolbar:SetPoint("TOPLEFT", frame, "TOPLEFT", TOOLBAR_LEFT, TOOLBAR_TOP)
        tab.toolbar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(WINDOW_MARGIN + DROPDOWN_WIDTH + UI.GAP), TOOLBAR_TOP)
        tab.toolbar:SetHeight(UI.CONTROL_HEIGHT)

        tab.pane = CreateFrame("Frame", nil, frame.Inset)
        tab.pane:SetPoint("TOPLEFT", frame.Inset, "TOPLEFT", UI.PADDING, -UI.PADDING)
        tab.pane:SetPoint("BOTTOMRIGHT", frame.Inset, "BOTTOMRIGHT", -UI.PADDING, UI.PADDING)
        tab.pane:Hide()
    end
    PanelTemplates_SetNumTabs(frame, #tabs)

    frame:SetScript("OnShow", RefreshSelected)
    SelectTab(selectedTab)
end

function UI.Toggle()
    if not frame then
        CreateMainFrame()
        return
    end
    frame:SetShown(not frame:IsShown())
end

function UI.Open(tabKey)
    for index, tab in ipairs(tabs) do
        if tab.key == tabKey then
            selectedTab = index
        end
    end
    if not frame then
        CreateMainFrame()
        return
    end
    -- In this order: showing refreshes the selected tab, which must be built by then.
    SelectTab(selectedTab)
    frame:Show()
end

local function RequestRefresh()
    if frame and frame:IsShown() then
        ns.Debounce("uiRefresh", REFRESH_DELAY_SECONDS, RefreshSelected)
    end
end

ns.Subscribe("LEDGER_CHANGED", RequestRefresh)
ns.Subscribe("AUCTIONS_CHANGED", RequestRefresh)
ns.Subscribe("STOCK_CHANGED", RequestRefresh)
