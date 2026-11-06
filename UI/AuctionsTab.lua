local _, ns = ...
local L = ns.L
local UI = ns.UI
local Colors = UI.Colors

local KINDS = {
    post = { label = L["Listing"], color = Colors.category1 },
    bought = { label = L["Purchase"], color = Colors.category2 },
    sold = { label = L["Sale"], color = Colors.category3 },
    expired = { label = L["Expiry"], color = Colors.category4 },
    cancel = { label = L["Cancellation"], color = Colors.category5 },
}

local FILTERS = {
    { value = "all", label = L["All"] },
    { value = "sold", label = L["Sales"] },
    { value = "bought", label = L["Purchases"] },
    { value = "post", label = L["Listings"] },
    { value = "expired", label = L["Expired"] },
    { value = "cancel", label = L["Cancelled"] },
    { value = "active", label = L["Active"] },
}

local filter = "all"
local search = ""
local listTable = nil

local function HistoryRow(entry)
    local quantity = entry.qty or 1
    local unit = entry.unit
    if entry.kind == "sold" or entry.kind == "bought" then
        unit = (entry.gross or 0) / quantity
    end
    local kind = KINDS[entry.kind]
    return {
        entry = entry,
        when = entry.t,
        whenText = ns.FormatDate(entry.t),
        kindText = kind.label,
        kindColor = kind.color,
        itemID = entry.itemID,
        link = entry.link,
        name = entry.name,
        qty = quantity,
        unit = unit,
        amount = ns.Stats.Net(entry),
        char = entry.char,
    }
end

-- Live auctions sort on the same column as history, with the end time as "when".
-- lowest: the cheaper unit price on sale when the auction is undercut.
local function ActiveRow(auction, characterKey, lowest)
    local remaining = auction.expiresAt and (auction.expiresAt - time())
    local kindText, kindColor = L["On sale"], Colors.category1
    if auction.sold then
        kindText, kindColor = L["Sold, mail pending"], Colors.category3
    elseif lowest then
        kindText, kindColor = L["Undercut"], Colors.loss
    end
    return {
        auction = auction,
        lowest = lowest,
        when = auction.expiresAt,
        whenText = remaining and ns.FormatDuration(remaining) or "-",
        kindText = kindText,
        kindColor = kindColor,
        itemID = auction.itemID,
        link = auction.link,
        name = auction.name,
        qty = auction.qty,
        unit = auction.unit,
        amount = auction.unit and auction.unit * auction.qty or nil,
        isListedValue = true,
        char = characterKey,
    }
end

local function BuildRows()
    local characterFilter = UI.GetCharacterFilter()
    local rows = {}
    if filter == "active" then
        local undercut = ns.Auctions.GetUndercut()
        for _, item in ipairs(ns.Auctions.GetAll(characterFilter)) do
            local row = ActiveRow(item.auction, item.char, undercut[item.auction])
            if UI.MatchesSearch(row.name, search) then
                rows[#rows + 1] = row
            end
        end
    else
        for _, entry in ipairs(ns.db.ledger) do
            if (filter == "all" or entry.kind == filter)
                and (not characterFilter or entry.char == characterFilter)
                and UI.MatchesSearch(entry.name, search) then
                rows[#rows + 1] = HistoryRow(entry)
            end
        end
    end
    return rows
end

local function ShowRowTooltip(owner, row)
    UI.ShowItemTooltip(owner, row.itemID, row.link, row.name)
    GameTooltip:AddLine(" ")
    local entry = row.entry
    if entry and entry.kind == "sold" then
        UI.AddMoneyLine(L["Sale price"], entry.gross)
        UI.AddMoneyLine(L["Auction house cut"], -(entry.cut or 0))
        UI.AddMoneyLine(L["Deposit refunded"], entry.deposit or 0)
        UI.AddMoneyLine(L["Received"], ns.Stats.Net(entry))
        if entry.other then
            GameTooltip:AddDoubleLine(L["Buyer"], entry.other, 0.8, 0.8, 0.8, 1, 1, 1)
        end
    elseif entry and entry.kind == "bought" then
        UI.AddMoneyLine(L["Paid"], entry.gross)
        if entry.other then
            GameTooltip:AddDoubleLine(L["Seller"], entry.other, 0.8, 0.8, 0.8, 1, 1, 1)
        end
    elseif entry and entry.kind == "post" then
        UI.AddMoneyLine(L["Deposit paid"], entry.deposit or 0)
    elseif entry and entry.kind == "cancel" then
        UI.AddMoneyLine(L["Cancellation cost"], entry.cost or 0)
    elseif row.auction then
        local character = ns.db.characters[row.char]
        GameTooltip:AddDoubleLine(L["Last synced"], ns.FormatDate(character and character.auctionsSyncedAt), 0.8, 0.8, 0.8, 1, 1, 1)
        if row.lowest then
            UI.AddMoneyLine(L["Lowest on the AH"], row.lowest)
            GameTooltip:AddDoubleLine(L["AH scan"], ns.FormatDate(ns.Market.GetScannedAt()), 0.8, 0.8, 0.8, 1, 1, 1)
        end
    end
    GameTooltip:Show()
end

local function Refresh()
    listTable:SetRows(BuildRows())
end

UI.RegisterTab({
    key = "auctions",
    title = L["Auctions"],
    Build = function(pane, toolbar)
        local segments = UI.CreateSegments(toolbar, FILTERS, filter, function(value)
            filter = value
            Refresh()
        end)
        segments:SetPoint("LEFT", toolbar, "LEFT")

        local searchBox = UI.CreateSearchBox(toolbar, function(text)
            search = text
            Refresh()
        end)
        searchBox:SetPoint("RIGHT", toolbar, "RIGHT")

        listTable = UI.CreateTable(pane, {
            columns = {
                { key = "when", title = L["Date"], width = 76, text = function(row) return row.whenText end },
                { key = "kindText", title = L["Type"], width = 138, ascendingFirst = true,
                    text = function(row) return row.kindText end,
                    marker = function(row) return row.kindColor end },
                { key = "name", title = L["Item"], width = 262, item = true, ascendingFirst = true,
                    sort = function(row) return row.name and row.name:lower() end },
                { key = "qty", title = L["Qty"], width = 40, align = "RIGHT", text = function(row) return ns.FormatCount(row.qty) end },
                { key = "unit", title = L["Unit price"], width = 110, align = "RIGHT", text = function(row) return ns.FormatMoney(row.unit) end },
                { key = "amount", title = L["Amount"], width = 112, align = "RIGHT",
                    text = function(row)
                        return row.isListedValue and ns.FormatMoney(row.amount) or ns.FormatSignedMoney(row.amount)
                    end,
                    color = function(row)
                        return not row.isListedValue and UI.ColorForAmount(row.amount) or nil
                    end },
                { key = "char", title = L["Character"], width = 84, gapBefore = 10, ascendingFirst = true,
                    sort = function(row) return ns.CharacterName(row.char) end,
                    text = function(row) return ns.ColoredCharacterName(row.char) end },
            },
            sort = { key = "when", ascending = false },
            onEnter = ShowRowTooltip,
        })
        listTable:SetAllPoints(pane)
    end,
    Refresh = Refresh,
})
