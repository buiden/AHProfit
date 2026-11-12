-- Farm window test against a strict mock client. Run from the project directory, after test/parity.py:
--   lua test/ui_test.lua
-- Unknown frame methods raise an error, frames start shown, and the expected numbers come from the farm page's own code.
local REF = dofile("test/parity_ref.lua")
local seedTime = tonumber(assert(io.open("AHProfit/Data.lua")):read("*a"):match("ns%.seed = { t = (%d+)"))
local W = { time = seedTime + 600, combat = false, level = 43, skills = {}, canPin = true, pins = {}, secret = {} }
local NOOP = {}
for m in ([[SetSize SetPoint SetFrameStrata SetMovable EnableMouse SetClampedToScreen RegisterForDrag StartMoving StopMovingOrSizing
    SetBackdrop SetBackdropColor SetBackdropBorderColor SetAllPoints ClearAllPoints SetAutoFocus SetNumeric SetMaxLetters ClearFocus
    LockHighlight UnlockHighlight SetHighlightTexture SetJustifyH SetJustifyV SetTextColor SetSpacing SetAlpha SetColorTexture
    SetThickness SetStartPoint SetEndPoint RegisterEvent SetScrollChild SetNormalFontObject SetHighlightFontObject]]):gmatch("%S+") do NOOP[m] = true end
