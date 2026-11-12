-- Money ledger, session archive and item cache (saved-data version 3). Run: lua test/ledger_test.lua
local W = { time = 1794400000, money = 0, name = "Abdullah", realm = "Realm", faction = "Alliance", level = 30, map = 1429,
    zone = "Elwynn Forest", secret = {}, repairMode = false, invoice = {}, asked = 0 }
local items = { [2589] = { "Linen Cloth", 13 }, [2592] = { "Wool Cloth", 33 }, [2770] = { "Copper Ore", 5 }, [2840] = { "Copper Bar", 10 } }
local handlers, chat, timers = {}, {}, {}
function issecretvalue(v) return W.secret[v] == true end
function GetServerTime() return W.time end
time = GetServerTime
date = os.date
function GetRealmName() return W.realm end
function UnitName() return W.name end
function UnitFactionGroup() return W.faction, W.faction end
function UnitLevel() return W.level end
function GetMoney() return W.money end
function GetZoneText() return W.zone end
function InRepairMode() return W.repairMode end
function RepairAllItems() end
function TakeTaxiNode() end
function TakeInboxMoney() end
function AutoLootMailItem() end
function GetInboxInvoiceInfo(i) return W.invoice[i] end
function hooksecurefunc(name, fn) local old = _G[name]; _G[name] = function(...) old(...); fn(...) end end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) chat[#chat + 1] = m end }
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
C_Map = { GetBestMapForUnit = function(u) assert(u == "player"); return W.map end }
C_Item = { GetItemInfo = function(id) local i = items[id]; if not i then return nil end
        return i[1], "l", 1, 1, 1, "t", "st", 20, "", 1, i[2], 7, 0, 0 end,
    GetItemCount = function() return 0 end,
    RequestLoadItemDataByID = function() W.asked = W.asked + 1 end }
local registered = {}
local frame = { Hide = function() end, SetScript = function(self, _, fn) handlers[self] = fn end }
function frame.RegisterEvent(self, e)
    if e:find("^NOT_IN_THIS_CLIENT") then error("unknown event " .. e) end
    registered[e] = true
end
function CreateFrame() local f = {}; for k, v in pairs(frame) do f[k] = v end; return f end
SlashCmdList = {}
local ns
local pass, fail = 0, 0
local function ok(name, cond, extra) if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. " " .. tostring(extra or "")) end end
local function fire(ev, ...) for f, fn in pairs(handlers) do fn(f, ev, ...) end end
local function boot(saved)
    AHProfitDB = saved; ns = {}; handlers = {}
    for _, f in ipairs({ "Data.lua", "Core.lua", "Tools.lua" }) do assert(loadfile("AHProfit/" .. f))("AHProfit", ns) end
    fire("ADDON_LOADED", "AHProfit")
    fire("PLAYER_ENTERING_WORLD")
    return AHProfitDB
end
local function money(d) W.money = W.money + d; fire("PLAYER_MONEY") end
local function today() return ns.scanDay(W.time) end
local function L(who, day) local C = AHProfitDB.ledger[who or "Abdullah-Realm"]; return C and C[day or today()] or {} end
local function io2(src, who, day) local e = L(who, day)[src]; return e and e[1] or 0, e and e[2] or 0 end

