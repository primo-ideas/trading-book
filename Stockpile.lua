local _, ns = ...

-- The stock is every tradable item the account holds, wherever it sits: bags,
-- bank, warband bank, mail and live auctions. Bound items are left out since
-- they cannot be sold. Banks can only be read while open, so their last known
-- contents are kept between visits.
local Stockpile = {}
ns.Stockpile = Stockpile

local SCAN_DELAY_SECONDS = 1

local BAG_IDS = {
    Enum.BagIndex.Backpack,
    Enum.BagIndex.Bag_1,
    Enum.BagIndex.Bag_2,
    Enum.BagIndex.Bag_3,
    Enum.BagIndex.Bag_4,
    Enum.BagIndex.ReagentBag,
}

local bankOpen = false

local function CountContainers(bagIDs)
    local counts = {}
    for _, bagID in ipairs(bagIDs) do
        for slot = 1, C_Container.GetContainerNumSlots(bagID) do
            local info = C_Container.GetContainerItemInfo(bagID, slot)
            if info and not info.isBound then
                counts[info.itemID] = (counts[info.itemID] or 0) + info.stackCount
                ns.RememberItem(info.itemID, info.itemName, info.quality, info.iconFileID)
            end
        end
    end
    return counts
end

-- History -------------------------------------------------------------------

