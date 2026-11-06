local _, ns = ...
local L = ns.L
local UI = ns.UI

-- Adds what the account holds of an item and what it sold for to the item's
-- tooltip, wherever the game shows one: bags, bank, auction house, chat links.
-- Without a price from Auctionator, which shows its own, it also gives the auction
-- house price from Trading Book's scan.
-- Trading Book's own window already shows all this, so its tooltips are left alone,
-- and so are the comparison tooltips beside an item, which would only repeat it.

local function AddLines(tooltip, itemID)
    local stock = ns.Stockpile.GetItemRow(itemID)
    local sales = ns.Stats.GetSaleStats(itemID)
    local market = not ns.Stats.GetAuctionatorPrice(itemID) and ns.Market.GetItem(itemID)
    local watched = ns.Watch.Get(itemID)
    if not stock and not sales and not market and not watched then
        return
    end
    local accent = UI.Colors.accent
    tooltip:AddLine(" ")
    tooltip:AddLine("Trading Book", accent[1], accent[2], accent[3])
    if stock then
        UI.AddValueLine(tooltip, L["Stock"], BreakUpLargeNumbers(stock.total))
        UI.AddHoldingLines(tooltip, stock)
        local unit = ns.Stats.GetUnitPrice(itemID)
        if unit then
            UI.AddValueLine(tooltip, L["Stock value"], ns.FormatMoney(unit * stock.total))
        end
    end
    if market then
        UI.AddValueLine(tooltip, L["AH price (%s ago)"]:format(ns.FormatDuration(time() - market.seenAt)),
            ns.FormatMoney(market.price))
        UI.AddValueLine(tooltip, L["On the AH"], ns.FormatCount(market.quantity))
        local change, since = ns.Market.GetChange(itemID)
        if change then
            UI.AddValueLine(tooltip, L["Change since %s"]:format(ns.FormatDay(since)), ns.FormatPercent(change, true))
        end
    end
    if watched and watched.below then
        UI.AddValueLine(tooltip, L["Buy target"], ns.FormatMoney(watched.below))
    end
    if watched and watched.above then
        UI.AddValueLine(tooltip, L["Sell target"], ns.FormatMoney(watched.above))
    end
    if sales and sales.average then
        UI.AddValueLine(tooltip, L["Avg. sale (90 days)"], ns.FormatMoney(sales.average))
    end
    if sales then
        local last = sales.last
        UI.AddValueLine(tooltip, L["Last sale (%s)"]:format(ns.FormatDay(last.t)),
            ns.FormatMoney((last.gross or 0) / (last.qty or 1)))
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

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)

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
