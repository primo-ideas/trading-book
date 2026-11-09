local _, ns = ...
local L = ns.L
local UI = ns.UI
local Colors = UI.Colors

-- A Trading Book tab in the auction house window: when the auction house was last
-- scanned, a button to scan it, the account's undercut auctions and the watched items.
--
-- The game's tab list stays untouched: changing it, or selecting a tab through the
-- PanelTemplates functions, taints the auction house and reaches the player's bags
-- even in combat. The addons' tabs go through LibAHTab instead, when one of them
-- brings it, as Auctionator does, so that they all stand in line and take turns.
-- Without it, the tab does the same on its own.

local TAB_ID, TAB_TITLE = "TradingBook", "Trading Book"
local TAB_GAP = 3

-- Inside the auction house window: below its title bar, above the player's money.
local PANEL_LEFT, PANEL_TOP, PANEL_RIGHT, PANEL_BOTTOM = 4, -26, -4, 27
local PADDING = 12
local GAP = 10
local TITLE_HEIGHT = 20
local STATUS_HEIGHT = 40
local SCAN_BUTTON_WIDTH, SCAN_BUTTON_HEIGHT = 220, 24
local STATUS_REFRESH_SECONDS = 1

local panel = nil
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
        local offer = ns.Market.GetOffer(watched.itemID)
        local price = offer and offer.price
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
    UI.AddOfferSourceLine(row.itemID)
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
    panel:Hide()
    UI.AddOwnFrame(panel)

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

-- What LibAHTab does for its tabs, for when no addon brings it. An empty display mode
-- makes the game hide its content, and forgetting it makes the game's next mode count
-- as a change, so that its tab is selected again.
local function AddOwnTab()
    local frame = AuctionHouseFrame
    local gameTabs = frame.Tabs
    -- A frame of its own as parent keeps the button out of the game's tab list.
    local root = CreateFrame("Frame", nil, frame)
    root:SetSize(10, 10)
    root:SetPoint("TOPLEFT", gameTabs[#gameTabs], "TOPRIGHT")

    local tab = CreateFrame("Button", "TradingBookAuctionHouseTab", root, "AuctionHouseFrameDisplayModeTabTemplate")
    tab:SetText(TAB_TITLE)
    tab:SetPoint("TOPLEFT", root, "TOPLEFT", TAB_GAP, 0)
    PanelTemplates_DeselectTab(tab)
    tab:SetScript("OnClick", function()
        frame:SetDisplayMode({})
        frame.displayMode = nil
        for _, gameTab in ipairs(gameTabs) do
            PanelTemplates_DeselectTab(gameTab)
        end
        PanelTemplates_SelectTab(tab)
        frame:SetTitle(TAB_TITLE)
        panel:Show()
    end)

    hooksecurefunc(frame, "SetDisplayMode", function(_, mode)
        if mode ~= nil and #mode > 0 then
            panel:Hide()
            PanelTemplates_DeselectTab(tab)
        end
    end)
end

local function Build()
    if panel or not AuctionHouseFrame then
        return
    end
    CreatePanel()
    local library = LibStub and LibStub("LibAHTab-1-0", true)
    if library then
        library:CreateTab(TAB_ID, panel, TAB_TITLE)
    else
        AddOwnTab()
    end
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
ns.Subscribe("AUCTIONATOR_PRICES_CHANGED", Refresh)
ns.Subscribe("AUCTIONS_CHANGED", Refresh)
ns.Subscribe("WATCH_CHANGED", Refresh)
