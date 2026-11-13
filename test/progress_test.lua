-- Scan progress window and scan failure reasons (PR-H), against a mock client.
--   lua test/progress_test.lua     (from the project directory)
local W = { time = 1794400000, timers = {}, order = 0, log = {}, frames = {}, created = {}, ready = true, selling = false }
local chat = {}
local handlers = {}
function issecretvalue() return false end
function GetServerTime() return math.floor(W.time) end
time = GetServerTime
function GetTime() return W.time end
function GetRealmName() return "Realm" end
function UnitFactionGroup() return "Alliance" end
function UnitName() return "Probe" end
function UnitFullName() return "Probe", "Realm" end
function IsInGuild() return W.guild ~= false end
function GetCursorInfo() return nil end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) chat[#chat + 1] = m end }
C_Timer = { After = function(d, fn) W.order = W.order + 1; W.timers[#W.timers + 1] = { due = W.time + d, fn = fn, o = W.order } end }
C_Item = { GetItemInfo = function() return nil end, GetItemCount = function() return 0 end }
Enum = { TooltipDataType = { Item = 0 }, AuctionHouseSortOrder = { Price = 0 } }
TooltipDataProcessor = { AddTooltipPostCall = function() end }
SlashCmdList = {}
C_ChatInfo = { InChatMessagingLockdown = function() return false end, RegisterAddonMessagePrefix = function() return 0 end,
    SendAddonMessage = function(_, msg) W.log[#W.log + 1] = msg; return 0 end }
AuctionHouseFrame = { ItemSellFrame = { IsShown = function() return W.selling end } }
function hooksecurefunc(t, name, fn)                             -- post-hook, as the client does it
    local orig = t[name]
    t[name] = function(...) local r = { orig(...) }; fn(...); return unpack(r) end
end

-- ---- frames: just enough to see what is shown, where and with which text
local function stub() return function() end end
local function newObj(kind)
    local o = { kind = kind, shown = true, points = {}, scripts = {}, events = {}, alpha = 1, min = 0, max = 1, value = 0 }
    local m = {}
    function m.Show(self) self.shown = true end
    function m.Hide(self) self.shown = false end
    function m.IsShown(self) return self.shown end
    function m.SetPoint(self, p, rel, rp, x, y) self.points[#self.points + 1] = { p, rel, rp, x, y } end
    function m.ClearAllPoints(self) self.points = {} end
    function m.GetPoint(self, i) local p = self.points[i or 1]; if p then return p[1], p[2], p[3], p[4], p[5] end end
    function m.SetScript(self, k, fn) self.scripts[k] = fn end
    function m.SetText(self, t) self.text = t end
    function m.GetText(self) return self.text end
    function m.SetMinMaxValues(self, a, b) self.min, self.max = a, b end
    function m.SetValue(self, v) self.value = v end
    function m.SetAlpha(self, a) self.alpha = a end
    function m.CreateFontString(self) local fs = newObj("FontString"); return fs end
    function m.CreateTexture(self) return newObj("Texture") end
    return setmetatable(o, { __index = function(_, k) return m[k] or stub() end })
end
function CreateFrame(kind, name, parent, template)
    local f = newObj(kind)
    f.name, f.parent, f.template = name, parent, template
    if kind == "Frame" or kind == "Button" or kind == "StatusBar" then f.shown = true end
    W.frames[#W.frames + 1] = f
    if name then W.created[name] = (W.created[name] or 0) + 1 end
    f.RegisterEvent = function(self, e) self.events[e] = true end
    f.SetScript = function(self, k, fn) self.scripts[k] = fn; if k == "OnEvent" then handlers[self] = fn end end
    return f
end
UIParent = newObj("Frame")

-- ---- auction house: pages of results, answered a moment after each request
W.pages, W.pi = {}, 0
local full = false
C_AuctionHouse = {
    SendBrowseQuery = function(q) W.sent = (W.sent or 0) + 1; W.lastQuery = q end,
    SearchForFavorites = function() W.favs = (W.favs or 0) + 1 end,
    GetBrowseResults = function() return W.cur or {} end,
    HasFullBrowseResults = function() return full end,
    IsThrottledMessageSystemReady = function() return W.ready end,
    RequestMoreBrowseResults = function() W.more = (W.more or 0) + 1 end,
}
local function fire(ev, ...) for f, fn in pairs(handlers) do if ev == "ADDON_LOADED" or ev == "PLAYER_LOGIN" or (f.events and f.events[ev]) then fn(f, ev, ...) end end end
local function run(sec)
    local stop = W.time + sec
    while true do
        local bi
        for i, t in ipairs(W.timers) do if t.due <= stop and (not bi or t.due < W.timers[bi].due or (t.due == W.timers[bi].due and t.o < W.timers[bi].o)) then bi = i end end
        if not bi then break end
        local t = table.remove(W.timers, bi); W.time = t.due; t.fn()
    end
    W.time = stop
end
local function items(from, n, price) local r = {} for i = 1, n do r[i] = { itemKey = { itemID = from + i }, minPrice = (price or 100) + i, totalQuantity = 1 } end return r end
-- the first page of a query (UPDATED), then each further page on request (ADDED); last = the house is done
local function firstPage(res, last) W.cur = res; full = last and true or false; fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED") end
local function addPage(res, last) full = last and true or false; fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", res) end

local pass, fail = 0, 0
local function ok(name, cond, extra) if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. " " .. tostring(extra or "")) end end
local ns
local function boot(saved)
    AHProfitDB = saved; ns = {}; handlers = {}; W.frames, W.created = {}, {}
    for _, f in ipairs({ "Data.lua", "Core.lua", "Sync.lua", "Progress.lua" }) do
        local chunk = loadfile("AHProfit/" .. f)
        if chunk then chunk("AHProfit", ns) else assert(f == "Progress.lua", "missing AHProfit/" .. f) end   -- (base: no window)
    end
    fire("ADDON_LOADED", "AHProfit"); fire("PLAYER_LOGIN"); run(30)
    AHProfitDB.autoscan = false                                  -- scans here start with /ahp scan
    return AHProfitDB
end
local function slash(s) SlashCmdList.AHPROFIT(s) end
local function plain(s) return (tostring(s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
local function said(pat) local n = 0; for _, c in ipairs(chat) do if plain(c):find(pat, 1, true) then n = n + 1 end end return n end
local NOWIN = { title = {}, line = {}, state = {}, bar = {}, close = { scripts = { OnClick = function() end } }, points = {},
    scripts = { OnDragStop = function() end }, GetPoint = function() end }   -- no window (base): every check fails, none errors
local function win() return ns.progress and ns.progress.frame or NOWIN end
local function shown() local f = win(); return f ~= NOWIN and f.shown end
local function line() return win().line.text or "" end
local function sentH() local n = 0; for _, m in ipairs(W.log) do if m:sub(1, 1) == "H" then n = n + 1 end end return n end
local function openAH() fire("AUCTION_HOUSE_SHOW"); run(2) end
local function closeAH() fire("AUCTION_HOUSE_CLOSED") end
-- a whole scan in pages of 100
local function fullScan(n, base)
    slash("scan"); run(0.5)
    local pages = math.ceil(n / 100)
    for p = 1, pages do
        local res = items((base or 0) + (p - 1) * 100, math.min(100, n - (p - 1) * 100))
        if p == 1 then firstPage(res, p == pages) else addPage(res, p == pages) end
        run(1.5)
    end
end

-- ---- the first scan: no estimate yet, an indeterminate bar, success text, hidden after 5 s
local db = boot({})
openAH()
slash("scan"); run(0.5)
ok("first scan: the window shows while scanning", shown() and win().title.text == "AH Profit: scanning the auction house", win() and win().title.text)
ok("first scan: the window is on UIParent, not the auction house window", win().parent == UIParent)
ok("first scan: no estimate, an indeterminate bar and no division by zero", win().indeterminate == true and win().bar.max == 1)
firstPage(items(0, 100)); run(1.5)
ok("first scan: the count shows", line():find("^100 items · keep the auction house open") ~= nil, line())
addPage(items(100, 100)); run(1.5)
addPage(items(200, 100), true); run(0.5)
ok("first scan: finished, shared with the guild", line() == "finished: 300 items, shared with your guild" and sentH() == 1 and ns.live().full > 0, line())
run(4); ok("first scan: still showing 4 s after", shown())
run(1.5); ok("first scan: hidden 5 s after finishing", not shown())

-- ---- the next scan: an estimate from the last full scan; the bar follows the count
run(1000)
slash("scan"); run(0.5)
ok("estimate: the bar measures against the last full scan", win().indeterminate == false and win().bar.max == 300, win().bar.max)
firstPage(items(0, 100)); run(1.5)
ok("estimate: the count rises", win().bar.value == 100 and line():find("^100 items of about 300 · keep the auction house open") ~= nil, line())
addPage(items(100, 100)); run(1.5)
ok("estimate: and rises again", win().bar.value == 200)
-- selling pauses the scan: the state line says so; it carries on afterwards
W.selling = true
addPage(items(200, 25)); run(3)
local more0 = W.more
ok("selling: the window says the scan is paused", win().state.text == "paused while you sell", win().state.text)
ok("selling: nothing is requested while selling", W.more == more0)
W.selling = false; run(1.5)
ok("selling: the pause line goes away when the scan carries on", win().state.text == "" and W.more == more0 + 1, win().state.text)
-- the server's limit: waiting
W.ready = false
addPage(items(225, 25)); run(1.5)
ok("throttle: the window says it waits for the server", win().state.text == "waiting for the server", win().state.text)
W.ready = true; fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY"); run(1.5)
addPage(items(250, 50), true); run(0.5)
ok("estimate: finished", line() == "finished: 300 items, shared with your guild", line())
run(6)

-- ---- the auction house closed mid-scan: one reason line, nothing shared, the last full scan kept
local full0, h0, c0 = ns.live().full, sentH(), #chat
run(1000)
slash("scan"); run(0.5)
firstPage(items(0, 100)); run(1.5)
addPage(items(100, 40)); run(1.5)
closeAH()
local want = "scan stopped: the auction house was closed (140 items). Nothing shared, older prices kept."
ok("closed mid-scan: the reason line once", said(want) == 1, chat[#chat])
ok("closed mid-scan: nothing shared, the last full scan unchanged", sentH() == h0 and ns.live().full == full0)
ok("closed mid-scan: the window keeps the reason", shown() and line() == want and win().title.text == "AH Profit: scan stopped", line())
run(120); ok("closed mid-scan: the reason stays up", shown())
openAH()
ok("closed mid-scan: gone when the auction house opens again", not shown())

-- ---- the player's own search replaces the scan's query: the reason line, nothing shared
h0, full0 = sentH(), ns.live().full
run(1000)
slash("scan"); run(0.5)
firstPage(items(0, 100)); run(1.5)
C_AuctionHouse.SendBrowseQuery({ searchString = "linen" })    -- the player searches
firstPage(items(5000, 12), true); run(2)
local want2 = "scan stopped: a search replaced it. Run /ahp scan to scan again."
ok("own search: the reason line once", said(want2) == 1, chat[#chat])
ok("own search: nothing shared, the last full scan unchanged", sentH() == h0 and ns.live().full == full0)
ok("own search: the window keeps the reason", shown() and line() == want2, line())
ok("own search: the scan asks for no more pages of the player's search", (function() local m = W.more; run(5); return W.more == m end)())

-- ---- Favorites asked before the scan, answered after it began: not a replacement
openAH(); run(1000)
C_AuctionHouse.SearchForFavorites()                            -- the game asks at open
slash("scan"); run(0.5)
firstPage(items(9000, 3)); run(1.5)                             -- the late Favorites answer
firstPage(items(0, 100)); run(1.5)
addPage(items(100, 100)); run(1.5)
addPage(items(200, 100), true); run(0.5)
ok("favorites: a late Favorites answer does not stop the scan", said(want2) == 1 and line():find("^finished: 300 items") ~= nil, line())
run(6)

-- ---- a scan that ends short says why
run(1000)
slash("scan"); run(0.5)
firstPage(items(0, 100)); run(1.5)
addPage(items(100, 50), true); run(0.5)
local want3 = "scan ended early with 150 items; older prices kept (only 150 of about 300 items)."
ok("ended short: existing text plus the reason", said(want3) == 1 and line() == want3, chat[#chat])

-- ---- the server refuses: existing text, in the window too
openAH(); run(1000)
slash("scan"); run(0.5)
fire("AUCTION_HOUSE_BROWSE_FAILURE")
ok("refused: existing text, in chat and in the window", said("the auction house refused the scan; try /ahp scan again.") == 1 and line() == "the auction house refused the scan; try /ahp scan again.")

-- ---- the close button hides the window for this scan only
openAH(); run(1000)
slash("scan"); run(0.5)
firstPage(items(0, 100)); run(1.5)
win().close.scripts.OnClick(win().close)
ok("close: hidden for this scan", not shown())
addPage(items(100, 100)); run(1.5)
ok("close: stays hidden while this scan runs", not shown())
addPage(items(200, 100), true); run(6)
run(1000); slash("scan"); run(0.5)
ok("close: shown again for the next scan", shown())
win().close.scripts.OnClick(win().close)
local cc = said("scan stopped: the auction house was closed")
closeAH()
ok("close: a scan that then stops leaves the window closed, the reason goes to chat", not shown() and said("scan stopped: the auction house was closed") == cc + 1)

-- ---- drag to move: the position is saved, survives a reload, reset centres it; a damaged one falls back
openAH()
local f = win()
f.points = { { "TOPLEFT", UIParent, "TOPLEFT", 123.4, -45.6 } }
f.scripts.OnDragStop(f)
ok("position: saved when dragged", type(db.progressPos) == "table" and db.progressPos[1] == "TOPLEFT" and db.progressPos[3] == 123 and db.progressPos[4] == -46)
local saved = db
db = boot(saved)
openAH(); slash("scan"); run(0.5)
local p, rel, rp, x, y = win():GetPoint(1)
ok("position: restored after a reload", p == "TOPLEFT" and rel == UIParent and rp == "TOPLEFT" and x == 123 and y == -46, tostring(p) .. " " .. tostring(x))
slash("progress reset")
p, rel, rp, x, y = win():GetPoint(1)
ok("position: reset puts it in the centre", p == "CENTER" and rp == "CENTER" and x == 0 and y == 0 and db.progressPos[1] == "CENTER")
closeAH()
db.progressPos = { "NOWHERE", 5, "x", {} }
db = boot(db)
openAH()
local okD = pcall(slash, "scan"); run(0.5)
p = win():GetPoint(1)
ok("position: a damaged position falls back to the default without an error", okD and p == "TOPRIGHT", tostring(p))
closeAH()

-- ---- progress off: no frame at all, chat lines still come
db = boot({})
slash("progress off")
openAH(); slash("scan"); run(0.5)
firstPage(items(0, 100)); run(1.5)
closeAH()
ok("off: no window created", (W.created.AHProfitScanProgress or 0) == 0 and win() == NOWIN)
ok("off: the reason still goes to chat", said("scan stopped: the auction house was closed (100 items).") >= 1)
slash("progress on")
openAH(); slash("scan"); run(0.5)
ok("on again: the window shows", shown())
closeAH()

-- ---- review round 1 (مانع)
-- S1: the auction house reopened within 5 s of finishing: the finished window still hides
db = boot({})
openAH(); slash("scan"); run(0.5)
firstPage(items(0, 100)); run(1.5); addPage(items(100, 100)); run(1.5); addPage(items(200, 100), true); run(0.5)
ok("S1: finished", line():find("^finished: 300 items") ~= nil, line())
closeAH(); run(2); openAH()                                    -- reopened 2-3 s later
run(10)
ok("S1: reopened within 5 s: the finished window still hides", not shown())
-- S2: closed while waiting to start, after a browse of 37 items: the count is this scan's (0)
run(1000)
firstPage(items(7000, 37), true); run(1)                       -- the player's own browse before the scan
local s2 = said("scan stopped: the auction house was closed (0 items).")
W.ready = false; slash("scan"); run(0.5)
closeAH(); W.ready = true
ok("S2: closed before the first page: 0 items, not the previous browse's", said("scan stopped: the auction house was closed (0 items).") == s2 + 1, chat[#chat])
-- S3: a Favorites search before our first page that never answers leaves the scan running
openAH(); run(1000)
slash("scan"); run(0.5)
C_AuctionHouse.SearchForFavorites()
firstPage(items(0, 100)); run(1.5); addPage(items(100, 100)); run(1.5); addPage(items(200, 100), true); run(0.5)
ok("S3: an unanswered Favorites call does not stop the scan", line():find("^finished: 300 items") ~= nil, line())
run(6)
-- S3: the same query as ours (blank search sorted by price) is not a replacement
run(1000); local full1 = ns.live().full
slash("scan"); run(0.5)
C_AuctionHouse.SendBrowseQuery({ searchString = "", filters = {}, itemClassFilters = {}, sorts = { { sortOrder = 0, reverseSort = false } } })
firstPage(items(0, 100)); run(1.5); addPage(items(100, 100)); run(1.5); addPage(items(200, 100), true); run(0.5)
ok("S3 (round 2): any query not sent by the scan stops it, even one the same as ours", ns.live().full == full1 and line() == "scan stopped: a search replaced it. Run /ahp scan to scan again.", line())
run(6)
-- S3: a search of the player's, then our last page arriving as more results: not complete
run(1000); local full2, c0 = ns.live().full, #chat
slash("scan"); run(0.5)
firstPage(items(0, 100)); run(1.5); addPage(items(100, 100)); run(1.5)
C_AuctionHouse.SendBrowseQuery({ searchString = "ore", filters = {}, sorts = {} })
addPage(items(200, 100), true); run(0.5)
ok("S3: a foreign search, then the last page: no complete scan", ns.live().full == full2, line())
ok("S3: ...said as a search replacing it", plain(chat[#chat]):find("scan stopped: a search replaced it.", 1, true) ~= nil, chat[#chat])
run(6)
-- note: /ahp progress on during a running scan shows the window at once
db = boot({}); slash("progress off")
openAH(); slash("scan"); run(0.5); firstPage(items(0, 100)); run(1.5)
slash("progress on")
ok("progress on during a scan: shown at once, with the count", shown() and line():find("^100 items") ~= nil, line())
closeAH()

-- ---- review round 2 (مانع)
local function fullScan500()
    run(1000); slash("scan"); run(0.5)
    for p = 1, 5 do if p == 1 then firstPage(items(0, 100)) else addPage(items((p - 1) * 100, 100), p == 5) end run(1.5) end
    run(6)
end
local function known() local n = 0; for _ in pairs(ns.live().p) do n = n + 1 end return n end
db = boot({}); openAH()
fullScan500()
ok("R2 setup: a 500-item full scan", known() == 500 and line():find("^finished: 500") ~= nil, line())
-- Q1/Q3: a level-filtered blank browse sorted by price replaces the scan: stopped, nothing deleted, nothing shared
for _, case in ipairs({ { "Q1 level 60-70, 300 rows", 300 }, { "Q2-style level filter, 280 rows (under half)", 280 } }) do
    run(1000); local f0, h0 = ns.live().full, sentH()
    slash("scan"); run(0.5)
    firstPage(items(0, 100)); run(1.5)
    C_AuctionHouse.SendBrowseQuery({ searchString = "", minLevel = 60, maxLevel = 70, filters = {}, itemClassFilters = {}, sorts = { { sortOrder = 0, reverseSort = false } } })
    firstPage(items(0, case[2]), true); run(2)
    ok("R2 " .. case[1] .. ": no full scan, no prices deleted, nothing shared", ns.live().full == f0 and known() == 500 and sentH() == h0, known())
end
-- the same with the level filter's answer arriving as more results (our last page): still not complete
run(1000); local f1 = ns.live().full
slash("scan"); run(0.5); firstPage(items(0, 100)); run(1.5)
C_AuctionHouse.SendBrowseQuery({ searchString = "", minLevel = 60, maxLevel = 70 })
addPage(items(100, 300), true); run(2)
ok("R2 level filter, then the last page as more results: not complete, said as a search", ns.live().full == f1 and known() == 500 and line() == "scan stopped: a search replaced it. Run /ahp scan to scan again.", line())
-- a query whose fields throw does not raise an error in the hook
run(1000); slash("scan"); run(0.5); firstPage(items(0, 100)); run(1.5)
local okT = pcall(C_AuctionHouse.SendBrowseQuery, setmetatable({}, { __index = function() error("no") end }))
firstPage(items(0, 50), true); run(2)
ok("R2 a query with a throwing metatable: no error, the scan stops", okT and line() == "scan stopped: a search replaced it. Run /ahp scan to scan again.", tostring(okT) .. " " .. line())
-- the auction house opened again mid-scan keeps the progress state; progress on then shows the window
run(1000); slash("progress off"); slash("scan"); run(0.5); firstPage(items(0, 100)); run(1.5)
fire("AUCTION_HOUSE_SHOW"); run(0.5)
slash("progress on")
ok("R2 AUCTION_HOUSE_SHOW again mid-scan, then progress on: shown with the count", shown() and line():find("^100 items") ~= nil and ns.progress.state_() == "scanning", tostring(ns.progress.state_()))
closeAH(); openAH()
-- stopped, then off, a new scan, on: the title is the scanning one
slash("scan"); run(0.5); slash("scan stop"); run(1)
slash("progress off"); run(1000); slash("scan"); run(0.5); firstPage(items(0, 100)); run(1.5)
slash("progress on")
ok("R2 stopped, off, scan, on: the scanning title", shown() and win().title.text == "AH Profit: scanning the auction house", win().title.text)
closeAH(); openAH()
-- a typed search sent just before the scan, answered after: not taken for the scan's first page
run(1000); local f2, k2 = ns.live().full, W.sent or 0
C_AuctionHouse.SendBrowseQuery({ searchString = "ore" })
slash("scan"); run(0.2)
ok("R2 late answer: the scan's query waits while a search just sent is unanswered", (W.sent or 0) == k2 + 1)
firstPage(items(9000, 30), true); run(1)                        -- the typed search's answer
ok("R2 late answer: the scan's query goes out right after that answer", (W.sent or 0) == k2 + 2, (W.sent or 0) - k2)
for p = 1, 5 do if p == 1 then firstPage(items(0, 100)) else addPage(items((p - 1) * 100, 100), p == 5) end run(1.5) end
ok("R2 late answer: then the scan runs and finishes with its own 500 items", (W.sent or 0) == k2 + 2 and ns.live().full > f2 and line():find("^finished: 500 items") ~= nil, line())
run(6)
-- ...and a search that is never answered delays the scan by 3 s at most
run(1000); local k3 = W.sent or 0
C_AuctionHouse.SendBrowseQuery({ searchString = "linen" })
slash("scan"); run(4)
ok("R2 an unanswered search delays the scan 3 s at most", (W.sent or 0) == k3 + 2, (W.sent or 0) - k3)
closeAH()

-- ---- old saves without the new fields
local okOld = pcall(boot, { v = 3, live = { ["Realm|Alliance"] = { p = { [5] = 1 }, q = { [5] = 1 }, t = { [5] = 1 }, full = 0 } } })
ok("an old save without the new fields loads", okOld and AHProfitDB.progress == nil and AHProfitDB.progressPos == nil)
slash("")
ok("help lists the progress commands", said("progress on | progress off | progress reset") >= 1)

print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
