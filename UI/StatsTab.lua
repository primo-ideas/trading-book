local _, ns = ...
local L = ns.L
local UI = ns.UI

local TILES_PER_ROW = 4
local CHART_HEIGHT = 150
local MAX_BARS = 60

local TILES = {
    { key = "net", label = L["Net profit"], icon = "Interface\\Icons\\INV_Misc_Coin_02",
        hint = L["Net profit = sales - purchases - fees"] },
    { key = "sales", label = L["Sales"], icon = "Interface\\Icons\\INV_Misc_CoinBag01" },
    { key = "spent", label = L["Purchases"], icon = "Interface\\Icons\\INV_Crate_03" },
    { key = "fees", label = L["Fees"], icon = "Interface\\Icons\\INV_Scroll_03",
        hint = L["Fees = cut + unrefunded deposits + cancellation costs"] },
    { key = "sellThrough", label = L["Sell-through"], icon = "Interface\\Icons\\Achievement_Reputation_08",
        hint = L["Share of listed quantity that sold, among auctions that ended"] },
    { key = "stockValue", label = L["Stock value (est.)"], icon = "Interface\\Icons\\INV_Box_01",
        hint = L["Priced with Auctionator or the auction house scan, or your recent sales when neither has a price"] },
    { key = "gold", label = L["Total gold"], icon = "Interface\\Icons\\INV_Misc_Coin_01" },
    { key = "goldChange", label = L["Gold change"], icon = "Interface\\Icons\\Achievement_GuildPerk_CashFlow" },
}

local period = 30
local tiles, chart, itemsTable = nil, nil, nil

local function BuildItemRows(summary)
    local rows = {}
    for _, item in pairs(summary.items) do
        if item.soldQty > 0 or item.boughtQty > 0 then
            item.avgSale = item.soldQty > 0 and item.gross / item.soldQty or nil
            item.avgPurchase = item.boughtQty > 0 and item.spent / item.boughtQty or nil
            rows[#rows + 1] = item
        end
    end
    return rows
end

local function Refresh()
    local characterFilter = UI.GetCharacterFilter()
    local options = { since = ns.Stats.PeriodStart(period), char = characterFilter }
    local summary = ns.Stats.Summarize(options)

    tiles.net:SetValue(ns.FormatSignedMoney(summary.net), UI.ColorForAmount(summary.net))
    tiles.sales:SetValue(ns.FormatMoney(summary.gross))
    tiles.spent:SetValue(ns.FormatMoney(summary.spent))
    tiles.fees:SetValue(ns.FormatMoney(summary.fees))
    tiles.sellThrough:SetValue(summary.sellThrough and ("%d%%"):format(summary.sellThrough * 100 + 0.5) or "-")
    tiles.stockValue:SetValue(ns.FormatMoney(ns.Stockpile.GetValue(characterFilter)))
    tiles.gold:SetValue(ns.FormatMoney(ns.Stockpile.GetGold(characterFilter)))

    local goldChange = ns.Gold.Analyze({ days = period, char = characterFilter }).change
    tiles.goldChange:SetValue(ns.FormatSignedMoney(goldChange), UI.ColorForAmount(goldChange))

    local bars, bucketDays = ns.Stats.BuildSeries(options, MAX_BARS)
    chart.Title:SetText(bucketDays > 1 and L["Net result per %d days"]:format(bucketDays) or L["Net result per day"])
    chart:SetBars(bars)
    itemsTable:SetRows(BuildItemRows(summary))
end

UI.RegisterTab({
    key = "stats",
    title = L["Stats"],
    Build = function(pane, toolbar)
        local segments = UI.CreateSegments(toolbar, UI.PERIODS, period, function(value)
            period = value
            Refresh()
        end)
        segments:SetPoint("LEFT", toolbar, "LEFT")

        local tilesHeight
        tiles, tilesHeight = UI.CreateTiles(pane, TILES, TILES_PER_ROW)

        local chartTop = -tilesHeight - UI.GAP
        chart = UI.CreateBarChart(pane, UI.CONTENT_WIDTH, CHART_HEIGHT)
        chart:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, chartTop)

        itemsTable = UI.CreateTable(pane, {
            columns = {
                { key = "name", title = L["Item"], width = 340, item = true, ascendingFirst = true,
                    sort = function(row) return row.name and row.name:lower() end },
                { key = "soldQty", title = L["Sold"], width = 70, align = "RIGHT", text = function(row) return ns.FormatCount(row.soldQty) end },
                { key = "avgSale", title = L["Avg. sale"], width = 120, align = "RIGHT", text = function(row) return ns.FormatMoney(row.avgSale) end },
                { key = "boughtQty", title = L["Bought"], width = 70, align = "RIGHT", text = function(row) return ns.FormatCount(row.boughtQty) end },
                { key = "avgPurchase", title = L["Avg. purchase"], width = 120, align = "RIGHT", text = function(row) return ns.FormatMoney(row.avgPurchase) end },
                { key = "net", title = L["Net"], width = 120, align = "RIGHT", text = function(row) return ns.FormatSignedMoney(row.net) end,
                    color = function(row) return UI.ColorForAmount(row.net) end },
            },
            sort = { key = "net", ascending = false },
            onEnter = function(owner, row)
                UI.ShowItemTooltip(owner, row.itemID, nil, row.name)
                GameTooltip:Show()
            end,
        })
        itemsTable:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, chartTop - CHART_HEIGHT - UI.GAP)
        itemsTable:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT")
    end,
    Refresh = Refresh,
})
