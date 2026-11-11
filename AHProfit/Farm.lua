-- AH Profit farm planner: the same calculations as the gold-farming page, over FarmData.lua.
-- Pure arithmetic, no game calls. S is the player's setup: lvMin, lvMax, mining, herbalism, blacksmithing, skinning,
-- mSkill, hSkill, bSkill. CUT is the share kept after the auction cut (0.95 for a 5% cut).
local _, ns = ...
local F = {}
ns.farm = F
local T, ITEMS, NODES, ZONES, ACTS, CRAFTS
-- ITEMS[i]  = { name, itemID, price, listed, vendor, inPriceList }
-- NODES[i]  = { name, prof (1 mining, 2 herbalism), skill, weight, fromForeverRecords, { item, qty, ... } }
-- ZONES[i]  = { name, lo, hi, horde, mapID, { node, count, ... }, { node, { cell, ... }, ... }, { pinName, x, y, ... } }
-- ACTS[i]   = { kind (1 mob, 2 fishing, 3 trunk), name, where, lo, hi, gear, { item, qty, ... }, skin { item, qty, ... }, { x*10, y*10, ... }, note, skinnable }
-- CRAFTS[i] = { item, makes, prof (1 smelting, 3 blacksmithing), skill, vendorCost, vendorNote, { item, qty, ... } }
local function data()
    if ITEMS then return true end
    local d = ns.farmData
    if type(d) ~= "table" or type(d[2]) ~= "table" or type(d[6]) ~= "table" then return false end
    T, ITEMS, NODES, ZONES, ACTS, CRAFTS = d[1], d[2], d[3], d[4], d[5], d[6]
    return true
end
F.ready = data
function F.time() return data() and T or nil end
function F.item(i) return ITEMS[i] end

function F.defaults(level)
    local lo, hi = 38, 48
    if type(level) == "number" and level >= 1 then lo, hi = math.max(1, level - 5), math.min(60, level + 5) end
    return { lvMin = lo, lvMax = hi, mining = true, herbalism = false, mSkill = 225, hSkill = 1, blacksmithing = true, bSkill = 200, skinning = false }
end

-- What one unit pays you: the auction price after the cut, or the vendor price when the vendor pays more.
local function best(i, CUT)
    local it = ITEMS[i]
    local a, b = it[3] * CUT, it[5]
    return a > b and a or b
end
F.best = best
local function nodeValue(d, CUT)
    local v, loot = 0, d[6]
    for k = 1, #loot, 2 do
        local it = ITEMS[loot[k]]
        if it[6] == 1 and it[3] > 0 then v = v + loot[k + 1] * it[3] * CUT end
    end
    return v
end
local function can(d, S)
    if d[2] == 1 then return (S.mining and S.mSkill >= d[3]) and true or false end
    return (S.herbalism and S.hSkill >= d[3]) and true or false
end

