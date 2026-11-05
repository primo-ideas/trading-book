local _, ns = ...

-- Sales, purchases and expiries are read from auction house mail: its invoices
-- carry the exact prices, and each mail can only be collected once, which makes
-- collection the one moment that cannot be counted twice across sessions.
--
-- The take hooks run after the call, but the server has not answered yet, so the
-- inbox copy made on the last MAIL_INBOX_UPDATE still lines up with the index.
local Mail = {}
ns.Mail = Mail

local MAIL_LIFETIME_DAYS = 30
local UNDO_WINDOW_SECONDS = 10
local MAX_ATTACHMENTS = 16 -- ATTACHMENTS_MAX_RECEIVE lives in the mail UI addon, which may load after us.

local inbox = {}
local inboxSize = nil
local lastTake = nil

-- Turns a global string such as "Auction successful: %s" into a pattern.
local function SubjectPattern(format)
    if not format then
        return nil
    end
    local pattern = format:gsub("([%^%$%(%)%.%[%]%*%+%-%?%%])", "%%%1")
    pattern = pattern:gsub("%%%%1%%%$s", "(.+)"):gsub("%%%%s", "(.+)")
    return "^" .. pattern .. "$"
end

local SUBJECTS = {
    { kind = "sold", pattern = SubjectPattern(AUCTION_SOLD_MAIL_SUBJECT) },
    { kind = "won", pattern = SubjectPattern(AUCTION_WON_MAIL_SUBJECT) },
    { kind = "expired", pattern = SubjectPattern(AUCTION_EXPIRED_MAIL_SUBJECT) },
}

local function ClassifySubject(subject)
    if not subject then
        return nil
    end
    for _, candidate in ipairs(SUBJECTS) do
        local captured = candidate.pattern and subject:match(candidate.pattern)
        if captured then
            local name, quantity = captured:match("^(.-) %((%d+)%)$")
            return candidate.kind, name or captured, tonumber(quantity)
        end
    end
end

-- An invoice is more reliable than the subject line. Its absence is ambiguous:
-- "seller_temp_invoice" means the money has not been delivered, so nothing to record.
local KIND_BY_INVOICE = { seller = "sold", buyer = "won", seller_temp_invoice = false }

local function ApplyInvoice(mail, index)
    local invoiceType, itemName, playerName, bid, _, deposit, consignment, _, _, _, count = GetInboxInvoiceInfo(index)
    if not invoiceType then
        return
    end
    mail.invoice = {
        itemName = itemName,
        playerName = playerName,
        bid = bid,
        deposit = deposit,
        consignment = consignment,
        count = count,
    }
    local kind = KIND_BY_INVOICE[invoiceType]
    if kind ~= nil then
        mail.kind = kind or nil
    end
end

local function ReadMail(index)
    local _, _, _, subject, money, _, daysLeft, itemCount, _, _, _, _, _, _, firstItemLink = GetInboxHeaderInfo(index)
    local mail = {
        subject = subject,
        money = money or 0,
        daysLeft = daysLeft,
        link = firstItemLink,
        attachedQty = 0,
        attachments = {},
    }
    mail.kind, mail.subjectName, mail.subjectQty = ClassifySubject(subject)
    ApplyInvoice(mail, index)

    if itemCount and itemCount > 0 then
        for attachment = 1, MAX_ATTACHMENTS do
            local name, itemID, icon, count, quality, _, isCurrency = GetInboxItem(index, attachment)
            if itemID and not isCurrency then
                mail.attachedQty = mail.attachedQty + (count or 1)
                mail.attachments[itemID] = (mail.attachments[itemID] or 0) + (count or 1)
                mail.itemID = mail.itemID or itemID
                mail.itemName = mail.itemName or name
                ns.RememberItem(itemID, name, quality, icon)
            end
        end
    end
    return mail
end

