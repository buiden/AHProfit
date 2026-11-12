-- AH Profit guild sync: when one player finishes a full auction house scan, the prices go to every guild member
-- running the addon over the hidden addon channel, so nobody else needs to scan or reload.
-- Received prices go into a separate shared layer (ns.shared, see Core.lua): they never change or delete your own
-- scans, and only your own full scan is ever sent on. A scan time more than 5 minutes ahead or more than 12 hours
-- behind your clock is refused, so a wrong clock cannot replace good prices or block later ones.
-- Messages (each at most 255 bytes, plain text):
--   H<ver>,<session>,<scan time>,<items>,<chunks>     start of a scan
--   D<session>,<chunk number>,<payload>               items: id step, price, quantity as base-32 digits
--   Q<ver>,<newest prices I have>                     sent at login; one member with newer prices answers
--   G<ver>,<map>,<node>,<x>,<y>,<time>                one gathering node a member just picked (x, y in 1/1000 of the map)
--   R<ver>,<nodes I know>                             sent at login; one member who knows more sends the newest ones
local _, ns = ...
local Y = {}
ns.sync = Y
local PFX, VER, MAXLEN, GAP = "AHProfit", 1, 238, 1.05
local AHEAD, BEHIND = 300, 43200           -- accepted scan times: up to 5 min in the future, up to 12 h old
Y.MAXITEMS = 60000                         -- hard cap on items kept in one house's shared layer
local held = setmetatable({}, { __mode = "k" })   -- shared layer -> item count, recounted for every accepted scan
local A = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+/"
local DEC = {}
for i = 1, 64 do DEC[A:byte(i)] = i - 1 end

local function secret(v) return issecretvalue ~= nil and issecretvalue(v) end
local function on() local DB = ns.db(); return DB and DB.sync ~= false end
local function whole(v, max) return type(v) == "number" and v >= 0 and v <= max and v == math.floor(v) end

