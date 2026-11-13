local _, ns = ...
local L = ns.L
local UI = ns.UI

local TILES_PER_ROW = 4
local CHART_HEIGHT = 150
local MAX_BARS = 60

local TILES = {
    { key = "net", label = L["Net profit"], icon = "Interface\\Icons\\INV_Misc_Coin_02",
        hint = L["Net profit = sales - purchases - fees"] },
    { key = "profit", label = L["Profit on sales"], icon = "Interface\\Icons\\INV_Misc_Coin_17",
        hint = L["Sales after the cut, less lost deposits and cancellations, less what the units sold cost to buy or craft. Units neither bought nor crafted count as free"] },
    { key = "sales", label = L["Sales"], icon = "Interface\\Icons\\INV_Misc_CoinBag01" },
    { key = "spent", label = L["Purchases"], icon = "Interface\\Icons\\INV_Crate_03",
        hint = L["Purchases whose mail invoice could not be read have no price: they count as zero, and the corner shows how many"] },
    { key = "fees", label = L["Fees"], icon = "Interface\\Icons\\INV_Scroll_03",
        hint = L["Fees = cut + unrefunded deposits + cancellation costs"] },
    { key = "sellThrough", label = L["Sell-through"], icon = "Interface\\Icons\\Achievement_Reputation_08",
        hint = L["Share of listed quantity that sold, among auctions that ended"] },
    { key = "stockValue", label = L["Stock value (est.)"], icon = "Interface\\Icons\\INV_Box_01",
        hint = L["Priced with Auctionator or the auction house scan, or your recent sales when neither has a price"] },
    { key = "goldChange", label = L["Gold change"], icon = "Interface\\Icons\\Achievement_GuildPerk_CashFlow" },
}

-- The player can put the tiles in an order of their own.
local tileOrder = UI.RegisterOrder("tiles", L["Stats tiles"])
for _, spec in ipairs(TILES) do
    table.insert(tileOrder, { key = spec.key, label = spec.label })
end

local period = 30
local tiles, tilesPane, chart, itemsTable = nil, nil, nil, nil

