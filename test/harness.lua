-- Minimal WoW client stub for AHProfit. Run: lua test/harness.lua (from the project directory)
-- The clock sits 10 minutes after the bundled price file, whatever its feed time is (the file is rebuilt hourly).
local seedTime = tonumber(assert(io.open("AHProfit/Data.lua")):read("*a"):match("ns%.seed = { t = (%d+)"))
local S = { time = seedTime + 600, faction = "Alliance", realm = "TestRealm", ready = true, pages = {}, page = 0, sent = 0, more = 0, count = {} }
local items = {}  -- id -> {vendor, bind, quality}
local handlers, tipcb, timers, chat = nil, nil, {}, {}
function GetServerTime() return S.time end
time = function() return S.time end
function GetRealmName() return S.realm end
function UnitFactionGroup() return S.faction, S.faction end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) chat[#chat + 1] = m end }
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
C_Item = {
    GetItemInfo = function(id) local i = items[id]; if not i then return nil end
        return "n", "l", i[3], 1, 1, "t", "st", 20, "", 1, i[1], 7, 0, i[2] end,
    GetItemCount = function(id) return S.count[id] or 0 end,
}
Enum = { TooltipDataType = { Item = 0 }, AuctionHouseSortOrder = { Price = 0 } }
TooltipDataProcessor = { AddTooltipPostCall = function(t, fn) assert(t == 0); tipcb = fn end }
C_AuctionHouse = {
    IsThrottledMessageSystemReady = function() return S.ready end,
    SendBrowseQuery = function(q) assert(q.searchString == "" and q.sorts[1].sortOrder == 0); S.sent = S.sent + 1; S.page = 1 end,
    GetBrowseResults = function() return S.pages[1] or {} end,
    HasFullBrowseResults = function() return S.page >= #S.pages end,
    RequestMoreBrowseResults = function() S.more = S.more + 1; S.page = S.page + 1 end,
}
local frame = { Hide = function() end, RegisterEvent = function() end, SetScript = function(_, _, fn) handlers = fn end }
function CreateFrame() return frame end
SlashCmdList = {}
local ns = {}
local function load(f) local fn = assert(loadfile("AHProfit/" .. f)); fn("AHProfit", ns) end
local function fire(ev, a) handlers(frame, ev, a) end
local function tip(id) local out = {}
    local tt = { AddDoubleLine = function(_, l, r) out[#out + 1] = (l .. " => " .. r):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") end }
    tipcb(tt, { id = id }); return out end
local function R(id, price, q) return { itemKey = { itemID = id }, minPrice = price, totalQuantity = q } end
local pass, fail = 0, 0
local function ok(name, cond, extra) if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. " " .. tostring(extra or "")) end end
local function has(lines, s) for _, l in ipairs(lines) do if l:find(s, 1, true) then return true end end return false end

load("Data.lua"); load("Core.lua"); fire("ADDON_LOADED", "Other"); ok("ignores other addons", AHProfitDB == nil)
fire("ADDON_LOADED", "AHProfit")
ok("defaults", AHProfitDB.enabled and AHProfitDB.autoscan == true and AHProfitDB.cut == 5)
ok("seed loaded", ns.seed.n > 2000 and #ns.seed.flat == ns.seed.n * 3)
ok("money", ns.money(12345):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") == "1g 23s 45c" and ns.money(-7):find("^-"))

-- the user's own example: vendor 5s, AH 6s -> 5s70c after 5% cut -> +70c
local f, id1 = ns.seed.flat, nil
id1 = f[1]; local seedPrice = f[2]
items[id1] = { 500, 0, 1 }
AHProfitDB.live["TestRealm|Alliance"] = { p = { [id1] = 600 }, q = { [id1] = 3 }, t = { [id1] = S.time }, full = 0 }
local l = tip(id1)
ok("exactly three lines, in order: vendor, AH, profit", #l == 3 and l[1] == "Vendor price => 5s 0c" and l[2] == "AH price  scan just now, 3 listed => 6s 0c" and l[3] == "AH profit  after 5% cut => +70c", table.concat(l, " / "))
local colors = {}
ns.addLines({ AddDoubleLine = function(_, _, _, r, g, b) colors[#colors + 1] = { r, g, b } end }, id1)
ok("a gain is green", colors[3][2] == 1 and colors[3][1] < 1)
AHProfitDB.cut = 15; l = tip(id1)
ok("15% cut still beats vendor by 10c", l[3] == "AH profit  after 15% cut => +10c" and #l == 3, table.concat(l, " / ")); AHProfitDB.cut = 5
items[id1] = { 580, 0, 1 }; l = tip(id1)
ok("vendor pays more: a minus", l[1] == "Vendor price => 5s 80c" and l[3] == "AH profit  after 5% cut => -10c" and #l == 3, table.concat(l, " / "))
colors = {}; ns.addLines({ AddDoubleLine = function(_, _, _, r, g, b) colors[#colors + 1] = { r, g, b } end }, id1)
ok("a loss is red", colors[3][1] == 1 and colors[3][2] < 1); items[id1] = { 500, 0, 1 }
S.count[id1] = 20; l = tip(id1); ok("no extra lines without Shift", #l == 3, table.concat(l, " / "))
function IsShiftKeyDown() return true end
l = tip(id1); ok("stack line with Shift", #l >= 4 and has(l, "Your 20 on the AH, after cut => 1g 14s 0c"), table.concat(l, " / ")); S.count[id1] = 0
IsShiftKeyDown = nil

-- feed fallback, newer feed beats older scan (one over 2 hours old: a scan under 2 hours wins whatever the feed)
AHProfitDB.live["TestRealm|Alliance"].t[id1] = ns.seed.t - 7300
l = tip(id1); ok("newer feed beats older scan", has(l, "AH price  feed 10m ago"), table.concat(l, " / "))
AHProfitDB.live["TestRealm|Alliance"].t[id1] = ns.seed.t - 10
l = tip(id1); ok("a scan under 2 hours old beats a newer feed", has(l, "AH price  scan 10m ago"), table.concat(l, " / "))
AHProfitDB.live["TestRealm|Alliance"].t[id1] = ns.seed.t - 7300
-- binding / unknown / uncached / no vendor value
items[900001] = { 100, 1, 2 }; ok("bind on pickup hidden", #tip(900001) == 0)
items[900002] = { 100, 4, 1 }; ok("quest item hidden", #tip(900002) == 0)
items[900003] = { 250, 0, 1 }; l = tip(900003); ok("unlisted shows vendor", #l == 2 and l[1] == "Vendor price => 2s 50c" and l[2] == "AH price => none listed", table.concat(l, " / "))
items[900004] = { 0, 0, 1 }; ok("unlisted, no vendor: nothing", #tip(900004) == 0)
local id2 = f[4]; l = tip(id2); ok("uncached item: price only, no profit claim", #l == 1 and has(l, "AH price") and not has(l, "profit"), table.concat(l, " / "))
items[id2] = { 0, 0, 1 }; l = tip(id2); ok("no vendor value: profit is the whole amount after the cut", #l == 3 and l[1] == "Vendor price => none" and has(l, "AH profit  after 5% cut => +"), table.concat(l, " / "))
ok("non-number id ignored", pcall(tipcb, { AddDoubleLine = function() error("x") end }, { id = "a" }))
ok("nil data ignored", pcall(tipcb, {}, nil))
S.faction = "Horde"; ok("other faction never sees Alliance feed", #tip(id2) == 0); S.faction = "Alliance"
AHProfitDB.enabled = false; ok("off", #tip(id1) == 0); AHProfitDB.enabled = true

-- scanning
SlashCmdList.AHPROFIT("scan"); ok("no scan when closed", S.sent == 0 and chat[#chat]:find("open the auction house"))
S.pages = { {}, {} }
for i = 1, 150 do S.pages[1][i] = R(1000 + i, 100 + i, 2) end
for i = 151, 300 do S.pages[2][i - 150] = R(1000 + i, 100 + i, 2) end
S.pages[2][151] = R(1001, 50, 5)   -- duplicate key for an item already seen: keep lowest, add quantity
S.pages[2][152] = R(1002, 0, 1)    -- zero price ignored
local function runTimers() local due = timers; timers = {}; for _, fn in ipairs(due) do fn() end return #due end   -- only what was due; new timers wait
fire("AUCTION_HOUSE_SHOW"); ok("autoscan deferred", S.sent == 0 and #timers == 1); runTimers()
ok("query sent", S.sent == 1)
fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"); ok("an automatic scan leaves a gap before the next page", S.more == 0 and #timers == 1, S.more)
runTimers(); ok("asked for more", S.more == 1)
fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", S.pages[2])
local L = AHProfitDB.live["TestRealm|Alliance"]
ok("scan complete", L.full == S.time and chat[#chat]:find("300 items priced"), chat[#chat])
ok("dup keeps lowest and sums", L.p[1001] == 50 and L.q[1001] == 7)
ok("zero price not stored", L.p[1002] == 102)
ok("stale item pruned by full scan", L.p[id1] == nil)
items[id1] = { 500, 0, 1 }; l = tip(id1); ok("full scan overrides older feed", has(l, "none listed"), table.concat(l, " / "))
-- a narrow manual search must not wipe anything
S.pages = { { R(1005, 1, 1) } }; fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
ok("narrow search keeps the rest", L.p[1300] == 400 and L.p[1005] == 1)
-- throttle handling
fire("AUCTION_HOUSE_CLOSED"); L.full = 0; S.ready = false; S.sent = 0
fire("AUCTION_HOUSE_SHOW"); runTimers(); ok("waits for throttle", S.sent == 0)
S.ready = true; fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY"); ok("starts when ready", S.sent == 1)
fire("AUCTION_HOUSE_CLOSED"); S.sent = 0; L.full = S.time; fire("AUCTION_HOUSE_SHOW"); ok("no rescan within 15 min", S.sent == 0 and #timers == 0, #timers)
-- selling: the scan must not send anything while a Sell tab is showing or an item is on the cursor
do
    local sell = { shown = false, IsShown = function(self) return self.shown end }
    AuctionHouseFrame = { ItemSellFrame = sell, CommoditiesSellFrame = { IsShown = function() return false end } }
    local cursor
    function GetCursorInfo() return cursor end
    S.pages = { {}, {}, {} }
    for p = 1, 3 do for i = 1, 100 do S.pages[p][i] = R(2000 + p * 100 + i, 10 + i, 1) end end
    fire("AUCTION_HOUSE_CLOSED"); L.full = 0; S.sent, S.more = 0, 0
    sell.shown = true
    fire("AUCTION_HOUSE_SHOW"); runTimers()
    ok("no scan starts while the Sell tab is showing", S.sent == 0 and #timers == 1, S.sent)
    runTimers(); runTimers(); ok("it keeps waiting, sending nothing", S.sent == 0 and S.more == 0)
    sell.shown = false; runTimers()
    ok("it starts once the Sell tab is left", S.sent == 1)
    fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"); sell.shown = true; runTimers()
    ok("mid-scan, opening the Sell tab stops the requests", S.more == 0 and #timers == 1, S.more)
    for _ = 1, 30 do runTimers() end
    ok("nothing is sent however long the player sells", S.more == 0 and S.sent == 1)
    sell.shown = false; cursor = "item"; runTimers()
    ok("an item on the cursor holds the scan too", S.more == 0)
    cursor = nil; runTimers()
    ok("the scan goes on from where it stood", S.more == 1)
    fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", S.pages[2]); runTimers()
    fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", S.pages[3])
    ok("and finishes with every page", S.more == 2 and L.full == S.time and L.p[2301] == 11 and chat[#chat]:find("300 items priced"), chat[#chat])
    -- a scan asked for by hand runs at full speed, but still yields to selling
    fire("AUCTION_HOUSE_CLOSED"); fire("AUCTION_HOUSE_SHOW"); S.sent, S.more = 0, 0
    SlashCmdList.AHPROFIT("scan"); fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    ok("manual scan asks for the next page at once", S.sent == 1 and S.more == 1 and #timers == 0)
    sell.shown = true; fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", S.pages[2])
    ok("manual scan also stands still while selling", S.more == 1 and #timers == 1)
    SlashCmdList.AHPROFIT("scan stop"); sell.shown = false; runTimers()
    ok("scan stop ends it", S.more == 1 and chat[#chat - 0]:find("scan stopped", 1, true), chat[#chat])
    fire("AUCTION_HOUSE_CLOSED"); AuctionHouseFrame, GetCursorInfo = nil, nil
end
SlashCmdList.AHPROFIT("cut 15"); ok("slash cut", AHProfitDB.cut == 15); SlashCmdList.AHPROFIT("cut 99"); ok("bad cut ignored", AHProfitDB.cut == 15)
SlashCmdList.AHPROFIT(""); ok("status prints", chat[#chat]:find("/ahp farm | scan", 1, true))
-- ---- PR-B: daily history of your own scans (AHProfitDB.hist), Auctionator's day rules
do
    local hasHist = type(ns.histOwn) == "function" and type(ns.scanDay) == "function"
    ok("history: saved data version 3 with a history table", AHProfitDB.v == 3 and type(AHProfitDB.hist) == "table", tostring(AHProfitDB.v))
    ok("history: scan day = whole UTC days since 2020-01-01", hasHist and ns.scanDay(1577836800) == 0 and ns.scanDay(1577836800 + 86399) == 0 and ns.scanDay(1577836800 + 86400) == 1 and ns.scanDay(1794385517) == 2506)
    local own = function(id) return hasHist and ns.histOwn(id) or {} end
    local function query(rows) S.pages = { rows }; fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED") end
    fire("AUCTION_HOUSE_CLOSED"); fire("AUCTION_HOUSE_SHOW"); timers = {}
    local day = hasHist and ns.scanDay(S.time) or 0
    query({ R(7001, 300, 4), R(7001, 200, 3), R(7002, 50, 1) })   -- one search: 7001 at two item levels
    fire("AUCTION_HOUSE_CLOSED")
    local h = own(7001)
    ok("history: a search is recorded once it ends, with its lowest price and total listed", #h == 1 and h[1].d == day and h[1].p == 200 and h[1].l == 200 and h[1].a == 7, h[1] and (h[1].p .. " " .. h[1].a))
    local HH = (AHProfitDB.hist or {})["TestRealm|Alliance"]
    local d7001 = HH and HH[7001] and ns.histDecode(HH[7001], day)
    ok("history: saved as one string per item", type(HH and HH[7001]) == "string", type(HH and HH[7001]))
    ok("history: a lone price has no separate low", d7001 and #d7001 == 1 and d7001[1][3] == 0)
    fire("AUCTION_HOUSE_SHOW"); timers = {}
    query({ R(7001, 250, 2) }); query({ R(7001, 260, 9) }); query({ R(7001, 180, 1) }); fire("AUCTION_HOUSE_CLOSED")
    h = own(7001)
    local e = (AHProfitDB.hist or {})["TestRealm|Alliance"]; e = e and e[7001] and ns.histDecode(e[7001], day)
    ok("history: same day keeps the highest low, the lowest low and the most listed", #h == 1 and h[1].p == 260 and h[1].l == 180 and h[1].a == 9 and e and e[1][3] == 180, h[1] and (h[1].p .. "/" .. h[1].l .. "/" .. h[1].a))
    S.time = S.time + 86400
    fire("AUCTION_HOUSE_SHOW"); timers = {}; query({ R(7001, 100, 2) }); fire("AUCTION_HOUSE_CLOSED")
    h = own(7001)
    ok("history: a new day starts a new entry", #h == 2 and h[2].d == day + 1 and h[2].p == 100 and h[1].p == 260)
    -- a full scan records too, before it forgets unlisted items
    fire("AUCTION_HOUSE_SHOW"); timers = {}
    S.pages = { {} }; for i = 1, 700 do S.pages[1][i] = R(7100 + i, 1000 + i, 1) end
    SlashCmdList.AHPROFIT("scan"); fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    local function recorded() local n = 0; for i = 7101, 7800 do if #own(i) == 1 then n = n + 1 end end return n end
    ok("history: a big scan is written over several frames, 400 items per frame", recorded() == 400 and #timers == 1, recorded())
    local frames = 0
    while #timers > 0 and frames < 10 do runTimers(); frames = frames + 1 end
    ok("history: a full scan records every item", recorded() == 700 and frames == 1 and own(7350)[1].p == 1250 and AHProfitDB.live["TestRealm|Alliance"].full == S.time, recorded() .. " in " .. frames)
    -- logout or /reload in the middle: everything still waiting is written before the game saves
    S.time = S.time + 1
    for i = 1, 700 do S.pages[1][i] = R(7100 + i, 2000 + i, 1) end
    SlashCmdList.AHPROFIT("scan"); fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    timers = {}                                                  -- the next frame never comes
    fire("PLAYER_LOGOUT")
    ok("history: logout writes everything still waiting", own(7800)[1] and own(7800)[1].p == 2700 and own(7101)[1].p == 2001, tostring(own(7800)[1] and own(7800)[1].p) .. " " .. tostring(own(7101)[1] and own(7101)[1].p) .. " n=" .. #own(7101))
    ok("history: items missing from the full scan keep their history", #own(7001) == 2 and AHProfitDB.live["TestRealm|Alliance"].p[7001] == nil)
    fire("AUCTION_HOUSE_CLOSED")
    -- encoding: round trip, and a corrupt string is dropped and started over on the next write
    do
        local enc, dec = ns.histEncode, ns.histDecode
        local list = { { 2490, 1, 0, 0 }, { 2491, 31, 30, 32 }, { 2495, 1e12, 999999999999, 1e9 }, { 2506, 33, 0, 7 } }
        local back = dec(enc(list), 2506)
        local same = back and #back == #list
        for i = 1, #list do for k = 1, 4 do if not (same and back[i][k] == list[i][k]) then same = false end end end
        ok("history: encoding round trip, including 0, 31/32 digit edges and the 1e12 price cap", same and #enc(list) < 60, enc(list))
        local Hh = AHProfitDB.hist["TestRealm|Alliance"]
        Hh[7001] = "ZZ!"
        ok("history: a corrupt string reads as no history", #own(7001) == 0)
        fire("AUCTION_HOUSE_SHOW"); timers = {}; query({ R(7001, 120, 3) }); fire("AUCTION_HOUSE_CLOSED")
        h = own(7001)
        ok("history: ...and the next write starts it over", #h == 1 and h[1].p == 120 and h[1].a == 3 and h[1].d == day + 1, #h)
        Hh[7001] = enc({ { day, 260, 180, 9 }, { day + 1, 100, 0, 2 } })     -- back to what the checks below expect
    end
    -- 21 days kept: older days drop out when the item is written again
    S.time = S.time + 20 * 86400
    fire("AUCTION_HOUSE_SHOW"); timers = {}; query({ R(7001, 90, 1) }); fire("AUCTION_HOUSE_CLOSED")
    h = own(7001)
    ok("history: days older than 21 are pruned", #h == 2 and h[1].d == day + 1 and h[2].d == day + 21, #h)
    -- item cap
    local cap = ns.HIST_ITEMS
    local H = (AHProfitDB.hist or {})["TestRealm|Alliance"]
    local ids = {}; for id in pairs(H or {}) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do own(id) end                      -- reading gives back the places of expired items
    local n0 = 0; for _ in pairs(H or {}) do n0 = n0 + 1 end
    ns.HIST_ITEMS = n0 + 1
    fire("AUCTION_HOUSE_SHOW"); timers = {}; query({ R(9601, 5, 1), R(9602, 5, 1), R(7001, 80, 1) }); fire("AUCTION_HOUSE_CLOSED")
    local n1 = 0; for _ in pairs(H or {}) do n1 = n1 + 1 end
    ok("history: item cap stops new items, known items still update", cap == 10000 and n1 == n0 + 1 and own(7001)[2] and own(7001)[2].l == 80, n1 - n0)
    ns.HIST_ITEMS = cap
    -- guild-received prices never enter the history (only browse results do)
    AHProfitDB.live["TestRealm|Alliance"].p[7999] = 5
    fire("AUCTION_HOUSE_SHOW"); timers = {}; fire("AUCTION_HOUSE_CLOSED")
    ok("history: prices not from your own browsing are not recorded", #own(7999) == 0)
end
-- ---- review round 2 (PR-B): the write queue loses nothing, survives errors, keeps house and day; expired items
-- give their place back
do
    local T0 = S.time
    local function boot(saved) AHProfitDB = saved; ns = {}; load("Data.lua"); load("Core.lua"); fire("ADDON_LOADED", "AHProfit"); AHProfitDB.autoscan = false; timers = {}; return AHProfitDB end
    local key = "TestRealm|Alliance"
    local function nHist(k) local n = 0; for _ in pairs((AHProfitDB.hist or {})[k or key] or {}) do n = n + 1 end return n end
    local function fullScan(n, base, price)
        fire("AUCTION_HOUSE_SHOW"); timers = {}
        S.pages = { {} }; for i = 1, n do S.pages[1][i] = R(base + i, price + i, 1) end
        SlashCmdList.AHPROFIT("scan"); fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    end
    local function drain() local f = 0; while #timers > 0 and f < 200 do runTimers(); f = f + 1 end return f end
    for _, n in ipairs({ 401, 1000, 5800, 10000 }) do
        boot({})
        fullScan(n, 100000, 100)
        drain()
        ok("history queue: a full scan of " .. n .. " items records every one", nHist() == n, nHist())
        fire("AUCTION_HOUSE_CLOSED")
    end
    -- an error on one row skips that row only; the queue does not stick and logout still writes
    boot({})
    AHProfitDB.hist[key] = setmetatable({}, { __newindex = function(t, k, v) if k == 200500 then error("boom") end rawset(t, k, v) end })
    local ok1 = pcall(fullScan, 1000, 200000, 100)
    local ok2 = pcall(drain)
    ok("history queue: an error on one row does not stop the rest", ok1 and ok2 and nHist() == 999, nHist())
    fire("AUCTION_HOUSE_CLOSED")
    pcall(fullScan, 50, 300000, 100); pcall(drain); fire("AUCTION_HOUSE_CLOSED")
    ok("history queue: ...and is not left busy (the next scan is written)", nHist() == 1049, nHist())
    pcall(fullScan, 1000, 200000, 500)
    timers = {}                                                  -- logout before the next frame
    local ok3 = pcall(fire, "PLAYER_LOGOUT")
    local Hk = AHProfitDB.hist[key]
    local h1 = ns.histOwn(201000)
    ok("history queue: logout with a failing row still writes the rest, without an error", ok3 and h1[1] and h1[1].p == 1500, ok3 and h1[1] and h1[1].p)
    fire("AUCTION_HOUSE_CLOSED")
    -- rows go to the house they were scanned on, even if the house changes before they are written
    boot({})
    fullScan(1000, 400000, 100)                                  -- 400 written, 600 waiting
    fire("AUCTION_HOUSE_CLOSED")
    S.realm = "OtherRealm"
    drain()
    S.realm = "TestRealm"
    ok("history queue: waiting rows go to the house they were scanned on", nHist() == 1000 and nHist("OtherRealm|Alliance") == 0, nHist() .. " " .. nHist("OtherRealm|Alliance"))
    -- a query seen before midnight counts for that day even if written after it
    boot({})
    local mid = 1577836800 + (ns.scanDay(S.time) + 1) * 86400
    S.time = mid - 5
    fire("AUCTION_HOUSE_SHOW"); timers = {}
    S.pages = { { R(500001, 77, 1) } }
    fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    S.time = mid + 5
    fire("AUCTION_HOUSE_CLOSED")
    local hm = ns.histOwn(500001)
    ok("history: a query seen before midnight counts for that day", hm[1] and hm[1].d == ns.scanDay(mid - 5), hm[1] and hm[1].d)
    S.time = T0
    -- at the item cap, items whose days have all expired give their place to new ones
    local today = ns.scanDay(S.time)
    local enc = ns.histEncode
    local old = {}
    for i = 1, 10000 do old[600000 + i] = enc({ { today - 30, 5, 0, 1 } }) end
    boot({ v = 2, hist = { [key] = old } })
    fire("AUCTION_HOUSE_SHOW"); timers = {}
    S.pages = { { R(700001, 9, 1), R(700002, 9, 1) } }
    fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"); fire("AUCTION_HOUSE_CLOSED"); drain()
    ok("history: at the cap, expired items give their place to new ones", #ns.histOwn(700001) == 1 and #ns.histOwn(700002) == 1 and nHist() <= 10000, nHist())
    -- ...but items with a recent day keep theirs
    local fresh = {}
    for i = 1, 10000 do fresh[800000 + i] = enc({ { today - 1, 5, 0, 1 } }) end
    boot({ v = 2, hist = { [key] = fresh } })
    fire("AUCTION_HOUSE_SHOW"); timers = {}
    S.pages = { { R(900001, 9, 1) } }
    fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"); fire("AUCTION_HOUSE_CLOSED"); drain()
    ok("history: at the cap, items with recent days keep their place", #ns.histOwn(900001) == 0 and nHist() == 10000, nHist())
    -- the logout flush also gives back places of expired items, a bounded number at a time
    boot({ v = 2, hist = { [key] = (function() local t = {}; for i = 1, 3000 do t[600000 + i] = enc({ { today - 30, 5, 0, 1 } }) end; return t end)() } })
    fire("PLAYER_LOGOUT")
    ok("history: logout frees expired items, at most 1,000 looked at", nHist() == 2000, nHist())
end

-- ---- review round 3 (PR-B): at the cap rows wait for the sweep; a future-dated string is kept; rows checked
do
    local T0 = S.time
    local function boot(saved) AHProfitDB = saved; ns = {}; load("Data.lua"); load("Core.lua"); fire("ADDON_LOADED", "AHProfit"); AHProfitDB.autoscan = false; timers = {}; return AHProfitDB end
    local key = "TestRealm|Alliance"
    local function nHist() local n = 0; for _ in pairs((AHProfitDB.hist or {})[key] or {}) do n = n + 1 end return n end
    local function fullScan(n, base, price)
        fire("AUCTION_HOUSE_SHOW"); timers = {}
        S.pages = { {} }; for i = 1, n do S.pages[1][i] = R(base + i, price + i, 1) end
        SlashCmdList.AHPROFIT("scan"); fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    end
    local function drain() local f = 0; while #timers > 0 and f < 2000 do runTimers(); f = f + 1 end return f end
    -- the reviewer's case: 10,000 scanned, 21 days pass, 5,000 rescanned, 1,000 new
    boot({})
    fullScan(10000, 100000, 100); drain(); fire("AUCTION_HOUSE_CLOSED")
    S.time = S.time + 21 * 86400
    fullScan(5000, 100000, 200); drain(); fire("AUCTION_HOUSE_CLOSED")
    fullScan(1000, 200000, 300); local frames = drain(); fire("AUCTION_HOUSE_CLOSED")
    local H = AHProfitDB.hist[key]
    local got, live = 0, 0
    for id = 200001, 201000 do if H[id] then got = got + 1 end end
    for id = 100001, 105000 do if H[id] then live = live + 1 end end
    ok("history cap: after 21 days, 1,000 new items all find a place freed by expired ones", got == 1000 and live == 5000 and nHist() <= 10000 and frames < 2000, got .. " " .. live .. " " .. nHist())
    -- a house that is really full (every item recent): the new row is dropped and the queue ends
    boot({})
    fullScan(10000, 100000, 100); drain(); fire("AUCTION_HOUSE_CLOSED")
    fullScan(1, 300000, 100); frames = drain(); fire("AUCTION_HOUSE_CLOSED")
    ok("history cap: a house full of recent items drops the new row and stops", #ns.histOwn(300001) == 0 and nHist() == 10000 and #timers == 0 and frames < 200, frames)
    -- one expired item among 9,999 recent ones: a single new item gets its place in the same scan
    do
        local today0 = ns.scanDay(S.time)
        local t = {}
        for i = 1, 10000 do t[100000 + i] = ns.histEncode({ { i == 10000 and today0 - 30 or today0, 5, 0, 1 } }) end
        boot({ v = 2, hist = { [key] = t } })
        fullScan(1, 600000, 100); frames = drain(); fire("AUCTION_HOUSE_CLOSED")
        ok("history cap: the one expired item among 9,999 gives its place in the same scan", #ns.histOwn(600001) == 1 and AHProfitDB.hist[key][110000] == nil and nHist() == 10000, frames)
    end
    S.time = T0
    -- a string dated after today (the server clock went back) is unreadable for now, never deleted
    boot({})
    local today = ns.scanDay(S.time)
    local Hf = ns.histHouse()
    Hf[42] = ns.histEncode({ { today - 2, 5, 0, 1 }, { today + 1, 6, 0, 1 } })
    local saved = Hf[42]
    local r1 = ns.histOwn(42)
    fire("PLAYER_LOGOUT")                                        -- the logout sweep looks at it too
    ok("history: a string dated after today reads as nothing but stays on disk", #r1 == 0 and Hf[42] == saved)
    S.time = S.time + 86400
    local r2 = ns.histOwn(42)
    ok("history: ...and reads again once the clock is past it", #r2 == 2, #r2)
    S.time = T0
    -- a queued row with a bad field takes no place
    boot({})
    local cap = ns.HIST_ITEMS
    ns.HIST_ITEMS = 1000
    local function up(f, name) for i = 1, 200 do local k, v = debug.getupvalue(f, i); if k == nil then break end; if k == name then return v end end end
    local stepF = up(ns.histFinish, "histStep") or up(up(ns.histFinish, "flushHist") or function() end, "histStep")
    fullScan(1000, 400000, 100)                                  -- 400 written, 600 waiting
    local q, qh = up(stepF, "queue"), up(stepF, "qh") or up(stepF, "qi")
    if q and qh and q[qh + 10] then q[qh + 10][2] = nil end      -- one waiting row loses its price
    drain(); fire("AUCTION_HOUSE_CLOSED")
    fullScan(1, 500000, 100); drain(); fire("AUCTION_HOUSE_CLOSED")
    ok("history: a row with a bad field takes no place in the cap", nHist() == 1000 and #ns.histOwn(500001) == 1, nHist())
    ns.HIST_ITEMS = cap
end

-- ---- saved history checked at load
do
    local function boot(saved)
        AHProfitDB = saved
        local n3 = {}
        ns = n3
        load("Data.lua"); load("Core.lua"); fire("ADDON_LOADED", "AHProfit")
        return AHProfitDB, n3
    end
    local today = math.floor((S.time - 1577836800) / 86400)
    local db1 = boot({ v = 1, shared = { ["TestRealm|Alliance"] = { p = { [5] = 9 }, q = { [5] = 1 }, t = { [5] = S.time }, full = 0, from = {} } } })
    ok("load: a version 1 save gets a history table and keeps its guild prices", db1.v == 3 and type(db1.hist) == "table" and db1.shared and db1.shared["TestRealm|Alliance"].p[5] == 9)
    -- a separate encoder, so these strings do not come from the code under test
    local A = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+/"
    local function digits(v) local o = {}; while v >= 32 do local d = v % 32; o[#o + 1] = A:sub(d + 33, d + 33); v = (v - d) / 32 end o[#o + 1] = A:sub(v + 1, v + 1); return table.concat(o) end
    local function enc(list) local o, prev = {}, 0; for _, e in ipairs(list) do o[#o + 1] = digits(e[1] - prev) .. digits(e[2]) .. digits(e[3]) .. digits(e[4]); prev = e[1] end return table.concat(o) end
    local db2 = boot({ v = 2, hist = { ["TestRealm|Alliance"] = {
        [10] = enc({ { today - 30, 5, 0, 1 }, { today - 1, 90, 80, 4 }, { today, 100, 0, 2 } }),
        [11] = enc({ { today - 40, 1, 0, 1 } }), [12] = "bad", [14] = enc({ { today + 3, 7, 0, 1 } }), [15] = enc({ { today, 50, 60, 1 } }),
        [16] = string.rep("1", 2000), [17] = { h = {} }, ["13"] = enc({ { today, 1, 0, 1 } }) }, [7] = {} } })
    local e = (db2.hist or {})["TestRealm|Alliance"]
    local h10 = ns.histOwn(10)
    ok("load: a stored string decodes, days older than 21 are dropped", #h10 == 2 and h10[1].d == today - 1 and h10[1].p == 90 and h10[1].l == 80 and h10[1].a == 4 and h10[2].p == 100 and h10[2].l == 100, #h10)
    ok("load: wrong types, string keys and over-long strings are dropped at load", e and e[16] == nil and e[17] == nil and e["13"] == nil and (db2.hist or {})[7] == nil)
    ok("load: strings are not decoded at load (checked when read)", e and e[12] == "bad" and e[14] ~= nil)
    ok("load: corrupt, future-day and low-above-high strings read as no history", #ns.histOwn(12) == 0 and #ns.histOwn(14) == 0 and #ns.histOwn(15) == 0 and #ns.histOwn(11) == 0)
    local many = { v = 2, hist = {} }
    for i = 1, 10 do many.hist["R" .. i .. "|Alliance"] = { [1] = enc({ { today - 10 + i, 5, 0, 1 } }) } end
    local db3 = boot(many)
    local nh = 0; for _ in pairs(db3.hist or {}) do nh = nh + 1 end
    ok("load: at most 8 houses, the most recently scanned kept", nh == 8 and db3.hist["R10|Alliance"] and db3.hist["R1|Alliance"] == nil, nh)
    local db4 = boot({ v = 4, hist = { x = 1 }, ledger = { y = 2 } })
    ok("load: a save from a newer version is left alone", db4.v == 4 and db4.hist and db4.hist.x == 1 and db4.ledger.y == 2 and db4.sessions == nil)
end
print(("%d passed, %d failed"):format(pass, fail)); os.exit(fail == 0 and 0 or 1)
