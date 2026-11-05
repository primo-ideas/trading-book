-- A small stand-in for the WoW client, enough to run the addon outside the game.
-- It is strict on purpose: unknown globals and frame methods raise errors, so a
-- typo fails a test instead of silently doing nothing.
--
-- It resolves anchors into rectangles like the client does, which lets tests check
-- layout. Text widths are estimates, and nothing is actually drawn.

local Mock = {}

local realG = _G
local allowedGlobals = {
    -- Written by the addon.
    TradingBook = true, TradingBookDB = true, SLASH_TRADINGBOOK1 = true,
    TradingBook_OnAddonCompartmentClick = true, TradingBookMainFrame = true,
    TradingBookMinimapButton = true,
    -- Optional dependency, nil when not installed.
    Auctionator = true,
}

-- Methods the addon calls whose effect does not matter here.
local NO_OP_METHODS = {
    "SetFrameStrata", "SetToplevel", "SetMovable", "SetClampedToScreen", "EnableMouse",
    "RegisterForDrag", "StartMoving", "StopMovingOrSizing", "SetID", "SetTitle",
    "SetWordWrap", "SetAutoFocus", "SetFixedFrameStrata", "SetFrameLevel",
    "SetFixedFrameLevel", "RegisterForClicks", "SetHighlightTexture",
    "LockHighlight", "UnlockHighlight", "SetThickness", "SetPortraitToAsset",
}

-- Fields that may be read before being set, or never set, on a widget.
local OPTIONAL_FIELDS = {
    cells = true, markers = true, Stripe = true, Icon = true, data = true, bar = true,
    Text = true, Value = true, Bar = true, Inset = true, header = true, onEnter = true,
    OnSlotLeave = true, Empty = true, Label = true,
}

-- Character width and line height of the fonts the addon uses. On the wide side,
-- so that layout checks keep some margin against the real font.
local FONTS = {
    GameFontHighlightSmall = { 6.2, 11 },
    GameFontNormalSmall = { 6.2, 11 },
    GameFontDisableSmall = { 6.2, 11 },
    GameFontNormal = { 7.2, 13 },
    GameFontHighlight = { 7.2, 13 },
    GameFontDisable = { 7.2, 13 },
    GameFontHighlightLarge = { 9.6, 17 },
}
local COIN_ICON_WIDTH = 14

local world, objects

local Object = {}

for _, name in ipairs(NO_OP_METHODS) do
    Object[name] = function() end
end

local function NewObject(fields)
    fields = fields or {}
    fields.scripts = {}
    fields.shown = true
    fields.text = ""
    fields.points = {}
    fields.kind = fields.kind or "frame"
    fields.template = fields.template or false
    local object = setmetatable(fields, {
        __index = function(_, key)
            local method = Object[key]
            if method then
                return method
            end
            if OPTIONAL_FIELDS[key] then
                return nil
            end
            error("Unknown widget field or method: " .. tostring(key), 2)
        end,
    })
    if objects then
        table.insert(objects, object)
    end
    return object
end

function Object:Show()
    local wasShown = self.shown
    self.shown = true
    if not wasShown and self.scripts.OnShow then
        self.scripts.OnShow(self)
    end
end
function Object:Hide() self.shown = false end
function Object:SetShown(shown) if shown then self:Show() else self:Hide() end end
function Object:IsShown() return self.shown end
function Object:SetText(text) self.text = text end
function Object:GetText() return self.text end
function Object:GetFontString() return self.fontString end
function Object:GetPoint() return "CENTER", nil, "CENTER", 10, 20 end
function Object:SetChecked(checked) self.checked = checked end
function Object:GetChecked() return self.checked end
function Object:SetScript(name, fn) self.scripts[name] = fn end
function Object:GetScript(name) return self.scripts[name] end
function Object:HookScript(name, fn)
    local previous = self.scripts[name]
    self.scripts[name] = function(...)
        if previous then previous(...) end
        fn(...)
    end
end
function Object:RegisterEvent(event)
    world.registered[event] = world.registered[event] or {}
    table.insert(world.registered[event], self)
end
function Object:SetTextColor(r, g, b) self.textColor = { r, g, b } end
function Object:SetColorTexture(r, g, b, a) self.color = { r, g, b, a or 1 } end
function Object:SetTexture(texture) self.texture = texture end
function Object:SetTexCoord(left, right, top, bottom) self.texCoord = { left, right, top, bottom } end
function Object:SetAtlas(atlas, useAtlasSize)
    self.atlas = atlas
    if useAtlasSize then
        self.width, self.height = 11, 7
    end
