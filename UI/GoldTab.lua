local _, ns = ...
local L = ns.L
local UI = ns.UI
local Colors = UI.Colors

local CHART_HEIGHT = 270
local MAX_POINTS = 90
local HIGHLIGHTS_WIDTH = 360
local CARD_PADDING = 12
local FACT_ROW_HEIGHT = 26

local HOLDERS = {
    { value = "all", label = L["All holders"] },
    { value = "characters", label = L["Characters"] },
    { value = "warband", label = L["Shared stock"] },
}

local TILES = {
    { key = "current", label = L["Current gold"], icon = "Interface\\Icons\\INV_Misc_Coin_01" },
    { key = "change", label = L["Change"], icon = "Interface\\Icons\\Achievement_GuildPerk_CashFlow" },
    { key = "perDay", label = L["Per day"], icon = "Interface\\Icons\\INV_Misc_Coin_02",
        hint = L["Average change per day over the period"] },
    { key = "auctions", label = L["Auction result"], icon = "Interface\\Icons\\INV_Misc_CoinBag01",
        hint = L["Net profit = sales - purchases - fees"] },
}

local FACTS = {
    { key = "best", label = L["Best day"] },
    { key = "worst", label = L["Worst day"] },
    { key = "peak", label = L["Peak"] },
    { key = "days", label = L["Days up / down"] },
    { key = "other", label = L["Outside auctions"], hint = L["Quests, loot, repairs and everything else"] },
}

local period = 30
local holders = "all"
local tiles, chart, breakdownTable, holderSegments = nil, nil, nil, nil
local facts = {}

local function ShowPointTooltip(point)
    local to = ns.FormatDay(point.t)
    local from = point.from and ns.FormatDay(point.from) or to
    GameTooltip:SetText(from == to and to or (from .. " - " .. to))
    UI.AddMoneyLine(L["Current gold"], point.value)
    GameTooltip:AddDoubleLine(L["Change"], ns.FormatSignedMoney(point.delta), 0.8, 0.8, 0.8, 1, 1, 1)
end

