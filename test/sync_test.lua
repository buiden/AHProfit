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
        W.log[#W.log + 1] = { from = cur.name, msg = msg, at = W.time }
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
run(11); ok("no request before the delay", count("Q") + count("A") == 0)
run(2); ok("request sent after login", count("A", "Saad") == 1)
run(300)
ok("exactly one member answered", count("H") == 1, count("H"))
ok("late player has the prices", G(d).full == L(c).full and G(d).p[1003] == 51)
ok("only the member who scanned answers; received scans are not passed on", count("H", "Tareq") == 1)
W.log = {}; local e = client("Nasser"); L(e).full = math.floor(W.time); run(60)
ok("nobody answers a player who is already newer", count("A", "Nasser") == 1 and count("H") == 0)
L(e).full = 0

-- ---- switches
W.log = {}; cur = a; a.slash("sync off")
W.time = W.time + 1000; scan(a, res); run(200)
ok("sync off: nothing sent", count("H", "Abdullah") + count("D", "Abdullah") + count("Q", "Abdullah") == 0 and a.db.sync == false)   -- others' hourly asks may appear
a.slash("sync on"); cur = a; a.slash("share"); run(200)
ok("/ahp share sends the last scan", count("H", "Abdullah") == 1 and G(b).full == L(a).full and G(b).p[1003] == 137)
W.log = {}; cur = b; b.slash("sync off"); W.time = W.time + 1000; scan(a, res2); run(200)
ok("sync off: nothing received", G(b).p[1003] == 137)
b.slash("sync on")
W.log = {}; a.guild = false; W.time = W.time + 1000; scan(a, res); run(200); cur = a; a.slash("share")
ok("not in a guild: nothing sent, clear message", count("H", "Abdullah") + count("D", "Abdullah") == 0 and chat[#chat]:find("not in a guild", 1, true), chat[#chat]); a.guild = true
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
    local updated = 0
    for i = said + 1, #chat do if chat[i]:find("prices updated", 1, true) then updated = updated + 1 end end
    ok("nothing stored: no 'prices updated' message and the sender is not recorded", c.db.syncFrom == before and updated == 0 and H.p[5] == nil, tostring(c.db.syncFrom) .. " " .. updated)
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
    ok("old save: shared layer created, version set, own scans kept", db.v == 3 and type(db.shared) == "table" and db.live["Realm|Alliance"].p[9] == 5)
    local c3, db3 = boot({ v = 1, shared = { ["Realm|Alliance"] = { p = { [7] = "x", [8] = 3 }, q = { [8] = 1 }, t = { [8] = math.floor(W.time) }, full = "no", from = 7 }, junk = 5 } })
    local H3 = db3.shared["Realm|Alliance"]
    ok("malformed shared layer repaired at load", H3 and H3.full == 0 and H3.p[7] == nil and H3.p[8] == 3 and type(H3.from) == "table", H3 and tostring(H3.full))
    local many = { v = 1, shared = {} }
    for i = 1, 12 do many.shared["Realm" .. i .. "|Alliance"] = { p = {}, q = {}, t = {}, full = i, from = {} } end
    local _, db4 = boot(many)
    local n4 = 0; for _ in pairs(db4.shared) do n4 = n4 + 1 end
    ok("at most 8 auction houses kept, the most recent ones", n4 == 8 and db4.shared["Realm12|Alliance"] and not db4.shared["Realm1|Alliance"], n4)
    local _, db5 = boot({ v = 4, shared = { x = 1 } })
    ok("a save from a newer version is left alone", db5.v == 4 and db5.shared.x == 1)
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
-- ---- PR-G: ask again (hourly, after a cut by expiry or by reload), answer at most once per 10 min
do
    for _, cl in ipairs(clients) do cl.guild = false end           -- earlier members leave: only the ones below talk
    W.guild, W.drop, W.fail, W.lockdown = true, nil, 0, false
    local function up(f, name)
        for i = 1, 200 do
            local k, v = debug.getupvalue(f, i)
            if k == nil then break end
            if k == name then return v end
        end
        error("upvalue " .. name)
    end
    local function since(kind, from, t0)
        local n = 0
        for _, m in ipairs(W.log) do if m.msg:sub(1, 1) == kind and m.from == from and m.at >= t0 then n = n + 1 end end
        return n
    end
    local function times(kind, from, t0)
        local o = {}
        for _, m in ipairs(W.log) do if m.msg:sub(1, 1) == kind and m.from == from and m.at >= t0 then o[#o + 1] = m.at end end
        return o
    end
    local function said(who, pat, c0)
        local n = 0
        for i = c0 + 1, #chat do if chat[i]:find(who .. ": ", 1, true) == 1 and chat[i]:find(pat, 1, true) then n = n + 1 end end
        return n
    end
    local big = {}
    for i = 1, 400 do big[i] = R(30000 + i * 3, 200 + i, 1) end

    -- hourly ask: once per period, 55-65 min apart, one tiny message; nobody answers when nothing is newer
    W.log = {}
    local t0 = W.time
    local own = client("Owner"); scan(own, big); run(60)             -- Owner's scan, shared at once
    local tlog = W.time
    local m = client("Member")
    run(13)
    ok("PR-G: member asks at login (12 s)", since("A", "Member", t0) == 1)
    run(300)
    ok("PR-G: the owner answers the login ask once", since("H", "Owner", tlog) == 1 and G(m).full == L(own).full, since("H", "Owner", tlog))
    local tq = W.time
    run(20 * 3600)
    local ts = times("A", "Member", tq)
    local okGap, lo, hi = true, 1e9, 0
    for i = 2, #ts do local g = ts[i] - ts[i - 1]; lo, hi = math.min(lo, g), math.max(hi, g); if g < 3300 or g > 3900 then okGap = false end end
    ok("PR-G: hourly ask, about 20 in 20 h", #ts >= 18 and #ts <= 22, #ts)
    ok("PR-G: hourly asks 55-65 min apart, with jitter", okGap and hi > lo, lo .. ".." .. hi)
    ok("PR-G: nobody answers an hourly ask when nothing is newer", since("H", "Owner", tq) == 0, since("H", "Owner", tq))
    cur = m; local st = m.ns.sync.status()
    ok("PR-G: status gives the next check", st:find("Next check for newer guild prices in ~%d+m%.") ~= nil, st)

    -- skipped while receiving, while sending, within 10 min of an ask, with sync off, outside a guild
    local Ym = m.ns.sync
    local function upOr(f, name) local okU, v = pcall(up, f, name); return okU and v or nil end   -- nil on versions without it
    local function toNext() cur = m; local n = upOr(Ym.status, "nextCheck"); return n and (n - W.time) or 3600 end
    -- receiving: a transfer from someone else is under way at the check
    run(toNext() - 5); local tr = W.time
    fire(m, "CHAT_MSG_ADDON", "AHProfit", "H1,616161," .. math.floor(W.time) .. ",5,3", "GUILD", "Busy-Realm", "", 0, 0, "", 0)
    fire(m, "CHAT_MSG_ADDON", "AHProfit", "D616161,1,3E1", "GUILD", "Busy-Realm", "", 0, 0, "", 0)
    run(10)
    ok("PR-G: no hourly ask while a transfer is coming in", since("A", "Member", tr) == 0, since("A", "Member", tr))
    run(1000)                                                    -- the Busy transfer expires (cut): one re-ask
    -- sending: Member's own broadcast is running at the check
    local mine = {}
    for i = 1, 3000 do mine[i] = R(40000 + i * 7, 300 + i, 2) end
    run(toNext() - 20)
    scan(m, mine); local tsend = W.time
    cur = m; ok("PR-G: member is sending", upOr(Ym.status, "out") ~= nil)
    run(40)
    ok("PR-G: no hourly ask while sending", since("A", "Member", tsend) == 0, since("A", "Member", tsend))
    run(300)
    -- within 10 min of the last ask
    run(toNext() - 300); cur = m; Ym.ask(); local tm = W.time
    run(310)
    ok("PR-G: no hourly ask within 10 min of the last one", since("A", "Member", tm) == 1, since("A", "Member", tm))
    -- sync off, then not in a guild: nothing, but the timer keeps going
    cur = m; m.slash("sync off"); local toff = W.time
    run(toNext() + 5)
    ok("PR-G: no hourly ask with sync off", since("A", "Member", toff) == 0)
    cur = m; m.slash("sync on"); m.guild = false; local tng = W.time
    run(toNext() + 5)
    ok("PR-G: no hourly ask outside a guild", since("A", "Member", tng) == 0)
    m.guild = true; local tback = W.time
    run(toNext() + 5)
    ok("PR-G: hourly ask resumes afterwards", since("A", "Member", tback) == 1, since("A", "Member", tback))

    -- cut by expiry: one line, one re-ask 30-40 s later, the next complete transfer succeeds
    local own2 = client("Seller"); local m2 = client("Buyer")
    run(400)
    for _, cl in ipairs({ own, m }) do cl.guild = false end
    local res3 = {}
    for i = 1, 400 do res3[i] = R(50000 + i * 3, 900 + i, 1) end
    local c0 = #chat
    W.drop = function(msg) local s = msg:match("^D%d+,(%d+),"); return s and tonumber(s) >= 3 end
    scan(own2, res3); run(60); W.drop = nil
    ok("PR-G: receiving line once when the header is accepted", said("Buyer", "receiving prices from Seller's scan (about 400 items)...", c0) == 1, said("Buyer", "receiving", c0))
    local got = 0; for _, t in pairs(G(m2).t) do if t == L(own2).full then got = got + 1 end end
    ok("PR-G: part of the scan arrived, not complete", got > 0 and got < 400 and G(m2).full < L(own2).full, got)
    local tcut = W.time
    run(900 - 60 + 4)
    ok("PR-G: no re-ask before the transfer expires", since("A", "Buyer", tcut) == 0)
    run(2)                                                       -- the expiry timer (header + 905 s)
    ok("PR-G: cut line once, with counts", said("Buyer", "Seller's prices were cut off (" .. got .. " of 400); asking the guild again.", c0) == 1, chat[#chat])
    cur = m2; local st2 = m2.ns.sync.status()
    ok("PR-G: status names the cut transfer", st2:find("Last transfer from Seller was cut (" .. got .. " of 400).", 1, true) ~= nil, st2)
    local texp = W.time
    run(29); ok("PR-G: re-ask waits 30 s", since("A", "Buyer", texp) == 0)
    run(12); ok("PR-G: one re-ask 30-40 s after the cut", since("A", "Buyer", texp) == 1, since("A", "Buyer", texp))
    run(300)
    ok("PR-G: the owner answers and the scan completes", G(m2).full == L(own2).full and said("Buyer", "prices updated from Seller's scan", c0) == 1, G(m2).full - L(own2).full)
    ok("PR-G: re-ask only once per cut", since("A", "Buyer", texp) == 1, since("A", "Buyer", texp))
    cur = m2; ok("PR-G: a complete scan clears the cut from status", not m2.ns.sync.status():find("was cut", 1, true))
    ok("PR-G: lines appear once each", said("Buyer", "receiving prices from Seller", c0) == 2 and said("Buyer", "cut off", c0) == 1, said("Buyer", "receiving", c0))

    -- cut by reload: the save holds shared prices newer than the last complete scan; one line, one ask at 30-40 s
    run(700)                                                     -- past Seller's 10-min answer limit
    local res4 = {}
    for i = 1, 400 do res4[i] = R(60000 + i * 3, 1900 + i, 1) end
    W.drop = function(msg) local s = msg:match("^D%d+,(%d+),"); return s and tonumber(s) >= 3 end
    scan(own2, res4); run(20); W.drop = nil
    local held = 0; for _, t in pairs(G(m2).t) do if t > G(m2).full then held = held + 1 end end
    ok("PR-G: before the reload, newer partial prices are held", held > 0, held)
    m2.guild = false                                             -- /reload: the old session's memory is gone
    local m3 = { name = "Buyer", frames = {}, prefix = {}, ns = {}, guild = true }
    clients[#clients + 1] = m3
    cur = m3; AHProfitDB = m2.db
    for _, f in ipairs({ "Core.lua", "Sync.lua" }) do assert(loadfile("AHProfit/" .. f))("AHProfit", m3.ns) end
    local c1, tl = #chat, W.time
    fire(m3, "ADDON_LOADED", "AHProfit"); m3.db = AHProfitDB; m3.slash = SlashCmdList.AHPROFIT
    fire(m3, "PLAYER_LOGIN")
    ok("PR-G: reload cut detected at login, one line", said("Buyer", "the last price transfer from Seller (" .. held .. " items) was cut by a reload; asking the guild again.", c1) == 1, chat[#chat])
    run(13); ok("PR-G: no extra ask at 12 s after a reload cut", since("A", "Buyer", tl) == 0, since("A", "Buyer", tl))
    run(30); ok("PR-G: one ask 30-40 s after login", since("A", "Buyer", tl) == 1, since("A", "Buyer", tl))
    run(300)
    ok("PR-G: the reload cut is filled in", G(m3).full == L(own2).full and since("A", "Buyer", tl) == 1, G(m3).full - L(own2).full)
    local c2 = #chat
    m3.guild = false
    local m4 = { name = "Buyer", frames = {}, prefix = {}, ns = {}, guild = true }
    clients[#clients + 1] = m4
    cur = m4; AHProfitDB = m3.db
    for _, f in ipairs({ "Core.lua", "Sync.lua" }) do assert(loadfile("AHProfit/" .. f))("AHProfit", m4.ns) end
    fire(m4, "ADDON_LOADED", "AHProfit"); fire(m4, "PLAYER_LOGIN")
    local tl2 = W.time; run(13)
    ok("PR-G: a normal login has no cut line and asks at 12 s", said("Buyer", "cut by a reload", c2) == 0 and since("A", "Buyer", tl2) == 1)
    m4.guild = false

    -- answer limit: five asks within 10 min, one broadcast; an ask after 10 min is answered
    local own3 = client("Banker"); scan(own3, big); run(120)
    own2.guild = false
    run(700)
    local ta = W.time
    for i = 1, 5 do
        fire(own3, "CHAT_MSG_ADDON", "AHProfit", "Q1,0", "GUILD", "Asker" .. i .. "-Realm", "", 0, 0, "", 0)
        run(110)
    end
    run(40)
    ok("PR-G: five asks within 10 min, one broadcast", since("H", "Banker", ta) == 1, since("H", "Banker", ta))
    run(30)                                                      -- now past 10 min since the answer
    local tb = W.time
    fire(own3, "CHAT_MSG_ADDON", "AHProfit", "Q1,0", "GUILD", "Asker6-Realm", "", 0, 0, "", 0); run(30)
    ok("PR-G: an ask after 10 min is answered", since("H", "Banker", tb) == 1, since("H", "Banker", tb))
    -- an ask during a running broadcast is served, but not before the 10 min are up
    local huge = {}
    for i = 1, 3000 do huge[i] = R(70000 + i * 7, 500 + i, 1) end
    run(700); scan(own3, huge); run(5)
    local tc = W.time
    fire(own3, "CHAT_MSG_ADDON", "AHProfit", "Q1,0", "GUILD", "Late-Realm", "", 0, 0, "", 0)
    run(60)
    ok("PR-G: an ask during a broadcast is not answered at once", since("H", "Banker", tc) == 0, since("H", "Banker", tc))
    run(600)
    ok("PR-G: ...it is answered once, 10 min after the last answer", since("H", "Banker", tc) == 1, since("H", "Banker", tc))
    -- the existing rule: no answer when the scan is not newer than the asker's, or more than 12 h old
    local td = W.time
    fire(own3, "CHAT_MSG_ADDON", "AHProfit", "Q1," .. L(own3).full, "GUILD", "Equal-Realm", "", 0, 0, "", 0); run(700)
    ok("PR-G: no answer when the scan is not newer", since("H", "Banker", td) == 0)
    run(12 * 3600)
    local te = W.time
    fire(own3, "CHAT_MSG_ADDON", "AHProfit", "Q1,0", "GUILD", "Old-Realm", "", 0, 0, "", 0); run(60)
    ok("PR-G: no answer when the scan is over 12 h old", since("H", "Banker", te) == 0)
    own3.guild = false

    -- ask / offer / pick: the newest scan is picked, equal times go to the lowest name
    local function offline(name) local cl = client(name); cl.guild = false; run(13); return cl end
    local function prices(base) local r = {} for i = 1, 300 do r[i] = R(80000 + i * 3, base + i, 1) end return r end
    local o300, o40, o5 = offline("Old300"), offline("Mid40"), offline("New5")
    scan(o300, prices(1000)); run(260 * 60 - 1.5)
    scan(o40, prices(2000)); run(35 * 60 - 1.5)
    scan(o5, prices(3000)); run(5 * 60 - 1.5)
    local ask = offline("Asker")
    cur = o300; local age300 = (W.time - L(o300).full) / 60
    cur = o40; local age40 = (W.time - L(o40).full) / 60
    cur = o5; local age5 = (W.time - L(o5).full) / 60
    ok("PR-G order: scans are about 300, 40 and 5 min old", math.abs(age300 - 300) < 1 and math.abs(age40 - 40) < 1 and math.abs(age5 - 5) < 1, age300 .. " " .. age40 .. " " .. age5)
    for _, cl in ipairs({ o300, o40, o5, ask }) do cl.guild = true end
    local tn = W.time
    cur = ask; ask.ns.sync.ask(); run(120)
    ok("PR-G order: only the newest owner (5 min) broadcasts", since("H", "New5", tn) == 1 and since("H", "Mid40", tn) == 0 and since("H", "Old300", tn) == 0,
        since("H", "New5", tn) .. " " .. since("H", "Mid40", tn) .. " " .. since("H", "Old300", tn))
    ok("PR-G order: the asker has the newest scan", G(ask).full == L(o5).full and G(ask).p[80003] == 3001)
    ok("PR-G order: the older owners took the newer scan as guild prices", G(o40).full == L(o5).full and G(o300).full == L(o5).full)
    for _, cl in ipairs({ o300, o40, o5, ask }) do cl.guild = false end
    -- two owners with scans of the same age: at most one broadcast
    local e1, e2 = offline("EqualA"), offline("EqualB")
    scan(e1, prices(4000)); scan(e2, prices(5000))
    cur = e2; L(e2).full = (function() cur = e1; return L(e1).full end)()
    run(20 * 60)
    local ask2 = offline("Asker2")
    for _, cl in ipairs({ e1, e2, ask2 }) do cl.guild = true end
    local tq2 = W.time
    cur = ask2; ask2.ns.sync.ask(); run(120)
    local nH = since("H", "EqualA", tq2) + since("H", "EqualB", tq2)
    cur = e1; local tE = L(e1).full
    ok("PR-G order: equally old scans, one broadcast", nH == 1, nH)
    ok("PR-G order: the asker has that scan", G(ask2).full == tE)
    for _, cl in ipairs({ e1, e2, ask2 }) do cl.guild = false end
    -- either way the receiver keeps only the newest: two owners both send (older one first)
    run(11 * 60)
    local f1, f2, rx = offline("FirstOld"), offline("SecondNew"), offline("Receiver")
    scan(f1, prices(6000)); run(60); scan(f2, prices(7000))
    for _, cl in ipairs({ f1, f2, rx }) do cl.guild = true end
    cur = f1; f1.ns.sync.broadcast(true); run(1)
    cur = f2; f2.ns.sync.broadcast(true); run(120)
    cur = f2; local tNew = L(f2).full
    ok("PR-G order: two broadcasts, the receiver keeps the newest scan only", G(rx).full == tNew and G(rx).p[80003] == 7001 and G(rx).t[80003] == tNew, tostring(G(rx).p[80003]))
    cur = f1; f1.ns.sync.broadcast(true); run(120)
    ok("PR-G order: an older scan arriving later changes nothing", G(rx).full == tNew and G(rx).p[80003] == 7001)
    for _, cl in ipairs({ f1, f2, rx }) do cl.guild = false end
    -- equal scan time: the lowest name is picked
    run(11 * 60)
    local zb, za, ask3 = offline("Zulu"), offline("Alpha"), offline("Asker3")
    scan(zb, prices(8000)); scan(za, prices(9000))
    cur = za; local tz = L(za).full; cur = zb; L(zb).full = tz
    for _, cl in ipairs({ zb, za, ask3 }) do cl.guild = true end
    local tq3 = W.time
    cur = ask3; ask3.ns.sync.ask(); run(120)
    ok("PR-G pick: both owners offered", since("O", "Zulu", tq3) == 1 and since("O", "Alpha", tq3) == 1)
    ok("PR-G pick: equal times, the lowest name is picked and sends", since("H", "Alpha", tq3) == 1 and since("H", "Zulu", tq3) == 0, since("H", "Alpha", tq3) .. " " .. since("H", "Zulu", tq3))
    cur = ask3; local st3 = ask3.ns.sync.status()
    ok("PR-G pick: status lists the offers heard", st3:find("Guild prices available: Alpha %d+m %(300 items%), Zulu %d+m %(300 items%)%.") ~= nil, st3)
    for _, cl in ipairs({ zb, za, ask3 }) do cl.guild = false end
    -- two askers in the same second: one broadcast
    run(11 * 60)
    local ow, a1, a2 = offline("Holder"), offline("AskOne"), offline("AskTwo")
    scan(ow, prices(9500))
    for _, cl in ipairs({ ow, a1, a2 }) do cl.guild = true end
    local tt = W.time
    cur = a1; a1.ns.sync.ask(); cur = a2; a2.ns.sync.ask(); run(120)
    ok("PR-G pick: two askers in the same second, one offer and one broadcast", since("O", "Holder", tt) == 1 and since("H", "Holder", tt) == 1 and since("P", "AskOne", tt) == 1 and since("P", "AskTwo", tt) == 1,
        since("O", "Holder", tt) .. " " .. since("H", "Holder", tt))
    ok("PR-G pick: both askers have the scan", G(a1).full == L(ow).full and G(a2).full == L(ow).full)
    run(700)
    ok("PR-G pick: and no second broadcast 10 min later (both were in the round)", since("H", "Holder", tt) == 1, since("H", "Holder", tt))
    -- a pick naming someone else, or a scan time that is not the owner's current one, is ignored
    local tp = W.time
    fire(ow, "CHAT_MSG_ADDON", "AHProfit", "P1,Someone," .. L(ow).full, "GUILD", "Picker-Realm", "", 0, 0, "", 0)
    fire(ow, "CHAT_MSG_ADDON", "AHProfit", "P1,Holder," .. (L(ow).full - 60), "GUILD", "Picker-Realm", "", 0, 0, "", 0)
    run(30)
    ok("PR-G pick: a pick for someone else or for a stale scan time is ignored", since("H", "Holder", tp) == 0, since("H", "Holder", tp))
    -- a pick within 10 min of an answer is ignored; a pick while sending is served once the 10 min are up
    fire(ow, "CHAT_MSG_ADDON", "AHProfit", "P1,Holder," .. L(ow).full, "GUILD", "Picker-Realm", "", 0, 0, "", 0); run(30)
    local tr2 = W.time
    fire(ow, "CHAT_MSG_ADDON", "AHProfit", "P1,Holder," .. L(ow).full, "GUILD", "Picker2-Realm", "", 0, 0, "", 0); run(300)
    ok("PR-G pick: a repeat pick within 10 min is ignored", since("H", "Holder", tp) == 1 and since("H", "Holder", tr2) == 0, since("H", "Holder", tp))
    local hugeP = {}
    for i = 1, 3000 do hugeP[i] = R(90000 + i * 7, 700 + i, 1) end
    run(700); ow.guild = false; scan(ow, hugeP); ow.guild = true
    fire(ow, "CHAT_MSG_ADDON", "AHProfit", "P1,Holder," .. L(ow).full, "GUILD", "Picker3-Realm", "", 0, 0, "", 0); run(5)
    local ts2 = W.time
    fire(ow, "CHAT_MSG_ADDON", "AHProfit", "A1,0", "GUILD", "Picker4-Realm", "", 0, 0, "", 0)          -- asked after the start
    fire(ow, "CHAT_MSG_ADDON", "AHProfit", "P1,Holder," .. L(ow).full, "GUILD", "Picker4-Realm", "", 0, 0, "", 0)
    run(200)
    ok("PR-G pick: a pick while sending is not served at once", since("H", "Holder", ts2) == 0)
    run(500)
    ok("PR-G pick: ...it is served once 10 min after the answer", since("H", "Holder", ts2) == 1, since("H", "Holder", ts2))
    -- the live case: a reload in the middle of a large broadcast (shared after a scan); the re-ask at login comes
    -- while the owner is still sending, so it is sent again right after (no answer in the last 10 min)
    run(700)
    local big2, viewer = offline("BigOwner"), offline("Viewer")
    local bigP = {}
    for i = 1, 3000 do bigP[i] = R(110000 + i * 7, 900 + i, 1) end
    big2.guild, viewer.guild = true, true
    scan(big2, bigP); run(18)                                     -- 18 s into the transfer
    local heldV = 0; for _, t in pairs(G(viewer).t) do if t > G(viewer).full then heldV = heldV + 1 end end
    ok("PR-G live: part of the scan arrived before the reload", heldV > 0 and heldV < 3000, heldV)
    viewer.guild = false
    local v2 = { name = "Viewer", frames = {}, prefix = {}, ns = {}, guild = true }
    clients[#clients + 1] = v2
    cur = v2; AHProfitDB = viewer.db
    for _, f in ipairs({ "Core.lua", "Sync.lua" }) do assert(loadfile("AHProfit/" .. f))("AHProfit", v2.ns) end
    fire(v2, "ADDON_LOADED", "AHProfit"); fire(v2, "PLAYER_LOGIN")
    local tv = W.time
    run(45)
    cur = big2; ok("PR-G live: the re-ask and pick arrive while the owner is still sending", since("P", "Viewer", tv) == 1 and big2.ns.sync.status():find("Sending your scan now", 1, true) ~= nil)
    run(400)
    ok("PR-G live: the owner sends once more after finishing, and the reloaded member has the whole scan", since("H", "BigOwner", tv) == 1 and G(v2).full == L(big2).full, since("H", "BigOwner", tv))
    big2.guild, v2.guild = false, false
    -- no offer when the scan is not newer than the asker's, or more than 12 h old
    ow.guild = true
    run(700); local tn0 = W.time
    cur = ow; local tow = L(ow).full
    fire(ow, "CHAT_MSG_ADDON", "AHProfit", "A1," .. tow, "GUILD", "Equal-Realm", "", 0, 0, "", 0); run(30)
    ok("PR-G offer: none when the scan is not newer than the asker's", since("O", "Holder", tn0) == 0)
    fire(ow, "CHAT_MSG_ADDON", "AHProfit", "A1," .. (tow - 1), "GUILD", "Older-Realm", "", 0, 0, "", 0); run(30)
    ok("PR-G offer: one when it is newer (control)", since("O", "Holder", tn0) == 1)
    run(12 * 3600 + 60); local t12 = W.time
    fire(ow, "CHAT_MSG_ADDON", "AHProfit", "A1,0", "GUILD", "Late-Realm", "", 0, 0, "", 0); run(30)
    ok("PR-G offer: none when the scan is more than 12 h old", since("O", "Holder", t12) == 0)
    -- unknown kinds are ignored without an error and without a reply
    local tu = W.time
    local okU = pcall(function()
        for _, msg in ipairs({ "Z1,5", "X", "A9,5", "O1,5", "O1," .. math.floor(W.time) .. ",0", "P1,,5", "P1," .. string.rep("N", 80) .. ",5" }) do
            fire(ow, "CHAT_MSG_ADDON", "AHProfit", msg, "GUILD", "Future-Realm", "", 0, 0, "", 0)
        end
    end)
    run(30)
    ok("PR-G: unknown or malformed kinds are ignored without an error or a reply", okU and since("H", "Holder", tu) + since("O", "Holder", tu) == 0)
    ow.guild = false
end
print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
