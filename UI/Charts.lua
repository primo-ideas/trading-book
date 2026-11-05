local _, ns = ...
local L = ns.L
local UI = ns.UI
local Colors = UI.Colors

local CARD_PADDING = 12
local TITLE_HEIGHT = 36
local X_AXIS_HEIGHT = 26
local Y_AXIS_WIDTH = 108
local BAR_GAP = 2
local MAX_BAR_WIDTH = 24
local LINE_THICKNESS = 2
local MAX_DOTS = 31
local DOT_SIZE = 5
local MARKER_SIZE = 8

-- A line on its own in a warm colour, in keeping with what it shows.
local LINE_COLOR = { 0.941, 0.706, 0 }
-- Grid and axes stay in the background, one step off the surface.
local GRID_COLOR = { 1, 1, 1, 0.07 }
local AXIS_COLOR = { 1, 1, 1, 0.22 }

local function CreateAxisLabel(chart)
    return chart:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
end

-- The card, title, plot area and axis labels shared by every chart.
local function CreateChart(parent, width, height)
    local chart = UI.CreateCard(parent)
    chart:SetSize(width, height)

    chart.Title = chart:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    chart.Title:SetPoint("TOPLEFT", chart, "TOPLEFT", CARD_PADDING, -CARD_PADDING)
    chart.Note = CreateAxisLabel(chart)
    chart.Note:SetPoint("TOPRIGHT", chart, "TOPRIGHT", -CARD_PADDING, -CARD_PADDING - 1)

    chart.plotWidth = width - Y_AXIS_WIDTH - CARD_PADDING
    chart.plotHeight = height - TITLE_HEIGHT - X_AXIS_HEIGHT
    chart.plot = CreateFrame("Frame", nil, chart)
    chart.plot:SetPoint("TOPLEFT", chart, "TOPLEFT", Y_AXIS_WIDTH, -TITLE_HEIGHT)
    chart.plot:SetSize(chart.plotWidth, chart.plotHeight)

    chart.TopLabel = CreateAxisLabel(chart)
    chart.TopLabel:SetPoint("RIGHT", chart.plot, "TOPLEFT", -8, 0)
    chart.BottomLabel = CreateAxisLabel(chart)
    chart.BottomLabel:SetPoint("RIGHT", chart.plot, "BOTTOMLEFT", -8, 0)
    chart.StartLabel = CreateAxisLabel(chart)
    chart.StartLabel:SetPoint("TOPLEFT", chart.plot, "BOTTOMLEFT", 0, -6)
    chart.EndLabel = CreateAxisLabel(chart)
    chart.EndLabel:SetPoint("TOPRIGHT", chart.plot, "BOTTOMRIGHT", 0, -6)

    chart.slots = {}
    return chart
end

-- The whole column is the hover target, so small marks stay easy to reach.
local function AcquireSlot(chart, index, onEnter)
    local slot = chart.slots[index]
    if not slot then
        slot = CreateFrame("Frame", nil, chart.plot)
        slot:EnableMouse(true)
        slot:SetScript("OnEnter", onEnter)
        slot:SetScript("OnLeave", function()
            if chart.OnSlotLeave then
                chart:OnSlotLeave()
            end
            GameTooltip:Hide()
        end)
        chart.slots[index] = slot
    end
    return slot
end

local function HideExtra(list, count)
    for index = count + 1, #list do
        list[index]:Hide()
    end
end

local function PlaceSlot(chart, slot, index, slotWidth)
    slot:ClearAllPoints()
    slot:SetPoint("TOPLEFT", chart.plot, "TOPLEFT", (index - 1) * slotWidth, 0)
    slot:SetSize(slotWidth, chart.plotHeight)
    slot:Show()
end

-- Bar chart of signed values ----------------------------------------------------

local function ShowBarTooltip(slot)
    local bar = slot.bar
    GameTooltip:SetOwner(slot, "ANCHOR_TOP")
    local from, to = ns.FormatDay(bar.from), ns.FormatDay(bar.to)
    GameTooltip:SetText(from == to and from or (from .. " - " .. to))
    UI.AddMoneyLine(L["Net result"], bar.net)
    UI.AddMoneyLine(L["Sales"], bar.gross)
    UI.AddMoneyLine(L["Purchases"], bar.spent)
    GameTooltip:Show()
end