end
function Object:SetJustifyH(justify) self.justify = justify end
function Object:SetAlpha(alpha) self.alpha = alpha end
function Object:SetEnabled(enabled) self.enabled = enabled end
function Object:SetStartPoint(_, relativeTo, x, y) self.lineStart = { relativeTo = relativeTo, x = x, y = y } end
function Object:SetEndPoint(_, relativeTo, x, y) self.lineEnd = { relativeTo = relativeTo, x = x, y = y } end

function Object:CreateFontString(_, layer, font)
    assert(font == nil or FONTS[font], "Unknown font: " .. tostring(font))
    return NewObject({ kind = "text", parent = self, layer = layer or "ARTWORK", font = font or "GameFontHighlight" })
end
function Object:CreateTexture(_, layer)
    return NewObject({ kind = "texture", parent = self, layer = layer or "ARTWORK" })
end
function Object:CreateLine(_, layer)
    return NewObject({ kind = "line", parent = self, layer = layer or "ARTWORK" })
end

-- Size ---------------------------------------------------------------------------

function Object:SetSize(width, height) self.width, self.height = width, height end
function Object:SetWidth(width) self.width = width end
function Object:SetHeight(height) self.height = height end
function Object:GetWidth() return self.width end
function Object:GetHeight() return self.height end
function Object:GetCenter() return self.centerX, self.centerY end
function Object:GetEffectiveScale() return self.effectiveScale end

function Object:GetStringWidth()
    local text = tostring(self.text)
    local icons = 0
    text = text:gsub("|T.-|t", function()
        icons = icons + 1
        return ""
    end)
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    -- Continuation bytes are not characters. The 3-byte ones here are CJK and Hangul,
    -- about twice as wide as a Latin letter.
    local characters = #(text:gsub("[\128-\191]", "")) + select(2, text:gsub("[\224-\239]", ""))
    return characters * FONTS[self.font][1] + icons * COIN_ICON_WIDTH
end

-- Anchors ------------------------------------------------------------------------

-- Accepts every form the client does, and like it replaces an anchor on the same point.
function Object:SetPoint(point, a, b, c, d)
    local relativeTo, relativePoint, x, y
    if type(a) == "number" then
        x, y = a, b
    elseif type(b) == "number" then
        relativeTo, x, y = a, b, c
    else
        relativeTo, relativePoint, x, y = a, b, c, d
    end
    local anchor = {
        point = point,
        relativeTo = relativeTo or self.parent,
        relativePoint = relativePoint or point,
        x = x or 0,
        y = y or 0,
    }
    self.points[point] = anchor
    self.lastPoint = anchor
end

function Object:ClearAllPoints()
    self.points = {}
end

function Object:SetAllPoints(target)
    self:SetPoint("TOPLEFT", target or self.parent, "TOPLEFT")
    self:SetPoint("BOTTOMRIGHT", target or self.parent, "BOTTOMRIGHT")
end

local function PointIn(rect, point)
    local x = (rect.left + rect.right) / 2
    local y = (rect.top + rect.bottom) / 2
    if point:find("LEFT") then x = rect.left elseif point:find("RIGHT") then x = rect.right end
    if point:find("TOP") then y = rect.top elseif point:find("BOTTOM") then y = rect.bottom end
    return x, y
end

-- Screen rectangle of an object, y going up, or nil when it has no anchors.
function Mock.Rect(object)
    if rawget(object, "rect") then
        return object.rect
    end
    if object.kind == "line" then
        local start, stop = rawget(object, "lineStart"), rawget(object, "lineEnd")
        if not (start and stop) then return nil end
        local origin = Mock.Rect(start.relativeTo)
        local x1, y1 = origin.left + start.x, origin.bottom + start.y
        local x2, y2 = origin.left + stop.x, origin.bottom + stop.y
        return { left = math.min(x1, x2), right = math.max(x1, x2), top = math.max(y1, y2), bottom = math.min(y1, y2) }
    end
    if next(object.points) == nil then
        return nil
    end

    local left, right, top, bottom, centerX, centerY
    for point, anchor in pairs(object.points) do
        local target = Mock.Rect(anchor.relativeTo)
        if not target then return nil end
        local x, y = PointIn(target, anchor.relativePoint)
        x, y = x + anchor.x, y + anchor.y
        if point:find("LEFT") then left = x elseif point:find("RIGHT") then right = x else centerX = x end
        if point:find("TOP") then top = y elseif point:find("BOTTOM") then bottom = y else centerY = y end
    end

    local width, height = rawget(object, "width"), rawget(object, "height")
    if object.kind == "text" then
        width = width or object:GetStringWidth()
        height = height or FONTS[object.font][2]
    end
    width, height = width or 0, height or 0

    if left and right then
        width = right - left
    elseif left then
        right = left + width
    elseif right then
        left = right - width
    else
        left, right = centerX - width / 2, centerX + width / 2
    end
    if top and bottom then
        height = top - bottom
    elseif top then
        bottom = top - height
    elseif bottom then
        top = bottom + height
    else
        top, bottom = centerY + height / 2, centerY - height / 2
    end
    return { left = left, right = right, top = top, bottom = bottom }
