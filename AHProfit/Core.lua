-- AH Profit: item tooltip lines with the lowest auction price, what you keep after the cut, and the gain over vendoring.
-- Prices come from two places: Data.lua (a snapshot of Blizzard's auction feed, bundled with the addon) and the
-- player's own auction house browsing, which is recorded while the auction house is open and replaces the snapshot.
local ADDON, ns = ...
local DB
local PREFIX = "|cffffd100AH Profit|r: "

local function secret(v) return issecretvalue ~= nil and issecretvalue(v) end
local function now() return (GetServerTime and GetServerTime()) or time() end
local function say(m) if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. m) end end

local function money(c)
    local neg = c < 0
    if neg then c = -c end
    local g, s, k = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    local t = ""
    if g > 0 then t = g .. "|cffffd700g|r " end
    if g > 0 or s > 0 then t = t .. s .. "|cffc7c7cfs|r " end
    return (neg and "-" or "") .. t .. k .. "|cffeda55fc|r"
end
ns.money = money

local function age(t)
    local d = now() - t
    if d < 90 then return "just now" end
    if d < 5400 then return math.floor(d / 60 + 0.5) .. "m ago" end
    if d < 129600 then return math.floor(d / 3600 + 0.5) .. "h ago" end
    return math.floor(d / 86400 + 0.5) .. "d ago"
end
ns.age = age
ns.now, ns.say = now, say
ns.db = function() return DB end

-- One auction house per realm group and faction; keying by realm and faction never mixes two houses.
local function houseKey()
    return (GetRealmName and GetRealmName() or "?") .. "|" .. (UnitFactionGroup and UnitFactionGroup("player") or "?")
end
local function live()
    local k = houseKey()
    local L = DB.live[k]
    if not L then L = { p = {}, q = {}, t = {}, full = 0 }; DB.live[k] = L end
    return L
end
ns.live = live

-- Saved-data version (DB.v): 1 added DB.shared (guild prices), 2 added DB.hist (daily history of your own scans),
-- 3 added DB.ledger (daily money per character and source), DB.sessions (finished farming sessions) and DB.items
-- (item names and vendor prices, Tools.lua).
-- A save written by a newer version (DB.v > KNOWN_V) is left untouched; this version then uses neither layer, and
-- neither stores nor shows received prices (ns.sharedOK() is false; Sync.lua refuses them).
-- Prices received from guild members (Sync.lua) live in their own layer, one per auction house: they never change
-- or delete your own scans. from = { [scan time] = sender name }. Received prices older than 12 hours are dropped.
local KNOWN_V, MAX_HOUSES, SHARED_KEEP = 3, 8, 43200
local spare = { p = {}, q = {}, t = {}, full = 0, from = {} }
local function shared()
    if DB.v ~= KNOWN_V then return spare end
    local k = houseKey()
    local H = DB.shared[k]
    if not H then H = { p = {}, q = {}, t = {}, full = 0, from = {} }; DB.shared[k] = H end
    return H
end
ns.shared = shared
ns.sharedOK = function() return DB ~= nil and DB.v == KNOWN_V end
local function okNum(v, max) return type(v) == "number" and v >= 0 and v <= max and v == math.floor(v) end
-- Drops received prices older than 12 hours and sender names no stored price uses. Returns the item count.
local function pruneShared(H)
    local oldest, used, n = now() - SHARED_KEEP, {}, 0
    for id, t in pairs(H.t) do
        if t < oldest then H.p[id], H.q[id], H.t[id] = nil, nil, nil
        else used[t] = true; n = n + 1 end
    end
    for t in pairs(H.from) do if not used[t] then H.from[t] = nil end end
    if H.full < oldest then H.full = 0 end
    return n
