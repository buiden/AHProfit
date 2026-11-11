-- AH Profit: item tooltip lines with the lowest auction price, what you keep after the cut, and the gain over vendoring.
-- Prices come from two places: Data.lua (a snapshot of Blizzard's auction feed, bundled with the addon) and the
-- player's own auction house browsing, which is recorded while the auction house is open and replaces the snapshot.
local ADDON, ns = ...
local DB
local PREFIX = "|cffffd100AH Profit|r: "

local function secret(v) return issecretvalue ~= nil and issecretvalue(v) end
local function now() return (GetServerTime and GetServerTime()) or time() end
local function say(m) if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. m) end end

local function money(c)
    local neg = c < 0
    if neg then c = -c end
    local g, s, k = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    local t = ""
    if g > 0 then t = g .. "|cffffd700g|r " end
    if g > 0 or s > 0 then t = t .. s .. "|cffc7c7cfs|r " end
    return (neg and "-" or "") .. t .. k .. "|cffeda55fc|r"
end
ns.money = money

local function age(t)
    local d = now() - t
    if d < 90 then return "just now" end
    if d < 5400 then return math.floor(d / 60 + 0.5) .. "m ago" end
    if d < 129600 then return math.floor(d / 3600 + 0.5) .. "h ago" end
    return math.floor(d / 86400 + 0.5) .. "d ago"
end
ns.age = age
ns.now, ns.say = now, say
ns.db = function() return DB end

-- One auction house per realm group and faction; keying by realm and faction never mixes two houses.
local function houseKey()
    return (GetRealmName and GetRealmName() or "?") .. "|" .. (UnitFactionGroup and UnitFactionGroup("player") or "?")
end
local function live()
    local k = houseKey()
    local L = DB.live[k]
    if not L then L = { p = {}, q = {}, t = {}, full = 0 }; DB.live[k] = L end
    return L
end
ns.live = live

-- Saved-data version (DB.v): 1 added DB.shared (guild prices), 2 added DB.hist (daily history of your own scans).
-- A save written by a newer version (DB.v > KNOWN_V) is left untouched; this version then uses neither layer, and
-- neither stores nor shows received prices (ns.sharedOK() is false; Sync.lua refuses them).
-- Prices received from guild members (Sync.lua) live in their own layer, one per auction house: they never change
-- or delete your own scans. from = { [scan time] = sender name }. Received prices older than 12 hours are dropped.
local KNOWN_V, MAX_HOUSES, SHARED_KEEP = 2, 8, 43200
local spare = { p = {}, q = {}, t = {}, full = 0, from = {} }
local function shared()
    if DB.v ~= KNOWN_V then return spare end
    local k = houseKey()
    local H = DB.shared[k]
    if not H then H = { p = {}, q = {}, t = {}, full = 0, from = {} }; DB.shared[k] = H end
    return H
end
ns.shared = shared
ns.sharedOK = function() return DB ~= nil and DB.v == KNOWN_V end
local function okNum(v, max) return type(v) == "number" and v >= 0 and v <= max and v == math.floor(v) end
-- Drops received prices older than 12 hours and sender names no stored price uses. Returns the item count.
local function pruneShared(H)
    local oldest, used, n = now() - SHARED_KEEP, {}, 0
    for id, t in pairs(H.t) do
        if t < oldest then H.p[id], H.q[id], H.t[id] = nil, nil, nil
        else used[t] = true; n = n + 1 end
    end
    for t in pairs(H.from) do if not used[t] then H.from[t] = nil end end
    if H.full < oldest then H.full = 0 end
    return n