end

function Mock.IsVisible(object)
    while object do
        if not object.shown then
            return false
        end
        object = rawget(object, "parent")
    end
    return true
end

function Mock.IsWithin(object, ancestor)
    object = rawget(object, "parent")
    while object do
        if object == ancestor then
            return true
        end
        object = rawget(object, "parent")
    end
    return false
end

function Mock.Objects()
    return objects
end

-- Templates ----------------------------------------------------------------------

local function TabTemplate(frame)
    frame.width, frame.height = 90, 32
end

local TEMPLATES = {
    ButtonFrameTemplate = function(frame)
        frame.Inset = NewObject({ parent = frame, frameType = "Frame", template = "InsetFrameTemplate" })
        frame.Inset:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -60)
        frame.Inset:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 26)
    end,
    PanelTabButtonTemplate = TabTemplate,
    SearchBoxTemplate = true,
    WowStyle1DropdownTemplate = function(frame)
        frame.width, frame.height = 150, 25
        function frame.SetupMenu(self, generator)
            assert(type(generator) == "function")
            self.generator = generator
        end
    end,
    WowScrollBoxList = function(frame)
        function frame.SetDataProvider(self, provider, retain)
            assert(retain ~= nil, "SetDataProvider called without a scroll retention constant")
            self.provider = provider
            for _, row in ipairs(rawget(self, "rendered") or {}) do
                row:Hide()
            end
            self.rendered = {}
            -- Like the real list, initialise row frames for what fits on screen.
            local extent = self.view.extent
            local rect = Mock.Rect(self)
            local capacity = rect and math.floor((rect.top - rect.bottom) / extent) or 25
            for index = 1, math.min(#provider.collection, capacity) do
                local row = NewObject({ parent = self, frameType = "Button" })
                row.height = extent
                row:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -(index - 1) * extent)
                row:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, -(index - 1) * extent)
                self.view.initializer(row, provider.collection[index])
                self.rendered[index] = row
            end
        end
    end,
    WowTrimScrollBar = function(frame)
        frame.width = 16
    end,
}

local function CreateFrameMock(frameType, name, parent, template)
    assert(type(frameType) == "string", "CreateFrame needs a frame type")
    local frame = NewObject({ frameType = frameType, parent = parent, template = template or false })
    if template then
        local setup = TEMPLATES[template]
        assert(setup, "Template not verified against the client: " .. template)
        if type(setup) == "function" then
            setup(frame)
        end
    end
    if name then
        rawset(realG, name, frame)
    end
    return frame
end

local function SplitBagSlot(location)
    return world.bags[location.bag] and world.bags[location.bag][location.slot]
end

