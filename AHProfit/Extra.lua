-- AH Profit extras: bank contents, deals, profit of the recipes you know, gathering nodes seen by you and your guild,
-- and what became of your own auctions. Everything is read from the game. Nothing is bought, sold, listed or moved.
local _, ns = ...
local X = {}
ns.extra = X
local Tl = ns.tools

local function secret(v) return issecretvalue ~= nil and issecretvalue(v) end
local function num(v) return type(v) == "number" and not secret(v) end
local function str(v) return type(v) == "string" and not secret(v) end
local function db() return ns.db() end
local function after(d, fn) if C_Timer and C_Timer.After then C_Timer.After(d, fn) end end
local function notify(kind) if ns.ui and ns.ui.OnExtra then ns.ui:OnExtra(kind) end end
local function me()
    local n, r = UnitName and UnitName("player"), GetRealmName and GetRealmName()
    return (str(n) and n or "?") .. "-" .. (str(r) and r or "?")
end
X.me = me
local function itemName(id)
    local n = C_Item.GetItemInfo(id)
    return str(n) and n or ("item " .. id)
end
local function afterCut(p, C) return math.floor(p * (100 - C) / 100) end

-- ------------------------------------------------------------------------------------------------------- bank --
-- The bank can only be read while it is open. What was in it is saved per character with the time it was seen.
local bankOpen = false
local function bankBagIds()
    local ids = {}
    if C_Bank and C_Bank.FetchPurchasedBankTabIDs and Enum and Enum.BankType then
        local ok, t = pcall(C_Bank.FetchPurchasedBankTabIDs, Enum.BankType.Character)
        if ok and type(t) == "table" then
            for _, b in ipairs(t) do if num(b) then ids[#ids + 1] = b end end
        end
    end
    if #ids == 0 and num(BANK_CONTAINER) and num(NUM_BAG_SLOTS) and num(NUM_BANKBAGSLOTS) then
        ids[1] = BANK_CONTAINER
        for b = NUM_BAG_SLOTS + 1, NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do ids[#ids + 1] = b end
    end
    return ids
end
function X.scanBank()
    local D = db()
    if not (D and bankOpen and Tl) then return false end
    local ids = bankBagIds()
    if #ids == 0 then return false end
    local list = Tl.bags(ids)
    if not list then return false end
    local items = {}
    for _, it in ipairs(list) do items[#items + 1] = { it.id, it.n, it.bound } end
    D.bank = D.bank or {}
    D.bank[me()] = { t = ns.now(), items = items }
    if ns.tools and ns.tools.noteItems then local ids = {}; for i, it in ipairs(items) do ids[i] = it[1] end; ns.tools.noteItems(ids) end
    return true
end
-- Returns the saved bank of this character as a list for the bag advisor, and when it was seen. nil: never seen.
function X.bank()
    local D = db()
    local b = D and D.bank and D.bank[me()]
    if type(b) ~= "table" or type(b.items) ~= "table" or type(b.t) ~= "number" then return nil end
    local list = {}
    for _, x in ipairs(b.items) do
        if type(x) == "table" and type(x[1]) == "number" and type(x[2]) == "number" and x[2] > 0 then
            list[#list + 1] = { id = x[1], n = x[2], bound = type(x[3]) == "number" and x[3] or 0 }
        end
    end
    return list, b.t
end

-- ------------------------------------------------------------------------------------------------------ deals --
-- Vendor prices are asked from the game, a few at a time, and remembered (they never change). No price list of our own.
local function pricedIds()
    local ids, seen = {}, {}
    for id in pairs(ns.live().p) do
        if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
    end
    for id in pairs(ns.shared().p) do
        if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
    end
    local S = ns.seed
    if S and S.flat and not (S.faction and UnitFactionGroup and UnitFactionGroup("player") ~= S.faction) then
        for i = 1, #S.flat, 3 do
            local id = S.flat[i]
            if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
        end
    end
    table.sort(ids)
    return ids
end
local scan
local function step()
    local s, D = scan, db()
    if not s or not D then scan = nil; return end
    local stop = math.min(#s.ids, s.i + 49)
    for k = s.i, stop do
        local id = s.ids[k]
        local name, vendor = Tl.info(id)
        if type(name) == "string" and type(vendor) == "number" then D.vend[id] = vendor
        else
            s.miss[#s.miss + 1] = id
            if C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
        end
    end
    s.i = stop + 1
    if s.i <= #s.ids then return after(0.1, step) end
    if #s.miss > 0 and s.pass < 4 then
        s.ids, s.miss, s.i, s.pass = s.miss, {}, 1, s.pass + 1
        return after(2, step)
    end
    scan = nil
    notify("deals")
end
-- Starts asking the game for the vendor price of every priced item it has not told us yet. false: nothing to ask.
function X.vendorScan()
    local D = db()
    if not D or not Tl then return false end
    if scan then return true end
    D.vend = D.vend or {}
    local todo = {}
    for _, id in ipairs(pricedIds()) do if D.vend[id] == nil then todo[#todo + 1] = id end end
    if #todo == 0 then return false end
    scan = { ids = todo, i = 1, pass = 1, miss = {}, total = #todo }
    step()
    return true
end
-- known = items whose vendor price the game has told us, unknown = priced items it has not, busy = still asking.
function X.vendorState()
    local D = db()
    local V = D and D.vend or {}
    local known, unknown = 0, 0
    for _, id in ipairs(pricedIds()) do if V[id] ~= nil then known = known + 1 else unknown = unknown + 1 end end
    return known, unknown, scan ~= nil
end
local function median(ps)
    table.sort(ps)
    local n = #ps
    return n % 2 == 1 and ps[(n + 1) / 2] or (ps[n / 2] + ps[n / 2 + 1]) / 2
end
X.DIP = 0.75
-- kind "vendor": the lowest auction is below what a vendor pays, so buying it and vendoring it gains `gain` each.
-- kind "dip": an item is at or below 75% of its own usual price (the middle of its daily prices, 5 days or more).
-- Daily prices come from your own scans (ns.histOwn, the day's highest low) when they cover 5 days or more, else
-- from the bundled History.lua; own = true says which.
-- The usual price (median of 5 or more daily prices) of every item that has one. Decoding every history string is
-- the slow part, so the result is kept until the next history write, a house change, a new day or another bundled
-- history table.
local usual = {}
local function usualKey()
    local H = ns.histHouse and ns.histHouse()
    return tostring(H) .. "|" .. (ns.histVersion and ns.histVersion() or 0) .. "|" .. (ns.scanDay and ns.scanDay(ns.now()) or 0) .. "|" .. tostring(ns.hist)
end
-- Per item, the decoded own prices are also kept with the string they came from (strings are interned, so the
-- comparison is cheap): after a write only the items whose string changed are decoded again.
local ownMemo = setmetatable({}, { __mode = "k" })               -- house table -> { [id] = { s, day, n, med } }
local bundledMemo = {}                                           -- { hist = table, [idx] = { n, med } }
local function usualOf(ps) return { n = #ps, med = #ps >= 5 and median(ps) or nil } end
local function ownUsual(H, id, today)
    local m = ownMemo[H]
    if not m then m = {}; ownMemo[H] = m end
    local e, s = m[id], H[id]
    if e and e.s == s and e.day == today then return e end
    local ps = {}
    for i, p in ipairs(ns.histOwn and ns.histOwn(id) or {}) do ps[i] = p.p end
    e = usualOf(ps)
    e.s, e.day = H[id], today
    m[id] = H[id] and e or nil                                   -- (an expired item may have just been dropped)
    return e
end
local function bundledUsual(idx)
    if bundledMemo.hist ~= ns.hist then bundledMemo = { hist = ns.hist } end
    local e = bundledMemo[idx]
    if not e then
        local ps, s = {}, Tl.histSeries(idx)
        if s then for i, p in ipairs(s.pts) do ps[i] = p.p end end
        e = usualOf(ps)
        bundledMemo[idx] = e
    end
    return e
end
-- A copy is handed out, so a caller changing it cannot change the next answer.
local function copyList(list)
    local out = {}
    for i, u in ipairs(list) do out[i] = { id = u.id, name = u.name, med = u.med, days = u.days, own = u.own } end
    return out
end
function X.usualPrices()
    if usual.key == usualKey() then return copyList(usual.list) end
    local list, cands, done = {}, {}, {}
    local H = ns.histHouse and ns.histHouse()
    local today = ns.scanDay and ns.scanDay(ns.now()) or 0
    if H then for id in pairs(H) do cands[#cands + 1] = { id = id } end end
    for _, m in ipairs(Tl.histList()) do cands[#cands + 1] = { id = m.id, name = m.name, idx = m.idx } end
    for _, c in ipairs(cands) do
        if not done[c.id] then
            local u, own = nil, false
            local mine = (H and H[c.id]) and ownUsual(H, c.id, today)
            if mine and mine.med then
                u, own = mine, true
            elseif c.idx then
                u = bundledUsual(c.idx)
            end
            if u and u.med then
                done[c.id] = true
                list[#list + 1] = { id = c.id, name = c.name, med = u.med, days = u.n, own = own }
            end
        end
    end
    usual.key, usual.list = usualKey(), list                     -- after the reads above (they may drop expired items)
    return copyList(list)
end
function X.deals()
    local D, out = db(), {}
    if not D or not Tl then return out end
    local V = D.vend or {}
    for _, id in ipairs(pricedIds()) do
        local v = V[id]
        if v and v > 0 then
            local p, q, t, src, from = ns.lookup(id)
            if p and p < v then out[#out + 1] = { kind = "vendor", id = id, name = itemName(id), price = p, vendor = v, gain = v - p, qty = q or 0, t = t, src = src, from = from } end
        end
    end
    for _, u in ipairs(X.usualPrices()) do
        local now, q, t, src, from = ns.lookup(u.id)
        if now and now <= u.med * X.DIP then
            out[#out + 1] = { kind = "dip", id = u.id, name = u.name or itemName(u.id), price = now, usual = u.med, days = u.days, own = u.own,
                below = 1 - now / u.med, qty = q or 0, t = t, src = src, from = from }
        end
    end
    table.sort(out, function(a, b)
        if a.kind ~= b.kind then return a.kind == "vendor" end
        if a.kind == "vendor" then if a.gain ~= b.gain then return a.gain > b.gain end
        elseif a.below ~= b.below then return a.below > b.below end
        return a.id < b.id
    end)
    return out
end

-- ---------------------------------------------------------------------------------------------------- recipes --
-- What a vendor charged this character for one unit, recorded whenever a vendor window is open.
local function readMerchant()
    local D = db()
    local n = GetMerchantNumItems and GetMerchantNumItems()
    if not D or not num(n) or not GetMerchantItemID then return end
    D.buy = D.buy or {}
    for i = 1, n do
        local id = GetMerchantItemID(i)
        local price, stack, ext
        if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
            local ok, info = pcall(C_MerchantFrame.GetItemInfo, i)
            if ok and type(info) == "table" then price, stack, ext = info.price, info.stackCount, info.hasExtendedCost end
        elseif GetMerchantItemInfo then
            local _, _, p, s, _, _, _, e = GetMerchantItemInfo(i)
            price, stack, ext = p, s, e
        end
        if num(id) and num(price) and price > 0 and num(stack) and stack >= 1 and not secret(ext) and ext ~= true then
            D.buy[id] = { price / stack, ns.now() }
        end
    end
end
X.readMerchant = readMerchant
-- Cheapest known way to get one unit: the lowest auction, or a vendor that showed it to this character.
local function unitCost(id)
    local D = db()
    local p = ns.lookup(id)
    local b = D and D.buy and D.buy[id]
    local bp = type(b) == "table" and type(b[1]) == "number" and b[1] or nil
    if bp and (not p or bp <= p) then return bp, "vendor" end
    if p then return p, "ah" end
end
X.unitCost = unitCost
local function field(t, k) local v = t[k]; if secret(v) then return nil end return v end
-- Reads the open profession window into the saved recipe list of this character. Returns how many it read.
function X.readRecipes()
    local TS, D = C_TradeSkillUI, db()
    if not (TS and D and TS.GetAllRecipeIDs and TS.GetRecipeInfo and TS.GetRecipeSchematic) then return 0 end
    local ok, ids = pcall(TS.GetAllRecipeIDs)
    if not ok or type(ids) ~= "table" then return 0 end
    local prof = ""
    if TS.GetBaseProfessionInfo then
        local okP, pi = pcall(TS.GetBaseProfessionInfo)
        if okP and type(pi) == "table" and str(pi.professionName) then prof = pi.professionName end
    end
    local BASIC = (Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic) or 1
    D.rec = D.rec or {}
    local mine = D.rec[me()]
    if type(mine) ~= "table" then mine = {}; D.rec[me()] = mine end
    local n, seen = 0, {}
    for _, rid in ipairs(ids) do
        if num(rid) then
            local okI, info = pcall(TS.GetRecipeInfo, rid)
            local okS, sc = pcall(TS.GetRecipeSchematic, rid, false)
            if okI and okS and type(info) == "table" and type(sc) == "table" and field(info, "learned") == true
                and num(sc.outputItemID) and sc.outputItemID > 0 and type(sc.reagentSlotSchematics) == "table" then
                local mats, good = {}, true
                for _, slot in ipairs(sc.reagentSlotSchematics) do
                    if type(slot) == "table" and field(slot, "reagentType") == BASIC then
                        local r = type(slot.reagents) == "table" and slot.reagents[1]
                        if type(r) == "table" and num(r.itemID) and num(slot.quantityRequired) and slot.quantityRequired > 0 then
                            mats[#mats + 1] = r.itemID; mats[#mats + 1] = slot.quantityRequired
                        else good = false end
                    end
                end
                if good and #mats > 0 then
                    local lo = num(sc.quantityMin) and sc.quantityMin >= 1 and sc.quantityMin or 1
                    local hi = num(sc.quantityMax) and sc.quantityMax >= lo and sc.quantityMax or lo
                    mine[rid] = { n = str(info.name) and info.name or (str(sc.name) and sc.name) or ("recipe " .. rid), out = sc.outputItemID, lo = lo, hi = hi, mats = mats, prof = prof }
                    seen[rid] = true; n = n + 1
                end
            end
        end
    end
    if n > 0 and prof ~= "" then                                  -- recipes of this profession that are gone (it was dropped)
        for rid, r in pairs(mine) do if r.prof == prof and not seen[rid] then mine[rid] = nil end end
    end
    if n > 0 then notify("rec") end
    return n
end
-- One recipe in numbers. value = what the output fetches (auction after the cut, or the vendor when that pays more),
-- cost = buying every material the cheapest known way, raw = what the materials would fetch if you sold them instead.
-- profit is nil while any material has no known price; own is nil while the output has no price.
local function calc(rid, r, C)
    local makes = (r.lo + r.hi) / 2
    local price, qty, t, src, from = ns.lookup(r.out)
    local _, vendor = Tl.info(r.out)
    local net = price and afterCut(price, C) or 0
    local each, how = 0, nil
    if net > 0 and net >= (type(vendor) == "number" and vendor or 0) then each, how = net, "ah"
    elseif type(vendor) == "number" and vendor > 0 then each, how = vendor, "vendor" end
    local row = { rid = rid, name = r.n, prof = r.prof, out = r.out, makes = makes, lo = r.lo, hi = r.hi, each = each, how = how, value = each * makes,
        price = price, listed = qty or 0, qtyKnown = qty ~= nil, t = t, src = src, from = from, mats = {}, cost = 0, raw = 0, known = true }
    for k = 1, #r.mats, 2 do
        local id, q = r.mats[k], r.mats[k + 1]
        local c, from = unitCost(id)
        local mp = ns.lookup(id)
        local _, mv = Tl.info(id)
        local rawEach = math.max(mp and afterCut(mp, C) or 0, type(mv) == "number" and mv or 0)
        row.mats[#row.mats + 1] = { id = id, q = q, name = itemName(id), each = c, from = from }
        if c then row.cost = row.cost + c * q else row.known = false end
        row.raw = row.raw + rawEach * q
    end
    if how and row.known then row.profit = row.value - row.cost end
    if how then row.own = row.value - row.raw end
    return row
end
function X.recipe(rid, C)
    local D = db()
    local r = D and D.rec and D.rec[me()] and D.rec[me()][rid]
    if type(r) ~= "table" or type(r.mats) ~= "table" then return nil end
    return calc(rid, r, C)
end
-- Every saved recipe of this character, best profit first; recipes without a full price come last.
function X.recipes(C)
    local D, rows = db(), {}
    local mine = D and D.rec and D.rec[me()]
    if type(mine) ~= "table" or not Tl then return rows end
    for rid, r in pairs(mine) do
        if type(r) == "table" and type(r.mats) == "table" then rows[#rows + 1] = calc(rid, r, C) end
    end
    table.sort(rows, function(a, b)
        if (a.profit ~= nil) ~= (b.profit ~= nil) then return a.profit ~= nil end
        if a.profit and a.profit ~= b.profit then return a.profit > b.profit end
        if a.name ~= b.name then return a.name < b.name end
        return a.rid < b.rid
    end)
    return rows
end
local function signed(v) return (v >= 0 and "+" or "-") .. ns.money(math.floor(math.abs(v) + 0.5)) end
-- Two lines for the profession window.
function X.profText(rid, C)
    local r = X.recipe(rid, C)
    if not r then return "|cffffd100AH Profit|r  This recipe is not read yet." end
    local makes = r.lo == r.hi and ("x" .. r.lo) or ("x" .. r.lo .. "-" .. r.hi)
    local a = "|cffffd100AH Profit|r  " .. r.name .. " " .. makes .. ": "
    if not r.how then return a .. "no auction listing and no vendor value for what it makes." end
    a = a .. "sells for " .. ns.money(math.floor(r.value + 0.5)) .. (r.how == "ah" and (" on the AH after the " .. C .. "% cut (" .. (r.qtyKnown and (r.listed .. " listed, ") or "") .. ns.srcLabel(r.src, r.t, r.from) .. ")") or " at a vendor")
    local b
    if r.profit then
        b = "Materials " .. ns.money(math.floor(r.cost + 0.5)) .. ".  Profit " .. (r.profit >= 0 and "|cff40ff40" or "|cffff5050") .. signed(r.profit) .. "|r"
    else
        local miss = {}
        for _, m in ipairs(r.mats) do if not m.each then miss[#miss + 1] = m.name end end
        b = "No price known for " .. table.concat(miss, ", ") .. ". Open a vendor that sells it once."
    end
    b = b .. "   With your own materials, against selling them: " .. signed(r.own)
    return a .. "\n" .. b
end
local profLine
local function showProf(rid)
    local fr = ProfessionsFrame
    if not (fr and CreateFrame and num(rid)) then return end
    if not profLine then
        local h = CreateFrame("Frame", nil, fr, BackdropTemplateMixin and "BackdropTemplate" or nil)
        h:SetPoint("TOPLEFT", fr, "BOTTOMLEFT", 0, -2); h:SetPoint("TOPRIGHT", fr, "BOTTOMRIGHT", 0, -2); h:SetHeight(40)
        if h.SetBackdrop then
            h:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
            h:SetBackdropColor(0.06, 0.05, 0.04, 0.94); h:SetBackdropBorderColor(0.78, 0.59, 0.18, 1)
        end
        profLine = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        profLine:SetPoint("TOPLEFT", 10, -7); profLine:SetPoint("TOPRIGHT", -10, -7); profLine:SetJustifyH("LEFT")
        X.profLine = profLine
    end
    X.profRecipe = rid
    profLine:SetText(X.profText(rid, (db() and db().cut) or 5))
end
X.showProf = showProf

-- -------------------------------------------------------------------------------------------- gathering nodes --
-- A node is recorded when your own gathering cast on it succeeds: which node, which map, where you stood, when.
-- Guild members running the addon receive it at once. Saved as { name hash, x, y, time, who }, x and y in 1/1000 of the map.
local byName, byHash
local NEAR = 12
function X.hash(s)
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 1000003 end
    return h
end
local function index()
    if byName then return true end
    local d = ns.farmData
    if type(d) ~= "table" or type(d[3]) ~= "table" then return false end
    byName, byHash = {}, {}
    for _, n in ipairs(d[3]) do
        local h = X.hash(n[1])
        byName[n[1]] = h
        if byHash[h] == nil then byHash[h] = n[1] else byHash[h] = false end
    end
    return true
end
function X.nodeHash(name) return index() and byName[name] or nil end
function X.nodeName(h) return index() and byHash[h] or nil end
-- Returns "new" or "again" (a node of that kind is already known within a few yards) and the time it was last seen.
function X.addNode(map, h, x, y, t, who)
    local D = db()
    if not D then return nil end
    D.nodes = D.nodes or {}
    local list = D.nodes[map]
    if not list then list = {}; D.nodes[map] = list end
    for _, n in ipairs(list) do
        if n[1] == h and math.abs(n[2] - x) <= NEAR and math.abs(n[3] - y) <= NEAR then
            local was = n[4]
            if t > was then n[4], n[5] = t, who end
            return "again", was
        end
    end
    if #list >= 800 then
        local old = 1
        for i = 2, #list do if list[i][4] < list[old][4] then old = i end end
        table.remove(list, old)
    end
    list[#list + 1] = { h, x, y, t, who }
    return "new"
end
function X.nodeCount()
    local D, n = db(), 0
    for _, list in pairs(D and D.nodes or {}) do n = n + #list end
    return n
end
-- Nodes seen on one map, newest first: { name, x, y (map %), t, who }.
function X.nodesOn(map)
    local D, out = db(), {}
    for _, n in ipairs(D and D.nodes and D.nodes[map] or {}) do
        out[#out + 1] = { name = X.nodeName(n[1]) or "node", x = n[2] / 10, y = n[3] / 10, t = n[4], who = n[5] }
    end
    table.sort(out, function(a, b) if a.t ~= b.t then return a.t > b.t end if a.x ~= b.x then return a.x < b.x end return a.y < b.y end)
    return out
end
-- Every node as { map, hash, x, y, t }, newest first, for sending to a guild member who has fewer.
function X.nodeList()
    local D, out = db(), {}
    for map, list in pairs(D and D.nodes or {}) do
        for _, n in ipairs(list) do out[#out + 1] = { map, n[1], n[2], n[3], n[4] } end
    end
    table.sort(out, function(a, b)
        for _, k in ipairs({ 5, 1, 2, 3, 4 }) do if a[k] ~= b[k] then if k == 5 then return a[k] > b[k] end return a[k] < b[k] end end
        return false
    end)
    return out
end
local function position()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return end
    local ok, map = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not num(map) then return end
    local ok2, pos = pcall(C_Map.GetPlayerMapPosition, map, "player")
    if not ok2 or type(pos) ~= "table" then return end
    local x, y = pos.x, pos.y
    if pos.GetXY then x, y = pos:GetXY() end
    if not (num(x) and num(y)) or x <= 0 or y <= 0 or x > 1 or y > 1 then return end
    return map, math.floor(x * 1000 + 0.5), math.floor(y * 1000 + 0.5)
end
local cast
local function gathered(h)
    local D = db()
    local map, x, y = position()
    if not D or not map then return end
    local t = ns.now()
    local who = UnitName and UnitName("player")
    local res, was = X.addNode(map, h, x, y, t, str(who) and who or "you")
    if res == "again" and t - was < 120 then return end          -- the second cast on the same vein, not another node
    local S = D.session
    if S and S.on then S.nodes = (S.nodes or 0) + 1 end
    if ns.sync and ns.sync.node then ns.sync.node(map, h, x, y, t) end
    notify("nodes")
end
-- Called by the guild sync for nodes another member gathered.
function X.shared(n) if n > 0 then notify("nodes") end end

-- ------------------------------------------------------------------------------------------------ own auctions --
-- Your auctions as the game lists them (open the Auctions tab of the auction house), and a count per item of how
-- often the game told you one sold or expired. A posted auction is never counted as income.
local soldPat, expPat
local function pattern(g)
    if not str(g) or not g:find("%s", 1, true) then return nil end
    local p = g:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
    p = p:gsub("%%%%s", "(.+)")
    return "^" .. p .. "$"
end
local function stat(name)
    local D = db()
    D.auc = D.auc or {}
    D.auc.stat = D.auc.stat or {}
    local s = D.auc.stat[name]
    if not s then s = { 0, 0 }; D.auc.stat[name] = s end
    return s
end
local function system(text)
    if not str(text) or not db() then return end
    if soldPat == nil then soldPat = pattern(ERR_AUCTION_SOLD_S) or false end
    if expPat == nil then expPat = pattern(ERR_AUCTION_EXPIRED_S) or false end
    local n = soldPat and text:match(soldPat)
    if n then local s = stat(n); s[1] = s[1] + 1; return notify("auc") end
    n = expPat and text:match(expPat)
    if n then local s = stat(n); s[2] = s[2] + 1; return notify("auc") end
end
X.system = system
-- sold, expired for an item name; nil when the game never reported either.
function X.sellThrough(name)
    local D = db()
    local s = D and D.auc and D.auc.stat and D.auc.stat[name]
    if type(s) == "table" and type(s[1]) == "number" and type(s[2]) == "number" then return s[1], s[2] end
end
local function readOwned()
    local A, D = C_AuctionHouse, db()
    if not (A and D and A.GetOwnedAuctions) then return end
    local ok, list = pcall(A.GetOwnedAuctions)
    if not ok or type(list) ~= "table" then return end
    local SOLD = (Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold) or 1
    local own = {}
    for _, a in ipairs(list) do
        local id = type(a) == "table" and type(a.itemKey) == "table" and a.itemKey.itemID
        if num(id) and num(a.quantity) and a.quantity >= 1 then
            own[#own + 1] = { id, a.quantity, num(a.buyoutAmount) and a.buyoutAmount or 0, (not secret(a.status) and a.status == SOLD) and 1 or 0 }
        end
    end
    D.auc = D.auc or {}
    D.auc.own = D.auc.own or {}
    D.auc.own[me()] = { t = ns.now(), list = own }
    if ns.tools and ns.tools.noteItems then local ids = {}; for i, it in ipairs(own) do ids[i] = it[1] end; ns.tools.noteItems(ids) end
    notify("auc")
end
X.readOwned = readOwned
-- Rows: { id, name, q, each (your buyout per unit), net (all of it after the cut), sold, low (lowest listing now),
-- under (someone is cheaper), sold/expired history }. Totals: n, asking (after cut, unsold only), soldN, t. nil: never read.
function X.auctions(C)
    local D = db()
    local o = D and D.auc and D.auc.own and D.auc.own[me()]
    if type(o) ~= "table" or type(o.list) ~= "table" then return nil end
    local rows, tot = {}, { n = 0, asking = 0, soldN = 0, under = 0, t = o.t }
    for _, a in ipairs(o.list) do
        if type(a) == "table" and type(a[1]) == "number" and type(a[2]) == "number" and type(a[3]) == "number" then
            local name = itemName(a[1])
            local low, _, lt, src, from = ns.lookup(a[1])
            local r = { id = a[1], name = name, q = a[2], each = a[3], net = afterCut(a[3], C) * a[2], sold = a[4] == 1, low = low, lowT = lt, src = src, from = from }
            r.under = (not r.sold) and low ~= nil and a[3] > 0 and low < a[3]
            r.soldN, r.expiredN = X.sellThrough(name)
            if r.sold then tot.soldN = tot.soldN + 1
            else
                tot.n, tot.asking = tot.n + 1, tot.asking + r.net
                if r.under then tot.under = tot.under + 1 end
            end
            rows[#rows + 1] = r
        end
    end
    table.sort(rows, function(a, b)
        if a.sold ~= b.sold then return a.sold end
        if a.net ~= b.net then return a.net > b.net end
        return a.id < b.id
    end)
    return rows, tot
end

-- Tooltip lines under the profit lines.
function X.tipLine(tt, id, price)
    local name, vendor = Tl.info(id)
    if price and type(vendor) == "number" and vendor > price then
        tt:AddDoubleLine("Below vendor price: buy it, vendor it", "+" .. ns.money(vendor - price), .25, 1, .25, .25, 1, .25)
    end
    if type(name) == "string" then
        local s, e = X.sellThrough(name)
        if s then tt:AddDoubleLine("Your auctions of this", s .. " sold, " .. e .. " expired", .6, .6, .6, .6, .6, .6) end
    end
end

-- ------------------------------------------------------------------------------------------------------ events --
local lastRead = 0
function X.event(ev, a1, a2, a3)
    if not db() then return end
    if ev == "BANKFRAME_OPENED" then bankOpen = true; after(0.5, function() if X.scanBank() then notify("bags") end end)
    elseif ev == "BANKFRAME_CLOSED" then bankOpen = false
    elseif ev == "BAG_UPDATE_DELAYED" or ev == "PLAYERBANKSLOTS_CHANGED" then
        if bankOpen and X.scanBank() then notify("bags") end
    elseif ev == "MERCHANT_SHOW" or ev == "MERCHANT_UPDATE" then readMerchant()
    elseif ev == "TRADE_SKILL_SHOW" or ev == "TRADE_SKILL_LIST_UPDATE" then
        if ns.now() ~= lastRead then
            lastRead = ns.now()
            after(0.3, function() X.readRecipes(); if X.profRecipe then showProf(X.profRecipe) end end)
        end
    elseif ev == "OWNED_AUCTIONS_UPDATED" then readOwned()
    elseif ev == "CHAT_MSG_SYSTEM" then system(a1)
    elseif ev == "UNIT_SPELLCAST_SENT" then
        cast = nil
        if a1 == "player" and str(a2) and str(a3) then
            local h = X.nodeHash(a2)
            if h then cast = { guid = a3, h = h } end
        end
    elseif ev == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 == "player" and cast and str(a2) and a2 == cast.guid then
            local h = cast.h
            cast = nil
            gathered(h)
        end
    end
end
X.events = { "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "BAG_UPDATE_DELAYED", "PLAYERBANKSLOTS_CHANGED", "MERCHANT_SHOW", "MERCHANT_UPDATE",
    "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "OWNED_AUCTIONS_UPDATED", "CHAT_MSG_SYSTEM" }
local f = CreateFrame("Frame")
f:Hide()
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(_, ev, ...)
    if ev == "PLAYER_LOGIN" then
        for _, e in ipairs(X.events) do pcall(f.RegisterEvent, f, e) end   -- an event this client does not have is skipped
        for _, e in ipairs({ "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED" }) do
            if f.RegisterUnitEvent then pcall(f.RegisterUnitEvent, f, e, "player") else pcall(f.RegisterEvent, f, e) end
        end
        if EventRegistry and EventRegistry.RegisterCallback then
            pcall(EventRegistry.RegisterCallback, EventRegistry, "ProfessionsRecipeListMixin.Event.OnRecipeSelected", function(_, a, b)
                local info = (type(a) == "table" and a.recipeID and a) or (type(b) == "table" and b.recipeID and b)
                if info and num(info.recipeID) then
                    if not X.recipe(info.recipeID, 5) then X.readRecipes() end
                    showProf(info.recipeID)
                end
            end, X)
        end
        return
    end
    X.event(ev, ...)
end)
