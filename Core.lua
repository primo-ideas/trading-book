local addonName, ns = ...
local L = ns.L

-- Global handle for inspecting data in game, e.g. /dump TradingBook.db.ledger[1]
TradingBook = ns

-- Game events ---------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local eventHandlers = {}

function ns.OnEvent(event, handler)
    local handlers = eventHandlers[event]
    if not handlers then
        handlers = {}
        eventHandlers[event] = handlers
        eventFrame:RegisterEvent(event)
    end
    table.insert(handlers, handler)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    for _, handler in ipairs(eventHandlers[event]) do
        handler(...)
    end
end)

-- Internal messages ---------------------------------------------------------

local subscribers = {}

function ns.Subscribe(message, handler)
    subscribers[message] = subscribers[message] or {}
    table.insert(subscribers[message], handler)
end

function ns.Publish(message)
    for _, handler in ipairs(subscribers[message] or {}) do
        handler()
    end
end

local debounced = {}

-- Runs fn once after delay, however many times it is requested in between.
function ns.Debounce(key, delay, fn)
    if debounced[key] then
        return
    end
    debounced[key] = true
    C_Timer.After(delay, function()
        debounced[key] = nil
        fn()
    end)
end

-- Saved data ----------------------------------------------------------------

local function InitDB()
    TradingBookDB = TradingBookDB or {}
    local db = TradingBookDB
    db.schema = db.schema or 1
    db.characters = db.characters or {}
    db.warband = db.warband or { items = {}, money = 0 }
    db.ledger = db.ledger or {}
    db.items = db.items or {}
    db.itemIDsByName = db.itemIDsByName or {}
    db.stockHistory = db.stockHistory or {}
    db.goldHistory = nil -- An account total from the first version, replaced by per-holder histories.
    db.ui = db.ui or {}
    ns.db = db
end

function ns.GetCharacter(key)
    key = key or ns.playerKey
    local character = ns.db.characters[key]
    if not character then
        character = { money = 0, stock = { bags = {}, bank = {}, mail = {} }, auctions = {} }
        ns.db.characters[key] = character
    end
    return character
end

ns.OnEvent("ADDON_LOADED", function(name)
    if name == addonName then
        InitDB()
    end
end)

ns.OnEvent("PLAYER_LOGIN", function()
    ns.playerKey = UnitName("player") .. "-" .. GetRealmName()
    ns.Ledger.Prune()
end)

-- Item details --------------------------------------------------------------

-- Details are kept so that alts' items still display when not in the client cache.
function ns.RememberItem(itemID, name, quality, icon)
    if not itemID then
        return
    end
    local info = ns.db.items[itemID]
    if not info then
        info = {}
        ns.db.items[itemID] = info
    end
    info.name = name or info.name
    info.quality = quality or info.quality
    info.icon = icon or info.icon
    if name then
        ns.db.itemIDsByName[name] = itemID
    end
end

function ns.GetItemDetails(itemID)
    local info = itemID and ns.db.items[itemID]
    if info and info.name then
        return info.name, info.quality, info.icon
    end
    if itemID then
        return C_Item.GetItemNameByID(itemID), C_Item.GetItemQualityByID(itemID), C_Item.GetItemIconByID(itemID)
    end
end

-- Sale mails only carry the item's name.
function ns.LookupItemID(name)
    if not name then
        return nil
    end
    return ns.db.itemIDsByName[name] or (C_Item.GetItemInfoInstant(name))
end

-- Formatting ----------------------------------------------------------------

local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD = 10000

local function CoinString(amount, isNegative)
    return (isNegative and "-" or "") .. C_CurrencyInfo.GetCoinTextureString(amount)
end

-- To the copper, where an amount has to be checked against an invoice.
function ns.FormatExactMoney(copper)
    if not copper then
        return "-"
    end
    return CoinString(math.floor(math.abs(copper) + 0.5), copper < 0)
end

-- Compact, for tables and tiles: the small coins are noise beside larger amounts.
function ns.FormatMoney(copper)
    if not copper then
        return "-"
    end
    local amount = math.floor(math.abs(copper) + 0.5)
    if amount >= 100 * COPPER_PER_GOLD then
        amount = math.floor(amount / COPPER_PER_GOLD + 0.5) * COPPER_PER_GOLD
    elseif amount >= COPPER_PER_GOLD then
        amount = math.floor(amount / COPPER_PER_SILVER + 0.5) * COPPER_PER_SILVER
    end
    return CoinString(amount, copper < 0)
end

function ns.FormatSignedMoney(copper)
    if copper and copper > 0 then
        return "+" .. ns.FormatMoney(copper)
    end
    return ns.FormatMoney(copper)
end

function ns.FormatCount(count)
    if not count or count == 0 then
        return "-"
    end
    return BreakUpLargeNumbers(count)
end

-- The order of day and month comes from the language.
function ns.FormatDay(t)
    return date(L["%m/%d"], t)
end

function ns.FormatDate(t)
    return t and date(L["%m/%d"] .. " %H:%M", t) or L["never"]
end

function ns.FormatDuration(seconds)
    if seconds >= 86400 then
        return L["%d d"]:format(math.floor(seconds / 86400))
    elseif seconds >= 3600 then
        return L["%d h"]:format(math.floor(seconds / 3600))
    end
    return L["%d min"]:format(math.max(1, math.floor(seconds / 60)))
end

function ns.FormatPercent(ratio, signed)
    if not ratio then
        return "-"
    end
    return (signed and "%+.1f%%" or "%.1f%%"):format(ratio * 100)
end

function ns.CharacterName(key)
    return key and key:match("^[^-]+") or ""
end

-- The name alone, in its class colour when the class is known.
function ns.ColoredCharacterName(key)
    local name = ns.CharacterName(key)
    local character = key and ns.db.characters[key]
    local color = character and character.class and RAID_CLASS_COLORS[character.class]
    if not color then
        return name
    end
    return ("|cff%02x%02x%02x%s|r"):format(
        math.floor(color.r * 255), math.floor(color.g * 255), math.floor(color.b * 255), name)
end

function ns.DayKey(t)
    return tonumber(date("%Y%m%d", t))
end

-- Noon on that day, safely away from clock changes.
function ns.DayKeyToTime(day)
    return time({
        year = math.floor(day / 10000),
        month = math.floor(day / 100) % 100,
        day = day % 100,
        hour = 12,
    })
end

function ns.Print(message)
    print("|cffffd200Trading Book|r: " .. message)
end

-- Entry points --------------------------------------------------------------

SLASH_TRADINGBOOK1 = "/tradingbook"
SlashCmdList.TRADINGBOOK = function(message)
    local command = message:lower():match("^%s*(%S*)")
    if command == "" then
        ns.UI.Toggle()
    elseif command == "auctions" or command == "stock" or command == "stats" or command == "gold" then
        ns.UI.Open(command)
    elseif command == "minimap" then
        ns.UI.ToggleMinimapButton()
    else
        ns.Print(L["Usage: /tradingbook [auctions | stock | stats | gold | minimap]"])
    end
end

-- Named by AddonCompartmentFunc in the TOC.
function TradingBook_OnAddonCompartmentClick()
    ns.UI.Toggle()
end