local function InstallApi()
    local G = realG

    G.time = function(t) if t then return os.time(t) end return world.now end
    G.date = function(format, t) return os.date(format, t or world.now) end
    G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    G.print = function(...) table.insert(world.printed, table.concat({ ... }, " ")) end
    G.GetLocale = function() return world.locale end
    G.BreakUpLargeNumbers = function(n) return tostring(n) end
    G.hooksecurefunc = function(a, b, c)
        local target, name, hook = G, a, b
        if type(a) == "table" then
            target, name, hook = a, b, c
        end
        local original = target[name]
        assert(type(original) == "function", "hooksecurefunc on a missing function: " .. tostring(name))
        target[name] = function(...)
            local results = { original(...) }
            hook(...)
            return unpack(results)
        end
    end

    G.CreateFrame = CreateFrameMock
    G.UIParent = NewObject()
    G.UIParent.rect = { left = 0, right = 1920, top = 1080, bottom = 0 }
    G.Minimap = NewObject({ width = 140, height = 140, centerX = 100, centerY = 100, effectiveScale = 2 })
    G.Minimap.rect = { left = 1700, right = 1840, top = 1060, bottom = 920 }
    G.GetCursorPosition = function() return world.cursorX, world.cursorY end
    G.UISpecialFrames = {}
    G.SlashCmdList = {}
    G.ITEM_QUALITY_COLORS = { [0] = { r = 0.6, g = 0.6, b = 0.6 }, [1] = { r = 1, g = 1, b = 1 }, [2] = { r = 0, g = 1, b = 0 }, [3] = { r = 0, g = 0.44, b = 0.87 } }
    G.RAID_CLASS_COLORS = { MAGE = { r = 0.25, g = 0.78, b = 0.92 }, WARRIOR = { r = 0.78, g = 0.61, b = 0.43 } }
    G.GameTooltip = NewObject({ lines = {} })
    function G.GameTooltip.SetOwner() end
    function G.GameTooltip.SetHyperlink(self, link) self.link = link end
    function G.GameTooltip.SetItemByID(self, id) self.itemID = id end
    function G.GameTooltip.AddLine(self, line) table.insert(self.lines, line) end
    function G.GameTooltip.AddDoubleLine(self, left, right) table.insert(self.lines, left .. "=" .. right) end

    G.ButtonFrameTemplate_HideButtonBar = function(frame)
        frame.Inset:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 4)
    end
    G.PanelTemplates_SetNumTabs = function(frame, count) frame.numTabs = count end
    G.PanelTemplates_SetTab = function(frame, index) frame.selectedTab = index end
    G.ScrollBoxConstants = { RetainScrollPosition = true }
    G.CreateDataProvider = function(collection) return { collection = collection } end
    G.CreateScrollBoxListLinearView = function()
        return {
            extent = 20,
            SetElementExtent = function(self, extent) self.extent = extent end,
            SetElementInitializer = function(self, frameType, initializer)
                assert(frameType == "Button")
                self.initializer = initializer
            end,
        }
    end
    G.ScrollUtil = {
        InitScrollBoxListWithScrollBar = function(scrollBox, _, view) scrollBox.view = view end,
    }

    G.C_Timer = {
        After = function(_, fn) table.insert(world.timers, fn) end,
    }

    G.UnitName = function() return "Primo" end
    G.GetRealmName = function() return "Hyjal" end
    G.UnitClass = function() return "Mage", "MAGE" end
    G.GetMoney = function() return world.money end

    G.C_CurrencyInfo = {
        GetCoinTextureString = function(copper) return tostring(copper) .. "c" end,
    }

    G.C_Item = {
        DoesItemExist = function(location) return SplitBagSlot(location) ~= nil end,
        GetItemID = function(location) return SplitBagSlot(location).itemID end,
        GetItemName = function(location) return SplitBagSlot(location).itemName end,
        GetItemLink = function(location) return SplitBagSlot(location).hyperlink end,
        GetItemQuality = function(location) return SplitBagSlot(location).quality end,
        GetItemNameByID = function(id) return world.itemCache[id] end,
        GetItemQualityByID = function() return nil end,
        GetItemIconByID = function(id) return id and (1000 + id) or nil end,
        GetItemInfoInstant = function(name)
            for id, cached in pairs(world.itemCache) do
                if cached == name then return id end
            end
        end,
    }

    G.Enum = {
        AuctionHouseSortOrder = { Price = 0, Name = 1 },
        AuctionStatus = { Active = 0, Sold = 1 },
        BankType = { Character = 0, Guild = 1, Account = 2 },
        BagIndex = {
            Backpack = 0, Bag_1 = 1, Bag_2 = 2, Bag_3 = 3, Bag_4 = 4, ReagentBag = 5,
            CharacterBankTab_1 = 6, CharacterBankTab_2 = 7, AccountBankTab_1 = 12,
        },
    }

    G.C_Container = {
        GetContainerNumSlots = function(bagID)
            return world.bagSizes[bagID] or 0
        end,
        GetContainerItemInfo = function(bagID, slot)
            return world.bags[bagID] and world.bags[bagID][slot]
        end,
    }

    G.C_Bank = {
        CanViewBank = function(bankType) return world.canViewBank[bankType] ~= false end,
        FetchPurchasedBankTabIDs = function(bankType)
            if bankType == G.Enum.BankType.Account then
                return { G.Enum.BagIndex.AccountBankTab_1 }
            end
            return { G.Enum.BagIndex.CharacterBankTab_1, G.Enum.BagIndex.CharacterBankTab_2 }
        end,
        FetchDepositedMoney = function() return world.warbandMoney end,
    }

    G.C_AuctionHouse = {
        PostItem = function() return false end,
        PostCommodity = function() return false end,
        ConfirmPostItem = function() end,
        ConfirmPostCommodity = function() end,
        CancelSell = function() end,
        CancelAuction = function() end,
        GetCancelCost = function(id) return world.cancelCosts[id] or 0 end,
        CalculateItemDeposit = function(_, _, quantity) return 100 * quantity end,
        CalculateCommodityDeposit = function(_, _, quantity) return 10 * quantity end,
        GetOwnedAuctions = function() return world.owned end,
        QueryOwnedAuctions = function(sorts)
            assert(type(sorts) == "table" and sorts[1] and sorts[1].sortOrder ~= nil)
            world.ownedQueries = world.ownedQueries + 1
        end,
    }

    -- Mail: taking is asynchronous, as on the server. See Mock.CompleteTake/FailTake.
    G.GetInboxNumItems = function() return #world.mails, #world.mails end
    G.GetInboxHeaderInfo = function(index)
        local mail = world.mails[index]
        if not mail then return end
        local itemCount = 0
        for _ in pairs(mail.items or {}) do itemCount = itemCount + 1 end
        local first = mail.items and mail.items[1]
        return nil, nil, "Auction House", mail.subject, mail.money or 0, 0, mail.daysLeft or 30, itemCount,
            false, false, false, false, false, first and first.count, first and first.link
    end
    G.GetInboxItem = function(index, attachment)
        local item = world.mails[index] and world.mails[index].items and world.mails[index].items[attachment]
        if item then
            return item.name, item.id, 1000 + item.id, item.count, item.quality or 1, true, item.isCurrency or false
        end
    end
    G.GetInboxInvoiceInfo = function(index)
        local mail = world.mails[index]
        local invoice = mail and mail.invoice
        if not invoice then return nil end
        if invoice.needsBody and not mail.bodyLoaded then return nil end
        return invoice.type, invoice.name, invoice.player, invoice.bid, invoice.buyout, invoice.deposit,
            invoice.consignment, 0, nil, nil, invoice.count, invoice.commodity
    end
    G.GetInboxText = function(index)
        world.mails[index].bodyLoaded = true
        world.bodiesLoaded = world.bodiesLoaded + 1
    end
    G.TakeInboxMoney = function(index) table.insert(world.takes, { index = index }) end
    G.TakeInboxItem = function(index, attachment) table.insert(world.takes, { index = index, attachment = attachment }) end
    G.AutoLootMailItem = function(index) table.insert(world.takes, { index = index, all = true }) end

    G.AUCTION_SOLD_MAIL_SUBJECT = world.subjects.sold
    G.AUCTION_WON_MAIL_SUBJECT = world.subjects.won
    G.AUCTION_EXPIRED_MAIL_SUBJECT = world.subjects.expired