-- ------------------------------------------------------------------------------------------------- gathering --
local function zoneCalc(zi, S, CUT)
    local z = ZONES[zi]
    local out = { zi = zi, name = z[1], lo = z[2], hi = z[3], mapID = z[5], rows = {}, val = 0 }
    local rows, zn, P, V = out.rows, z[6], 0, 0
    for prof = 1, 2 do
        if (prof == 1 and S.mining) or (prof == 2 and S.herbalism) then
            local pool, val, first = 0, 0, #rows + 1
            for k = 1, #zn, 2 do
                local d = NODES[zn[k]]
                if d[2] == prof then
                    local w = d[4] * zn[k + 1]
                    pool = pool + w
                    local ok, v = can(d, S), nodeValue(d, CUT)
                    if ok then val = val + w * v end
                    rows[#rows + 1] = { i = #rows + 1, ni = zn[k], name = d[1], w = w, ok = ok, v = v, prof = prof, skill = d[3], estimate = d[5] ~= 1, share = 0 }
                end
            end
            if pool > 0 then
                for k = first, #rows do rows[k].share = rows[k].w / pool end
                P, V = P + pool, V + val
            end
        end
    end
    out.val = P > 0 and V / P or 0
    table.sort(rows, function(a, b)
        if a.ok ~= b.ok then return a.ok end
        local x, y = a.share * a.v, b.share * b.v
        if x ~= y then return x > y end
        return a.i < b.i
    end)
    return out
end

-- Zones for the level range, best average pickup first. Only zones with something the player can gather.
function F.zones(S, CUT)
    local list = {}
    if not data() then return list end
    for zi = 1, #ZONES do
        local z = ZONES[zi]
        if z[4] == 0 and z[2] <= S.lvMax and z[3] >= S.lvMin then
            local r = zoneCalc(zi, S, CUT)
            for k = 1, #r.rows do
                if r.rows[k].ok then list[#list + 1] = r; break end
            end
        end
    end
    table.sort(list, function(a, b) if a.val ~= b.val then return a.val > b.val end return a.zi < b.zi end)
    return list
end

-- The 12 most valuable map squares of a zone (the map is a 20 x 20 grid), ordered as a loop. Coordinates are map %.
function F.route(r)
    local z, cells, score, order = ZONES[r.zi], {}, {}, {}
    for k = 1, #z[7], 2 do cells[z[7][k]] = z[7][k + 1] end
    for _, x in ipairs(r.rows) do
        local cs = x.ok and cells[x.ni]
        if cs then
            for j = 1, #cs do
                local c = cs[j]
                if not score[c] then score[c] = 0; order[#order + 1] = c end
                score[c] = score[c] + x.share * x.v
            end
        end
    end
    table.sort(order, function(a, b) if score[a] ~= score[b] then return score[a] > score[b] end return a < b end)
    local pts, cx, cy = {}, 0, 0
    for k = 1, math.min(12, #order) do
        local c = order[k]
        local p = { i = k, x = (c % 20) * 5 + 2.5, y = math.floor(c / 20) * 5 + 2.5, v = score[c] }
        pts[k] = p; cx = cx + p.x; cy = cy + p.y
    end
    local n = #pts > 0 and #pts or 1
    cx, cy = cx / n, cy / n
    for _, p in ipairs(pts) do p.a = math.atan2(p.y - cy, p.x - cx) end
    table.sort(pts, function(a, b) if a.a ~= b.a then return a.a < b.a end return a.i < b.i end)
    return { score = score, max = order[1] and score[order[1]] or 1, pts = pts }
end
function F.pins(r)
    local out, p = {}, ZONES[r.zi][8]
    for k = 1, #p, 3 do out[#out + 1] = { name = p[k], x = p[k + 1], y = p[k + 2] } end
    return out
end

-- ------------------------------------------------------------------------------------------ mobs and fishing --
local function sum(list, CUT)
    local t = 0
    for k = 1, #list, 2 do t = t + list[k + 1] * best(list[k], CUT) end
    return t
end
function F.skinValue(a, CUT) return a[11] == 1 and sum(a[8], CUT) or 0 end
function F.actValue(a, S, CUT) return sum(a[7], CUT) + a[6] + (S.skinning and F.skinValue(a, CUT) or 0) end
local function acts(kind, S, CUT, sorted)
    local list = {}
    if not data() then return list end
    for i = 1, #ACTS do
        local a = ACTS[i]
        if a[1] == kind and (kind ~= 1 or (a[4] <= S.lvMax and a[5] >= S.lvMin)) then
            list[#list + 1] = { i = i, a = a, name = a[2], where = a[3], lo = a[4], hi = a[5], v = F.actValue(a, S, CUT) }
        end
    end
    if sorted then table.sort(list, function(x, y) if x.v ~= y.v then return x.v > y.v end return x.i < y.i end) end
    return list
end
function F.mobs(S, CUT) return acts(1, S, CUT, true) end
function F.fishing(S, CUT) return acts(2, S, CUT, true) end
function F.trunks(S, CUT) return acts(3, S, CUT, false) end

-- Each drop that pays something, most valuable first: { name, id, q, each, v, vendor (true when the vendor pays more), listed }.
function F.drops(list, CUT)
    local out = {}
    for k = 1, #list, 2 do
        local it, q, each = ITEMS[list[k]], list[k + 1], best(list[k], CUT)
        if q * each > 0 then
            out[#out + 1] = { i = #out + 1, name = it[1], id = it[2], q = q, each = each, v = q * each,
                vendor = it[5] > 0 and it[5] >= it[3] * CUT, listed = it[4], thin = it[3] > 0 and it[4] < 150 and it[3] * CUT > it[5] }
        end
    end
    table.sort(out, function(x, y) if x.v ~= y.v then return x.v > y.v end return x.i < y.i end)
    return out
end

-- Recorded spawn points of a mob (map %), and the densest map square among them.
function F.spawns(a)
    local xy, pts, cnt, keys = a[9], {}, {}, {}
    for k = 1, #xy, 2 do
        local x, y = xy[k] / 10, xy[k + 1] / 10
        pts[#pts + 1] = { x = x, y = y }
        local c = math.min(19, math.floor(y / 5)) * 20 + math.min(19, math.floor(x / 5))
        if not cnt[c] then cnt[c] = {}; keys[#keys + 1] = c end
        cnt[c][#cnt[c] + 1] = pts[#pts]
    end
    table.sort(keys, function(p, q) if #cnt[p] ~= #cnt[q] then return #cnt[p] > #cnt[q] end return p < q end)
    local hot, h = nil, keys[1] and cnt[keys[1]]
    if h then
        local sx, sy = 0, 0
        for _, p in ipairs(h) do sx = sx + p.x; sy = sy + p.y end
        hot = { x = sx / #h, y = sy / #h, n = #h }
    end
    return pts, hot
end

-- ---------------------------------------------------------------------------------------------------- crafting --
-- own = gain from crafting your own materials instead of selling them raw; profit = gain when you buy the materials.
function F.crafts(S, CUT)
    local rows = {}
    if not data() then return rows end
    for ci = 1, #CRAFTS do
        local c = CRAFTS[ci]
        local o = ITEMS[c[1]]
        local on = (c[3] == 1 and S.mining) or (c[3] == 3 and S.blacksmithing)
        if on and o[6] == 1 and o[3] > 0 then
            local buy, raw, miss, mats = 0, 0, false, c[7]
            for k = 1, #mats, 2 do
                local m = ITEMS[mats[k]]
                if m[6] ~= 1 or m[3] <= 0 then miss = true; break end
                buy = buy + mats[k + 1] * m[3]
                raw = raw + mats[k + 1] * m[3] * CUT
            end
            if not miss then
                local vc, net = c[5], o[3] * c[2] * CUT
                local sk = c[3] == 1 and S.mSkill or S.bSkill
                local row = { i = ci, c = c, name = o[1], id = o[2], makes = c[2], listed = o[4], skill = c[4], smelting = c[3] == 1,
                    net = net, buy = buy + vc, profit = net - buy - vc, own = net - raw - vc, ok = sk >= c[4] }
                if row.own > 0 or row.profit > 0 then rows[#rows + 1] = row end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.ok ~= b.ok then return a.ok end
        if a.own ~= b.own then return a.own > b.own end
        return a.i < b.i
    end)
    return rows
end
function F.mats(c)
    local out = {}
    for k = 1, #c[7], 2 do out[#out + 1] = c[7][k + 1] .. " " .. ITEMS[c[7][k]][1] end
    if c[6] ~= "" then out[#out + 1] = c[6] end
    return table.concat(out, " + ")
end

-- Map id for a zone name, or for an activity ("Fishing in Tanaris", or a mob whose place is a zone name).
function F.mapFor(name)
    if not data() or type(name) ~= "string" then return nil end
    name = name:gsub("^Fishing in ", "")
    for i = 1, #ZONES do
        if ZONES[i][1] == name and ZONES[i][5] > 0 then return ZONES[i][5] end
    end
end
