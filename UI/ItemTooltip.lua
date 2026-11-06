local _, ns = ...
local L = ns.L
local UI = ns.UI

-- Adds what the account holds of an item and what it sold for to the item's
-- tooltip, wherever the game shows one: bags, bank, auction house, chat links.
-- Trading Book's own window already shows all this, so its tooltips are left alone,
-- and so are the comparison tooltips beside an item, which would only repeat it.

local function AddLines(tooltip, itemID)
    local stock = ns.Stockpile.GetItemRow(itemID)
    local sales = ns.Stats.GetSaleStats(itemID)
    if not stock and not sales then
        return
    end
    local accent = UI.Colors.accent
    tooltip:AddLine(" ")
    tooltip:AddLine("Trading Book", accent[1], accent[2], accent[3])
    if stock then
        UI.AddValueLine(tooltip, L["Stock"], BreakUpLargeNumbers(stock.total))
        UI.AddHoldingLines(tooltip, stock)
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