end

-- Test API ------------------------------------------------------------------

local ADDON_NAME = "TradingBook"

local function TocFiles()
    local files = {}
    for line in io.lines("TradingBook.toc") do
        line = line:gsub("%s+$", "")
        if line ~= "" and line:sub(1, 2) ~= "##" then
            table.insert(files, (line:gsub("\\", "/")))
        end
    end
    return files
end

function Mock.Fire(event, ...)
    for _, frame in ipairs(world.registered[event] or {}) do
        frame.scripts.OnEvent(frame, event, ...)
    end
end

function Mock.RunTimers()
    -- Timers can schedule timers.
    while #world.timers > 0 do
        local timers = world.timers
        world.timers = {}
        for _, fn in ipairs(timers) do
            fn()
        end
    end
end

function Mock.FindFrames(template)
    local found = {}
    for _, frame in ipairs(objects) do
        if frame.template == template then
            table.insert(found, frame)
        end
    end
    return found
end

-- The entries a dropdown would show, as { text, isSelected, setSelected, data }.
function Mock.MenuEntries(dropdown)
    local entries = {}
    dropdown.generator(dropdown, {
        CreateRadio = function(_, text, isSelected, setSelected, data)
            table.insert(entries, { text = text, isSelected = isSelected, setSelected = setSelected, data = data })
        end,
    })
    return entries
