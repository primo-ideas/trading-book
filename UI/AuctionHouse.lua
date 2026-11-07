local _, ns = ...
local L = ns.L
local UI = ns.UI
local Colors = UI.Colors

-- A Trading Book tab in the auction house window: when the auction house was last
-- scanned, a button to scan it, the account's undercut auctions and the watched items.
--
-- The tab goes after the window's own, and after those of any addon that added its
-- tab first. Its panel covers the auction house's content rather than taking over
-- the auction house's display modes, which belong to the game.

-- Inside the auction house window, below its title bar.
local PANEL_LEFT, PANEL_TOP, PANEL_RIGHT, PANEL_BOTTOM = 4, -26, -4, 4
local PADDING = 12
local GAP = 10
local TITLE_HEIGHT = 20
local STATUS_HEIGHT = 40
local SCAN_BUTTON_WIDTH, SCAN_BUTTON_HEIGHT = 220, 24
local STATUS_REFRESH_SECONDS = 1
-- Above the auction house's own content, which the panel hides.
local PANEL_LEVEL_OFFSET = 100

local tab, tabIndex, panel = nil, nil, nil
local lastScan, scanState, scanButton = nil, nil, nil
local undercutTable, watchTable = nil, nil

-- Scan status -------------------------------------------------------------------------

local function RefreshStatus()
    lastScan:SetText(L["Last scan: %s"]:format(ns.FormatDate(ns.Market.GetScannedAt())))
    local canScan = false
    if ns.Market.GetScanState() then
        scanState:SetText(L["Scanning the auction house..."])
    else
        local wait = ns.Market.NextScanAt() - time()
        if wait > 0 then
            scanState:SetText(L["Next scan in %s"]:format(ns.FormatDuration(wait)))
        else
            scanState:SetText(L["Ready to scan"])
            canScan = true
        end
    end
    scanButton:SetEnabled(canScan)
end

-- Lists -------------------------------------------------------------------------------

local function UndercutRows()
    local undercut = ns.Auctions.GetUndercut()
    local rows = {}
    for _, item in ipairs(ns.Auctions.GetAll()) do
        local lowest = undercut[item.auction]
        if lowest then
            local auction = item.auction
            table.insert(rows, {
                itemID = auction.itemID, link = auction.link, name = auction.name,
                qty = auction.qty, unit = auction.unit, lowest = lowest, char = item.char,
            })
        end
    end
    return rows
end

-- A target is reached when what is on sale now meets it, as the chat alerts say.
local function WatchRows()
    local rows = {}
    for _, watched in ipairs(ns.Watch.GetAll()) do
        local market = ns.Market.GetItem(watched.itemID)
        local price = market and market.quantity > 0 and market.price or nil
        table.insert(rows, {
            itemID = watched.itemID,
            link = watched.link,
            name = ns.GetItemDetails(watched.itemID),
            below = watched.below,
            above = watched.above,
            price = price,
            reached = price ~= nil and ((watched.below and price <= watched.below)
                or (watched.above and price >= watched.above)) or false,
        })
    end
    return rows
end

local function Refresh()
    if not (panel and panel:IsShown()) then
        return
    end
    RefreshStatus()
    undercutTable:SetRows(UndercutRows())
    watchTable:SetRows(WatchRows())
end

local function ShowUndercutTooltip(owner, row)
    UI.ShowItemTooltip(owner, row.itemID, row.link, row.name)
    GameTooltip:AddLine(" ")
    UI.AddMoneyLine(L["Unit price"], row.unit)
    UI.AddMoneyLine(L["Lowest on the AH"], row.lowest)
    UI.AddValueLine(GameTooltip, L["AH scan"], ns.FormatDate(ns.Market.GetScannedAt()))
    GameTooltip:Show()
end

local function ShowWatchTooltip(owner, row)
    UI.ShowItemTooltip(owner, row.itemID, row.link, row.name)
    GameTooltip:Show()
end

local function CreateTitle(text)
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetText(text)
    return title
end

-- Panel -------------------------------------------------------------------------------

