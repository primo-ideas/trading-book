local _, ns = ...
local L = ns.L
local UI = ns.UI

local CHANGE_DAYS = 7
local FOOTER_HEIGHT = 20

local PLACE_FILTERS = {
    { value = "all", label = L["All"] },
    { value = "bags", label = L["Bags"] },
    { value = "bank", label = L["Personal bank"] },
    { value = "warband", label = L["Shared stock"] },
    { value = "mail", label = L["Mail"] },
    { value = "auctions", label = L["AH"] },
}

local TILES = {
    { key = "value", label = L["Stock value"], icon = "Interface\\Icons\\INV_Box_01",
        hint = L["Priced with Auctionator or the auction house scan, or your recent sales when neither has a price"] },
    { key = "items", label = L["Different items"], icon = "Interface\\Icons\\INV_Misc_Bag_10" },
    { key = "units", label = L["Units"], icon = "Interface\\Icons\\INV_Crate_03" },
}

local place = "all"
local search = ""
local stockTable, tiles, scansLabel = nil, nil, nil

local function QuantityKey()
    return place == "all" and "total" or place
end

local function CountColumn(key, title, width)
    return { key = key, title = title, width = width, align = "RIGHT", text = function(row) return ns.FormatCount(row[key]) end }
end

local function FormatChange(change)
    if not change then
        return "-"
    elseif change > 0 then
        return "+" .. BreakUpLargeNumbers(change)
    end
    return change == 0 and "0" or "-" .. BreakUpLargeNumbers(-change)
end

-- Rows for the selected place, and totals that ignore the search: it narrows the
-- list to look something up, not the stock being measured.
local function BuildRows()
    local characterFilter = UI.GetCharacterFilter()
    -- The shared stock belongs to no character, so it stays whichever one is selected.
    local scope = place ~= "warband" and characterFilter or nil
    local quantityKey = QuantityKey()
    local rows = {}
    local totals = { value = 0, items = 0, units = 0 }

    for _, row in ipairs(ns.Stockpile.GetRows(scope)) do
        local quantity = row[quantityKey]
        if quantity > 0 then
            row.name = ns.GetItemDetails(row.itemID)
            row.unitPrice, row.priceSource, row.priceSeenAt = ns.Stats.GetUnitPrice(row.itemID)
            row.value = row.unitPrice and row.unitPrice * quantity or nil
            totals.value = totals.value + (row.value or 0)
            totals.items = totals.items + 1
            totals.units = totals.units + quantity
            if UI.MatchesSearch(row.name, search) then
                -- History covers the whole stock of the account, nothing narrower.
                local isWholeAccount = place == "all" and not characterFilter
                row.change = isWholeAccount and ns.Stockpile.GetChange(row.itemID, CHANGE_DAYS) or nil
                rows[#rows + 1] = row
            end
        end
    end
    return rows, totals
end

local function PriceSource(row)
    if row.priceSource == "auctionator" then
        return L["Source: Auctionator"]
    elseif row.priceSource == "scan" then
        return L["Source: auction house scan of %s"]:format(ns.FormatDate(row.priceSeenAt))
    end
    return L["Source: your recent sales"]
end

local function ShowRowTooltip(owner, row)
    UI.ShowItemTooltip(owner, row.itemID, nil, row.name)
    GameTooltip:AddLine(" ")
    UI.AddHoldingLines(GameTooltip, row)
    if row.change then
        GameTooltip:AddDoubleLine(L["Change over 7 days"], FormatChange(row.change), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    if row.unitPrice then
        UI.AddMoneyLine(L["Unit value"], row.unitPrice)
        GameTooltip:AddLine(PriceSource(row), 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

local function Refresh()
    local rows, totals = BuildRows()
    stockTable:SetRows(rows)
    tiles.value:SetValue(ns.FormatMoney(totals.value))
    tiles.items:SetValue(ns.FormatCount(totals.items))
    tiles.units:SetValue(ns.FormatCount(totals.units))
    scansLabel:SetText(L["Bank last scanned: %s    Shared stock: %s"]:format(
        ns.FormatDate(ns.GetCharacter().stock.bankScannedAt),
        ns.FormatDate(ns.db.warband.scannedAt)))
end

UI.RegisterTab({
    key = "stock",
    title = L["Stock"],
    Build = function(pane, toolbar)
        local segments = UI.CreateSegments(toolbar, PLACE_FILTERS, place, function(value)
            place = value
            stockTable:SortBy(QuantityKey(), false)
            Refresh()
        end)
        segments:SetPoint("LEFT", toolbar, "LEFT")

        local searchBox = UI.CreateSearchBox(toolbar, function(text)
            search = text
            Refresh()
        end)
        searchBox:SetPoint("RIGHT", toolbar, "RIGHT")

        local tilesHeight
        tiles, tilesHeight = UI.CreateTiles(pane, TILES, #TILES)

        scansLabel = pane:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        scansLabel:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 2, 0)

        stockTable = UI.CreateTable(pane, {
            columns = {
                { key = "name", title = L["Item"], width = 298, item = true, ascendingFirst = true,
                    sort = function(row) return row.name and row.name:lower() end },
                CountColumn("total", L["Total"], 62),
                CountColumn("bags", L["Bags"], 56),
                CountColumn("bank", L["Bank"], 62),
                CountColumn("warband", L["Shared"], 66),
                CountColumn("mail", L["Mail"], 62),
                CountColumn("auctions", L["AH"], 46),
                { key = "change", title = L["7 d"], width = 52, align = "RIGHT", text = function(row) return FormatChange(row.change) end,
                    color = function(row) return UI.ColorForAmount(row.change) end },
                { key = "value", title = L["Value"], width = 112, align = "RIGHT", text = function(row) return ns.FormatMoney(row.value) end },
            },
            sort = { key = "total", ascending = false },
            onEnter = ShowRowTooltip,
        })
        stockTable:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -tilesHeight - UI.GAP)
        stockTable:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, FOOTER_HEIGHT)
    end,
    Refresh = Refresh,
})