local function BuildHighlights(pane, top)
    local card = UI.CreateCard(pane)
    card:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, top)
    card:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT")
    card:SetWidth(HIGHLIGHTS_WIDTH)

    local title = card:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    title:SetPoint("TOPLEFT", card, "TOPLEFT", CARD_PADDING, -CARD_PADDING)
    title:SetText(L["Highlights"])

    for index, fact in ipairs(FACTS) do
        local row = CreateFrame("Frame", nil, card)
        row:SetPoint("TOPLEFT", card, "TOPLEFT", CARD_PADDING, -CARD_PADDING - 22 - (index - 1) * FACT_ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", card, "TOPRIGHT", -CARD_PADDING, -CARD_PADDING - 22 - (index - 1) * FACT_ROW_HEIGHT)
        row:SetHeight(FACT_ROW_HEIGHT)

        local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        label:SetPoint("LEFT", row, "LEFT")
        label:SetText(fact.label)
        label:SetTextColor(Colors.secondary[1], Colors.secondary[2], Colors.secondary[3])

        row.Value = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.Value:SetPoint("RIGHT", row, "RIGHT")
        row.Value:SetJustifyH("RIGHT")

        if fact.hint then
            UI.AddHint(row, fact.label, fact.hint)
        end
        facts[fact.key] = row
    end
end

local function SetFact(key, text, color)
    local c = color or Colors.text
    facts[key].Value:SetText(text)
    facts[key].Value:SetTextColor(c[1], c[2], c[3])
end

local function DatedMoney(point, signedValue)
    if not point then
        return "-"
    end
    local amount = signedValue and ns.FormatSignedMoney(point.delta) or ns.FormatMoney(point.value)
    return amount .. "  |cff898781" .. ns.FormatDay(point.t) .. "|r"
end

local function HolderName(row)
    return row.isWarband and L["Shared stock"] or ns.ColoredCharacterName(row.key)
end

local function Refresh()
    local characterFilter = UI.GetCharacterFilter()
    -- A selected character already says whose gold this is.
    holderSegments.SetActive(not characterFilter)

    local options = { days = period, char = characterFilter, holders = holders }
    local analysis = ns.Gold.Analyze(options)

    tiles.current:SetValue(ns.FormatMoney(analysis.current))
    tiles.change:SetValue(ns.FormatSignedMoney(analysis.change), UI.ColorForAmount(analysis.change))
    tiles.change:SetNote(analysis.percent and ns.FormatPercent(analysis.percent, true) or "")
    tiles.perDay:SetValue(ns.FormatSignedMoney(analysis.perDay), UI.ColorForAmount(analysis.perDay))
    tiles.auctions:SetValue(ns.FormatSignedMoney(analysis.auctionNet), UI.ColorForAmount(analysis.auctionNet))

    chart.Note:SetText(analysis.trackedSince
        and L["Tracked since %s"]:format(ns.FormatDay(ns.DayKeyToTime(analysis.trackedSince))) or "")
    chart:SetPoints(ns.Gold.Downsample(analysis.points, MAX_POINTS))

    SetFact("best", DatedMoney(analysis.best, true), analysis.best and Colors.gain)
    SetFact("worst", DatedMoney(analysis.worst, true), analysis.worst and Colors.loss)
    SetFact("peak", DatedMoney(analysis.peak, false))
    SetFact("days", analysis.upDays and (analysis.upDays .. " / " .. analysis.downDays) or "-")
    SetFact("other", ns.FormatSignedMoney(analysis.otherIncome), UI.ColorForAmount(analysis.otherIncome))

    breakdownTable:SetRows(ns.Gold.GetBreakdown(options))
end

UI.RegisterTab({
    key = "gold",
    title = L["Gold"],
    Build = function(pane, toolbar)
        local periods = UI.CreateSegments(toolbar, UI.PERIODS, period, function(value)
            period = value
            Refresh()
        end)
        periods:SetPoint("LEFT", toolbar, "LEFT")

        holderSegments = UI.CreateSegments(toolbar, HOLDERS, holders, function(value)
            holders = value
            Refresh()
        end)
        holderSegments:SetPoint("LEFT", periods, "RIGHT", UI.GAP, 0)

        local tilesHeight
        tiles, tilesHeight = UI.CreateTiles(pane, TILES, #TILES)

        local chartTop = -tilesHeight - UI.GAP
        chart = UI.CreateLineChart(pane, UI.CONTENT_WIDTH, CHART_HEIGHT, ShowPointTooltip)
        chart:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, chartTop)
        chart.Title:SetText(L["Gold over time"])

        local bottomTop = chartTop - CHART_HEIGHT - UI.GAP
        BuildHighlights(pane, bottomTop)

        breakdownTable = UI.CreateTable(pane, {
            columns = {
                { key = "key", title = L["Holder"], width = 190, ascendingFirst = true,
                    sort = function(row) return row.isWarband and "" or ns.CharacterName(row.key) end,
                    text = HolderName },
                { key = "gold", title = L["Gold"], width = 120, align = "RIGHT", text = function(row) return ns.FormatMoney(row.gold) end },
                { key = "share", title = L["Share"], width = 62, align = "RIGHT", text = function(row) return ns.FormatPercent(row.share) end },
                { key = "change", title = L["Change"], width = 112, align = "RIGHT", text = function(row) return ns.FormatSignedMoney(row.change) end,
                    color = function(row) return UI.ColorForAmount(row.change) end },
            },
            sort = { key = "gold", ascending = false },
        })
        breakdownTable:SetPoint("TOPLEFT", pane, "TOPLEFT", HIGHLIGHTS_WIDTH + UI.GAP, bottomTop)
        breakdownTable:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT")
    end,
    Refresh = Refresh,
})