-- Gains and losses stand on either side of a baseline, so sign does not rest on
-- colour alone. bars: { from, to, net, gross, spent }.
function UI.CreateBarChart(parent, width, height)
    local chart = CreateChart(parent, width, height)

    chart.Baseline = chart.plot:CreateTexture(nil, "BORDER")
    chart.Baseline:SetHeight(1)
    chart.Baseline:SetColorTexture(AXIS_COLOR[1], AXIS_COLOR[2], AXIS_COLOR[3], AXIS_COLOR[4])

    function chart.SetBars(self, bars)
        local maxGain, maxLoss = 0, 0
        for _, bar in ipairs(bars) do
            maxGain = math.max(maxGain, bar.net)
            maxLoss = math.max(maxLoss, -bar.net)
        end
        local range = maxGain + maxLoss
        local baseline = range > 0 and self.plotHeight * maxLoss / range or self.plotHeight / 2

        self.Baseline:ClearAllPoints()
        self.Baseline:SetPoint("BOTTOMLEFT", self.plot, "BOTTOMLEFT", 0, baseline)
        self.Baseline:SetPoint("BOTTOMRIGHT", self.plot, "BOTTOMRIGHT", 0, baseline)
        self.TopLabel:SetText(maxGain > 0 and ns.FormatMoney(maxGain) or "")
        self.BottomLabel:SetText(maxLoss > 0 and ns.FormatMoney(-maxLoss) or "")
        self.StartLabel:SetText(#bars > 0 and ns.FormatDay(bars[1].from) or "")
        self.EndLabel:SetText(#bars > 0 and ns.FormatDay(bars[#bars].to) or "")

        local slotWidth = #bars > 0 and self.plotWidth / #bars or 0
        local barWidth = math.min(math.max(1, slotWidth - BAR_GAP), MAX_BAR_WIDTH)

        for index, bar in ipairs(bars) do
            local slot = AcquireSlot(self, index, ShowBarTooltip)
            slot.bar = bar
            PlaceSlot(self, slot, index, slotWidth)

            if not slot.Bar then
                slot.Bar = slot:CreateTexture(nil, "ARTWORK")
            end
            slot.Bar:ClearAllPoints()
            if bar.net == 0 or range == 0 then
                slot.Bar:Hide()
            else
                local color = bar.net > 0 and Colors.category1 or Colors.loss
                slot.Bar:SetColorTexture(color[1], color[2], color[3])
                slot.Bar:SetSize(barWidth, math.max(1, math.abs(bar.net) / range * self.plotHeight))
                if bar.net > 0 then
                    slot.Bar:SetPoint("BOTTOM", slot, "BOTTOM", 0, baseline)
                else
                    slot.Bar:SetPoint("TOP", slot, "BOTTOM", 0, baseline)
                end
                slot.Bar:Show()
            end
        end
        HideExtra(self.slots, #bars)
    end
    return chart
end

-- Line chart --------------------------------------------------------------------

local function PointX(chart, index, count)
    return (index - 0.5) * chart.plotWidth / count
end

-- Around the values rather than from zero: a line shows change, and a large stock
-- of gold would otherwise flatten it.
local function ValueRange(points)
    local low, high = points[1].value, points[1].value
    for _, point in ipairs(points) do
        low = math.min(low, point.value)
        high = math.max(high, point.value)
    end
    local margin = math.max((high - low) * 0.12, high * 0.02, 10000)
    return math.max(0, low - margin), high + margin
end

-- onPoint(point) fills the tooltip for a point. points: { t, from?, value, delta }.
function UI.CreateLineChart(parent, width, height, onPoint)
    local chart = CreateChart(parent, width, height)
    chart.lines = {}
    chart.dots = {}

    for _, position in ipairs({ 0, 0.5, 1 }) do
        local grid = chart.plot:CreateTexture(nil, "BORDER")
        grid:SetPoint("BOTTOMLEFT", chart.plot, "BOTTOMLEFT", 0, position * chart.plotHeight)
        grid:SetPoint("BOTTOMRIGHT", chart.plot, "BOTTOMRIGHT", 0, position * chart.plotHeight)
        grid:SetHeight(1)
        grid:SetColorTexture(GRID_COLOR[1], GRID_COLOR[2], GRID_COLOR[3], GRID_COLOR[4])
    end

    chart.MiddleLabel = CreateAxisLabel(chart)
    chart.MiddleLabel:SetPoint("RIGHT", chart.plot, "LEFT", -8, 0)

    chart.Empty = chart:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    chart.Empty:SetPoint("BOTTOM", chart.plot, "CENTER", 0, 12)
    chart.Empty:SetText(L["History builds up day after day."])

    chart.Crosshair = chart.plot:CreateTexture(nil, "BORDER")
    chart.Crosshair:SetWidth(1)
    chart.Crosshair:SetColorTexture(AXIS_COLOR[1], AXIS_COLOR[2], AXIS_COLOR[3], AXIS_COLOR[4])
    chart.Crosshair:Hide()

    chart.Marker = chart.plot:CreateTexture(nil, "OVERLAY")
    chart.Marker:SetSize(MARKER_SIZE, MARKER_SIZE)
    chart.Marker:SetColorTexture(LINE_COLOR[1], LINE_COLOR[2], LINE_COLOR[3])
    chart.Marker:Hide()

    function chart.OnSlotLeave(self)
        self.Crosshair:Hide()
        self.Marker:Hide()
    end

    local function ShowPoint(slot)
        chart.Crosshair:ClearAllPoints()
        chart.Crosshair:SetPoint("TOPLEFT", chart.plot, "TOPLEFT", slot.x, 0)
        chart.Crosshair:SetPoint("BOTTOMLEFT", chart.plot, "BOTTOMLEFT", slot.x, 0)
        chart.Crosshair:Show()
        chart.Marker:ClearAllPoints()
        chart.Marker:SetPoint("CENTER", chart.plot, "BOTTOMLEFT", slot.x, slot.y)
        chart.Marker:Show()

        GameTooltip:SetOwner(slot, "ANCHOR_TOP")
        onPoint(slot.point)
        GameTooltip:Show()
    end

    function chart.SetPoints(self, points)
        local count = #points
        self.Empty:SetShown(count < 2)
        if count == 0 then
            for _, label in ipairs({ self.TopLabel, self.MiddleLabel, self.BottomLabel, self.StartLabel, self.EndLabel }) do
                label:SetText("")
            end
            HideExtra(self.slots, 0)
            HideExtra(self.lines, 0)
            HideExtra(self.dots, 0)
            return
        end

        local low, high = ValueRange(points)
        self.TopLabel:SetText(ns.FormatMoney(high))
        self.MiddleLabel:SetText(ns.FormatMoney((high + low) / 2))
        self.BottomLabel:SetText(ns.FormatMoney(low))
        self.StartLabel:SetText(ns.FormatDay(points[1].from or points[1].t))
        self.EndLabel:SetText(ns.FormatDay(points[count].t))

        local slotWidth = self.plotWidth / count
        local showDots = count <= MAX_DOTS
        local previousX, previousY

        for index, point in ipairs(points) do
            local x = PointX(self, index, count)
            local y = (point.value - low) / (high - low) * self.plotHeight

            local slot = AcquireSlot(self, index, ShowPoint)
            slot.point, slot.x, slot.y = point, x, y
            PlaceSlot(self, slot, index, slotWidth)

            if previousX then
                local line = self.lines[index - 1]
                if not line then
                    line = self.plot:CreateLine(nil, "ARTWORK")
                    line:SetThickness(LINE_THICKNESS)
                    line:SetColorTexture(LINE_COLOR[1], LINE_COLOR[2], LINE_COLOR[3])
                    self.lines[index - 1] = line
                end
                line:SetStartPoint("BOTTOMLEFT", self.plot, previousX, previousY)
                line:SetEndPoint("BOTTOMLEFT", self.plot, x, y)
                line:Show()
            end
            previousX, previousY = x, y

            local dot = self.dots[index]
            if showDots then
                if not dot then
                    dot = self.plot:CreateTexture(nil, "ARTWORK")
                    dot:SetSize(DOT_SIZE, DOT_SIZE)
                    dot:SetColorTexture(LINE_COLOR[1], LINE_COLOR[2], LINE_COLOR[3])
                    self.dots[index] = dot
                end
                dot:ClearAllPoints()
                dot:SetPoint("CENTER", self.plot, "BOTTOMLEFT", x, y)
                dot:Show()
            end
        end
        HideExtra(self.slots, count)
        HideExtra(self.lines, count - 1)
        HideExtra(self.dots, showDots and count or 0)
    end
    return chart
end