local M = {}
local MT = { __index = function(_, k)
    if M[k] then return M[k] end
    if NOOP[k] then return function() end end
    if type(k) == "string" and k:match("^%u") then error("unknown frame method " .. k, 2) end
    return nil
end }
local function new(kind, parent)
    local o = setmetatable({ kind = kind, shown = true, scripts = {}, kids = {}, w = 0, h = 0 }, MT)
    if parent then parent.kids[#parent.kids + 1] = o end
    return o
end
function M:Show() self.shown = true; if self.scripts.OnShow then for _, f in ipairs(self.scripts.OnShow) do f(self) end end end
function M:Hide() self.shown = false end
function M:IsShown() return self.shown end
function M:SetShown(v) assert(type(v) == "boolean", "SetShown needs a boolean"); self.shown = v end
function M:SetScript(n, fn) self.scripts[n] = { fn } end
function M:HookScript(n, fn) self.scripts[n] = self.scripts[n] or {}; table.insert(self.scripts[n], fn) end
function M:SetText(t) assert(type(t) == "string" or type(t) == "number", "SetText needs text"); self.text = tostring(t) end
function M:GetText() return self.text or "" end
function M:SetChecked(v) self.checked = v and true or false end
function M:GetChecked() return self.checked end
function M:HasFocus() return false end
function M:SetWidth(w) self.w = w end
function M:SetHeight(h) self.h = h end
function M:GetWidth() return self.w end
function M:GetHeight() return self.h end
function M:GetStringHeight() local _, n = (self.text or ""):gsub("\n", ""); return 12 * (n + 1) end
function M:CreateFontString() return new("FontString", self) end
function M:CreateTexture() return new("Texture", self) end
function M:CreateLine() return new("Line", self) end
M.SetSize = function(self, w, h) self.w, self.h = w, h end
local chat, coreEvents = {}, nil
local frames = {}
function CreateFrame(kind, name, parent)
    local f = new(kind, parent)
    frames[#frames + 1] = f
    if name then _G[name] = f end
    return f
end
UIParent = new("Frame")
UISpecialFrames = {}
WorldMapFrame = new("Frame"); WorldMapFrame.shown = false; WorldMapFrame.mapID = 1
local canvas = new("Frame"); canvas.w, canvas.h = 1000, 660
function WorldMapFrame:GetCanvas() return canvas end
function WorldMapFrame:GetMapID() return self.mapID end
function WorldMapFrame:OnMapChanged() end
function WorldMapFrame:SetMapID(id) self.mapID = id; self:OnMapChanged() end
function OpenWorldMap(id) WorldMapFrame:Show(); WorldMapFrame:SetMapID(id) end
function hooksecurefunc(t, name, fn) local old = t[name]; t[name] = function(...) old(...); fn(...) end end
function InCombatLockdown() return W.combat end
function issecretvalue(v) return W.secret[v] == true end
function UnitLevel() return W.level end
function CreateVector2D(x, y) return { x = x, y = y } end
C_SkillInfo = { GetNumSkillLines = function() return #W.skills end, GetSkillLineInfo = function(i) return W.skills[i] end }
C_Map = { CanSetUserWaypointOnMap = function() return W.canPin end, SetUserWaypoint = function(p) W.pins[#W.pins + 1] = p; return true end }
C_SuperTrack = { SetSuperTrackedUserWaypoint = function(v) W.tracked = v end }
date = os.date
function GetServerTime() return W.time end
time = function() return W.time end
function GetRealmName() return "TestRealm" end
function UnitFactionGroup() return "Alliance", "Alliance" end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) chat[#chat + 1] = m end }
C_Timer = { After = function() end }
C_Item = { GetItemInfo = function() return nil end, GetItemCount = function() return 0 end }
Enum = { TooltipDataType = { Item = 0 }, AuctionHouseSortOrder = { Price = 0 } }
TooltipDataProcessor = { AddTooltipPostCall = function() end }
C_AuctionHouse = {}
SlashCmdList = {}

local pass, fail = 0, 0
local function ok(name, cond, extra) if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. " " .. tostring(extra or "")) end end
local function close(a, b) return math.abs(a - b) <= 1e-9 * math.max(1, math.abs(a), math.abs(b)) end
local function plain(s) return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
local function load(ns, list) for _, f in ipairs(list) do assert(loadfile("AHProfit/" .. f))("AHProfit", ns) end end
-- Fires the addon's load event on Core's event frame (the newest frame with an OnEvent script).
local function loaded()
    for i = #frames, 1, -1 do
        local h = frames[i].scripts.OnEvent
        if h then h[1](frames[i], "ADDON_LOADED", "AHProfit"); return true end
    end
    error("Core event frame not found")
end
local function shownKids(f, kind) local n = 0; for _, k in ipairs(f.kids) do if k.kind == kind and k.shown then n = n + 1 end end return n end

-- ---- no farm data: the window says so instead of failing
do
    local ns = {}
    load(ns, { "Data.lua", "Core.lua", "Farm.lua", "UI.lua" })
    loaded()
    ns.ui:Toggle()
    ok("missing data message", ns.ui.status:GetText():find("Farm data is missing", 1, true), ns.ui.status:GetText())
    AHProfitDB = nil; AHProfitFarmFrame = nil; SlashCmdList = {}; UISpecialFrames = {}
end

local ns = {}
load(ns, { "Data.lua", "FarmData.lua", "Core.lua" })
load(ns, { "Farm.lua", "UI.lua" })
local UI, F = ns.ui, ns.farm

-- ---- first run reads the character
W.skills = { { skillID = 129, rank = 300 }, { skillID = 2946, parentSkillLineID = 186, rank = 231 }, { skillID = 164, rank = 215 },
    { skillID = 393, rank = W.secret }, { isHeader = true, name = "Professions" } }
W.secret[W.secret] = true
loaded()
ok("load event sets defaults", AHProfitDB and AHProfitDB.cut == 5 and AHProfitDB.farm == nil)
SlashCmdList.AHPROFIT("farm")
local S = AHProfitDB.farm
ok("window opens", AHProfitFarmFrame and AHProfitFarmFrame:IsShown())
ok("first run uses character", S.lvMin == 38 and S.lvMax == 48 and S.mining and S.mSkill == 231 and S.blacksmithing and S.bSkill == 215 and not S.herbalism and not S.skinning,
    string.format("%s-%s m%s %s b%s %s h%s s%s", S.lvMin, S.lvMax, tostring(S.mining), S.mSkill, tostring(S.blacksmithing), S.bSkill, tostring(S.herbalism), tostring(S.skinning)))
ok("escape closes it", UISpecialFrames[1] == "AHProfitFarmFrame")
SlashCmdList.AHPROFIT("farm"); ok("second /ahp farm closes", not AHProfitFarmFrame:IsShown())
SlashCmdList.AHPROFIT("farm")
W.skills = {}; S.mining = true; S.mSkill = 99; UI:Detect(S); ok("no professions reported keeps the setup", S.mining and S.mSkill == 99)
W.secret[43] = true; S.lvMin = 5; UI:Detect(S); ok("hidden level keeps the range", S.lvMin == 5); W.secret[43] = nil
C_SkillInfo.GetNumSkillLines = function() error("blocked") end; ok("skill api failure is survived", UI:Detect(S) == false)

-- ---- every scenario, every tab: same options, order and values as the page
local KEYS = { "lvMin", "lvMax", "mining", "herbalism", "mSkill", "hSkill", "blacksmithing", "bSkill", "skinning" }
local compared = 0
for si, sc in ipairs(REF.scenarios) do
    for _, k in ipairs(KEYS) do S[k] = sc[k] end
    AHProfitDB.cut = sc.cut
    local r = REF.ref[si]
    local want = { mine = {}, mobs = {}, fish = {}, craft = {} }
    for _, z in ipairs(r.zones) do table.insert(want.mine, { z[1], z[2] }) end
    for _, m in ipairs(r.mobs) do table.insert(want.mobs, { m[1], m[2] }) end
    for _, m in ipairs(r.fish) do table.insert(want.fish, { m[1], m[2] }) end
    for _, m in ipairs(r.trunks) do table.insert(want.fish, { m[1], m[2] }) end
    for _, c in ipairs(r.crafts) do table.insert(want.craft, { c[1], c[5] }) end
    for tab, w in pairs(want) do
        S.tab = tab; UI.sel = nil
        local okRun, err = pcall(UI.Refresh, UI)
        local e = UI.entries or {}
        local same = okRun and #e == #w
        for i = 1, (same and #w or 0) do
            compared = compared + 1
            if plain(e[i].left):sub(1, #w[i][1]) ~= w[i][1] or not close(e[i].v, w[i][2]) then same = false; err = i .. ": " .. plain(e[i].left) .. " " .. e[i].v .. " vs " .. w[i][1] .. " " .. w[i][2]; break end
        end
        ok("scenario " .. si .. " " .. tab, same, err or (#e .. " vs " .. #w))
        local rows = 0
        for _, row in ipairs(UI.rows) do if row.shown then rows = rows + 1 end end
        ok("scenario " .. si .. " " .. tab .. " rows", rows == #w, rows)
        if #w == 0 then ok("scenario " .. si .. " " .. tab .. " says why it is empty", #UI.empty:GetText() > 20 and UI.detail:GetText() == "", UI.empty:GetText())
        else ok("scenario " .. si .. " " .. tab .. " detail", #UI.detail:GetText() > 40 and UI.empty:GetText() == "") end
        for i, x in ipairs(e) do
            local o1, d = pcall(x.detail)
            local o2, m = true, nil
            if x.map then o2, m = pcall(x.map) end
            if not (o1 and o2 and #d >= 2) then ok("scenario " .. si .. " " .. tab .. " entry " .. i, false, tostring(d) .. tostring(m)) end
        end
    end
end
ok("values compared with the page", compared > 300, compared)

-- ---- maps (scenario 1: defaults)
for _, k in ipairs(KEYS) do S[k] = REF.scenarios[1][k] end
AHProfitDB.cut = 5
local R1 = REF.ref[1]
S.tab = "mine"; UI.sel = 1; UI:Refresh()
local zm = UI.entries[1].map()
local cells = 0; for _ in pairs(zm.score) do cells = cells + 1 end
local routeSame = #zm.pts == #R1.zones[1][4]
for i, p in ipairs(R1.zones[1][4]) do if not (zm.pts[i] and close(zm.pts[i].x, p[1]) and close(zm.pts[i].y, p[2])) then routeSame = false end end
ok("route stops match the page", routeSame and #zm.pts > 2, #zm.pts)
ok("zone has a map id", zm.mapID == F.mapFor(R1.zones[1][1]) and zm.mapID > 0, zm.mapID)
UI:Act("map")
local overlay = canvas.kids[#canvas.kids]
ok("world map opened on the zone", WorldMapFrame:IsShown() and WorldMapFrame.mapID == zm.mapID)
ok("squares, loop lines and stop numbers drawn", shownKids(overlay, "Texture") == cells and shownKids(overlay, "Line") == #zm.pts and shownKids(overlay, "FontString") == #zm.pts,
    shownKids(overlay, "Texture") .. "/" .. cells .. " " .. shownKids(overlay, "Line") .. " " .. shownKids(overlay, "FontString"))
WorldMapFrame:SetMapID(1); ok("other map shows nothing", shownKids(overlay, "Texture") + shownKids(overlay, "Line") + shownKids(overlay, "FontString") == 0)
WorldMapFrame:SetMapID(zm.mapID); ok("back on the zone it shows again", shownKids(overlay, "Texture") == cells)
UI:Act("pin")
local pin = W.pins[#W.pins]
ok("pin on first loop stop", pin and pin.uiMapID == zm.mapID and close(pin.position.x, zm.pts[1].x / 100) and close(pin.position.y, zm.pts[1].y / 100) and W.tracked == true)
S.tab = "mobs"; UI.sel = 1; UI:Refresh()
local m1 = R1.mobs[1]
UI:Act("map")
ok("mob dots = recorded spawn points", shownKids(overlay, "Texture") == m1[6] and shownKids(overlay, "Line") == 0 and m1[6] > 0, shownKids(overlay, "Texture") .. " vs " .. m1[6])
UI:Act("pin"); pin = W.pins[#W.pins]
ok("mob pin on densest area", close(pin.position.x, m1[3] / 100) and close(pin.position.y, m1[4] / 100), pin.position.x .. "," .. pin.position.y)
ok("pin note", UI.note:GetText():find("Pin set", 1, true))
W.canPin = false; local n = #W.pins; UI:Act("pin"); ok("refused pin is reported", #W.pins == n and UI.note:GetText():find("Cannot", 1, true)); W.canPin = true
W.combat = true; UI:ClearMap(); UI:Act("map"); ok("no map opening in combat", shownKids(overlay, "Texture") == 0 and UI.note:GetText():find("combat", 1, true)); W.combat = false
UI:Act("map"); UI:ClearMap(); ok("clear map", shownKids(overlay, "Texture") == 0)
S.tab = "craft"; UI.sel = 1; UI:Refresh(); ok("crafting has no map buttons", not UI.mapBtn:IsShown() and not UI.wayBtn:IsShown())
S.tab = "fish"; UI.sel = 1; UI:Refresh(); ok("fishing zone has map button", UI.mapBtn:IsShown())
UI.sel = #UI.entries; UI:Refresh(); ok("trunk has no map button", not UI.mapBtn:IsShown())

-- ---- controls
S.tab = "mine"; UI:Refresh()
UI.boxes.lvMin:SetText("55"); UI.boxes.lvMin.scripts.OnEditFocusLost[1](); ok("level box pushes the other end", S.lvMin == 55 and S.lvMax == 55 and UI.boxes.lvMax:GetText() == "55")
UI.boxes.lvMin:SetText(""); UI.boxes.lvMin.scripts.OnEditFocusLost[1](); ok("empty box becomes 1", S.lvMin == 1)
UI.checks.herbalism:SetChecked(true); UI.checks.herbalism.scripts.OnClick[1](); ok("tick herbalism", S.herbalism == true and UI.boxes.hSkill:IsShown())
UI.tabs.craft.scripts.OnClick[1](); ok("tab click", S.tab == "craft" and UI.head:GetText():find("per craft", 1, true))
SlashCmdList.AHPROFIT("cut 15"); ok("cut change refreshes the window", UI.status:GetText():find("15% cut", 1, true), UI.status:GetText())
SlashCmdList.AHPROFIT("cut 5")
local before = collectgarbage("count"); local t0 = os.clock()
for i = 1, 200 do S.tab = ({ "mine", "mobs", "fish", "craft" })[i % 4 + 1]; UI:Refresh() end
print(string.format("refresh cost: %.2f ms each, %.0f KB garbage each (runs only when you click)", (os.clock() - t0) * 1000 / 200, (collectgarbage("count") - before) / 200))

-- ---- the farm window uses your own (newer) auction prices, not only the bundled farm data
do
    for _, k in ipairs(KEYS) do S[k] = REF.scenarios[1][k] end
    AHProfitDB.cut = 5
    local CUT, T = 0.95, F.time()
    local L = ns.live()
    local function snap()
        local out = {}
        for _, z in ipairs(F.zones(S, CUT)) do out[#out + 1] = z.name .. "=" .. z.val end
        for _, m in ipairs(F.mobs(S, CUT)) do out[#out + 1] = m.name .. "=" .. m.v end
        for _, c in ipairs(F.crafts(S, CUT)) do out[#out + 1] = c.name .. "=" .. c.own .. "/" .. c.profit end
        return table.concat(out, ";")
    end
    local base = snap()
    -- the bundled feed is the same snapshot as the farm data: on its own it changes nothing
    ok("no scan: same ranking and values as the page", base == snap() and next(L.p) == nil)
    -- the zone ranked last becomes first once your scan prices its main ore very high
    local zs = F.zones(S, CUT)
    local last = zs[#zs]
    local node, ore
    for _, r in ipairs(last.rows) do if r.ok then node = r; break end end
    local nd = ns.farmData[3][node.ni]
    ore = F.item(nd[6][1])
    L.p[ore[2]], L.q[ore[2]], L.t[ore[2]] = 50000000, 7, T + 60
    local zs2, rank, v2 = F.zones(S, CUT), nil, nil
    for i, z in ipairs(zs2) do if z.name == last.name then rank, v2 = i, z.val end end
    local function order(list) local o = {}; for _, z in ipairs(list) do o[#o + 1] = z.name end return table.concat(o, ",") end
    ok("a newer own scan changes the zone ranking", #zs > 1 and order(zs2) ~= order(zs) and v2 > last.val * 100, order(zs2) .. " " .. tostring(v2) .. " vs " .. last.val)
    local d = F.drops({ nd[6][1], 1 }, CUT)
    ok("drops show the scanned price and its listed count", d[1] and d[1].each == 50000000 * CUT and d[1].listed == 7, d[1] and (d[1].each .. " " .. d[1].listed))
    ok("best() uses the scanned price", F.best(nd[6][1], CUT) == 50000000 * CUT)
    S.tab = "mine"; UI:Refresh()
    ok("the status line says a newer price counts", UI.status:GetText():find("or the addon's newer price for the item", 1, true), UI.status:GetText())
    -- a scan older than the farm data does not override it
    L.t[ore[2]] = T - 60
    ok("an older scan leaves the ranking alone", snap() == base)
    -- a price from Auctionator (seen today, after the farm data) has no listed count: never "only 0 listed"
    do
        local t0, rt = W.time, time
        W.time = T + 2 * 86400
        time = function(x) if type(x) == "table" then return 1577836800 end return W.time end
        Auctionator = { API = { v1 = { GetAuctionAgeByItemID = function(_, id) return id == ore[2] and 0 or nil end,
            GetAuctionPriceByItemID = function(_, id) return id == ore[2] and 4000 or nil end } } }
        local da = F.drops({ nd[6][1], 1 }, CUT)
        ok("drops: an Auctionator price is used, with no listed count and not called thin", da[1] and da[1].each == math.max(4000 * CUT, ore[5])
            and da[1].listed == nil and da[1].thin == false, da[1] and tostring(da[1].listed) .. " " .. tostring(da[1].thin))
        Auctionator, time, W.time = nil, rt, t0
    end
    -- crafting: a scanned bar price moves the craft's numbers
    local cr = F.crafts(S, CUT)[1]
    L.p[cr.id], L.q[cr.id], L.t[cr.id] = 90000000, 3, T + 60
    local cr2
    for _, c in ipairs(F.crafts(S, CUT)) do if c.id == cr.id then cr2 = c end end
    ok("a newer own scan of the crafted item changes its value", cr2 and cr2.net == 90000000 * cr.makes * CUT, cr2 and cr2.net)
    -- an item the farm data does not list in its price list counts once you have scanned it
    local unl
    for i, it in ipairs(ns.farmData[2]) do if it[6] ~= 1 and it[5] == 0 then unl = i; break end end
    if unl then
        local it = F.item(unl)
        L.p[it[2]], L.q[it[2]], L.t[it[2]] = 1234, 2, T + 60
        ok("a scanned item outside the bundled price list gets a value", F.best(unl, CUT) == 1234 * CUT, F.best(unl, CUT))
    end
    -- the ranking returns to the page's once the scans are gone; nothing breaks before the saved data loads
    for _, k in ipairs({ "p", "q", "t" }) do L[k] = {} end
    ok("scans cleared: back to the page's values", snap() == base)
    local saved = ns.lookup
    ns.lookup = function() error("not ready") end
    ok("a failing price lookup falls back to the farm data", pcall(snap) and snap() == base)
    ns.lookup = saved
end

-- ---- a crafted item priced by Auctionator (no listed count): its detail opens and claims no count
do
    local t0, rt = W.time, time
    W.time = F.time() + 2 * 86400
    time = function(x) if type(x) == "table" then return 1577836800 end return W.time end
    Auctionator = { API = { v1 = { GetAuctionAgeByItemID = function(_, id) return id == 2862 and 0 or nil end,
        GetAuctionPriceByItemID = function(_, id) return id == 2862 and 100 or nil end } } }
    local s = AHProfitDB.farm
    s.mining, s.blacksmithing, s.mSkill, s.bSkill, s.tab = true, true, 300, 300, "craft"
    UI.sel = nil
    local sel
    for i, x in ipairs(UI:Entries()) do if x.left == "Rough Sharpening Stone" then sel = i end end
    UI.sel = sel
    local okR, err = pcall(UI.Refresh, UI)
    local d = okR and UI.detail and UI.detail:GetText() or ""
    ok("craft detail with an Auctionator price opens and leaves the listed count out", sel ~= nil and okR and d ~= "" and not d:find("listed", 1, true),
        tostring(sel) .. " " .. tostring(err) .. " " .. d:sub(1, 120))
    Auctionator, time, W.time = nil, rt, t0
    UI.sel = 1; UI:Refresh()
end

-- ================================================================ bags, deposits, session and price history ==
do
    AHProfitDB = nil; AHProfitFarmFrame = nil; SlashCmdList = {}; UISpecialFrames = {}
    local pts = {}
    M.SetPoint = function(self, ...) self.point = { ... } end
    M.SetStartPoint = function(self, _, _, x, y) self.x0, self.y0 = x, y end
    M.SetEndPoint = function(self, _, _, x, y) self.x1, self.y1 = x, y end
    local IT = {                       -- id -> name, vendor, bind, class
        [900001] = { "Test Ore", 500, 0, 7 }, [900002] = { "Thin Margin", 500, 0, 7 }, [900003] = { "Half Bound Sword", 100, 2, 2 },
        [900004] = { "Worthless", 0, 0, 7 }, [900005] = { "Pickup Only", 50, 1, 4 }, [900006] = { "Quest Thing", 0, 4, 12 },
    }
    C_Item.GetItemInfo = function(id) local i = IT[id]; if not i then return nil end
        return i[1], "l", 1, 1, 1, "t", "st", 20, "", 1, i[2], i[4], 0, i[3] end
    W.bag = { [0] = { { 900001, 6 }, false, { 900002, 4 }, { 900003, 2, true }, { 900003, 3 } }, [1] = { { 900001, 4 }, { 900004, 1 }, { 900005, 1, true }, { 900006, 1 }, { 900007, 2 } } }
    C_Container = { GetContainerNumSlots = function(b) return W.bag[b] and #W.bag[b] or 0 end,
        GetContainerItemInfo = function(b, s) local x = W.bag[b] and W.bag[b][s]; if not x then return nil end
            return { itemID = x[1], stackCount = x[2], isBound = x[3] == true } end }
    W.money = 100000
    function GetMoney() return W.money end
    ItemLocation = { CreateFromBagAndSlot = function(_, b, s) return { b = b, s = s } end }
    Enum.ItemCommodityStatus = { Unknown = 0, Item = 1, Commodity = 2 }
    local asked = {}
    C_AuctionHouse = {
        GetItemCommodityStatus = function(loc) local x = W.bag[loc.b][loc.s]; return x[1] == 900003 and 1 or 2 end,
        CalculateCommodityDeposit = function(id, d, q) assert(d == 2); asked[id] = q; return id == 900001 and q * 7 or 0 end,
        CalculateItemDeposit = function(loc, d, q) assert(d == 2 and q == 1); asked.loc = loc; return 33 end,
    }
    local n2 = {}
    local mark = #frames
    load(n2, { "Data.lua", "FarmData.lua", "History.lua", "Core.lua", "Sync.lua", "Farm.lua", "Tools.lua", "Extra.lua", "UI.lua" })
    local core                                                   -- Core's event frame: the first one this load created
    for i = mark + 1, #frames do
        local h = frames[i].scripts.OnEvent
        if h then core = core or frames[i]; h[1](frames[i], "ADDON_LOADED", "AHProfit") end
    end
    local T, U = n2.tools, n2.ui
    local function fire(ev, a) core.scripts.OnEvent[1](core, ev, a) end
    local Lv = n2.live()
    local function price(id, p, q) Lv.p[id], Lv.q[id], Lv.t[id] = p, q, W.time end
    price(900001, 600, 50); price(900002, 520, 9); price(900003, 1000, 1); price(900005, 9999, 1)

    -- ---- bag advisor: the 5s vendor / 6s auction example, soulbound stacks, pickup-only, quest and unloaded items
    local rows, tot = T.advise(T.bags(), 5)
    local by = {}
    for _, r in ipairs(rows) do by[r.id] = r end
    ok("6s on the AH against 5s at a vendor is +70c each after the 5% cut", by[900001].verdict == "ah" and by[900001].net == 570 and by[900001].gain == 700 and by[900001].value == 5700, by[900001].gain)
    ok("a margin the cut eats goes to the vendor", by[900002].verdict == "vendor" and by[900002].value == 2000)
    ok("soulbound part is vendored, the rest auctioned", by[900003].verdict == "ah" and by[900003].free == 3 and by[900003].value == 950 * 3 + 100 * 2)
    ok("pickup-only is never auctioned", by[900005].verdict == "vendor" and by[900005].value == 50)
    ok("worthless and quest items are left out", by[900004] == nil and by[900006] == nil and tot.kept == 2)
    ok("unloaded item is counted as pending, not guessed", tot.pending == 1 and by[900007] == nil)
    ok("totals", tot.ah == 8550 and tot.vendor == 2250 and tot.all == 7550 and tot.extra == 3250, tot.ah .. " " .. tot.vendor .. " " .. tot.all .. " " .. tot.extra)
    ok("best first", rows[1].id == 900001 and rows[2].id == 900003)
    local r15 = T.advise(T.bags(), 15)
    ok("at a 15% cut the same item is +10c each", r15[1].id == 900001 and r15[1].net == 510 and r15[1].gain == 100)
    ok("no deposit is invented while the auction house is closed", tot.risk == 0 and tot.unmeasured == 2 and T.deposit(900001) == nil)

    -- ---- the window
    SlashCmdList.AHPROFIT("bags")
    local S2 = AHProfitDB.farm
    ok("/ahp bags opens the bags tab", AHProfitFarmFrame:IsShown() and S2.tab == "bags")
    ok("status without full scans names only the feed", plain(U.status:GetText()):find("^Prices: the feed from "), plain(U.status:GetText()))
    if n2.shared then
        local Hs = n2.shared(); Hs.full = W.time - 600; Lv.full = W.time - 1800; U:Refresh()
        ok("status names your scan and the guild's separately", plain(U.status:GetText()):find("Prices: your scan 30m ago, a guild scan 10m ago, else the feed from ", 1, true), plain(U.status:GetText()))
        Hs.full = 0; Lv.full = 0; U:Refresh()
    else ok("status names your scan and the guild's separately", false, "no shared layer") end
    ok("bags headline", plain(U.head:GetText()):find("Auction 2 for 85s 50c, vendor the rest for 22s 50c: 32s 50c more than vendoring it all.", 1, true), plain(U.head:GetText()))
    ok("bags headline says one is loading", plain(U.head:GetText()):find("1 still loading", 1, true))
    ok("setup rows hidden on a tool tab", not U.boxes.lvMin:IsShown() and not U.checks.mining:IsShown() and U.intro:GetText() ~= "")
    ok("no map buttons on a tool tab", not U.mapBtn:IsShown() and not U.graph:IsShown() and not U.sessBtn:IsShown())
    ok("detail explains the row", plain(U.detail:GetText()):find("Auction instead of vendor: +7s 0c for your 10", 1, true) and plain(U.detail:GetText()):find("Deposit not measured yet", 1, true), plain(U.detail:GetText()))
    do  -- a price with no listed count (Auctionator) does not claim "0 listed"
        local real = n2.lookup
        n2.lookup = function(id) local p, q, t, s, f = real(id); if id == 900001 and p then return p, nil, W.time, "auctionator" end return p, q, t, s, f end
        U:Refresh()
        local d = plain(U.detail:GetText())
        ok("bags detail: an Auctionator price is named and has no listed count", d:find("AH lowest (Auctionator, today): ", 1, true) and not d:find("each, ", 1, true) and not d:find("0 listed", 1, true), (d:gsub("\n", " | ")))
        n2.lookup = real; U:Refresh()
    end

    -- ---- deposits are read from the game once the auction house is open
    fire("AUCTION_HOUSE_SHOW")
    ok("opening the auction house measures deposits", T.deposit(900001) and T.deposit(900001)[1] == 7 and asked[900001] == 10)
    ok("an item (not a commodity) uses the item deposit of a stack that can be listed", T.deposit(900003)[1] == 33 and asked.loc.b == 0 and asked.loc.s == 5)
    ok("a zero answer for an unknown item is not stored", T.deposit(900005) == nil)
    local _, tot2 = T.advise(T.bags(), 5)
    ok("deposit at risk is totalled", tot2.risk == 70 + 99 and tot2.unmeasured == 0, tot2.risk)
    ok("detail shows the measured deposit", plain(U.detail:GetText()):find("Deposit for", 1, true) and plain(U.detail:GetText()):find(": 70c, lost if it does not sell", 1, true), plain(U.detail:GetText()))
    local tip = {}
    n2.addLines({ AddDoubleLine = function(_, l, r) tip[#tip + 1] = plain(l .. " => " .. r) end }, 900001)
    ok("tooltip is three lines without Shift", #tip == 3, #tip)
    tip = {}; IsShiftKeyDown = function() return true end
    n2.addLines({ AddDoubleLine = function(_, l, r) tip[#tip + 1] = plain(l .. " => " .. r) end }, 900001)
    IsShiftKeyDown = nil
    ok("with Shift the tooltip carries the deposit line", tip[#tip]:find("Deposit, lost if it does not sell", 1, true) and tip[#tip]:find("=> 7c", 1, true), tip[#tip])
    fire("AUCTION_HOUSE_CLOSED"); W.time = W.time + 5

    -- ---- session: measured coin and items
    ok("no session yet", T.sessionReport(5) == nil)
    SlashCmdList.AHPROFIT("session")
    ok("session tab invites a start", S2.tab == "sess" and U.sessBtn:IsShown() and U.sessBtn:GetText() == "Start session" and U.detail:GetText():find("No session yet", 1, true))
    U.sessBtn.scripts.OnClick[1]()
    ok("start button starts", T.sessionOn() and U.sessBtn:GetText() == "Stop session")
    W.money = W.money + 120; fire("PLAYER_MONEY")
    W.bag[0][2] = { 900001, 5 }; fire("BAG_UPDATE_DELAYED")                          -- looted 5 ore
    fire("MERCHANT_SHOW")
    W.bag[0][2] = { 900001, 3 }; W.money = W.money + 1000; fire("PLAYER_MONEY"); fire("BAG_UPDATE_DELAYED")   -- sold 2 of them
    W.bag[1][6] = { 900002, 3 }; W.money = W.money - 300; fire("PLAYER_MONEY"); fire("BAG_UPDATE_DELAYED")    -- bought 3, repaired
    fire("MERCHANT_CLOSED"); W.time = W.time + 5
    W.bag[0][3] = { 900002, 3 }; fire("BAG_UPDATE_DELAYED")                          -- used one that was there before the session
    fire("MAIL_SHOW"); W.money = W.money + 4000; fire("PLAYER_MONEY"); W.bag[1][7] = { 900004, 9 }; fire("BAG_UPDATE_DELAYED"); fire("MAIL_CLOSED")
    W.time = W.time + 1795
    local R = T.sessionReport(5)
    ok("coin is split by where it came from", R.inc.loot == 120 and R.inc.vendor == 1000 and R.inc.mail == 4000 and R.out.vendor == 300 and R.coinIn == 5120 and R.coinOut == 300)
    ok("sold items stop counting, bought and mailed ones never count", #R.gained == 1 and R.gained[1].id == 900001 and R.gained[1].n == 3 and R.gainedValue == 3 * 570, #R.gained .. " " .. R.gainedValue)
    ok("materials used up are a cost", #R.used == 1 and R.used[1].id == 900002 and R.used[1].n == 1 and R.usedValue == 500)
    ok("elapsed time", R.elapsed == 1800, R.elapsed)
    U:Refresh()
    local d = plain(U.detail:GetText())
    ok("session text: measured coin per hour", d:find("Coin, measured: +48s 20c  =  +96s 40c per hour", 1, true), d)
    ok("session text: coin plus items", d:find("Coin plus items: +60s 30c  =  +1g 20s 60c per hour", 1, true), d)
    ok("session text: says what is an estimate", d:find("an estimate", 1, true) and d:find("Posted auctions count as nothing", 1, true))
    ok("session list shows the gain", #U.entries == 1 and plain(U.rows[1].left:GetText()):find("Test Ore x3", 1, true))
    fire("PLAYER_LOGOUT"); W.time = W.time + 50000; T.init()
    ok("time logged out is not farming time", T.sessionReport(5).elapsed == 1800, T.sessionReport(5).elapsed)
    W.time = W.time + 60; SlashCmdList.AHPROFIT("session stop"); W.time = W.time + 999
    ok("stop freezes the clock", not T.sessionOn() and T.sessionReport(5).elapsed == 1860)
    W.money = W.money + 77; fire("PLAYER_MONEY")
    ok("nothing is counted after stop", T.sessionReport(5).coinIn == 5120)
    U:Refresh(); ok("button offers a new session", U.sessBtn:GetText() == "Start new session")
    W.secret[W.money] = true; SlashCmdList.AHPROFIT("session start"); W.secret[W.money] = nil
    W.money = W.money + 5; fire("PLAYER_MONEY"); W.money = W.money + 5; fire("PLAYER_MONEY")
    ok("a hidden money value is never used as a starting point", T.sessionReport(5).coinIn == 5, T.sessionReport(5).coinIn)

    -- ---- price history: the real file
    local raw = assert(io.open("AHProfit/History.lua")):read("*a")
    local _, count = raw:gsub('{"', "")
    local all = T.histList()
    ok("every material of the history file is listed", #all == count and count > 100, #all .. " vs " .. count)
    local io1 = {}
    for _, m in ipairs(T.histList("iron ore")) do if m.name == "Iron Ore" then io1[#io1 + 1] = m end end
    ok("search matches part of a name", #T.histList("iron ore") >= 2 and #T.histList("iron ore") < 10)
    local d1, p1 = raw:match('{"Iron Ore",2772,(%d+),(%d+),')
    ok("search finds Iron Ore with its day-1 price", #io1 == 1 and io1[1].id == 2772 and io1[1].day1 == tonumber(d1) and io1[1].day1p == tonumber(p1))
    SlashCmdList.AHPROFIT("prices")
    ok("prices tab", S2.tab == "hist" and U.graph:IsShown() and U.search:IsShown() and #U.entries == count)
    ok("nothing chosen yet", U.graph.text:GetText():find("Pick a material", 1, true) and U.series == nil)
    U.search:SetText("Iron Ore"); U.search.scripts.OnTextChanged[1]()
    local at
    for i, e in ipairs(U.entries) do if e.id == 2772 then at = i end end
    ok("typing filters the list", #U.entries == #T.histList("iron ore") and at ~= nil)
    U.rows[at].scripts.OnClick[1]()
    local fp = n2.lookup(2772)
    ok("choosing draws the real series", S2.histId == 2772 and U.series and U.series.id == 2772 and plain(U.graph.text:GetText()):find("Day 1 (" .. T.dayText(tonumber(d1)) .. "): " .. plain(n2.money(tonumber(p1))), 1, true), plain(U.graph.text:GetText()))
    ok("the difference since day 1 is price now minus day 1", U.graphInfo.diff == fp - tonumber(p1) and U.graphInfo.now == fp)
    U.search:SetText(""); U.search.scripts.OnTextChanged[1]()
    ok("the choice survives clearing the search", S2.histId == 2772 and U.entries[U.sel].id == 2772)

    -- ---- price history: a known series, to check the drawing
    local today = math.floor((W.time + 10800) / 86400)
    n2.hist = { W.time, { today - 4, 5 }, { { "Test Ore", 900001, today - 3, 100, 0, 100, 0, 150, 200 } } }
    price(900001, 600, 50)                                       -- priced now: the clock of this test has moved on by hours, sometimes past midnight
    S2.histId = 900001; U:Refresh()
    local g = U.graph
    local function shown(kind) local t = {}; for _, o in ipairs(g.pool[kind]) do if o.shown then t[#t + 1] = o end end return t end
    local lines, dots = shown("line"), shown("dot")
    ok("three daily points plus now", #dots == 4 and U.graphInfo.n == 4, #dots)
    ok("no line is drawn across a day without listings", #lines == 3, #lines)
    ok("graph text: day 1, now and the difference", plain(g.text:GetText()):find("Day 1 (" .. T.dayText(today - 3) .. "): 1s 0c     Since day 1: +5s 0c  +500.0%", 1, true), plain(g.text:GetText()))
    ok("day 1 sits at the left edge and now at the right edge", close(dots[1].point[4], 74) and close(dots[4].point[4], 74 + 486), dots[1].point[4] .. " " .. dots[4].point[4])
    ok("higher price is drawn higher", dots[4].point[5] > dots[3].point[5] and dots[3].point[5] > dots[2].point[5] and dots[2].point[5] > dots[1].point[5])
    ok("everything stays inside the plot", dots[4].point[5] <= -78 and dots[1].point[5] >= -78 - 122)
    ok("the day-1 level line runs across at the day-1 price", lines[1].isBase and close(lines[1].y0, dots[1].point[5]) and close(lines[1].y0, lines[1].y1) and close(lines[1].x1 - lines[1].x0, 486))
    ok("axis labels", plain(g.hi:GetText()) == "6s 0c" and plain(g.lo:GetText()) == "1s 0c" and g.to:GetText() == "now" and g.from:GetText() == T.dayText(today - 3))
    Lv.p[900001], Lv.q[900001], Lv.t[900001] = nil, nil, nil
    U:Refresh()
    ok("not listed now: falls back to the last day, and says so", plain(g.text:GetText()):find("not listed now, last seen at 2s 0c", 1, true) and plain(g.text:GetText()):find("Since day 1: +1s 0c  +100.0%", 1, true) and #shown("dot") == 3, plain(g.text:GetText()))
    n2.hist = { W.time, { today, 1 }, { { "Test Ore", 900001, today, 100, 100 } } }
    U:Refresh()
    ok("a single day draws one point without dividing by zero", #shown("dot") == 1 and plain(g.text:GetText()):find("+0.0%", 1, true))
    n2.hist = nil; U:Refresh()
    ok("missing history says so", U.status:GetText():find("Price history is missing", 1, true) and #U.entries == 0)

    -- ---- deals, recipes and auctions tabs
    do
        local X = n2.extra
        ok("extras loaded with their three tabs", X ~= nil and U.tabs.deals ~= nil and U.tabs.rec ~= nil and U.tabs.auc ~= nil)
        U.tabs.rec.scripts.OnClick[1]()
        ok("recipes tab before the profession window was opened says so", #U.entries == 0 and U:EmptyText():find("Open your profession window", 1, true), U:EmptyText())
        U.tabs.auc.scripts.OnClick[1]()
        ok("auctions tab before the auction house was opened says so", #U.entries == 0 and U:EmptyText():find("Not read yet", 1, true), U:EmptyText())
        AHProfitDB.vend = AHProfitDB.vend or {}
        AHProfitDB.vend[900002] = 500
        local was = Lv.p[900002]
        price(900002, 440, 9)
        U.tabs.deals.scripts.OnClick[1]()
        local hit
        for _, e in ipairs(U.entries) do if e.left == "Thin Margin" then hit = e end end
        ok("deals tab lists an auction below vendor price", hit ~= nil and plain(hit.right) == "+60c each" and hit.sub:find("below vendor price, 9 listed", 1, true), hit and plain(hit.right))
        local lines = hit and hit.detail() or {}
        ok("deal detail states both prices and the gain", #lines >= 4 and plain(lines[3]):find("A vendor pays 5s 0c each: +60c per unit", 1, true), lines[3] and plain(lines[3]))
        do  -- an unknown listed count (Auctionator) is left out, never "0 listed"
            local real = n2.lookup
            n2.lookup = function(id) local p, q, t, s, f = real(id); if id == 900002 and p then return p, nil, W.time, "auctionator" end return p, q, t, s, f end
            U.tabs.deals.scripts.OnClick[1]()
            local h2
            for _, x in ipairs(U.entries) do if x.left == "Thin Margin" then h2 = x end end
            local dl = h2 and table.concat(h2.detail(), " | ") or ""
            ok("deals: an unknown listed count is left out of the row and its detail", h2 and h2.sub == "below vendor price" and not plain(dl):find("listed", 1, true)
                and plain(dl):find("AH lowest (Auctionator, today): 4s 40c each", 1, true), h2 and (h2.sub .. " / " .. plain(dl)))
            n2.lookup = real
        end
        ok("deals head counts them", plain(U.head:GetText()):find("below vendor price", 1, true), U.head:GetText())
        price(900002, was, 9)
        price(900001, 600, 50)                                   -- the history test above removed its price
        -- a dip from your own daily history says where its usual price comes from
        local Hh = n2.histHouse and n2.histHouse()
        if Hh then
            local sd = n2.scanDay(W.time)
            Hh[900001] = n2.histEncode({ { sd - 4, 2000, 0, 1 }, { sd - 3, 2000, 0, 1 }, { sd - 2, 2000, 0, 1 }, { sd - 1, 2000, 0, 1 }, { sd, 2000, 0, 1 } })
            if n2.histChanged then n2.histChanged() end
            U.tabs.deals.scripts.OnClick[1]()
            local dipE
            for _, e in ipairs(U.entries) do if e.left == "Test Ore" then dipE = e end end
            local dl = dipE and dipE.detail() or {}
            local txt = plain(table.concat(dl, "\n"))
            ok("own-history dip detail names its source", txt:find("over 5 days, from your own scans", 1, true), txt)
            ok("own-history dip detail does not promise a graph of your own prices", not txt:find("shows its graph", 1, true), txt)
            Hh[900001] = nil
            if n2.histChanged then n2.histChanged() end
        else ok("own-history dip detail names its source", false, "no history") end
        AHProfitDB.auc = { own = { [X.me()] = { t = W.time, list = { { 900001, 10, 700, 0 }, { 900003, 1, 900, 1 } } } } }
        U.tabs.auc.scripts.OnClick[1]()
        ok("auctions tab lists own auctions, sold first", #U.entries == 2 and U.entries[1].left == "Half Bound Sword" and U.entries[1].sub == "sold, gold waiting" and U.entries[2].sub == "someone is cheaper", #U.entries)
        ok("auctions head totals only what is unsold, after the cut", plain(U.head:GetText()):find("1 listed, 66s 50c if all sell, 1 undercut, 1 sold", 1, true), plain(U.head:GetText()))
        AHProfitDB.rec = { [X.me()] = { [5] = { n = "Test Blade", out = 900003, lo = 1, hi = 1, mats = { 900001, 1 }, prof = "Blacksmithing" } } }
        U.tabs.rec.scripts.OnClick[1]()
        ok("recipes tab shows profit per craft", #U.entries == 1 and U.entries[1].left == "Test Blade" and plain(U.entries[1].right) == "+3s 50c", U.entries[1] and plain(U.entries[1].right))
        do  -- an unknown listed count (Auctionator) is left out of the recipe detail
            local real = n2.lookup
            n2.lookup = function(id) local p, q, t, s, f = real(id); if id == 900003 and p then return p, nil, W.time, "auctionator" end return p, q, t, s, f end
            U.tabs.rec.scripts.OnClick[1]()
            local rl = U.entries[1] and plain(table.concat(U.entries[1].detail(), " | ")) or ""
            ok("recipes: an unknown listed count is left out of the detail", rl:find("Sells for", 1, true) and rl:find("Auctionator, today", 1, true) and not rl:find("listed", 1, true), rl)
            n2.lookup = real
            U.tabs.rec.scripts.OnClick[1]()
        end
        AHProfitDB.bank = { [X.me()] = { t = W.time, items = { { 900001, 3, 0 } } } }
        U.tabs.bags.scripts.OnClick[1]()
        local nb = 0
        for _, e in ipairs(U.entries) do if e.bank then nb = nb + 1 end end
        ok("bags tab adds the bank rows, marked as bank", nb == 1 and plain(U.head:GetText()):find("Bank (", 1, true), nb)
        AHProfitDB.bank = nil
    end

    -- ---- the farm tabs still work next to the tools
    U.tabs.mine.scripts.OnClick[1]()
    ok("back to gathering", S2.tab == "mine" and #U.entries > 0 and U.boxes.lvMin:IsShown() and U.checks.mining:IsShown() and not U.graph:IsShown() and U.intro:GetText() == "")
    S2.tab = "hist"; U:Refresh(); S2.tab = "bags"; C_Container = nil; U:Refresh()
    ok("a client without the bag API gets a plain message", U.empty:GetText():find("does not report the bag contents", 1, true), U.empty:GetText())
end
print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
