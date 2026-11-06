local _, ns = ...
local L = ns.L

-- Items watched for a price: a target to buy at or below, to sell at or above, or
-- both. Each auction house scan checks them and says in the chat which ones hit
-- their target.
local Watch = {}
ns.Watch = Watch

local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD = 10000

-- Amounts as players write them: 12g50s25c, 50s, 75c, or a number of gold such as
-- 12 or 12.5. The letters stay English in every language, like the commands.
function Watch.ParseMoney(text)
    text = text and text:lower()
    if not text or text == "" then
        return nil
    end
    local gold = tonumber(text:match("^%d+%.?%d*$") or text:match("^%d*%.%d+$"))
    if gold then
        return math.floor(gold * COPPER_PER_GOLD + 0.5)
    end
    local copper = 0
    local rest = text:gsub("(%d+)([gsc])", function(amount, unit)
        local value = tonumber(amount)
        if unit == "g" then
            copper = copper + value * COPPER_PER_GOLD
        elseif unit == "s" then
            copper = copper + value * COPPER_PER_SILVER
        else
            copper = copper + value
        end
        return ""
    end)
    if rest ~= "" then
        return nil
    end
    return copper
end

-- The item a command names, from a shift-clicked link or an exact name, and what
-- follows the link. Returns itemID, link, rest.
local function ReadItem(text)
    local itemID = tonumber(text:match("|Hitem:(%d+)"))
    if itemID then
        local link = text:match("(|c.-|Hitem:.-|h.-|h|r)") or text:match("(|Hitem:.-|h.-|h)")
        local rest = text:match("|Hitem:.-|h.-|h|?r?(.*)$") or ""
        return itemID, link, rest
    end
    return nil, nil, text
end

local function DisplayName(itemID)
    local watched = ns.db.watch[itemID]
    return (watched and watched.link) or ns.GetItemDetails(itemID) or L["Unknown item"]
end

local function TargetParts(watched)
    local parts = {}
    if watched.below then
        table.insert(parts, L["buy at %s or less"]:format(ns.FormatMoney(watched.below)))
    end
    if watched.above then
        table.insert(parts, L["sell at %s or more"]:format(ns.FormatMoney(watched.above)))
    end
    return parts
end

-- { below, above, link } for a watched item, or nil.
function Watch.Get(itemID)
    return itemID and ns.db.watch[itemID]
end

-- direction: "below" or "above". A nil price removes that target.
function Watch.Set(itemID, direction, price, link)
    local watched = ns.db.watch[itemID] or {}
    watched[direction] = price
    watched.link = link or watched.link
    if not watched.below and not watched.above then
        watched = nil
    end
    ns.db.watch[itemID] = watched
end

function Watch.Remove(itemID)
    ns.db.watch[itemID] = nil
end

-- Commands -------------------------------------------------------------------------

local function List()
    local itemIDs = {}
    for itemID in pairs(ns.db.watch) do
        table.insert(itemIDs, itemID)
    end
    if #itemIDs == 0 then
        ns.Print(L["No item is watched. /tradingbook watch followed by an item and a price adds one."])
        return
    end
    table.sort(itemIDs, function(a, b)
        return (ns.GetItemDetails(a) or "") < (ns.GetItemDetails(b) or "")
    end)
    ns.Print(L["Watched items:"])
    for _, itemID in ipairs(itemIDs) do
        local parts = TargetParts(ns.db.watch[itemID])
        local market = ns.Market.GetItem(itemID)
        if market and market.quantity > 0 then
            table.insert(parts, L["now %s"]:format(ns.FormatMoney(market.price)))
        else
            table.insert(parts, L["no price yet"])
        end
        print("  " .. DisplayName(itemID) .. ": " .. table.concat(parts, ", "))
    end
end

-- /tradingbook watch [item [below|above] price]
function Watch.Command(text)
    text = text:match("^%s*(.-)%s*$")
    if text == "" then
        List()
        return
    end
    local itemID, link, rest = ReadItem(text)
    local words = {}
    for word in rest:gmatch("%S+") do
        table.insert(words, word)
    end
    local price = Watch.ParseMoney(table.remove(words))
    local direction = "below"
    local keyword = words[#words] and words[#words]:lower()
    if keyword == "below" or keyword == "above" then
        direction = keyword
        table.remove(words)
    end
    if not itemID then
        itemID = ns.LookupItemID(table.concat(words, " "))
    elseif #words > 0 then
        itemID = nil -- Words left between the link and the price.
    end
    if not itemID then
        ns.Print(L["Unknown item. Shift-click it into the command, or type its exact name."])
        return
    end
    if not price then
        ns.Print(L["Unknown price. Write it like 12g50s, 50s or 12.5."])
        return
    end
    Watch.Set(itemID, direction, price, link)
    ns.Print(L["Watching %s: %s."]:format(DisplayName(itemID), table.concat(TargetParts(ns.db.watch[itemID]), ", ")))
end

-- /tradingbook unwatch item
function Watch.UnwatchCommand(text)
    local itemID, _, rest = ReadItem(text:match("^%s*(.-)%s*$"))
    itemID = itemID or ns.LookupItemID(rest)
    if not itemID then
        ns.Print(L["Unknown item. Shift-click it into the command, or type its exact name."])
        return
    end
    local name = DisplayName(itemID)
    if not ns.db.watch[itemID] then
        ns.Print(L["%s is not watched."]:format(name))
        return
    end
    Watch.Remove(itemID)
    ns.Print(L["%s is no longer watched."]:format(name))
end

-- Alerts ---------------------------------------------------------------------------

-- Checked after each scan, against what is on sale at that moment.
ns.Subscribe("MARKET_CHANGED", function()
    for itemID, watched in pairs(ns.db.watch) do
        local market = ns.Market.GetItem(itemID)
        if market and market.quantity > 0 then
            local price = ns.FormatMoney(market.price)
            if watched.below and market.price <= watched.below then
                ns.Print(L["Watched %s is at %s: %s."]:format(DisplayName(itemID), price,
                    L["buy at %s or less"]:format(ns.FormatMoney(watched.below))))
            end
            if watched.above and market.price >= watched.above then
                ns.Print(L["Watched %s is at %s: %s."]:format(DisplayName(itemID), price,
                    L["sell at %s or more"]:format(ns.FormatMoney(watched.above))))
            end
        end
    end
end)
