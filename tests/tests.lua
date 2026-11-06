local Mock = dofile("tests/wow_mock.lua")

local output = print -- The mock replaces print to capture the addon's chat messages.
local passed, failed = 0, 0
local tests = {}

-- Every language of the client with its own words. enUS is the keys, enGB only reorders dates.
local LOCALES = { "deDE", "esES", "esMX", "frFR", "itIT", "koKR", "ptBR", "ruRU", "zhCN", "zhTW" }

local function test(name, fn)
    table.insert(tests, { name = name, fn = fn })
end

local function eq(actual, expected, label)
    if actual ~= expected then
        error((label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function near(actual, expected, tolerance, label)
    if math.abs(actual - expected) > tolerance then
        error((label or "value") .. ": expected about " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function location(bag, slot)
    return { bag = bag, slot = slot }
end

local function soldMail(name, bid, options)
    options = options or {}
    local count = options.count
    return {
        subject = "Auction successful: " .. name .. (count and (" (" .. count .. ")") or ""),
        money = bid + (options.deposit or 0) - (options.cut or 0),
        daysLeft = options.daysLeft or 30,
        invoice = {
            type = "seller", name = name, player = options.buyer, bid = bid, buyout = bid,
            deposit = options.deposit or 0, consignment = options.cut or 0, count = count,
            needsBody = options.needsBody,
        },
    }
end

local function kinds(ledger)
    local names = {}
    for _, entry in ipairs(ledger) do
        table.insert(names, entry.kind)
    end
    return table.concat(names, ",")
end

-- Listings ------------------------------------------------------------------

test("a commodity listing is recorded only once the server creates it", function()
    local _ = Mock.Boot()
    Mock.SetBagItem(0, 1, 1001, "Herb", 200)
    C_AuctionHouse.PostCommodity(location(0, 1), 2, 50, 3000)
    eq(#TradingBookDB.ledger, 0, "before creation")

    Mock.Fire("AUCTION_HOUSE_AUCTION_CREATED", 555)
    eq(#TradingBookDB.ledger, 1, "after creation")
    local entry = TradingBookDB.ledger[1]
    eq(entry.kind, "post")
    eq(entry.itemID, 1001)
    eq(entry.qty, 50)
    eq(entry.unit, 3000)
    eq(entry.deposit, 500)
    eq(entry.char, "Primo-Hyjal")
end)

test("posting several items at once records one listing with the full quantity", function()
    Mock.Boot()
    Mock.SetBagItem(0, 1, 2001, "Sword", 1)
    C_AuctionHouse.PostItem(location(0, 1), 3, 3, nil, 90000)
    Mock.Fire("AUCTION_HOUSE_AUCTION_CREATED", 1)
    Mock.Fire("AUCTION_HOUSE_AUCTION_CREATED", 2)
    Mock.Fire("AUCTION_HOUSE_AUCTION_CREATED", 3)
    eq(#TradingBookDB.ledger, 1)
    eq(TradingBookDB.ledger[1].qty, 3)
    eq(TradingBookDB.ledger[1].deposit, 300)
end)

test("backing out of a price warning records nothing", function()
    Mock.Boot()
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    C_AuctionHouse.PostCommodity(location(0, 1), 1, 10, 3000)
    C_AuctionHouse.CancelSell()
    Mock.Fire("AUCTION_HOUSE_AUCTION_CREATED", 9)
    eq(#TradingBookDB.ledger, 0)
end)

test("a confirmed price warning records the listing once", function()
    Mock.Boot()
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    C_AuctionHouse.PostCommodity(location(0, 1), 1, 10, 3000)
    C_AuctionHouse.ConfirmPostCommodity(location(0, 1), 1, 10, 3000)
    Mock.Fire("AUCTION_HOUSE_AUCTION_CREATED", 9)
    eq(#TradingBookDB.ledger, 1)
end)

test("a refused listing does not attach to the next one", function()
    Mock.Boot()
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    Mock.SetBagItem(0, 2, 1002, "Ore", 10)
    C_AuctionHouse.PostCommodity(location(0, 1), 1, 10, 3000)
    Mock.Fire("AUCTION_HOUSE_SHOW_ERROR", 1)
    C_AuctionHouse.PostCommodity(location(0, 2), 1, 5, 700)
    Mock.Fire("AUCTION_HOUSE_AUCTION_CREATED", 9)
    eq(#TradingBookDB.ledger, 1)
    eq(TradingBookDB.ledger[1].itemID, 1002)
end)

test("a listing that never completes expires instead of matching a later one", function()
    local _, world = Mock.Boot()
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    C_AuctionHouse.PostCommodity(location(0, 1), 1, 10, 3000)
    world.now = world.now + 120
    Mock.Fire("AUCTION_HOUSE_AUCTION_CREATED", 9)
    eq(#TradingBookDB.ledger, 0)
end)

-- Cancellations and owned auctions -------------------------------------------

test("a cancellation records its cost and item, and ends the auction", function()
    local ns, world = Mock.Boot()
    world.owned = { { auctionID = 77, itemKey = { itemID = 2001 }, itemLink = "|Hitem:2001|h[Sword]|h",
        status = 0, quantity = 1, timeLeftSeconds = 3600, buyoutAmount = 90000 } }
    Mock.Fire("OWNED_AUCTIONS_UPDATED")
    eq(#ns.Auctions.GetAll(), 1)

    world.cancelCosts[77] = 450
    C_AuctionHouse.CancelAuction(77)
    eq(#TradingBookDB.ledger, 0, "before server confirmation")
    Mock.Fire("AUCTION_CANCELED", 77)

    local entry = TradingBookDB.ledger[1]
    eq(entry.kind, "cancel")
    eq(entry.cost, 450)
    eq(entry.name, "Sword")
    eq(#ns.Auctions.GetAll(), 0)
end)

test("owned auctions are requested when the auction house opens, once it has settled", function()
    local _, world = Mock.Boot()
    Mock.Fire("AUCTION_HOUSE_SHOW")
    eq(world.ownedQueries, 0, "not immediately")
    Mock.RunTimers()
    eq(world.ownedQueries, 1)

    Mock.Fire("AUCTION_HOUSE_SHOW")
    Mock.Fire("AUCTION_HOUSE_CLOSED")
    Mock.RunTimers()
    eq(world.ownedQueries, 1, "not after closing")
end)

test("ended auctions stop counting as live", function()
    local ns, world = Mock.Boot()
    world.owned = { { auctionID = 1, itemKey = { itemID = 1001 }, status = 0, quantity = 5, timeLeftSeconds = 60, buyoutAmount = 10 } }
    Mock.Fire("OWNED_AUCTIONS_UPDATED")
    eq(#ns.Auctions.GetAll(), 1)
    world.now = world.now + 61
    eq(#ns.Auctions.GetAll(), 0)
end)

-- Mail ----------------------------------------------------------------------

test("a sale takes its amounts and buyer from the invoice", function()
    local ns, world = Mock.Boot()
    ns.RememberItem(1001, "Herb")
    world.mails = { soldMail("Herb", 100000, { cut = 5000, deposit = 200, count = 20, buyer = "Bob" }) }
    Mock.Fire("MAIL_SHOW")
    TakeInboxMoney(1)
    local entry = TradingBookDB.ledger[1]
    eq(entry.kind, "sold")
    eq(entry.itemID, 1001)
    eq(entry.qty, 20)
    eq(entry.gross, 100000)
    eq(entry.cut, 5000)
    eq(entry.deposit, 200)
    eq(entry.other, "Bob")
    eq(ns.Stats.Net(entry), 100000 + 200 - 5000)
end)

test("a sale is dated from the mail's remaining lifetime, not its collection", function()
    local _, world = Mock.Boot()
    world.mails = { soldMail("Herb", 100, { daysLeft = 27 }) }
    Mock.Fire("MAIL_SHOW")
    TakeInboxMoney(1)
    eq(TradingBookDB.ledger[1].t, world.now - 3 * 86400)
end)

test("identical mails are all recorded when collected in a row", function()
    local _, world = Mock.Boot()
    for _ = 1, 3 do
        table.insert(world.mails, soldMail("Herb", 100, { cut = 5 }))
    end
    Mock.Fire("MAIL_SHOW")
    for _ = 1, 3 do
        TakeInboxMoney(1)
        Mock.CompleteTake()
    end
    eq(#TradingBookDB.ledger, 3)
    eq(#world.mails, 0)
end)

test("collecting the same mail twice before the server answers counts once", function()
    local _, world = Mock.Boot()
    world.mails = { soldMail("Herb", 100), soldMail("Ore", 200) }
    Mock.Fire("MAIL_SHOW")
    TakeInboxMoney(1)
    TakeInboxMoney(1)
    Mock.Fire("MAIL_INBOX_UPDATE") -- Unrelated refresh, mail still there.
    TakeInboxMoney(1)
    eq(#TradingBookDB.ledger, 1)
end)

test("an expired auction with several attachments counts once, with their total", function()
    local _, world = Mock.Boot()
    world.mails = { {
        subject = "Auction expired: Herb",
        items = {
            { name = "Herb", id = 1001, count = 200, link = "|Hitem:1001|h[Herb]|h" },
            { name = "Herb", id = 1001, count = 50, link = "|Hitem:1001|h[Herb]|h" },
        },
    } }
    Mock.Fire("MAIL_SHOW")
    TakeInboxItem(1, 2)
    Mock.CompleteTake()
    TakeInboxItem(1, 1)
    Mock.CompleteTake()
    eq(kinds(TradingBookDB.ledger), "expired")
    eq(TradingBookDB.ledger[1].qty, 250)
    eq(TradingBookDB.ledger[1].itemID, 1001)
end)

test("a purchase uses the invoice price and the attached item", function()
    local _, world = Mock.Boot()
    world.mails = { {
        subject = "Auction won: Herb (20)",
        items = { { name = "Herb", id = 1001, count = 20, link = "|Hitem:1001|h[Herb]|h" } },
        invoice = { type = "buyer", name = "Herb", player = "Alice", bid = 60000, buyout = 60000, deposit = 0, consignment = 0, count = 20, commodity = true },
    } }
    Mock.Fire("MAIL_SHOW")
    AutoLootMailItem(1)
    local entry = TradingBookDB.ledger[1]
    eq(entry.kind, "bought")
    eq(entry.gross, 60000)
    eq(entry.qty, 20)
    eq(entry.itemID, 1001)
    eq(entry.other, "Alice")
end)

test("collection failing on full bags can be retried without double counting", function()
    local _, world = Mock.Boot()
    world.mails = { {
        subject = "Auction expired: Herb",
        items = { { name = "Herb", id = 1001, count = 20 } },
    }, soldMail("Ore", 100) }
    Mock.Fire("MAIL_SHOW")

    AutoLootMailItem(1)
    eq(#TradingBookDB.ledger, 1, "recorded on take")
    Mock.FailTake()
    eq(#TradingBookDB.ledger, 0, "undone on failure")

    AutoLootMailItem(1)
    Mock.CompleteTake()
    eq(kinds(TradingBookDB.ledger), "expired")
end)

test("a failure after a successful take does not undo that take", function()
    local _, world = Mock.Boot()
    world.mails = { soldMail("Herb", 100), soldMail("Ore", 200) }
    Mock.Fire("MAIL_SHOW")
    TakeInboxMoney(1)
    Mock.CompleteTake()
    Mock.Fire("MAIL_FAILED", 0) -- Say, a mail being sent bounces.
    eq(#TradingBookDB.ledger, 1)
end)

test("a failure after a successful partial take does not undo the expiry", function()
    local _, world = Mock.Boot()
    world.mails = { {
        subject = "Auction expired: Herb",
        items = { { name = "Herb", id = 1001, count = 200 }, { name = "Herb", id = 1001, count = 50 } },
    } }
    Mock.Fire("MAIL_SHOW")
    TakeInboxItem(1, 2)
    Mock.CompleteTake() -- The mail stays: only MAIL_SUCCESS tells the take worked.
    Mock.Fire("MAIL_FAILED", 0)
    eq(#TradingBookDB.ledger, 1)
end)

test("a mail leaving the inbox counts as taken even without a success event", function()
    local _, world = Mock.Boot()
    world.mails = { soldMail("Herb", 100), soldMail("Ore", 200) }
    Mock.Fire("MAIL_SHOW")
    TakeInboxMoney(1)
    table.remove(world.mails, 1)
    Mock.Fire("MAIL_INBOX_UPDATE")
    Mock.Fire("MAIL_FAILED", 0)
    eq(#TradingBookDB.ledger, 1)
end)

test("a pending sale notice and ordinary mail are not recorded", function()
    local _, world = Mock.Boot()
    world.mails = {
        { subject = "Sale pending: Herb", invoice = { type = "seller_temp_invoice", name = "Herb", bid = 100, deposit = 0, consignment = 5 } },
        { subject = "Hello from a friend", money = 500 },
    }
    Mock.Fire("MAIL_SHOW")
    TakeInboxMoney(2)
    TakeInboxMoney(1)
    eq(#TradingBookDB.ledger, 0)
end)

test("an invoice is trusted even when the subject line is not recognised", function()
    local _, world = Mock.Boot()
    local mail = soldMail("Herb", 100, { cut = 5 })
    mail.subject = "A subject in another wording"
    world.mails = { mail }
    Mock.Fire("MAIL_SHOW")
    TakeInboxMoney(1)
    eq(kinds(TradingBookDB.ledger), "sold")
    eq(TradingBookDB.ledger[1].cut, 5)
end)

test("an invoice needing the mail body is read at collection, not while scanning", function()
    local _, world = Mock.Boot()
    world.mails = { soldMail("Herb", 100, { cut = 5, needsBody = true }) }
    Mock.Fire("MAIL_SHOW")
    Mock.Fire("MAIL_INBOX_UPDATE")
    eq(world.bodiesLoaded, 0, "scanning must not mark mail as read")
    TakeInboxMoney(1)
    eq(world.bodiesLoaded, 1)
    eq(TradingBookDB.ledger[1].cut, 5)
end)

test("without any invoice a sale falls back on the subject and the mail's money", function()
    local _, world = Mock.Boot()
    world.mails = { { subject = "Auction successful: Herb (20)", money = 950 } }
    Mock.Fire("MAIL_SHOW")
    TakeInboxMoney(1)
    local entry = TradingBookDB.ledger[1]
    eq(entry.name, "Herb")
    eq(entry.qty, 20)
    eq(entry.gross, 950)
end)

test("subjects are recognised in French, including special characters", function()
    local _, world = Mock.Boot({
        locale = "frFR",
        subjects = {
            sold = "Vente aux enchères réussie : %s",
            won = "Enchère remportée (HV) : %s",
            expired = "Vente aux enchères expirée - %1$s",
        },
    })
    world.mails = {
        { subject = "Vente aux enchères réussie : Herbe (5)", money = 95 },
        { subject = "Enchère remportée (HV) : Herbe", items = { { name = "Herbe", id = 1001, count = 1 } } },
        { subject = "Vente aux enchères expirée - Herbe", items = { { name = "Herbe", id = 1001, count = 2 } } },
    }
    Mock.Fire("MAIL_SHOW")
    TakeInboxItem(3, 1)
    TakeInboxItem(2, 1)
    TakeInboxMoney(1)
    eq(kinds(TradingBookDB.ledger), "expired,bought,sold")
    eq(TradingBookDB.ledger[3].qty, 5)
end)

test("a sale collected from mail ends the matching live auction", function()
    local ns, world = Mock.Boot()
    ns.RememberItem(1001, "Herb")
    world.owned = { { auctionID = 1, itemKey = { itemID = 1001 }, status = 0, quantity = 50, timeLeftSeconds = 9000, buyoutAmount = 10 } }
    Mock.Fire("OWNED_AUCTIONS_UPDATED")
    world.mails = { soldMail("Herb", 100, { count = 20 }) }
    Mock.Fire("MAIL_SHOW")
    TakeInboxMoney(1)
    eq(ns.Auctions.GetAll()[1].auction.qty, 30)
end)

test("a sale already marked sold is consumed before auctions still on sale", function()
    local ns, world = Mock.Boot()
    ns.RememberItem(1001, "Herb")
    world.owned = {
        { auctionID = 1, itemKey = { itemID = 1001 }, status = 0, quantity = 50, timeLeftSeconds = 9000, buyoutAmount = 10 },
        { auctionID = 2, itemKey = { itemID = 1001 }, status = 1, quantity = 20, timeLeftSeconds = 3000, buyoutAmount = 10 },
    }
    Mock.Fire("OWNED_AUCTIONS_UPDATED")
    world.mails = { soldMail("Herb", 100, { count = 20 }) }
    Mock.Fire("MAIL_SHOW")
    TakeInboxMoney(1)
    local live = ns.Auctions.GetAll()
    eq(#live, 1)
    eq(live[1].auction.qty, 50)
end)

-- Stock ---------------------------------------------------------------------

local function findRow(rows, itemID)
    for _, row in ipairs(rows) do
        if row.itemID == itemID then
            return row
        end
    end
end

test("stock counts every location and leaves bound items out", function()
    local ns, world = Mock.Boot()
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    Mock.SetBagItem(5, 1, 1001, "Herb", 5)
    Mock.SetBagItem(1, 1, 3001, "Soulbound Ring", 1, { isBound = true })
    Mock.SetBagItem(6, 1, 1001, "Herb", 100)
    Mock.SetBagItem(12, 1, 1001, "Herb", 1000)
    world.mails = { { subject = "Hi", items = { { name = "Herb", id = 1001, count = 7 } } } }
    world.owned = { { auctionID = 1, itemKey = { itemID = 1001 }, status = 0, quantity = 40, timeLeftSeconds = 9000, buyoutAmount = 10 } }

    Mock.Fire("BANKFRAME_OPENED")
    Mock.Fire("MAIL_SHOW")
    Mock.Fire("OWNED_AUCTIONS_UPDATED")
    Mock.RunTimers()

    local row = findRow(ns.Stockpile.GetRows(), 1001)
    eq(row.bags, 15, "bags")
    eq(row.bank, 100, "bank")
    eq(row.warband, 1000, "warband")
    eq(row.mail, 7, "mail")
    eq(row.auctions, 40, "auctions")
    eq(row.total, 1162, "total")
    eq(findRow(ns.Stockpile.GetRows(), 3001), nil, "bound item")
end)

test("bank contents are remembered when the bank is closed", function()
    local ns = Mock.Boot()
    Mock.SetBagItem(6, 1, 1001, "Herb", 100)
    Mock.Fire("BANKFRAME_OPENED")
    Mock.RunTimers()
    Mock.Fire("BANKFRAME_CLOSED")

    Mock.SetBagItem(6, 1, 1001, "Herb", 1) -- Would be wrong if read while closed.
    Mock.Fire("BAG_UPDATE_DELAYED")
    Mock.RunTimers()
    eq(findRow(ns.Stockpile.GetRows(), 1001).bank, 100)
end)

test("an inaccessible warband bank keeps its last known contents", function()
    local ns, world = Mock.Boot()
    Mock.SetBagItem(12, 1, 1001, "Herb", 500)
    Mock.Fire("BANKFRAME_OPENED")
    Mock.RunTimers()

    world.canViewBank[Enum.BankType.Account] = false
    world.bags[12] = nil
    Mock.Fire("PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED", 12, 1)
    Mock.RunTimers()
    eq(findRow(ns.Stockpile.GetRows(), 1001).warband, 500)
end)

test("sold auctions no longer count as stock", function()
    local ns, world = Mock.Boot()
    world.owned = { { auctionID = 1, itemKey = { itemID = 1001 }, status = 1, quantity = 40, timeLeftSeconds = 3000, buyoutAmount = 10 } }
    Mock.Fire("OWNED_AUCTIONS_UPDATED")
    Mock.RunTimers()
    eq(findRow(ns.Stockpile.GetRows(), 1001), nil)
end)

test("other characters are summed, and filtered out on request", function()
    local ns = Mock.Boot()
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    Mock.Fire("BAG_UPDATE_DELAYED")
    Mock.RunTimers()
    TradingBookDB.characters["Alt-Hyjal"] = { money = 777, stock = { bags = { [1001] = 5 }, bank = {}, mail = {} }, auctions = {} }

    eq(findRow(ns.Stockpile.GetRows(), 1001).total, 15, "account")
    eq(findRow(ns.Stockpile.GetRows("Primo-Hyjal"), 1001).total, 10, "filtered")
    eq(findRow(ns.Stockpile.GetRows(), 1001).characters["Alt-Hyjal"].bags, 5, "breakdown")
end)

test("stock history keeps one point per day and only records changes", function()
    local ns, world = Mock.Boot()
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    Mock.Fire("BAG_UPDATE_DELAYED")
    Mock.RunTimers()
    Mock.SetBagItem(0, 1, 1001, "Herb", 12)
    Mock.Fire("BAG_UPDATE_DELAYED")
    Mock.RunTimers()
    eq(#TradingBookDB.stockHistory[1001], 1, "same day")
    eq(TradingBookDB.stockHistory[1001][1].value, 12)

    world.now = world.now + 86400
    Mock.Fire("BAG_UPDATE_DELAYED")
    Mock.RunTimers()
    eq(#TradingBookDB.stockHistory[1001], 1, "unchanged next day")

    world.now = world.now + 86400
    world.bags[0][1] = nil
    Mock.Fire("BAG_UPDATE_DELAYED")
    Mock.RunTimers()
    eq(#TradingBookDB.stockHistory[1001], 2, "gone")
    eq(TradingBookDB.stockHistory[1001][2].value, 0, "recorded as zero")
    eq(ns.Stockpile.GetChange(1001, 1), -12, "change")
end)

test("stock change is unknown before the addon was running", function()
    local ns, world = Mock.Boot()
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    Mock.Fire("BAG_UPDATE_DELAYED")
    Mock.RunTimers()
    eq(ns.Stockpile.GetChange(1001, 7), nil, "too early")

    world.now = world.now + 8 * 86400
    Mock.SetBagItem(0, 1, 1001, "Herb", 25)
    Mock.Fire("BAG_UPDATE_DELAYED")
    Mock.RunTimers()
    eq(ns.Stockpile.GetChange(1001, 7), 15, "known")
end)

test("gold sums characters and the warband bank", function()
    local ns, world = Mock.Boot()
    world.money = 1000
    world.warbandMoney = 500
    Mock.Fire("PLAYER_MONEY")
    Mock.Fire("BANKFRAME_OPENED")
    Mock.RunTimers()
    TradingBookDB.characters["Alt-Hyjal"] = { money = 250, stock = { bags = {}, bank = {}, mail = {} }, auctions = {} }
    eq(ns.Stockpile.GetGold(), 1750, "account")
    eq(ns.Stockpile.GetGold("Primo-Hyjal"), 1000, "character")
end)

-- Gold history ----------------------------------------------------------------

local function dayKey(ns, world, offset)
    return ns.DayKey(world.now + offset * 86400)
end

-- Adds a holder with a history given as { [day offset] = value }, oldest first.
local function goldSeries(ns, world, values)
    local series = {}
    for _, item in ipairs(values) do
        table.insert(series, { day = dayKey(ns, world, item[1]), value = item[2] })
    end
    series[1].opening = values.opening or series[1].value
    return series
end

local function setCharacterGold(ns, world, key, values, class)
    TradingBookDB.characters[key] = {
        class = class,
        money = values[#values][2],
        moneyHistory = goldSeries(ns, world, values),
        stock = { bags = {}, bank = {}, mail = {} },
        auctions = {},
    }
end

local function setWarbandGold(ns, world, values)
    TradingBookDB.warband.scannedAt = world.now
    TradingBookDB.warband.money = values[#values][2]
    TradingBookDB.warband.moneyHistory = goldSeries(ns, world, values)
end

-- The player's own history, replacing what login recorded.
local PLAYER_KEY = "Primo-Hyjal"

test("each holder records its own gold, one point a day at most", function()
    local ns, world = Mock.Boot({ money = 1000 })
    world.money = 1500
    Mock.Fire("PLAYER_MONEY")
    Mock.RunTimers()
    local history = TradingBookDB.characters[PLAYER_KEY].moneyHistory
    eq(#history, 1, "same day")
    eq(history[1].value, 1500)

    world.now = world.now + 86400
    world.money = 2000
    Mock.Fire("PLAYER_MONEY")
    Mock.RunTimers()
    eq(#history, 2, "next day")

    eq(TradingBookDB.warband.moneyHistory, nil, "warband not seen yet")
    world.warbandMoney = 700
    Mock.Fire("BANKFRAME_OPENED")
    Mock.RunTimers()
    eq(TradingBookDB.warband.moneyHistory[1].value, 700, "warband once seen")
end)

test("gains on the very first day count, against the amount held at first sight", function()
    local ns, world = Mock.Boot({ money = 1000 })
    world.money = 1500
    Mock.Fire("PLAYER_MONEY")
    Mock.RunTimers()
    local analysis = ns.Gold.Analyze({ days = 7, char = PLAYER_KEY })
    eq(analysis.current, 1500)
    eq(analysis.change, 500)
    eq(#analysis.points, 1, "only the day it has been tracked")
    eq(analysis.points[1].delta, 500)
end)

test("the first login on an alt is not a gain", function()
    local ns, world = Mock.Boot({ money = 1000 })
    Mock.RunTimers()
    world.now = world.now + 86400
    Mock.Fire("PLAYER_MONEY")
    Mock.RunTimers()
    eq(ns.Gold.Analyze({ days = 7 }).change, 0, "before the alt")

    setCharacterGold(ns, world, "Alt-Hyjal", { { 0, 50000 } })
    local analysis = ns.Gold.Analyze({ days = 7 })
    eq(analysis.current, 51000, "the alt's gold is counted")
    eq(analysis.change, 0, "but it is no gain")

    setCharacterGold(ns, world, "Alt-Hyjal", { { 0, 50500 }, opening = 50000 })
    eq(ns.Gold.Analyze({ days = 7 }).change, 500, "what the alt earns afterwards is")
end)

test("moving gold between holders is no gain", function()
    local ns, world = Mock.Boot({ money = 5000 })
    setCharacterGold(ns, world, PLAYER_KEY, { { -2, 5000 }, { 0, 3000 } })
    setWarbandGold(ns, world, { { -2, 1000 }, { 0, 3000 } })
    eq(ns.Gold.Analyze({ days = 7 }).change, 0, "whole account")
    eq(ns.Gold.Analyze({ days = 7, holders = "characters" }).change, -2000, "characters")
    eq(ns.Gold.Analyze({ days = 7, holders = "warband" }).change, 2000, "warband")
end)

test("the analysis finds the best and worst days, the peak, and how days went", function()
    local ns, world = Mock.Boot()
    setCharacterGold(ns, world, PLAYER_KEY, { { -5, 1000 }, { -4, 1500 }, { -3, 1200 }, { -1, 2000 }, { 0, 1900 } })
    local a = ns.Gold.Analyze({ days = 30, char = PLAYER_KEY })

    eq(#a.points, 6, "starts when tracking did, not 30 days ago")
    eq(a.current, 1900)
    eq(a.change, 900)
    near(a.percent, 0.9, 0.0001, "percent")
    near(a.perDay, 150, 0.0001, "per day")
    eq(a.best.delta, 800, "best")
    eq(a.best.day, dayKey(ns, world, -1), "best day")
    eq(a.worst.delta, -300, "worst")
    eq(a.worst.day, dayKey(ns, world, -3), "worst day")
    eq(a.peak.value, 2000, "peak")
    eq(a.peak.day, dayKey(ns, world, -1), "peak day")
    eq(a.upDays, 2, "days up")
    eq(a.downDays, 2, "days down")
    eq(a.trackedSince, dayKey(ns, world, -5))

    local total = 0
    for _, point in ipairs(a.points) do
        total = total + point.delta
    end
    eq(total, a.change, "daily changes add up")
end)

test("a period measures against the day before it", function()
    local ns, world = Mock.Boot()
    setCharacterGold(ns, world, PLAYER_KEY, { { -5, 1000 }, { -3, 1200 }, { -1, 2000 }, { 0, 1900 } })
    local a = ns.Gold.Analyze({ days = 2, char = PLAYER_KEY })
    eq(#a.points, 2)
    eq(a.change, 700, "from 1200, held two days ago")
    eq(a.best.delta, 800)
    eq(a.worst.delta, -100)
end)

test("a flat period has no best or worst day, and no gold has no percentage", function()
    local ns, world = Mock.Boot()
    setCharacterGold(ns, world, PLAYER_KEY, { { -3, 1000 } })
    local flat = ns.Gold.Analyze({ days = 7, char = PLAYER_KEY })
    eq(flat.best, nil)
    eq(flat.worst, nil)
    eq(flat.change, 0)

    setCharacterGold(ns, world, PLAYER_KEY, { { -3, 0 }, { 0, 500 } })
    eq(ns.Gold.Analyze({ days = 7, char = PLAYER_KEY }).percent, nil)
end)

test("gold can be filtered by character or kind of holder", function()
    local ns, world = Mock.Boot()
    setCharacterGold(ns, world, PLAYER_KEY, { { -2, 1000 }, { 0, 1100 } })
    setCharacterGold(ns, world, "Alt-Hyjal", { { -2, 2000 }, { 0, 2200 } })
    setWarbandGold(ns, world, { { -2, 4000 }, { 0, 4400 } })

    eq(ns.Gold.Analyze({ days = 7 }).current, 7700, "all")
    eq(ns.Gold.Analyze({ days = 7, holders = "all" }).change, 700, "all, explicit")
    eq(ns.Gold.Analyze({ days = 7, holders = "characters" }).current, 3300, "characters")
    eq(ns.Gold.Analyze({ days = 7, holders = "warband" }).current, 4400, "warband")
    eq(ns.Gold.Analyze({ days = 7, char = "Alt-Hyjal" }).current, 2200, "one character")
    eq(ns.Gold.Analyze({ days = 7, char = "Alt-Hyjal", holders = "warband" }).current, 2200, "a character wins over the holder filter")
end)

test("the warband bank is left out until it has been seen", function()
    local ns = Mock.Boot({ money = 100 })
    local a = ns.Gold.Analyze({ days = 7, holders = "warband" })
    eq(#a.points, 0)
    eq(a.current, 0)
    eq(#ns.Gold.GetBreakdown({ days = 7, holders = "warband" }), 0)
end)

test("an old alt without history still counts for its known gold", function()
    local ns, world = Mock.Boot({ money = 100 })
    TradingBookDB.characters["Old-Hyjal"] = { money = 900, stock = { bags = {}, bank = {}, mail = {} }, auctions = {} }
    local a = ns.Gold.Analyze({ days = 7 })
    eq(a.current, 1000)
    eq(a.change, 0)
end)

test("income splits between auctions and the rest, on the same scope", function()
    local ns, world = Mock.Boot()
    setCharacterGold(ns, world, PLAYER_KEY, { { -2, 1000 }, { 0, 5000 } })
    setCharacterGold(ns, world, "Alt-Hyjal", { { -2, 1000 }, { 0, 1000 } })
    ns.Ledger.Add({ kind = "sold", itemID = 1, qty = 1, gross = 3000, cut = 150, deposit = 0, t = world.now - 86400 })
    ns.Ledger.Add({ kind = "sold", itemID = 1, qty = 1, gross = 700, cut = 0, deposit = 0, t = world.now, char = "Alt-Hyjal" })

    local all = ns.Gold.Analyze({ days = 7 })
    eq(all.auctionNet, 2850 + 700)
    eq(all.otherIncome, 4000 - 3550)

    local one = ns.Gold.Analyze({ days = 7, char = PLAYER_KEY })
    eq(one.auctionNet, 2850, "this character's sales only")
    eq(one.otherIncome, 1150)

    eq(ns.Gold.Analyze({ days = 7, holders = "warband" }).auctionNet, nil, "not for gold merely stored")
    eq(ns.Gold.Analyze({ days = 7, holders = "characters" }).auctionNet, nil, "transfers would pass for income")
end)

test("long histories are shortened without losing the end or the changes", function()
    local ns, world = Mock.Boot()
    local values = {}
    for offset = -199, 0 do
        table.insert(values, { offset, 1000 + (offset + 200) * 10 + (offset % 7) * 100 })
    end
    setCharacterGold(ns, world, PLAYER_KEY, values)
    local a = ns.Gold.Analyze({ days = 0, char = PLAYER_KEY })
    eq(#a.points, 200, "all time")

    local sampled = ns.Gold.Downsample(a.points, 90)
    eq(#sampled <= 90, true, "shortened: " .. #sampled)
    eq(sampled[#sampled].day, dayKey(ns, world, 0), "still ends today")
    eq(sampled[#sampled].value, a.current)
    eq(sampled[1].from, a.points[1].t, "still starts on the first day")
    local total = 0
    for _, point in ipairs(sampled) do
        total = total + point.delta
    end
    eq(total, a.change, "changes still add up")

    eq(ns.Gold.Downsample(a.points, 500), a.points, "left alone when short enough")
end)

test("the breakdown gives each holder its gold, share and change", function()
    local ns, world = Mock.Boot()
    setCharacterGold(ns, world, PLAYER_KEY, { { -2, 1000 }, { 0, 1500 } })
    setCharacterGold(ns, world, "Alt-Hyjal", { { 0, 500 } })
    setWarbandGold(ns, world, { { -2, 2000 } })

    local rows = ns.Gold.GetBreakdown({ days = 7 })
    eq(#rows, 3)
    local byKey, share = {}, 0
    for _, row in ipairs(rows) do
        byKey[row.key] = row
        share = share + row.share
    end
    near(share, 1, 0.0001, "shares")
    eq(byKey[PLAYER_KEY].gold, 1500)
    eq(byKey[PLAYER_KEY].change, 500)
    eq(byKey["Alt-Hyjal"].change, 0, "first seen today: no gain")
    eq(byKey.warband.isWarband, true)
    near(byKey.warband.share, 0.5, 0.0001, "warband share")
end)

test("saved data from the first version loses its old gold total without harm", function()
    local ns = Mock.Boot({ money = 100, db = { goldHistory = { { day = 20260101, value = 5 } } } })
    eq(TradingBookDB.goldHistory, nil)
    eq(ns.Gold.Analyze({ days = 7 }).current, 100)
end)

-- Stats ---------------------------------------------------------------------

local function seedLedger(ns, world)
    local now = world.now
    ns.Ledger.Add({ kind = "post", t = now - 2 * 86400, itemID = 1001, name = "Herb", qty = 100, unit = 1000, deposit = 500 })
    ns.Ledger.Add({ kind = "sold", t = now - 1 * 86400, itemID = 1001, name = "Herb", qty = 60, gross = 60000, cut = 3000, deposit = 300 })
    ns.Ledger.Add({ kind = "expired", t = now, itemID = 1001, name = "Herb", qty = 30 })
    ns.Ledger.Add({ kind = "cancel", t = now, itemID = 1001, name = "Herb", qty = 10, cost = 150 })
    ns.Ledger.Add({ kind = "bought", t = now, itemID = 2001, name = "Sword", qty = 1, gross = 20000 })
    ns.Ledger.Add({ kind = "sold", t = now - 40 * 86400, itemID = 2001, name = "Sword", qty = 1, gross = 90000, cut = 4500, deposit = 0, char = "Alt-Hyjal" })
end

test("the summary reconciles: net equals sales minus purchases minus fees", function()
    local ns, world = Mock.Boot()
    seedLedger(ns, world)
    local s = ns.Stats.Summarize({ since = ns.Stats.PeriodStart(7) })
    eq(s.gross, 60000, "sales")
    eq(s.spent, 20000, "purchases")
    eq(s.fees, 3000 + (500 - 300) + 150, "fees")
    eq(s.net, 36650, "net")
    eq(s.net, s.gross - s.spent - s.fees, "identity")
end)

test("the net matches the actual change in the player's money", function()
    local ns, world = Mock.Boot()
    seedLedger(ns, world)
    local gold = 0
    gold = gold - 500             -- Deposit when listing.
    gold = gold + 60000 + 300 - 3000 -- Sale mail.
    gold = gold - 150             -- Cancellation.
    gold = gold - 20000           -- Purchase.
    gold = gold + 90000 - 4500    -- The alt's old sale.
    eq(ns.Stats.Summarize().net, gold)
end)

test("sell-through is by quantity across sold, expired and cancelled", function()
    local ns, world = Mock.Boot()
    seedLedger(ns, world)
    local s = ns.Stats.Summarize({ since = ns.Stats.PeriodStart(7) })
    near(s.sellThrough, 60 / 100, 0.0001, "sell-through")
    eq(ns.Stats.Summarize({ since = world.now + 1 }).sellThrough, nil, "no data")
end)

test("the summary filters by period and character, and breaks down by item", function()
    local ns, world = Mock.Boot()
    seedLedger(ns, world)
    eq(ns.Stats.Summarize({ since = ns.Stats.PeriodStart(7) }).items[2001].soldQty, 0, "old sale outside period")
    eq(ns.Stats.Summarize().items[2001].soldQty, 1, "all time")
    eq(ns.Stats.Summarize({ char = "Alt-Hyjal" }).gross, 90000, "character")

    local herb = ns.Stats.Summarize().items[1001]
    eq(herb.soldQty, 60)
    eq(herb.net, -500 + 60000 + 300 - 3000 - 150)
end)

test("the series covers each day of the period, including empty ones", function()
    local ns, world = Mock.Boot()
    seedLedger(ns, world)
    local bars, bucketDays = ns.Stats.BuildSeries({ since = ns.Stats.PeriodStart(7) }, 60)
    eq(#bars, 7, "bars")
    eq(bucketDays, 1, "bucket")
    eq(bars[5].net, -500, "two days ago")
    eq(bars[6].net, 57300, "yesterday")
    eq(bars[7].net, -20150, "today")
    eq(bars[1].net, 0, "empty day")
    eq(os.date("%d/%m", bars[7].from), os.date("%d/%m", world.now), "last bar is today")
end)

test("long periods are grouped without losing money", function()
    local ns, world = Mock.Boot()
    seedLedger(ns, world)
    local bars, bucketDays = ns.Stats.BuildSeries({ since = ns.Stats.PeriodStart(90) }, 60)
    eq(bucketDays, 2, "bucket")
    eq(#bars, 45, "bars")
    local total = 0
    for _, bar in ipairs(bars) do
        total = total + bar.net
    end
    eq(total, ns.Stats.Summarize({ since = ns.Stats.PeriodStart(90) }).net)
end)

test("an all-time series starts at the first entry, and is empty without any", function()
    local ns, world = Mock.Boot()
    local bars = ns.Stats.BuildSeries({}, 60)
    eq(#bars, 0, "empty")
    ns.Ledger.Add({ kind = "sold", t = world.now - 2 * 86400, gross = 100, qty = 1 })
    eq(#ns.Stats.BuildSeries({}, 60), 3, "from first entry")
end)

-- Walks a whole year so that it covers the clock changes of whatever time zone runs it.
test("day buckets hold on every day of the year, including clock changes", function()
    local ns, world = Mock.Boot()
    for day = 1, 365 do
        world.now = os.time({ year = 2027, month = 1, day = day, hour = 12 })
        TradingBookDB.ledger = {}
        ns.Ledger.Add({ kind = "sold", t = os.time({ year = 2027, month = 1, day = day - 1, hour = 23 }), gross = 100, qty = 1 })
        ns.Ledger.Add({ kind = "sold", t = os.time({ year = 2027, month = 1, day = day, hour = 1 }), gross = 200, qty = 1 })
        local bars = ns.Stats.BuildSeries({ since = ns.Stats.PeriodStart(3) }, 60)
        eq(#bars, 3, "bars on day " .. day)
        eq(bars[1].net, 0, "two days ago, on day " .. day)
        eq(bars[2].net, 100, "yesterday, on day " .. day)
        eq(bars[3].net, 200, "today, on day " .. day)
    end
end)

-- Auction house scan helpers -----------------------------------------------------

-- Opens the auction house and lets the automatic scan, if any, be requested.
local function openAuctionHouse()
    Mock.Fire("AUCTION_HOUSE_SHOW")
    Mock.RunTimers()
end

-- The server's answer to a scan, read to the end.
local function answerScan(auctions)
    Mock.SetReplicate(auctions)
    Mock.Fire("REPLICATE_ITEM_LIST_UPDATE")
    Mock.RunTimers()
end

local function auction(itemID, count, buyout, saleStatus)
    return { itemID = itemID, count = count, buyout = buyout, saleStatus = saleStatus }
end

test("item value prefers Auctionator, then the auction house scan, then recent sales", function()
    local ns, world = Mock.Boot()
    ns.Ledger.Add({ kind = "sold", itemID = 1001, qty = 10, gross = 1000 })
    local price, source = ns.Stats.GetUnitPrice(1001)
    eq(price, 100)
    eq(source, "sales")
    eq(ns.Stats.GetUnitPrice(9999), nil, "unknown item")

    openAuctionHouse()
    answerScan({ auction(1001, 2, 600) })
    local seenAt
    price, source, seenAt = ns.Stats.GetUnitPrice(1001)
    eq(price, 300)
    eq(source, "scan")
    eq(seenAt, world.now)

    rawset(_G, "Auctionator", { API = { v1 = { GetAuctionPriceByItemID = function(caller, id)
        eq(caller, "TradingBook")
        return id == 1001 and 555 or nil
    end } } })
    price, source = ns.Stats.GetUnitPrice(1001)
    rawset(_G, "Auctionator", nil)
    eq(price, 555)
    eq(source, "auctionator")
end)

test("a broken Auctionator does not break Trading Book", function()
    local ns = Mock.Boot()
    ns.Ledger.Add({ kind = "sold", itemID = 1001, qty = 1, gross = 100 })
    rawset(_G, "Auctionator", { API = { v1 = { GetAuctionPriceByItemID = function() error("boom") end } } })
    local price, source = ns.Stats.GetUnitPrice(1001)
    rawset(_G, "Auctionator", nil)
    eq(price, 100)
    eq(source, "sales")
end)

test("the sale price average drops out of the recent window", function()
    local ns, world = Mock.Boot()
    ns.Ledger.Add({ kind = "sold", t = world.now - 100 * 86400, itemID = 1001, qty = 1, gross = 100 })
    eq(ns.Stats.GetUnitPrice(1001), nil)
end)

-- Ledger --------------------------------------------------------------------

test("the ledger drops its oldest entries past the cap", function()
    local db = { ledger = {} }
    for i = 1, 20005 do
        db.ledger[i] = { kind = "expired", t = i, qty = 1 }
    end
    Mock.Boot({ db = db })
    eq(#TradingBookDB.ledger, 20000)
    eq(TradingBookDB.ledger[1].t, 6)
end)

test("existing saved data survives a reload", function()
    local ns = Mock.Boot()
    Mock.SetBagItem(6, 1, 1001, "Herb", 10)
    Mock.Fire("BANKFRAME_OPENED")
    Mock.RunTimers()
    ns.Ledger.Add({ kind = "sold", itemID = 1001, qty = 1, gross = 100 })
    local saved = TradingBookDB

    local reloaded = Mock.Boot({ db = saved })
    eq(#TradingBookDB.ledger, 1)
    eq(findRow(reloaded.Stockpile.GetRows(), 1001).bank, 10)
end)

-- Interface -----------------------------------------------------------------

local function renderedTexts(tableFrame)
    local texts = {}
    for _, row in ipairs(tableFrame.ScrollBox.rendered) do
        local cells = {}
        for _, cell in ipairs(row.cells) do
            table.insert(cells, cell.text)
        end
        table.insert(texts, table.concat(cells, "|"))
    end
    return texts
end

-- Finds a frame's children built by the tabs through the registry the mock keeps.
local function captureTables(ns)
    local tables = {}
    local create = ns.UI.CreateTable
    ns.UI.CreateTable = function(...)
        local tbl = create(...)
        table.insert(tables, tbl)
        return tbl
    end
    return tables
end

local function captureSegments(ns)
    local segments = {}
    local create = ns.UI.CreateSegments
    ns.UI.CreateSegments = function(parent, options, initial, onChange)
        table.insert(segments, onChange)
        return create(parent, options, initial, onChange)
    end
    return segments
end

test("the window opens on every tab, with and without data", function()
    local ns, world = Mock.Boot()
    ns.UI.Toggle()
    ns.UI.Open("stock")
    ns.UI.Open("stats")
    ns.UI.Open("auctions")
    eq(TradingBookMainFrame:IsShown(), true)

    seedLedger(ns, world)
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    Mock.Fire("BAG_UPDATE_DELAYED")
    Mock.RunTimers()
    ns.UI.Open("stock")
    ns.UI.Open("stats")

    ns.UI.Toggle()
    eq(TradingBookMainFrame:IsShown(), false, "toggled off")
    ns.UI.Toggle()
    eq(TradingBookMainFrame:IsShown(), true, "toggled on")
end)

test("the auctions tab lists history, filters it, and sorts by column", function()
    local ns, world = Mock.Boot()
    local tables = captureTables(ns)
    local segments = captureSegments(ns)
    seedLedger(ns, world)
    ns.UI.Open("auctions")
    local list = tables[1]

    eq(#list.rows, 6, "all")
    eq(list.rows[1].when >= list.rows[2].when, true, "newest first")
    eq(list.rows[#list.rows].entry.t, world.now - 40 * 86400, "oldest last")

    segments[1]("sold")
    eq(#list.rows, 2, "sales")
    segments[1]("all")

    list.columns[6].header.scripts.OnClick()
    eq(list.sortColumn.key, "amount")
    eq(list.rows[1].amount, 90000 - 4500, "largest amount first")
    list.columns[6].header.scripts.OnClick()
    eq(list.rows[1].amount, -20000, "reversed")

    local rendered = renderedTexts(list)
    eq(#rendered, 6, "rows rendered")
end)

test("row tooltips explain the amounts of each kind of entry", function()
    local ns, world = Mock.Boot()
    local tables = captureTables(ns)
    seedLedger(ns, world)
    ns.UI.Open("auctions")
    for _, row in ipairs(tables[1].ScrollBox.rendered) do
        row.scripts.OnEnter(row)
        row.scripts.OnLeave(row)
    end
    local found = false
    for _, line in ipairs(GameTooltip.lines) do
        if line == "Auction house cut=-3000c" then
            found = true
        end
    end
    eq(found, true, "cut shown as a deduction")
end)

test("the active filter lists live auctions with their remaining time", function()
    local ns, world = Mock.Boot()
    local tables = captureTables(ns)
    local segments = captureSegments(ns)
    world.owned = {
        { auctionID = 1, itemKey = { itemID = 1001 }, itemLink = "|Hitem:1001|h[Herb]|h", status = 0, quantity = 5, timeLeftSeconds = 7200, buyoutAmount = 100 },
        { auctionID = 2, itemKey = { itemID = 1002 }, itemLink = "|Hitem:1002|h[Ore]|h", status = 1, quantity = 2, timeLeftSeconds = 1800, buyoutAmount = 50 },
    }
    Mock.Fire("OWNED_AUCTIONS_UPDATED")
    ns.UI.Open("auctions")
    segments[1]("active")

    local rows = tables[1].rows
    eq(#rows, 2)
    local byName = {}
    for _, row in ipairs(rows) do byName[row.name] = row end
    eq(byName.Herb.amount, 500, "unit price times quantity")
    eq(byName.Herb.whenText, "2 h")
    eq(byName.Ore.kindText, "Sold, mail pending")
    for _, row in ipairs(tables[1].ScrollBox.rendered) do
        row.scripts.OnEnter(row)
    end
end)

test("the search box filters by name, ignoring case and pattern characters", function()
    local ns, world = Mock.Boot()
    local tables = captureTables(ns)
    local boxes = {}
    local createBox = ns.UI.CreateSearchBox
    ns.UI.CreateSearchBox = function(parent, onChange)
        table.insert(boxes, onChange)
        return createBox(parent, onChange)
    end
    seedLedger(ns, world)
    ns.UI.Open("auctions")

    boxes[1]("SWOR")
    eq(#tables[1].rows, 2)
    boxes[1]("%w[")
    eq(#tables[1].rows, 0, "pattern characters are literal")
    boxes[1]("")
    eq(#tables[1].rows, 6)
end)

local function selectCharacter(key)
    local dropdown = Mock.FindFrames("WowStyle1DropdownTemplate")[1]
    for _, entry in ipairs(Mock.MenuEntries(dropdown)) do
        if entry.data == key then
            entry.setSelected(entry.data)
            return
        end
    end
    error("No menu entry for " .. tostring(key))
end

test("the character menu lists the account, then this character, then the others", function()
    local ns = Mock.Boot()
    TradingBookDB.characters["Zed-Hyjal"] = { money = 0, stock = { bags = {}, bank = {}, mail = {} }, auctions = {} }
    TradingBookDB.characters["Alt-Hyjal"] = { money = 0, class = "WARRIOR", stock = { bags = {}, bank = {}, mail = {} }, auctions = {} }
    ns.UI.Open("auctions")

    local entries = Mock.MenuEntries(Mock.FindFrames("WowStyle1DropdownTemplate")[1])
    eq(#entries, 4)
    eq(entries[1].text, "Whole account")
    eq(entries[2].data, PLAYER_KEY, "this character first")
    eq(entries[3].data, "Alt-Hyjal")
    eq(entries[4].data, "Zed-Hyjal")
    eq(entries[3].text:find("Alt", 1, true) ~= nil and entries[3].text:find("|c", 1, true) == 1, true, "name in class colour")
    eq(entries[4].text, "Zed", "plain when the class is unknown")

    eq(entries[1].isSelected(entries[1].data), true, "account selected by default")
    entries[3].setSelected(entries[3].data)
    eq(entries[1].isSelected(entries[1].data), false)
    eq(entries[3].isSelected(entries[3].data), true)
end)

test("the character menu filters every tab, including other characters than this one", function()
    local ns, world = Mock.Boot()
    local tables = captureTables(ns)
    seedLedger(ns, world)
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    Mock.Fire("BAG_UPDATE_DELAYED")
    Mock.RunTimers()
    TradingBookDB.characters["Alt-Hyjal"] = { money = 0, stock = { bags = { [1001] = 5 }, bank = {}, mail = {} }, auctions = {} }

    ns.UI.Open("auctions")
    eq(#tables[1].rows, 6, "history, all characters")

    selectCharacter(PLAYER_KEY)
    eq(#tables[1].rows, 5, "history, this character")
    selectCharacter("Alt-Hyjal")
    eq(#tables[1].rows, 1, "history, the alt")

    ns.UI.Open("stock")
    eq(tables[2].rows[1].total, 5, "stock, the alt")

    selectCharacter("")
    eq(tables[2].rows[1].total, 15, "stock, all characters")
end)

test("the filter buttons mark the selection, and can be greyed out", function()
    local ns = Mock.Boot()
    local chosen = {}
    local group = ns.UI.CreateSegments(UIParent, {
        { value = "a", label = "One" },
        { value = "b", label = "Two" },
    }, "a", function(value) table.insert(chosen, value) end)

    eq(group.buttons.a.Underline:IsShown(), true, "initial selection")
    eq(group.buttons.b.Underline:IsShown(), false)
    eq(#chosen, 0, "no notification for the initial state")

    group.buttons.b.scripts.OnClick(group.buttons.b)
    eq(chosen[1], "b", "notified")
    eq(group.buttons.a.Underline:IsShown(), false, "moved")
    eq(group.buttons.b.Selected:IsShown(), true, "moved")

    group.SetActive(false)
    eq(group.buttons.a.enabled, false, "greyed")
    group.SetActive(true)
    eq(group.buttons.a.enabled, true, "back")
end)

-- Stock filters ----------------------------------------------------------------

local function stockFixture()
    local ns, world = Mock.Boot()
    local tables = captureTables(ns)
    local segments = captureSegments(ns)
    ns.Ledger.Add({ kind = "sold", itemID = 1001, name = "Herb", qty = 1, gross = 100 })
    ns.Ledger.Add({ kind = "sold", itemID = 1002, name = "Ore", qty = 1, gross = 10 })
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    Mock.SetBagItem(6, 1, 1001, "Herb", 20)
    Mock.SetBagItem(12, 1, 1001, "Herb", 40)
    Mock.SetBagItem(0, 2, 1002, "Ore", 3)
    Mock.SetBagItem(12, 2, 1003, "Gem", 7)
    Mock.Fire("BANKFRAME_OPENED")
    Mock.RunTimers()
    Mock.Fire("BANKFRAME_CLOSED")
    ns.UI.Open("stock")
    return ns, tables[1], segments[1]
end

local function rowIDs(tbl)
    local ids = {}
    for _, row in ipairs(tbl.rows) do
        table.insert(ids, row.itemID)
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

test("the stock shows every place by default", function()
    local _, list = stockFixture()
    eq(rowIDs(list), "1001,1002,1003")
end)

test("the stock filters by bags, personal bank or shared stock", function()
    local _, list, select = stockFixture()
    select("bags")
    eq(rowIDs(list), "1001,1002", "bags")
    select("bank")
    eq(rowIDs(list), "1001", "personal bank")
    select("warband")
    eq(rowIDs(list), "1001,1003", "shared stock")
    select("mail")
    eq(rowIDs(list), "", "mail")
    eq(list.Empty:IsShown(), true, "says so when empty")
    select("all")
    eq(rowIDs(list), "1001,1002,1003", "back to everything")
end)

test("a filtered stock values what is in that place, and sorts on it", function()
    local _, list, select = stockFixture()
    select("warband")
    eq(list.sortColumn.key, "warband", "sorted on the filtered place")
    eq(list.rows[1].itemID, 1001, "most in that place first")
    eq(list.rows[1].value, 40 * 100, "valued on the 40 in the shared stock, not the 70 in total")
    eq(list.rows[1].total, 70, "the total stays visible")

    select("all")
    eq(list.sortColumn.key, "total")
    eq(list.rows[1].value, 70 * 100)
end)

test("the shared stock stays visible with a character selected", function()
    local _, list, select = stockFixture()
    TradingBookDB.characters["Alt-Hyjal"] = { money = 0, stock = { bags = {}, bank = {}, mail = {} }, auctions = {} }
    selectCharacter("Alt-Hyjal")
    eq(rowIDs(list), "", "the alt holds nothing itself")
    select("warband")
    eq(rowIDs(list), "1001,1003", "the shared stock is nobody's")
    select("bags")
    eq(rowIDs(list), "", "the alt's bags are empty")
end)

-- Keeps what each tile displays, by key.
local function captureTileValues(ns)
    local values = {}
    local createTile = ns.UI.CreateTile
    ns.UI.CreateTile = function(parent, spec, width)
        local tile = createTile(parent, spec, width)
        local set = tile.SetValue
        tile.SetValue = function(self, text, color)
            values[spec.key] = text
            set(self, text, color)
        end
        return tile
    end
    return values
end

test("the stock tiles follow the selected place", function()
    local ns = Mock.Boot()
    local values = captureTileValues(ns)
    local segments = captureSegments(ns)
    ns.Ledger.Add({ kind = "sold", itemID = 1001, name = "Herb", qty = 1, gross = 100 })
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    Mock.SetBagItem(6, 1, 1001, "Herb", 20)
    Mock.SetBagItem(12, 2, 1002, "Ore", 7)
    Mock.Fire("BANKFRAME_OPENED")
    Mock.RunTimers()
    Mock.Fire("BANKFRAME_CLOSED")
    ns.UI.Open("stock")
    eq(values.units, "37", "everywhere")
    eq(values.items, "2", "everywhere")

    segments[1]("bags")
    eq(values.units, "10", "in the bags")
    eq(values.items, "1", "in the bags")
    eq(values.value, "1000c", "valued in the bags")

    segments[1]("bank")
    eq(values.units, "20", "in the bank")
    eq(values.value, "2000c", "valued in the bank")
end)

test("the stock tiles sum the filter, and the search only narrows the list", function()
    local ns, world = Mock.Boot()
    local tables = captureTables(ns)
    local values = captureTileValues(ns)
    local boxes = {}
    local createBox = ns.UI.CreateSearchBox
    ns.UI.CreateSearchBox = function(parent, onChange)
        table.insert(boxes, onChange)
        return createBox(parent, onChange)
    end
    ns.Ledger.Add({ kind = "sold", itemID = 1001, name = "Herb", qty = 1, gross = 100 })
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    Mock.SetBagItem(0, 2, 1002, "Ore", 3)
    Mock.Fire("BAG_UPDATE_DELAYED")
    Mock.RunTimers()
    ns.UI.Open("stock")
    eq(values.items, "2")
    eq(values.units, "13")
    eq(values.value, "1000c")

    boxes[1]("herb")
    eq(#tables[1].rows, 1, "list narrowed")
    eq(values.items, "2", "tiles unchanged")
end)

test("the change over 7 days only shows on the whole account's stock", function()
    local ns, world = Mock.Boot()
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    Mock.Fire("BAG_UPDATE_DELAYED")
    Mock.RunTimers()
    world.now = world.now + 8 * 86400
    Mock.SetBagItem(0, 1, 1001, "Herb", 25)
    Mock.Fire("BAG_UPDATE_DELAYED")
    Mock.RunTimers()
    local tables = captureTables(ns)
    local segments = captureSegments(ns)
    ns.UI.Open("stock")
    eq(tables[1].rows[1].change, 15, "whole account")
    segments[1]("bags")
    eq(tables[1].rows[1].change, nil, "history does not cover one place")
    segments[1]("all")
    selectCharacter(PLAYER_KEY)
    eq(tables[1].rows[1].change, nil, "nor one character")
end)

-- Gold tab ---------------------------------------------------------------------

local function goldFixture()
    local ns, world = Mock.Boot()
    local tables = captureTables(ns)
    local segments = captureSegments(ns)
    local charts = {}
    local createChart = ns.UI.CreateLineChart
    ns.UI.CreateLineChart = function(...)
        local chart = createChart(...)
        table.insert(charts, chart)
        return chart
    end
    setCharacterGold(ns, world, PLAYER_KEY, { { -5, 1000000 }, { -3, 1400000 }, { -1, 1200000 }, { 0, 1500000 } }, "MAGE")
    setCharacterGold(ns, world, "Alt-Hyjal", { { -5, 300000 }, { 0, 350000 } }, "WARRIOR")
    setWarbandGold(ns, world, { { -5, 2000000 }, { -2, 2500000 } })
    ns.UI.Open("gold")
    return ns, world, tables[1], segments, charts[1]
end

test("the gold tab draws its chart, table and highlights for the selection", function()
    local ns, world, breakdown, segments, chart = goldFixture()
    eq(#breakdown.rows, 3, "three holders")
    eq(breakdown.rows[1].key, "warband", "largest first")

    local shown = 0
    for _, line in ipairs(chart.lines) do
        if line:IsShown() then shown = shown + 1 end
    end
    eq(shown, 5, "six days, five segments")
    eq(chart.Empty:IsShown(), false, "enough history")
    eq(chart.Note.text, "Tracked since " .. os.date("%m/%d", world.now - 5 * 86400))

    segments[2]("warband")
    eq(#breakdown.rows, 1, "warband only")
    eq(breakdown.rows[1].key, "warband")
    selectCharacter("Alt-Hyjal")
    eq(#breakdown.rows, 1, "one character")
    eq(breakdown.rows[1].key, "Alt-Hyjal")
    local row = breakdown.ScrollBox.rendered[1]
    eq(row.cells[1].text:find("Alt", 1, true) ~= nil, true, "holder named")
    selectCharacter("")
    segments[2]("all")
    eq(#breakdown.rows, 3)
end)

test("holder filters grey out while a character is selected", function()
    local ns, world, breakdown = goldFixture()
    local capture = Mock.Objects()
    local holderGroup
    for _, object in ipairs(capture) do
        if rawget(object, "buttons") and object.buttons.characters then
            holderGroup = object
        end
    end
    eq(holderGroup.buttons.characters.enabled, true, "active")
    selectCharacter("Alt-Hyjal")
    eq(holderGroup.buttons.characters.enabled, false, "greyed")
    selectCharacter("")
    eq(holderGroup.buttons.characters.enabled, true, "active again")
end)

test("the gold chart keeps its marks inside the plot, and shows each point on hover", function()
    local ns, world, breakdown, segments, chart = goldFixture()
    local plot = Mock.Rect(chart.plot)
    for _, slot in ipairs(chart.slots) do
        if slot:IsShown() then
            eq(slot.y >= 0 and slot.y <= chart.plotHeight, true, "y in the plot: " .. slot.y)
            eq(slot.x >= 0 and slot.x <= chart.plotWidth, true, "x in the plot: " .. slot.x)
            local rect = Mock.Rect(slot)
            eq(rect.left >= plot.left - 0.01 and rect.right <= plot.right + 0.01, true, "hover area in the plot")
        end
    end

    local slot = chart.slots[6]
    slot.scripts.OnEnter(slot)
    eq(chart.Crosshair:IsShown(), true, "crosshair")
    eq(chart.Marker:IsShown(), true, "marker")
    local lines = table.concat(GameTooltip.lines, ";")
    eq(lines:find("Current gold=", 1, true) ~= nil, true, "value in the tooltip: " .. lines)
    eq(lines:find("Change=", 1, true) ~= nil, true, "change in the tooltip")
    slot.scripts.OnLeave(slot)
    eq(chart.Crosshair:IsShown(), false, "crosshair gone")
    eq(chart.Marker:IsShown(), false, "marker gone")
end)

test("the gold chart copes with no data, one day, a flat line and fewer points later", function()
    local ns, world, breakdown, segments, chart = goldFixture()

    chart:SetPoints({})
    eq(chart.Empty:IsShown(), true, "no data")
    eq(chart.TopLabel.text, "", "no axis")

    chart:SetPoints({ { t = world.now, day = 1, value = 5000, delta = 0 } })
    eq(chart.Empty:IsShown(), true, "one day: history still building")
    eq(chart.slots[1]:IsShown(), true, "that day can be hovered")
    eq(chart.slots[2]:IsShown(), false, "older slots hidden")
    eq(chart.lines[1]:IsShown(), false, "older lines hidden")

    local flat = {}
    for i = 1, 5 do
        flat[i] = { t = world.now + i * 86400, day = i, value = 0, delta = 0 }
    end
    chart:SetPoints(flat)
    eq(chart.slots[1].y >= 0, true, "no division by zero on a flat line")

    local long = {}
    for i = 1, 60 do
        long[i] = { t = world.now + i * 86400, day = i, value = i * 10000, delta = 10000 }
    end
    chart:SetPoints(long)
    eq(chart.dots[1]:IsShown(), false, "no dots on a dense line")
end)

test("the gold chart hides what a shorter series no longer uses", function()
    local ns, world, breakdown, segments, chart = goldFixture()
    local function series(count)
        local points = {}
        for i = 1, count do
            points[i] = { t = world.now + i * 86400, day = i, value = i * 100000, delta = 100000 }
        end
        return points
    end
    chart:SetPoints(series(5))
    eq(chart.lines[4]:IsShown(), true, "five days: four segments")
    eq(chart.dots[5]:IsShown(), true, "five days: five dots")

    chart:SetPoints(series(3))
    eq(chart.lines[2]:IsShown(), true, "three days: two segments")
    eq(chart.lines[3]:IsShown(), false, "the third segment is gone")
    eq(chart.lines[4]:IsShown(), false, "the fourth too")
    eq(chart.slots[3]:IsShown(), true, "third day still hoverable")
    eq(chart.slots[4]:IsShown(), false, "fourth day gone")
    eq(chart.dots[4]:IsShown(), false, "its dot too")
end)

test("the net result chart stays usable when bars disappear", function()
    local ns, world = Mock.Boot()
    local charts = {}
    local createChart = ns.UI.CreateBarChart
    ns.UI.CreateBarChart = function(...)
        local chart = createChart(...)
        table.insert(charts, chart)
        return chart
    end
    seedLedger(ns, world)
    ns.UI.Open("stats")
    local chart = charts[1]
    local slot = chart.slots[#chart.slots]
    slot.scripts.OnEnter(slot)
    slot.scripts.OnLeave(slot)
    chart:SetBars({})
    eq(slot:IsShown(), false, "hidden")
end)

test("tabs are only built when first shown", function()
    local ns = Mock.Boot()
    local tables = captureTables(ns)
    ns.UI.Open("stats")
    eq(#tables, 1)
    ns.UI.Toggle()
    ns.UI.Open("stock") -- Reopening a closed window on a tab never built yet.
    eq(#tables, 2)
    eq(TradingBookMainFrame:IsShown(), true)
end)

test("the open tab refreshes when data changes, and a closed window does not", function()
    local ns, world = Mock.Boot()
    local tables = captureTables(ns)
    ns.UI.Open("auctions")
    eq(#tables[1].rows, 0)

    ns.Ledger.Add({ kind = "sold", itemID = 1001, name = "Herb", qty = 1, gross = 100 })
    Mock.RunTimers()
    eq(#tables[1].rows, 1, "refreshed")

    ns.UI.Toggle()
    ns.Ledger.Add({ kind = "sold", itemID = 1001, name = "Herb", qty = 1, gross = 100 })
    Mock.RunTimers()
    eq(#tables[1].rows, 1, "closed window left alone")
end)

test("the stock tab shows locations, value and history", function()
    local ns, world = Mock.Boot()
    local tables = captureTables(ns)
    ns.Ledger.Add({ kind = "sold", itemID = 1001, name = "Herb", qty = 10, gross = 1000 })
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    Mock.SetBagItem(6, 1, 1001, "Herb", 30)
    Mock.Fire("BANKFRAME_OPENED")
    Mock.RunTimers()
    Mock.Fire("BANKFRAME_CLOSED")
    ns.UI.Open("stock")

    local rows = tables[1].rows
    eq(#rows, 1)
    eq(rows[1].total, 40)
    eq(rows[1].value, 4000, "valued at average sale")
    eq(rows[1].name, "Herb")
    eq(rows[1].change, nil, "no history yet")

    local row = tables[1].ScrollBox.rendered[1]
    row.scripts.OnEnter(row)
    eq(row.cells[1].text, "Herb")
    eq(row.cells[2].text, "40")
    eq(GameTooltip.itemID, 1001)
end)

test("items of offline characters still display from saved details", function()
    local ns = Mock.Boot()
    local tables = captureTables(ns)
    TradingBookDB.characters["Alt-Hyjal"] = { money = 0, stock = { bags = { [4242] = 3 }, bank = {}, mail = {} }, auctions = {} }
    ns.RememberItem(4242, "Rare Gem", 2, 999)
    ns.UI.Open("stock")
    eq(tables[1].rows[1].name, "Rare Gem")
    eq(tables[1].ScrollBox.rendered[1].cells[1].text, "Rare Gem")
end)

test("items never seen by this client show a placeholder instead of an error", function()
    local ns = Mock.Boot()
    local tables = captureTables(ns)
    TradingBookDB.characters["Alt-Hyjal"] = { money = 0, stock = { bags = { [4242] = 3 }, bank = {}, mail = {} }, auctions = {} }
    ns.UI.Open("stock")
    eq(tables[1].ScrollBox.rendered[1].cells[1].text, "Unknown item")
end)

test("the stats tab fills its tiles and item table for the chosen period", function()
    local ns, world = Mock.Boot()
    local tables = captureTables(ns)
    local segments = captureSegments(ns)
    seedLedger(ns, world)
    ns.UI.Open("stats")

    local items = tables[1].rows
    eq(#items, 2, "items within 30 days")
    eq(items[1].itemID, 1001, "best net first")

    segments[#segments](7)
    segments[#segments](0)
    eq(#tables[1].rows, 2, "all time")
    local herb, sword
    for _, row in ipairs(tables[1].rows) do
        if row.itemID == 1001 then herb = row end
        if row.itemID == 2001 then sword = row end
    end
    eq(herb.avgSale, 1000, "per unit, over 60 sold")
    eq(herb.avgPurchase, nil, "never bought")
    eq(sword.avgSale, 90000)
    eq(sword.avgPurchase, 20000)
end)

-- Layout -----------------------------------------------------------------------

-- The heaviest account the game allows, in each language: 12-letter names, and every
-- character at the gold cap.
local GOLD_CAP = 99999990000
local LONGEST_NAME = "Twelveletter"

local layoutLocale = "enUS"

local function layoutTest(name, fn)
    for _, locale in ipairs({ "enUS", unpack(LOCALES) }) do
        test(name .. " [" .. locale .. "]", function()
            layoutLocale = locale
            fn()
        end)
    end
end

local function layoutFixture()
    local ns, world = Mock.Boot({ locale = layoutLocale, money = GOLD_CAP })
    Mock.UseRealisticMoney()
    for i = 1, 40 do
        local itemID = 5000 + i
        local name = "An item with a really very long name, number " .. i
        ns.RememberItem(itemID, name, 3, 1000 + itemID)
        Mock.SetBagItem(0, i, itemID, name, 1234 + i)
        Mock.SetBagItem(6, i, itemID, name, 5432)
        Mock.SetBagItem(12, i, itemID, name, 9999)
        ns.Ledger.Add({ kind = "sold", itemID = itemID, name = name, qty = 1000, gross = 998765400, cut = 49938270, deposit = 123456, t = world.now - i * 86400, char = PLAYER_KEY })
        ns.Ledger.Add({ kind = "bought", itemID = itemID, name = name, qty = 999, gross = 887654300, t = world.now - i * 43200, char = LONGEST_NAME .. "-Hyjal" })
        ns.Ledger.Add({ kind = "post", itemID = itemID, name = name, qty = 1, unit = 993456, deposit = 123456, t = world.now - i * 21600 })
    end
    world.warbandMoney = GOLD_CAP
    Mock.Fire("BANKFRAME_OPENED")
    Mock.RunTimers()
    Mock.Fire("BANKFRAME_CLOSED")
    setCharacterGold(ns, world, PLAYER_KEY, { { -60, GOLD_CAP / 2 }, { -30, GOLD_CAP / 4 }, { -2, GOLD_CAP / 3 }, { 0, GOLD_CAP } }, "MAGE")
    for i = 1, 14 do
        local letter = string.char(96 + i)
        setCharacterGold(ns, world, LONGEST_NAME:sub(1, 11) .. letter .. "-Hyjal", { { -40, GOLD_CAP / 2 }, { 0, GOLD_CAP } }, "WARRIOR")
    end
    return ns, world
end

local function overlap(a, b)
    return a.left < b.right - 0.01 and b.left < a.right - 0.01 and a.bottom < b.top - 0.01 and b.bottom < a.top - 0.01
end

local function describe(object, rect)
    return ("%s %s [%.0f,%.0f %.0f,%.0f] %q"):format(object.kind, tostring(rawget(object, "template") or rawget(object, "frameType") or ""),
        rect.left, rect.bottom, rect.right, rect.top, tostring(rawget(object, "text") or ""))
end

local function isInsideTabButton(object, frame)
    while object and object ~= frame do
        if rawget(object, "template") == "PanelTabButtonTemplate" then
            return true
        end
        object = rawget(object, "parent")
    end
    return false
end

-- Everything visible in the window, other than the tab buttons below it by design.
local function visibleContent(frame)
    local found = {}
    for _, object in ipairs(Mock.Objects()) do
        if Mock.IsWithin(object, frame) and Mock.IsVisible(object) and not isInsideTabButton(object, frame) then
            local rect = Mock.Rect(object)
            if rect then
                table.insert(found, { object = object, rect = rect })
            end
        end
    end
    return found
end

local function directChildren(parent)
    local found = {}
    for _, object in ipairs(Mock.Objects()) do
        if rawget(object, "parent") == parent and Mock.IsVisible(object) then
            local rect = Mock.Rect(object)
            if rect then
                table.insert(found, { object = object, rect = rect })
            end
        end
    end
    return found
end

local function activePane(frame)
    for _, object in ipairs(directChildren(frame.Inset)) do
        return object.object, object.rect
    end
end

for _, tab in ipairs({ "auctions", "stock", "stats", "gold" }) do
    layoutTest("layout: the " .. tab .. " tab keeps everything inside the window", function()
        local ns = layoutFixture()
        ns.UI.Open(tab)
        local frame = TradingBookMainFrame
        local window = Mock.Rect(frame)
        for _, item in ipairs(visibleContent(frame)) do
            local rect = item.rect
            eq(rect.left >= window.left and rect.right <= window.right and rect.bottom >= window.bottom and rect.top <= window.top,
                true, "outside the window: " .. describe(item.object, rect))
        end
    end)

    layoutTest("layout: the " .. tab .. " tab keeps its content inside the margins", function()
        local ns = layoutFixture()
        ns.UI.Open(tab)
        local frame = TradingBookMainFrame
        local inset = Mock.Rect(frame.Inset)
        local _, pane = activePane(frame)
        eq(pane.left - inset.left, ns.UI.PADDING, "left margin")
        eq(inset.right - pane.right, ns.UI.PADDING, "right margin")
        eq(inset.top - pane.top, ns.UI.PADDING, "top margin")
        eq(pane.bottom - inset.bottom, ns.UI.PADDING, "bottom margin")
        eq(pane.right - pane.left, ns.UI.CONTENT_WIDTH, "content width constant")
        eq(pane.top - pane.bottom, ns.UI.CONTENT_HEIGHT, "content height constant")

        for _, item in ipairs(visibleContent(activePane(frame))) do
            local rect = item.rect
            eq(rect.left >= pane.left - 0.01 and rect.right <= pane.right + 0.01 and rect.bottom >= pane.bottom - 0.01 and rect.top <= pane.top + 0.01,
                true, "outside the pane: " .. describe(item.object, rect))
        end
    end)

    layoutTest("layout: the " .. tab .. " tab keeps a gap between its blocks", function()
        local ns = layoutFixture()
        ns.UI.Open(tab)
        local children = directChildren(activePane(TradingBookMainFrame))
        eq(#children >= 1, true, "has blocks")
        for i = 1, #children do
            for j = i + 1, #children do
                local a, b = children[i], children[j]
                eq(overlap(a.rect, b.rect), false, "overlap: " .. describe(a.object, a.rect) .. " and " .. describe(b.object, b.rect))
                if a.object.kind == "frame" and b.object.kind == "frame" then
                    local horizontal = math.max(a.rect.left - b.rect.right, b.rect.left - a.rect.right)
                    local vertical = math.max(a.rect.bottom - b.rect.top, b.rect.bottom - a.rect.top)
                    eq(math.max(horizontal, vertical) >= ns.UI.GAP - 0.01, true,
                        "too close: " .. describe(a.object, a.rect) .. " and " .. describe(b.object, b.rect))
                end
            end
        end
    end)

    layoutTest("layout: the " .. tab .. " tab's controls fit without touching", function()
        local ns = layoutFixture()
        ns.UI.Open(tab)
        local frame = TradingBookMainFrame
        local inset = Mock.Rect(frame.Inset)
        local window = Mock.Rect(frame)
        local controls = {}
        local dropdown = Mock.FindFrames("WowStyle1DropdownTemplate")[1]
        table.insert(controls, { object = dropdown, rect = Mock.Rect(dropdown) })
        for _, child in ipairs(directChildren(frame)) do
            if child.object ~= dropdown and child.object ~= frame.Inset and not isInsideTabButton(child.object, frame)
                and child.object.kind == "frame" then
                for _, control in ipairs(directChildren(child.object)) do
                    table.insert(controls, control)
                end
            end
        end
        eq(#controls >= 2, true, "has controls")
        for i, control in ipairs(controls) do
            eq(control.rect.bottom >= inset.top - 0.01, true, "above the content: " .. describe(control.object, control.rect))
            eq(control.rect.left >= window.left + 60, true, "clear of the portrait: " .. describe(control.object, control.rect))
            for j = i + 1, #controls do
                eq(overlap(control.rect, controls[j].rect), false,
                    "controls touching: " .. describe(control.object, control.rect) .. " and " .. describe(controls[j].object, controls[j].rect))
            end
        end
    end)

    layoutTest("layout: the " .. tab .. " tab's text fits, except item names that may truncate", function()
        local ns = layoutFixture()
        ns.UI.Open(tab)
        for _, item in ipairs(visibleContent(TradingBookMainFrame)) do
            local object = item.object
            if object.kind == "text" and object.text ~= "" and not (object.font == "GameFontHighlight") then
                local available = item.rect.right - item.rect.left
                eq(object:GetStringWidth() <= available + 0.01, true,
                    ("text cut: %q is %.0f wide in %.0f"):format(tostring(object.text), object:GetStringWidth(), available))
            end
        end
    end)
end

layoutTest("layout: filter buttons sit side by side, inside their group", function()
    local ns = layoutFixture()
    for _, tab in ipairs({ "auctions", "stock", "stats", "gold" }) do
        ns.UI.Open(tab)
        for _, object in ipairs(Mock.Objects()) do
            if rawget(object, "buttons") and Mock.IsVisible(object) then
                local group = Mock.Rect(object)
                local rects = {}
                for _, button in pairs(object.buttons) do
                    table.insert(rects, Mock.Rect(button))
                end
                eq(#rects >= 2, true, tab .. ": a group has several buttons")
                for i, rect in ipairs(rects) do
                    eq(rect.left >= group.left - 0.01 and rect.right <= group.right + 0.01, true, tab .. ": button outside its group")
                    for j = i + 1, #rects do
                        eq(overlap(rect, rects[j]), false, tab .. ": buttons on top of each other")
                    end
                end
            end
        end
    end
end)

layoutTest("layout: nothing spills out of the card or row that holds it", function()
    local ns = layoutFixture()
    for _, tab in ipairs({ "auctions", "stock", "stats", "gold" }) do
        ns.UI.Open(tab)
        local _, pane = activePane(TradingBookMainFrame)
        for _, item in ipairs(visibleContent(activePane(TradingBookMainFrame))) do
            local object = item.object
            local parent = rawget(object, "parent")
            local holder = Mock.Rect(parent)
            -- Sort arrows may overhang a narrow column by a few pixels, within the header band.
            if object.kind ~= "line" and holder and not rawget(object, "atlas") then
                local rect = item.rect
                eq(rect.left >= holder.left - 0.01 and rect.right <= holder.right + 0.01
                    and rect.bottom >= holder.bottom - 3 and rect.top <= holder.top + 3,
                    true, tab .. ": spills out of its parent: " .. describe(object, rect))
            end
        end
    end
end)

layoutTest("layout: the highlights fit their card, with the longest amounts", function()
    local ns = layoutFixture()
    ns.UI.Open("gold")
    for _, item in ipairs(visibleContent(TradingBookMainFrame)) do
        local object = item.object
        if object.kind == "text" and object.font == "GameFontHighlightSmall" then
            local parent = rawget(object, "parent")
            for _, sibling in ipairs(directChildren(parent)) do
                if sibling.object ~= object and sibling.object.kind == "text" then
                    eq(overlap(item.rect, sibling.rect), false,
                        "text overlap: " .. describe(object, item.rect) .. " and " .. describe(sibling.object, sibling.rect))
                end
            end
        end
    end
end)

layoutTest("layout: table columns use the width they are given", function()
    local ns = layoutFixture()
    local tables = captureTables(ns)
    for _, tab in ipairs({ "auctions", "stock", "stats", "gold" }) do
        ns.UI.Open(tab)
    end
    for index, tbl in ipairs(tables) do
        local list = Mock.Rect(tbl.ScrollBox)
        local last = Mock.Rect(tbl.columns[#tbl.columns].header)
        eq(list.right - last.right <= 12, true,
            ("table %d leaves %.0f unused beside the scroll bar"):format(index, list.right - last.right))
    end
end)

layoutTest("layout: tiles do not cut their value, label or note", function()
    local ns, world = layoutFixture()
    for _, tab in ipairs({ "stats", "gold", "stock" }) do
        ns.UI.Open(tab)
        for _, item in ipairs(visibleContent(TradingBookMainFrame)) do
            local object = item.object
            if object.kind == "text" and object.font == "GameFontHighlightLarge" then
                local parent = Mock.Rect(rawget(object, "parent"))
                eq(item.rect.left + object:GetStringWidth() <= parent.right, true,
                    ("%s: value too wide: %q"):format(tab, tostring(object.text)))
            end
        end
    end
end)

layoutTest("layout: table columns fit beside the scroll bar", function()
    local ns = layoutFixture()
    local tables = captureTables(ns)
    for _, tab in ipairs({ "auctions", "stock", "stats", "gold" }) do
        ns.UI.Open(tab)
    end
    eq(#tables, 4)
    for index, tbl in ipairs(tables) do
        local list = Mock.Rect(tbl.ScrollBox)
        for _, column in ipairs(tbl.columns) do
            local header = Mock.Rect(column.header)
            eq(header.right <= list.right - 2, true, ("table %d: column %s runs into the scroll bar"):format(index, column.key))
        end
    end
end)

layoutTest("layout: table rows are not clipped by the list", function()
    local ns = layoutFixture()
    local tables = captureTables(ns)
    ns.UI.Open("auctions")
    local list = Mock.Rect(tables[1].ScrollBox)
    for _, row in ipairs(tables[1].ScrollBox.rendered) do
        local rect = Mock.Rect(row)
        eq(rect.bottom >= list.bottom - 0.01, true, "row below the list")
        for _, cell in ipairs(row.cells) do
            local cellRect = Mock.Rect(cell)
            eq(cellRect.right <= rect.right, true, "cell beyond the row")
        end
    end
end)

-- Minimap icon ---------------------------------------------------------------

-- The mock's minimap: 140 wide, centered on (100, 100), at an effective scale of 2.
local function dragTo(button, world, x, y)
    world.cursorX, world.cursorY = x * 2, y * 2
    button.scripts.OnDragStart(button)
    button.scripts.OnUpdate(button)
    button.scripts.OnDragStop(button)
end

test("the minimap icon appears at login, on the edge of the minimap", function()
    Mock.Boot()
    local button = TradingBookMinimapButton
    eq(button:IsShown(), true)
    eq(button.parent, Minimap, "child of the minimap")
    eq(button.lastPoint.relativeTo, Minimap, "anchored to the minimap")
    near(button.lastPoint.x, -75 * math.cos(math.rad(45)), 0.01, "x")
    near(button.lastPoint.y, -75 * math.sin(math.rad(45)), 0.01, "y")
end)

test("clicking the minimap icon opens and closes the window", function()
    Mock.Boot()
    local button = TradingBookMinimapButton
    button.scripts.OnClick(button, "LeftButton")
    eq(TradingBookMainFrame:IsShown(), true, "opened")
    button.scripts.OnClick(button, "LeftButton")
    eq(TradingBookMainFrame:IsShown(), false, "closed")
end)

test("dragging the icon follows the cursor around the edge, in any direction", function()
    local _, world = Mock.Boot()
    local button = TradingBookMinimapButton
    local cases = {
        { x = 300, y = 100, expectX = 75, expectY = 0 }, -- Right, far beyond the edge.
        { x = 100, y = 130, expectX = 0, expectY = 75 }, -- Above, inside the map.
        { x = 50, y = 100, expectX = -75, expectY = 0 }, -- Left.
        { x = 100, y = 50, expectX = 0, expectY = -75 }, -- Below.
    }
    for _, case in ipairs(cases) do
        dragTo(button, world, case.x, case.y)
        near(button.lastPoint.x, case.expectX, 0.01, "x")
        near(button.lastPoint.y, case.expectY, 0.01, "y")
        local angle = TradingBookDB.ui.minimap.angle
        eq(angle >= 0 and angle < 360, true, "angle in range: " .. angle)
    end
end)

test("the icon stops following the cursor once dropped", function()
    local _, world = Mock.Boot()
    local button = TradingBookMinimapButton
    dragTo(button, world, 300, 100)
    eq(button.scripts.OnUpdate, nil)
end)

test("the icon keeps its position across a reload", function()
    local _, world = Mock.Boot()
    dragTo(TradingBookMinimapButton, world, 300, 100)
    local saved = TradingBookDB

    Mock.Boot({ db = saved })
    near(TradingBookMinimapButton.lastPoint.x, 75, 0.01, "x")
    near(TradingBookMinimapButton.lastPoint.y, 0, 0.01, "y")
end)

test("the icon's tooltip explains it, but stays out of the way while dragging", function()
    Mock.Boot()
    local button = TradingBookMinimapButton
    button.scripts.OnEnter(button)
    eq(#GameTooltip.lines, 4, "hints")
    eq(GameTooltip.text, "Trading Book")

    button.scripts.OnDragStart(button)
    eq(GameTooltip:IsShown(), false, "hidden on drag")
    button.scripts.OnEnter(button)
    eq(GameTooltip:IsShown(), false, "not reopened during the drag")
    button.scripts.OnDragStop(button)
    button.scripts.OnEnter(button)
    eq(GameTooltip:IsShown(), true, "back after the drag")
end)

test("/tradingbook minimap hides the icon for good, and brings it back", function()
    local _, world = Mock.Boot()
    SlashCmdList.TRADINGBOOK("minimap")
    eq(TradingBookMinimapButton:IsShown(), false, "hidden")
    eq(#world.printed, 1, "says how to bring it back")

    local saved = TradingBookDB
    Mock.Boot({ db = saved })
    eq(TradingBookMinimapButton:IsShown(), false, "still hidden after a reload")

    SlashCmdList.TRADINGBOOK("MINIMAP")
    eq(TradingBookMinimapButton:IsShown(), true, "shown again")
end)

test("saved data from before the minimap icon gets it at the default position", function()
    Mock.Boot({ db = { ui = { position = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 0 } } } })
    eq(TradingBookMinimapButton:IsShown(), true)
    eq(TradingBookDB.ui.minimap.angle, 225)
    eq(TradingBookDB.ui.position.point, "CENTER", "other settings untouched")
end)

-- Item tooltips ----------------------------------------------------------------

-- The lines Trading Book adds when an item is hovered somewhere in the game.
local function hoverItem(itemID)
    GameTooltip.lines = {}
    GameTooltip:SetOwner(UIParent, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(itemID)
    return table.concat(GameTooltip.lines, "\n")
end

local function has(text, part)
    return text:find(part, 1, true) ~= nil
end

test("looking one item up gives the same row as the whole stock", function()
    local ns, world = Mock.Boot()
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    Mock.SetBagItem(6, 1, 1001, "Herb", 20)
    Mock.SetBagItem(12, 1, 1001, "Herb", 40)
    Mock.SetBagItem(0, 2, 1002, "Ore", 3)
    Mock.Fire("BANKFRAME_OPENED")
    Mock.RunTimers()
    TradingBookDB.characters["Alt-Hyjal"] = {
        money = 0, stock = { bags = { [1001] = 1 }, bank = {}, mail = { [1001] = 5 } },
        auctions = {
            { auctionID = 1, itemID = 1001, qty = 3, expiresAt = world.now + 3600 },
            { auctionID = 2, itemID = 1001, qty = 50, sold = true, expiresAt = world.now + 3600 },
            { auctionID = 3, itemID = 1001, qty = 70, expiresAt = world.now - 60 },
        },
    }
    local whole = findRow(ns.Stockpile.GetRows(), 1001)
    local single = ns.Stockpile.GetItemRow(1001)
    for _, place in ipairs({ "total", "bags", "bank", "warband", "mail", "auctions" }) do
        eq(single[place], whole[place], place)
    end
    eq(single.total, 79, "sold and ended auctions left out")
    eq(single.characters["Alt-Hyjal"].auctions, 3, "per character")
    eq(ns.Stockpile.GetItemRow(4242), nil, "an item not held")
end)

test("an item's tooltip shows the account's stock, by character and place", function()
    local _, world = Mock.Boot()
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    Mock.SetBagItem(6, 1, 1001, "Herb", 20)
    Mock.SetBagItem(12, 1, 1001, "Herb", 40)
    Mock.Fire("BANKFRAME_OPENED")
    Mock.RunTimers()
    TradingBookDB.characters["Alt-Hyjal"] = {
        money = 0, class = "WARRIOR", stock = { bags = {}, bank = {}, mail = { [1001] = 5 } },
        auctions = { { auctionID = 7, itemID = 1001, qty = 3, expiresAt = world.now + 3600 } },
    }
    local text = hoverItem(1001)
    eq(has(text, "Trading Book"), true, "a header: " .. text)
    eq(has(text, "Stock=78"), true, "the account total")
    eq(has(text, "Primo|r=Bags 10, Bank 20"), true, "the player, by place")
    eq(has(text, "Alt|r=Mail 5, AH 3"), true, "an alt, auctions included")
    eq(has(text, "Warband bank=40"), true, "the warband bank")
    eq(has(text, "sale"), false, "no sale lines for an item never sold")
end)

test("an item's tooltip shows its average sale over 90 days and its last sale", function()
    local ns, world = Mock.Boot()
    local day = 86400
    ns.Ledger.Add({ kind = "sold", t = world.now - 200 * day, itemID = 1001, name = "Herb", qty = 1, gross = 99900 })
    ns.Ledger.Add({ kind = "sold", t = world.now - day, itemID = 1001, name = "Herb", qty = 1, gross = 400 })
    -- Collected last, but sent earlier: dates come from the mail.
    ns.Ledger.Add({ kind = "sold", t = world.now - 10 * day, itemID = 1001, name = "Herb", qty = 2, gross = 200 })
    ns.Ledger.Add({ kind = "bought", itemID = 1001, name = "Herb", qty = 1, gross = 5 })

    local text = hoverItem(1001)
    eq(has(text, "Avg. sale (90 days)=200c"), true, "per unit, recent sales only: " .. text)
    eq(has(text, "Last sale (11/04)=400c"), true, "the latest by date, per unit")
    eq(has(text, "Stock="), false, "no stock line for an item not held")

    ns.Ledger.Add({ kind = "sold", itemID = 1001, name = "Herb", qty = 4, gross = 2000 })
    text = hoverItem(1001)
    eq(has(text, "Last sale (11/05)=500c"), true, "follows the ledger: " .. text)
    eq(has(text, "Avg. sale (90 days)=371c"), true, "2600 over 7 units")
end)

test("an item sold only long ago shows its last sale but no average", function()
    local ns, world = Mock.Boot()
    local longAgo = world.now - 200 * 86400
    ns.Ledger.Add({ kind = "sold", t = longAgo, itemID = 1002, name = "Ore", qty = 2, gross = 1000 })
    local text = hoverItem(1002)
    eq(has(text, "Avg. sale"), false, "no recent sale to average: " .. text)
    eq(has(text, "Last sale (" .. ns.FormatDay(longAgo) .. ")=500c"), true, "the last one")
end)

test("an item the account never held nor sold gets no lines", function()
    Mock.Boot()
    eq(hoverItem(4242), "")
end)

test("the window's own item tooltips do not get the lines twice", function()
    local _, list = stockFixture()
    local row = list.ScrollBox.rendered[1]
    GameTooltip.lines = {}
    row.scripts.OnEnter(row)
    local text = table.concat(GameTooltip.lines, "\n")
    eq(has(text, "Trading Book"), false, "no extra section: " .. text)
    local _, count = text:gsub("Bags 10, Bank 20", "")
    eq(count, 1, "holdings listed once")
end)

test("chat links get the lines, comparison tooltips do not", function()
    local ns = Mock.Boot()
    ns.Ledger.Add({ kind = "sold", itemID = 1001, name = "Herb", qty = 1, gross = 100 })
    ItemRefTooltip:SetOwner(UIParent, "ANCHOR_PRESERVE")
    ItemRefTooltip:SetHyperlink("|cffffffff|Hitem:1001::::|h[Herb]|h|r")
    eq(has(table.concat(ItemRefTooltip.lines, "\n"), "Last sale"), true, "chat link")

    local comparison = Mock.NewTooltip()
    comparison:SetOwner(GameTooltip, "ANCHOR_NONE")
    comparison:SetItemByID(1001)
    eq(#comparison.lines, 0, "comparison tooltip")
end)

test("/tradingbook tooltip hides the lines for good, and brings them back", function()
    local ns, world = Mock.Boot()
    ns.Ledger.Add({ kind = "sold", itemID = 1001, name = "Herb", qty = 1, gross = 100 })
    SlashCmdList.TRADINGBOOK("tooltip")
    eq(hoverItem(1001), "", "hidden")
    eq(#world.printed, 1, "says how to bring them back")

    world = select(2, Mock.Boot({ db = TradingBookDB }))
    eq(hoverItem(1001), "", "still hidden after a reload")
    SlashCmdList.TRADINGBOOK("TOOLTIP")
    eq(has(hoverItem(1001), "Last sale"), true, "shown again")
    eq(#world.printed, 1, "says so")
end)

-- Auction house scan ----------------------------------------------------------

test("opening the auction house scans it without Auctionator, at the lowest price per unit", function()
    local ns, world = Mock.Boot()
    Mock.Fire("AUCTION_HOUSE_SHOW")
    eq(world.replicateRequests, 0, "not before the auction house has settled")
    Mock.RunTimers()
    eq(world.replicateRequests, 1)
    answerScan({
        auction(1001, 10, 1000), auction(1001, 5, 400), auction(1001, 1, 150),
        auction(1002, 1, 0), -- Bids only.
        auction(1003, 2, 500, 1), -- Already sold.
        auction(82800, 1, 10), -- A caged pet.
    })
    local item = ns.Market.GetItem(1001)
    eq(item.price, 80, "lowest buyout per unit")
    eq(item.quantity, 16, "everything on sale")
    eq(item.seenAt, world.now)
    eq(ns.Market.GetItem(1002), nil, "no buyout, no price")
    eq(ns.Market.GetItem(1003), nil, "sold auctions left out")
    eq(ns.Market.GetItem(82800), nil, "caged pets left out")
    eq(has(world.printed[#world.printed], "Auction house scanned: 1 items priced."), true, world.printed[#world.printed])
end)

test("a large auction house is read a few thousand auctions a frame", function()
    local ns, world = Mock.Boot()
    openAuctionHouse()
    local auctions = {}
    for i = 1, 5000 do
        auctions[i] = auction(2000 + i % 50, 1, 100 + i)
    end
    Mock.SetReplicate(auctions)
    Mock.Fire("REPLICATE_ITEM_LIST_UPDATE")
    eq(world.replicateReads < 5000, true, "not all in one frame")
    eq(ns.Market.GetItem(2001), nil, "nothing saved before the end")
    Mock.RunTimers()
    eq(world.replicateReads, 5000, "each auction read once")
    eq(ns.Market.GetItem(2001).price, 101)
    eq(ns.Market.GetItem(2001).quantity, 100)
end)

test("scans keep the game's 15 minutes apart, and a scan by hand says when it can run", function()
    local _, world = Mock.Boot()
    openAuctionHouse()
    answerScan({ auction(1001, 1, 100) })
    world.now = world.now + 10 * 60
    SlashCmdList.TRADINGBOOK("scan")
    eq(world.replicateRequests, 1, "too soon")
    eq(has(world.printed[#world.printed], "scanned again in 5 min"), true, world.printed[#world.printed])

    Mock.Fire("AUCTION_HOUSE_CLOSED")
    local printed = #world.printed
    openAuctionHouse()
    eq(world.replicateRequests, 1, "not on reopening either")
    eq(#world.printed, printed, "an automatic scan says nothing when it cannot run")

    world.now = world.now + 5 * 60
    SlashCmdList.TRADINGBOOK("scan")
    eq(world.replicateRequests, 2, "allowed again")
    eq(has(world.printed[#world.printed], "Scanning the auction house..."), true)
end)

test("a scan by hand needs the auction house open", function()
    local _, world = Mock.Boot()
    SlashCmdList.TRADINGBOOK("scan")
    eq(world.replicateRequests, 0)
    eq(has(world.printed[1], "Open the auction house to scan it."), true, world.printed[1])
end)

test("Auctionator with prices makes the automatic scan unnecessary, but not without data", function()
    local ns, world = Mock.Boot()
    ns.RememberItem(1001, "Herb", 1, 1)
    local price = 500
    rawset(_G, "Auctionator", { API = { v1 = { GetAuctionPriceByItemID = function() return price end } } })
    openAuctionHouse()
    local withPrices = world.replicateRequests
    Mock.Fire("AUCTION_HOUSE_CLOSED")
    price = nil
    openAuctionHouse()
    rawset(_G, "Auctionator", nil)
    eq(withPrices, 0, "Auctionator has prices")
    eq(world.replicateRequests, 1, "Auctionator without data")
end)

test("the setting turns the automatic scan off, while the command still scans", function()
    local _, world = Mock.Boot()
    Mock.SettingsControl("Scan the auction house").setting:SetValue(false)
    openAuctionHouse()
    eq(world.replicateRequests, 0)
    SlashCmdList.TRADINGBOOK("scan")
    eq(world.replicateRequests, 1)

    Mock.Boot({ db = TradingBookDB })
    eq(Mock.SettingsControl("Scan the auction house").setting:GetValue(), false, "kept across a reload")
end)

test("closing the auction house drops a scan in progress and keeps the previous prices", function()
    local ns, world = Mock.Boot()
    openAuctionHouse()
    answerScan({ auction(1001, 1, 100) })
    local firstScan = world.now
    world.now = world.now + 20 * 60
    SlashCmdList.TRADINGBOOK("scan")
    local auctions = {}
    for i = 1, 5000 do
        auctions[i] = auction(1001, 1, 50)
    end
    Mock.SetReplicate(auctions)
    Mock.Fire("REPLICATE_ITEM_LIST_UPDATE")
    Mock.Fire("AUCTION_HOUSE_CLOSED")
    Mock.RunTimers()
    eq(ns.Market.GetItem(1001).price, 100, "previous price kept")
    eq(ns.Market.GetItem(1001).seenAt, firstScan)
    eq(has(world.printed[#world.printed], "scan stopped"), true, world.printed[#world.printed])
end)

test("a request the server never answers does not block the next one", function()
    local _, world = Mock.Boot()
    openAuctionHouse()
    eq(world.replicateRequests, 1)
    world.now = world.now + 16 * 60
    SlashCmdList.TRADINGBOOK("scan")
    eq(world.replicateRequests, 2)
end)

test("items gone from the auction house keep their last price for a month, with none on sale", function()
    local ns, world = Mock.Boot()
    openAuctionHouse()
    answerScan({ auction(1001, 3, 300), auction(1002, 1, 70) })
    local firstScan = world.now
    world.now = world.now + 20 * 60
    SlashCmdList.TRADINGBOOK("scan")
    answerScan({ auction(1002, 2, 120) })
    local gone = ns.Market.GetItem(1001)
    eq(gone.price, 100, "last price kept")
    eq(gone.quantity, 0, "none on sale now")
    eq(gone.seenAt, firstScan)
    eq(ns.Market.GetItem(1002).price, 60, "replaced by the new scan")

    world.now = world.now + 31 * 86400
    SlashCmdList.TRADINGBOOK("scan")
    answerScan({ auction(1002, 1, 80) })
    eq(ns.Market.GetItem(1001), nil, "dropped after 30 days")
    eq(ns.Market.GetItem(1002).price, 80)
end)

test("the account's items keep a price a day, for the change since a week ago", function()
    local ns, world = Mock.Boot()
    ns.RememberItem(1001, "Herb", 1, 1)
    openAuctionHouse()
    answerScan({ auction(1001, 1, 100), auction(1002, 1, 100) })
    local firstDay = world.now
    eq(ns.Market.GetChange(1001), nil, "no price a week old yet")
    for day = 1, 8 do
        world.now = firstDay + day * 86400
        SlashCmdList.TRADINGBOOK("scan")
        answerScan({ auction(1001, 1, 100 + day * 5), auction(1002, 1, 200) })
    end
    local change, since = ns.Market.GetChange(1001)
    near(change, 35 / 105, 0.0001, "against the latest price at least 7 days old")
    eq(ns.DayKey(since), ns.DayKey(firstDay + 86400))
    eq(ns.Market.GetChange(1002), nil, "items the account never dealt in keep no history")

    world.now = world.now + 20 * 60
    SlashCmdList.TRADINGBOOK("scan")
    answerScan({ auction(1002, 1, 200) })
    eq(ns.Market.GetChange(1001), nil, "not on sale any more")

    world.now = firstDay + 40 * 86400
    SlashCmdList.TRADINGBOOK("scan")
    answerScan({ auction(1001, 1, 100) })
    local days = 0
    for _ in pairs(TradingBookDB.market.realms.Hyjal.history[1001]) do
        days = days + 1
    end
    eq(days, 1, "only the last 30 days are kept")
end)

test("connected realms share their prices", function()
    Mock.Boot({ connectedRealms = { "Elune" } })
    openAuctionHouse()
    answerScan({ auction(1001, 1, 100) })
    local ns = Mock.Boot({ db = TradingBookDB, realm = "Elune", connectedRealms = { "Hyjal" } })
    eq(ns.Market.GetItem(1001) and ns.Market.GetItem(1001).price, 100, "another realm of the group")
    ns = Mock.Boot({ db = TradingBookDB, realm = "Ysondre" })
    eq(ns.Market.GetItem(1001), nil, "a realm outside the group")
end)

test("without Auctionator, item tooltips give the auction house price, its age and what is on sale", function()
    local ns, world = Mock.Boot()
    ns.RememberItem(4242, "Gem", 1, 1)
    openAuctionHouse()
    answerScan({ auction(4242, 4, 1000), auction(4242, 2, 600) })
    world.now = world.now + 8 * 86400
    SlashCmdList.TRADINGBOOK("scan")
    answerScan({ auction(4242, 1, 300) })
    world.now = world.now + 2 * 3600
    local text = hoverItem(4242)
    eq(has(text, "Trading Book"), true, "even for an item neither held nor sold: " .. text)
    eq(has(text, "AH price (2 h ago)=300c"), true, "price and age")
    eq(has(text, "On the AH=1"), true, "quantity on sale")
    eq(has(text, "Change since 11/05=+20.0%"), true, "change since a week ago")
    eq(has(text, "Stock value"), false, "nothing held")

    rawset(_G, "Auctionator", { API = { v1 = { GetAuctionPriceByItemID = function() return 999 end } } })
    text = hoverItem(4242)
    rawset(_G, "Auctionator", nil)
    eq(text, "", "Auctionator shows its own price")
end)

test("item tooltips and the stock tab value the account's stock at the scanned price", function()
    local ns, world = Mock.Boot()
    local tables = captureTables(ns)
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    Mock.Fire("BANKFRAME_OPENED")
    Mock.RunTimers()
    Mock.Fire("BANKFRAME_CLOSED")
    openAuctionHouse()
    answerScan({ auction(1001, 1, 30) })
    eq(has(hoverItem(1001), "Stock value=300c"), true, "in the item's tooltip")

    ns.UI.Open("stock")
    eq(tables[1].rows[1].value, 300, "in the stock tab")
    local row = tables[1].ScrollBox.rendered[1]
    GameTooltip.lines = {}
    row.scripts.OnEnter(row)
    local lines = table.concat(GameTooltip.lines, ";")
    eq(has(lines, "Source: auction house scan of 11/05 12:00"), true, lines)
end)

test("a finished scan refreshes the open window", function()
    local ns, world = Mock.Boot()
    local tables = captureTables(ns)
    Mock.SetBagItem(0, 1, 1001, "Herb", 10)
    Mock.Fire("BANKFRAME_OPENED")
    Mock.RunTimers()
    Mock.Fire("BANKFRAME_CLOSED")
    ns.UI.Open("stock")
    eq(tables[1].rows[1].value, nil, "no price yet")
    openAuctionHouse()
    answerScan({ auction(1001, 1, 30) })
    eq(tables[1].rows[1].value, 300)
end)

-- Settings ---------------------------------------------------------------------

local function scaleControls()
    return Mock.SettingsControl("Custom window scale"), Mock.SettingsControl("Window scale")
end

-- Where the window's centre is on the screen, whatever its scale.
local function screenCenter(frame)
    local x, y = frame:GetCenter()
    local scale = frame:GetEffectiveScale()
    return x * scale, y * scale
end

test("the add-on has a page in the game's options, with every setting", function()
    Mock.Boot()
    local page = Mock.SettingsPage()
    eq(page ~= nil, true, "registered among the add-ons")
    eq(page.name, "Trading Book")
    local names = {}
    for _, control in ipairs(page.controls) do
        table.insert(names, control.kind .. ":" .. control.setting:GetName())
        eq(control.tooltip ~= nil, true, "explained: " .. control.setting:GetName())
    end
    eq(table.concat(names, ", "), "checkbox:Minimap icon, checkbox:Item tooltips, "
        .. "checkbox:Scan the auction house, checkbox:Custom window scale, slider:Window scale")

    local custom, slider = scaleControls()
    eq(slider.parent, custom, "the slider depends on the checkbox")
    eq(slider.options.minValue, 50)
    eq(slider.options.maxValue, 120)
    eq(slider.options.steps, 14, "steps of 5%")
    eq(slider.options.formatter(85), "85%")
end)

test("right-clicking the icon or the add-on menu entry opens the settings", function()
    local _, world = Mock.Boot()
    local id = Mock.SettingsPage():GetID()
    local button = TradingBookMinimapButton
    button.scripts.OnClick(button, "RightButton")
    eq(world.openedSettings, id, "from the icon")
    eq(TradingBookMainFrame, nil, "without opening the window")

    world.openedSettings = nil
    TradingBook_OnAddonCompartmentClick("TradingBook", "RightButton")
    eq(world.openedSettings, id, "from the add-on menu")
    TradingBook_OnAddonCompartmentClick("TradingBook", "LeftButton")
    eq(TradingBookMainFrame:IsShown(), true, "a left click still opens the window")

    world.openedSettings = nil
    SlashCmdList.TRADINGBOOK("settings")
    eq(world.openedSettings, id, "from the slash command")
end)

test("the minimap and tooltip settings agree with the slash commands", function()
    local ns, world = Mock.Boot()
    ns.Ledger.Add({ kind = "sold", itemID = 1001, name = "Herb", qty = 1, gross = 100 })
    local minimap = Mock.SettingsControl("Minimap icon").setting
    local tooltip = Mock.SettingsControl("Item tooltips").setting
    eq(minimap:GetValue(), true)
    eq(tooltip:GetValue(), true)

    minimap:SetValue(false)
    eq(TradingBookMinimapButton:IsShown(), false, "the icon hides")
    tooltip:SetValue(false)
    eq(hoverItem(1001), "", "the tooltip lines go")
    eq(#world.printed, 0, "quietly, the panel shows it")

    SlashCmdList.TRADINGBOOK("minimap")
    SlashCmdList.TRADINGBOOK("tooltip")
    eq(minimap:GetValue(), true, "the slash command shows in the settings")
    eq(tooltip:GetValue(), true)
    eq(minimap.updates > 0 and tooltip.updates > 0, true, "an open panel is told")
    eq(TradingBookMinimapButton:IsShown(), true)
    eq(has(hoverItem(1001), "Last sale"), true)

    minimap:SetValue(false)
    Mock.Boot({ db = TradingBookDB })
    eq(Mock.SettingsControl("Minimap icon").setting:GetValue(), false, "kept across a reload")
    eq(TradingBookMinimapButton:IsShown(), false)
end)

test("the window follows the game's UI scale until it has a scale of its own", function()
    Mock.Boot()
    UIParent:SetScale(0.8)
    SlashCmdList.TRADINGBOOK("")
    local frame = TradingBookMainFrame
    local custom, slider = scaleControls()
    near(frame:GetEffectiveScale(), 0.8, 0.0001, "the game's scale")
    eq(custom.setting:GetValue(), false)
    eq(Mock.IsControlEnabled(slider), false, "slider greyed out")
    eq(slider.setting:GetValue(), 80, "the slider shows the game's scale")
    slider.setting:SetValue(110)
    eq(TradingBookDB.ui.scale, nil, "a greyed-out slider changes nothing")

    custom.setting:SetValue(true)
    near(frame:GetEffectiveScale(), 0.8, 0.0001, "turning it on changes nothing yet")
    eq(Mock.IsControlEnabled(slider), true, "slider usable")

    slider.setting:SetValue(110)
    near(frame:GetEffectiveScale(), 1.1, 0.0001, "the window's own scale")

    UIParent:SetScale(0.6)
    Mock.Fire("UI_SCALE_CHANGED")
    near(frame:GetEffectiveScale(), 1.1, 0.0001, "kept when the game's scale changes")
    eq(slider.setting:GetValue(), 110)

    custom.setting:SetValue(false)
    near(frame:GetEffectiveScale(), 0.6, 0.0001, "the game's scale again")
    eq(TradingBookDB.ui.scale, nil)
end)

test("a scale of its own starts from the game's, on the slider's steps and range", function()
    Mock.Boot()
    local custom, slider = scaleControls()
    for _, case in ipairs({ { 0.71, 70 }, { 0.73, 75 }, { 0.4, 50 }, { 1.5, 120 } }) do
        UIParent:SetScale(case[1])
        custom.setting:SetValue(true)
        eq(slider.setting:GetValue(), case[2], "from " .. case[1])
        near(TradingBookDB.ui.scale, case[2] / 100, 0.0001, "saved from " .. case[1])
        custom.setting:SetValue(false)
    end
end)

test("the scale is set before the window first shows, and kept across a reload", function()
    Mock.Boot()
    UIParent:SetScale(0.7)
    local custom, slider = scaleControls()
    custom.setting:SetValue(true)
    slider.setting:SetValue(90)
    Mock.Fire("UI_SCALE_CHANGED") -- No window yet.
    SlashCmdList.TRADINGBOOK("")
    near(TradingBookMainFrame:GetEffectiveScale(), 0.9, 0.0001, "on creation")

    Mock.Boot({ db = TradingBookDB })
    UIParent:SetScale(0.7)
    SlashCmdList.TRADINGBOOK("")
    near(TradingBookMainFrame:GetEffectiveScale(), 0.9, 0.0001, "after a reload")
    eq(Mock.SettingsControl("Window scale").setting:GetValue(), 90)
end)

test("changing the scale keeps the window's centre on the same spot of the screen", function()
    Mock.Boot()
    UIParent:SetScale(0.8)
    SlashCmdList.TRADINGBOOK("")
    local frame = TradingBookMainFrame
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", 300, 1100)
    frame.scripts.OnDragStop(frame)
    local x, y = screenCenter(frame)

    local custom, slider = scaleControls()
    custom.setting:SetValue(true)
    slider.setting:SetValue(120)
    local newX, newY = screenCenter(frame)
    near(newX, x, 0.01, "x")
    near(newY, y, 0.01, "y")

    Mock.Boot({ db = TradingBookDB })
    UIParent:SetScale(0.8)
    SlashCmdList.TRADINGBOOK("")
    newX, newY = screenCenter(TradingBookMainFrame)
    near(newX, x, 0.01, "x after a reload")
    near(newY, y, 0.01, "y after a reload")
end)

test("restoring the defaults gives back the game's scale, the icon and the tooltip lines", function()
    for _, reverse in ipairs({ false, true }) do
        Mock.Boot()
        UIParent:SetScale(0.7)
        local page = Mock.SettingsPage()
        local custom, slider = scaleControls()
        custom.setting:SetValue(true)
        slider.setting:SetValue(110)
        Mock.SettingsControl("Minimap icon").setting:SetValue(false)
        Mock.SettingsControl("Item tooltips").setting:SetValue(false)

        local first, last, step = 1, #page.controls, 1
        if reverse then
            first, last, step = last, first, -1
        end
        for index = first, last, step do
            page.controls[index].setting:SetValueToDefault()
        end
        local order = reverse and "in reverse order" or "in order"
        eq(TradingBookDB.ui.scale, nil, "follows the game again, " .. order)
        eq(slider.setting:GetValue(), 70, "the slider shows the game's scale, " .. order)
        eq(TradingBookMinimapButton:IsShown(), true, "icon, " .. order)
        eq(TradingBookDB.ui.hideItemTooltip, nil, "tooltip lines, " .. order)
    end
end)

test("the slash command opens tabs and explains itself otherwise", function()
    local ns, world = Mock.Boot()
    SlashCmdList.TRADINGBOOK("")
    eq(TradingBookMainFrame:IsShown(), true)
    SlashCmdList.TRADINGBOOK("stats")
    SlashCmdList.TRADINGBOOK("STOCK")
    eq(#world.printed, 0)
    SlashCmdList.TRADINGBOOK("nonsense")
    eq(#world.printed, 1)
    TradingBook_OnAddonCompartmentClick()
end)

test("English needs no translation, and an unknown string falls back to it", function()
    local ns = Mock.Boot({ locale = "enUS" })
    eq(ns.Translation, nil)
    eq(ns.L["Purchases"], "Purchases")

    ns = Mock.Boot({ locale = "frFR" })
    eq(ns.L["Purchases"], "Achats")
    eq(ns.L["A string nobody translated"], "A string nobody translated")
end)

-- The strings the interface asks for, read from the sources listed in the TOC.
local function interfaceStrings()
    local keys = {}
    for line in io.lines("TradingBook.toc") do
        line = line:gsub("%s+$", "")
        if line ~= "" and line:sub(1, 2) ~= "##" and not line:find("^Locales") then
            for sourceLine in io.lines((line:gsub("\\", "/"))) do
                for key in sourceLine:gmatch('L%["(.-)"%]') do
                    keys[key] = true
                end
            end
        end
    end
    return keys
end

local function placeholders(text)
    local found = {}
    for placeholder in text:gmatch("%%[ds]") do
        table.insert(found, placeholder)
    end
    return table.concat(found, " ")
end

for _, locale in ipairs(LOCALES) do
    test(locale .. ": every interface string is translated, with the same placeholders", function()
        local ns = Mock.Boot({ locale = locale })
        local keys = interfaceStrings()
        local problems = {}
        for key in pairs(keys) do
            if not ns.Translation[key] then
                table.insert(problems, "missing: " .. key)
            end
        end
        for key, text in pairs(ns.Translation) do
            if not keys[key] then
                table.insert(problems, "unused: " .. key)
            elseif key ~= "%m/%d" and placeholders(key) ~= placeholders(text) then
                table.insert(problems, "placeholders: " .. key)
            end
        end
        table.sort(problems)
        eq(table.concat(problems, "; "), "")
    end)
end

test("the add-on list has a description and a category in every language", function()
    local lines = {}
    for line in io.lines("TradingBook.toc") do
        lines[line:match("^## ([^:]+):") or ""] = true
    end
    for _, locale in ipairs(LOCALES) do
        eq(lines["Notes-" .. locale], true, "description in " .. locale)
        eq(lines["Category-" .. locale], true, "category in " .. locale)
    end
end)

test("dates follow the order of the language", function()
    -- The clock of the fake client reads 5 November.
    local expected = {
        enUS = "11/05", enGB = "05/11", deDE = "05.11.", esES = "05/11", esMX = "05/11", frFR = "05/11",
        itIT = "05/11", koKR = "11/05", ptBR = "05/11", ruRU = "05.11", zhCN = "11/05", zhTW = "11/05",
    }
    for locale, day in pairs(expected) do
        local ns, world = Mock.Boot({ locale = locale })
        eq(ns.FormatDay(world.now), day, locale)
        eq(ns.FormatDate(world.now), day .. " 12:00", locale)
    end
end)

test("money formatting drops the small coins beside larger amounts", function()
    local ns = Mock.Boot()
    eq(ns.FormatMoney(nil), "-")
    eq(ns.FormatMoney(0), "0c")
    eq(ns.FormatMoney(9999), "9999c", "under a gold piece: as is")
    eq(ns.FormatMoney(12345), "12300c", "from a gold piece: to the silver")
    eq(ns.FormatMoney(-12345), "-12300c")
    eq(ns.FormatMoney(1234567), "1230000c", "from 100 gold: to the gold")
    eq(ns.FormatMoney(33.4), "33c", "averages are rounded")
    eq(ns.FormatSignedMoney(5), "+5c")
    eq(ns.FormatSignedMoney(-5), "-5c")
end)

test("exact money keeps every coin, for checking against an invoice", function()
    local ns = Mock.Boot()
    eq(ns.FormatExactMoney(nil), "-")
    eq(ns.FormatExactMoney(1234567), "1234567c")
    eq(ns.FormatExactMoney(-1234567), "-1234567c")
    eq(ns.FormatExactMoney(33.4), "33c")
end)

test("tooltips show exact amounts while the tables stay compact", function()
    local ns, world = Mock.Boot()
    local tables = captureTables(ns)
    ns.Ledger.Add({ kind = "sold", itemID = 1001, name = "Herb", qty = 1, gross = 1234567, cut = 61728, deposit = 0 })
    ns.UI.Open("auctions")
    local row = tables[1].ScrollBox.rendered[1]
    eq(row.cells[6].text, "+1170000c", "compact in the table")
    row.scripts.OnEnter(row)
    local lines = table.concat(GameTooltip.lines, ";")
    eq(lines:find("Sale price=1234567c", 1, true) ~= nil, true, "exact in the tooltip: " .. lines)
    eq(lines:find("Auction house cut=-61728c", 1, true) ~= nil, true, "exact cut")
end)

test("the sort arrow marks the sorted column, and flips with the direction", function()
    local ns, world = Mock.Boot()
    local tables = captureTables(ns)
    seedLedger(ns, world)
    ns.UI.Open("auctions")
    local list = tables[1]
    local amount, date_ = list.columns[6], list.columns[1]
    eq(date_.header.Arrow:IsShown(), true, "default column")
    eq(amount.header.Arrow:IsShown(), false)
    eq(date_.header.Arrow.atlas, "auctionhouse-ui-sortarrow")

    amount.header.scripts.OnClick(amount.header)
    eq(amount.header.Arrow:IsShown(), true, "moved")
    eq(date_.header.Arrow:IsShown(), false, "moved")
    local before = amount.header.Arrow.texCoord[3]
    amount.header.scripts.OnClick(amount.header)
    eq(amount.header.Arrow.texCoord[3] ~= before, true, "flipped")
end)

layoutTest("the sort arrow sits beside its title without covering it", function()
    local ns, world = Mock.Boot({ locale = layoutLocale })
    local tables = captureTables(ns)
    ns.UI.Open("stock")
    for _, column in ipairs(tables[1].columns) do
        local arrow = Mock.Rect(column.header.Arrow)
        local title = Mock.Rect(column.header.Text)
        if column.align == "RIGHT" then
            eq(arrow.right <= title.left, true, column.key .. ": left of a right-aligned title")
        else
            eq(arrow.left >= title.right, true, column.key .. ": right of a left-aligned title")
        end
    end
end)

layoutTest("table rows line up with their headers, on every tab", function()
    local ns, world = layoutFixture()
    local tables = captureTables(ns)
    for _, tab in ipairs({ "auctions", "stock", "stats", "gold" }) do
        ns.UI.Open(tab)
    end
    eq(#tables, 4)
    for index, tbl in ipairs(tables) do
        local row = tbl.ScrollBox.rendered[1]
        eq(row ~= nil, true, "table " .. index .. " has rows")
        for columnIndex, column in ipairs(tbl.columns) do
            local header = Mock.Rect(column.header)
            local cell = Mock.Rect(row.cells[columnIndex])
            if column.item or column.marker then
                eq(cell.right, header.right, ("table %d, %s: right edge"):format(index, column.key))
            else
                eq(cell.left, header.left, ("table %d, %s: left edge"):format(index, column.key))
                eq(cell.right, header.right, ("table %d, %s: right edge"):format(index, column.key))
            end
        end
    end
end)

test("the margins are generous enough to breathe", function()
    local ns = Mock.Boot()
    eq(ns.UI.PADDING >= 12, true, "window padding")
    eq(ns.UI.GAP >= 10, true, "gap between blocks")
end)

-- Runner --------------------------------------------------------------------

local failures = {}
for _, t in ipairs(tests) do
    local ok, err = xpcall(t.fn, function(message)
        return debug.traceback(tostring(message), 2)
    end)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        table.insert(failures, "FAIL  " .. t.name .. "\n      " .. tostring(err):gsub("\n", "\n      "))
    end
end

setmetatable(_G, nil)
for _, failure in ipairs(failures) do
    output(failure)
    output("")
end
output(("%d passed, %d failed"):format(passed, failed))

return failed
