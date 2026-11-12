-- Bags-full advisor (Bags.lua). Run: lua test/bagfull_test.lua
local W = { time = 1794400000, secret = {}, class = "WARRIOR", bags = {}, ah = {}, loot = {}, opened = 0 }
-- id -> name, quality, max stack, vendor, classID, item family
local IT = {
    [2589] = { "Linen Cloth", 1, 20, 13, 7, 0 }, [2770] = { "Copper Ore", 1, 20, 5, 7, 1024 }, [765] = { "Silverleaf", 1, 20, 5, 7, 32 },
    [2880] = { "Weak Flux", 1, 20, 25, 7, 0 }, [3300] = { "Rabbit's Foot", 0, 5, 10, 15, 0 }, [4306] = { "Silk Cloth", 1, 20, 150, 7, 0 },
    [1200] = { "Rusty Sword", 0, 1, 30, 2, 0 }, [1201] = { "Fine Sword", 2, 1, 900, 2, 0 }, [1202] = { "Bound Ring", 2, 1, 0, 4, 0 },
    [5000] = { "Quest Thing", 1, 1, 0, 12, 0 }, [5001] = { "Starts a Quest", 1, 1, 0, 15, 0 }, [6948] = { "Hearthstone", 1, 1, 0, 15, 0 },
    [5100] = { "Some Key", 1, 1, 0, 13, 0 }, [2901] = { "Mining Pick", 1, 1, 10, 2, 0 }, [5140] = { "Flash Powder", 1, 20, 6, 15, 0 },
    [4540] = { "Tough Hunk of Bread", 1, 20, 1, 0, 0 }, [4541] = { "Stale Bread", 0, 20, 1, 0, 0 }, [7777] = { "Mystery", 1, 1, 0, 15, 0 },
    [7778] = { "Mystery Two", 1, 1, 0, 15, 0 }, [9999] = { "Gem of Value", 3, 1, 5000, 15, 0 },
}
local handlers, chat, timers = {}, {}, {}
function issecretvalue(v) return W.secret[v] == true end
function GetServerTime() return W.time end
time = GetServerTime
date = os.date
function GetRealmName() return "Realm" end
function UnitName() return "Abdullah" end
function UnitFactionGroup() return "Alliance", "Alliance" end
function UnitClass() return "Class", W.class end
ERR_INV_FULL = "Inventory is full."
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) chat[#chat + 1] = m end }
C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
C_Item = { GetItemInfo = function(id) local i = IT[id]; if not i then return nil end
        return i[1], "|cff|Hitem:" .. id .. "::|h[" .. i[1] .. "]|h|r", i[2], 1, 1, "t", "st", i[3], "", 77, i[4], i[5], 0, 0 end,
    GetItemFamily = function(id) return IT[id] and IT[id][6] or 0 end }
-- bags[b] = { size, family, slots = { [slot] = { id, n, bound, quest } } }
C_Container = {
    GetContainerNumSlots = function(b) local x = W.bags[b]; if W.boomSlots then error("no") end return x and x.size or 0 end,
    GetContainerNumFreeSlots = function(b) local x = W.bags[b]; local n = 0
        if not x then return 0, 0 end
        for s = 1, x.size do if not x.slots[s] then n = n + 1 end end
        return n, x.family end,
    GetContainerItemInfo = function(b, s) local x = W.bags[b] and W.bags[b].slots[s]; if not x then return nil end
        if x.boom then error("unreadable") end
        return { itemID = x[1], stackCount = x[2], isBound = x[3] == true, hyperlink = "|cffffffff|Hitem:" .. tostring(x[1]) .. "::|h[" .. tostring(IT[x[1]] and IT[x[1]][1]) .. "]|h|r", iconFileID = 1 } end,
    GetContainerItemQuestInfo = function(b, s) local x = W.bags[b].slots[s]; return { isQuestItem = false, questID = x and x.quest or nil } end,
}
function GetNumLootItems() return #W.loot end
function GetLootSlotLink(i) return W.loot[i] and ("|Hitem:" .. W.loot[i][1] .. "::|h") end
function GetLootSlotInfo(i) return 1, "x", W.loot[i][2] end
function OpenAllBags() W.opened = W.opened + 1 end
function GetTime() return W.clock or W.time end
-- frames: event frames keep their handler; anything else accepts any call
local FM = {}
FM.__index = function(t, k)
    if k == "IsShown" then return function(self) return rawget(self, "shown") == true end end
    if k == "Show" then return function(self) self.shown = true end end
    if k == "Hide" then return function(self) self.shown = false end end
    if k == "SetText" then return function(self, s) self.txt = s end end
    if k == "GetText" then return function(self) return rawget(self, "txt") end end
    if k == "SetScript" then return function(self, ev, fn) local s = rawget(self, "scripts") or {}; rawset(self, "scripts", s); s[ev] = fn; if ev == "OnEvent" then handlers[self] = fn end end end
    if k == "RegisterEvent" then return function(self, e) local s = rawget(self, "events") or {}; rawset(self, "events", s); s[e] = true end end
    if k == "GetPoint" then return function() return "TOP", nil, "TOP", 10, -100 end end
    if k == "CreateTexture" or k == "CreateFontString" then return function() return setmetatable({}, FM) end end
    if type(k) == "string" and k:match("^%u") then return function() end end   -- any other method
    return nil                                                   -- data fields: nil, as on a real frame
end
function CreateFrame() return setmetatable({}, FM) end
UIParent = setmetatable({}, FM)
SlashCmdList = {}
local ns
local pass, fail = 0, 0
local function ok(name, cond, extra) if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. " " .. tostring(extra or "")) end end
local function fire(ev, ...)
    for f, fn in pairs(handlers) do
        local evs = rawget(f, "events")
        if ev == "ADDON_LOADED" or ev == "PLAYER_LOGIN" or ev == "PLAYER_LOGOUT" or (evs and evs[ev]) then fn(f, ev, ...) end
    end