local function ScanInbox()
    local size = GetInboxNumItems()
    if inboxSize and size < inboxSize then
        lastTake = nil -- The mail left the inbox: that take succeeded.
    end
    local previous = inbox
    local sameSize = size == inboxSize
    local contents = {}
    inbox = {}
    for index = 1, size do
        local mail = ReadMail(index)
        -- A mail with several attachments stays in the inbox across takes. Once
        -- the size changes, indices have shifted and an identical mail may now
        -- sit at this index, so the marker must not be carried over.
        local before = previous[index]
        if sameSize and before and before.taken and before.subject == mail.subject then
            mail.taken = true
        end
        inbox[index] = mail
        for itemID, count in pairs(mail.attachments) do
            contents[itemID] = (contents[itemID] or 0) + count
        end
    end
    inboxSize = size
    ns.Stockpile.SetMailContents(contents)
end

-- Mail lasts a fixed time, so the time left reveals when it was sent.
local function SentAt(mail)
    local now = time()
    if not mail.daysLeft then
        return now
    end
    local age = (MAIL_LIFETIME_DAYS - mail.daysLeft) * 86400
    return now - math.max(0, age)
end

local function RecordSale(mail)
    local invoice = mail.invoice or {}
    local name = invoice.itemName or mail.subjectName
    local itemID = ns.LookupItemID(name)
    local quantity = invoice.count or mail.subjectQty or 1
    ns.Auctions.Consume(itemID, quantity, true)
    return ns.Ledger.Add({
        kind = "sold",
        t = SentAt(mail),
        itemID = itemID,
        name = name,
        qty = quantity,
        gross = invoice.bid or mail.money,
        cut = invoice.consignment or 0,
        deposit = invoice.deposit or 0,
        other = invoice.playerName,
    })
end

local function RecordPurchase(mail)
    local invoice = mail.invoice or {}
    return ns.Ledger.Add({
        kind = "bought",
        t = SentAt(mail),
        itemID = mail.itemID or ns.LookupItemID(invoice.itemName or mail.subjectName),
        name = invoice.itemName or mail.itemName or mail.subjectName,
        link = mail.link,
        qty = invoice.count or mail.subjectQty or math.max(1, mail.attachedQty),
        gross = invoice.bid or 0,
        other = invoice.playerName,
    })
end

local function RecordExpiry(mail)
    local itemID = mail.itemID or ns.LookupItemID(mail.subjectName)
    local quantity = math.max(1, mail.attachedQty)
    ns.Auctions.Consume(itemID, quantity, false)
    return ns.Ledger.Add({
        kind = "expired",
        t = SentAt(mail),
        itemID = itemID,
        name = mail.itemName or mail.subjectName,
        link = mail.link,
        qty = quantity,
    })
end

local RECORDERS = { sold = RecordSale, won = RecordPurchase, expired = RecordExpiry }

local function OnTake(index)
    if not inboxSize then
        ScanInbox()
    end
    local mail = inbox[index]
    if not mail or mail.taken then
        return
    end
    -- An invoice can come back empty until the mail body is loaded. Scans leave
    -- bodies alone since that marks mail as read, but this one is being collected.
    if not mail.invoice and (mail.kind == "sold" or mail.kind == "won") then
        GetInboxText(index)
        ApplyInvoice(mail, index)
    end
    local record = RECORDERS[mail.kind]
    if record then
        mail.taken = true
        lastTake = { index = index, mail = mail, entry = record(mail), at = time() }
    end
end

hooksecurefunc("TakeInboxMoney", OnTake)
hooksecurefunc("TakeInboxItem", OnTake)
hooksecurefunc("AutoLootMailItem", OnTake)

-- Collection can fail, typically on full bags: the mail stays and will be taken again.
ns.OnEvent("MAIL_FAILED", function()
    if lastTake and time() - lastTake.at <= UNDO_WINDOW_SECONDS then
        ns.Ledger.Remove(lastTake.entry)
        lastTake.mail.taken = nil
        local current = inbox[lastTake.index]
        if current then
            current.taken = nil
        end
    end
    lastTake = nil
end)

ns.OnEvent("MAIL_SUCCESS", function()
    lastTake = nil
end)

ns.OnEvent("MAIL_SHOW", ScanInbox)
ns.OnEvent("MAIL_INBOX_UPDATE", ScanInbox)

ns.OnEvent("MAIL_CLOSED", function()
    inbox = {}
    inboxSize = nil
    lastTake = nil
end)
