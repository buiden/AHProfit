-- AH Profit tools: bag advisor, measured listing deposits, a measured farming session, and price history for materials.
-- Nothing here sells, lists or moves anything. It only reads the bags, the money counter and the price tables.
local _, ns = ...
local T = {}
ns.tools = T

local function secret(v) return issecretvalue ~= nil and issecretvalue(v) end
local function num(v) return type(v) == "number" and not secret(v) end
local DURATION = 2                                               -- the middle of the three listing lengths
T.DURATION = DURATION

-- name, vendor price, bind type, item class. nil name: the client has not loaded the item yet.
local function info(id)
    local name, _, _, _, _, _, _, _, _, _, vendor, classID, _, bind = C_Item.GetItemInfo(id)
    if secret(name) or secret(vendor) or secret(bind) or secret(classID) then return nil end
    return name, vendor, bind, classID
end
T.info = info

-- ---------------------------------------------------------------------------------------------------- the bags --
-- Returns a list of { id, n (total), bound (soulbound part), bag, slot } and the same keyed by item id.
-- ids: the bag numbers to read; the five carried bags when left out.
function T.bags(ids)
    local C = C_Container
    if not (C and C.GetContainerNumSlots and C.GetContainerItemInfo) then return nil end
    local items, order = {}, {}
    for _, bag in ipairs(ids or { 0, 1, 2, 3, 4 }) do
        local ok, n = pcall(C.GetContainerNumSlots, bag)
        if ok and num(n) then
            for slot = 1, n do
                local ok2, i = pcall(C.GetContainerItemInfo, bag, slot)
                if ok2 and type(i) == "table" and num(i.itemID) and num(i.stackCount) and i.stackCount > 0 then
                    local it = items[i.itemID]
                    if not it then
                        it = { id = i.itemID, n = 0, bound = 0, bag = bag, slot = slot }
                        items[i.itemID] = it; order[#order + 1] = it
                    end
                    it.n = it.n + i.stackCount
                    if not secret(i.isBound) and i.isBound == true then it.bound = it.bound + i.stackCount
                    else it.bag, it.slot = bag, slot end           -- remember a slot that can be listed
                end
            end
        end
    end
    return order, items
end

-- ------------------------------------------------------------------------------------------- listing deposits --
-- The deposit is asked from the game itself, which only answers while the auction house is open. It is stored per
-- unit with the time it was measured. No formula is guessed when there is no measurement.
local ctx = {}
function T.ahOpen() return ctx.ah == true end
function T.deposit(id)
    local D = ns.db()
    local d = D and D.dep and D.dep[id]
    if type(d) == "table" and type(d[1]) == "number" and type(d[2]) == "number" then return d end
end
local function measure(it)
    local A, D = C_AuctionHouse, ns.db()
    local q = it.n - it.bound
    if not (A and D and q >= 1) then return end
    local loc
    if ItemLocation and ItemLocation.CreateFromBagAndSlot then
        local ok, l = pcall(ItemLocation.CreateFromBagAndSlot, ItemLocation, it.bag, it.slot)
        if ok then loc = l end
    end
    local commodity                                             -- true, false, or nil when the game does not say
    if loc and A.GetItemCommodityStatus and Enum and Enum.ItemCommodityStatus then
        local ok, s = pcall(A.GetItemCommodityStatus, loc)
        if ok and num(s) then
            if s == Enum.ItemCommodityStatus.Commodity then commodity = true
            elseif s == Enum.ItemCommodityStatus.Item then commodity = false end
        end
    end
    local d
    if commodity ~= false and A.CalculateCommodityDeposit then
        local ok, v = pcall(A.CalculateCommodityDeposit, it.id, DURATION, q)
        if ok and num(v) and (v > 0 or (v == 0 and commodity == true)) then d = v / q end
    end
    if d == nil and commodity ~= true and loc and A.CalculateItemDeposit then
        local ok, v = pcall(A.CalculateItemDeposit, loc, DURATION, 1)
        if ok and num(v) and (v > 0 or (v == 0 and commodity == false)) then d = v end
    end
    if d ~= nil then
        D.dep = D.dep or {}
        D.dep[it.id] = { d, ns.now() }
    end
end
function T.measureAll(list)
    if not T.ahOpen() then return end
    list = list or T.bags()
    if not list then return end
    for _, it in ipairs(list) do measure(it) end
end
function T.durationText()
    local s = _G["AUCTION_DURATION_" .. ({ "ONE", "TWO", "THREE" })[DURATION]]
    return (type(s) == "string" and not secret(s) and s ~= "") and s or "the middle listing length"
end

-- ------------------------------------------------------------------------------------------------ bag advisor --
-- For every item in the bags: auction it, vendor it, or neither. cutPct is the auction cut (5 or 15).
-- Totals: ah (after cut), vendor, all (vendoring everything), extra (advice minus vendoring everything),
-- risk (measured deposits on the auction rows), pending (items the client has not loaded yet), kept.
function T.advise(list, cutPct)
    local rows, tot = {}, { ah = 0, vendor = 0, all = 0, risk = 0, pending = 0, kept = 0, unmeasured = 0 }
    for _, it in ipairs(list) do
        local name, vendor, bind, classID = info(it.id)
        if type(name) ~= "string" or type(vendor) ~= "number" then
            tot.pending = tot.pending + 1
        else
            local free = it.n - it.bound
            local price, qty, t, src, from = ns.lookup(it.id)
            local net = price and math.floor(price * (100 - cutPct) / 100) or 0
            local r = { id = it.id, name = name, n = it.n, free = free, bound = it.bound, vendor = vendor, price = price, net = net,
                qty = qty, t = t, src = src, from = from, gear = classID == 2 or classID == 4, quest = bind == 4 or classID == 12 }
            if price and free > 0 and bind ~= 1 and bind ~= 4 and net > vendor then
                r.verdict, r.value, r.gain = "ah", net * free + vendor * it.bound, (net - vendor) * free
                tot.ah, tot.vendor = tot.ah + net * free, tot.vendor + vendor * it.bound
                local d = T.deposit(it.id)
                if d then r.risk, r.riskAt = math.floor(d[1] * free + 0.5), d[2]; tot.risk = tot.risk + r.risk
                else tot.unmeasured = tot.unmeasured + 1 end
            elseif vendor > 0 and not r.quest then
                r.verdict, r.value = "vendor", vendor * it.n
                tot.vendor = tot.vendor + r.value
            else
                r.verdict, r.value = "keep", 0
                tot.kept = tot.kept + 1
            end
            if not r.quest then tot.all = tot.all + vendor * it.n end
            if r.verdict ~= "keep" then rows[#rows + 1] = r end
        end
    end
    table.sort(rows, function(a, b) if a.value ~= b.value then return a.value > b.value end return a.name < b.name end)
    tot.extra = tot.ah + tot.vendor - tot.all
    return rows, tot
end

-- ---------------------------------------------------------------------------------------------------- session --
-- Measured, not estimated from drop rates: coin is the real change of the money counter, split by the window that
-- was open; items are the real change of the bag contents. Items that leave the bags at a vendor, the mailbox, the
-- bank, the auction house or a trade stop counting (sold, posted or stored), so nothing is counted twice and an
-- auction that is only posted is never counted as income.
local lastMoney
local grace = 0
local function sess() local D = ns.db(); return D and D.session end
local onLedger                                                   -- the daily money ledger, below
local function place()
    if ctx.vendor then return "vendor" end
    if ctx.mail then return "mail" end
    if ctx.ah then return "ah" end
    if ctx.trade then return "trade" end
    return "loot"
end
-- The windows where items leave or enter the bags without being farmed (sold, posted, stored, traded).
local BAG_WINDOWS = { vendor = true, mail = true, ah = true, trade = true, bank = true }
local function neutral() return ctx.vendor or ctx.mail or ctx.ah or ctx.trade or ctx.bank or ns.now() <= grace end
local function counts(items)
    local c = {}
    for id, it in pairs(items) do c[id] = it.n end
    return c
end
function T.sessionOn() local S = sess(); return S ~= nil and S.on == true end
local onMoney
function T.sessionStart()
    local D = ns.db()
    if not D then return false end
    onMoney()                      -- a change not yet seen belongs to the time before; the ledger still gets it
    local _, items = T.bags()
    local t = ns.now()
    D.session = { on = true, acc = 0, at = t, started = t, inc = {}, out = {}, net = {}, cur = counts(items or {}), bags = items ~= nil }
    T.where(D.session)
    local m = GetMoney and GetMoney()
    if not num(m) then D.session.blind = true end                -- hidden now: the next change is not the session's
    return true
end
function T.sessionStop()
    local S = sess()
    if not (S and S.on) then return false end
    S.acc, S.on = S.acc + math.max(0, ns.now() - S.at), false
    T.archive(S)
    return true
end
onMoney = function()
    local m = GetMoney and GetMoney()
    if not num(m) then return end
    local S = sess()
    if lastMoney then
        local d, c = m - lastMoney, place()
        if S and S.on and S.blind then S.blind = nil
        elseif S and S.on then
            if d > 0 then S.inc[c] = (S.inc[c] or 0) + d elseif d < 0 then S.out[c] = (S.out[c] or 0) - d end
        end
        if d ~= 0 then onLedger(d) end
    end
    lastMoney = m
end
local function onBags()
    local S = sess()
    if not (S and S.on) then return end
    local _, items = T.bags()
    if not items then return end
    local quiet, cur, net = neutral(), S.cur, S.net
    local function apply(id, d)
        local v = net[id] or 0
        if quiet then
            if d < 0 and v > 0 then v = math.max(0, v + d) end
        else v = v + d end
        net[id] = v ~= 0 and v or nil
    end
    for id, it in pairs(items) do
        local d = it.n - (cur[id] or 0)
        if d ~= 0 then apply(id, d) end
    end
    for id, n in pairs(cur) do if not items[id] then apply(id, -n) end end
    S.cur = counts(items)
end
-- Returns nil without a session, else { on, elapsed, inc, out, coinIn, coinOut, gained = { rows }, used = { rows },
-- gainedValue, usedValue }. Row: { id, name, n, each, value, how ("ah", "vendor" or nil when no price is known) }.
function T.sessionReport(cutPct)
    local S = sess()
    if not S then return nil end
    local R = { on = S.on, elapsed = S.acc + (S.on and math.max(0, ns.now() - S.at) or 0), inc = S.inc, out = S.out,
        coinIn = 0, coinOut = 0, gained = {}, used = {}, gainedValue = 0, usedValue = 0, bags = S.bags, nodes = S.nodes or 0 }
    for _, v in pairs(S.inc) do R.coinIn = R.coinIn + v end
    for _, v in pairs(S.out) do R.coinOut = R.coinOut + v end
    for id, n in pairs(S.net) do
        local name, vendor = info(id)
        local price = ns.lookup(id)
        local net = price and math.floor(price * (100 - cutPct) / 100) or 0
        local each, how = 0, nil
        if net > 0 and net >= (vendor or 0) then each, how = net, "ah"
        elseif type(vendor) == "number" and vendor > 0 then each, how = vendor, "vendor" end
        local q = n > 0 and n or -n
        local row = { id = id, name = type(name) == "string" and name or ("item " .. id), n = q, each = each, value = each * q, how = how }
        if n > 0 then R.gained[#R.gained + 1] = row; R.gainedValue = R.gainedValue + row.value
        else R.used[#R.used + 1] = row; R.usedValue = R.usedValue + row.value end
    end
    local function by(a, b) if a.value ~= b.value then return a.value > b.value end return a.name < b.name end
    table.sort(R.gained, by); table.sort(R.used, by)
    return R
end

-- ------------------------------------------------------------------------------------ money ledger (DB.v 3) --
-- DB.ledger[char][day][source] = { in, out }: copper per character ("Name-Realm"), day (UTC days since 2020-01-01,
-- like the price history) and source, from the change of the money counter only. The source is the window that is
-- open (or was closed a moment ago); with none, money coming in is "loot" and money going out is "other".
-- Kept 180 days, at most 50 characters. A save from a newer version is not written (ns.sharedOK() is false).
local LEDGER_DAYS, LEDGER_CHARS, SESSIONS, ITEMS = 180, 50, 100, 5000
T.LEDGER_DAYS, T.LEDGER_CHARS, T.SESSIONS, T.ITEMS = LEDGER_DAYS, LEDGER_CHARS, SESSIONS, ITEMS
local SOURCES = { vendor = true, repair = true, ah = true, mail = true, trade = true, trainer = true, taxi = true, quest = true,
    loot = true, other = true }
T.SOURCES = SOURCES
local MAXC = 1e12
local function okNum(v, max) return num(v) and v >= 0 and v <= max and v == math.floor(v) end
local function me()
    local n, r = UnitName and UnitName("player"), GetRealmName and GetRealmName()
    if type(n) ~= "string" or secret(n) or n == "" or type(r) ~= "string" or secret(r) or r == "" then return nil end
    return n .. "-" .. r
end
local function writable() local D = ns.db(); return D and ns.sharedOK and ns.sharedOK() and type(D.ledger) == "table" and D or nil end
local recent = {}                  -- source -> until when a just-made call still counts
local lastClosed, ledgerGrace = nil, 0   -- the window closed last, and until when money still goes to it
-- Money taken from mails: each take call notes what it expects (kind "ah" for an auction invoice, else "mail", and
-- the mail's money when the game tells it). Money coming in at the mailbox is matched to these in order, so taking
-- many mails at once still splits auction sales from other mail, even when the game merges money events.
local mailq = {}
local function soon(src, sec) recent[src] = ns.now() + (sec or 2) end
local function within(src) return recent[src] ~= nil and ns.now() <= recent[src] end
local function ledgerSource(d)
    if d < 0 and ((InRepairMode and InRepairMode() == true) or within("repair")) then return "repair" end
    if ctx.vendor then return "vendor" end
    if ctx.ah then return "ah" end
    if ctx.mail then return "mail" end
    if ctx.trade then return "trade" end
    if ctx.trainer then return "trainer" end
    if ctx.taxi or within("taxi") then return "taxi" end
    if ctx.quest or within("quest") then return "quest" end
    if lastClosed and ns.now() <= ledgerGrace and SOURCES[lastClosed] then return lastClosed end
    return d > 0 and "loot" or "other"
end
T.ledgerSource = ledgerSource
-- Drops days older than LEDGER_DAYS from one character's ledger; returns its newest day (or nil when empty).
local function pruneChar(C, today)
    local newest
    for day in pairs(C) do
        if day <= today - LEDGER_DAYS then C[day] = nil
        elseif not newest or day > newest then newest = day end
    end
    return newest
end
local function trimChars(L, today, keep)
    local list = {}
    for k, C in pairs(L) do
        local newest = pruneChar(C, today)
        if newest then list[#list + 1] = { k, newest } else L[k] = nil end
    end
    if #list <= LEDGER_CHARS then return end
    table.sort(list, function(a, b) if a[1] == keep then return b[1] ~= keep elseif b[1] == keep then return false end
        if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
    for i = LEDGER_CHARS + 1, #list do L[list[i][1]] = nil end
end
onLedger = function(d)
    local D, k = writable(), me()
    if not (D and k) then return end
    local today = ns.scanDay(ns.now())
    local C = D.ledger[k]
    local new = not C
    if new then C = {}; D.ledger[k] = C end
    local day = C[today]
    if not day then day = {}; C[today] = day; pruneChar(C, today) end
    if new then trimChars(D.ledger, today, k) end                -- after the day exists, so the new character counts
    local function add(src, x)
        local e = day[src]
        if not e then e = { 0, 0 }; day[src] = e end
        if x > 0 then e[1] = math.min(MAXC, e[1] + x) else e[2] = math.min(MAXC, e[2] - x) end
    end
    local src = ledgerSource(d)
    if src == "mail" and d > 0 then
        local t = ns.now()
        while mailq[1] and t - mailq[1][3] > 30 do table.remove(mailq, 1) end   -- a take whose money never came
        local rest = d
        while rest > 0 and mailq[1] do
            local q = mailq[1]
            local x = q[2] and math.min(rest, q[2]) or rest             -- unknown amount: this whole change
            add(q[1], x); rest = rest - x
            if q[2] and q[2] > x then q[2] = q[2] - x else table.remove(mailq, 1) end
        end
        if rest > 0 then add("mail", rest) end
        return
    end
    add(src, d)
end

-- ------------------------------------------------------------------------------------------ session archive --
-- A finished session is kept in DB.sessions (the newest SESSIONS): who, where it started, when, coin by source
-- and the items gained or used (the 30 largest changes; value them with today's prices).
local function copySide(t)
    local out = {}
    for c, v in pairs(t or {}) do if type(c) == "string" and #c <= 16 and okNum(v, MAXC) and v > 0 then out[c] = v end end
    return out
end
function T.where(S)
    local m = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if okNum(m, 1e7) then S.map = m end
    local z = GetZoneText and GetZoneText()
    if type(z) == "string" and not secret(z) and z ~= "" and #z <= 80 then S.zone = z end
end
function T.archive(S)
    local D = writable()
    if not D then return end
    local n, r = UnitName and UnitName("player"), GetRealmName and GetRealmName()
    local f, lvl = UnitFactionGroup and UnitFactionGroup("player"), UnitLevel and UnitLevel("player")
    local items, list = {}, {}
    for id, q in pairs(S.net or {}) do if okNum(id, 1e7) and num(q) and q ~= 0 and q == math.floor(q) then list[#list + 1] = { id, q } end end
    table.sort(list, function(a, b) local x, y = math.abs(a[2]), math.abs(b[2]); if x ~= y then return x > y end return a[1] < b[1] end)
    for i = 1, math.min(30, #list) do items[i] = list[i] end
    if S.map == nil and S.zone == nil then T.where(S) end
    local rec = { char = (type(n) == "string" and not secret(n)) and n or nil, realm = (type(r) == "string" and not secret(r)) and r or nil,
        faction = (type(f) == "string" and not secret(f)) and f or nil, level = okNum(lvl, 1000) and lvl or nil,
        map = S.map, zone = S.zone, start = S.started, stop = ns.now(), dur = S.acc, inc = copySide(S.inc), out = copySide(S.out),
        items = items, nodes = okNum(S.nodes, 1e6) and S.nodes or 0 }
    local A = D.sessions
    A[#A + 1] = rec
    while #A > SESSIONS do table.remove(A, 1) end
    T.noteItems((function() local ids = {}; for i, x in ipairs(items) do ids[i] = x[1] end return ids end)())
end

-- ---------------------------------------------------------------------------------------------- item cache --
-- DB.items[id] = { name, vendor price, time last seen }, for the items in your bank, your auctions and your
-- sessions, so tools outside the game can name them. Only what the client has loaded is stored; the rest is asked
-- for and tried again at logout. At most ITEMS, the least recently seen dropped first.
local missing, missingN, MISSING_MAX = {}, 0, 500
function T.missingCount() return missingN end
function T.noteItems(ids)
    local D = writable()
    if not (D and type(D.items) == "table") then return end
    local I, t, added = D.items, ns.now(), false
    for i = 1, math.min(#ids, 2000) do
        local id = ids[i]
        if okNum(id, 1e7) and id > 0 then
            local name, vendor = info(id)
            if type(name) == "string" and name ~= "" and #name <= 200 and okNum(vendor, 1e10) then
                local e = I[id]
                if e then e[1], e[2], e[3] = name, vendor, t else I[id] = { name, vendor, t }; added = true end
                if missing[id] then missing[id] = nil; missingN = missingN - 1 end
            elseif not missing[id] and missingN < MISSING_MAX then    -- at most MISSING_MAX wait; the rest come again later
                missing[id] = true; missingN = missingN + 1
                if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
            end
        end
    end
    if added then
        local list = {}
        for id, e in pairs(I) do list[#list + 1] = { id, e[3] } end
        if #list > ITEMS then
            table.sort(list, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
            for k = 1, #list - ITEMS do I[list[k][1]] = nil end
        end
    end
end
-- The items of this character's bank, auctions and running session, and those still missing.
local function noteMine()
    local D, k = ns.db(), me()
    if not (D and k) then return end
    local ids, seen = {}, {}
    local function add(id) if not seen[id] then seen[id] = true; ids[#ids + 1] = id end end
    local b = type(D.bank) == "table" and D.bank[k]
    if type(b) == "table" and type(b.items) == "table" then for _, it in ipairs(b.items) do if type(it) == "table" then add(it[1]) end end end
    local o = type(D.auc) == "table" and type(D.auc.own) == "table" and D.auc.own[k]
    if type(o) == "table" and type(o.list) == "table" then for _, it in ipairs(o.list) do if type(it) == "table" then add(it[1]) end end end
    local S = sess()
    if S and type(S.net) == "table" then for id in pairs(S.net) do add(id) end end
    for id in pairs(missing) do add(id) end
    T.noteItems(ids)
end
T.noteMine = noteMine

-- Checks the v3 tables at load: wrong types and out-of-range values are dropped, the caps applied.
local function loadV3()
    local D = writable()
    if not D then return end
    local today = ns.scanDay(ns.now())
    for k, C in pairs(D.ledger) do
        if type(k) ~= "string" or #k > 80 or type(C) ~= "table" then D.ledger[k] = nil
        else
            for day, srcs in pairs(C) do
                if not okNum(day, 1e5) or type(srcs) ~= "table" then C[day] = nil
                else
                    for s, e in pairs(srcs) do
                        if not (SOURCES[s] and type(e) == "table" and okNum(e[1], MAXC) and okNum(e[2], MAXC)) then srcs[s] = nil end
                    end
                    if next(srcs) == nil then C[day] = nil end
                end
            end
        end
    end
    trimChars(D.ledger, today, me())
    local A, keep = D.sessions, {}
    for i = 1, #A do
        local s = A[i]
        if type(s) == "table" and okNum(s.start, 1e10) and okNum(s.stop, 1e10) and okNum(s.dur, 1e9) and type(s.inc) == "table"
            and type(s.out) == "table" and type(s.items) == "table" then
            s.inc, s.out = copySide(s.inc), copySide(s.out)
            keep[#keep + 1] = s
        end
    end
    while #keep > SESSIONS do table.remove(keep, 1) end
    D.sessions = keep
    local n, list = 0, {}
    for id, e in pairs(D.items) do
        if not (okNum(id, 1e7) and type(e) == "table" and type(e[1]) == "string" and e[1] ~= "" and #e[1] <= 200
            and okNum(e[2], 1e10) and okNum(e[3], 1e10)) then D.items[id] = nil
        else n = n + 1; list[n] = { id, e[3] } end
    end
    if n > ITEMS then
        table.sort(list, function(a, b) if a[2] ~= b[2] then return a[2] < b[2] end return a[1] < b[1] end)
        for k = 1, n - ITEMS do D.items[list[k][1]] = nil end
    end
end

-- ------------------------------------------------------------------------------------------------- events --
-- Core.lua owns the event frame and forwards these.
T.events = { "PLAYER_ENTERING_WORLD", "PLAYER_MONEY", "BAG_UPDATE_DELAYED", "PLAYER_LOGOUT", "MERCHANT_SHOW", "MERCHANT_CLOSED",
    "MAIL_SHOW", "MAIL_CLOSED", "TRADE_SHOW", "TRADE_CLOSED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
    "TRAINER_SHOW", "TRAINER_CLOSED", "TAXIMAP_OPENED", "TAXIMAP_CLOSED", "QUEST_COMPLETE", "QUEST_FINISHED", "QUEST_TURNED_IN" }
local OPEN = { MERCHANT_SHOW = "vendor", MAIL_SHOW = "mail", TRADE_SHOW = "trade", BANKFRAME_OPENED = "bank", AUCTION_HOUSE_SHOW = "ah",
    TRAINER_SHOW = "trainer", TAXIMAP_OPENED = "taxi", QUEST_COMPLETE = "quest" }
local CLOSE = { MERCHANT_CLOSED = "vendor", MAIL_CLOSED = "mail", TRADE_CLOSED = "trade", BANKFRAME_CLOSED = "bank", AUCTION_HOUSE_CLOSED = "ah",
    TRAINER_CLOSED = "trainer", TAXIMAP_CLOSED = "taxi", QUEST_FINISHED = "quest" }
-- The only calls watched: repairing, taking a flight, taking money from a mail. Nothing is called, only noted.
local hooked = false
local function hooks()
    if hooked or not hooksecurefunc then return end
    hooked = true
    if RepairAllItems then hooksecurefunc("RepairAllItems", function() soon("repair") end) end
    if TakeTaxiNode then hooksecurefunc("TakeTaxiNode", function() soon("taxi", 3) end) end
    local function mail(i)
        local ok, kind = pcall(function() return GetInboxInvoiceInfo and GetInboxInvoiceInfo(i) end)
        local ok2, m = pcall(function() if GetInboxHeaderInfo then return select(5, GetInboxHeaderInfo(i)) end end)
        kind = (ok and not secret(kind) and kind == "seller") and "ah" or "mail"
        m = (ok2 and okNum(m, MAXC) and m > 0) and m or nil
        if m == nil and kind == "mail" then return end           -- nothing to expect: plain mail money is "mail" anyway
        if #mailq < 50 then mailq[#mailq + 1] = { kind, m, ns.now() } end
    end
    if TakeInboxMoney then hooksecurefunc("TakeInboxMoney", mail) end
    if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", mail) end
end
function T.init()
    local S = sess()
    if S and S.on then S.at = ns.now() end                       -- time spent logged out is not farming time
    loadV3()
    hooks()
end
function T.event(ev)
    if OPEN[ev] then
        ctx[OPEN[ev]] = true
        if ev == "AUCTION_HOUSE_SHOW" and C_Timer and C_Timer.After then C_Timer.After(1.5, function() T.measureAll() end) end
    elseif CLOSE[ev] then
        if ev == "QUEST_FINISHED" and not ctx.quest then return end   -- it also closes the other quest frames
        ctx[CLOSE[ev]] = nil
        lastClosed, ledgerGrace = CLOSE[ev], ns.now() + 1        -- money a moment after the window closes is still its
        if BAG_WINDOWS[CLOSE[ev]] then grace = ns.now() + 1 end  -- the bags settle a moment after these close
    elseif ev == "QUEST_TURNED_IN" then soon("quest"); return
    elseif ev == "PLAYER_MONEY" or ev == "PLAYER_ENTERING_WORLD" then onMoney()
    elseif ev == "BAG_UPDATE_DELAYED" then onBags()
    elseif ev == "PLAYER_LOGOUT" then
        local S = sess()
        if S and S.on then S.acc, S.at = S.acc + math.max(0, ns.now() - S.at), ns.now() end
        noteMine()
        return
    else return end                                              -- auction scan pages and the like are not ours
    if ns.ui and ns.ui.OnTools then ns.ui:OnTools(ev) end
end

-- Tooltip line under the profit lines: only when a deposit was measured for this item.
function T.tipLine(tt, id)
    local d = T.deposit(id)
    if not d then return end
    tt:AddDoubleLine("Deposit, lost if it does not sell (" .. ns.age(d[2]) .. ")", ns.money(math.floor(d[1] + 0.5)), .6, .6, .6, .6, .6, .6)
end

-- ---------------------------------------------------------------------------------------------- price history --
-- History.lua: ns.hist = { feedTime, { firstDay, days }, { { name, itemID, day1, day1Price, price per day ... }, ... } }
-- A day is a Riyadh calendar day (number of days since 1970). A price of 0 means nothing was listed that day.
-- Each daily price is the middle value of that day's hourly official snapshots of the lowest asking price.
local function hist()
    local d = ns.hist
    if type(d) ~= "table" or type(d[2]) ~= "table" or type(d[3]) ~= "table" then return nil end
    return d
end
function T.histTime() local d = hist(); return d and d[1] or nil end
function T.dayText(day) return date("!%a %d %b", day * 86400) end
-- Materials whose name contains q (lower case, plain text). Row: { idx, name, id, day1, day1p, last }.
function T.histList(q)
    local d = hist()
    local out = {}
    if not d then return out end
    for i, it in ipairs(d[3]) do
        if not q or q == "" or it[1]:lower():find(q, 1, true) then
            local last = 0
            for k = #it, 5, -1 do if it[k] > 0 then last = it[k]; break end end
            out[#out + 1] = { idx = i, name = it[1], id = it[2], day1 = it[3], day1p = it[4], last = last > 0 and last or it[4] }
        end
    end
    return out
end
-- One material: { name, id, day1, day1p, pts = { { d = day, p = price }, ... }, lo, hi }.
function T.histSeries(idx)
    local d = hist()
    local it = d and d[3][idx]
    if not it then return nil end
    local s = { name = it[1], id = it[2], day1 = it[3], day1p = it[4], pts = {}, lo = it[4], hi = it[4] }
    local first = d[2][1]
    for k = 5, #it do
        local p = it[k]
        if p > 0 then
            s.pts[#s.pts + 1] = { d = first + k - 5, p = p }
            if p < s.lo then s.lo = p end
            if p > s.hi then s.hi = p end
        end
    end
    return s
end