-- The items of the period, with what they earned and how they sold.
local function BuildItemRows(summary, analysis)
    local rows = {}
    for key, item in pairs(summary.items) do
        local profit = analysis[key]
        if item.soldQty > 0 or item.boughtQty > 0 or (profit and profit.advice) then
            item.avgSale = item.soldQty > 0 and item.gross / item.soldQty or nil
            item.avgPurchase = item.pricedBoughtQty > 0 and item.spent / item.pricedBoughtQty or nil
            item.profit = profit
            rows[#rows + 1] = item
        end
    end
    return rows
end

local function ProfitOf(row)
    return row.profit and row.profit.profit
end

local function AdviceOf(row)
    return row.profit and ns.Profit.ADVICE[row.profit.advice]
end

local function AdviceColor(advice)
    return advice.bad and UI.Colors.loss or UI.Colors.gain
end

local function ShowItemTooltip(owner, row)
    UI.ShowItemTooltip(owner, row.itemID, nil, row.name)
    local profit = row.profit
    if profit then
        GameTooltip:AddLine(" ")
        UI.AddMoneyLine(L["After the cut"], profit.proceeds)
        UI.AddMoneyLine(L["Lost fees"], profit.feesLost)
        if profit.costSource then
            UI.AddMoneyLine(profit.costSource == "bought" and L["Unit cost (bought)"] or L["Unit cost (crafted)"],
                profit.unitCost)
        else
            UI.AddValueLine(GameTooltip, L["Unit cost"], L["Free: neither bought nor crafted"])
        end
        UI.AddValueLine(GameTooltip, L["Profit"], ns.FormatSignedMoney(profit.profit))
        if profit.unitProfit then
            UI.AddValueLine(GameTooltip, L["Profit per unit"], ns.FormatSignedMoney(profit.unitProfit))
        end
        local advice = AdviceOf(row)
        if advice then
            local color = AdviceColor(advice)
            GameTooltip:AddLine(advice.text, color[1], color[2], color[3], true)
        end
    end
    if row.boughtQty > 0 then
        GameTooltip:AddLine(" ")
        UI.AddValueLine(GameTooltip, L["Bought"], ns.FormatCount(row.boughtQty))
        UI.AddMoneyLine(L["Avg. purchase"], row.avgPurchase)
    end
    UI.AddValueLine(GameTooltip, L["Net"], ns.FormatSignedMoney(row.net))
    GameTooltip:Show()
end

local function Refresh()
    local characterFilter = UI.GetCharacterFilter()
    local options = { since = ns.Stats.PeriodStart(period), char = characterFilter }
    local summary = ns.Stats.Summarize(options)

    local analysis = ns.Profit.Analyze(options)
    local profit = ns.Profit.Total(analysis)
    tiles.net:SetValue(ns.FormatSignedMoney(summary.net), UI.ColorForAmount(summary.net))
    tiles.profit:SetValue(ns.FormatSignedMoney(profit), UI.ColorForAmount(profit))
    tiles.sales:SetValue(ns.FormatMoney(summary.gross))
    tiles.spent:SetValue(ns.FormatMoney(summary.spent))
    tiles.spent:SetNote(summary.unpricedPurchases > 0
        and L["%s unpriced"]:format(BreakUpLargeNumbers(summary.unpricedPurchases)) or "")
    tiles.fees:SetValue(ns.FormatMoney(summary.fees))
    tiles.sellThrough:SetValue(summary.sellThrough and ("%d%%"):format(summary.sellThrough * 100 + 0.5) or "-")
    tiles.stockValue:SetValue(ns.FormatMoney(ns.Stockpile.GetValue(characterFilter)))

    local goldChange = ns.Gold.Analyze({ days = period, char = characterFilter }).change
    tiles.goldChange:SetValue(ns.FormatSignedMoney(goldChange), UI.ColorForAmount(goldChange))

    local bars, bucketDays = ns.Stats.BuildSeries(options, MAX_BARS)
    chart.Title:SetText(bucketDays > 1 and L["Net result per %d days"]:format(bucketDays) or L["Net result per day"])
    chart:SetBars(bars)
    itemsTable:SetRows(BuildItemRows(summary, analysis))
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
        tiles, tilesHeight = UI.CreateTiles(pane, TILES, TILES_PER_ROW, UI.GetOrder("tiles"))
        tilesPane = pane

        local chartTop = -tilesHeight - UI.GAP
        chart = UI.CreateBarChart(pane, UI.CONTENT_WIDTH, CHART_HEIGHT)
        chart:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, chartTop)

        itemsTable = UI.CreateTable(pane, {
            columns = {
                { key = "name", title = L["Item"], width = 222, item = true, ascendingFirst = true,
                    sort = function(row) return row.name and row.name:lower() end },
                { key = "soldQty", title = L["Sold"], width = 60, align = "RIGHT", text = function(row) return ns.FormatCount(row.soldQty) end },
                { key = "avgSale", title = L["Avg. sale"], width = 105, align = "RIGHT", text = function(row) return ns.FormatMoney(row.avgSale) end },
                { key = "sellThrough", title = L["Sold %"], width = 70, align = "RIGHT",
                    sort = function(row) return row.profit and row.profit.sellThrough end,
                    text = function(row)
                        local ratio = row.profit and row.profit.sellThrough
                        return ratio and ns.FormatPercent(ratio) or "-"
                    end },
                { key = "timeToSell", title = L["Time to sell"], width = 85, align = "RIGHT",
                    sort = function(row) return row.profit and row.profit.timeToSell end,
                    text = function(row)
                        local seconds = row.profit and row.profit.timeToSell
                        return seconds and ns.FormatDuration(seconds) or "-"
                    end },
                { key = "unitCost", title = L["Unit cost"], width = 105, align = "RIGHT",
                    sort = function(row) return row.profit and row.profit.unitCost end,
                    text = function(row) return ns.FormatMoney(row.profit and row.profit.unitCost) end },
                { key = "profit", title = L["Profit"], width = 110, align = "RIGHT", sort = ProfitOf,
                    text = function(row) return ns.FormatSignedMoney(ProfitOf(row)) end,
                    color = function(row) return UI.ColorForAmount(ProfitOf(row)) end },
                { key = "advice", title = L["Advice"], width = 70,
                    sort = function(row) return row.profit and row.profit.advice end,
                    text = function(row)
                        local advice = AdviceOf(row)
                        return advice and advice.label or ""
                    end,
                    color = function(row)
                        local advice = AdviceOf(row)
                        return advice and AdviceColor(advice) or nil
                    end },
            },
            sort = { key = "profit", ascending = false },
            onEnter = ShowItemTooltip,
        })
        itemsTable:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, chartTop - CHART_HEIGHT - UI.GAP)
        itemsTable:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT")
    end,
    Refresh = Refresh,
})

ns.Subscribe("ORDER_CHANGED", function()
    if tiles then
        UI.ArrangeTiles(tilesPane, tiles, UI.GetOrder("tiles"), TILES_PER_ROW)
    end
end)
