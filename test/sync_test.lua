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
-- Prices received from the guild live in their own layer, never in your own scans.
local function G(c) cur = c; return c.ns.shared and c.ns.shared() or { p = {}, q = {}, t = {}, from = {}, full = -1 } end   -- (no layer on old versions)
local function look(c, id) cur = c; return c.ns.lookup(id) end
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
ok("first prices arrive at once, no reload", G(b).p[1003] == 137 and G(b).full == 0 and L(b).full == 0)
run(120)
local nd = count("D", "Abdullah")
ok("all chunks sent, never throttled", nd >= 5 and not W.throttled, nd)
local same = true
for i = 1, 400 do local id = 1000 + i * 3; if G(b).p[id] ~= 100 + i * 37 or G(b).q[id] ~= i % 9 or G(b).t[id] ~= tscan then same = false end end
ok("receiver has every price, in the shared layer", same)
ok("shared layer marked complete, own scans untouched", G(b).full == tscan and G(c).full == tscan and L(b).full == 0 and L(c).full == 0)
ok("own scan of an item the sender did not list is kept", L(b).p[5] == 999)
ok("own entries are never overwritten by a shared scan", L(b).p[1001] == 1 and L(c).p[1003] == 7)
ok("own scan younger than 2 h wins over the guild's", look(b, 1001) == 1 and select(4, look(b, 1001)) == "scan")
ok("receiver's own newer price kept", look(c, 1003) == 7)
local p, q, t, src, from = look(b, 1006)
ok("tooltip source is the guild, with the sender's name", p == 174 and src == "guild" and t == tscan and from == "Abdullah", tostring(src) .. " " .. tostring(from))
ok("source label names the sender", b.ns.srcLabel and b.ns.srcLabel(src, t, from):find("^guild %(Abdullah, %d+m ago%)$"), b.ns.srcLabel and b.ns.srcLabel(src, t, from))
ok("sender unchanged by own messages", L(a).p[1003] == 137 and a.db.syncFrom == nil and next(G(a).p) == nil)
ok("receiver told who it came from", b.db.syncFrom == "Abdullah" and chat[#chat]:find("shared with your guild", 1, true) or chat[#chat - 1]:find("Abdullah's scan", 1, true), chat[#chat])
cur = b; b.slash(""); ok("status names the source", chat[#chat - 1]:find("Last received: Abdullah's scan", 1, true), chat[#chat - 1])
W.log = {}; fire(b, "AUCTION_HOUSE_SHOW"); run(2); fire(b, "AUCTION_HOUSE_CLOSED")
ok("receiver does not rescan within 15 minutes", L(b).full == 0 and G(b).full == tscan)

-- ---- hostile or broken input never errors and never changes prices
local before = G(b).p[1006]
local function inject(msg, chan, prefix, sender) fire(b, "CHAT_MSG_ADDON", prefix or "AHProfit", msg, chan or "GUILD", sender or "Evil-Realm", "", 0, 0, "", 0) end
local okAll = true
for _, m in ipairs({ "", "H", "H1", "D", "Q", "Hx,1,1,1,1", "H1,123456," .. (W.time + 99999) .. ",5,1", "H1,123456," .. (W.time - 90000) .. ",5,1", "H2,123456," .. W.time .. ",5,1",
    "H1,123456," .. W.time .. ",0,1", "H1,123456," .. W.time .. ",5,9", "D123456,1,1E1", "D123456,1,!!!", "Q1,abc", string.rep("D", 300), "H1,123456,99999999999999999999,5,1" }) do
    local o, e = pcall(inject, m); if not o then okAll = false; print(e) end
end
ok("garbage survives", okAll and G(b).p[1006] == before and G(b).full == tscan)
run(1); W.time = W.time + 10
inject("H1,222222," .. W.time .. ",1,1", "PARTY"); inject("D222222,1,3E1", "PARTY"); ok("non-guild channel ignored", G(b).p[3] == nil)
inject("H1,222222," .. W.time .. ",1,1", "GUILD", "Other"); inject("D222222,1,3E1", "GUILD", "Other"); ok("other prefix ignored", G(b).p[3] == nil)
inject("H1,222222," .. W.time .. ",2,1"); inject("D222222,1,3E1"); ok("count mismatch: no pruning, not complete", G(b).p[1006] == before and G(b).full == tscan)
inject("H1,333333," .. W.time .. ",1,1"); inject("D333333,1,3E1E1E1"); ok("more items than announced: dropped", G(b).full == tscan and G(b).p[1006] == before)
inject("H1,444444," .. (tscan - 5) .. ",1,1"); inject("D444444,1,3E1"); ok("older scan ignored", G(b).p[1006] == before)
G(b).p[3], G(b).q[3], G(b).t[3] = nil, nil, nil

-- ---- PR-C hardening: time bounds, own data never touched, malformed chunks
do
    local now = math.floor(W.time)
    local function copy(H) local o = { full = H.full }; for _, k in ipairs({ "p", "q", "t", "from" }) do o[k] = {}; for i, v in pairs(H[k]) do o[k][i] = v end end return o end
    local G0 = copy(G(b))
    local L0 = {}; for id, v in pairs(L(b).p) do L0[id] = v end
    local function sameOwn() for id, v in pairs(L0) do if L(b).p[id] ~= v then return false end end for id in pairs(L(b).p) do if L0[id] == nil then return false end end return true end
    inject("H1,510001," .. (now + 301) .. ",1,1"); inject("D510001,1,4E1")
    ok("scan time more than 5 min in the future: rejected", G(b).p[4] == nil and G(b).full == tscan)
    inject("H1,510002," .. (now - 43201) .. ",1,1"); inject("D510002,1,4E1")
    ok("scan time older than 12 h: rejected", G(b).p[4] == nil)
    inject("H1,510003," .. (now + 299) .. ",1,1"); inject("D510003,1,4E1")
    ok("small clock difference (under 5 min ahead) is accepted", G(b).p[4] == 14 and G(b).full == now + 299, tostring(G(b).p[4]))
    ok("a complete shared scan never deletes own entries", sameOwn() and L(b).full == 0)
    ok("...but it does replace the older shared prices", G(b).p[1006] == nil)
    ok("a shared scan from the future cannot block later scans for long", G(b).full <= now + 300)
    W.time = W.time + 10; now = math.floor(W.time)
    inject("H1,510004," .. (now + 299) .. ",3,2"); inject("D510004,1,5E1"); inject("D510004,2,0")
    ok("malformed second chunk: sender dropped, first chunk kept, nothing deleted", G(b).p[5] == 14 and G(b).p[4] == 14 and sameOwn())
    inject("D510004,2,6E1")
    ok("chunks after the drop are ignored", G(b).p[6] == nil)
    -- an own scan older than 2 h loses to a newer guild price; a younger one wins
    L(b).p[4], L(b).q[4], L(b).t[4] = 77, 1, now - 7201
    ok("own scan older than 2 h: the newer guild price is shown", look(b, 4) == 14 and select(4, look(b, 4)) == "guild")
    L(b).t[4] = now - 7199
    ok("own scan younger than 2 h: own price is shown", look(b, 4) == 77 and select(4, look(b, 4)) == "scan")
    L(b).p[4], L(b).q[4], L(b).t[4] = nil, nil, nil
    local H = G(b); for k, v in pairs(copy(G0)) do H[k] = v end
    ok("shared layer restored for the next checks", G(b).p[1006] == before and G(b).full == tscan)
    -- the shared layer has a hard item cap: new items beyond it are not stored
    local n0 = 0; for _ in pairs(G(b).p) do n0 = n0 + 1 end
    local Yb, cap = b.ns.sync, b.ns.sync.MAXITEMS or 60000
    ok("item cap default", cap == 60000)
    Yb.MAXITEMS = n0 + 1
    W.time = W.time + 10; now = math.floor(W.time)
    inject("H1,510005," .. (now + 299) .. ",4,1"); inject("D510005,1,1E11E11E1")     -- items 1, 2, 3 of 4 announced
    local n1 = 0; for _ in pairs(G(b).p) do n1 = n1 + 1 end
    ok("item cap: an unfinished transfer stores only one new item, existing ones still update", n1 == n0 + 1 and G(b).p[1] == 14 and G(b).p[2] == nil and G(b).p[3] == nil, n1 - n0)
    ok("item cap: an unfinished transfer is not marked complete and deletes nothing", G(b).full == tscan and G(b).p[1006] == before, G(b).full - tscan)
    W.time = W.time + 10; now = math.floor(W.time)
    inject("H1,510006," .. (now + 299) .. ",3,1"); inject("D510006,1,1E11E11E1")
    local n2 = 0; for _ in pairs(G(b).p) do n2 = n2 + 1 end
    ok("item cap: a complete newer scan replaces the layer, items kept aside at the cap included", n2 == 3 and G(b).p[2] == 14 and G(b).p[3] == 14 and G(b).full == now + 299 and G(b).p[1006] == nil, n2)
    Yb.MAXITEMS = cap
    local H2 = G(b); for k, v in pairs(copy(G0)) do H2[k] = v end   -- back to the earlier layer for the checks below
    -- the tooltip line names the guild member
    local lines = {}
    b.db.enabled = true
    cur = b; b.ns.addLines({ AddDoubleLine = function(_, l, r) lines[#lines + 1] = l end }, 1006)
    ok("tooltip says guild (Name, age)", lines[1] and lines[1]:find("guild (Abdullah, ", 1, true), tostring(lines[1]))
end

-- ---- lost message: prices that arrived are used, nothing is forgotten
W.time = W.time + 1000; W.log = {}
local res2 = {}
for i = 1, 400 do res2[i] = R(1000 + i * 3, 50 + i, 1) end
res2[400] = nil                                                     -- item 2200 is gone in the new scan
W.drop = function(m) return m:match("^D%d+,2,") ~= nil end
scan(c, res2); run(120); W.drop = nil
ok("with a lost chunk: arrived prices used", G(a).p[1003] == 51 and G(a).t[1003] == L(c).full)
ok("with a lost chunk: nothing forgotten, not marked complete", L(a).p[2200] ~= nil and G(a).full < L(c).full)

-- ---- game refuses some messages / chat lockdown: still completes
W.time = W.time + 1000; W.log = {}; W.fail = 4
scan(c, res2); run(60); W.lockdown = true; run(20); W.lockdown = false; run(200)
ok("retries through refusals", G(a).full == L(c).full and G(a).p[2200] == nil and L(a).p[2200] ~= nil and G(b).full == L(c).full, G(a).full .. " " .. L(c).full)

-- ---- someone logs in later: asks, exactly one member answers
W.log = {}
local d = client("Saad")
run(11); ok("no request before the delay", count("Q") == 0)
run(2); ok("request sent after login", count("Q", "Saad") == 1)
run(300)
ok("exactly one member answered", count("H") == 1, count("H"))
ok("late player has the prices", G(d).full == L(c).full and G(d).p[1003] == 51)
ok("only the member who scanned answers; received scans are not passed on", count("H", "Tareq") == 1)
W.log = {}; local e = client("Nasser"); L(e).full = math.floor(W.time); run(60)
ok("nobody answers a player who is already newer", count("Q", "Nasser") == 1 and count("H") == 0)
L(e).full = 0

-- ---- switches
W.log = {}; cur = a; a.slash("sync off")
W.time = W.time + 1000; scan(a, res); run(200)
ok("sync off: nothing sent", #W.log == 0 and a.db.sync == false)
a.slash("sync on"); cur = a; a.slash("share"); run(200)
ok("/ahp share sends the last scan", count("H", "Abdullah") == 1 and G(b).full == L(a).full and G(b).p[1003] == 137)
W.log = {}; cur = b; b.slash("sync off"); W.time = W.time + 1000; scan(a, res2); run(200)
ok("sync off: nothing received", G(b).p[1003] == 137)
b.slash("sync on")
W.log = {}; a.guild = false; W.time = W.time + 1000; scan(a, res); run(200); cur = a; a.slash("share")
ok("not in a guild: nothing sent, clear message", #W.log == 0 and chat[#chat]:find("not in a guild", 1, true), chat[#chat]); a.guild = true
local sv = C_ChatInfo; C_ChatInfo = nil; local o1 = pcall(function() cur = a; return a.ns.sync.broadcast(true) end); C_ChatInfo = sv
ok("client without addon messages: no error", o1)

-- ---- review round 1 (B1, S1, S2, N6, N7): fresh own scan first, no lockout at the cap, provenance pruned
do
    local function to(c, msg, sender) fire(c, "CHAT_MSG_ADDON", "AHProfit", msg, "GUILD", sender or "Hostile-Realm", "", 0, 0, "", 0) end
    local function send(c, sid, t, prices, sender)
        cur = c
        local ch, n = c.ns.sync.encode({ p = prices, q = {} })
        to(c, "H1," .. sid .. "," .. t .. "," .. n .. "," .. #ch, sender)
        for i, p in ipairs(ch) do to(c, "D" .. sid .. "," .. i .. "," .. p, sender) end
    end
    local function look3(c, id) cur = c; local p, _, _, src = c.ns.lookup(id); return tostring(p) .. " " .. tostring(src) end
    local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end return n end
    W.guild = false                                              -- nothing here may reach the other clients
    -- S1: a fresh own scan wins whatever the feed's age and whatever a guild member claims
    for _, case in ipairs({ { 60, 30, true }, { 60, 30, false }, { 1800, 600, true }, { 60, 120, true }, { 60, nil, true }, { 7200, nil, true }, { 7201, nil, true } }) do
        local c = client("Probe" .. case[1] .. tostring(case[2]) .. tostring(case[3]))
        local now = math.floor(W.time)
        local Lc = L(c); Lc.p[3], Lc.q[3], Lc.t[3] = 77, 9, now - case[1]
        if case[3] then Lc.full = now - case[1] end
        if case[2] then c.ns.seed = { t = now - case[2], flat = { 3, 50, 5 } } end
        cur = c; to(c, "H1,111111," .. (now + 300) .. ",2,2"); to(c, "D111111,1," .. c.ns.sync.encode({ p = { [3] = 14 }, q = { [3] = 1 } })[1])
        local want = case[1] <= 7200 and "77 scan" or "14 guild"
        ok("S1: own " .. case[1] .. "s, feed " .. tostring(case[2]) .. "s, full " .. tostring(case[3]) .. ", hostile +300 partial -> " .. want, look3(c, 3) == want, look3(c, 3))
    end
    -- B1: junk ids from unfinished transfers fill the 60,000 cap
    local function fillCap(c, t)
        for _, range in ipairs({ { 1, 49000 }, { 49001, 60000 } }) do
            local prices = {}
            for i = range[1], range[2] do prices[9000000 + i] = 1 end
            cur = c
            local ch, n = c.ns.sync.encode({ p = prices, q = {} })
            to(c, "H1,123456," .. t .. "," .. (n + 1) .. "," .. (#ch + 1))       -- announces one item more: never completes
            for i, p in ipairs(ch) do to(c, "D123456," .. i .. "," .. p) end
        end
    end
    local function honest(c, sid, t, k)
        local pr = {}
        for i = 1, k do pr[i + 100] = 100 + i end
        send(c, sid, t, pr, "Honest-Realm")
        local got = 0
        for i = 1, k do if G(c).p[i + 100] then got = got + 1 end end
        return got
    end
    do
        local c = client("ProbeCapNow")
        local now = math.floor(W.time)
        fillCap(c, now + 1)
        ok("B1: the cap can be filled by unfinished transfers", count(G(c).p) == 60000 and G(c).full == 0, count(G(c).p))
        W.time = W.time + 60
        local got = honest(c, 777770, math.floor(W.time), 5000)
        ok("B1: a complete honest scan within 12 h replaces the layer instead of being refused", got == 5000 and G(c).full == math.floor(W.time) and count(G(c).p) == 5000 and G(c).p[9000001] == nil, got .. " " .. count(G(c).p))
        ok("B1: ...and its sender is shown", look3(c, 101) == "101 guild" and c.db.syncFrom == "Honest")
    end
    do
        local c = client("ProbeCapWeek")
        local now = math.floor(W.time)
        fillCap(c, now + 1)
        W.time = W.time + 7 * 86400
        local got = honest(c, 777771, math.floor(W.time), 5000)
        ok("B1: a week later (Mani's repro) every honest item is stored", got == 5000 and G(c).p[9000001] == nil, got)
        -- older than 12 h: dropped at load and when a header is accepted
        W.time = W.time + 43201
        cur = c; to(c, "H1,777772," .. math.floor(W.time) .. ",9,9")
        ok("B1: entries older than 12 h are dropped when a header is accepted", count(G(c).p) == 0 and next(G(c).from) == nil, count(G(c).p))
        W.time = W.time - 43201 - 7 * 86400
    end
    -- S2 / Astra C4: provenance from unfinished transfers does not pile up
    do
        local c = client("ProbeFrom")
        local now = math.floor(W.time)
        for i = 1, 200 do cur = c; to(c, "H1,123456," .. (now - 201 + i) .. ",2,2"); to(c, "D123456,1,3E1") end
        ok("S2: sender names of unfinished transfers do not pile up (at most the last two)", count(G(c).from) <= 2, count(G(c).from))
        cur = c; to(c, "H1,123457," .. now .. ",2,2")
        ok("S2: ...and the next accepted header keeps only the one in use", count(G(c).from) == 1, count(G(c).from))
    end
    -- N7: an empty or absurdly long sender name is refused, without an error
    do
        local c = client("ProbeName")
        local now = math.floor(W.time)
        local okNoName = pcall(send, c, 123450, now, { [3] = 14 }, "-Realm")
        local okLong = pcall(send, c, 123451, now, { [5] = 14 }, string.rep("S", 100) .. "-Realm")
        ok("N7: empty and over-long sender names are refused without an error", okNoName and okLong and G(c).p[3] == nil and G(c).p[5] == nil)
    end
    W.guild = true
end

-- ---- review round 2 (PR-C): staging bounded, pending transfers expire, no false "updated" message
do
    local function up(f, name)
        for i = 1, 200 do
            local k, v = debug.getupvalue(f, i)
            if k == nil then break end
            if k == name then return v end
        end
        error("upvalue " .. name)
    end
    local c = client("ProbeFlood")
    cur = c
    local Y = c.ns.sync
    local header = up(Y.receive, "header")
    local R, held = up(header, "R"), up(header, "held")
    local function to(msg, sender) fire(c, "CHAT_MSG_ADDON", "AHProfit", msg, "GUILD", sender or "Flood-Realm", "", 0, 0, "", 0) end
    local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end return n end
    W.guild = false
    local H = G(c)
    local t0 = math.floor(W.time)
    for i = 1, 60000 do H.p[9000000 + i], H.q[9000000 + i], H.t[9000000 + i] = 1, 0, t0 end
    held[H] = 60000
    local prices = {}
    for i = 1, 79 do prices[i] = 1 end
    local payload = Y.encode({ p = prices, q = {} })[1]
    to("H1,123456," .. (t0 + 1) .. ",50000,2000")
    for seq = 1, 300 do to("D123456," .. seq .. "," .. payload) end
    local r = R["Flood-Realm"]
    ok("flood: the same ids repeated are staged once (at most the declared items)", r and #r.stage == 79 * 3, r and #r.stage)
    -- a pending transfer expires 900 s after its header even with no other header: when a chunk arrives...
    W.time = W.time + 901
    to("D123456,301," .. payload, "Flood-Realm")
    ok("flood: a chunk after 900 s ends the pending transfer", R["Flood-Realm"] == nil)
    -- ...and on its own, from a timer
    to("H1,123457," .. math.floor(W.time) .. ",50000,2000", "Flood2-Realm")
    to("D123457,1," .. payload, "Flood2-Realm")
    ok("flood: pending transfer present", R["Flood2-Realm"] ~= nil)
    run(1000)
    ok("flood: a timer ends a pending transfer nobody finishes", R["Flood2-Realm"] == nil, count(R))
    -- a complete scan that stores nothing (the layer stays full of newer prices) reports nothing
    for i = 1, 60000 do H.t[9000000 + i] = math.floor(W.time) + 300 end
    local before = c.db.syncFrom
    local said = #chat
    to("H1,123458," .. math.floor(W.time) .. ",2,1", "Honest-Realm")
    to("D123458,1," .. Y.encode({ p = { [5] = 10, [6] = 11 }, q = {} })[1], "Honest-Realm")
    ok("nothing stored: no 'prices updated' message and the sender is not recorded", c.db.syncFrom == before and #chat == said and H.p[5] == nil, tostring(c.db.syncFrom) .. " " .. (#chat - said))
    W.guild = true
end

-- ---- guild-received prices never enter your own daily history
do
    local c = client("ProbeHist")
    cur = c
    W.guild = false
    local t0 = math.floor(W.time)
    local function to(msg) fire(c, "CHAT_MSG_ADDON", "AHProfit", msg, "GUILD", "Guildmate-Realm", "", 0, 0, "", 0) end
    local ch, n = c.ns.sync.encode({ p = { [4242] = 99, [4243] = 98 }, q = { [4242] = 1, [4243] = 1 } })
    to("H1,135791," .. t0 .. "," .. n .. "," .. #ch)
    for i, p in ipairs(ch) do to("D135791," .. i .. "," .. p) end
    ok("guild scan received", G(c).p[4242] == 99)
    run(5)
    fire(c, "PLAYER_LOGOUT")
    local hist = c.db.hist or {}
    local any = false
    for _, H in pairs(hist) do if H[4242] or H[4243] then any = true end end
    ok("guild-received prices never enter your own daily history", not any and c.ns.histOwn and #c.ns.histOwn(4242) == 0)
    W.guild = true
end

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
-- ---- saved shared layer: versioned, checked at load, capped
do
    local function boot(saved)
        local c2 = { name = "Boot", frames = {}, prefix = {}, ns = {}, guild = false }
        cur = c2; AHProfitDB = saved
        for _, f in ipairs({ "Core.lua", "Sync.lua" }) do assert(loadfile("AHProfit/" .. f))("AHProfit", c2.ns) end
        fire(c2, "ADDON_LOADED", "AHProfit")
        return c2, AHProfitDB
    end
    local _, db = boot({ live = { ["Realm|Alliance"] = { p = { [9] = 5 }, q = { [9] = 1 }, t = { [9] = 1 }, full = 0 } } })
    ok("old save: shared layer created, version set, own scans kept", db.v == 2 and type(db.shared) == "table" and db.live["Realm|Alliance"].p[9] == 5)
    local c3, db3 = boot({ v = 1, shared = { ["Realm|Alliance"] = { p = { [7] = "x", [8] = 3 }, q = { [8] = 1 }, t = { [8] = math.floor(W.time) }, full = "no", from = 7 }, junk = 5 } })
    local H3 = db3.shared["Realm|Alliance"]
    ok("malformed shared layer repaired at load", H3 and H3.full == 0 and H3.p[7] == nil and H3.p[8] == 3 and type(H3.from) == "table", H3 and tostring(H3.full))
    local many = { v = 1, shared = {} }
    for i = 1, 12 do many.shared["Realm" .. i .. "|Alliance"] = { p = {}, q = {}, t = {}, full = i, from = {} } end
    local _, db4 = boot(many)
    local n4 = 0; for _ in pairs(db4.shared) do n4 = n4 + 1 end
    ok("at most 8 auction houses kept, the most recent ones", n4 == 8 and db4.shared["Realm12|Alliance"] and not db4.shared["Realm1|Alliance"], n4)
    local _, db5 = boot({ v = 3, shared = { x = 1 } })
    ok("a save from a newer version is left alone", db5.v == 3 and db5.shared.x == 1)
    -- S2 / B1 at load: prices older than 12 h and sender names no stored price uses are dropped
    local nowL = math.floor(W.time)
    local _, db6 = boot({ v = 1, shared = { ["Realm|Alliance"] = { p = { [1] = 5, [2] = 6 }, q = { [1] = 1, [2] = 1 }, t = { [1] = nowL - 43201, [2] = nowL - 60 }, full = nowL - 43201,
        from = { [nowL - 43201] = "Old", [nowL - 60] = "Recent", [nowL - 30] = "Unused" } } } })
    local H6 = db6.shared and db6.shared["Realm|Alliance"]
    ok("load: shared prices older than 12 h dropped, recent kept", H6 and H6.p[1] == nil and H6.p[2] == 6, H6 and tostring(H6.p[1]))
    ok("load: only sender names of stored prices are kept", H6 and H6.from[nowL - 60] == "Recent" and H6.from[nowL - 43201] == nil and H6.from[nowL - 30] == nil)
    -- N6: with a save from a newer version, received prices are neither stored nor shown
    local c7, db7 = boot({ v = 9, shared = { x = 1 } })
    local tN = math.floor(W.time)
    c7.ns.sync.receive("AHProfit", "H1,424242," .. tN .. ",1,1", "GUILD", "Guildmate-Realm")
    c7.ns.sync.receive("AHProfit", "D424242,1,3E1", "GUILD", "Guildmate-Realm")
    cur = c7
    ok("N6: a newer save: received prices are not shown and its data is untouched", c7.ns.lookup(3) == nil and db7.shared.x == 1 and db7.v == 9)
end
print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