-- Series only grow when a value changes, and keep one point per day at most.
function Stockpile.RecordPoint(series, day, value)
    local last = series[#series]
    if last and last.value == value then
        return
    end
    if last and last.day == day then
        local before = series[#series - 1]
        if before and before.value == value then
            series[#series] = nil
        else
            last.value = value
        end
    else
        series[#series + 1] = { day = day, value = value }
    end
end

local RecordPoint = Stockpile.RecordPoint

local function ValueAt(series, day)
    for i = #series, 1, -1 do
        if series[i].day <= day then
            return series[i].value
        end
    end
end

local function RecordHistory()
    local db = ns.db
    local today = ns.DayKey(time())
    db.historyStartDay = db.historyStartDay or today

    local totals = {}
    for _, row in ipairs(Stockpile.GetRows()) do
        totals[row.itemID] = row.total
    end
    for itemID, total in pairs(totals) do
        db.stockHistory[itemID] = db.stockHistory[itemID] or {}
        RecordPoint(db.stockHistory[itemID], today, total)
    end
    for itemID, series in pairs(db.stockHistory) do
        if not totals[itemID] then
            RecordPoint(series, today, 0)
        end
    end
end

-- Change in total stock of an item over the last days, or nil when the addon was
-- not running that long ago. An item with no record back then was simply not held.
function Stockpile.GetChange(itemID, days)
    local db = ns.db
    local target = ns.DayKey(time() - days * 86400)
    if not db.historyStartDay or target < db.historyStartDay then
        return nil
    end
    local series = db.stockHistory[itemID]
    if not series or #series == 0 then
        return 0
    end
    return series[#series].value - (ValueAt(series, target) or 0)
end

-- Reading -------------------------------------------------------------------

-- Rows by item ID, for every item or only one. Without a character filter, totals
-- span the whole account including the warband bank.
local function CollectRows(characterKey, onlyItemID)
    local db = ns.db
    local now = time()
    local rowsByItem = {}

    local function Add(itemID, place, quantity, key)
        if not itemID or quantity == 0 then
            return
        end
        local row = rowsByItem[itemID]
        if not row then
            row = { itemID = itemID, total = 0, bags = 0, bank = 0, warband = 0, mail = 0, auctions = 0, characters = {} }
            rowsByItem[itemID] = row
        end
        row.total = row.total + quantity
        row[place] = row[place] + quantity
        if key then
            local holdings = row.characters[key]
            if not holdings then
                holdings = {}
                row.characters[key] = holdings
            end
            holdings[place] = (holdings[place] or 0) + quantity
        end
    end

    -- Looking a single item up directly keeps tooltips cheap, as they redraw often.
    local function AddCounts(counts, place, key)
        if onlyItemID then
            Add(onlyItemID, place, counts[onlyItemID] or 0, key)
            return
        end
        for itemID, quantity in pairs(counts) do
            Add(itemID, place, quantity, key)
        end
    end

    for key, character in pairs(db.characters) do
        if not characterKey or key == characterKey then
            for _, place in ipairs({ "bags", "bank", "mail" }) do
                AddCounts(character.stock[place], place, key)
            end
            for _, auction in ipairs(character.auctions) do
                if not auction.sold and ns.Auctions.IsLive(auction, now)
                    and (not onlyItemID or auction.itemID == onlyItemID) then
                    Add(auction.itemID, "auctions", auction.qty, key)
                end
            end
        end
    end
    if not characterKey then
        AddCounts(db.warband.items, "warband")
    end
    return rowsByItem
end

function Stockpile.GetRows(characterKey)
    local rows = {}
    for _, row in pairs(CollectRows(characterKey)) do
        rows[#rows + 1] = row
    end
    return rows
end

-- The same row as GetRows for one item across the whole account, or nil when none is held.
function Stockpile.GetItemRow(itemID)
    return CollectRows(nil, itemID)[itemID]
end

-- Money held on characters, plus the warband bank for the whole account.
function Stockpile.GetGold(characterKey)
    local db = ns.db
    if characterKey then
        return db.characters[characterKey] and db.characters[characterKey].money or 0
    end
    local total = db.warband.money or 0
    for _, character in pairs(db.characters) do
        total = total + (character.money or 0)
    end
    return total
end

function Stockpile.GetValue(characterKey)
    local total = 0
    for _, row in ipairs(Stockpile.GetRows(characterKey)) do
        local unit = ns.Stats.GetUnitPrice(row.itemID)
        if unit then
            total = total + unit * row.total
        end
    end
    return total
end

-- Scanning ------------------------------------------------------------------

local function Scan()
    if not ns.playerKey then
        return -- Bag events can fire before login.
    end
    local character = ns.GetCharacter()
    local now = time()
    character.stock.bags = CountContainers(BAG_IDS)

    if bankOpen then
        if C_Bank.CanViewBank(Enum.BankType.Character) then
            character.stock.bank = CountContainers(C_Bank.FetchPurchasedBankTabIDs(Enum.BankType.Character))
            character.stock.bankScannedAt = now
        end
        if C_Bank.CanViewBank(Enum.BankType.Account) then
            local warband = ns.db.warband
            warband.items = CountContainers(C_Bank.FetchPurchasedBankTabIDs(Enum.BankType.Account))
            warband.money = C_Bank.FetchDepositedMoney(Enum.BankType.Account)
            warband.scannedAt = now
        end
    end

    RecordHistory()
    ns.Gold.Record()
    ns.Publish("STOCK_CHANGED")
end

local function RequestScan()
    ns.Debounce("stockScan", SCAN_DELAY_SECONDS, Scan)
end

function Stockpile.SetMailContents(contents)
    local character = ns.GetCharacter()
    character.stock.mail = contents
    character.stock.mailScannedAt = time()
    RequestScan()
end

local function UpdateMoney()
    if ns.playerKey then
        ns.GetCharacter().money = GetMoney()
        RequestScan()
    end
end

ns.OnEvent("PLAYER_LOGIN", function()
    local character = ns.GetCharacter()
    character.class = select(2, UnitClass("player"))
    UpdateMoney()
end)

ns.OnEvent("PLAYER_MONEY", UpdateMoney)
ns.OnEvent("BAG_UPDATE_DELAYED", RequestScan)
ns.OnEvent("PLAYERBANKSLOTS_CHANGED", RequestScan)
ns.OnEvent("PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED", RequestScan)
ns.Subscribe("AUCTIONS_CHANGED", RequestScan)

ns.OnEvent("BANKFRAME_OPENED", function()
    bankOpen = true
    RequestScan()
end)

ns.OnEvent("BANKFRAME_CLOSED", function()
    bankOpen = false
end)