end
ns.pruneShared = pruneShared
-- Checks the saved shared layer at load: wrong types are dropped, at most MAX_HOUSES houses (the newest kept).
local loadHist
local function loadShared()
    if type(DB.v) == "number" and DB.v > KNOWN_V then return end
    local v = type(DB.v) == "number" and DB.v or 0
    if v < 1 or type(DB.shared) ~= "table" then DB.shared = {} end
    if v < 2 or type(DB.hist) ~= "table" then DB.hist = {} end
    DB.v = KNOWN_V
    loadHist()
    local keys = {}
    for k, H in pairs(DB.shared) do
        if type(k) ~= "string" or type(H) ~= "table" then DB.shared[k] = nil
        else
            for _, f in ipairs({ "p", "q", "t", "from" }) do if type(H[f]) ~= "table" then H[f] = {} end end
            if not okNum(H.full, 1e10) then H.full = 0 end
            for id, p in pairs(H.p) do
                if not (okNum(id, 1e7) and okNum(p, 1e12) and p > 0 and okNum(H.t[id], 1e10)) then H.p[id], H.q[id], H.t[id] = nil, nil, nil
                elseif not okNum(H.q[id], 1e9) then H.q[id] = 0 end
            end
            for id in pairs(H.t) do if H.p[id] == nil then H.t[id], H.q[id] = nil, nil end end
            for id in pairs(H.q) do if H.p[id] == nil then H.q[id] = nil end end
            for t, n in pairs(H.from) do if not (okNum(t, 1e10) and type(n) == "string" and n ~= "" and #n <= 64) then H.from[t] = nil end end
            pruneShared(H)
            keys[#keys + 1] = k
        end
    end
    if #keys > MAX_HOUSES then
        table.sort(keys, function(a, b) return DB.shared[a].full > DB.shared[b].full end)
        for i = MAX_HOUSES + 1, #keys do DB.shared[keys[i]] = nil end
    end
end

local seedIdx
local function seedLookup(id)
    local S = ns.seed
    if not S or not S.flat then return end
    if S.faction and UnitFactionGroup and UnitFactionGroup("player") ~= S.faction then return end
    if not seedIdx then
        seedIdx = {}
        local f = S.flat
        for i = 1, #f, 3 do seedIdx[f[i]] = i end
    end
    local i = seedIdx[id]
    if i then return S.flat[i + 1], S.flat[i + 2], S.t end
end

-- Returns price per unit (copper), quantity listed, time seen, source ("scan", "guild" or "feed") and, for "guild",
-- the sender's name. Order: your own scan when it is at most 2 hours old (always, whatever the feed's age or a
-- guild member's claim), then a guild member's scan newer than yours, then your older scan, then the bundled feed.
-- A scan older than the feed loses to the feed.
local OWN_FRESH = 7200
local function lookup(id)
    local L, H = live(), shared()
    local lp, lt = L.p[id], L.t[id]
    if lp and now() - lt <= OWN_FRESH then return lp, L.q[id], lt, "scan" end
    local gp, gt = H.p[id], H.t[id]
    local sp, sq, st = seedLookup(id)
    if sp and math.max(L.full, H.full) >= st then sp = nil end   -- a complete scan newer than the snapshot is the whole truth
    if sp and lp and lt < st then lp = nil end
    if sp and gp and gt < st then gp = nil end
    if gp and (not lp or gt > lt) then return gp, H.q[id], gt, "guild", H.from[gt] end
    if lp then return lp, L.q[id], lt, "scan" end
    if sp then return sp, sq, st, "feed" end
end
ns.lookup = lookup
-- How a price's source is shown: "scan 5m ago", "guild (Name, 20m ago)", "feed 1h ago".
local function srcLabel(src, t, from)
    if src == "guild" then return "guild (" .. (type(from) == "string" and from or "a guild member") .. ", " .. age(t) .. ")" end
    return (src == "scan" and "scan " or "feed ") .. age(t)
end
ns.srcLabel = srcLabel

-- ------------------------------------------------------------------ daily history of your own auction house scans --
-- DB.hist[house][itemID] = { h = {}, l = {}, a = {} }, each keyed by scan day (whole days since 2020-01-01 UTC):
-- h = the highest of the day's lowest prices, l = the lowest one (kept only when below h), a = the most listed.
-- Written from every own browse result, full scans and searches alike, once per query with that query's lowest
-- price per item. Guild prices never enter it. Kept 21 days; at most HIST_ITEMS items per house, 8 houses.
local DAY0, HIST_DAYS, HIST_ITEMS = 1577836800, 21, 10000
ns.HIST_ITEMS = HIST_ITEMS
local function scanDay(t) return math.floor((t - DAY0) / 86400) end
ns.scanDay = scanDay
local histCount = setmetatable({}, { __mode = "k" })
local function histHouse()
    if DB.v ~= KNOWN_V then return nil end
    local k = houseKey()
    local H = DB.hist[k]
    if not H then H = {}; DB.hist[k] = H; histCount[H] = 0 end
    if not histCount[H] then local n = 0; for _ in pairs(H) do n = n + 1 end; histCount[H] = n end
    return H
end
ns.histHouse = histHouse
local function prune(e, oldest)
    local any = false
    for _, f in ipairs({ "h", "l", "a" }) do
        for d in pairs(e[f]) do if d < oldest then e[f][d] = nil elseif f == "h" then any = true end end
    end
    return any
end
local function histAdd(H, id, p, q, day)
    local e = H[id]
    if not e then
        if histCount[H] >= ns.HIST_ITEMS then return end
        e = { h = {}, l = {}, a = {} }; H[id] = e; histCount[H] = histCount[H] + 1
    end
    local hi, lo = e.h[day], e.l[day] or e.h[day]
    hi = (hi and hi > p) and hi or p
    lo = (lo and lo < p) and lo or p
    e.h[day] = hi
    e.l[day] = lo < hi and lo or nil
    if q > (e.a[day] or -1) then e.a[day] = q end
    prune(e, day - HIST_DAYS + 1)
end
-- Daily prices of one item from your own scans, oldest first: { { d = day, p = h, l = l or h, a = a }, ... }.
function ns.histOwn(id)
    local H = histHouse()
    local e = H and H[id]
    if not e then return {} end
    local out = {}
    for d, h in pairs(e.h) do out[#out + 1] = { d = d, p = h, l = e.l[d] or h, a = e.a[d] or 0 } end
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end
-- At load: wrong types dropped, days older than 21 dropped, the item cap and the newest 8 houses kept.
loadHist = function()
    local today = scanDay(now())
    local oldest, keys = today - HIST_DAYS + 1, {}
    for k, H in pairs(DB.hist) do
        if type(k) ~= "string" or type(H) ~= "table" then DB.hist[k] = nil
        else
            local n, newest = 0, -1
            for id, e in pairs(H) do
                local good = okNum(id, 1e7) and type(e) == "table" and type(e.h) == "table"
                if good then
                    if type(e.l) ~= "table" then e.l = {} end
                    if type(e.a) ~= "table" then e.a = {} end
                    for d, p in pairs(e.h) do if not (okNum(d, 1e5) and d <= today and okNum(p, 1e12) and p > 0) then e.h[d] = nil end end
                    for d, p in pairs(e.l) do if not (e.h[d] and okNum(p, 1e12) and p > 0 and p < e.h[d]) then e.l[d] = nil end end
                    for d, a in pairs(e.a) do if not (e.h[d] and okNum(a, 1e9)) then e.a[d] = nil end end
                    good = prune(e, oldest)
                end
                if not good or n >= HIST_ITEMS then H[id] = nil
                else
                    n = n + 1
                    for d in pairs(e.h) do if d > newest then newest = d end end
                end
            end
            histCount[H] = n
            keys[#keys + 1] = { k = k, newest = newest }
        end
    end
    if #keys > MAX_HOUSES then
        table.sort(keys, function(a, b) return a.newest > b.newest end)
        for i = MAX_HOUSES + 1, #keys do DB.hist[keys[i].k] = nil end
    end
end

local GREY, WHITE, GREEN, RED = { .6, .6, .6 }, { 1, 1, 1 }, { .25, 1, .25 }, { 1, .3, .3 }
local function line(tt, l, r, lc, rc)
    tt:AddDoubleLine(l, r, lc[1], lc[2], lc[3], rc[1], rc[2], rc[3])
end

-- Three lines, always in the same order: what a vendor pays, the lowest auction price, and what selling on the
-- auction house gains you over the vendor once the cut is taken (green when it is a gain, red when it is a loss).
-- Hold Shift for the extra lines (your stack, deposit, your own record with this item).
local function addLines(tt, id)
    if not DB or not DB.enabled or type(id) ~= "number" then return end
    local _, _, quality, _, _, _, _, _, _, _, vendor, _, _, bind = C_Item.GetItemInfo(id)
    if secret(vendor) or secret(bind) or secret(quality) then return end
    if bind == 1 or bind == 4 then return end                    -- bind on pickup and quest items cannot be auctioned
    local price, qty, t, src, from = lookup(id)
    local hasVendor = type(vendor) == "number" and vendor > 0
    if not price then
        if hasVendor and quality and quality >= 1 then
            line(tt, "Vendor price", money(vendor), WHITE, WHITE)
            line(tt, "AH price", "none listed", WHITE, GREY)
        end
        return
    end
    if vendor ~= nil then line(tt, "Vendor price", hasVendor and money(vendor) or "none", WHITE, hasVendor and WHITE or GREY) end
    line(tt, "AH price  |cff999999" .. srcLabel(src, t, from) .. (qty and qty > 0 and (", " .. qty .. " listed") or "") .. "|r", money(price), WHITE, WHITE)
    if vendor == nil then return end                             -- item not cached yet; the next hover has it
    local net = math.floor(price * (100 - DB.cut) / 100)
    local d = net - (hasVendor and vendor or 0)
    local c = d >= 0 and GREEN or RED
    line(tt, "AH profit  |cff999999after " .. DB.cut .. "% cut|r", (d >= 0 and "+" or "") .. money(d), c, c)
    if IsShiftKeyDown and IsShiftKeyDown() then
        local n = C_Item.GetItemCount and C_Item.GetItemCount(id) or 0
        if type(n) == "number" and not secret(n) and n > 1 then
            line(tt, "Your " .. n .. " on the AH, after cut", money(net * n), GREY, WHITE)
        end
        if ns.tools then ns.tools.tipLine(tt, id) end
        if ns.extra then ns.extra.tipLine(tt, id, price) end
    end
end
ns.addLines = addLines

local function onTooltip(tt, data)
    if not data or not tt or not tt.AddDoubleLine then return end
    local id = data.id
    if id == nil or secret(id) then return end
    addLines(tt, id)
end

-- ------------------------------------------------------------------ recording the auction house while it is open --
local open, scanning, waitingThrottle, pendingStart = false, false, false, false
local scanId, seen, scanCount = 0, {}, 0
local pend = {}                    -- items seen in the current query, written to the daily history when it ends
local function flushHist()
    local H = next(pend) and histHouse()
    if H then
        local L, day = live(), scanDay(now())
        for id in pairs(pend) do
            local p, q = L.p[id], L.q[id]
            if p then histAdd(H, id, p, q or 0, day) end
        end
    end
    pend = {}
end

local function record(results)
    if type(results) ~= "table" then return end
    local L, t = live(), now()
    for i = 1, #results do
        local r = results[i]
        local id, price = r.itemKey and r.itemKey.itemID, r.minPrice
        if type(id) == "number" and type(price) == "number" and not secret(price) and price > 0 then
            local q = type(r.totalQuantity) == "number" and r.totalQuantity or 0
            if seen[id] == scanId then
                if price < L.p[id] then L.p[id] = price end      -- same item at several item levels or suffixes
                L.q[id] = L.q[id] + q
            else
                seen[id] = scanId; scanCount = scanCount + 1
                L.p[id], L.q[id], L.t[id] = price, q, t
            end
            pend[id] = true
        end
    end
end

local function finish()
    scanning = false
    flushHist()
    local L, known = live(), 0
    for _ in pairs(L.p) do known = known + 1 end
    -- Only a scan that plausibly covered the whole house may forget items; a narrow search must not wipe the rest.
    if scanCount >= 200 and scanCount * 2 >= known then
        for id in pairs(L.p) do
            if seen[id] ~= scanId then L.p[id], L.q[id], L.t[id] = nil, nil, nil end
        end
        L.full = now()
        say("scan finished, " .. scanCount .. " items priced.")
        if ns.sync then ns.sync.broadcast(true) end
    else
        say("scan ended early with " .. scanCount .. " items; older prices kept.")
    end
end

-- The game allows one auction house request at a time, and its Sell tab refuses to post ("You're doing this too
-- fast") while a request of ours is under way. So the scan stands still for as long as you are selling: while a
-- Sell tab is showing or an item is on the cursor. A scan that started by itself also leaves a gap between pages.
local GAP = 1
local autoRun, queued = false, false
local SELL = { "ItemSellFrame", "CommoditiesSellFrame", "WoWTokenSellFrame" }
local function selling()
    local F = AuctionHouseFrame
    if type(F) == "table" then
        for i = 1, #SELL do
            local s = F[SELL[i]]
            if type(s) == "table" and s.IsShown and s:IsShown() then return true end
        end
    end
    return GetCursorInfo ~= nil and GetCursorInfo() == "item"
end
ns.selling = selling

local more
local function later(d)
    if queued then return end
    queued = true
    C_Timer.After(d, function() queued = false; more() end)
end
more = function()
    if not scanning then return end
    if C_AuctionHouse.HasFullBrowseResults() then return finish() end
    if selling() then return later(1) end                        -- look again in a second; nothing is sent meanwhile
    if C_AuctionHouse.IsThrottledMessageSystemReady() then C_AuctionHouse.RequestMoreBrowseResults()
    else waitingThrottle = true end
end
local function page()                                            -- a page arrived
    if scanning and autoRun and not C_AuctionHouse.HasFullBrowseResults() then later(GAP) else more() end
end

local function startScan(auto)
    auto = auto == true
    if not open then return say("open the auction house first.") end
    if scanning then return say("already scanning.") end
    autoRun = auto
    if auto and selling() then                                   -- wait until the player is done selling
        C_Timer.After(2, function() if open and not scanning and not pendingStart then startScan(true) end end)
        return
    end
    if not C_AuctionHouse.IsThrottledMessageSystemReady() then pendingStart = true; return end
    pendingStart, scanning = false, true
    C_AuctionHouse.SendBrowseQuery({
        searchString = "", filters = {}, itemClassFilters = {},
        sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } },
    })
end
ns.startScan = startScan

local f = CreateFrame("Frame")
f:Hide()
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, ev, a1)
    if ev == "ADDON_LOADED" then
        if a1 ~= ADDON then return end
        AHProfitDB = AHProfitDB or {}
        DB = AHProfitDB
        if DB.enabled == nil then DB.enabled = true end
        if DB.autoV ~= 3 then DB.autoscan = true; DB.autoV = 3 end   -- on again: the scan now stands still while you sell
        if DB.sync == nil then DB.sync = true end
        if DB.cut ~= 5 and DB.cut ~= 15 then DB.cut = 5 end
        DB.live = DB.live or {}
        loadShared()
        if ns.tools then
            for _, e in ipairs(ns.tools.events) do f:RegisterEvent(e) end
            ns.tools.init()
        end
        if TooltipDataProcessor and Enum and Enum.TooltipDataType then
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, onTooltip)
        end
        if C_AuctionHouse and C_AuctionHouse.SendBrowseQuery then
            for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
                "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "AUCTION_HOUSE_BROWSE_FAILURE", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" }) do
                f:RegisterEvent(e)
            end
        end
    elseif ev == "AUCTION_HOUSE_SHOW" then
        open = true
        if DB.autoscan and C_AuctionHouse and C_AuctionHouse.SendBrowseQuery and now() - math.max(live().full, shared().full) > 900 then C_Timer.After(1, function() if open and not scanning then startScan(true) end end) end
    elseif ev == "AUCTION_HOUSE_CLOSED" then
        flushHist()
        open, scanning, waitingThrottle, pendingStart = false, false, false, false
    elseif ev == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
        flushHist()                                              -- a new query: the previous one is complete
        scanId = scanId + 1; scanCount = 0
        record(C_AuctionHouse.GetBrowseResults())
        page()
    elseif ev == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        record(a1)
        page()
    elseif ev == "AUCTION_HOUSE_BROWSE_FAILURE" then
        if scanning then scanning = false; say("the auction house refused the scan; try /ahp scan again.") end
    elseif ev == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        if pendingStart then startScan(autoRun)
        elseif waitingThrottle then waitingThrottle = false; more() end
    end
    if ev ~= "ADDON_LOADED" and DB and ns.tools then ns.tools.event(ev) end
