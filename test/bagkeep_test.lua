-- Bags-full advisor: reusable Use items. Run: lua test/bagkeep_test.lua
local pass, fail = 0, 0
local function ok(name, cond, extra)
    if cond then pass = pass + 1 else fail = fail + 1; print("FAIL " .. name .. " " .. tostring(extra or "")) end
end
-- id -> name, quality, max stack, vendor, classID
local IT = {
    [211527] = { "Cozy Sleeping Bag", 1, 1, 1, 15 },
    [900001] = { "Reusable Use Item", 1, 1, 1, 15 }, -- synthetic, deliberately not a tool
    [900002] = { "Grey Use Item", 0, 1, 1, 15 },
    [9999] = { "Gem of Value", 3, 1, 5000, 15 },
    [900003] = { "Cheap Recipe", 1, 1, 25, 9 },
}
local slots, saved = {}, {}
function UnitClass() return "Warrior", "WARRIOR" end
C_Item = { GetItemInfo = function(id)
    local i = IT[id]; if not i then return nil end
    return i[1], "item:" .. id, i[2], 1, 1, "t", "st", i[3], "", 77, i[4], i[5], 0, 0
end }
C_Container = {
    GetContainerNumSlots = function(bag) return bag == 0 and #slots or 0 end,
    GetContainerNumFreeSlots = function() return 0, 0 end,
    GetContainerItemInfo = function(bag, slot)
        local s = bag == 0 and slots[slot]
        if s then return { itemID = s.id, stackCount = s.n, isBound = s.bound } end
    end,
}
function CreateFrame() return { Hide = function() end, RegisterEvent = function() end, SetScript = function() end } end
local ns = { db = function() return saved end }
assert(loadfile("AHProfit/Bags.lua"))("AHProfit", ns)
local B = ns.bags
local function setup(id)
    saved = {}
    slots = { { bag = 0, slot = 1, id = id, n = 1, bound = false }, { bag = 0, slot = 2, id = 9999, n = 1, bound = false } }
    C_Item.GetItemSpell, GetItemSpell = nil, nil
end
local function suggestion(a) return a and (a.kind .. ":" .. tostring(a.slot and a.slot.id)) or "nil" end

-- The one-copper, unbound, class-15 sleeping bag used to win over the valuable item.
for _, api in ipairs({ "without spell API", "with C_Item.GetItemSpell", "with GetItemSpell" }) do
    setup(211527)
    local function spell(id) if id == 211527 then return "Rested", 12345 end end
    if api == "with C_Item.GetItemSpell" then C_Item.GetItemSpell = spell
    elseif api == "with GetItemSpell" then GetItemSpell = spell end
    local a = B.advise(nil)
    ok("sleeping bag: never suggested " .. api, a and a.kind == "destroy" and a.slot.id == 9999
        and B.protected(slots[1]) == "a tool", suggestion(a))
end

-- A Use effect protects non-grey items outside the existing categories, by name or spell id.
for _, api in ipairs({ "C_Item.GetItemSpell", "GetItemSpell" }) do
    local function use(fn)
        if api == "C_Item.GetItemSpell" then C_Item.GetItemSpell = fn else GetItemSpell = fn end
    end
    for _, result in ipairs({ "name", "id", "name and id" }) do
        setup(900001)
        use(function(id)
            if id == 900001 then
                if result == "name" then return "Reusable Effect"
                elseif result == "id" then return nil, 12345
                else return "Reusable Effect", 12345 end
            end
        end)
        local a = B.advise(nil)
        ok("use: white item protected by " .. api .. " (" .. result .. ")", a and a.kind == "destroy" and a.slot.id == 9999
            and B.protected(slots[1]) == "has a use effect", suggestion(a))
    end

    setup(900001)
    use(function() return nil end)
    local a = B.advise(nil)
    ok("use: no spell from " .. api .. " leaves item eligible", a and a.kind == "destroy" and a.slot.id == 900001
        and B.protected(slots[1]) == nil, suggestion(a))

    setup(900001)
    use(function() error("spell lookup unavailable") end)
    local success, a = pcall(B.advise, nil)
    ok("use: failing " .. api .. " leaves item eligible without error", success and a and a.kind == "destroy" and a.slot.id == 900001, suggestion(success and a))

    setup(211527)
    use(function() error("spell lookup unavailable") end)
    local success, a = pcall(B.advise, nil)
    ok("sleeping bag: never suggested with failing " .. api, success and a and a.kind == "destroy" and a.slot.id == 9999, suggestion(success and a))

    setup(900002)
    use(function(id) if id == 900002 then return "Grey Effect", 12345 end end)
    local a = B.advise(nil)
    ok("use: grey item stays eligible with " .. api, a and a.kind == "destroy" and a.slot.id == 900002 and a.grey
        and B.protected(slots[1]) == nil, suggestion(a))
