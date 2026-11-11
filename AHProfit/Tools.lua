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
local function place()
    if ctx.vendor then return "vendor" end
    if ctx.mail then return "mail" end
    if ctx.ah then return "ah" end
    if ctx.trade then return "trade" end
    return "loot"
end
local function neutral() return next(ctx) ~= nil or ns.now() <= grace end
local function counts(items)
    local c = {}
    for id, it in pairs(items) do c[id] = it.n end
    return c
end
function T.sessionOn() local S = sess(); return S ~= nil and S.on == true end
function T.sessionStart()
    local D = ns.db()
    if not D then return false end
    local _, items = T.bags()
    local t = ns.now()
    D.session = { on = true, acc = 0, at = t, started = t, inc = {}, out = {}, net = {}, cur = counts(items or {}), bags = items ~= nil }
    local m = GetMoney and GetMoney()
    lastMoney = num(m) and m or nil
    return true
end
function T.sessionStop()
    local S = sess()
    if not (S and S.on) then return false end
    S.acc, S.on = S.acc + math.max(0, ns.now() - S.at), false
    return true
end
local function onMoney()
    local m = GetMoney and GetMoney()
    if not num(m) then return end
    local S = sess()
    if S and S.on and lastMoney then
        local d, c = m - lastMoney, place()
        if d > 0 then S.inc[c] = (S.inc[c] or 0) + d elseif d < 0 then S.out[c] = (S.out[c] or 0) - d end
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

-- ------------------------------------------------------------------------------------------------- events --
-- Core.lua owns the event frame and forwards these.
T.events = { "PLAYER_ENTERING_WORLD", "PLAYER_MONEY", "BAG_UPDATE_DELAYED", "PLAYER_LOGOUT", "MERCHANT_SHOW", "MERCHANT_CLOSED",
    "MAIL_SHOW", "MAIL_CLOSED", "TRADE_SHOW", "TRADE_CLOSED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }
local OPEN = { MERCHANT_SHOW = "vendor", MAIL_SHOW = "mail", TRADE_SHOW = "trade", BANKFRAME_OPENED = "bank", AUCTION_HOUSE_SHOW = "ah" }
local CLOSE = { MERCHANT_CLOSED = "vendor", MAIL_CLOSED = "mail", TRADE_CLOSED = "trade", BANKFRAME_CLOSED = "bank", AUCTION_HOUSE_CLOSED = "ah" }
function T.init()
    local S = sess()
    if S and S.on then S.at = ns.now() end                       -- time spent logged out is not farming time
end
function T.event(ev)
    if OPEN[ev] then
        ctx[OPEN[ev]] = true
        if ev == "AUCTION_HOUSE_SHOW" and C_Timer and C_Timer.After then C_Timer.After(1.5, function() T.measureAll() end) end
    elseif CLOSE[ev] then
        ctx[CLOSE[ev]] = nil
        grace = ns.now() + 1                                     -- the bags settle a moment after the window closes
    elseif ev == "PLAYER_MONEY" or ev == "PLAYER_ENTERING_WORLD" then onMoney()
    elseif ev == "BAG_UPDATE_DELAYED" then onBags()
    elseif ev == "PLAYER_LOGOUT" then
        local S = sess()
        if S and S.on then S.acc, S.at = S.acc + math.max(0, ns.now() - S.at), ns.now() end
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
