-- AH Profit guild sync: when one player finishes a full auction house scan, the prices go to every guild member
-- running the addon over the hidden addon channel, so nobody else needs to scan or reload.
-- Received prices go into a separate shared layer (ns.shared, see Core.lua): they never change or delete your own
-- scans, and only your own full scan is ever sent on. A scan time more than 5 minutes ahead or more than 12 hours
-- behind your clock is refused, so a wrong clock cannot replace good prices or block later ones.
-- Messages (each at most 255 bytes, plain text):
--   H<ver>,<session>,<scan time>,<items>,<chunks>     start of a scan
--   D<session>,<chunk number>,<payload>               items: id step, price, quantity as base-32 digits
--   Q<ver>,<newest prices I have>                     sent by 0.6.0 at login; one member with newer prices answers
--   A<ver>,<newest prices I have>                     ask (0.6.1 on): at login, about once an hour, 30 s after a cut
--   O<ver>,<scan time>,<items>,<wait>                 offer: each owner of a newer complete scan, no prices; <wait>
--                                                     = seconds until it may send that scan again (its 10 min)
--   P<ver>,<owner>,<scan time>                        pick: the asker names the newest offer; only that owner sends
--   An owner answers a Q or a pick at most once per 10 min; one that comes while it is sending is served once
--   the 10 min are up.
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
local ASKGAP, HOUR, JITTER, CUTWAIT = 600, 3600, 300, 30      -- asks: at most one per 10 min, hourly +-5 min, 30 s after a cut
local lastAsk, lastAnswer, nextCheck, reask, cut = -1e9, -1e9, nil, false, nil
local busy, mine, startRound                                 -- defined further down
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
            if again then Y.answerLater() end
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
    out = { msgs = msgs, i = 1, fails = 0, n = n, t = L.full, started = ns.now() }
    Y.sent(L.full)
    again = false
    if not quiet then ns.say("sharing " .. n .. " prices with your guild, about " .. math.ceil(#msgs * GAP / 60) .. " min.") end
    pump(out)
    return true
end
function Y.ask(retry)
    if not on() or not inGuild() then return end
    local L, H = ns.live(), ns.shared()
    local have = math.floor(math.max(L.full, H.full, ns.seed and ns.seed.t or 0))
    if send("A" .. VER .. "," .. have) then lastAsk = ns.now(); startRound(have, retry) end
end
-- Answering: one broadcast per 10 min at most. A member who asked while a broadcast was running missed its start,
-- so it is sent again once the 10 min are up.
function Y.answerLater()
    local wait = lastAnswer + ASKGAP - ns.now()
    local function go()
        if not again or out then return end
        again = false; lastAnswer = ns.now(); Y.broadcast(true)
    end
    if wait <= 0 then go() else C_Timer.After(wait, go) end
end
-- Asking again: about once an hour, so a member who stays online after a cut transfer, or who logged in while the
-- scan's owner was offline, still gets the newest prices. Nothing is sent while a transfer runs either way or
-- within 10 min of the last ask; when everyone has the newest scan, nobody answers.
local function hourly()
    if on() and inGuild() and not out and not busy() and ns.now() - lastAsk >= ASKGAP then Y.ask() end
    local wait = HOUR - JITTER + math.random() * 2 * JITTER
    nextCheck = ns.now() + wait
    C_Timer.After(wait, hourly)
end
-- After a cut transfer: ask once, 30 s later (up to 10 s jitter), but never within 10 min of the last ask.
local function askAgain()
    if reask then return end
    reask = true
    local wait = math.max(CUTWAIT + math.random() * 10, lastAsk + ASKGAP - ns.now())
    C_Timer.After(wait, function()
        reask = false
        if on() and inGuild() and not busy() then Y.ask() end
    end)
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
local PENDING = 900                                              -- an unfinished transfer is forgotten after this
busy = function() return next(R) ~= nil end
local function expire(now)
    for k, r in pairs(R) do
        if now - r.at > PENDING then
            R[k] = nil
            if r.count < r.chunks and on() and inGuild() then  -- cut off: the rest never came
                cut = { from = k:match("^[^-]+"), got = r.items, n = r.n }
                ns.say(cut.from .. "'s prices were cut off (" .. cut.got .. " of " .. cut.n .. "); asking the guild again.")
                askAgain()
            end
        end
    end
end
mine = function(sender)
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
    expire(now)
    if t <= math.max(L.full, H.full) then return end            -- nothing newer than what is here
    held[H] = ns.pruneShared(H)                                  -- also drops entries older than 12 h
    if not R[sender] or R[sender].t ~= t then
        ns.say("receiving prices from " .. sender:match("^[^-]+") .. "'s scan (about " .. n .. " items)...")
    end
    R[sender] = { sid = sid, t = t, n = n, chunks = chunks, got = {}, count = 0, items = 0, seen = {}, at = now, stage = {}, stored = 0 }
    C_Timer.After(PENDING + 5, function() expire(ns.now()) end)  -- also when nobody sends anything more
end
local function chunk(sender, sid, seq, payload)
    expire(ns.now())
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
        if not seen[id] then                                     -- each item once per transfer, so the set-aside
            seen[id] = true; r.items = r.items + 1               -- list never exceeds the declared item count
            if H.p[id] == nil and n >= Y.MAXITEMS then         -- full: kept aside until the scan is complete
                local st = r.stage
                st[#st + 1] = id; st[#st + 1] = list[i + 1]; st[#st + 1] = list[i + 2]
            elseif (H.t[id] or 0) < t then
                if H.p[id] == nil then n = n + 1 end
                H.p[id], H.q[id], H.t[id] = list[i + 1], list[i + 2], t
                r.stored = r.stored + 1
            end
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
            r.stored = r.stored + 1
        end
    end
    if complete and t > H.full then H.full = t; cut = nil end
    local used = {}
    for _, it in pairs(H.t) do used[it] = true end
    for k in pairs(H.from) do if not used[k] then H.from[k] = nil end end
    if r.stored == 0 then return end                             -- nothing of it could be kept: say nothing
    local DB = ns.db()
    DB.syncFrom, DB.syncAt = name, t
    ns.say("prices updated from " .. DB.syncFrom .. "'s scan (" .. ns.age(t) .. "), " .. r.stored .. " items.")
end
local function request(have)
    if out then if out.t > have then again = true end return end
    local L = ns.live()
    if L.full <= have or ns.now() - L.full > 43200 then return end
    if ns.now() - lastAnswer < ASKGAP then return end           -- answered in the last 10 min: the hourly ask comes back
    local tok = {}
    pending = tok
    -- Only your own scan is sent. When a guild member's newer scan is known here, its owner gets the first chance
    -- to answer (seeing their reply cancels this one).
    local wait = ns.shared().full > L.full and 12 or 2
    C_Timer.After(wait + math.random() * 8, function()
        if pending == tok and not out then lastAnswer = ns.now(); Y.broadcast(true) end
    end)
end
-- Asks from 0.6.1 on: ASK -> every owner of a newer complete scan OFFERs it (no prices) -> the asker PICKs the newest
-- (equal times: the lowest name, so every asker picks the same owner) -> only that owner broadcasts. 0.6.0 owners
-- ignore A, O and P, so they are not picked until they update; their own Q asks are still answered above.
local OFFERWAIT, COLLECT, RESEND = 3, 5, 600
local round, heard, lastOffer, askedAt = nil, {}, nil, {}
local sentT, sentAt = nil, -1e9                                  -- the last scan broadcast, and when it began
local function ownCount(L)
    local n = 0
    for id, p in pairs(L.p) do if whole(id, 1e7) and id > 0 and whole(p, 1e12) and p > 0 then n = n + 1 end end
    return n
end
local function offerFor(have, who)                               -- someone asked: offer your scan if it is newer
    local L, now = ns.live(), ns.now()
    local n = 0
    for k, at in pairs(askedAt) do if now - at > 900 then askedAt[k] = nil else n = n + 1 end end
    if n < 50 then askedAt[who] = now end                        -- when each member last asked (see picked)
    if L.full <= have or now - L.full > 43200 then return end
    if lastOffer and lastOffer.t == L.full and now - lastOffer.at < COLLECT then return end   -- one offer per round
    lastOffer = { t = L.full, at = now }
    local t = L.full
    C_Timer.After(math.random() * OFFERWAIT, function()
        local L2 = ns.live()
        if L2.full ~= t or not on() or not inGuild() then return end
        local n = ownCount(L2)
        if n == 0 then return end                                -- nothing to send: no offer, so it cannot be picked
        local wait = (sentT == t) and math.max(0, math.ceil(sentAt + RESEND - ns.now())) or 0
        send("O" .. VER .. "," .. t .. "," .. n .. "," .. math.min(wait, RESEND))
    end)
end
local function offerSeen(name, t, n, wait)
    local now = ns.now()
    if not (whole(t, now + AHEAD) and t >= now - BEHIND and whole(n, 1e7) and n > 0) then return end
    wait = math.min(whole(wait, 1e6) and wait or 0, 600)
    heard[name] = { t = t, n = n, at = now }
    local count, oldest = 0, nil
    for k, v in pairs(heard) do count = count + 1; if not oldest or v.at < heard[oldest].at then oldest = k end end
    if count > 20 then heard[oldest] = nil end
    if round and t > round.have then
        local o = round.offers[name]
        if not o or t > o then round.offers[name] = t; round.waits[name] = wait end
    end
end
-- An owner that was picked but sends nothing (a made-up offer, or a client that broke) is skipped: if neither its
-- header nor any of its chunks is heard within 30 s, that owner and scan time are left out, and one more round is
-- asked at once (only one per ask). The skip lasts until the owner offers another scan time, its header for that
-- scan is heard after all, or 12 h. Chunks count as alive: an owner still sending sends the scan again later.
local WATCH = 30
local skipped, watch = {}, nil
local function isSkipped(name, t)
    local sk = skipped[name]
    if not sk then return false end
    if sk.t ~= t or ns.now() - sk.at > 43200 then skipped[name] = nil; return false end
    return true
end
local function finishRound(r)
    if round ~= r then return end
    round = nil
    local best, bt
    for name, t in pairs(r.offers) do
        if not isSkipped(name, t) and (not bt or t > bt or (t == bt and name < best)) then best, bt = name, t end
    end
    if not (best and on() and inGuild()) then return end
    if not send("P" .. VER .. "," .. best .. "," .. bt) then return end
    local w = { owner = best, t = bt, retry = r.retry }
    watch = w
    C_Timer.After(WATCH + (r.waits[best] or 0), function()       -- an owner inside its 10 min said how long it waits
        if watch ~= w then return end
        watch = nil
        if w.alive then return end
        skipped[w.owner] = { t = w.t, at = ns.now() }
        if not w.retry and on() and inGuild() then Y.ask(true) end     -- one more round, leaving that owner out
    end)
end
-- Every H or D from the owner being watched shows it is sending; its H for the picked scan also clears a skip.
local function heardFrom(who, t)
    if watch and who == watch.owner and (t == nil or t == watch.t) then watch.alive = true end
    if t and skipped[who] and skipped[who].t == t then skipped[who] = nil end
end
function Y.sent(t) sentT, sentAt = t, ns.now() end
startRound = function(have, retry)
    local r = { have = have, offers = {}, waits = {}, retry = retry }
    round = r
    C_Timer.After(COLLECT, function() finishRound(r) end)
end
-- Picked: each scan goes out at most once per 10 min (its window starts with any broadcast of it). A pick inside the
-- window is remembered (one per scan) and that scan is sent once more when the window ends, if it is still the
-- current scan and under 12 h old; so a member cut by a /reload, or who logged in just after a broadcast, has it
-- within about 10 min. A pick from a member who asked before that broadcast began is not remembered: it was in the
-- same round and has the scan.
local queued, queueTimer = nil, false
local function resend()
    queueTimer = false
    local L, now = ns.live(), ns.now()
    if not queued or queued ~= L.full or now - queued > 43200 or not on() or not inGuild() then queued = nil; return end
    local wait = 30                                              -- still sending: look again shortly
    if not out then
        wait = (sentT == queued) and (sentAt + RESEND - now) or 0
        if wait <= 0 then queued = nil; pending = nil; lastAnswer = now; Y.broadcast(true); return end
    end
    queueTimer = true
    C_Timer.After(wait, resend)
end
local function picked(owner, t, who)
    if not mine(owner) then return end                           -- someone else was picked
    local L, now = ns.live(), ns.now()
    if t ~= L.full or now - t > 43200 then return end            -- not the scan this owner has now, or too old
    local open = out or (sentT == t and now - sentAt < RESEND)
    if not open then pending = nil; lastAnswer = now; Y.broadcast(true); return end
    if sentT == t and (askedAt[who] or -1e9) <= sentAt then return end   -- in that broadcast's round: has it
    queued = t
    if not queueTimer then
        queueTimer = true
        C_Timer.After(out and 30 or (sentAt + RESEND - now), resend)
    end
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
        if sid then heardFrom(who); chunk(sender, tonumber(sid), tonumber(seq), payload) end
    elseif k == "H" then
        local ver, sid, t, n, chunks = text:match("^H(%d%d?),(%d%d%d%d%d%d),(%d%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?),(%d%d?%d?%d?%d?),(%d%d?%d?%d?)$")
        if ver then heardFrom(who, tonumber(t)); header(sender, tonumber(ver), tonumber(sid), tonumber(t), tonumber(n), tonumber(chunks)) end
    elseif k == "Q" then
        local ver, have = text:match("^Q(%d%d?),(%d%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?)$")
        if ver and tonumber(ver) == VER then request(tonumber(have)) end
    elseif k == "A" then
        local ver, have = text:match("^A(%d%d?),(%d%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?)$")
        if ver and tonumber(ver) == VER then offerFor(tonumber(have), who) end
    elseif k == "O" then
        local ver, t, n, wait = text:match("^O(%d%d?),(%d%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?),(%d%d?%d?%d?%d?%d?%d?),?(%d?%d?%d?%d?)$")
        if ver and tonumber(ver) == VER then offerSeen(who, tonumber(t), tonumber(n), tonumber(wait)) end
    elseif k == "P" then
        local ver, owner, t = text:match("^P(%d%d?),([^,]+),(%d%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?)$")
        if ver and tonumber(ver) == VER and #owner <= 64 then picked(owner, tonumber(t), who) end
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
    if cut then
        s = s .. " Last transfer from " .. cut.from .. " was cut (" .. cut.got .. (cut.n and (" of " .. cut.n) or " items arrived") .. ")."
    end
    local now, list = ns.now(), {}
    for name, v in pairs(heard) do if now - v.at < 2 * HOUR and now - v.t < 43200 then list[#list + 1] = { name, v } end end
    table.sort(list, function(x, y) if x[2].t ~= y[2].t then return x[2].t > y[2].t end return x[1] < y[1] end)
    if #list > 0 then
        local parts = {}
        for i = 1, math.min(5, #list) do
            local v, age = list[i][2], math.max(0, now - list[i][2].t)
            local n = v.n >= 1000 and string.format("%d,%03d", math.floor(v.n / 1000), v.n % 1000) or tostring(v.n)
            parts[#parts + 1] = list[i][1] .. " " .. (age < 3600 and (math.floor(age / 60) .. "m") or (math.floor(age / 3600) .. "h")) .. " (" .. n .. " items)"
        end
        s = s .. " Guild prices available: " .. table.concat(parts, ", ") .. "."
    end
    if nextCheck then s = s .. " Next check for newer guild prices in ~" .. math.max(1, math.ceil((nextCheck - ns.now()) / 60)) .. "m." end
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
    -- A transfer cut by a reload or logout leaves shared prices newer than the last complete scan in the save.
    local H, newest, got = ns.sharedOK() and ns.shared(), 0, 0
    if H then
        for _, t in pairs(H.t) do
            if t > H.full then
                if t > newest then newest, got = t, 1 elseif t == newest then got = got + 1 end
            end
        end
    end
    if newest > 0 and on() and inGuild() then
        cut = { from = H.from[newest] or "a guild member", got = got }
        ns.say("the last price transfer from " .. cut.from .. " (" .. got .. " items) was cut by a reload; asking the guild again.")
        askAgain()                                               -- this is the login ask, 30 s in instead of 12
    else
        C_Timer.After(12, Y.ask)
    end
    local first = HOUR - JITTER + math.random() * 2 * JITTER
    nextCheck = ns.now() + first
    C_Timer.After(first, hourly)
    C_Timer.After(25, Y.askNodes)
end)
