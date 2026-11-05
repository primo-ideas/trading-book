local _, ns = ...

-- Gold is recorded per holder: each character, plus the warband bank. Totals are
-- summed from those histories when needed, so any combination can be shown.
--
-- Before it was first seen, a holder counts at the amount it had then. Otherwise
-- logging in on an alt for the first time would look like a huge gain.
local Gold = {}
ns.Gold = Gold

local SECONDS_PER_DAY = 86400

-- Keeps the amount held on first sight: the first point is overwritten during its
-- day, and the gains of that first day would be lost with it.
local function RecordHolder(holder, value)
    holder.moneyHistory = holder.moneyHistory or {}
    local series = holder.moneyHistory
    local isFirst = #series == 0
    ns.Stockpile.RecordPoint(series, ns.DayKey(time()), value)
    if isFirst then
        series[1].opening = value
    end
end

function Gold.Record()
    local character = ns.GetCharacter()
    RecordHolder(character, character.money or 0)
    local warband = ns.db.warband
    if warband.scannedAt then
        RecordHolder(warband, warband.money or 0)
    end
end

-- Holders ----------------------------------------------------------------------

-- options.char selects one character. Otherwise options.holders selects "all"
-- (the default), "characters" or "warband".
local function GetHolders(options)
    local db = ns.db
    local holders = {}

    local function Add(key, record, isWarband)
        table.insert(holders, {
            key = key,
            isWarband = isWarband,
            money = record.money or 0,
            series = record.moneyHistory or {},
            cursor = 1,
        })
    end

    if options.char then
        if db.characters[options.char] then
            Add(options.char, db.characters[options.char])
        end
        return holders
    end
    if options.holders ~= "warband" then
        for key, character in pairs(db.characters) do
            Add(key, character)
        end
    end
    if options.holders ~= "characters" and db.warband.scannedAt then
        Add("warband", db.warband, true)
    end
    return holders
end

-- Days must be asked for in increasing order, since each holder keeps its place.
local function ValueOn(holder, day)
    local series = holder.series
    if #series == 0 then
        return holder.money
    end
    if day < series[1].day then
        return series[1].opening or series[1].value
    end
    while series[holder.cursor + 1] and series[holder.cursor + 1].day <= day do
        holder.cursor = holder.cursor + 1
    end
    return series[holder.cursor].value
end

local function TrackedSince(holders)
    local earliest
    for _, holder in ipairs(holders) do
        local first = holder.series[1]
        if first and (not earliest or first.day < earliest) then
            earliest = first.day
        end
    end
    return earliest
end

-- First midnight of a period, which cannot start before tracking did.
local function PeriodStart(holders, days)
    local requested = ns.Stats.PeriodStart(days)
    local trackedSince = TrackedSince(holders)
    if not trackedSince then
        return requested or ns.Stats.StartOfDay(time())
    end
    local tracked = ns.Stats.StartOfDay(ns.DayKeyToTime(trackedSince))
    return requested and math.max(requested, tracked) or tracked
end

-- Analysis -----------------------------------------------------------------------

-- Returns one point per day of the period, and the total on the day before it.
local function BuildDays(holders, start)
    local dayCount = ns.Stats.DaysSince(start, time()) + 1
    local points = {}
    local base = 0
    for offset = -1, dayCount - 1 do
        local t = start + offset * SECONDS_PER_DAY + SECONDS_PER_DAY / 2
        local day = ns.DayKey(t)
        local total = 0
        for _, holder in ipairs(holders) do
            total = total + ValueOn(holder, day)
        end
        if offset < 0 then
            base = total
        else
            table.insert(points, { t = t, day = day, value = total })
        end
    end
    return points, base
end

-- options: as GetHolders, plus days (nil or 0 for all time).
function Gold.Analyze(options)
    local holders = GetHolders(options)
    local result = { points = {}, current = 0, change = 0 }
    if #holders == 0 then
        return result
    end

    local start = PeriodStart(holders, options.days)
    local points, base = BuildDays(holders, start)
    result.points = points
    result.current = points[#points].value
    result.change = result.current - base
    result.percent = base > 0 and result.change / base or nil
    result.perDay = result.change / #points
    result.trackedSince = TrackedSince(holders)
    result.upDays, result.downDays = 0, 0

    local previous = base
    for _, point in ipairs(points) do
        point.delta = point.value - previous
        previous = point.value
        if point.delta > 0 then
            result.upDays = result.upDays + 1
            if not result.best or point.delta > result.best.delta then
                result.best = point
            end
        elseif point.delta < 0 then
            result.downDays = result.downDays + 1
            if not result.worst or point.delta < result.worst.delta then
                result.worst = point
            end
        end
        if not result.peak or point.value >= result.peak.value then
            result.peak = point
        end
    end

    -- Gold moved to the warband bank is no income, so splitting income by source
    -- only makes sense on the whole account or on a single character.
    if options.char or options.holders == nil or options.holders == "all" then
        result.auctionNet = ns.Stats.Summarize({ since = start, char = options.char }).net
        result.otherIncome = result.change - result.auctionNet
    end
    return result
end

-- Shortens a long series for drawing. Each point closes a stretch of days, so the
-- last one is always today and the changes still add up.
function Gold.Downsample(points, maxPoints)
    if #points <= maxPoints then
        return points
    end
    local step = math.ceil(#points / maxPoints)
    local sampled = {}
    local first = #points % step
    if first == 0 then
        first = step
    end
    local index = 0
    local stretchEnd = first
    local delta, from = 0, nil
    for _, point in ipairs(points) do
        index = index + 1
        from = from or point.t
        delta = delta + point.delta
        if index == stretchEnd then
            table.insert(sampled, { t = point.t, from = from, day = point.day, value = point.value, delta = delta })
            stretchEnd = stretchEnd + step
            delta, from = 0, nil
        end
    end
    return sampled
end

-- One row per holder in the selection: what it holds, its share, its change.
function Gold.GetBreakdown(options)
    local holders = GetHolders(options)
    if #holders == 0 then
        return {}
    end
    local baseDay = ns.DayKey(PeriodStart(holders, options.days) - SECONDS_PER_DAY / 2)
    local today = ns.DayKey(time())

    local rows = {}
    local total = 0
    for _, holder in ipairs(holders) do
        local base = ValueOn(holder, baseDay)
        local gold = ValueOn(holder, today)
        total = total + gold
        table.insert(rows, { key = holder.key, isWarband = holder.isWarband, gold = gold, change = gold - base })
    end
    for _, row in ipairs(rows) do
        row.share = total > 0 and row.gold / total or nil
    end
    return rows
end
