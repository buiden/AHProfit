-- Waylaid Crates and Craftsman's Writs: their tooltip also shows the auction price of what they ask for.
-- A crate lists every bundle it accepts (count x item, the bundle's total at the lowest AH price) and marks the
-- cheapest one. A writ shows the item it requests and that item's AH price. The lists are in WritData.lua.
local _, ns = ...
local W = {}
ns.writs_ui = W

local GREY, WHITE, GOLD, GREEN = { .6, .6, .6 }, { 1, 1, 1 }, { 1, .82, 0 }, { .25, 1, .25 }

local function line(tt, l, r, lc, rc) tt:AddDoubleLine(l, r, lc[1], lc[2], lc[3], rc[1], rc[2], rc[3]) end
local function name(id)
    local n = C_Item and C_Item.GetItemInfo and C_Item.GetItemInfo(id)
    if type(n) == "string" and not (issecretvalue and issecretvalue(n)) then return n end
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
    return "item #" .. id                                        -- not cached yet; the next hover has the name
end
local function price(id)
    if not ns.lookup then return nil end
    local ok, p = pcall(ns.lookup, id)
    return ok and type(p) == "number" and p or nil
end

-- Adds the lines for a crate or writ; returns true when id is one of them.
function W.tipLines(tt, id)
    local money = ns.money
    local b = ns.crates and ns.crates[id]
    if b then
        local best, bestCost = nil, nil
        local costs = {}
        for i = 1, #b, 2 do
            local p = price(b[i])
            if p then
                costs[i] = p * b[i + 1]
                if not bestCost or costs[i] < bestCost then best, bestCost = i, costs[i] end
            end
        end
        line(tt, "Crate accepts one bundle (AH price)", " ", GOLD, GOLD)
        for i = 1, #b, 2 do
            local l = "  " .. b[i + 1] .. "x " .. name(b[i])
            if costs[i] then
                local c = i == best and GREEN or WHITE
                line(tt, l .. (i == best and "  |cff40ff40cheapest|r" or ""), money(costs[i]), c, c)
            else
                line(tt, l, "none listed", WHITE, GREY)
            end
        end
        return true
    end
    local want = ns.writs and ns.writs[id]
    if want then
        local p = price(want)
        line(tt, "Writ asks for: " .. name(want), p and money(p) or "none listed", GOLD, p and WHITE or GREY)
        return true
    end
    return false
end