end)

SLASH_AHPROFIT1 = "/ahp"
SlashCmdList["AHPROFIT"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "farm" then if ns.ui then ns.ui:Toggle() end
    elseif msg == "bags" or msg == "session" or msg == "prices" or msg == "deals" or msg == "recipes" or msg == "auctions" then if ns.ui then ns.ui:Open(msg) end
    elseif msg == "session start" and ns.tools then ns.tools.sessionStart(); say("session started. /ahp session shows it."); if ns.ui then ns.ui:Refresh() end
    elseif msg == "session stop" and ns.tools then say(ns.tools.sessionStop() and "session stopped." or "no session is running."); if ns.ui then ns.ui:Refresh() end
    elseif msg == "scan" then startScan()
    elseif msg == "scan stop" then
        if scanning or pendingStart then scanning, waitingThrottle, pendingStart = false, false, false; say("scan stopped; prices seen so far are kept.")
        else say("no scan is running.") end
    elseif msg == "on" or msg == "off" then DB.enabled = msg == "on"; say("tooltip lines " .. msg .. ".")
    elseif msg == "auto on" or msg == "auto off" then DB.autoscan = msg == "auto on"; say("scan when the auction house opens: " .. msg:sub(6) .. "." .. (DB.autoscan and " It stands still while you are on a Sell tab." or ""))
    elseif msg == "sync on" or msg == "sync off" then DB.sync = msg == "sync on"; say("guild sharing " .. msg:sub(6) .. ".")
    elseif msg == "share" then if ns.sync then ns.sync.broadcast() end
    elseif msg == "cut 5" or msg == "cut 15" then DB.cut = tonumber(msg:sub(5)); say("cut set to " .. DB.cut .. "%."); if ns.ui then ns.ui:Refresh() end
    else
        local L, n = live(), 0
        for _ in pairs(L.p) do n = n + 1 end
        say(n .. " items from your scans" .. (L.full > 0 and (", last full scan " .. age(L.full)) or ", no full scan yet")
            .. ". Bundled feed: " .. (ns.seed and (ns.seed.n .. " items, " .. ns.seed.label .. ", " .. age(ns.seed.t)) or "none") .. ".")
        say("/ahp bags | session | session start | session stop | prices | deals | recipes | auctions")
        if ns.extra then say(ns.extra.nodeCount() .. " gathering nodes seen by you and your guild.") end
        if ns.sync then say(ns.sync.status()) end
        say("/ahp farm | scan | scan stop | share | sync on | sync off | on | off | auto on | auto off | cut 5 | cut 15")
    end
end
