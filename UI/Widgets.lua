local _, ns = ...
local L = ns.L

local UI = {}
ns.UI = UI

-- Spacing shared by every tab, so that margins stay consistent.
UI.PADDING = 14
UI.GAP = 12
UI.CONTROL_HEIGHT = 26
UI.TILE_HEIGHT = 60

local HEADER_HEIGHT = 28
local ROW_HEIGHT = 26
local ROW_PADDING = 10
local COLUMN_GAP = 8
local ICON_SIZE = 20
local MARKER_SIZE = 8
local MARKER_GAP = 6
local SCROLLBAR_WIDTH = 22
local SEGMENT_PADDING = 12
local SORT_ARROW_ATLAS = "auctionhouse-ui-sortarrow"
local SORT_ARROW_GAP = 3
local UNKNOWN_ICON = 134400

-- Text and marks for a dark surface. Categories take hues in a fixed order.
UI.Colors = {
    accent = { 1, 0.82, 0 },
    text = { 0.941, 0.937, 0.925 },
    secondary = { 0.765, 0.761, 0.718 },
    muted = { 0.537, 0.529, 0.506 },
    gain = { 0.2, 0.75, 0.2 },
    loss = { 0.902, 0.404, 0.404 },
    category1 = { 0.224, 0.529, 0.898 }, -- Blue
    category2 = { 0.851, 0.349, 0.149 }, -- Orange
    category3 = { 0.098, 0.62, 0.439 }, -- Aqua
    category4 = { 0.788, 0.522, 0 }, -- Yellow
    category5 = { 0.835, 0.318, 0.506 }, -- Magenta
}
local Colors = UI.Colors

function UI.ColorForAmount(amount)
    if amount and amount > 0 then
        return Colors.gain
    elseif amount and amount < 0 then
        return Colors.loss
    end
    return nil
end

UI.PERIODS = {
    { value = 7, label = L["7 days"] },
    { value = 30, label = L["30 days"] },
    { value = 90, label = L["90 days"] },
    { value = 0, label = L["All time"] },
}

-- Tooltips ------------------------------------------------------------------

-- Battle pet links are not accepted by SetHyperlink on an item tooltip.
function UI.ShowItemTooltip(owner, itemID, link, name)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if link and link:find("|Hitem:", 1, true) then
        GameTooltip:SetHyperlink(link)
    elseif itemID then
        GameTooltip:SetItemByID(itemID)
    else
        GameTooltip:SetText(name or L["Unknown item"])
    end
end

-- A label and its value, in the colours every tooltip of the addon uses.
function UI.AddValueLine(tooltip, label, value)
    tooltip:AddDoubleLine(label, value, 0.8, 0.8, 0.8, 1, 1, 1)
end

function UI.AddMoneyLine(label, copper)
    UI.AddValueLine(GameTooltip, label, ns.FormatExactMoney(copper))
end

-- Where the price an auction is undercut by comes from.
function UI.AddOfferSourceLine(itemID)
    local offer = ns.Market.GetOffer(itemID)
    if offer and offer.source == "auctionator" then
        GameTooltip:AddLine(L["Source: Auctionator"], 0.8, 0.8, 0.8)
    else
        UI.AddValueLine(GameTooltip, L["AH scan"], ns.FormatDate(ns.Market.GetScannedAt()))
    end
end

local HOLDING_PLACES = {
    { key = "bags", label = L["Bags"] },
    { key = "bank", label = L["Bank"] },
    { key = "mail", label = L["Mail"] },
    { key = "auctions", label = L["AH"] },
}