local function CreatePanel()
    panel = CreateFrame("Frame", nil, AuctionHouseFrame)
    panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", PANEL_LEFT, PANEL_TOP)
    panel:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", PANEL_RIGHT, PANEL_BOTTOM)
    panel:SetFrameLevel(AuctionHouseFrame:GetFrameLevel() + PANEL_LEVEL_OFFSET)
    panel:EnableMouse(true)
    panel:Hide()
    UI.AddOwnFrame(panel)

    local background = panel:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0.06, 0.06, 0.06, 1)

    scanButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    scanButton:SetSize(SCAN_BUTTON_WIDTH, SCAN_BUTTON_HEIGHT)
    scanButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PADDING, -PADDING)
    scanButton:SetText(L["Scan the auction house"])
    scanButton:SetScript("OnClick", function()
        ns.Market.Scan(true)
        RefreshStatus()
    end)

    lastScan = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    lastScan:SetPoint("TOPLEFT", panel, "TOPLEFT", PADDING, -PADDING)
    lastScan:SetPoint("RIGHT", scanButton, "LEFT", -GAP, 0)
    lastScan:SetJustifyH("LEFT")
    scanState = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    scanState:SetPoint("TOPLEFT", lastScan, "BOTTOMLEFT", 0, -4)
    scanState:SetPoint("RIGHT", scanButton, "LEFT", -GAP, 0)
    scanState:SetJustifyH("LEFT")

    -- Two lists one under the other, sharing what is left of the height.
    local listsTop = PADDING + STATUS_HEIGHT + GAP
    local panelHeight = AuctionHouseFrame:GetHeight() + PANEL_TOP - PANEL_BOTTOM
    local listHeight = (panelHeight - listsTop - PADDING - 2 * TITLE_HEIGHT - GAP) / 2

    local undercutTitle = CreateTitle(L["Undercut auctions"])
    undercutTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", PADDING, -listsTop)
    undercutTable = UI.CreateTable(panel, {
        columns = {
            { key = "name", title = L["Item"], width = 262, item = true, ascendingFirst = true,
                sort = function(row) return row.name and row.name:lower() end },
            { key = "qty", title = L["Qty"], width = 50, align = "RIGHT",
                text = function(row) return ns.FormatCount(row.qty) end },
            { key = "unit", title = L["Unit price"], width = 110, align = "RIGHT",
                text = function(row) return ns.FormatMoney(row.unit) end },
            { key = "lowest", title = L["Lowest on the AH"], width = 160, align = "RIGHT",
                text = function(row) return ns.FormatMoney(row.lowest) end,
                color = function() return Colors.loss end },
            { key = "char", title = L["Character"], width = 100, gapBefore = 10, ascendingFirst = true,
                sort = function(row) return ns.CharacterName(row.char) end,
                text = function(row) return ns.ColoredCharacterName(row.char) end },
        },
        sort = { key = "name", ascending = true },
        onEnter = ShowUndercutTooltip,
    })
    undercutTable:SetPoint("TOPLEFT", panel, "TOPLEFT", PADDING, -listsTop - TITLE_HEIGHT)
    undercutTable:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PADDING, -listsTop - TITLE_HEIGHT)
    undercutTable:SetHeight(listHeight)

    local watchTop = listsTop + TITLE_HEIGHT + listHeight + GAP
    local watchTitle = CreateTitle(L["Watched items"])
    watchTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", PADDING, -watchTop)
    watchTable = UI.CreateTable(panel, {
        columns = {
            { key = "name", title = L["Item"], width = 200, item = true, ascendingFirst = true,
                sort = function(row) return row.name and row.name:lower() end },
            { key = "below", title = L["Buy target"], width = 170, align = "RIGHT",
                text = function(row) return ns.FormatMoney(row.below) end },
            { key = "above", title = L["Sell target"], width = 170, align = "RIGHT",
                text = function(row) return ns.FormatMoney(row.above) end },
            { key = "price", title = L["Lowest on the AH"], width = 160, align = "RIGHT",
                text = function(row) return ns.FormatMoney(row.price) end,
                color = function(row) return row.reached and Colors.gain or nil end },
        },
        sort = { key = "name", ascending = true },
        onEnter = ShowWatchTooltip,
    })
    watchTable:SetPoint("TOPLEFT", panel, "TOPLEFT", PADDING, -watchTop - TITLE_HEIGHT)
    watchTable:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PADDING, PADDING)

    -- The wait before the next scan counts down while the panel shows.
    local elapsed = 0
    panel:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        if elapsed >= STATUS_REFRESH_SECONDS then
            elapsed = 0
            RefreshStatus()
        end
    end)
    panel:SetScript("OnShow", Refresh)
end

-- Tab ---------------------------------------------------------------------------------

local function TabPosition(button)
    for index, candidate in ipairs(AuctionHouseFrame.Tabs) do
        if candidate == button then
            return index
        end
    end
end

local function Select()
    PanelTemplates_SetTab(AuctionHouseFrame, tabIndex)
    panel:Show()
    Refresh()
end

local function Build()
    if tab or not AuctionHouseFrame then
        return
    end
    CreatePanel()

    local tabs = AuctionHouseFrame.Tabs
    -- The game's own tabs, hooked before ours joins them. Selecting one again may
    -- change nothing on the game's side, so the panel goes and the tab is marked here.
    for _, button in ipairs(tabs) do
        button:HookScript("OnClick", function(self)
            if panel:IsShown() then
                panel:Hide()
                PanelTemplates_SetTab(AuctionHouseFrame, TabPosition(self))
            end
        end)
    end

    tab = CreateFrame("Button", "TradingBookAuctionHouseTab", AuctionHouseFrame, "PanelTabButtonTemplate")
    tab:SetText("Trading Book")
    tab:SetPoint("LEFT", tabs[#tabs], "RIGHT", 3, 0)
    table.insert(tabs, tab)
    tabIndex = #tabs
    tab:SetID(tabIndex)
    PanelTemplates_SetNumTabs(AuctionHouseFrame, #tabs)
    tab:SetScript("OnClick", Select)

    -- Any other tab selected, including another addon's, takes the panel away.
    hooksecurefunc("PanelTemplates_SetTab", function(frame, index)
        if frame == AuctionHouseFrame and index ~= tabIndex then
            panel:Hide()
        end
    end)
    AuctionHouseFrame:HookScript("OnHide", function()
        panel:Hide()
    end)
end

-- The auction house window loads with the game's auction house addon, the first time
-- the auction house opens.
ns.OnEvent("ADDON_LOADED", function(name)
    if name == "Blizzard_AuctionHouseUI" then
        Build()
    end
end)

ns.OnEvent("PLAYER_LOGIN", Build)

ns.Subscribe("MARKET_CHANGED", Refresh)
ns.Subscribe("AUCTIONS_CHANGED", Refresh)
ns.Subscribe("WATCH_CHANGED", Refresh)