end
ns.pruneShared = pruneShared
-- Checks the saved shared layer at load: wrong types are dropped, at most MAX_HOUSES houses (the newest kept).
local loadHist
local function loadShared()
    if type(DB.v) == "number" and DB.v > KNOWN_V then return end
    local v = type(DB.v) == "number" and DB.v or 0
    if v < 1 or type(DB.shared) ~= "table" then DB.shared = {} end
    if v < 2 or type(DB.hist) ~= "table" then DB.hist = {} end
    for _, k in ipairs({ "ledger", "sessions", "items" }) do
        if v < 3 or type(DB[k]) ~= "table" then DB[k] = {} end
    end
    DB.v = KNOWN_V
    loadHist()
    local keys = {}
    for k, H in pairs(DB.shared) do
        if type(k) ~= "string" or type(H) ~= "table" then DB.shared[k] = nil
        else
            for _, f in ipairs({ "p", "q", "t", "from" }) do if type(H[f]) ~= "table" then H[f] = {} end end
            if not okNum(H.full, 1e10) then H.full = 0 end
            for id, p in pairs(H.p) do
                if not (okNum(id, 1e7) and okNum(p, 1e12) and p > 0 and okNum(H.t[id], 1e10)) then H.p[id], H.q[id], H.t[id] = nil, nil, nil
                elseif not okNum(H.q[id], 1e9) then H.q[id] = 0 end
            end
            for id in pairs(H.t) do if H.p[id] == nil then H.t[id], H.q[id] = nil, nil end end
            for id in pairs(H.q) do if H.p[id] == nil then H.q[id] = nil end end
            for t, n in pairs(H.from) do if not (okNum(t, 1e10) and type(n) == "string" and n ~= "" and #n <= 64) then H.from[t] = nil end end
            pruneShared(H)
            keys[#keys + 1] = k
        end
    end
    if #keys > MAX_HOUSES then
        table.sort(keys, function(a, b) return DB.shared[a].full > DB.shared[b].full end)
        for i = MAX_HOUSES + 1, #keys do DB.shared[keys[i]] = nil end
    end
end

local seedIdx
local function seedLookup(id)
    local S = ns.seed
    if not S or not S.flat then return end
    if S.faction and UnitFactionGroup and UnitFactionGroup("player") ~= S.faction then return end
    if not seedIdx then
        seedIdx = {}
        local f = S.flat
        for i = 1, #f, 3 do seedIdx[f[i]] = i end
    end
    local i = seedIdx[id]
    if i then return S.flat[i + 1], S.flat[i + 2], S.t end
end

-- Auctionator (optional): its public API gives an item's latest lowest price and how many days ago it was seen
-- (0 = today, by Auctionator's own day, which starts at local midnight). Only a price seen today is used, and only
-- through pcall; without Auctionator, or with DB.useAuctionator == false, this returns nothing. No listed count is
-- known; the time returned is the start of Auctionator's day, the earliest the price can be from. Answers are kept
-- for a minute, so a list of thousands of items asks once per item.
local AUC_ID, AUC_KEEP, DAY0_UTC = "AHProfit", 60, 1577836800
local aucCache, aucAt, aucDay = {}, 0, 0
local function aucDayStart(t)
    local ok, day0 = pcall(time, { year = 2020, month = 1, day = 1, hour = 0 })
    if not ok or type(day0) ~= "number" or day0 > t then day0 = DAY0_UTC end
    return t - (t - day0) % 86400
end
local function auctionator(id)
    if DB and DB.useAuctionator == false then return end
    local api = type(Auctionator) == "table" and type(Auctionator.API) == "table" and Auctionator.API.v1
    if type(api) ~= "table" or type(api.GetAuctionAgeByItemID) ~= "function" or type(api.GetAuctionPriceByItemID) ~= "function" then return end
    local t = now()
    -- Auctionator counts days on the computer's clock (time()), so its day start is taken from that clock too.
    local okC, clock = pcall(time)
    local ds = aucDayStart((okC and type(clock) == "number") and clock or t)
    -- The cache is dropped after a minute and whenever Auctionator's day changes: an answer from before midnight
    -- ("seen today") is not today's after it.
    if t - aucAt > AUC_KEEP or t < aucAt or ds ~= aucDay then aucCache, aucAt, aucDay = {}, t, ds end
    local c = aucCache[id]
    if c == nil then
        c = false
        local ok, days = pcall(api.GetAuctionAgeByItemID, AUC_ID, id)
        if ok and not secret(days) and days == 0 then
            local ok2, p = pcall(api.GetAuctionPriceByItemID, AUC_ID, id)
            if ok2 and not secret(p) and okNum(p, 1e12) and p > 0 then c = p end
        end
        aucCache[id] = c
    end
    if c then return c, ds end
end
ns.auctionatorPrice = auctionator

-- Returns price per unit (copper), quantity listed, time seen, source ("scan", "guild", "auctionator" or "feed")
-- and, for "guild", the sender's name. Order: your own scan when it is at most 2 hours old (always, whatever the
-- feed's age or a guild member's claim), then a guild member's scan newer than yours, then your older scan, then
-- the bundled feed. A scan older than the feed loses to the feed. When there is no scan of yours or the guild's, or
-- the newest is more than 24 hours old, a price Auctionator saw today comes before them (its listed count is nil),
-- unless a complete scan of yours or the guild's since Auctionator's day started did not have the item.
local OWN_FRESH, AUC_AFTER = 7200, 86400
local function lookup(id)
    local L, H = live(), shared()
    local lp, lt = L.p[id], L.t[id]
    if lp and now() - lt <= OWN_FRESH then return lp, L.q[id], lt, "scan" end
    local gp, gt = H.p[id], H.t[id]
    local newest = math.max(lp and lt or 0, gp and gt or 0)
    -- A complete scan (yours or the guild's) since Auctionator's day started is the whole truth: an item not in it
    -- is not listed, and Auctionator's older sighting from the same day does not bring it back.
    local okC, clock = pcall(time)                                 -- the computer's clock, as Auctionator counts days
    if now() - newest > AUC_AFTER and math.max(L.full, H.full) <= aucDayStart((okC and type(clock) == "number") and clock or now()) then
        local ap, at = auctionator(id)
        if ap then return ap, nil, at, "auctionator" end
    end
    local sp, sq, st = seedLookup(id)
    if sp and math.max(L.full, H.full) >= st then sp = nil end   -- a complete scan newer than the snapshot is the whole truth
    if sp and lp and lt < st then lp = nil end
    if sp and gp and gt < st then gp = nil end
    if gp and (not lp or gt > lt) then return gp, H.q[id], gt, "guild", H.from[gt] end
    if lp then return lp, L.q[id], lt, "scan" end
    if sp then return sp, sq, st, "feed" end
end
ns.lookup = lookup
-- How a price's source is shown: "scan 5m ago", "guild (Name, 20m ago)", "Auctionator, today", "feed 1h ago".
local function srcLabel(src, t, from)
    if src == "auctionator" then return "Auctionator, today" end
    if src == "guild" then return "guild (" .. (type(from) == "string" and from or "a guild member") .. ", " .. age(t) .. ")" end
    return (src == "scan" and "scan " or "feed ") .. age(t)
end
ns.srcLabel = srcLabel

-- ------------------------------------------------------------------ daily history of your own auction house scans --
-- DB.hist[house][itemID] = one string per item: for each recorded scan day, oldest first, four numbers
-- (day step, h, l, a) as base-32 digits (the alphabet of Sync.lua; a digit of 32 or more means "more digits
-- follow"). The first day step is the day itself, later ones the gap to the previous day (at least 1).
-- day = whole days since 2020-01-01 UTC; h = the highest of the day's lowest prices, l = the lowest one (0 when
-- it equals h), a = the most listed. A string is decoded only when that item's history is read or written.
-- Written from every own browse result, full scans and searches alike, once per query with that query's lowest
-- price per item. Guild prices never enter it. Kept 21 days; at most HIST_ITEMS items per house, 8 houses.
local DAY0, HIST_DAYS, HIST_ITEMS, HIST_LEN = 1577836800, 21, 10000, 1024
ns.HIST_ITEMS = HIST_ITEMS
local function scanDay(t) return math.floor((t - DAY0) / 86400) end
ns.scanDay = scanDay
local A64 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+/"
local D64 = {}
for i = 1, 64 do D64[A64:byte(i)] = i - 1 end
local function put(buf, v)
    while v >= 32 do
        local d = v % 32
        buf[#buf + 1] = A64:sub(d + 33, d + 33)
        v = (v - d) / 32
    end
    buf[#buf + 1] = A64:sub(v + 1, v + 1)
end
local function take(s, i, n)
    local v, mult = 0, 1
    while true do
        if i > n or mult > 1099511627776 then return nil end
        local c = D64[s:byte(i)]
        if not c then return nil end
        i = i + 1
        if c >= 32 then v = v + (c - 32) * mult; mult = mult * 32
        else return v + c * mult, i end
    end
end
-- Days oldest first, { { d, h, l, a }, ... } with l = 0 when it equals h. The list is assumed checked.
local function histEncode(days)
    local buf, prev = {}, 0
    for _, e in ipairs(days) do
        put(buf, e[1] - prev); put(buf, e[2]); put(buf, e[3]); put(buf, e[4])
        prev = e[1]
    end
    return table.concat(buf)
end
-- Decodes and checks one item's string: days increasing and not after today, prices 1..1e12, a low below its high
-- (or 0), counts up to 1e9. Days older than 21 are dropped. nil when anything is wrong (the item is then dropped).
local function histDecode(s, today)
    if type(s) ~= "string" or #s == 0 or #s > HIST_LEN then return nil end
    local out, i, n, day = {}, 1, #s, 0
    while i <= n do
        local step, h, l, a
        step, i = take(s, i, n); if not step or (day > 0 and step < 1) then return nil end
        h, i = take(s, i, n); if not h or h < 1 or h > 1e12 then return nil end
        l, i = take(s, i, n); if not l or l >= h then return nil end
        a, i = take(s, i, n); if not a or a > 1e9 then return nil end
        day = day + step
        if day > today or day > 1e5 then return nil end
        if day > today - HIST_DAYS then out[#out + 1] = { day, h, l, a } end
    end
    return out
end
ns.histEncode, ns.histDecode = histEncode, histDecode
local histCount = setmetatable({}, { __mode = "k" })
-- histVersion changes whenever any history string is written or dropped, so readers can cache decoded results.
local histVersion = 0
ns.histVersion = function() return histVersion end
ns.histChanged = function() histVersion = histVersion + 1 end
local function histHouseOf(k)
    if DB.v ~= KNOWN_V then return nil end
    local H = DB.hist[k]
    if not H then H = {}; DB.hist[k] = H; histCount[H] = 0 end
    if not histCount[H] then local n = 0; for _ in pairs(H) do n = n + 1 end; histCount[H] = n end
    return H
end
local function histHouse() return histHouseOf(houseKey()) end
ns.histHouse = histHouse
-- Whether a stored string may be dropped: damaged, or every recorded day expired. A string with a day after today
-- (the server clock went back) is unreadable for now but kept: it reads again once the clock is past that day.
local function histDroppable(e, today)
    local d = histDecode(e, today)
    if d then return #d == 0 end
    return histDecode(e, 1e5) == nil                             -- nil: damaged; a list: only dated in the future
end
-- Items that may be dropped give their place back. This looks at up to max items per call, continuing where the
-- last call stopped; it returns how many it looked at and whether it reached the end of the house.
local sweepAt = setmetatable({}, { __mode = "k" })
local function histSweep(H, today, max)
    local k, used = sweepAt[H], 0
    if k ~= nil and H[k] == nil then k = nil end
    while used < max do
        local id, e = next(H, k)
        if id == nil then sweepAt[H] = nil; return used, true end -- went round once
        used = used + 1
        if histDroppable(e, today) then H[id] = nil; histCount[H] = histCount[H] - 1; histVersion = histVersion + 1
        else k = id end
    end
    sweepAt[H] = k
    return used, false
end
-- The first time a house is full on a given day, one sweep of the whole house starts, SWEEP_STEP items per frame.
-- Until it has gone round, a new item that finds the house full waits (its row stays queued for the next frame);
-- once it has, a house that is still full has no expired items, and new items are dropped until the next day.
local SWEEP_STEP, BATCH_SWEEP = 200, 50  -- per frame: the whole-house pass, and what one batch of rows may add
local capPass = setmetatable({}, { __mode = "k" })               -- house -> { day, done }
local capSweep
local function capNext(H, pass)
    if C_Timer and C_Timer.After then C_Timer.After(0, function() if capPass[H] == pass and not pass.done then capSweep(H, pass) end end)
    else pass.done = true end
end
capSweep = function(H, pass)
    local _, round = histSweep(H, scanDay(now()), SWEEP_STEP)
    if round then pass.done = true else capNext(H, pass) end
end
local sweepLeft, canWait = 0, false -- decodes the sweep may still spend in this batch; whether a row may wait
local function histAdd(H, id, p, q, day)
    if not (okNum(p, 1e12) and p >= 1 and okNum(q, 1e9) and okNum(day, 1e5)) then return end   -- a bad row takes no place
    -- A row may be older than the newest day already stored (seen before midnight, written after; or the clock
    -- stepped back): the string is read as of the later of the row's day and today, and the row goes in day order.
    local asOf = math.max(day, scanDay(now()))
    if day <= asOf - HIST_DAYS then return end                   -- already older than what is kept
    local days
    if H[id] == nil then
        if histCount[H] >= ns.HIST_ITEMS then
            local today = scanDay(now())
            local pass = capPass[H]
            if not pass or pass.day ~= today then
                pass = { day = today }; capPass[H] = pass; sweepAt[H] = nil
                capNext(H, pass)                                 -- starts on the next frame
            end
            while histCount[H] >= ns.HIST_ITEMS and not pass.done and sweepLeft > 0 do
                local used, round = histSweep(H, today, math.min(sweepLeft, 50))
                sweepLeft = sweepLeft - used
                if round then pass.done = true end
            end
            if histCount[H] >= ns.HIST_ITEMS then return (canWait and not pass.done) and "wait" or nil end
        end
        days = {}
        histCount[H] = histCount[H] + 1
    else
        days = histDecode(H[id], asOf)
        if not days then
            if histDecode(H[id], 1e5) then return end            -- it has a day after that: kept as it is, row not placed
            days = {}                                            -- damaged: starts over
        end
    end
    local i = #days
    while i > 0 and days[i][1] > day do i = i - 1 end
    local e = days[i]
    if e and e[1] == day then                                    -- the same day: highest low, lowest low, most listed
        local hi = e[2] > p and e[2] or p
        local lo = e[3] > 0 and e[3] or e[2]
        lo = lo < p and lo or p
        e[2], e[3] = hi, lo < hi and lo or 0
        if q > e[4] then e[4] = q end
    else
        table.insert(days, i + 1, { day, p, 0, q })
    end
    H[id] = histEncode(days)
    histVersion = histVersion + 1
end
-- Daily prices of one item from your own scans, oldest first: { { d = day, p = h, l = l or h, a = a }, ... }.
function ns.histOwn(id)
    local H = histHouse()
    local days = H and H[id] and histDecode(H[id], scanDay(now()))
    if H and H[id] and (not days or #days == 0) and histDroppable(H[id], scanDay(now())) then   -- expired or damaged
        H[id] = nil; histCount[H] = histCount[H] - 1; histVersion = histVersion + 1
    end
    local out = {}
    for _, e in ipairs(days or {}) do out[#out + 1] = { d = e[1], p = e[2], l = e[3] > 0 and e[3] or e[2], a = e[4] } end
    return out
end
-- At load only cheap checks: wrong key or value types and over-long strings dropped, the item cap; strings are
-- checked when decoded. With more than 8 houses, the ones scanned most recently are kept (this decodes them).
loadHist = function()
    local keys = {}
    for k, H in pairs(DB.hist) do
        if type(k) ~= "string" or type(H) ~= "table" then DB.hist[k] = nil
        else
            local n = 0
            for id, e in pairs(H) do
                if not (okNum(id, 1e7) and type(e) == "string" and #e > 0 and #e <= HIST_LEN) or n >= HIST_ITEMS then H[id] = nil
                else n = n + 1 end
            end
            histCount[H] = n
            keys[#keys + 1] = k
        end
    end
    if #keys > MAX_HOUSES then
        local today, newest = scanDay(now()), {}
        for _, k in ipairs(keys) do
            local m = -1
            for _, e in pairs(DB.hist[k]) do
                local days = histDecode(e, today)
                if days and days[#days] and days[#days][1] > m then m = days[#days][1] end
            end
            newest[k] = m
        end
        table.sort(keys, function(a, b) return newest[a] > newest[b] end)
        for i = MAX_HOUSES + 1, #keys do DB.hist[keys[i]] = nil end
    end
end

local GREY, WHITE, GREEN, RED = { .6, .6, .6 }, { 1, 1, 1 }, { .25, 1, .25 }, { 1, .3, .3 }
local function line(tt, l, r, lc, rc)
    tt:AddDoubleLine(l, r, lc[1], lc[2], lc[3], rc[1], rc[2], rc[3])
end

-- Three lines, always in the same order: what a vendor pays, the lowest auction price, and what selling on the
-- auction house gains you over the vendor once the cut is taken (green when it is a gain, red when it is a loss).
-- Hold Shift for the extra lines (your stack, deposit, your own record with this item).
local function addLines(tt, id)
    if not DB or not DB.enabled or type(id) ~= "number" then return end
    local _, _, quality, _, _, _, _, _, _, _, vendor, _, _, bind = C_Item.GetItemInfo(id)
    if secret(vendor) or secret(bind) or secret(quality) then return end
    if bind == 1 or bind == 4 then return end                    -- bind on pickup and quest items cannot be auctioned
    local price, qty, t, src, from = lookup(id)
    local hasVendor = type(vendor) == "number" and vendor > 0
    if not price then
        if hasVendor and quality and quality >= 1 then
            line(tt, "Vendor price", money(vendor), WHITE, WHITE)
            line(tt, "AH price", "none listed", WHITE, GREY)
        end
        return
    end
    if vendor ~= nil then line(tt, "Vendor price", hasVendor and money(vendor) or "none", WHITE, hasVendor and WHITE or GREY) end
    line(tt, "AH price  |cff999999" .. srcLabel(src, t, from) .. (qty and qty > 0 and (", " .. qty .. " listed") or "") .. "|r", money(price), WHITE, WHITE)
    if vendor == nil then return end                             -- item not cached yet; the next hover has it
    local net = math.floor(price * (100 - DB.cut) / 100)
    local d = net - (hasVendor and vendor or 0)
    local c = d >= 0 and GREEN or RED
    line(tt, "AH profit  |cff999999after " .. DB.cut .. "% cut|r", (d >= 0 and "+" or "") .. money(d), c, c)
    if IsShiftKeyDown and IsShiftKeyDown() then
        local n = C_Item.GetItemCount and C_Item.GetItemCount(id) or 0
        if type(n) == "number" and not secret(n) and n > 1 then
            line(tt, "Your " .. n .. " on the AH, after cut", money(net * n), GREY, WHITE)
        end
        if ns.tools then ns.tools.tipLine(tt, id) end
        if ns.extra then ns.extra.tipLine(tt, id, price) end
    end
end
ns.addLines = addLines

local function onTooltip(tt, data)
    if not data or not tt or not tt.AddDoubleLine then return end
    local id = data.id
    if id == nil or secret(id) then return end
    addLines(tt, id)
end

-- ------------------------------------------------------------------ recording the auction house while it is open --
local open, scanning, waitingThrottle, pendingStart = false, false, false, false
local scanId, seen, scanCount = 0, {}, 0
local ours, foreign, estimate = false, false, nil
local foreignOpen, foreignAt = false, -1e9                       -- a query of someone else's not answered yet, and when               -- sending our query; someone else's query during the scan;
                                                                 -- items expected (progress)
local function prog(fn, ...) local P = ns.progress; if P and P[fn] then P[fn](...) end end
local pend = {}                    -- items seen in the current query, written to the daily history when it ends
-- Writing re-encodes each item's string, so a full scan of thousands of items is spread over frames: up to
-- HIST_BATCH items per frame, the rest on the next ones. Whatever is still waiting is written at logout (and at
-- /reload), before the game saves. The queue runs from qh to qt (explicit bounds: Lua 5.1's # is undefined on a
-- table with holes). Each row carries the house and the day it was scanned on. A row that fails is skipped; the
-- rest go on.
local HIST_BATCH, SWEEP_LOGOUT = 400, 1000
local queue, qh, qt, qBusy, waiting = {}, 1, 0, false, {}
local function histRows(stop)
    while qh <= stop do
        local w = queue[qh]
        queue[qh] = nil; qh = qh + 1                             -- past it first, so an error skips only this row
        local H = histHouseOf(w[5])
        if H and histAdd(H, w[1], w[2], w[3], w[4]) == "wait" then waiting[#waiting + 1] = w end
    end
end
local function histStep(all, sweep, final)
    sweepLeft, canWait = sweep or BATCH_SWEEP, not final        -- at logout nothing can wait
    local stop = all and qt or math.min(qt, qh + HIST_BATCH - 1)
    while qh <= stop do pcall(histRows, stop) end
    -- Rows waiting for the sweep go to the end of the queue and are tried again on a later frame; the rest of the
    -- batch is written meanwhile.
    for i = 1, #waiting do qt = qt + 1; queue[qt] = waiting[i] end
    waiting = {}
    if qh > qt then queue, qh, qt, qBusy = {}, 1, 0, false; return end
    qBusy = true
    if C_Timer and C_Timer.After then C_Timer.After(0, function() histStep(false) end)
    elseif not all then histStep(true) end
end
local function flushHist()
    local k = next(pend) and DB.v == KNOWN_V and houseKey()
    if k then
        local L = live()
        for id, day in pairs(pend) do
            local p, q = L.p[id], L.q[id]
            if p then qt = qt + 1; queue[qt] = { id, p, q or 0, day, k } end
        end
    end
    pend = {}
    if qBusy or qh > qt then return end
    if qt - qh + 1 <= HIST_BATCH then histStep(true) else qBusy = true; histStep(false) end
end
-- At logout: everything still waiting, then a little more of the sweep for the current house.
ns.histFinish = function()
    pcall(function()
        flushHist()
        if qh <= qt then histStep(true, SWEEP_LOGOUT, true) end
        local H = histHouse()
        if H then histSweep(H, scanDay(now()), SWEEP_LOGOUT) end
    end)
end

local function record(results)
    if type(results) ~= "table" then return end
    local L, t = live(), now()
    for i = 1, #results do
        local r = results[i]
        local id, price = r.itemKey and r.itemKey.itemID, r.minPrice
        if type(id) == "number" and type(price) == "number" and not secret(price) and price > 0 then
            local q = type(r.totalQuantity) == "number" and r.totalQuantity or 0
            if seen[id] == scanId then
                if price < L.p[id] then L.p[id] = price end      -- same item at several item levels or suffixes
                L.q[id] = L.q[id] + q
            else
                seen[id] = scanId; scanCount = scanCount + 1
                L.p[id], L.q[id], L.t[id] = price, q, t
            end
            pend[id] = pend[id] or scanDay(t)                    -- the day it was seen, even if written after midnight
        end
    end
end

local function finish()
    scanning = false
    flushHist()
    local L, known = live(), 0
    for _ in pairs(L.p) do known = known + 1 end
    -- Only a scan that plausibly covered the whole house may forget items; a narrow search must not wipe the rest.
    if not foreign and scanCount >= 200 and scanCount * 2 >= known then   -- (foreign: a search of the player's came in)
        for id in pairs(L.p) do
            if seen[id] ~= scanId then L.p[id], L.q[id], L.t[id] = nil, nil, nil end
        end
        L.full = now()
        say("scan finished, " .. scanCount .. " items priced.")
        local shared = ns.sync and ns.sync.broadcast(true)
        local n = ns.progress and ns.progress.num(scanCount) or tostring(scanCount)
        prog("done", "finished: " .. n .. " items" .. (shared and ", shared with your guild" or (DB.sync == false and " (sharing off)" or " (not shared)")))
    elseif foreign then                                          -- a search of the player's came in
        foreign = false
        local text = "scan stopped: a search replaced it. Run /ahp scan to scan again."
        say(text); prog("fail", text)
    else
        local P, about = ns.progress, estimate or (known > scanCount and known) or nil
        local why = about and about > scanCount and (" (only " .. (P and P.num(scanCount) or scanCount) .. " of about " .. (P and P.num(about) or about) .. " items)")
            or (scanCount < 200 and " (fewer than 200 items)") or ""
        local text = "scan ended early with " .. scanCount .. " items; older prices kept" .. why .. "."
        say(text)
        prog("fail", text)
    end
end

-- The game allows one auction house request at a time, and its Sell tab refuses to post ("You're doing this too
-- fast") while a request of ours is under way. So the scan stands still for as long as you are selling: while a
-- Sell tab is showing or an item is on the cursor. A scan that started by itself also leaves a gap between pages.
local GAP = 1
local autoRun, queued = false, false
local SELL = { "ItemSellFrame", "CommoditiesSellFrame", "WoWTokenSellFrame" }
local function selling()
    local F = AuctionHouseFrame
    if type(F) == "table" then
        for i = 1, #SELL do
            local s = F[SELL[i]]
            if type(s) == "table" and s.IsShown and s:IsShown() then return true end
        end
    end
    return GetCursorInfo ~= nil and GetCursorInfo() == "item"
end
ns.selling = selling

local more
local function later(d)
    if queued then return end
    queued = true
    C_Timer.After(d, function() queued = false; more() end)
end
more = function()
    if not scanning then return end
    if C_AuctionHouse.HasFullBrowseResults() then return finish() end
    if selling() then prog("state", "paused"); return later(1) end   -- look again in a second; nothing is sent meanwhile
    if C_AuctionHouse.IsThrottledMessageSystemReady() then prog("state", "scanning"); C_AuctionHouse.RequestMoreBrowseResults()
    else waitingThrottle = true; prog("state", "waiting") end
end
local function page()                                            -- a page arrived
    if scanning and autoRun and not C_AuctionHouse.HasFullBrowseResults() then later(GAP) else more() end
end

local function startScan(auto)
    auto = auto == true
    if not open then return say("open the auction house first.") end
    if scanning then return say("already scanning.") end
    autoRun = auto
    if auto and selling() then                                   -- wait until the player is done selling
        C_Timer.After(2, function() if open and not scanning and not pendingStart then startScan(true) end end)
        return
    end
    if not pendingStart then                                     -- the estimate: items in the last full scan, own or guild
        scanCount = 0                                            -- (not the previous browse's count)
        local L, H, n = live(), shared(), 0
        local layer = (H.full > L.full) and H or (L.full > 0 and L) or nil
        if layer then for _ in pairs(layer.p) do n = n + 1 end end
        estimate = n > 0 and n or nil
    end
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then
        if not pendingStart then prog("start", estimate, true) end
        pendingStart = true; return
    end
    -- A search sent just before (the player's) may still be answered: wait for that answer, 3 s at most, so it is not
    -- taken for the scan's first page.
    if foreignOpen and (GetTime and GetTime() or 0) - foreignAt < 3 then
        if not pendingStart then prog("start", estimate, true) end
        pendingStart = true
        C_Timer.After(0.5, function() if open and pendingStart and not scanning then startScan(autoRun) end end)
        return
    end
    if not pendingStart then prog("start", estimate) else prog("state", "scanning") end
    pendingStart, scanning, foreign = false, true, false
    ours = true
    pcall(C_AuctionHouse.SendBrowseQuery, {
        searchString = "", filters = {}, itemClassFilters = {},
        sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } },
    })
    ours = false
end
ns.startScan = startScan

local f = CreateFrame("Frame")
f:Hide()
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, ev, a1)
    if ev == "ADDON_LOADED" then
        if a1 ~= ADDON then return end
        AHProfitDB = AHProfitDB or {}
        DB = AHProfitDB
        if DB.enabled == nil then DB.enabled = true end
        if DB.autoV ~= 3 then DB.autoscan = true; DB.autoV = 3 end   -- on again: the scan now stands still while you sell
        if DB.sync == nil then DB.sync = true end
        if DB.cut ~= 5 and DB.cut ~= 15 then DB.cut = 5 end
        DB.live = DB.live or {}
        loadShared()
        f:RegisterEvent("PLAYER_LOGOUT")
        if ns.tools then
            for _, e in ipairs(ns.tools.events) do pcall(f.RegisterEvent, f, e) end   -- an event this client lacks is skipped
            ns.tools.init()
        end
        if TooltipDataProcessor and Enum and Enum.TooltipDataType then
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, onTooltip)
        end
        -- Any browse query not sent by the scan (the player's search, any filter, or another addon's) replaces the
        -- scan's results, so it stops the scan. A post-hook on the game's API table: it runs after the call, reads
        -- none of its arguments, only sets flags, and never touches the auction house window. Favorites searches are
        -- not watched: a Favorites answer is rejected unless it covers half the house (the completeness rule).
        if hooksecurefunc and C_AuctionHouse and type(C_AuctionHouse.SendBrowseQuery) == "function" then
            pcall(hooksecurefunc, C_AuctionHouse, "SendBrowseQuery", function()
                if ours then return end
                foreignOpen, foreignAt = true, GetTime and GetTime() or 0
                if scanning then foreign = true end
            end)
        end
        if C_AuctionHouse and C_AuctionHouse.SendBrowseQuery then
            for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
                "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "AUCTION_HOUSE_BROWSE_FAILURE", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" }) do
                f:RegisterEvent(e)
            end
        end
    elseif ev == "AUCTION_HOUSE_SHOW" then
        open = true
        prog("opened")
        if DB.autoscan and C_AuctionHouse and C_AuctionHouse.SendBrowseQuery and now() - math.max(live().full, shared().full) > 900 then C_Timer.After(1, function() if open and not scanning then startScan(true) end end) end
    elseif ev == "PLAYER_LOGOUT" then
        ns.histFinish()                                          -- the game saves right after this
    elseif ev == "AUCTION_HOUSE_CLOSED" then
        flushHist()
        if scanning or pendingStart then
            local text = "scan stopped: the auction house was closed (" .. (ns.progress and ns.progress.num(scanCount) or scanCount)
                .. " items). Nothing shared, older prices kept."
            say(text); prog("fail", text)
        end
        open, scanning, waitingThrottle, pendingStart, foreign = false, false, false, false, false
    elseif ev == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        foreignOpen = false                                      -- (answers come in order: anything sent before is in)
        flushHist()                                              -- a new query: the previous one is complete
        scanId = scanId + 1; scanCount = 0
        record(C_AuctionHouse.GetBrowseResults())
        if scanning and foreign then                             -- the player's own search replaced the scan's query
            scanning, waitingThrottle, foreign = false, false, false
            local text = "scan stopped: a search replaced it. Run /ahp scan to scan again."
            say(text); prog("fail", text)
            return
        end
        if scanning then prog("count", scanCount) end
        page()
    elseif ev == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        record(a1)
        if scanning then prog("count", scanCount) end
        page()
    elseif ev == "AUCTION_HOUSE_BROWSE_FAILURE" then
        if scanning then
            scanning, foreign = false, false
            local text = "the auction house refused the scan; try /ahp scan again."
            say(text); prog("fail", text)
        end
    elseif ev == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        if pendingStart then startScan(autoRun)
        elseif waitingThrottle then waitingThrottle = false; more() end
    end
    if ev ~= "ADDON_LOADED" and DB and ns.tools then ns.tools.event(ev) end
end)

SLASH_AHPROFIT1 = "/ahp"
SlashCmdList["AHPROFIT"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "farm" then if ns.ui then ns.ui:Toggle() end
    elseif msg == "bags" or msg == "session" or msg == "prices" or msg == "deals" or msg == "recipes" or msg == "auctions" then if ns.ui then ns.ui:Open(msg) end
    elseif msg == "session start" and ns.tools then ns.tools.sessionStart(); say("session started. /ahp session shows it."); if ns.ui then ns.ui:Refresh() end
    elseif msg == "session stop" and ns.tools then say(ns.tools.sessionStop() and "session stopped." or "no session is running."); if ns.ui then ns.ui:Refresh() end
    elseif msg == "scan" then startScan()
    elseif msg == "scan stop" then
        if scanning or pendingStart then
            scanning, waitingThrottle, pendingStart, foreign = false, false, false, false
            say("scan stopped; prices seen so far are kept."); prog("fail", "scan stopped by you; prices seen so far are kept.")
        else say("no scan is running.") end
    elseif msg == "on" or msg == "off" then DB.enabled = msg == "on"; say("tooltip lines " .. msg .. ".")
    elseif msg == "auto on" or msg == "auto off" then DB.autoscan = msg == "auto on"; say("scan when the auction house opens: " .. msg:sub(6) .. "." .. (DB.autoscan and " It stands still while you are on a Sell tab." or ""))
    elseif msg == "auctionator on" or msg == "auctionator off" then
        DB.useAuctionator = msg == "auctionator on"
        say("Auctionator prices " .. msg:sub(13) .. "." .. ((DB.useAuctionator and not (type(Auctionator) == "table" and type(Auctionator.API) == "table")) and " Auctionator is not loaded." or ""))
        if ns.ui then ns.ui:Refresh() end
    elseif msg == "sync on" or msg == "sync off" then DB.sync = msg == "sync on"; say("guild sharing " .. msg:sub(6) .. ".")
    elseif msg == "share" then if ns.sync then ns.sync.broadcast() end
    elseif msg:match("^progress ") and ns.progress and ns.progress.slash(msg:sub(10)) then
    elseif ns.bags and ns.bags.slash(msg) then                   -- keep, unkeep, bagfull (Bags.lua)
    elseif msg == "cut 5" or msg == "cut 15" then DB.cut = tonumber(msg:sub(5)); say("cut set to " .. DB.cut .. "%."); if ns.ui then ns.ui:Refresh() end
    else
        local L, n = live(), 0
        for _ in pairs(L.p) do n = n + 1 end
        say(n .. " items from your scans" .. (L.full > 0 and (", last full scan " .. age(L.full)) or ", no full scan yet")
            .. ". Bundled feed: " .. (ns.seed and (ns.seed.n .. " items, " .. ns.seed.label .. ", " .. age(ns.seed.t)) or "none") .. ".")
        say("/ahp bags | session | session start | session stop | prices | deals | recipes | auctions")
        if ns.extra then say(ns.extra.nodeCount() .. " gathering nodes seen by you and your guild.") end
        if ns.sync then say(ns.sync.status()) end
        if type(Auctionator) == "table" and type(Auctionator.API) == "table" then
            say("Auctionator: " .. (DB.useAuctionator == false and "off" or "on, its prices seen today fill in when yours are missing or over a day old") .. ".")
        end
        say("/ahp farm | scan | scan stop | share | sync on | sync off | auctionator on | auctionator off | on | off | auto on | auto off | cut 5 | cut 15 | keep <item> | unkeep <item> | bagfull <0-20> | bagfull off | progress on | progress off | progress reset")
    end
end