-- Where a stock row's units are: one line per character, by name, then the warband bank.
function UI.AddHoldingLines(tooltip, row)
    local keys = {}
    for key in pairs(row.characters) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        local parts = {}
        for _, place in ipairs(HOLDING_PLACES) do
            local quantity = row.characters[key][place.key]
            if quantity then
                parts[#parts + 1] = place.label .. " " .. BreakUpLargeNumbers(quantity)
            end
        end
        UI.AddValueLine(tooltip, ns.ColoredCharacterName(key), table.concat(parts, ", "))
    end
    if row.warband > 0 then
        UI.AddValueLine(tooltip, L["Warband bank"], BreakUpLargeNumbers(row.warband))
    end
end

function UI.AddHint(frame, title, text)
    frame:EnableMouse(true)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(title)
        GameTooltip:AddLine(text, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- Cards and tiles -----------------------------------------------------------

-- A slightly raised surface with a hairline edge, to group what belongs together.
function UI.CreateCard(parent)
    local card = CreateFrame("Frame", nil, parent)

    local background = card:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(1, 1, 1, 0.035)

    local function Edge(pointA, pointB, width, height)
        local edge = card:CreateTexture(nil, "BORDER")
        edge:SetPoint(pointA, card, pointA)
        edge:SetPoint(pointB, card, pointB)
        if width then
            edge:SetWidth(width)
        else
            edge:SetHeight(height)
        end
        edge:SetColorTexture(1, 1, 1, 0.07)
    end
    Edge("TOPLEFT", "TOPRIGHT", nil, 1)
    Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    Edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
    Edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
    return card
end

-- spec: { key, label, icon, hint? }. tile:SetValue(text, color?) and tile:SetNote(text).
function UI.CreateTile(parent, spec, width)
    local tile = UI.CreateCard(parent)
    tile:SetSize(width, UI.TILE_HEIGHT)

    local strip = tile:CreateTexture(nil, "ARTWORK")
    strip:SetPoint("TOPLEFT", tile, "TOPLEFT")
    strip:SetPoint("BOTTOMLEFT", tile, "BOTTOMLEFT")
    strip:SetWidth(3)
    strip:SetColorTexture(Colors.accent[1], Colors.accent[2], Colors.accent[3], 0.8)

    local icon = tile:CreateTexture(nil, "ARTWORK")
    icon:SetSize(34, 34)
    icon:SetPoint("LEFT", tile, "LEFT", 14, 0)
    icon:SetTexture(spec.icon)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local textLeft = 14 + 34 + 10
    local label = tile:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", tile, "TOPLEFT", textLeft, -12)
    label:SetText(spec.label)

    local note = tile:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPRIGHT", tile, "TOPRIGHT", -10, -12)

    local value = tile:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
    value:SetPoint("BOTTOMLEFT", tile, "BOTTOMLEFT", textLeft, 11)
    value:SetPoint("BOTTOMRIGHT", tile, "BOTTOMRIGHT", -10, 11)
    value:SetJustifyH("LEFT")
    value:SetWordWrap(false)

    function tile.SetValue(_, text, color)
        local c = color or Colors.text
        value:SetText(text)
        value:SetTextColor(c[1], c[2], c[3])
    end
    function tile.SetNote(_, text)
        note:SetText(text)
    end

    if spec.hint then
        UI.AddHint(tile, spec.label, spec.hint)
    end
    return tile
end

local function TileWidth(perRow)
    return (UI.CONTENT_WIDTH - (perRow - 1) * UI.GAP) / perRow
end

-- Places tiles in rows across the content, from the top of the parent, in the order
-- of keys. Returns the height they take.
function UI.ArrangeTiles(parent, tiles, keys, perRow)
    local width = TileWidth(perRow)
    for index, key in ipairs(keys) do
        local column = (index - 1) % perRow
        local row = math.floor((index - 1) / perRow)
        local tile = tiles[key]
        tile:ClearAllPoints()
        tile:SetPoint("TOPLEFT", parent, "TOPLEFT", column * (width + UI.GAP), -row * (UI.TILE_HEIGHT + UI.GAP))
    end
    local rows = math.ceil(#keys / perRow)
    return rows * UI.TILE_HEIGHT + (rows - 1) * UI.GAP
end

-- Lays tiles out in rows across the content, starting at the top of the parent.
-- keys gives their order, the order of specs by default. Returns them by key, with
-- the height they took.
function UI.CreateTiles(parent, specs, perRow, keys)
    local tiles = {}
    local defaultKeys = {}
    for index, spec in ipairs(specs) do
        tiles[spec.key] = UI.CreateTile(parent, spec, TileWidth(perRow))
        defaultKeys[index] = spec.key
    end
    return tiles, UI.ArrangeTiles(parent, tiles, keys or defaultKeys, perRow)
end

-- Filters -------------------------------------------------------------------

-- options: array of { value, label }. onChange receives the selected value.
-- group.Select(value) selects without notifying; group.SetActive(bool) greys it out.
function UI.CreateSegments(parent, options, initial, onChange)
    local group = CreateFrame("Frame", nil, parent)
    group:SetHeight(UI.CONTROL_HEIGHT)

    local background = group:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(1, 1, 1, 0.05)

    local buttons = {}
    group.buttons = buttons

    function group.Select(value)
        for optionValue, button in pairs(buttons) do
            local selected = optionValue == value
            button.Selected:SetShown(selected)
            button.Underline:SetShown(selected)
            local c = selected and Colors.text or Colors.secondary
            button.Label:SetTextColor(c[1], c[2], c[3])
        end
    end

    function group.SetActive(active)
        group:SetAlpha(active and 1 or 0.4)
        for _, button in pairs(buttons) do
            button:SetEnabled(active)
        end
    end

    local offset = 0
    for _, option in ipairs(options) do
        local button = CreateFrame("Button", nil, group)
        button.Label = button:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        button.Label:SetPoint("CENTER", button, "CENTER")
        button.Label:SetText(option.label)

        local width = button.Label:GetStringWidth() + 2 * SEGMENT_PADDING
        button:SetSize(width, UI.CONTROL_HEIGHT)
        button:SetPoint("LEFT", group, "LEFT", offset, 0)

        button.Selected = button:CreateTexture(nil, "BACKGROUND")
        button.Selected:SetAllPoints()
        button.Selected:SetColorTexture(Colors.accent[1], Colors.accent[2], Colors.accent[3], 0.16)

        button.Underline = button:CreateTexture(nil, "ARTWORK")
        button.Underline:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT")
        button.Underline:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT")
        button.Underline:SetHeight(2)
        button.Underline:SetColorTexture(Colors.accent[1], Colors.accent[2], Colors.accent[3])

        local hover = button:CreateTexture(nil, "HIGHLIGHT")
        hover:SetAllPoints()
        hover:SetColorTexture(1, 1, 1, 0.06)

        button:SetScript("OnClick", function()
            group.Select(option.value)
            onChange(option.value)
        end)
        buttons[option.value] = button
        offset = offset + width
    end
    group:SetWidth(offset)
    group.Select(initial)
    return group
end

function UI.CreateSearchBox(parent, onChange)
    local box = CreateFrame("EditBox", nil, parent, "SearchBoxTemplate")
    box:SetSize(160, UI.CONTROL_HEIGHT)
    box:SetAutoFocus(false)
    box:HookScript("OnTextChanged", function(self)
        onChange(self:GetText())
    end)
    return box
end

-- Case-insensitive, and an empty search matches everything.
function UI.MatchesSearch(name, search)
    if not search or search == "" then
        return true
    end
    return (name or ""):lower():find(search:lower(), 1, true) ~= nil
end

-- Sortable table ------------------------------------------------------------

local TableMixin = {}

function TableMixin:ApplySort()
    local rows, column, ascending = self.rows, self.sortColumn, self.sortAscending
    local value = column.sort or function(row)
        return row[column.key]
    end
    table.sort(rows, function(a, b)
        local va, vb = value(a), value(b)
        if va == vb then
            return a.order < b.order
        end
        if va == nil then
            return false
        elseif vb == nil then
            return true
        end
        if ascending then
            return va < vb
        end
        return va > vb
    end)
    for position, row in ipairs(rows) do
        row.position = position
    end
    self.ScrollBox:SetDataProvider(CreateDataProvider(rows), ScrollBoxConstants.RetainScrollPosition)
    self.Empty:SetShown(#rows == 0)
    self:UpdateHeaders()
end

function TableMixin:UpdateHeaders()
    for _, column in ipairs(self.columns) do
        local arrow = column.header.Arrow
        arrow:SetShown(column == self.sortColumn)
        if self.sortAscending then
            arrow:SetTexCoord(0, 1, 1, 0)
        else
            arrow:SetTexCoord(0, 1, 0, 1)
        end
    end
end

function TableMixin:SetRows(rows)
    for index, row in ipairs(rows) do
        row.order = index
    end
    self.rows = rows
    self:ApplySort()
end

function TableMixin:SortBy(key, ascending)
    for _, column in ipairs(self.columns) do
        if column.key == key then
            self.sortColumn = column
            self.sortAscending = ascending
            self:ApplySort()
            return
        end
    end
end

local function BuildRow(tbl, row)
    row.Stripe = row:CreateTexture(nil, "BACKGROUND")
    row.Stripe:SetAllPoints()
    row.Stripe:SetColorTexture(1, 1, 1, 0.025)

    local hover = row:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(Colors.accent[1], Colors.accent[2], Colors.accent[3], 0.1)

    row.cells = {}
    row.markers = {}
    local x = ROW_PADDING
    for index, column in ipairs(tbl.columns) do
        x = x + (column.gapBefore or 0)
        local textX, textWidth = x, column.width
        if column.item then
            row.Icon = row:CreateTexture(nil, "ARTWORK")
            row.Icon:SetSize(ICON_SIZE, ICON_SIZE)
            row.Icon:SetPoint("LEFT", row, "LEFT", x, 0)
            row.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            textX = x + ICON_SIZE + MARKER_GAP
            textWidth = column.width - ICON_SIZE - MARKER_GAP
        elseif column.marker then
            local marker = row:CreateTexture(nil, "ARTWORK")
            marker:SetSize(MARKER_SIZE, MARKER_SIZE)
            marker:SetPoint("LEFT", row, "LEFT", x, 0)
            row.markers[index] = marker
            textX = x + MARKER_SIZE + MARKER_GAP
            textWidth = column.width - MARKER_SIZE - MARKER_GAP
        end
        local cell = row:CreateFontString(nil, "ARTWORK", column.item and "GameFontHighlight" or "GameFontHighlightSmall")
        cell:SetPoint("LEFT", row, "LEFT", textX, 0)
        cell:SetWidth(textWidth)
        cell:SetJustifyH(column.align or "LEFT")
        cell:SetWordWrap(false)
        row.cells[index] = cell
        x = x + column.width + COLUMN_GAP
    end

    if tbl.onEnter then
        row:SetScript("OnEnter", function(self)
            tbl.onEnter(self, self.data)
        end)
        row:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)
    end
end

local function InitRow(tbl, row, data)
    if not row.cells then
        BuildRow(tbl, row)
    end
    row.data = data
    row.Stripe:SetShown(data.position % 2 == 0)
    for index, column in ipairs(tbl.columns) do
        local cell = row.cells[index]
        local color
        if column.item then
            local name, quality, icon = ns.GetItemDetails(data.itemID)
            row.Icon:SetTexture(icon or UNKNOWN_ICON)
            cell:SetText(data.name or name or L["Unknown item"])
            local qualityColor = quality and ITEM_QUALITY_COLORS[quality]
            color = qualityColor and { qualityColor.r, qualityColor.g, qualityColor.b } or nil
        else
            cell:SetText(column.text(data))
            color = column.color and column.color(data) or nil
        end
        color = color or Colors.text
        cell:SetTextColor(color[1], color[2], color[3])

        local marker = row.markers[index]
        if marker then
            local markerColor = column.marker(data) or Colors.muted
            marker:SetColorTexture(markerColor[1], markerColor[2], markerColor[3])
        end
    end
end

-- spec.columns: array of
--   { key, title, width, align = "RIGHT"?, text = fn(row), sort = fn(row)?,
--     color = fn(row)?, marker = fn(row)?, item = true?, ascendingFirst = true?,
--     gapBefore = extra space on its left? }
-- An item column draws the icon and quality-coloured name of row.itemID. A marker
-- is a small coloured square before the text, which always remains to name it.
-- spec.sort = { key, ascending }; spec.onEnter = fn(rowFrame, row)
function UI.CreateTable(parent, spec)
    local tbl = UI.CreateCard(parent)
    for name, method in pairs(TableMixin) do
        tbl[name] = method
    end
    tbl.columns = spec.columns
    tbl.onEnter = spec.onEnter
    tbl.rows = {}
    tbl.sortAscending = spec.sort.ascending

    local band = tbl:CreateTexture(nil, "BACKGROUND")
    band:SetPoint("TOPLEFT", tbl, "TOPLEFT")
    band:SetPoint("TOPRIGHT", tbl, "TOPRIGHT")
    band:SetHeight(HEADER_HEIGHT)
    band:SetColorTexture(Colors.accent[1], Colors.accent[2], Colors.accent[3], 0.06)

    local separator = tbl:CreateTexture(nil, "BORDER")
    separator:SetPoint("TOPLEFT", band, "BOTTOMLEFT")
    separator:SetPoint("TOPRIGHT", band, "BOTTOMRIGHT")
    separator:SetHeight(1)
    separator:SetColorTexture(Colors.accent[1], Colors.accent[2], Colors.accent[3], 0.3)

    local x = ROW_PADDING
    for _, column in ipairs(spec.columns) do
        if column.key == spec.sort.key then
            tbl.sortColumn = column
        end
        x = x + (column.gapBefore or 0)
        local header = CreateFrame("Button", nil, tbl)
        header:SetSize(column.width, HEADER_HEIGHT)
        header:SetPoint("TOPLEFT", tbl, "TOPLEFT", x, 0)
        header.Text = header:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        header.Text:SetText(column.title)

        -- Anchored to the title rather than measured, on the side that stays free.
        header.Arrow = header:CreateTexture(nil, "OVERLAY")
        header.Arrow:SetAtlas(SORT_ARROW_ATLAS, true)
        if column.align == "RIGHT" then
            header.Text:SetPoint("RIGHT", header, "RIGHT")
            header.Arrow:SetPoint("RIGHT", header.Text, "LEFT", -SORT_ARROW_GAP, 0)
        else
            header.Text:SetPoint("LEFT", header, "LEFT")
            header.Arrow:SetPoint("LEFT", header.Text, "RIGHT", SORT_ARROW_GAP, 0)
        end

        header:SetScript("OnClick", function()
            if tbl.sortColumn == column then
                tbl.sortAscending = not tbl.sortAscending
            else
                tbl.sortColumn = column
                tbl.sortAscending = column.ascendingFirst or false
            end
            tbl:ApplySort()
        end)
        column.header = header
        x = x + column.width + COLUMN_GAP
    end

    tbl.ScrollBox = CreateFrame("Frame", nil, tbl, "WowScrollBoxList")
    tbl.ScrollBox:SetPoint("TOPLEFT", tbl, "TOPLEFT", 0, -HEADER_HEIGHT - 1)
    tbl.ScrollBox:SetPoint("BOTTOMRIGHT", tbl, "BOTTOMRIGHT", -SCROLLBAR_WIDTH, 1)

    tbl.ScrollBar = CreateFrame("EventFrame", nil, tbl, "WowTrimScrollBar")
    tbl.ScrollBar:SetPoint("TOPLEFT", tbl.ScrollBox, "TOPRIGHT", 3, -3)
    tbl.ScrollBar:SetPoint("BOTTOMLEFT", tbl.ScrollBox, "BOTTOMRIGHT", 3, 3)

    local view = CreateScrollBoxListLinearView(0, 0, 0, 0)
    view:SetElementExtent(ROW_HEIGHT)
    view:SetElementInitializer("Button", function(row, data)
        InitRow(tbl, row, data)
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(tbl.ScrollBox, tbl.ScrollBar, view)

    tbl.Empty = tbl:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    tbl.Empty:SetPoint("CENTER", tbl.ScrollBox, "CENTER")
    tbl.Empty:SetText(L["Nothing to show yet."])

    tbl:UpdateHeaders()
    return tbl
end
