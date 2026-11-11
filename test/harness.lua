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

-- feed fallback, newer feed beats older scan
AHProfitDB.live["TestRealm|Alliance"].t[id1] = ns.seed.t - 10
l = tip(id1); ok("newer feed beats older scan", has(l, "AH price  feed 10m ago"), table.concat(l, " / "))
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
print(("%d passed, %d failed"):format(pass, fail)); os.exit(fail == 0 and 0 or 1)
