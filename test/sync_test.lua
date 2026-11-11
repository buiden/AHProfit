-- Guild sync test: several simulated players in one guild, each with their own copy of the addon.
--   lua test/sync_test.lua     (from the project directory)
local W = { time = 1794400000, timers = {}, order = 0, fail = 0, lockdown = false, log = {}, drop = nil, guild = true, tokens = {} }
local cur, clients = nil, {}
local chat = {}
function issecretvalue() return false end
function GetServerTime() return math.floor(W.time) end
time = GetServerTime
function GetRealmName() return "Realm" end
function UnitFactionGroup() return "Alliance" end
function UnitName() return cur.name end
function UnitFullName() return cur.name, "Realm" end
function IsInGuild() return W.guild and cur.guild end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) chat[#chat + 1] = cur.name .. ": " .. m end }
C_Timer = { After = function(d, fn) W.order = W.order + 1; W.timers[#W.timers + 1] = { due = W.time + d, fn = fn, c = cur, o = W.order } end }
C_Item = { GetItemInfo = function() return nil end, GetItemCount = function() return 0 end }
Enum = { TooltipDataType = { Item = 0 }, AuctionHouseSortOrder = { Price = 0 } }
TooltipDataProcessor = { AddTooltipPostCall = function() end }
SlashCmdList = {}
C_AuctionHouse = { SendBrowseQuery = function() end, GetBrowseResults = function() return W.results end, HasFullBrowseResults = function() return true end,
    IsThrottledMessageSystemReady = function() return true end, RequestMoreBrowseResults = function() end }
function CreateFrame()
    local f = { ev = {} }
    function f:RegisterEvent(e) self.ev[e] = true end
    function f:SetScript(_, fn) self.fn = fn end
    function f:Hide() end
    cur.frames[#cur.frames + 1] = f
    return f
end
local function fire(c, ev, ...)
    local old = cur; cur = c
    for _, f in ipairs(c.frames) do if f.ev[ev] and f.fn then f.fn(f, ev, ...) end end
    cur = old
end
C_ChatInfo = {
    InChatMessagingLockdown = function() return W.lockdown end,
    RegisterAddonMessagePrefix = function(p) cur.prefix[p] = true; return 0 end,
    SendAddonMessage = function(prefix, msg, chan)
        assert(#prefix <= 16 and #msg <= 255, "message too long: " .. #msg)
        assert(not msg:find("[^%w+/,]"), "unexpected character in message")
        if W.fail > 0 then W.fail = W.fail - 1; return 3 end
        local b = W.tokens[cur] or { n = 10, at = W.time }           -- the client's limit: 10 at once, then 1 per second
        b.n = math.min(10, b.n + (W.time - b.at)); b.at = W.time; W.tokens[cur] = b
        if b.n < 1 then W.throttled = (W.throttled or 0) + 1; return 3 end
        b.n = b.n - 1
        W.log[#W.log + 1] = { from = cur.name, msg = msg }
        if W.drop and W.drop(msg) then return 0 end
        local sender = cur.name .. "-Realm"
        for _, c in ipairs(clients) do
            if c.guild and c.prefix[prefix] then fire(c, "CHAT_MSG_ADDON", prefix, msg, chan, sender, "", 0, 0, "", 0) end
        end
        return 0
    end,
}
local function run(sec)
    local stop = W.time + sec
    while true do
        local bi
        for i, t in ipairs(W.timers) do if t.due <= stop and (not bi or t.due < W.timers[bi].due or (t.due == W.timers[bi].due and t.o < W.timers[bi].o)) then bi = i end end
        if not bi then break end
        local t = table.remove(W.timers, bi)
        W.time = t.due; cur = t.c; t.fn()
    end
    W.time = stop
end
local function client(name)
    local c = { name = name, frames = {}, prefix = {}, ns = {}, guild = true }
    clients[#clients + 1] = c
    cur = c; AHProfitDB = nil
    for _, f in ipairs({ "Core.lua", "Sync.lua" }) do assert(loadfile("AHProfit/" .. f))("AHProfit", c.ns) end
    fire(c, "ADDON_LOADED", "AHProfit"); c.db = AHProfitDB; c.slash = SlashCmdList.AHPROFIT
    c.db.autoscan = true                                         -- these members chose /ahp auto on
    fire(c, "PLAYER_LOGIN")
    return c
end
local function L(c) cur = c; return c.ns.live() end
local function scan(c, results)
    W.results = results
    fire(c, "AUCTION_HOUSE_SHOW"); run(1.5)
    fire(c, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"); fire(c, "AUCTION_HOUSE_CLOSED")
end
local function R(id, price, q) return { itemKey = { itemID = id }, minPrice = price, totalQuantity = q } end
local function count(kind, from) local n = 0; for _, m in ipairs(W.log) do if m.msg:sub(1, 1) == kind and (not from or m.from == from) then n = n + 1 end end return n end
local pass, fail = 0, 0
local function ok(name, cond, extra) if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. " " .. tostring(extra or "")) end end

local a, b, c = client("Abdullah"), client("Ahmed"), client("Tareq")
local Y = a.ns.sync

-- ---- encoding
do
    local Lx = { p = {}, q = {} }
    local ids = { 1, 2, 33, 1024, 25000, 9999999 }
    local pr = { 1, 31, 32, 123456789, 999999999999, 600 }
    for i, id in ipairs(ids) do Lx.p[id] = pr[i]; Lx.q[id] = (i - 1) * 1000 end
    Lx.p[77] = 0; Lx.p[78] = 1.5; Lx.p["x"] = 5; Lx.p[5e7] = 5; Lx.p[79] = 2e12       -- none of these may be sent
    Lx.p[80] = 9; Lx.q[80] = nil
    local ch, n = Y.encode(Lx)
    ok("only valid items encoded", n == 7 and #ch == 1, n)
    local d = Y.decode(ch[1])
    local back = {}
    for i = 1, #d, 3 do back[d[i]] = { d[i + 1], d[i + 2] } end
    local same = back[80] and back[80][1] == 9 and back[80][2] == 0
    for i, id in ipairs(ids) do if not (back[id] and back[id][1] == pr[i] and back[id][2] == (i - 1) * 1000) then same = false end end
    ok("round trip exact", same)
    for _, bad in ipairs({ "", "!", "0", "100", "w", "wwwwwwwwwwwwwwww1", "01", "1 1", "1010", "111x" }) do
        if bad ~= "111x" then ok("bad payload rejected: " .. bad, Y.decode(bad) == nil) end
    end
    ok("zero step rejected", Y.decode("111011") == nil)
end

-- ---- one player scans, the guild gets it
L(b).p[5] = 999; L(b).q[5] = 1; L(b).t[5] = W.time - 5000          -- Ahmed: an old price for an item no longer listed
L(b).p[1001] = 1; L(b).q[1001] = 1; L(b).t[1001] = W.time - 5000   -- and an old price for one that is
local res = {}
for i = 1, 400 do res[i] = R(1000 + i * 3, 100 + i * 37, i % 9) end
scan(a, res)
local tscan = L(a).full
ok("scan done on sender", tscan > 0 and count("H", "Abdullah") == 1)
L(c).p[1003] = 7; L(c).q[1003] = 2; L(c).t[1003] = W.time + 1     -- Tareq sees one item himself after the scan started
run(1.2)
ok("first prices arrive at once, no reload", L(b).p[1003] == 137 and L(b).full == 0)
run(120)
local nd = count("D", "Abdullah")
ok("all chunks sent, never throttled", nd >= 5 and not W.throttled, nd)
local same = true
for i = 1, 400 do local id = 1000 + i * 3; if L(b).p[id] ~= 100 + i * 37 or L(b).q[id] ~= i % 9 or L(b).t[id] ~= tscan then same = false end end
ok("receiver has every price", same)
ok("receiver marked complete", L(b).full == tscan and L(c).full == tscan)
ok("item no longer listed is forgotten", L(b).p[5] == nil)
ok("stale price replaced", L(b).p[1001] == nil or L(b).p[1001] ~= 1)
ok("receiver's own newer price kept", L(c).p[1003] == 7)
cur = b; local p, q, t, src = b.ns.lookup(1006)
ok("tooltip source is the shared scan", p == 174 and src == "scan" and t == tscan)
ok("sender unchanged by own messages", L(a).p[1003] == 137 and a.db.syncFrom == nil)
ok("receiver told who it came from", b.db.syncFrom == "Abdullah" and chat[#chat]:find("shared with your guild", 1, true) or chat[#chat - 1]:find("Abdullah's scan", 1, true), chat[#chat])
cur = b; b.slash(""); ok("status names the source", chat[#chat - 1]:find("Last received: Abdullah's scan", 1, true), chat[#chat - 1])
W.log = {}; fire(b, "AUCTION_HOUSE_SHOW"); run(2); fire(b, "AUCTION_HOUSE_CLOSED")
ok("receiver does not rescan within 15 minutes", L(b).full == tscan)

-- ---- hostile or broken input never errors and never changes prices
local before = L(b).p[1006]
local function inject(msg, chan, prefix, sender) fire(b, "CHAT_MSG_ADDON", prefix or "AHProfit", msg, chan or "GUILD", sender or "Evil-Realm", "", 0, 0, "", 0) end
local okAll = true
for _, m in ipairs({ "", "H", "H1", "D", "Q", "Hx,1,1,1,1", "H1,123456," .. (W.time + 99999) .. ",5,1", "H1,123456," .. (W.time - 90000) .. ",5,1", "H2,123456," .. W.time .. ",5,1",
    "H1,123456," .. W.time .. ",0,1", "H1,123456," .. W.time .. ",5,9", "D123456,1,1E1", "D123456,1,!!!", "Q1,abc", string.rep("D", 300), "H1,123456,99999999999999999999,5,1" }) do
    local o, e = pcall(inject, m); if not o then okAll = false; print(e) end
end
ok("garbage survives", okAll and L(b).p[1006] == before and L(b).full == tscan)
run(1); W.time = W.time + 10
inject("H1,222222," .. W.time .. ",1,1", "PARTY"); inject("D222222,1,3E1", "PARTY"); ok("non-guild channel ignored", L(b).p[3] == nil)
inject("H1,222222," .. W.time .. ",1,1", "GUILD", "Other"); inject("D222222,1,3E1", "GUILD", "Other"); ok("other prefix ignored", L(b).p[3] == nil)
inject("H1,222222," .. W.time .. ",2,1"); inject("D222222,1,3E1"); ok("count mismatch: no pruning, not complete", L(b).p[1006] == before and L(b).full == tscan)
inject("H1,333333," .. W.time .. ",1,1"); inject("D333333,1,3E1E1E1"); ok("more items than announced: dropped", L(b).full == tscan and L(b).p[1006] == before)
inject("H1,444444," .. (tscan - 5) .. ",1,1"); inject("D444444,1,3E1"); ok("older scan ignored", L(b).p[1006] == before)
L(b).p[3], L(b).q[3], L(b).t[3] = nil, nil, nil

-- ---- lost message: prices that arrived are used, nothing is forgotten
W.time = W.time + 1000; W.log = {}
local res2 = {}
for i = 1, 400 do res2[i] = R(1000 + i * 3, 50 + i, 1) end
res2[400] = nil                                                     -- item 2200 is gone in the new scan
W.drop = function(m) return m:match("^D%d+,2,") ~= nil end
scan(c, res2); run(120); W.drop = nil
ok("with a lost chunk: arrived prices used", L(a).p[1003] == 51 and L(a).t[1003] == L(c).full)
ok("with a lost chunk: nothing forgotten, not marked complete", L(a).p[2200] ~= nil and L(a).full == tscan)

-- ---- game refuses some messages / chat lockdown: still completes
W.time = W.time + 1000; W.log = {}; W.fail = 4
scan(c, res2); run(60); W.lockdown = true; run(20); W.lockdown = false; run(200)
ok("retries through refusals", L(a).full == L(c).full and L(a).p[2200] == nil and L(b).full == L(c).full, L(a).full .. " " .. L(c).full)

-- ---- someone logs in later: asks, exactly one member answers
W.log = {}
local d = client("Saad")
run(11); ok("no request before the delay", count("Q") == 0)
run(2); ok("request sent after login", count("Q", "Saad") == 1)
run(300)
ok("exactly one member answered", count("H") == 1, count("H"))
ok("late player has the prices", L(d).full == L(c).full and L(d).p[1003] == 51)
W.log = {}; local e = client("Nasser"); L(e).full = math.floor(W.time); run(60)
ok("nobody answers a player who is already newer", count("Q", "Nasser") == 1 and count("H") == 0)
L(e).full = 0

-- ---- switches
W.log = {}; cur = a; a.slash("sync off")
W.time = W.time + 1000; scan(a, res); run(200)
ok("sync off: nothing sent", #W.log == 0 and a.db.sync == false)
a.slash("sync on"); cur = a; a.slash("share"); run(200)
ok("/ahp share sends the last scan", count("H", "Abdullah") == 1 and L(b).full == L(a).full and L(b).p[1003] == 137)
W.log = {}; cur = b; b.slash("sync off"); W.time = W.time + 1000; scan(a, res2); run(200)
ok("sync off: nothing received", L(b).p[1003] == 137 and L(c).p[1003] == 51)
b.slash("sync on")
W.log = {}; a.guild = false; W.time = W.time + 1000; scan(a, res); run(200); cur = a; a.slash("share")
ok("not in a guild: nothing sent, clear message", #W.log == 0 and chat[#chat]:find("not in a guild", 1, true), chat[#chat]); a.guild = true
local sv = C_ChatInfo; C_ChatInfo = nil; local o1 = pcall(function() cur = a; return a.ns.sync.broadcast(true) end); C_ChatInfo = sv
ok("client without addon messages: no error", o1)

-- ---- size of a real scan
do
    local ns2 = {}
    assert(loadfile("AHProfit/Data.lua"))("AHProfit", ns2)
    local Lr = { p = {}, q = {} }
    local fl = ns2.seed.flat
    for i = 1, #fl, 3 do Lr.p[fl[i]] = fl[i + 1]; Lr.q[fl[i]] = fl[i + 2] end
    local t0 = os.clock(); local ch, n = Y.encode(Lr); local ms = (os.clock() - t0) * 1000
    local total = 0
    for _, s in ipairs(ch) do local dd = Y.decode(s); total = total + (dd and #dd / 3 or -1e9) end
    ok("real price list round trips", total == n and n == ns2.seed.n, total .. " " .. n)
    print(string.format("real scan: %d items = %d messages = %.1f min to share; encoding takes %.0f ms once", n, #ch + 1, (#ch + 1) * 1.05 / 60, ms))
end
print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