-- ---------------------------------------------------------------------------------------------------- encoding --
local function put(buf, v)
    while v >= 32 do
        local d = v % 32
        buf[#buf + 1] = A:sub(d + 33, d + 33)
        v = (v - d) / 32
    end
    buf[#buf + 1] = A:sub(v + 1, v + 1)
end
local function item(prev, id, p, q)
    local b = {}
    put(b, id - prev); put(b, p); put(b, q)
    return table.concat(b)
end
-- Returns the chunk payloads and the number of items in them.
function Y.encode(L)
    local ids = {}
    for id, p in pairs(L.p) do
        if whole(id, 1e7) and id > 0 and whole(p, 1e12) and p > 0 then ids[#ids + 1] = id end
    end
    table.sort(ids)
    local chunks, cur, len, prev = {}, {}, 0, 0
    for i = 1, #ids do
        local id = ids[i]
        local q = L.q[id]
        if not whole(q, 1e9) then q = 0 end
        local s = item(prev, id, L.p[id], q)
        if len + #s > MAXLEN then
            chunks[#chunks + 1] = table.concat(cur)
            cur, len = {}, 0
            s = item(0, id, L.p[id], q)
        end
        cur[#cur + 1] = s; len = len + #s; prev = id
    end
    if len > 0 then chunks[#chunks + 1] = table.concat(cur) end
    return chunks, #ids
end
local function read(s, i, n)
    local v, mult = 0, 1
    while true do
        if i > n or mult > 1099511627776 then return nil end
        local c = DEC[s:byte(i)]
        if not c then return nil end
        i = i + 1
        if c >= 32 then v = v + (c - 32) * mult; mult = mult * 32
        else return v + c * mult, i end
    end
end
-- Returns a flat list id, price, quantity, ... or nil when anything about the payload is wrong.
function Y.decode(s)
    local out, i, n, id = {}, 1, #s, 0
    local d, p, q
    while i <= n do
        d, i = read(s, i, n); if not d or d < 1 then return nil end
        p, i = read(s, i, n); if not p or p < 1 or p > 1e12 then return nil end
        q, i = read(s, i, n); if not q or q > 1e9 then return nil end
        id = id + d
        if id > 1e7 then return nil end
        out[#out + 1] = id; out[#out + 1] = p; out[#out + 1] = q
    end
    if #out == 0 then return nil end
    return out
end

-- ----------------------------------------------------------------------------------------------------- sending --
local out, again, pending = nil, false, nil
local function inGuild() return IsInGuild ~= nil and IsInGuild() and true or false end
-- true = sent; false = try again later.
local function send(msg)
    local CI = C_ChatInfo
    if not (CI and CI.SendAddonMessage) then return false end
    if CI.InChatMessagingLockdown and CI.InChatMessagingLockdown() then return false end
    local ok, r = pcall(CI.SendAddonMessage, PFX, msg, "GUILD")
    return ok and (r == true or r == 0)
end
local function pump(job)
    if out ~= job then return end
    if not on() or not inGuild() then out = nil; return end
    if send(job.msgs[job.i]) then
        job.i, job.fails = job.i + 1, 0
        if job.i > #job.msgs then
            out = nil
            ns.say("scan shared with your guild (" .. job.n .. " items).")
            if again then again = false; Y.broadcast(true) end
            return
        end
        C_Timer.After(GAP, function() pump(job) end)
    else
        job.fails = job.fails + 1
        if job.fails > 30 then out = nil; ns.say("could not share the scan with your guild; the game refused the messages."); return end
        C_Timer.After(5, function() pump(job) end)
    end
end
-- Sends this player's last full scan to the guild. quiet = no chat line when there is nothing to do.
function Y.broadcast(quiet)
    pending = nil
    if not on() then if not quiet then ns.say("guild sharing is off (/ahp sync on).") end return false end
    if not inGuild() then if not quiet then ns.say("you are not in a guild.") end return false end
    local L = ns.live()
    if L.full <= 0 then if not quiet then ns.say("no full scan to share yet.") end return false end
    local chunks, n = Y.encode(L)
    if n == 0 then return false end
    local sid = math.random(100000, 999999)
    local msgs = { "H" .. VER .. "," .. sid .. "," .. L.full .. "," .. n .. "," .. #chunks }
    for i = 1, #chunks do msgs[i + 1] = "D" .. sid .. "," .. i .. "," .. chunks[i] end
    out = { msgs = msgs, i = 1, fails = 0, n = n, t = L.full }
    again = false
    if not quiet then ns.say("sharing " .. n .. " prices with your guild, about " .. math.ceil(#msgs * GAP / 60) .. " min.") end
    pump(out)
    return true
end
function Y.ask()
    if not on() or not inGuild() then return end
    local L, H = ns.live(), ns.shared()
    send("Q" .. VER .. "," .. math.floor(math.max(L.full, H.full, ns.seed and ns.seed.t or 0)))
end

-- Gathering nodes go out one at a time, behind any price broadcast.
local nq, nbusy, nfail, npending = {}, false, 0, nil
local NODE_BATCH = 40
local function npump()
    if #nq == 0 or not on() or not inGuild() then nq, nbusy = {}, false; return end
    local wait = 5
    if not out then
        if send(nq[1]) then table.remove(nq, 1); nfail = 0; wait = GAP
        else
            nfail = nfail + 1
            if nfail > 20 then nq, nbusy, nfail = {}, false, 0; return end
        end
    end
    if #nq == 0 then nbusy = false; return end
    C_Timer.After(wait, npump)
end
function Y.node(map, h, x, y, t)
    if not on() or not inGuild() or #nq >= 120 then return false end
    nq[#nq + 1] = "G" .. VER .. "," .. map .. "," .. h .. "," .. x .. "," .. y .. "," .. t
    if not nbusy then nbusy = true; npump() end
    return true
end
function Y.askNodes()
    if not on() or not inGuild() or not ns.extra then return end
    send("R" .. VER .. "," .. ns.extra.nodeCount())
end
local function nodeRequest(have)
    local X = ns.extra
    if not X or X.nodeCount() <= have then return end
    local tok = {}
    npending = tok
    C_Timer.After(3 + math.random() * 9, function()
        if npending ~= tok then return end                       -- someone else answered first
        npending = nil
        local list = X.nodeList()
        for i = 1, math.min(NODE_BATCH, #list) do
            local n = list[i]
            Y.node(n[1], n[2], n[3], n[4], n[5])
        end
    end)
end
local function nodeSeen(sender, map, h, x, y, t)
    local X, now = ns.extra, ns.now()
    npending = nil
    if not X then return end
    if not (whole(map, 100000) and map > 0 and whole(h, 1000002) and whole(x, 1000) and x > 0 and whole(y, 1000) and y > 0) then return end
    if not (whole(t, now + 120) and t > now - 7776000) then return end      -- not from the future, not older than 90 days
    if not X.nodeName(h) then return end                         -- only nodes this addon knows by name
    local res = X.addNode(map, h, x, y, t, sender:match("^[^-]+"))
    X.shared(res == "new" and 1 or 0)
end

-- --------------------------------------------------------------------------------------------------- receiving --
local R = {}
local function mine(sender)
    local n, r = UnitName("player")
    if UnitFullName then n, r = UnitFullName("player") end
    if secret(n) or secret(r) or type(n) ~= "string" then return false end
    local sn, sr = sender:match("^([^-]+)-?(.*)$")
    return sn == n and (sr == "" or not r or r == "" or sr:gsub("[%s%-]", "") == r:gsub("[%s%-]", ""))
end
local function header(sender, ver, sid, t, n, chunks)
    if ver ~= VER or not ns.sharedOK() then return end          -- a save from a newer version: nothing received
    local now = ns.now()
    if not (whole(t, now + AHEAD) and t >= now - BEHIND and whole(n, 50000) and n > 0 and whole(chunks, 2000) and chunks > 0 and chunks <= n) then return end
    local L, H = ns.live(), ns.shared()
    if pending and t >= L.full then pending = nil end           -- someone else is already answering the request
    for k, r in pairs(R) do if now - r.at > 900 then R[k] = nil end end
    if t <= math.max(L.full, H.full) then return end            -- nothing newer than what is here
    held[H] = ns.pruneShared(H)                                  -- also drops entries older than 12 h
    R[sender] = { sid = sid, t = t, n = n, chunks = chunks, got = {}, count = 0, items = 0, seen = {}, at = now, stage = {} }
end
local function chunk(sender, sid, seq, payload)
    local r = R[sender]
    if not r or r.sid ~= sid or not whole(seq, r.chunks) or seq < 1 or r.got[seq] then return end
    local list = Y.decode(payload)
    if not list or r.items + #list / 3 > r.n then R[sender] = nil; return end
    r.got[seq] = true; r.count = r.count + 1
    local H, t, seen = ns.shared(), r.t, r.seen
    local n = held[H] or 0
    local name = sender:match("^[^-]+")
    H.from[t] = name
    for i = 1, #list, 3 do
        local id = list[i]
        if not seen[id] then seen[id] = true; r.items = r.items + 1 end
        if H.p[id] == nil and n >= Y.MAXITEMS then             -- full: kept aside until the scan is complete
            local st = r.stage
            st[#st + 1] = id; st[#st + 1] = list[i + 1]; st[#st + 1] = list[i + 2]
        elseif (H.t[id] or 0) < t then
            if H.p[id] == nil then n = n + 1 end
            H.p[id], H.q[id], H.t[id] = list[i + 1], list[i + 2], t
        end
    end
    held[H] = n
    if r.count < r.chunks then return end
    R[sender] = nil
    if r.items ~= r.n then return end                            -- incomplete: keep what arrived, forget nothing
    -- Complete and newer than the layer: it replaces the older entries (shared layer only; your own scans are never
    -- touched), so junk from unfinished transfers cannot hold the cap. Items kept aside at the cap go in now.
    for id, it in pairs(H.t) do
        if it < t and not seen[id] then H.p[id], H.q[id], H.t[id] = nil, nil, nil; held[H] = held[H] - 1 end
    end
    local st, complete = r.stage, true
    for i = 1, #st, 3 do
        local id = st[i]
        if H.p[id] == nil and held[H] >= Y.MAXITEMS then complete = false
        elseif (H.t[id] or 0) < t then
            if H.p[id] == nil then held[H] = held[H] + 1 end
            H.p[id], H.q[id], H.t[id] = st[i + 1], st[i + 2], t
        end
    end
    if complete and t > H.full then H.full = t end
    local used = {}
    for _, it in pairs(H.t) do used[it] = true end
    for k in pairs(H.from) do if not used[k] then H.from[k] = nil end end
    local DB = ns.db()
    DB.syncFrom, DB.syncAt = name, t
    ns.say("prices updated from " .. DB.syncFrom .. "'s scan (" .. ns.age(t) .. "), " .. r.n .. " items.")
end
local function request(have)
    if out then if out.t > have then again = true end return end
    local L = ns.live()
    if L.full <= have or ns.now() - L.full > 43200 then return end
    local tok = {}
    pending = tok
    -- Only your own scan is sent. When a guild member's newer scan is known here, its owner gets the first chance
    -- to answer (seeing their reply cancels this one).
    local wait = ns.shared().full > L.full and 12 or 2
    C_Timer.After(wait + math.random() * 8, function() if pending == tok and not out then Y.broadcast(true) end end)
end
function Y.receive(prefix, text, channel, sender)
    if secret(prefix) or secret(text) or secret(channel) or secret(sender) then return end
    if prefix ~= PFX or channel ~= "GUILD" or type(text) ~= "string" or type(sender) ~= "string" or #text > 255 then return end
    if not ns.db() or not on() or mine(sender) then return end
    local who = sender:match("^([^-]+)")
    if not who or #who > 64 then return end                     -- no usable sender name
    local k = text:sub(1, 1)
    if k == "D" then
        local sid, seq, payload = text:match("^D(%d%d%d%d%d%d),(%d%d?%d?%d?),([%w+/]+)$")
        if sid then chunk(sender, tonumber(sid), tonumber(seq), payload) end
    elseif k == "H" then
        local ver, sid, t, n, chunks = text:match("^H(%d%d?),(%d%d%d%d%d%d),(%d%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?),(%d%d?%d?%d?%d?),(%d%d?%d?%d?)$")
        if ver then header(sender, tonumber(ver), tonumber(sid), tonumber(t), tonumber(n), tonumber(chunks)) end
    elseif k == "Q" then
        local ver, have = text:match("^Q(%d%d?),(%d%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?)$")
        if ver and tonumber(ver) == VER then request(tonumber(have)) end
    elseif k == "G" then
        local ver, map, h, x, y, t = text:match("^G(%d%d?),(%d%d?%d?%d?%d?%d?),(%d%d?%d?%d?%d?%d?%d?),(%d%d?%d?%d?),(%d%d?%d?%d?),(%d%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?)$")
        if ver and tonumber(ver) == VER then nodeSeen(sender, tonumber(map), tonumber(h), tonumber(x), tonumber(y), tonumber(t)) end
    elseif k == "R" then
        local ver, have = text:match("^R(%d%d?),(%d%d?%d?%d?%d?%d?%d?)$")
        if ver and tonumber(ver) == VER then nodeRequest(tonumber(have)) end
    end
end
function Y.status()
    local DB = ns.db()
    if not on() then return "Guild sharing is off." end
    if not inGuild() then return "Guild sharing is on, but you are not in a guild." end
    local s = "Guild sharing is on."
    if out then s = s .. " Sending your scan now (" .. (out.i - 1) .. " of " .. #out.msgs .. " messages)." end
    if DB.syncFrom and DB.syncAt then s = s .. " Last received: " .. DB.syncFrom .. "'s scan, " .. ns.age(DB.syncAt) .. "." end
    return s
end

local f = CreateFrame("Frame")
f:Hide()
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(_, ev, ...)
    if ev == "CHAT_MSG_ADDON" then return Y.receive(...) end
    local CI = C_ChatInfo
    if not (CI and CI.RegisterAddonMessagePrefix and CI.SendAddonMessage) then return end
    pcall(CI.RegisterAddonMessagePrefix, PFX)
    f:RegisterEvent("CHAT_MSG_ADDON")
    C_Timer.After(12, Y.ask)
    C_Timer.After(25, Y.askNodes)
end)
