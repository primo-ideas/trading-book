local _, ns = ...
local L = ns.L
local UI = ns.UI

-- Adds what the account holds of an item and what it sold for to the item's
-- tooltip, wherever the game shows one: bags, bank, auction house, chat links.
-- Without a price from Auctionator, which shows its own, it also gives the auction
-- house price from Trading Book's scan.
-- Trading Book's own windows already show all this, so their tooltips are left alone,
-- and so are the comparison tooltips beside an item, which would only repeat it.
--
-- The lines come together at the bottom of the tooltip, with no title to save room,
-- in blocks the player can put in an order of their own.

local BLOCKS = {
    {
        key = "stock",
        label = L["Stock"],
        Add = function(tooltip, item)
            local stock = item.stock
            if not stock then
                return
            end
            UI.AddValueLine(tooltip, L["Stock"], BreakUpLargeNumbers(stock.total))
            UI.AddHoldingLines(tooltip, stock)
            local unit = ns.Stats.GetUnitPrice(item.itemID)
            if unit then
                UI.AddValueLine(tooltip, L["Stock value"], ns.FormatMoney(unit * stock.total))
            end
        end,
    },
    {
        key = "market",
        label = L["Auction house price"],
        Add = function(tooltip, item)
            local market = item.market
            if not market then
                return
            end
            UI.AddValueLine(tooltip, L["AH price (%s ago)"]:format(ns.FormatDuration(time() - market.seenAt)),
                ns.FormatMoney(market.price))
            UI.AddValueLine(tooltip, L["On the AH"], ns.FormatCount(market.quantity))
            local change, since = ns.Market.GetChange(item.itemID)
            if change then
                UI.AddValueLine(tooltip, L["Change since %s"]:format(ns.FormatDay(since)), ns.FormatPercent(change, true))
            end
        end,
    },
    {
        key = "watch",
        label = L["Price targets"],
        Add = function(tooltip, item)
            local watched = item.watched
            if watched and watched.below then
                UI.AddValueLine(tooltip, L["Buy target"], ns.FormatMoney(watched.below))
            end
            if watched and watched.above then
                UI.AddValueLine(tooltip, L["Sell target"], ns.FormatMoney(watched.above))
            end
        end,
    },
    {
        key = "sales",
        label = L["Sales"],
        Add = function(tooltip, item)
            local sales = item.sales
            if sales and sales.average then
                UI.AddValueLine(tooltip, L["Avg. sale (90 days)"], ns.FormatMoney(sales.average))
            end
            if sales then
                local last = sales.last
                UI.AddValueLine(tooltip, L["Last sale (%s)"]:format(ns.FormatDay(last.t)),
                    ns.FormatMoney((last.gross or 0) / (last.qty or 1)))
            end
        end,
    },
    {
        key = "profit",
        label = L["Profit"],
        Add = function(tooltip, item)
            local profit = item.profit
            if not profit then
                return
            end
            if profit.unitProfit then
                UI.AddValueLine(tooltip, L["Profit per unit (90 days)"], ns.FormatSignedMoney(profit.unitProfit))
            end
            if profit.sellThrough then
                UI.AddValueLine(tooltip, L["Sold %"], ns.FormatPercent(profit.sellThrough))
            end
            if profit.timeToSell then
                UI.AddValueLine(tooltip, L["Time to sell"], ns.FormatDuration(profit.timeToSell))
            end
            local advice = profit.advice and ns.Profit.ADVICE[profit.advice]
            if advice then
                local color = advice.bad and UI.Colors.loss or UI.Colors.gain
                tooltip:AddLine(advice.text, color[1], color[2], color[3], true)
            end
        end,
    },
}

local blockOrder = UI.RegisterOrder("tooltip", L["Item tooltips"])
for _, block in ipairs(BLOCKS) do
    table.insert(blockOrder, { key = block.key, label = block.label })
end

local function FindBlock(key)
    for _, block in ipairs(BLOCKS) do
        if block.key == key then
            return block
        end
    end
end

local function AddLines(tooltip, itemID)
    local item = {
        itemID = itemID,
        stock = ns.Stockpile.GetItemRow(itemID),
        sales = ns.Stats.GetSaleStats(itemID),
        market = not ns.Stats.GetAuctionatorPrice(itemID) and ns.Market.GetItem(itemID) or nil,
        watched = ns.Watch.Get(itemID),
        profit = ns.Profit.GetRecent(itemID),
    }
    for _, key in ipairs(UI.GetOrder("tooltip")) do
        FindBlock(key).Add(tooltip, item)
    end
end

-- Runs each time an item tooltip is filled, including its refreshes while hovered.
local function OnItemTooltip(tooltip, data)
    if not ns.db or ns.db.ui.hideItemTooltip then
        return
    end
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then
        return
    end
    if UI.IsOwnFrame(tooltip:GetOwner()) then
        return
    end
    if data and data.id then
        AddLines(tooltip, data.id)
    end
end

-- Post calls run in the order they were added: added once every addon has loaded,
-- Trading Book's lines come after those of the others.
ns.OnEvent("PLAYER_LOGIN", function()
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
end)

function UI.IsItemTooltipShown()
    return not ns.db.ui.hideItemTooltip
end

function UI.SetItemTooltipShown(shown)
    ns.db.ui.hideItemTooltip = not shown or nil
end

function UI.ToggleItemTooltip()
    local shown = not UI.IsItemTooltipShown()
    UI.SetItemTooltipShown(shown)
    UI.RefreshSettings()
    if shown then
        ns.Print(L["Item tooltip lines shown."])
    else
        ns.Print(L["Item tooltip lines hidden. Type /tradingbook tooltip to bring them back."])
    end
end
