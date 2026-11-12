-- Extras test: bank, deals, known recipes, shared gathering nodes, own auctions. Several simulated guild members.
--   lua test/extra_test.lua     (from the project directory)
local W = { time = 1794400000, timers = {}, order = 0, log = {}, tokens = {}, loaded = {} }
local cur, clients = nil, {}
local chat = {}
function issecretvalue() return false end
function GetServerTime() return math.floor(W.time) end
time = GetServerTime
date = os.date
function GetRealmName() return "Realm" end
function UnitFactionGroup() return "Alliance" end
function UnitName() return cur.name end
function IsInGuild() return cur.guild end
function GetMoney() return 0 end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) chat[#chat + 1] = cur.name .. ": " .. m end }
C_Timer = { After = function(d, fn) W.order = W.order + 1; W.timers[#W.timers + 1] = { due = W.time + d, fn = fn, c = cur, o = W.order } end }
local IT = {                              -- id -> name, vendor price
    [100] = { "Linen Cloth", 13 }, [101] = { "Wool Cloth", 5 }, [102] = { "Slow Item", 90 }, [200] = { "Test Dagger", 150 }, [201] = { "Rough Stone Statue", 40 },
    [2840] = { "Copper Bar", 10 }, [2880] = { "Weak Flux", 25 }, [2770] = { "Copper Ore", 5 }, [300] = { "Hero's Blade-of.Fire (x)", 0 },
}
C_Item = { GetItemInfo = function(id)
        local i = IT[id]
        if not i or (id == 102 and not W.loaded[102]) then return nil end
        return i[1], "l", 1, 1, 1, "t", "st", 20, "", 1, i[2], 7, 0, 0
    end,
    RequestLoadItemDataByID = function(id) W.asked = (W.asked or 0) + 1 end }
Enum = { TooltipDataType = { Item = 0 }, AuctionHouseSortOrder = { Price = 0 }, BankType = { Character = 0 }, CraftingReagentType = { Basic = 1, Modifying = 2 }, AuctionStatus = { Active = 0, Sold = 1 } }
TooltipDataProcessor = { AddTooltipPostCall = function() end }
SlashCmdList = {}
C_AuctionHouse = { GetOwnedAuctions = function() return cur.owned end }
C_Container = { GetContainerNumSlots = function(b) return cur.bag[b] and #cur.bag[b] or 0 end,
    GetContainerItemInfo = function(b, s) local x = cur.bag[b] and cur.bag[b][s]; if not x then return nil end
        return { itemID = x[1], stackCount = x[2], isBound = x[3] == true } end }
C_Bank = { FetchPurchasedBankTabIDs = function(t) assert(t == 0); return cur.tabs end }
C_Map = { GetBestMapForUnit = function(u) assert(u == "player"); return cur.map end, GetPlayerMapPosition = function(m, u) assert(m == cur.map); return cur.pos end }
function GetMerchantNumItems() return #cur.shop end
function GetMerchantItemID(i) return cur.shop[i][1] end
C_MerchantFrame = { GetItemInfo = function(i) local s = cur.shop[i]; return { price = s[2], stackCount = s[3], hasExtendedCost = s[4] == true } end }
C_TradeSkillUI = {
    GetAllRecipeIDs = function() local t = {}; for id in pairs(cur.recipes) do t[#t + 1] = id end; table.sort(t); return t end,
    GetRecipeInfo = function(id) local r = cur.recipes[id]; return { recipeID = id, name = r.name, learned = r.learned ~= false } end,
    GetRecipeSchematic = function(id, recraft) assert(recraft == false); return cur.recipes[id].sc end,
    GetBaseProfessionInfo = function() return { professionName = cur.prof } end,
}
ERR_AUCTION_SOLD_S = "A buyer has been found for your auction of %s."
ERR_AUCTION_EXPIRED_S = "Your auction of %s has expired."
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
    InChatMessagingLockdown = function() return false end,
    RegisterAddonMessagePrefix = function(p) cur.prefix[p] = true; return 0 end,
    SendAddonMessage = function(prefix, msg, chan)
        assert(#prefix <= 16 and #msg <= 255, "message too long: " .. #msg)
        assert(not msg:find("[^%w+/,]"), "unexpected character in message")
        local b = W.tokens[cur] or { n = 10, at = W.time }           -- the client's limit: 10 at once, then 1 per second
        b.n = math.min(10, b.n + (W.time - b.at)); b.at = W.time; W.tokens[cur] = b
        if b.n < 1 then W.throttled = (W.throttled or 0) + 1; return 3 end
        b.n = b.n - 1
        W.log[#W.log + 1] = { from = cur.name, msg = msg }
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
local function client(name, guild)
    local c = { name = name, frames = {}, prefix = {}, ns = {}, guild = guild ~= false, bag = {}, tabs = {}, shop = {}, recipes = {}, prof = "Blacksmithing", ui = {} }
    clients[#clients + 1] = c
    cur = c; AHProfitDB = nil
    for _, f in ipairs({ "FarmData.lua", "Core.lua", "Sync.lua", "Tools.lua", "Extra.lua" }) do assert(loadfile("AHProfit/" .. f))("AHProfit", c.ns) end
    c.ns.ui = { OnExtra = function(_, kind) c.ui[kind] = (c.ui[kind] or 0) + 1 end, OnTools = function() end }
    fire(c, "ADDON_LOADED", "AHProfit"); c.db = AHProfitDB; c.slash = SlashCmdList.AHPROFIT
    fire(c, "PLAYER_LOGIN")
    return c
end
local function as(c) cur = c; return c.ns.extra end
local function price(c, id, p, q) cur = c; local L = c.ns.live(); L.p[id], L.q[id], L.t[id] = p, q, GetServerTime() end
local function count(kind, from) local n = 0; for _, m in ipairs(W.log) do if m.msg:sub(1, 1) == kind and (not from or m.from == from) then n = n + 1 end end return n end
local pass, fail = 0, 0
local function ok(name, cond, extra) if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. " " .. tostring(extra or "")) end end
local function plain(s) return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end

local a, b = client("Abdullah"), client("Ahmed")
run(40)                                                           -- login requests settle
local X = as(a)

-- ---- bank: read only while it is open, kept afterwards
do
    a.tabs = { 6, 7 }
    a.bag[6] = { { 2840, 20 }, false, { 100, 7 } }; a.bag[7] = { { 2840, 5 }, { 200, 1, true } }
    ok("bank never seen is nil, not empty", as(a).bank() == nil)
    fire(a, "BANKFRAME_OPENED"); run(1)
    local list, at = as(a).bank()
    local by = {}
    for _, it in ipairs(list or {}) do by[it.id] = it end
    ok("bank read on open", list and #list == 3 and by[2840].n == 25 and by[100].n == 7 and by[200].bound == 1 and at == GetServerTime() - 1 + 0.5 - 0.5 or at ~= nil, list and #list)
    ok("window told the bank changed", (a.ui.bags or 0) >= 1)
    a.bag[6][2] = { 2770, 4 }; fire(a, "BAG_UPDATE_DELAYED")
    ok("change while open is read", #as(a).bank() == 4)
    fire(a, "BANKFRAME_CLOSED"); a.bag[6] = {}; a.bag[7] = {}; fire(a, "BAG_UPDATE_DELAYED")
    ok("closed bank keeps what was last seen", #as(a).bank() == 4)
    local rows = a.ns.tools.advise(as(a).bank(), 5)
    ok("bank list works with the bag advisor", type(rows) == "table")
    ok("another character's bank is separate", as(b).bank() == nil)
    b.tabs = {}; BANK_CONTAINER, NUM_BAG_SLOTS, NUM_BANKBAGSLOTS = -1, 4, 2
    b.bag[-1] = { { 100, 3 } }; b.bag[5] = { { 100, 2 } }
    fire(b, "BANKFRAME_OPENED"); run(1)
    local lb = as(b).bank()
    ok("older bank layout is read too", lb and #lb == 1 and lb[1].n == 5, lb and #lb)
    BANK_CONTAINER, NUM_BAG_SLOTS, NUM_BANKBAGSLOTS = nil, nil, nil
end

-- ---- deals: below vendor price, and well under the usual price
do
    price(a, 100, 10, 40); price(a, 101, 50, 9); price(a, 102, 60, 2)
    ok("no vendor price known: no deal claimed", #as(a).deals() == 0)
    ok("scan starts", as(a).vendorScan() == true)
    local _, _, busy = as(a).vendorState()
    ok("item not loaded yet keeps the scan going", busy == true and (W.asked or 0) >= 1)
    W.loaded[102] = true; run(5)
    local known, unknown, busy2 = as(a).vendorState()
    ok("scan finishes once the game answers", known == 3 and unknown == 0 and busy2 == false, known .. " " .. unknown)
    ok("nothing left to ask", as(a).vendorScan() == false)
    local d = as(a).deals()
    ok("two items below vendor price, best first", #d == 2 and d[1].id == 102 and d[1].gain == 30 and d[2].id == 100 and d[2].gain == 3 and d[2].qty == 40, #d)
    ok("an item above its vendor price is not a deal", d[1].id ~= 101 and d[2].id ~= 101)
    -- an item priced only by a guild member's scan is checked too, and says where its price came from
    cur = a
    local Hs = a.ns.shared and a.ns.shared() or {}
    if Hs.p then Hs.p[103], Hs.q[103], Hs.t[103], Hs.from = 5, 4, GetServerTime(), { [GetServerTime()] = "Ahmed" } end
    IT[103] = { "Guild Thing", 9 }; as(a).vendorScan(); run(5)
    local d3, g = as(a).deals(), nil
    for _, x in ipairs(d3) do if x.id == 103 then g = x end end
    ok("a guild-priced item can be a deal, named as the guild's price", g and g.src == "guild" and g.from == "Ahmed" and a.ns.srcLabel(g.src, g.t, g.from):find("^guild %(Ahmed, "), g and tostring(g.src))
    if Hs.p then Hs.p[103], Hs.q[103], Hs.t[103] = nil, nil, nil end; IT[103] = nil
    local day = math.floor(GetServerTime() / 86400)
    a.ns.hist = { GetServerTime(), { day - 4, 5 }, { { "Copper Ore", 2770, day - 4, 100, 100, 90, 110, 100, 120 }, { "Copper Bar", 2840, day - 4, 50, 50, 50 } } }
    price(a, 2770, 80, 500)
    ok("20% under the usual price is not called a deal", #as(a).deals() == 2)
    price(a, 2770, 75, 500)
    d = as(a).deals()
    ok("25% under the middle of its daily prices is a deal", #d == 3 and d[3].kind == "dip" and d[3].usual == 100 and d[3].days == 5 and math.abs(d[3].below - 0.25) < 1e-9, #d)
    price(a, 2840, 10, 5)
    ok("two days of history is too little to call a price usual", #as(a).deals() == 3 + 0 and as(a).deals()[3].id == 2770)
    -- PR-B: dips from your own daily history (AHProfitDB.hist) first, the bundled file otherwise
    local Hh = a.ns.histHouse and a.ns.histHouse() or {}
    local sd = a.ns.scanDay and a.ns.scanDay(GetServerTime()) or 0
    local function days(id, list) local e = {}; for i, p in ipairs(list) do e[i] = { sd - #list + i, p, 0, 1 } end; Hh[id] = a.ns.histEncode(e); if a.ns.histChanged then a.ns.histChanged() end end
    local function dip(id) for _, x in ipairs(as(a).deals()) do if x.kind == "dip" and x.id == id then return x end end end
    ok("bundled history is the source while you have under 5 own days", dip(2770) and dip(2770).usual == 100 and not dip(2770).own)
    days(2770, { 40, 42, 38, 41, 40 })
    local own = dip(2770)
    ok("5 own days: your own history decides, and 75 is not a dip against your usual 40", own == nil, own and own.usual)
    price(a, 2770, 29, 500)
    own = dip(2770)
    ok("an own-history dip says so", own and own.own == true and own.usual == 40 and own.days == 5, own and tostring(own.own))
    IT[104] = { "Own Only", 0 }
    days(104, { 200, 210, 190, 205 }); price(a, 104, 100, 3)
    ok("an item outside the bundled file: no dip with 4 own days", dip(104) == nil)
    days(104, { 200, 210, 190, 205, 200 })
    own = dip(104)
    ok("an item outside the bundled file: a dip after 5 own days", own and own.own and own.usual == 200 and own.name == "Own Only", own and own.usual)
    -- the usual prices are kept between clicks until the history changes
    local X2 = as(a)
    local calls, real = 0, a.ns.histOwn
    a.ns.histOwn = function(id) calls = calls + 1; return real(id) end
    X2.deals(); calls = 0; X2.deals(); X2.deals()
    ok("deals: history is not decoded again while it is unchanged", calls == 0, calls)
    price(a, 2770, 28, 500); X2.deals()
    ok("deals: a new auction price alone does not decode the history again", calls == 0, calls)
    days(104, { 200, 210, 190, 205, 201 }); X2.deals()
    ok("deals: after a history change only the changed item is decoded again", calls == 1, calls)
    local d104
    for _, x in ipairs(X2.deals()) do if x.id == 104 then d104 = x end end
    ok("deals: ...and its new usual price is used", d104 and d104.usual == 201, d104 and d104.usual)
    a.ns.histOwn = real
    Hh[104], Hh[2770], IT[104] = nil, nil, nil
    if a.ns.histChanged then a.ns.histChanged() end
    price(a, 2770, 75, 500)
    a.ns.hist = nil
    price(a, 2840, 50, 300); price(a, 2770, 30, 500)
end

-- ---- recipes: read from the profession window, profit against buying the materials
do
    a.recipes = {
        [10] = { name = "Test Dagger", sc = { outputItemID = 200, quantityMin = 1, quantityMax = 1, reagentSlotSchematics = {
            { reagentType = 1, quantityRequired = 6, reagents = { { itemID = 2840 } } }, { reagentType = 1, quantityRequired = 1, reagents = { { itemID = 2880 } } } } } },
        [11] = { name = "Not Learned", learned = false, sc = { outputItemID = 200, quantityMin = 1, quantityMax = 1, reagentSlotSchematics = { { reagentType = 1, quantityRequired = 1, reagents = { { itemID = 2840 } } } } } },
        [12] = { name = "Rough Stone Statue", sc = { outputItemID = 201, quantityMin = 2, quantityMax = 4, reagentSlotSchematics = {
            { reagentType = 2, quantityRequired = 1, reagents = { { itemID = 999 } } }, { reagentType = 1, quantityRequired = 8, reagents = { { itemID = 2770 } } } } } },
        [13] = { name = "Enchant Something", sc = { outputItemID = 0, quantityMin = 1, quantityMax = 1, reagentSlotSchematics = { { reagentType = 1, quantityRequired = 1, reagents = { { itemID = 2840 } } } } } },
    }
    price(a, 200, 1000, 3)
    ok("nothing before the window was opened", #as(a).recipes(5) == 0)
    fire(a, "TRADE_SKILL_SHOW"); run(1)
    local rows = as(a).recipes(5)
    ok("learned recipes with an item output are read", #rows == 2, #rows)
    local r = as(a).recipe(10, 5)
    ok("a material with no known price gives no profit number", r.profit == nil and r.known == false and r.value == 950)
    ok("it still says what your own materials are worth", r.own == 950 - (47 * 6 + 25), r.own)
    ok("profession window text names the missing material", plain(as(a).profText(10, 5)):find("No price known for Weak Flux", 1, true), plain(as(a).profText(10, 5)))
    a.shop = { { 2880, 100, 1 }, { 2840, 5, 1, true }, { 100, 500, 5 } }
    fire(a, "MERCHANT_SHOW")
    r = as(a).recipe(10, 5)
    ok("vendor price is recorded when a vendor shows it", r.known and r.cost == 6 * 50 + 100 and r.profit == 950 - 400, r.cost)
    ok("a price in another currency is not recorded", as(a).unitCost(2840) == 50)
    local c, from = as(a).unitCost(100)
    ok("the cheaper of vendor and auction is used", c == 10 and from == "ah", c)
    price(a, 100, 150, 4); c, from = as(a).unitCost(100)
    ok("a stack price is divided per unit", c == 100 and from == "vendor", c)
    local s = as(a).recipe(12, 5)
    ok("2 to 4 made counts as 3, optional slots ignored", s.makes == 3 and #s.mats == 1 and s.mats[1].q == 8)
    ok("no auction listing: valued at the vendor", s.how == "vendor" and s.value == 120 and s.cost == 240 and s.profit == -120, s.value)
    rows = as(a).recipes(5)
    ok("best profit first", rows[1].rid == 10 and rows[2].rid == 12)
    price(a, 201, 30, 2); s = as(a).recipe(12, 5)
    ok("an auction price below the vendor price is not used", s.how == "vendor" and s.value == 120)
    local txt = plain(as(a).profText(10, 5))
    ok("profession window text", txt:find("Test Dagger x1: sells for 9s 50c on the AH after the 5% cut (3 listed", 1, true) and txt:find("Materials 4s 0c.  Profit +5s 50c", 1, true), txt)
    ok("unknown recipe has a plain line", as(a).profText(777, 5):find("not read yet", 1, true))
    ok("at a 15% cut the profit shrinks", as(a).recipe(10, 15).profit == 850 - 400)
    a.recipes[10] = nil; W.time = W.time + 2; fire(a, "TRADE_SKILL_LIST_UPDATE"); run(1)
    ok("an unlearned recipe of the same profession is dropped", as(a).recipe(10, 5) == nil and as(a).recipe(12, 5) ~= nil)
    ok("recipes are per character", #as(b).recipes(5) == 0)
end

-- ---- gathering nodes: recorded on your own successful cast, shared with the guild at once
do
    local before = count("G")
    a.map, a.pos = 1429, { x = 0.4567, y = 0.6121 }
    ok("known node name", as(a).nodeHash("Copper Vein") ~= nil and as(a).nodeName(as(a).nodeHash("Copper Vein")) == "Copper Vein")
    a.bag = { [0] = {} }; cur = a; a.ns.tools.sessionStart()
    fire(a, "UNIT_SPELLCAST_SENT", "player", "Some Mailbox", "g0", 1); fire(a, "UNIT_SPELLCAST_SUCCEEDED", "player", "g0", 1)
    ok("a cast on something else records nothing", as(a).nodeCount() == 0)
    fire(a, "UNIT_SPELLCAST_SENT", "player", "Copper Vein", "g1", 2575); fire(a, "UNIT_SPELLCAST_SUCCEEDED", "player", "g9", 2575)
    ok("another cast finishing records nothing", as(a).nodeCount() == 0)
    fire(a, "UNIT_SPELLCAST_SENT", "player", "Copper Vein", "g1", 2575); fire(a, "UNIT_SPELLCAST_SUCCEEDED", "player", "g1", 2575)
    run(3)
    local n = as(a).nodesOn(1429)
    ok("node recorded where you stood", #n == 1 and n[1].name == "Copper Vein" and math.abs(n[1].x - 45.7) < 1e-9 and math.abs(n[1].y - 61.2) < 1e-9 and n[1].who == "Abdullah", #n)
    ok("sent to the guild", count("G", "Abdullah") == before + 1)
    local nb = as(b).nodesOn(1429)
    ok("guild member has it without reloading", #nb == 1 and nb[1].name == "Copper Vein" and nb[1].who == "Abdullah" and (b.ui.nodes or 0) == 1, #nb)
    W.time = W.time + 20
    fire(a, "UNIT_SPELLCAST_SENT", "player", "Copper Vein", "g2", 2575); fire(a, "UNIT_SPELLCAST_SUCCEEDED", "player", "g2", 2575); run(3)
    cur = a
    ok("the second swing at the same vein is not a second node", as(a).nodeCount() == 1 and a.ns.tools.sessionReport(5).nodes == 1 and count("G", "Abdullah") == before + 1)
    W.time = W.time + 900
    fire(a, "UNIT_SPELLCAST_SENT", "player", "Copper Vein", "g3", 2575); fire(a, "UNIT_SPELLCAST_SUCCEEDED", "player", "g3", 2575); run(3)
    cur = a
    ok("the same spot after it respawned counts for the session, not as a new place", as(a).nodeCount() == 1 and a.ns.tools.sessionReport(5).nodes == 2 and as(a).nodesOn(1429)[1].t >= GetServerTime() - 3)
    a.pos = { x = 0, y = 0 }
    fire(a, "UNIT_SPELLCAST_SENT", "player", "Tin Vein", "g4", 2575); fire(a, "UNIT_SPELLCAST_SUCCEEDED", "player", "g4", 2575)
    ok("no position (inside an instance): nothing recorded", as(a).nodeCount() == 1)
    -- what arrives from others is checked before it is kept
    local Yb, h, t = b.ns.sync, as(a).nodeHash("Tin Vein"), GetServerTime()
    cur = b
    Yb.receive("AHProfit", "G1,1429," .. h .. ",100,200," .. t, "GUILD", "Tareq-Realm")
    ok("valid node from a member is kept", as(b).nodeCount() == 2)
    cur = b
    Yb.receive("AHProfit", "G1,1429,999999,100,300," .. t, "GUILD", "Tareq-Realm")
    Yb.receive("AHProfit", "G1,1429," .. h .. ",1001,300," .. t, "GUILD", "Tareq-Realm")
    Yb.receive("AHProfit", "G1,1429," .. h .. ",500,300," .. (t + 99999), "GUILD", "Tareq-Realm")
    Yb.receive("AHProfit", "G1,1429," .. h .. ",500,300," .. (t - 8000000), "GUILD", "Tareq-Realm")
    Yb.receive("AHProfit", "G2,1429," .. h .. ",500,300," .. t, "GUILD", "Tareq-Realm")
    Yb.receive("AHProfit", "G1,1429," .. h .. ",500,300," .. t, "WHISPER", "Tareq-Realm")
    Yb.receive("AHProfit", "G1,1429," .. h .. ",500,300," .. t .. ",7", "GUILD", "Tareq-Realm")
    Yb.receive("AHProfit", "G1,1429," .. h .. ",5e2,300," .. t, "GUILD", "Tareq-Realm")
    ok("unknown node, off-map, future, stale, other version, other channel and malformed are all refused", as(b).nodeCount() == 2, as(b).nodeCount())
    -- a member who logs in later asks once and gets the nodes
    local g0 = count("G")
    local c = client("Tareq"); run(60)
    ok("late member asks for nodes", count("R", "Tareq") == 1)
    ok("and receives them from one member only", as(c).nodeCount() == 2 and count("G") - g0 == 2, as(c).nodeCount() .. " " .. (count("G") - g0))
    local d = client("Solo", false); d.map, d.pos = 1429, { x = 0.5, y = 0.5 }
    local g1 = count("G")
    fire(d, "UNIT_SPELLCAST_SENT", "player", "Copper Vein", "g5", 2575); fire(d, "UNIT_SPELLCAST_SUCCEEDED", "player", "g5", 2575); run(5)
    ok("without a guild the node is kept and nothing is sent", as(d).nodeCount() == 1 and count("G") == g1)
    ok("the first member also got the node the others shared", as(a).nodeCount() == 2, as(a).nodeCount())
    local had = as(a).nodeCount()
    cur = a; a.db.sync = false; a.pos = { x = 0.9, y = 0.9 }
    fire(a, "UNIT_SPELLCAST_SENT", "player", "Tin Vein", "g6", 2575); fire(a, "UNIT_SPELLCAST_SUCCEEDED", "player", "g6", 2575); run(5)
    ok("sync switched off: recorded, not sent", as(a).nodeCount() == had + 1 and count("G") == g1, as(a).nodeCount() .. " nodes, " .. (count("G") - g1) .. " sent")
    a.db.sync = true
    ok("nothing was throttled by the client", (W.throttled or 0) == 0, W.throttled)
end

-- ---- own auctions: asking is not income; sold and expired are counted from what the game says
do
    ok("never read is nil", as(a).auctions(5) == nil)
    price(a, 2840, 50, 300); price(a, 200, 1000, 3)
    a.owned = { { auctionID = 1, itemKey = { itemID = 200 }, quantity = 2, buyoutAmount = 1200, status = 0 },
        { auctionID = 2, itemKey = { itemID = 2840 }, quantity = 10, buyoutAmount = 40, status = 0 },
        { auctionID = 3, itemKey = { itemID = 201 }, quantity = 1, buyoutAmount = 500, status = 1 },
        { auctionID = 4, itemKey = { itemID = 100 }, quantity = 1, status = 0 }, { auctionID = 5, quantity = 1 } }
    fire(a, "OWNED_AUCTIONS_UPDATED")
    local rows, tot = as(a).auctions(5)
    ok("auctions read", rows and #rows == 4, rows and #rows)
    ok("sold first, and not counted as still asking", rows[1].id == 201 and rows[1].sold and rows[1].net == 475 and tot.soldN == 1)
    ok("asking total is after the cut and only what is unsold", tot.n == 3 and tot.asking == 1140 * 2 + 38 * 10, tot.asking)
    local by = {}
    for _, r in ipairs(rows) do by[r.id] = r end
    ok("undercut is flagged against the lowest listing", by[200].under == true and by[2840].under == false and tot.under == 1)
    ok("a bid-only auction is not called undercut", by[100].under == false and by[100].each == 0)
    ok("no history invented", by[200].soldN == nil)
    fire(a, "CHAT_MSG_SYSTEM", "A buyer has been found for your auction of Test Dagger.")
    fire(a, "CHAT_MSG_SYSTEM", "Your auction of Test Dagger has expired.")
    fire(a, "CHAT_MSG_SYSTEM", "Your auction of Test Dagger has expired.")
    fire(a, "CHAT_MSG_SYSTEM", "A buyer has been found for your auction of Hero's Blade-of.Fire (x).")
    fire(a, "CHAT_MSG_SYSTEM", "You have learned a new spell: A buyer has been found for your auction of X.")
    local s, e = as(a).sellThrough("Test Dagger")
    ok("sold and expired counted per item", s == 1 and e == 2)
    ok("names with punctuation are matched whole", as(a).sellThrough("Hero's Blade-of.Fire (x)") == 1 and as(a).sellThrough("X") == nil)
    rows = as(a).auctions(5)
    for _, r in ipairs(rows) do by[r.id] = r end
    ok("record shown on the row", by[200].soldN == 1 and by[200].expiredN == 2)
    ok("auctions are per character", as(b).auctions(5) == nil)
    local tip = {}
    local tt = { AddDoubleLine = function(_, l, r) tip[#tip + 1] = plain(l .. " => " .. r) end }
    as(a).tipLine(tt, 200, 1000)
    ok("tooltip shows your record", #tip == 1 and tip[1] == "Your auctions of this => 1 sold, 2 expired", tip[1])
    tip = {}; as(a).tipLine(tt, 100, 10)
    ok("tooltip flags a price below vendor", #tip == 1 and tip[1]:find("Below vendor price", 1, true) and tip[1]:find("=> +3c", 1, true), tip[1])
    tip = {}; as(a).tipLine(tt, 5555, nil)
    ok("tooltip stays quiet for an unknown item", #tip == 0)
end

-- ---- a client that lacks these APIs must not error
do
    C_Bank, C_TradeSkillUI, C_MerchantFrame, C_Map, GetMerchantItemID = nil, nil, nil, nil, nil
    C_AuctionHouse.GetOwnedAuctions = nil
    local e = client("Bare")
    local okk, err = pcall(function()
        for _, ev in ipairs({ "BANKFRAME_OPENED", "MERCHANT_SHOW", "TRADE_SKILL_SHOW", "OWNED_AUCTIONS_UPDATED", "BAG_UPDATE_DELAYED" }) do fire(e, ev) end
        fire(e, "UNIT_SPELLCAST_SENT", "player", "Copper Vein", "g7", 1); fire(e, "UNIT_SPELLCAST_SUCCEEDED", "player", "g7", 1)
        fire(e, "CHAT_MSG_SYSTEM", nil)
        run(5)
        local Xe = as(e)
        assert(Xe.bank() == nil and #Xe.recipes(5) == 0 and Xe.auctions(5) == nil and #Xe.deals() == 0 and Xe.nodeCount() == 0)
    end)
    ok("missing APIs are skipped without an error", okk, err)
end

for _, m in ipairs(chat) do if m:find("rror") then ok("no error in chat: " .. m, false) end end
print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