-- ---- version 3 tables appear; an old save keeps its data
local db = boot({ v = 2, live = { ["Realm|Alliance"] = { p = { [9] = 5 }, q = {}, t = { [9] = W.time }, full = 0 } }, hist = {} })
ok("load: a version 2 save becomes version 3 with empty ledger, sessions and items", db.v == 3 and next(db.ledger) == nil
    and #db.sessions == 0 and next(db.items) == nil and db.live["Realm|Alliance"].p[9] == 5)
ok("load: the new events are registered", registered.TRAINER_SHOW and registered.TAXIMAP_OPENED and registered.QUEST_TURNED_IN)

-- ---- each source
W.money = 100000; boot({}); fire("PLAYER_ENTERING_WORLD")
money(500)
ok("ledger: money with no window open is loot", select(1, io2("loot")) == 500)
fire("MERCHANT_SHOW"); money(1200); money(-300)
ok("ledger: at a vendor, a sale and a purchase", io2("vendor") == 1200 and select(2, io2("vendor")) == 300)
W.repairMode = true; money(-450); W.repairMode = false
RepairAllItems(); money(-1000)
ok("ledger: repairs by cursor and by Repair All", select(2, io2("repair")) == 1450 and select(2, io2("vendor")) == 300)
W.time = W.time + 5; money(-20)
ok("ledger: a while after Repair All, spending at the vendor is vendor again", select(2, io2("vendor")) == 320)
fire("MERCHANT_CLOSED"); money(70)
ok("ledger: money a moment after the window closed still goes to it", io2("vendor") == 1270)
W.time = W.time + 5; money(30)
ok("ledger: later it is loot", io2("loot") == 530)
fire("AUCTION_HOUSE_SHOW"); money(-5000); money(-60); fire("AUCTION_HOUSE_CLOSED")
ok("ledger: auction house buyouts and deposits", select(2, io2("ah")) == 5060)
W.time = W.time + 5
fire("MAIL_SHOW")
W.invoice[1] = "seller"; TakeInboxMoney(1); money(9500)
W.invoice[2] = nil; TakeInboxMoney(2); money(100)
money(-30)
fire("MAIL_CLOSED")
ok("ledger: money from an auction invoice is ah, other mail money is mail", io2("ah") == 9500 and io2("mail") == 100 and select(2, io2("mail")) == 30)
W.time = W.time + 5
fire("TRAINER_SHOW"); money(-900); fire("TRAINER_CLOSED")
W.time = W.time + 5
fire("TAXIMAP_OPENED"); TakeTaxiNode(3); fire("TAXIMAP_CLOSED"); W.time = W.time + 1; money(-80)
W.time = W.time + 5
fire("TRADE_SHOW"); money(2000); fire("TRADE_CLOSED")
W.time = W.time + 5
fire("QUEST_COMPLETE"); fire("QUEST_FINISHED"); fire("QUEST_TURNED_IN", 1, 100, 350); W.time = W.time + 1; money(350)
W.time = W.time + 5
fire("QUEST_FINISHED"); money(40)
ok("ledger: trainer, taxi, trade and quest", select(2, io2("trainer")) == 900 and select(2, io2("taxi")) == 80 and io2("trade") == 2000
    and io2("quest") == 350 and io2("loot") == 570)
W.time = W.time + 5; money(-15)
ok("ledger: money going out with no window is other", select(2, io2("other")) == 15)
local total = 0
for _, e in pairs(L()) do total = total + e[1] - e[2] end
ok("ledger: the sources add up to the change of the money counter", total == W.money - 100000, total)

-- ---- secret and non-number money is ignored, the next real value is measured from the last good one
local before = W.money
W.money = { 1 }; fire("PLAYER_MONEY")
local sv = 123456; W.secret[sv] = true; local keep = W.money; W.money = sv; fire("PLAYER_MONEY"); W.money = before; W.secret[sv] = nil
money(5)
ok("ledger: secret or odd money values are ignored", io2("loot") == 575, io2("loot"))

-- ---- two characters, day rollover
local d0 = today()
W.name = "Ahmed"; fire("PLAYER_ENTERING_WORLD"); money(10)
ok("ledger: a second character has its own ledger, from its own first value", io2("loot", "Ahmed-Realm") == 10 and io2("loot") == 575)
W.time = (d0 + 1) * 86400 + 1577836800 + 10; money(7)
ok("ledger: after midnight (UTC) money goes to the next day", io2("loot", "Ahmed-Realm", d0 + 1) == 7 and io2("loot", "Ahmed-Realm", d0) == 10)
W.name = "Abdullah"; fire("PLAYER_ENTERING_WORLD")

-- ---- pruning: 180 days, 50 characters, at load and when a day starts
db = AHProfitDB
db.ledger["Abdullah-Realm"][today() - 180] = { loot = { 1, 0 } }
db.ledger["Abdullah-Realm"][today() - 179] = { loot = { 2, 0 } }
for i = 1, 55 do db.ledger["Alt" .. i .. "-Realm"] = { [today() - i] = { loot = { i, 0 } } } end
db.ledger["Bad"] = { [today()] = { loot = { -1, 0 }, nope = { 1, 0 } } }
db.ledger[7] = {}
W.money = 100000
db = boot(db)
local n = 0; for _ in pairs(db.ledger) do n = n + 1 end
ok("ledger: at load, days older than 180 are dropped, the newest day kept", db.ledger["Abdullah-Realm"][today() - 180] == nil and db.ledger["Abdullah-Realm"][today() - 179] ~= nil)
ok("ledger: at load, at most 50 characters (the least recent dropped), bad entries dropped", n == 50 and db.ledger["Alt55-Realm"] == nil
    and db.ledger["Alt1-Realm"] ~= nil and db.ledger.Bad == nil and db.ledger[7] == nil, n)
W.time = W.time + 86400 * 2; db.ledger["Abdullah-Realm"][today() - 180] = { loot = { 1, 0 } }; money(1)
ok("ledger: a new day prunes that character's old days", db.ledger["Abdullah-Realm"][today() - 180] == nil and io2("loot") == 1)
W.name = "Newcomer"; fire("PLAYER_ENTERING_WORLD"); money(3)
n = 0; for _ in pairs(db.ledger) do n = n + 1 end
ok("ledger: a new character past 50 drops the least recent one, never itself", n == 50 and io2("loot", "Newcomer-Realm") == 3, n)
W.name = "Abdullah"; fire("PLAYER_ENTERING_WORLD")

-- ---- a save from a newer version is not written
W.money = 100000
db = boot({ v = 4, ledger = { x = 1 } })
money(50); ns.tools.noteItems({ 2589 })
ok("ledger: a save from a newer version gets no ledger, session or item writes", db.v == 4 and db.ledger.x == 1 and db.items == nil and db.sessions == nil)

-- ---- session archive
W.money = 100000
db = boot({})
W.map, W.zone = 1429, "Elwynn Forest"
ns.tools.sessionStart()
W.map, W.zone = 1436, "Westfall"
money(400); fire("MERCHANT_SHOW"); money(1000); money(-200); fire("MERCHANT_CLOSED")
local S = db.session
S.net = { [2589] = 12, [2770] = -3 }; S.nodes = 4
W.time = W.time + 1800
ok("session: stopping archives it", ns.tools.sessionStop() and #db.sessions == 1)
local A = db.sessions[1]
ok("session: who, where it started, when", A.char == "Abdullah" and A.realm == "Realm" and A.faction == "Alliance" and A.level == 30
    and A.map == 1429 and A.zone == "Elwynn Forest" and A.stop - A.start == 1800 and A.dur == 1800)
ok("session: coin by source and nodes", A.inc.loot == 400 and A.inc.vendor == 1000 and A.out.vendor == 200 and A.nodes == 4)
ok("session: items gained and used", #A.items == 2 and A.items[1][1] == 2589 and A.items[1][2] == 12 and A.items[2][2] == -3)
ok("session: its items are named in the item cache", db.items[2589] and db.items[2589][1] == "Linen Cloth" and db.items[2589][2] == 13)
ok("session: stopping twice archives once", not ns.tools.sessionStop() and #db.sessions == 1)
for i = 1, 105 do ns.tools.sessionStart(); W.time = W.time + 60; ns.tools.sessionStop() end
ok("session: at most 100 kept, the oldest dropped", #db.sessions == 100 and db.sessions[1].start > A.start)
local big = {}; for i = 1, 40 do big[100000 + i] = i end
ns.tools.sessionStart(); db.session.net = big; ns.tools.sessionStop()
local last = db.sessions[#db.sessions]
ok("session: the 30 largest item changes kept", #last.items == 30 and last.items[1][2] == 40 and last.items[30][2] == 11)
-- archived sessions checked at load
db.sessions[1] = { start = "x" }; db.sessions[2].inc = { loot = -5, vendor = 3 }
db = boot(db)
ok("session: a damaged archived session is dropped at load, negative coin removed", #db.sessions == 99 and db.sessions[1].inc.loot == nil
    and db.sessions[1].inc.vendor == 3)

-- ---- item cache
db = boot({})
ns.tools.noteItems({ 2589, 2592, 99999, -1, "x" })
ok("items: loaded items stored with name, vendor price and time; unknown ones asked for", db.items[2589][1] == "Linen Cloth"
    and db.items[2592][2] == 33 and db.items[99999] == nil and W.asked >= 1 and db.items[-1] == nil)
items[99999] = { "Late Item", 7 }
fire("PLAYER_LOGOUT")
ok("items: an item that was not loaded is stored when tried again at logout", db.items[99999] and db.items[99999][1] == "Late Item")
items[5555] = { "Secret Thing", 1 }; W.secret["Secret Thing"] = true
items[5556] = { "No Price", nil }
ns.tools.noteItems({ 5555, 5556 })
ok("items: secret names and missing prices are never stored", db.items[5555] == nil and db.items[5556] == nil)
-- the cap: 5,000, the least recently seen dropped
for i = 1, 5000 do db.items[200000 + i] = { "x" .. i, 1, W.time - 100000 + i } end
items[300001] = { "Newest", 2 }
ns.tools.noteItems({ 300001 })
local c = 0; for _ in pairs(db.items) do c = c + 1 end
ok("items: at most 5,000, the least recently seen dropped", c == 5000 and db.items[300001] and db.items[200001] == nil and db.items[200004] == nil
    and db.items[200005] ~= nil and db.items[2589] ~= nil, c)
db.items[200500] = { 5, 1, 1 }; db.items.k = { "a", 1, 1 }; db.items[200501] = { "y", -1, 1 }
db = boot(db)
ok("items: bad entries dropped at load", db.items[200500] == nil and db.items.k == nil and db.items[200501] == nil and db.items[300001] ~= nil)
-- bank and auctions on logout
db.bank = { ["Abdullah-Realm"] = { t = 1, items = { { 2840, 5, 0 } } } }
db.auc = { own = { ["Abdullah-Realm"] = { t = 1, list = { { 2770, 20, 100, 0 } } } } }
fire("PLAYER_LOGOUT")
ok("items: the bank and auction items of this character are named at logout", db.items[2840] and db.items[2770] and db.items[2770][1] == "Copper Ore")

for _, m in ipairs(chat) do if m:find("rror") then ok("no error in chat: " .. m, false) end end
print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
