local _, ns = ...
local UI = ns.UI

-- Sections the player can put in an order of their own, from the settings: the
-- window's tabs, the blocks of item tooltips and the tiles of the Stats tab. Each
-- owner registers its items in their default order, and only the player's order of
-- keys is saved, so that a section added later still shows up.
local lists = {}

local function FindList(kind)
    for _, list in ipairs(lists) do
        if list.kind == kind then
            return list
        end
    end
    error("Unknown order: " .. tostring(kind))
end

-- items: { key, label } in the default order. Returns the array, which the owner
-- may still add items to.
function UI.RegisterOrder(kind, title, items)
    local list = { kind = kind, title = title, items = items or {} }
    table.insert(lists, list)
    return list.items
end

-- Every list, in the order they were registered: { kind, title, items }.
function UI.GetOrderLists()
    return lists
end

function UI.GetOrderLabel(kind, key)
    for _, item in ipairs(FindList(kind).items) do
        if item.key == key then
            return item.label
        end
    end
end

-- The keys of a list in the player's order. A key no longer known is dropped, and
-- one missing from the saved order keeps its default rank among the others.
function UI.GetOrder(kind)
    local list = FindList(kind)
    local known = {}
    for _, item in ipairs(list.items) do
        known[item.key] = true
    end
    local orders = ns.db and ns.db.ui.order
    local saved = orders and orders[kind] or {}
    local keys, placed = {}, {}
    for _, key in ipairs(saved) do
        if known[key] and not placed[key] then
            keys[#keys + 1] = key
            placed[key] = true
        end
    end
    for index, item in ipairs(list.items) do
        if not placed[item.key] then
            table.insert(keys, math.min(index, #keys + 1), item.key)
        end
    end
    return keys
end

local function IsDefault(kind, keys)
    for index, item in ipairs(FindList(kind).items) do
        if keys[index] ~= item.key then
            return false
        end
    end
    return true
end

-- keys: the whole list in its new order, or nil for the default one.
function UI.SetOrder(kind, keys)
    local orders = ns.db.ui.order or {}
    if keys and not IsDefault(kind, keys) then
        local copy = {}
        for index, key in ipairs(keys) do
            copy[index] = key
        end
        orders[kind] = copy
    else
        orders[kind] = nil
    end
    ns.db.ui.order = next(orders) and orders or nil
    ns.Publish("ORDER_CHANGED")
end

-- Moves an item one rank up (-1) or down (+1). Returns whether it moved.
function UI.MoveInOrder(kind, key, offset)
    local keys = UI.GetOrder(kind)
    for index, candidate in ipairs(keys) do
        if candidate == key then
            local target = index + offset
            if target < 1 or target > #keys then
                return false
            end
            keys[index], keys[target] = keys[target], keys[index]
            UI.SetOrder(kind, keys)
            return true
        end
    end
    return false
end

function UI.ResetOrders()
    ns.db.ui.order = nil
    ns.Publish("ORDER_CHANGED")
end