end
local function boot(saved)
    AHProfitDB = saved; ns = {}; handlers = {}
    for _, f in ipairs({ "Data.lua", "Core.lua", "Bags.lua" }) do assert(loadfile("AHProfit/" .. f))("AHProfit", ns) end
    fire("ADDON_LOADED", "AHProfit"); fire("PLAYER_LOGIN")
    ns.lookup = function(id) local p = W.ah[id]; if p then return p, 5, W.time, "scan" end end
    return AHProfitDB
end
local function plain(s) return (tostring(s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")) end
-- a bag of size n filled with the given stacks; nil entries are free slots
local function bag(size, family, list)
    local slots = {}
    for i = 1, size do slots[i] = list[i] end
    return { size = size, family = family or 0, slots = slots }
end
local function full(n, id) local t = {}; for i = 1, n do t[i] = { id or 4306, 20 } end return t end   -- n full stacks of silk
local B
local function setup(bags) W.bags = bags; W.ah = {}; boot({}); B = ns.bags end

-- ---- free fix first: merging partial stacks
setup({ [0] = bag(4, 0, { { 2589, 5 }, { 2589, 7 }, { 1200, 1 }, { 4306, 20 } }) })
local a = B.advise(nil)
ok("merge: two partial stacks that fit in one are suggested before any destroy", a and a.kind == "merge" and a.id == 2589 and a.frees == 1, a and a.kind)
ok("merge: the text says so", plain(B.text(a)[1]) == "Merge [Linen Cloth] (frees 1 slot)" or plain(B.text(a)[1]):find("^Merge .*Linen Cloth.* %(frees 1 slot%)$"), plain(B.text(a)[1]))
setup({ [0] = bag(4, 0, { { 2589, 15 }, { 2589, 15 }, { 1200, 1 }, { 4306, 20 } }) })
a = B.advise(nil)
ok("merge: partial stacks that still need two slots free nothing", a and a.kind == "destroy", a and a.kind)

-- ---- an incoming item that stacks onto a partial stack: no alert
setup({ [0] = bag(3, 0, { { 2589, 5 }, { 1200, 1 }, { 4306, 20 } }) })
ok("incoming: stacks onto its own partial stack, no advice", B.advise(2589) == nil)
ok("incoming: another item gets advice", B.advise(2880) ~= nil)

-- ---- bag families
setup({ [0] = bag(2, 0, { { 4306, 20 } }), [1] = bag(2, 32, { { 765, 20 }, { 765, 20 } }) })
ok("families: herb bag full, general bag has room: no advice for a sword", B.advise(1201) == nil and B.advise(nil) == nil)
setup({ [0] = bag(2, 0, { { 4306, 20 }, { 1200, 1 } }), [1] = bag(2, 32, { { 765, 20 } }) })
a = B.advise(1201)
ok("families: general bags full, herb bag free: advice for a sword", a and a.kind == "destroy" and a.slot.bag == 0, a and a.kind)
ok("families: ...but a herb fits in the herb bag", B.advise(765) == nil)
ok("families: a herb in the herb bag is never offered for a sword", a.slot.id ~= 765)
setup({ [0] = bag(2, 0, { { 4306, 20 }, { 4306, 20 } }), [1] = bag(2, 32, { { 765, 3 }, { 765, 20 } }) })
a = B.advise(nil)
ok("families: a general item's advice never uses the herb bag (its partial stacks do not merge for it)", a and a.kind == "destroy" and a.slot.bag == 0, a and a.kind)

-- ---- slot value: count x unit value; AH after the cut when higher and not bound; unknown after known; grey first
setup({ [0] = bag(3, 0, { { 2770, 1 }, { 2589, 20 }, { 7777, 1 } }) })
a = B.advise(nil)
ok("value: 1 ore (5c) before 20 cloth (2s 60c)", a.slot.id == 2770 and a.value == 5 and a.how == "vendor", a.slot.id)
W.ah[2770] = 1000
a = B.advise(nil)
ok("value: the ore at the AH (9s 50c after the cut) is now worth more than the cloth", a.slot.id == 2589 and a.value == 260, a.slot.id .. " " .. tostring(a.value))
W.ah[2589] = 2; W.ah[7777] = nil
a = B.advise(nil)
ok("value: an AH price below the vendor's leaves the vendor value", a.slot.id == 2589 and a.value == 260)
setup({ [0] = bag(2, 0, { { 7777, 1 }, { 7778, 1 } }) })
a = B.advise(nil)
ok("value: when everything is unknown, one is still offered, marked unknown", a.kind == "destroy" and a.unknown and plain(B.text(a)[1]):find("value unknown", 1, true), plain(B.text(a)[1]))
setup({ [0] = bag(3, 0, { { 7777, 1 }, { 2589, 20 }, { 1201, 1 } }) })
a = B.advise(nil)
ok("value: unknown is ranked after known", a.slot.id == 2589)
setup({ [0] = bag(2, 0, { { 2589, 1 }, { 3300, 5 } }) })
a = B.advise(nil)
ok("value: the cheapest slot wins even over grey (1 linen 13c before 5 grey feet 50c)", a.slot.id == 2589 and a.value == 13 and not a.grey, a.slot.id)
W.loot = { { 2880, 1 } }                                         -- a 25c drop: worth more than the 13c slot
local Lg = B.lootCompare()
ok("value: ...and the skip-drop comparison uses that cheapest slot (25c drop: take it)", Lg and Lg.advice.value == 13 and Lg.drop.value == 25 and not Lg.skip, Lg and Lg.advice.value)
W.loot = {}
setup({ [0] = bag(2, 0, { { 2880, 1 }, { 3300, 1 } }) })
W.ah[2880] = nil; IT[3300][4] = 25
a = B.advise(nil)
ok("value: at the same value, grey first", a.grey and a.slot.id == 3300, a.slot.id)
IT[3300][4] = 10
setup({ [0] = bag(2, 0, { { 1201, 1, true }, { 4306, 20 } }) })
W.ah[1201] = 99999
a = B.advise(nil)
ok("value: a bound item has no AH value (vendor only)", a.slot.id == 1201 and a.value == 900 and a.how == "vendor", tostring(a.value))

-- ---- never suggested
setup({ [0] = bag(12, 0, { { 5000, 1 }, { 5001, 1, false, quest = 1 }, { 6948, 1 }, { 5100, 1 }, { 2901, 1 }, { 4540, 5 }, { 1202, 1, true }, { 9999, 1 }, { 5140, 5 }, { 4541, 3 }, { 1201, 1 }, { 2589, 20 } }) })
W.bags[0].slots[2].quest = 1234
local protectedIds = { 5000, 5001, 6948, 5100, 2901, 4540, 1202 }
local cands = {}
for _, s in ipairs(select(2, B.scan())) do if not B.protected(s) then cands[s.id] = true end end
local leaked = {}
for _, id in ipairs(protectedIds) do if cands[id] then leaked[#leaked + 1] = id end end
ok("never: quest items, quest starters, hearthstone, keys, tools, usable food, bound vendor-0 items", #leaked == 0, table.concat(leaked, ","))
ok("never: grey food and ordinary items stay eligible", cands[4541] and cands[1201] and cands[2589] and cands[9999])
ok("never: another class's reagent stays eligible for a warrior", cands[5140])
W.class = "ROGUE"
cands = {}
for _, s in ipairs(select(2, B.scan())) do if not B.protected(s) then cands[s.id] = true end end
ok("never: the player's own class reagents", not cands[5140])
W.class = "WARRIOR"
a = B.advise(nil)
ok("never: the first suggestion is the grey food (cheapest grey)", a.slot.id == 4541, a.slot.id)
-- equipment sets
C_EquipmentSet = { GetEquipmentSetIDs = function() return { 1 } end, GetItemLocations = function() return { [16] = 777 } end }
function EquipmentManager_UnpackLocation(loc) if loc == 777 then return true, false, true, false, 11, 0 end end
ok("never: an item in an equipment set", B.protected({ bag = 0, slot = 11, id = 1201, n = 1 }) ~= nil)
C_EquipmentSet, EquipmentManager_UnpackLocation = nil, nil

-- ---- keep list: slash, persistence, caps, load check
setup({ [0] = bag(2, 0, { { 2770, 1 }, { 2589, 20 } }) })
SlashCmdList.AHPROFIT("keep |cff9d9d9d|hitem:2770::::::::|h[copper ore]|h|r")
local db = AHProfitDB
a = B.advise(nil)
ok("keep: a kept item is never suggested", db.keep[2770] == true and a.slot.id == 2589)
SlashCmdList.AHPROFIT("unkeep 2770")
ok("keep: unkeep removes it", db.keep[2770] == nil and B.advise(nil).slot.id == 2770)
for i = 1, 600 do B.keep(100000 + i) end
local n = 0; for _ in pairs(db.keep) do n = n + 1 end
ok("keep: at most 500 ids", n == 500 and not B.keep(999999), n)
db.keep["x"] = true; db.keep[5.5] = true; db.keep[7] = "yes"; db.bagfull = "lots"
db = boot(db)
n = 0; for _ in pairs(db.keep) do n = n + 1 end
ok("keep: bad entries dropped at load, the list kept", n == 500 and db.keep.x == nil and db.keep[5.5] == nil and db.keep[7] == nil and db.bagfull == nil, n)
SlashCmdList.AHPROFIT("keep nothing")
ok("keep: a bad argument explains itself", chat[#chat]:find("/ahp keep <item link or item id>", 1, true))

-- ---- loot comparison, both directions
setup({ [0] = bag(2, 0, { { 2770, 1 }, { 4306, 20 } }) })
W.loot = { { 9999, 1 } }
local L = B.lootCompare()
ok("loot: a 50s drop against a 5c slot: take it", L and L.drop.value == 5000 and L.advice.value == 5 and not L.skip)
local txt = plain(table.concat(B.text(L.advice, L), " / "))
ok("loot: the text compares them", txt:find("Drop is worth 50s 0c, your cheapest slot is 5c.", 1, true) and not txt:find("skip", 1, true), txt)
setup({ [0] = bag(1, 0, { { 4306, 20 } }) })
W.loot = { { 2770, 1 } }
L = B.lootCompare()
txt = plain(table.concat(B.text(L.advice, L), " / "))
ok("loot: a 5c drop against a 30s slot: skip it", L and L.skip and txt:find("Keep your bags; skip this drop.", 1, true), txt)
W.loot = { { 4306, 1 } }
setup({ [0] = bag(2, 0, { { 4306, 19 }, { 2770, 1 } }) })
ok("loot: a drop that stacks onto a partial stack needs no comparison", B.lootCompare() == nil)
W.loot = {}

-- ---- events: the alert
setup({ [0] = bag(2, 0, { { 2770, 1 }, { 4306, 20 } }) })
fire("UI_ERROR_MESSAGE", 3, "Inventory is full.")
ok("event: 'Inventory is full' shows the advice", B.lastText and plain(B.lastText[1]):find("Cheapest slot: ", 1, true), B.lastText and plain(B.lastText[1]))
B.lastText = nil
fire("UI_ERROR_MESSAGE", 3, "Something else.")
ok("event: other errors show nothing", B.lastText == nil)
setup({ [0] = bag(2, 0, { { 2770, 1 }, { 4306, 20 } }) })
fire("BAG_UPDATE_DELAYED")
ok("event: the bags filling up show the advice once", B.lastText ~= nil)
B.lastText = nil; fire("BAG_UPDATE_DELAYED")
ok("event: ...not again while they stay full", B.lastText == nil)
W.bags[0].slots[1] = nil; fire("BAG_UPDATE_DELAYED"); W.bags[0].slots[1] = { 2770, 1 }; fire("BAG_UPDATE_DELAYED")
ok("event: ...and again after a slot was freed and filled", B.lastText ~= nil)
SlashCmdList.AHPROFIT("bagfull off"); B.lastText = nil
fire("UI_ERROR_MESSAGE", 3, "Inventory is full."); W.bags[0].slots[1] = nil; fire("BAG_UPDATE_DELAYED"); W.bags[0].slots[1] = { 2770, 1 }; fire("BAG_UPDATE_DELAYED")
ok("event: /ahp bagfull off silences it", B.lastText == nil and AHProfitDB.bagfull == -1)
SlashCmdList.AHPROFIT("bagfull 1"); W.bags[0].slots[1] = nil
fire("BAG_UPDATE_DELAYED")
ok("event: /ahp bagfull 1 warns with one slot left", B.lastText ~= nil and AHProfitDB.bagfull == 1)
SlashCmdList.AHPROFIT("bagfull 0"); W.bags[0].slots[1] = { 2770, 1 }
-- the alert's buttons: Show opens the bags and names the slot; Keep adds the item and shows the next advice
setup({ [0] = bag(3, 0, { { 2770, 1 }, { 2589, 20 }, { 4306, 20 } }) })
fire("UI_ERROR_MESSAGE", 3, "Inventory is full.")
local fr = B.frame()
local opened = W.opened
rawget(fr.show, "scripts").OnClick()
ok("alert: Show never opens the bags; with them closed it names the slot in chat", W.opened == opened and chat[#chat]:find("bag 1, slot 1 (open your bags to see it).", 1, true), chat[#chat])
rawget(fr.keepBtn, "scripts").OnClick()
ok("alert: Keep adds the item to the keep list and moves on to the next slot", AHProfitDB.keep[2770] == true and plain(B.lastText[1]):find("Linen Cloth", 1, true), B.lastText and plain(B.lastText[1]))
ok("alert: it is shown", fr:IsShown())
rawget(fr.close, "scripts").OnClick()
ok("alert: Close hides it", not fr:IsShown())
-- the loot case through events
setup({ [0] = bag(1, 0, { { 4306, 20 } }) })
W.loot = { { 2770, 1 } }
fire("LOOT_OPENED"); fire("UI_ERROR_MESSAGE", 3, "Inventory is full.")
ok("event: with the loot window open the alert compares the drop", B.lastText and plain(table.concat(B.lastText, " ")):find("skip this drop", 1, true), B.lastText and plain(table.concat(B.lastText, " ")))
fire("LOOT_CLOSED"); W.loot = {}

-- ---- cost: a bag update with free slots reads no slot; a full scan of 5 x 36 slots stays small
setup({ [0] = bag(36, 0, {}), [1] = bag(36, 0, {}), [2] = bag(36, 0, {}), [3] = bag(36, 0, {}), [4] = bag(36, 0, {}) })
local reads, realInfo = 0, C_Container.GetContainerItemInfo
C_Container.GetContainerItemInfo = function(...) reads = reads + 1; return realInfo(...) end
fire("BAG_UPDATE_DELAYED")
ok("cost: a bag update with free slots reads no slot", reads == 0, reads)
local ids = { 2589, 2770, 2880, 4306, 1201, 1200, 3300, 9999 }
for b = 0, 4 do for s = 1, 36 do W.bags[b].slots[s] = { ids[(b * 36 + s) % #ids + 1], 1 } end end
local t0 = os.clock()
for _ = 1, 20 do fire("BAG_UPDATE_DELAYED"); B.advise(nil) end
local ms = (os.clock() - t0) * 1000 / 40
print(string.format("COST full 180-slot advice %.2f ms each", ms))
ok("cost: full advice over 180 slots under 5 ms", ms < 5, ms)
C_Container.GetContainerItemInfo = realInfo

-- ---- review fixes (PR-F)
-- F1: the bags were sorted after the alert: a bag update re-reads the shown slot and re-advises; Show re-checks
setup({ [0] = bag(3, 0, { { 2589, 1 }, { 9999, 1 }, { 4306, 20 } }) })
fire("BAG_UPDATE_DELAYED")
ok("F1: the alert names the linen in slot 1", plain(B.lastText[1]):find("Linen Cloth", 1, true))
W.bags[0].slots[1], W.bags[0].slots[2] = W.bags[0].slots[2], W.bags[0].slots[1]   -- sorted: the gem moves to slot 1
fire("BAG_UPDATE_DELAYED")
local fr1 = B.frame()
rawget(fr1.show, "scripts").OnClick()
ok("F1: after a swap the advice follows the linen to slot 2", plain(B.lastText[1]):find("Linen Cloth", 1, true) and chat[#chat]:find("slot 2", 1, true), chat[#chat])
-- the same swap with the alert not refreshed by a bag update (Show alone)
W.bags[0].slots[1], W.bags[0].slots[2] = W.bags[0].slots[2], W.bags[0].slots[1]
rawget(fr1.show, "scripts").OnClick()
ok("F1: Show re-checks the slot before naming it", chat[#chat]:find("slot 1", 1, true) and plain(B.lastText[1]):find("Linen Cloth", 1, true), chat[#chat])
-- F3: pooled, unnamed item buttons in an open bag frame; the bags are never opened by the addon
local function button(bagID, slot) local b = setmetatable({}, FM); rawset(b, "GetBagID", function() return bagID end); rawset(b, "GetID", function() return slot end); return b end
local pool = setmetatable({}, FM); rawset(pool, "shown", true)
local btns = { button(0, 3), button(0, 1), button(0, 2) }
rawset(pool, "EnumerateValidItems", function() local i = 0; return function() i = i + 1; if btns[i] then return i, btns[i] end end end)
function ContainerFrameUtil_EnumerateContainerFrames() local i = 0; local list = { pool }; return function() i = i + 1; if list[i] then return i, list[i] end end end
local before = W.opened
rawget(fr1.show, "scripts").OnClick()
ok("F3: with the bag open, the pooled button for the slot is marked", B.marked == btns[2] and W.opened == before and chat[#chat]:find("bag 1, slot 1.", 1, true), chat[#chat])
rawset(pool, "shown", false)
rawget(fr1.show, "scripts").OnClick()
ok("F3: with the bag closed, only the chat line", B.marked == nil and W.opened == before)
rawset(pool, "EnumerateValidItems", function() error("broken pool") end); rawset(pool, "shown", true)
ok("F3: a broken bag frame is ignored", pcall(rawget(fr1.show, "scripts").OnClick) and B.marked == nil)
ContainerFrameUtil_EnumerateContainerFrames = nil
-- F4: slot reads
setup({ [0] = bag(36, 0, full(36)), [1] = bag(36, 0, full(36)), [2] = bag(36, 0, full(36)), [3] = bag(36, 0, full(36)), [4] = bag(36, 0, full(36)) })
W.bags[0].slots[1] = { 2589, 1 }
local reads, realInfo2 = 0, C_Container.GetContainerItemInfo
C_Container.GetContainerItemInfo = function(...) reads = reads + 1; return realInfo2(...) end
fire("BAG_UPDATE_DELAYED")
local first = reads; reads = 0
for _ = 1, 20 do fire("BAG_UPDATE_DELAYED") end
ok("F4: while full and alerted, a bag update reads only the shown slot", first == 180 and reads == 20, first .. " / " .. reads)
reads = 0
W.clock = 100
for _ = 1, 20 do fire("UI_ERROR_MESSAGE", 3, "Inventory is full."); W.clock = W.clock + 0.01 end
ok("F4: a burst of 20 full errors within half a second scans once", reads == 180, reads)
reads = 0; W.clock = W.clock + 1
W.loot = { { 2770, 1 }, { 2880, 1 }, { 9999, 1 }, { 765, 1 }, { 1201, 1 } }
fire("LOOT_OPENED"); fire("UI_ERROR_MESSAGE", 3, "Inventory is full.")
ok("F4: a 5-item loot window reads the bags once", reads == 180, reads)
fire("LOOT_CLOSED"); W.loot = {}
C_Container.GetContainerItemInfo = realInfo2
-- should-fixes
setup({ [0] = bag(3, 0, { { 8000, 200 }, { 8001, 1 }, { 2589, 20 } }) })
IT[8000] = { "Rough Arrow", 1, 200, 1, 6, 1 }
local s8 = { bag = 0, slot = 1, id = 8000, n = 200 }
ok("never: ammunition", B.protected(s8) ~= nil)
ok("never: an item the client has not loaded yet is skipped", B.protected({ bag = 0, slot = 2, id = 8001, n = 1 }) == "not loaded yet")
IT[8000] = nil
local tx = plain(table.concat(B.text({ kind = "destroy", slot = { id = 2589, n = 1 }, value = nil, unknown = true }, { drop = { value = 500 } }), " / "))
ok("text: an unknown slot value is not called the drop's", tx:find("Drop is worth 5s 0c; your cheapest slot's value is not known.", 1, true), tx)
tx = plain(table.concat(B.text({ kind = "destroy", slot = { id = 2589, n = 1 }, value = 13 }, { drop = { value = nil } }), " / "))
ok("text: an unknown drop value", tx:find("The drop's value is not known; your cheapest slot is 13c.", 1, true), tx)
setup({ [0] = bag(2, 0, { { 2770, 1 }, { 4306, 20 } }) })
for i = 1, 500 do B.keep(300000 + i) end
fire("UI_ERROR_MESSAGE", 3, "Inventory is full.")
rawget(B.frame().keepBtn, "scripts").OnClick()
ok("keep: with the list full, Keep says so and claims nothing", chat[#chat]:find("keep list is full", 1, true) and AHProfitDB.keep[2770] == nil, chat[#chat])
db = boot({ v = 99, keep = { [5] = true, x = "bad" }, bagfull = "lots" })
ok("newer save: keep and bagfull are left as they are", db.keep.x == "bad" and db.bagfull == "lots")
setup({ [0] = bag(1, 0, { { 2770, 1 } }) })
AHProfitDB.bagAlertPos = { "NOWHERE", "BAD", 1, 2 }
local realCF = CreateFrame
CreateFrame = function(...) local fr = realCF(...); rawset(fr, "SetPoint", function(_, p) if p == "NOWHERE" then error("bad point") end end); return fr end
ok("position: a damaged saved position falls back without an error", pcall(fire, "UI_ERROR_MESSAGE", 3, "Inventory is full.") and B.lastText ~= nil)
CreateFrame = realCF

-- ---- unreadable client data never errors
setup({ [0] = bag(2, 0, { { 2770, 1 }, { 4306, 20 } }) })
W.bags[0].slots[1].boom = true
ok("robust: an unreadable slot is skipped", pcall(B.advise, nil))
W.bags[0].slots[1] = { 2770, 1 }
W.secret[2770] = true
local okS, aS = pcall(B.advise, nil)
ok("robust: a secret item id is skipped", okS and (aS == nil or aS.slot == nil or aS.slot.id ~= 2770))
W.secret[2770] = nil
W.boomSlots = true
ok("robust: a failing bag size call gives no advice and no error", select(2, pcall(B.advise, nil)) == nil); W.boomSlots = nil
local saved = C_Container; C_Container = nil
ok("robust: no container API, no advice, no error", select(2, pcall(B.advise, nil)) == nil); C_Container = saved
local savedI = C_Item; C_Item = nil
ok("robust: no item API, no error", pcall(B.advise, nil)); C_Item = savedI

-- ---- advice only: nothing in the addon acts on items
local src = ""
for _, f in ipairs({ "Bags.lua", "Core.lua", "Tools.lua", "Extra.lua", "UI.lua", "Sync.lua", "Farm.lua" }) do src = src .. assert(io.open("AHProfit/" .. f)):read("*a") end
local bad = {}
for _, fn in ipairs({ "DeleteCursorItem", "PickupContainerItem", "UseContainerItem", "SplitContainerItem", "PickupItem", "AutoEquipCursorItem", "SellCursorItem" }) do
    if src:find(fn, 1, true) then bad[#bad + 1] = fn end
end
ok("advice only: no call that deletes, moves, uses or sells an item", #bad == 0, table.concat(bad, ","))
ok("advice only: the bags are never opened by the addon (taint)", not assert(io.open("AHProfit/Bags.lua")):read("*a"):find("OpenAllBags", 1, true))

for _, m in ipairs(chat) do if m:find("rror") then ok("no error in chat: " .. m, false) end end
print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
