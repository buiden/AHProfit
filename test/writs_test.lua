-- Waylaid Crate / Craftsman's Writ tooltip lines. Run: lua test/writs_test.lua (from the project directory)
local names = { [2447] = "Peacebloom", [765] = "Silverleaf", [2449] = "Earthroot", [785] = "Mageroyal", [2450] = "Briarthorn", [4393] = "Craftsman's Monocle" }
local requested = {}
C_Item = { GetItemInfo = function(id) return names[id] end, RequestLoadItemDataByID = function(id) requested[#requested + 1] = id end }
local prices = { [2447] = 50, [765] = 40, [2449] = 100, [785] = 300 }   -- Briarthorn and the monocle are not listed
local ns = { money = function(c) return c .. "c" end, lookup = function(id) return prices[id], 1, 0, "scan" end }
for _, f in ipairs({ "WritData.lua", "Writs.lua" }) do assert(loadfile("AHProfit/" .. f))("AHProfit", ns) end

local pass, fail = 0, 0
local function ok(n, c, x) if c then pass = pass + 1 else fail = fail + 1; print("FAIL " .. n .. " " .. tostring(x or "")) end end
local function tip(id)
    local out = {}
    local tt = { AddDoubleLine = function(_, l, r) out[#out + 1] = (l .. " => " .. r):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") end }
    return ns.writs_ui.tipLines(tt, id), out
end
local function has(t, s) for _, l in ipairs(t) do if l:find(s, 1, true) then return l end end end

-- data
local nc, nw = 0, 0
for k, b in pairs(ns.crates) do nc = nc + 1; ok("crate pairs " .. k, #b >= 2 and #b % 2 == 0) end
for k, v in pairs(ns.writs) do nw = nw + 1; ok("writ target " .. k, type(v) == "number" and v > 0 and v ~= k) end
ok("30 crates", nc == 30, nc); ok("150 writs", nw == 150, nw)

-- crate: every bundle with count x price, cheapest marked, unlisted shown
local is, t = tip(248682)                                       -- Waylaid Crate: Apprentice Herbs
ok("crate handled", is)
ok("crate header", has(t, "Crate accepts one bundle"))
ok("peacebloom total", has(t, "20x Peacebloom") and has(t, "20x Peacebloom"):find("1000c", 1, true), has(t, "20x Peacebloom"))
ok("silverleaf cheapest", has(t, "20x Silverleaf  cheapest => 800c"), table.concat(t, " | "))
ok("only one cheapest", select(2, table.concat(t, "\n"):gsub("cheapest", "")) == 1)
ok("mageroyal total", has(t, "10x Mageroyal => 3000c"))
ok("briarthorn unlisted", has(t, "10x Briarthorn => none listed"))
ok("6 lines", #t == 6, #t)

-- writ: requested item and its price, or none listed; uncached name asks the client
is, t = tip(264082)                                             -- Craftsman's Writ: Craftsman's Monocle
ok("writ handled", is)
ok("writ line", has(t, "Writ asks for: Craftsman's Monocle => none listed"), table.concat(t, " | "))
prices[4393] = 12345
is, t = tip(264082)
ok("writ price", has(t, "Writ asks for: Craftsman's Monocle => 12345c"), table.concat(t, " | "))
names[4393] = nil
is, t = tip(264082)
ok("uncached name", has(t, "item #4393") and requested[#requested] == 4393)

-- other items untouched; a lookup error never breaks the tooltip
is, t = tip(2447)
ok("plain item ignored", is == false and #t == 0)
ns.lookup = function() error("boom") end
is, t = tip(248682)
ok("lookup error safe", is and has(t, "none listed"))

print(pass .. " passed, " .. fail .. " failed")
if fail > 0 then os.exit(1) end