end

-- Money as the client writes it, with coin icons, for checks on text width.
function Mock.UseRealisticMoney()
    local coin = "|TInterface\\MoneyFrame\\UI-GoldIcon:14:14|t"
    C_CurrencyInfo.GetCoinTextureString = function(copper)
        local gold = math.floor(copper / 10000)
        local silver = math.floor(copper / 100) % 100
        local bronze = copper % 100
        local parts = {}
        if gold > 0 then
            local digits = tostring(gold):reverse():gsub("(%d%d%d)", "%1 "):reverse():gsub("^ ", "")
            table.insert(parts, digits .. " " .. coin)
        end
        if silver > 0 then table.insert(parts, silver .. " " .. coin) end
        if bronze > 0 or #parts == 0 then table.insert(parts, bronze .. " " .. coin) end
        return table.concat(parts, " ")
    end
end

-- Server accepts the oldest take: the mail loses its attachment or disappears.
function Mock.CompleteTake()
    local take = table.remove(world.takes, 1)
    local mail = world.mails[take.index]
    if take.attachment and mail.items then
        mail.items[take.attachment] = nil
        if next(mail.items) then
            Mock.Fire("MAIL_SUCCESS", 0)
            Mock.Fire("MAIL_INBOX_UPDATE")
            return
        end
    end
    table.remove(world.mails, take.index)
    Mock.Fire("MAIL_SUCCESS", 0)
    Mock.Fire("MAIL_INBOX_UPDATE")
end

function Mock.FailTake()
    table.remove(world.takes, 1)
    Mock.Fire("MAIL_FAILED", 0)
    Mock.Fire("MAIL_INBOX_UPDATE")
end

function Mock.SetBagItem(bag, slot, itemID, name, count, options)
    options = options or {}
    world.bags[bag] = world.bags[bag] or {}
    world.bagSizes[bag] = math.max(world.bagSizes[bag] or 0, slot)
    world.bags[bag][slot] = {
        itemID = itemID,
        itemName = name,
        stackCount = count,
        hyperlink = "|cffffffff|Hitem:" .. itemID .. "::::|h[" .. name .. "]|h|r",
        quality = options.quality or 1,
        iconFileID = 1000 + itemID,
        isBound = options.isBound or false,
    }
end

-- Loads the addon as the client would, on a clean client.
-- options: locale, subjects, db, money
function Mock.Boot(options)
    options = options or {}
    world = {
        now = os.time({ year = 2026, month = 11, day = 5, hour = 12 }),
        locale = options.locale or "enUS",
        subjects = options.subjects or {
            sold = "Auction successful: %s",
            won = "Auction won: %s",
            expired = "Auction expired: %s",
        },
        registered = {},
        timers = {},
        printed = {},
        bags = {},
        bagSizes = {},
        canViewBank = {},
        cancelCosts = {},
        owned = {},
        ownedQueries = 0,
        mails = {},
        takes = {},
        bodiesLoaded = 0,
        itemCache = {},
        money = options.money or 0,
        warbandMoney = 0,
        cursorX = 0,
        cursorY = 0,
    }
    objects = {}

    setmetatable(realG, nil)
    realG.TradingBookDB = nil
    realG.TradingBook = nil
    realG.TradingBookMainFrame = nil
    realG.TradingBookMinimapButton = nil
    InstallApi()

    setmetatable(realG, {
        __index = function(_, key)
            if allowedGlobals[key] then
                return nil
            end
            error("Read of undefined global: " .. tostring(key), 2)
        end,
        __newindex = function(t, key, value)
            if not allowedGlobals[key] then
                error("Write to undeclared global: " .. tostring(key), 2)
            end
            rawset(t, key, value)
        end,
    })

    local ns = {}
    for _, path in ipairs(TocFiles()) do
        local chunk, err = loadfile(path)
        if not chunk then
            error("Syntax error: " .. tostring(err), 0)
        end
        chunk(ADDON_NAME, ns)
    end

    -- As in the client, saved variables only appear just before our own ADDON_LOADED.
    Mock.Fire("ADDON_LOADED", "SomeOtherAddon")
    rawset(realG, "TradingBookDB", options.db)
    Mock.Fire("ADDON_LOADED", ADDON_NAME)
    Mock.Fire("PLAYER_LOGIN")
    Mock.RunTimers()
    return ns, world
end

return Mock