end

setup(900001)
local a = B.advise(nil)
ok("use: white item stays eligible without either spell API", a and a.kind == "destroy" and a.slot.id == 900001
    and B.protected(slots[1]) == nil, suggestion(a))

-- Prefer the namespaced API when present; a failed call or no spell is not a Use effect.
setup(900001)
local modern, legacy = 0, 0
C_Item.GetItemSpell = function(id) modern = modern + 1; if id == 900001 then return "Reusable Effect", 12345 end end
GetItemSpell = function() legacy = legacy + 1; error("prefer C_Item") end
local a = B.advise(nil)
ok("use: C_Item.GetItemSpell takes precedence over global API", a and a.kind == "destroy" and a.slot.id == 9999 and modern > 0 and legacy == 0, suggestion(a))
C_Item.GetItemSpell = function() return nil end
GetItemSpell = function(id) if id == 900001 then return "Reusable Effect", 12345 end end
local a = B.advise(nil)
ok("use: no spell from preferred API leaves item eligible", a and a.kind == "destroy" and a.slot.id == 900001, suggestion(a))
C_Item.GetItemSpell = function() error("spell lookup unavailable") end
local success, a = pcall(B.advise, nil)
ok("use: failed preferred API leaves item eligible without error", success and a and a.kind == "destroy" and a.slot.id == 900001, suggestion(success and a))

-- Keep earlier category reasons, even when the item also has a Use effect.
setup(900001)
GetItemSpell = function() return "Reusable Effect", 12345 end
for _, case in ipairs({ { 12, "a quest item" }, { 6, "ammunition" }, { 13, "a key" }, { 0, "food, drink or a potion" } }) do
    IT[900001][5] = case[1]
    ok("use: existing reason unchanged: " .. case[2], B.protected(slots[1]) == case[2], B.protected(slots[1]))
end
IT[900001][5] = 15
IT[900001][4], slots[1].bound = 0, true
ok("use: existing bound-item reason unchanged", B.protected(slots[1]) == "bound, no vendor price", B.protected(slots[1]))
IT[900001][4], slots[1].bound = 1, false
B.keep(900001)
ok("use: existing keep-list reason unchanged", B.protected(slots[1]) == "on your keep list", B.protected(slots[1]))

setup(900001)
slots[2].id = 211527
GetItemSpell = function(id) if id == 900001 then return "Reusable Effect", 12345 end end
local a = B.advise(nil)
ok("use: full bag of protected items has no destroy suggestion", a and a.kind == "none", suggestion(a))
local text = table.concat(B.text({ kind = "none" }), " / ")
ok("text: nothing eligible mentions non-grey Use items", text:find("non-grey Use items", 1, true), text)

-- Recipes stay eligible even though their Use teaches a spell; empty API results are not a Use effect.
do
    setup(900003)
    C_Item.GetItemSpell = function(id) if id == 900003 then return "Learning", 483 end end
    local a = B.advise(nil)
    ok("recipe: cheap recipe with a Use spell is still suggested", a and a.kind == "destroy" and a.slot.id == 900003, suggestion(a))
    for _, r in ipairs({ { "", 0 }, { "", nil }, { nil, 0 } }) do
        setup(900001)
        C_Item.GetItemSpell = function(id) if id == 900001 then return r[1], r[2] end end
        local b = B.advise(nil)
        ok("use: empty API result is not a Use effect (" .. tostring(r[1]) .. "," .. tostring(r[2]) .. ")",
            b and b.kind == "destroy" and b.slot.id == 900001, suggestion(b))
    end
end

print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
