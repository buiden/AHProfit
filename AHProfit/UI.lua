-- AH Profit farm window (/ahp farm): the gold-farming page inside the game. Gathering zones, mobs, fishing and
-- crafting ranked for your level and professions, with routes and recorded spawn points drawn on the world map.
local _, ns = ...
local F = ns.farm
local Tl = ns.tools
local X = Tl and ns.extra
local UI = {}
ns.ui = UI
local GOLD, GREY = { 1, 0.82, 0 }, { 0.6, 0.6, 0.6 }
local TABS = { { "mine", "Gathering", "pickup" }, { "mobs", "Mobs", "kill" }, { "fish", "Fishing", "catch" }, { "craft", "Crafting", "craft" },
    { "bags", "Bags" }, { "sess", "Session" }, { "hist", "Prices" }, { "deals", "Deals" }, { "rec", "Recipes" }, { "auc", "Auctions" } }
local EXTRA_TAB = { deals = true, rec = true, auc = true }
local FARM_TAB, ANY_TAB = { mine = true, mobs = true, fish = true, craft = true }, {}
for _, t in ipairs(TABS) do ANY_TAB[t[1]] = true end
local SKILL_IDS = { [186] = "mSkill", [182] = "hSkill", [164] = "bSkill", [393] = "skinning" }
local DB, S

local function secret(v) return issecretvalue ~= nil and issecretvalue(v) end
local function cut() return (100 - ((AHProfitDB and AHProfitDB.cut) or 5)) / 100 end
local function coin(v) return ns.money(math.floor(v + 0.5)) end
local function pct(v) return math.floor(v * 100 + 0.5) .. "%" end
local function grey(s) return "|cff999999" .. s .. "|r" end

local function backdrop(f, alpha)
    if not f.SetBackdrop and BackdropTemplateMixin then Mixin(f, BackdropTemplateMixin) end
    if f.SetBackdrop then
        f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        f:SetBackdropColor(0.06, 0.05, 0.04, alpha or 0.94)
        f:SetBackdropBorderColor(0.78, 0.59, 0.18, 1)
    end
end
local function label(parent, font, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetJustifyH("LEFT")
    if text then fs:SetText(text) end
    return fs
end

-- ------------------------------------------------------------------------------------------- the player's setup --
-- Level and profession skills read from the character. Anything the client hides or does not report keeps its value.
function UI:Detect(S0)
    local lvl = UnitLevel and UnitLevel("player")
    if type(lvl) == "number" and not secret(lvl) and lvl >= 1 then
        S0.lvMin, S0.lvMax = math.max(1, lvl - 5), math.min(60, lvl + 5)
    end
    local SI = C_SkillInfo
    if not (SI and SI.GetNumSkillLines and SI.GetSkillLineInfo) then return false end
    local ok, n = pcall(SI.GetNumSkillLines)
    if not ok or type(n) ~= "number" or secret(n) then return false end
    local found = { mSkill = false, hSkill = false, bSkill = false, skinning = false }
    for i = 1, n do
        local ok2, a = pcall(SI.GetSkillLineInfo, i)
        if ok2 and type(a) == "table" and not secret(a.skillID) and not secret(a.rank) then
            local key = SKILL_IDS[a.skillID] or (not secret(a.parentSkillLineID) and SKILL_IDS[a.parentSkillLineID])
            if key and type(a.rank) == "number" and a.rank >= 1 and a.rank > (found[key] or 0) then found[key] = a.rank end
        end
    end
    if not (found.mSkill or found.hSkill or found.bSkill or found.skinning) then return false end
    S0.mining, S0.herbalism, S0.blacksmithing, S0.skinning = found.mSkill and true, found.hSkill and true, found.bSkill and true, found.skinning and true
    if found.mSkill then S0.mSkill = found.mSkill end
    if found.hSkill then S0.hSkill = found.hSkill end
    if found.bSkill then S0.bSkill = found.bSkill end
    return true
end

local function settings()
    if S then return S end
    AHProfitDB = AHProfitDB or {}
    DB = AHProfitDB
    if type(DB.farm) ~= "table" then
        DB.farm = F.defaults()
        DB.farm.tab = "mine"
        UI:Detect(DB.farm)
    end
    S = DB.farm
    local d = F.defaults()
    for k, v in pairs(d) do if type(S[k]) ~= type(v) then S[k] = v end end
    if not ANY_TAB[S.tab] or (not Tl and not FARM_TAB[S.tab]) then S.tab = "mine" end
    return S
end

-- --------------------------------------------------------------------------------------------- building the list --
-- Each entry: { left, right, sub, detail = function() -> lines, map = function() -> { mapID, cells, pts, dots, hot } }
local function zoneEntries(CUT)
    local out = {}
    for _, r in ipairs(F.zones(S, CUT)) do
        out[#out + 1] = { left = r.name, sub = "level " .. r.lo .. "-" .. r.hi, right = coin(r.val), v = r.val,
            detail = function()
                local L = { "|cffffd100" .. r.name .. "|r  average per node you pick: " .. coin(r.val) }
                for _, x in ipairs(r.rows) do
                    local who = x.prof == 1 and "Mining " or "Herbalism "
                    if x.ok then
                        L[#L + 1] = x.name .. "  " .. grey(pct(x.share) .. " of nodes" .. (x.estimate and ", estimated count" or "")) .. "  " .. coin(x.v) .. " each"
                    else
                        L[#L + 1] = grey(x.name .. "  " .. pct(x.share) .. " of nodes, needs " .. who .. x.skill)
                    end
                end
                local rt = F.route(r)
                if #rt.pts > 0 then
                    local t = {}
                    for k, p in ipairs(rt.pts) do t[k] = k .. ") " .. p.x .. ", " .. p.y end
                    L[#L + 1] = " "
                    L[#L + 1] = "Loop through the richest map squares: " .. table.concat(t, "   ")
                end
                for _, p in ipairs(F.pins(r)) do L[#L + 1] = grey("Known spot: " .. p.name .. " at " .. p.x .. ", " .. p.y) end
                local seen = X and X.nodesOn(r.mapID) or {}
                if #seen > 0 then
                    L[#L + 1] = "|cff40ff40" .. #seen .. " nodes picked here by you and your guild|r (green dots on the map). Newest:"
                    for k = 1, math.min(5, #seen) do
                        local n = seen[k]
                        L[#L + 1] = "  " .. n.name .. " at " .. string.format("%.1f, %.1f", n.x, n.y) .. grey("  " .. tostring(n.who) .. ", " .. ns.age(n.t))
                    end
                end
                L[#L + 1] = grey("Node counts are recorded spawn points. How many are up at once is decided by the server.")
                return L
            end,
            map = function()
                local rt = F.route(r)
                return { mapID = r.mapID, name = r.name, score = rt.score, max = rt.max, pts = rt.pts, pins = F.pins(r), seen = X and X.nodesOn(r.mapID) or nil }
            end }
    end
    return out
end

local function dropLines(L, list, CUT, title)
    local d = F.drops(list, CUT)
    if #d == 0 then return end
    L[#L + 1] = title
    for _, x in ipairs(d) do
        local q = x.q >= 1 and string.format("%.2f", x.q) or pct(x.q)
        L[#L + 1] = "  " .. x.name .. "  " .. grey(q .. " per unit, " .. coin(x.each) .. (x.vendor and " at a vendor" or " on the AH after cut")
            .. (x.thin and (", only " .. x.listed .. " listed") or "")) .. "  " .. coin(x.v)
    end
end

local function actEntries(list, CUT, unit)
    local out = {}
    for _, m in ipairs(list) do
        local a = m.a
        local isMob = a[1] == 1
        out[#out + 1] = { left = m.name, sub = isMob and (m.where .. ", level " .. m.lo .. "-" .. m.hi) or "", right = coin(m.v), v = m.v,
            detail = function()
                local L = { "|cffffd100" .. m.name .. "|r  average per " .. unit .. ": " .. coin(m.v) }
                if not isMob then L[#L + 1] = grey(m.where) end
                dropLines(L, a[7], CUT, "Drops:")
                if a[6] > 0 then L[#L + 1] = "  Grey and green gear sold to a vendor  " .. coin(a[6]) end
                if a[11] == 1 then
                    local sv = F.skinValue(a, CUT)
                    dropLines(L, a[8], CUT, S.skinning and ("Skinning (included): " .. coin(sv)) or ("Skinning would add " .. coin(sv) .. " (not ticked):"))
                end
                if a[10] ~= "" then L[#L + 1] = grey(a[10]) end
                if isMob then
                    local pts, hot = F.spawns(a)
                    if hot then L[#L + 1] = #pts .. " recorded spawn points. Densest area around " .. string.format("%.1f, %.1f", hot.x, hot.y) .. " (" .. hot.n .. " points)." end
                    L[#L + 1] = grey("Spawn points are recorded locations, not live positions or timers.")
                end
                return L
            end,
            map = function()
                local id = F.mapFor(isMob and m.where or m.name)
                if not id then return nil end
                local pts, hot = F.spawns(a)
                return { mapID = id, name = isMob and m.where or m.name, dots = pts, hot = hot }
            end }
    end
    return out
end

local function craftEntries(CUT)
    local out = {}
    for _, r in ipairs(F.crafts(S, CUT)) do
        local who = r.smelting and "Mining " or "Blacksmithing "
        out[#out + 1] = { left = r.name .. (r.makes > 1 and (" x" .. r.makes) or ""), sub = r.ok and "" or ("needs " .. who .. r.skill),
            right = (r.own >= 0 and "+" or "") .. coin(r.own), v = r.own, dim = not r.ok,
            detail = function()
                return { "|cffffd100" .. r.name .. "|r  " .. grey(who .. r.skill .. ", " .. r.listed .. " listed"),
                    "Materials: " .. F.mats(r.c),
                    "Sells for (after cut): " .. coin(r.net),
                    "With your own materials, compared with selling them raw: " .. (r.own >= 0 and "+" or "") .. coin(r.own),
                    "Buying the materials on the AH (" .. coin(r.buy) .. "): " .. (r.profit >= 0 and "+" or "") .. coin(r.profit),
                    grey("Asking prices, not completed sales. Listing deposits are not included.") }
            end }
    end
    return out
end

-- ---------------------------------------------------------------------------- bags, session and price history --
local function signed(v) return (v >= 0 and "+" or "") .. coin(v) end
local function dur(s)
    local h, m = math.floor(s / 3600), math.floor(s / 60) % 60
    return h > 0 and (h .. "h " .. m .. "m") or (m .. "m")
end
local function bagRows(out, rows, C, where)
    for _, r in ipairs(rows) do
        local ah = r.verdict == "ah"
        out[#out + 1] = { left = r.name .. (r.n > 1 and (" x" .. r.n) or ""), sub = (ah and "auction house" or "vendor") .. (where or ""), bank = where ~= nil,
            right = (ah and "|cff40ff40" or "") .. coin(r.value) .. (ah and "|r" or ""), v = r.value, verdict = r.verdict,
            detail = function()
                local L = { "|cffffd100" .. r.name .. "|r  " .. (ah and ("auction " .. r.free .. (r.bound > 0 and (", vendor the " .. r.bound .. " soulbound") or "")) or ("vendor all " .. r.n)) }
                if r.price then
                    L[#L + 1] = "AH lowest (" .. (r.src == "scan" and "scan " or "feed ") .. ns.age(r.t) .. "): " .. coin(r.price) .. " each, " .. (r.qty or 0) .. " listed"
                    L[#L + 1] = "After " .. C .. "% cut: " .. coin(r.net) .. " each. A vendor pays " .. coin(r.vendor) .. " each."
                else
                    L[#L + 1] = "No auction listings seen. A vendor pays " .. coin(r.vendor) .. " each."
                end
                if ah then
                    L[#L + 1] = "Auction instead of vendor: |cff40ff40" .. signed(r.gain) .. "|r for your " .. r.free
                    if r.risk then L[#L + 1] = "Deposit for " .. Tl.durationText() .. ": " .. coin(r.risk) .. ", lost if it does not sell " .. grey("(measured " .. ns.age(r.riskAt) .. ")")
                    else L[#L + 1] = grey("Deposit not measured yet. Open the auction house with this in your bags and it is read from the game.") end
                    if r.qty and r.free > r.qty then L[#L + 1] = grey("You hold more than is listed (" .. r.free .. " against " .. r.qty .. "). Selling all of it at this price is unlikely.") end
                    if r.gear then L[#L + 1] = grey("Gear: this is the cheapest listing of any version of the item. Yours may be worth more or less.") end
                elseif r.price and r.bound < r.n then
                    L[#L + 1] = "The auction house would leave you " .. signed((r.net - r.vendor) * r.free) .. " against the vendor."
                elseif r.bound >= r.n then
                    L[#L + 1] = grey("Soulbound: it can only be vendored.")
                end
                if where then L[#L + 1] = grey("This is in your bank, as it was when you last opened it.") end
                L[#L + 1] = grey("Asking prices, not completed sales. Nothing is sold or listed for you.")
                return L
            end }
    end
end
local function bagEntries()
    local out = {}
    local list = Tl.bags()
    UI.bagTot, UI.bankTot, UI.bankAt = nil, nil, nil
    if not list then return out end
    Tl.measureAll(list)
    local C = (AHProfitDB and AHProfitDB.cut) or 5
    local rows, tot = Tl.advise(list, C)
    UI.bagTot = tot
    bagRows(out, rows, C)
    local bank, at
    if X then bank, at = X.bank() end
    if bank then
        local brows, btot = Tl.advise(bank, C)
        UI.bankTot, UI.bankAt = btot, at
        bagRows(out, brows, C, ", in your bank")
    end
    return out
end

local function sessLines()
    local R = UI.sessR
    if not R then
        return { "No session yet.", "Press Start session, then go and farm. The addon measures the coin you really pick up and the items that really",
            "land in your bags, so the gold per hour is yours and not an average from a drop table." }
    end
    local C = (AHProfitDB and AHProfitDB.cut) or 5
    local hours = R.elapsed / 3600
    local function rate(v) return R.elapsed >= 60 and ("  =  " .. signed(v / hours) .. " per hour") or "" end
    local L = { "|cffffd100Session|r  " .. (R.on and "running" or "stopped") .. ", " .. dur(R.elapsed) }
    local loot, vend = R.inc.loot or 0, R.inc.vendor or 0
    local other = (R.inc.mail or 0) + (R.inc.ah or 0) + (R.inc.trade or 0)
    L[#L + 1] = "Coin picked up (loot, quests): " .. coin(loot)
    if vend > 0 then L[#L + 1] = "Sold to vendors: " .. coin(vend) end
    if other > 0 then L[#L + 1] = "Mail, auction house and trades: " .. coin(other) end
    if R.coinOut > 0 then L[#L + 1] = "Spent (repairs, purchases, deposits, postage): -" .. coin(R.coinOut) end
    L[#L + 1] = "Coin, measured: " .. signed(R.coinIn - R.coinOut) .. rate(R.coinIn - R.coinOut)
    L[#L + 1] = "Items gained and still in your bags: " .. coin(R.gainedValue) .. grey(" at current prices, an estimate")
    if R.usedValue > 0 then L[#L + 1] = "Used up from your bags: -" .. coin(R.usedValue) end
    local all = R.coinIn - R.coinOut + R.gainedValue - R.usedValue
    L[#L + 1] = "Coin plus items: " .. signed(all) .. rate(all)
    if (R.nodes or 0) > 0 then
        L[#L + 1] = "Nodes you gathered: " .. R.nodes .. (R.elapsed >= 60 and ("  =  " .. string.format("%.0f", R.nodes / hours) .. " per hour, measured") or "")
    end
    L[#L + 1] = " "
    L[#L + 1] = grey("Coin is the real change of your money. Item values are asking prices after the " .. C .. "% cut, or the vendor price,")
    L[#L + 1] = grey("not sales. Posted auctions count as nothing until the gold arrives. Vendor income counts everything you sold,")
    L[#L + 1] = grey("also items from before the session. Time logged out is not counted.")
    if not R.bags then L[#L + 1] = grey("This client did not report the bag contents, so only coin is measured.") end
    return L
end
local function sessEntries()
    local out = {}
    local R = Tl.sessionReport((AHProfitDB and AHProfitDB.cut) or 5)
    UI.sessR = R
    if not R then return out end
    for _, x in ipairs(R.gained) do
        out[#out + 1] = { left = x.name .. " x" .. x.n, sub = x.how == "ah" and "auction price after cut" or (x.how == "vendor" and "vendor price" or "no price known"),
            right = coin(x.value), v = x.value, detail = sessLines }
    end
    return out
end

local function change(now, base)
    local d = now - base
    local p = base > 0 and d / base * 100 or 0
    local col = d > 0 and "|cff40ff40" or (d < 0 and "|cffff5050" or "|cff999999")
    return col .. string.format("%+.1f%%", p) .. "|r", d, col
end
local function histEntries()
    local out = {}
    for _, m in ipairs(Tl.histList(UI.histQ)) do
        local now = ns.lookup(m.id)
        local shown = now or m.last
        out[#out + 1] = { id = m.id, left = m.name, sub = now and "" or "not listed now", right = coin(shown) .. "  " .. change(shown, m.day1p), v = shown,
            pick = function() S.histId = m.id end, detail = function() return {} end }
    end
    return out
end

-- ------------------------------------------------------------------------- deals, known recipes, own auctions --
local function fresh(src, t) return (src == "scan" and "scan " or "feed ") .. ns.age(t) end
local function dealEntries()
    local out = {}
    if not X then return out end
    local t = ns.now()
    if not UI.dealAsk or t - UI.dealAsk > 60 then UI.dealAsk = t; X.vendorScan() end
    for _, d in ipairs(X.deals()) do
        if d.kind == "vendor" then
            out[#out + 1] = { left = d.name, sub = "below vendor price, " .. d.qty .. " listed", right = "|cff40ff40+" .. coin(d.gain) .. "|r each", v = d.gain,
                detail = function()
                    return { "|cffffd100" .. d.name .. "|r  buy it on the auction house, sell it to a vendor",
                        "AH lowest (" .. fresh(d.src, d.t) .. "): " .. coin(d.price) .. " each, " .. d.qty .. " listed",
                        "A vendor pays " .. coin(d.vendor) .. " each: |cff40ff40+" .. coin(d.gain) .. "|r per unit, with no auction cut and no deposit.",
                        grey("Only the cheapest listing is known to be this low; the next one may cost more. Check the price before you buy."),
                        grey("A price from the feed can be up to an hour old, and someone else may have bought it. Nothing is bought for you.") }
                end }
        else
            out[#out + 1] = { left = d.name, sub = pct(d.below) .. " under its usual price", right = coin(d.price), v = d.below,
                detail = function()
                    return { "|cffffd100" .. d.name .. "|r  cheaper than usual",
                        "AH lowest now (" .. fresh(d.src, d.t) .. "): " .. coin(d.price) .. " each, " .. d.qty .. " listed",
                        "Usual price: " .. coin(d.usual) .. grey("  the middle of its daily prices over " .. d.days .. " days"),
                        "That is " .. pct(d.below) .. " lower. The Prices tab shows its graph.",
                        grey("A low price can stay low. This is not a promise that it rises again.") }
                end }
        end
    end
    return out
end
local function recEntries()
    local out = {}
    if not X then return out end
    local C = (AHProfitDB and AHProfitDB.cut) or 5
    for _, r in ipairs(X.recipes(C)) do
        local right = r.profit and ((r.profit >= 0 and "|cff40ff40" or "|cffff5050") .. signed(r.profit) .. "|r") or grey("no price")
        out[#out + 1] = { left = r.name .. (r.makes ~= 1 and (" x" .. (r.lo == r.hi and r.lo or (r.lo .. "-" .. r.hi))) or ""), sub = r.prof, right = right, v = r.profit or 0, dim = r.profit == nil,
            detail = function()
                local L = { "|cffffd100" .. r.name .. "|r  " .. grey(r.prof ~= "" and r.prof or "profession") }
                if r.how == "ah" then L[#L + 1] = "Sells for " .. coin(r.value) .. " on the AH after the " .. C .. "% cut" .. grey("  " .. coin(r.price) .. " each, " .. r.listed .. " listed, " .. fresh(r.src, r.t))
                elseif r.how == "vendor" then L[#L + 1] = "Sells for " .. coin(r.value) .. " at a vendor" .. grey("  no auction listing pays more")
                else L[#L + 1] = "What it makes has no auction listing and no vendor value." end
                L[#L + 1] = "Materials:"
                for _, m in ipairs(r.mats) do
                    L[#L + 1] = "  " .. m.q .. " " .. m.name .. "  " .. (m.each and (coin(m.each * m.q) .. grey(m.from == "vendor" and "  from a vendor" or "  on the AH")) or grey("no price known; open a vendor that sells it once"))
                end
                if r.profit then L[#L + 1] = "Buying every material (" .. coin(r.cost) .. "): " .. signed(r.profit) end
                if r.own then L[#L + 1] = "With your own materials, compared with selling them: " .. signed(r.own) end
                L[#L + 1] = grey("Asking prices, not completed sales. Listing deposits are not included. Recipes are read from your profession window.")
                return L
            end }
    end
    return out
end
local function aucEntries()
    local out = {}
    UI.aucTot = nil
    if not X then return out end
    local C = (AHProfitDB and AHProfitDB.cut) or 5
    local rows, tot = X.auctions(C)
    if not rows then return out end
    UI.aucTot = tot
    for _, r in ipairs(rows) do
        local sub = r.sold and "sold, gold waiting" or (r.under and "someone is cheaper" or (r.each == 0 and "bid only" or "lowest or equal"))
        out[#out + 1] = { left = r.name .. (r.q > 1 and (" x" .. r.q) or ""), sub = sub, right = (r.sold and "|cff40ff40" or "") .. coin(r.net) .. (r.sold and "|r" or ""), v = r.net, dim = r.under,
            detail = function()
                local L = { "|cffffd100" .. r.name .. "|r  " .. (r.sold and "sold" or "listed") .. ", " .. r.q .. " at " .. coin(r.each) .. " each" }
                L[#L + 1] = (r.sold and "You receive " or "If all of it sells you receive ") .. coin(r.net) .. " after the " .. C .. "% cut."
                if r.low and not r.sold then
                    L[#L + 1] = "Lowest listing now (" .. fresh(r.src, r.lowT) .. "): " .. coin(r.low) .. (r.under and "  |cffff5050below yours|r" or "")
                end
                if r.soldN then
                    local n = r.soldN + r.expiredN
                    L[#L + 1] = "Your record for this item: " .. r.soldN .. " sold, " .. r.expiredN .. " expired" .. (n >= 3 and ("  (" .. pct(r.soldN / n) .. " sold)") or "")
                else L[#L + 1] = grey("No sale or expiry of this item recorded yet.") end
                L[#L + 1] = grey("A listed auction is not income. It counts only when the game says it sold.")
                return L
            end }
    end
    return out
end

-- The price graph of the chosen material: one point per day, the day-1 price as a level line, and the price now.
local PX, PY, PW, PH = 74, -78, 486, 122
function UI:DrawGraph()
    local g = self.graph
    for kind, list in pairs(g.pool) do
        for i = 1, #list do list[i]:Hide() end
        g.used[kind] = 0
    end
    local function take(kind, make)
        g.used[kind] = (g.used[kind] or 0) + 1
        local o = g.pool[kind][g.used[kind]]
        if not o then o = make(); g.pool[kind][g.used[kind]] = o end
        o:Show()
        return o
    end
    for _, l in ipairs({ g.hi, g.lo, g.base, g.from, g.to }) do l:SetText("") end
    local idx
    if S.histId then for _, m in ipairs(Tl.histList()) do if m.id == S.histId then idx = m.idx; break end end end
    local s = idx and Tl.histSeries(idx)
    self.series = s
    if not s then
        g.text:SetText(Tl.histTime() and "Pick a material from the list. Its graph shows the price on every day since day 1 and the difference to now."
            or "Price history is missing. Run the updater, then /reload.")
        return
    end
    local now, _, nowT, src = ns.lookup(s.id)
    local pts = {}
    for i, p in ipairs(s.pts) do pts[i] = p end
    local last = pts[#pts]
    if now and (not last or (nowT + 10800) / 86400 >= last.d) then pts[#pts + 1] = { d = (nowT + 10800) / 86400, p = now, now = true } end
    local cur = now or (last and last.p) or s.day1p
    local pc, diff, col = change(cur, s.day1p)
    local lo, hi = math.min(s.lo, cur), math.max(s.hi, cur)
    g.text:SetText("|cffffd100" .. s.name .. "|r  " .. (now and ("now " .. coin(now) .. grey(" (" .. (src == "scan" and "scan " or "feed ") .. ns.age(nowT) .. ")")) or ("not listed now, last seen at " .. coin(cur)))
        .. "\nDay 1 (" .. Tl.dayText(s.day1) .. "): " .. coin(s.day1p) .. "     Since day 1: " .. col .. (diff >= 0 and "+" or "") .. coin(diff) .. "|r  " .. pc
        .. "\n" .. grey("Lowest " .. coin(lo) .. ", highest " .. coin(hi) .. " over " .. #s.pts .. (#s.pts == 1 and " day" or " days") .. " with listings. Each day is the middle of that day's hourly lowest asking price."))
    self.graphInfo = { now = now, cur = cur, diff = diff, lo = lo, hi = hi, n = #pts }
    if #pts == 0 then return end
    local span = hi - lo
    local lo2, hi2 = lo - math.max(1, span * 0.08), hi + math.max(1, span * 0.08)
    local x0 = pts[1].d
    local x1 = math.max(pts[#pts].d, x0 + 1)
    local function px(d) return PX + (d - x0) / (x1 - x0) * PW end
    local function py(p) return PY - (1 - (p - lo2) / (hi2 - lo2)) * PH end
    local function seg(xa, ya, xb, yb, r, gr, b, a, th)
        local l = take("line", function() return g:CreateLine(nil, "ARTWORK") end)
        l:SetThickness(th); l:SetColorTexture(r, gr, b, a)
        l:SetStartPoint("TOPLEFT", g, xa, ya); l:SetEndPoint("TOPLEFT", g, xb, yb)
        return l
    end
    seg(PX, py(s.day1p), PX + PW, py(s.day1p), 1, 0.82, 0, 0.45, 1).isBase = true
    for k = 1, #pts - 1 do
        local a, b = pts[k], pts[k + 1]
        if b.d - a.d <= 1.0001 then seg(px(a.d), py(a.p), px(b.d), py(b.p), 0.3, 0.9, 1, 0.95, 2) end   -- no line across days without listings
    end
    for _, p in ipairs(pts) do
        local t = take("dot", function() return g:CreateTexture(nil, "OVERLAY") end)
        if p.now then t:SetColorTexture(1, 1, 1, 1) else t:SetColorTexture(0.3, 0.9, 1, 1) end
        t:SetSize(p.now and 7 or 5, p.now and 7 or 5)
        t:ClearAllPoints(); t:SetPoint("CENTER", g, "TOPLEFT", px(p.d), py(p.p))
    end
    g.hi:SetText(coin(hi)); g.hi:ClearAllPoints(); g.hi:SetPoint("RIGHT", g, "TOPLEFT", PX - 6, py(hi))
    if hi > lo then g.lo:SetText(coin(lo)); g.lo:ClearAllPoints(); g.lo:SetPoint("RIGHT", g, "TOPLEFT", PX - 6, py(lo)) end
    g.base:SetText("day 1"); g.base:ClearAllPoints(); g.base:SetPoint("BOTTOMRIGHT", g, "TOPLEFT", PX + PW, py(s.day1p) + 1)
    g.from:SetText(Tl.dayText(math.floor(x0)))
    g.to:SetText(pts[#pts].now and "now" or Tl.dayText(math.floor(pts[#pts].d)))
end

function UI:Entries()
    settings()
    local CUT = cut()
    if S.tab == "bags" then return bagEntries() end
    if S.tab == "sess" then return sessEntries() end
    if S.tab == "hist" then return histEntries() end
    if S.tab == "deals" then return dealEntries() end
    if S.tab == "rec" then return recEntries() end
    if S.tab == "auc" then return aucEntries() end
    if S.tab == "mine" then return zoneEntries(CUT) end
    if S.tab == "mobs" then return actEntries(F.mobs(S, CUT), CUT, "kill") end
    if S.tab == "craft" then return craftEntries(CUT) end
    local out = actEntries(F.fishing(S, CUT), CUT, "catch")
    for _, e in ipairs(actEntries(F.trunks(S, CUT), CUT, "trunk")) do e.sub = "per trunk fished up"; out[#out + 1] = e end
    return out
end

function UI:EmptyText()
    if S.tab == "mine" then
        if not S.mining and not S.herbalism then return "Tick Mining or Herbalism to see gathering zones." end
        return "Nothing you can gather in zones for level " .. S.lvMin .. "-" .. S.lvMax .. " at your skill."
    elseif S.tab == "mobs" then return "No mobs recorded for level " .. S.lvMin .. "-" .. S.lvMax .. "."
    elseif S.tab == "craft" then
        if not S.mining and not S.blacksmithing then return "Tick Mining (smelting) or Blacksmithing to see crafts." end
        return "No craft currently beats selling the materials."
    end
    if S.tab == "bags" then
        if not self.bagTot then return "This client does not report the bag contents." end
        return "Nothing in your bags is worth auctioning or vendoring."
    elseif S.tab == "sess" then return self.sessR and "No items gained in this session yet." or ""
    elseif S.tab == "hist" then return Tl.histTime() and "No material matches that search." or ""
    elseif S.tab == "deals" then
        local known, unknown, busy = 0, 0, false
        if X then known, unknown, busy = X.vendorState() end
        if busy or (known == 0 and unknown > 0) then return "Asking the game for vendor prices (" .. known .. " of " .. (known + unknown) .. "). This takes a moment the first time." end
        return "No deals right now: nothing is listed below its vendor price and no material is well under its usual price."
    elseif S.tab == "rec" then return "No recipes read yet. Open your profession window once and they appear here."
    elseif S.tab == "auc" then return self.aucTot and "You have no auctions." or "Not read yet. Open the auction house and its Auctions tab once." end
    return "No fishing data."
end

-- ------------------------------------------------------------------------------------------------- world map --
local overlay, pool, used, shown = nil, { tex = {}, line = {}, text = {} }, {}, nil
local function take(kind, make)
    used[kind] = (used[kind] or 0) + 1
    local o = pool[kind][used[kind]]
    if not o then o = make(); pool[kind][used[kind]] = o end
    o:Show()
    return o
end
local function clearMap()
    for kind, list in pairs(pool) do
        for i = 1, #list do list[i]:Hide() end
        used[kind] = 0
    end
end
local function drawMap()
    if not overlay then return end
    clearMap()
    local m = shown
    if not m or not WorldMapFrame:IsShown() or WorldMapFrame:GetMapID() ~= m.mapID then return end
    local canvas = WorldMapFrame:GetCanvas()
    local w, h = canvas:GetWidth(), canvas:GetHeight()
    local function tex() return take("tex", function() return overlay:CreateTexture(nil, "OVERLAY") end) end
    if m.score then                                              -- gathering: shaded squares, then the numbered loop
        for c, v in pairs(m.score) do
            local t = tex()
            t:SetColorTexture(1, 0.82, 0, 0.12 + 0.38 * (v / m.max))
            t:SetSize(w / 20, h / 20)
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", canvas, "TOPLEFT", (c % 20) * w / 20, -math.floor(c / 20) * h / 20)
        end
        local n = #m.pts
        for k, p in ipairs(m.pts) do
            if n > 1 then
                local q = m.pts[k % n + 1]
                local l = take("line", function() return overlay:CreateLine(nil, "OVERLAY") end)
                l:SetThickness(3)
                l:SetColorTexture(0.3, 0.9, 1, 0.9)
                l:SetStartPoint("TOPLEFT", canvas, p.x / 100 * w, -p.y / 100 * h)
                l:SetEndPoint("TOPLEFT", canvas, q.x / 100 * w, -q.y / 100 * h)
            end
            local fs = take("text", function() return overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge") end)
            fs:SetText(k)
            fs:ClearAllPoints()
            fs:SetPoint("CENTER", canvas, "TOPLEFT", p.x / 100 * w, -p.y / 100 * h)
        end
    end
    if m.seen then                                               -- nodes picked by you and your guild
        local d = math.max(5, w / 130)
        for _, p in ipairs(m.seen) do
            local t = tex()
            t:SetColorTexture(0.25, 1, 0.25, 0.95)
            t:SetSize(d, d)
            t:ClearAllPoints()
            t:SetPoint("CENTER", canvas, "TOPLEFT", p.x / 100 * w, -p.y / 100 * h)
        end
    end
    if m.dots then                                               -- mobs: one dot per recorded spawn point
        local d = math.max(4, w / 160)
        for _, p in ipairs(m.dots) do
            local t = tex()
            t:SetColorTexture(1, 0.25, 0.2, 0.9)
            t:SetSize(d, d)
            t:ClearAllPoints()
            t:SetPoint("CENTER", canvas, "TOPLEFT", p.x / 100 * w, -p.y / 100 * h)
        end
    end
end
local function hookMap()
    if overlay or not WorldMapFrame or not WorldMapFrame.GetCanvas then return overlay ~= nil end
    overlay = CreateFrame("Frame", nil, WorldMapFrame:GetCanvas())
    overlay:SetAllPoints(WorldMapFrame:GetCanvas())
    overlay:SetFrameStrata("HIGH")
    hooksecurefunc(WorldMapFrame, "OnMapChanged", drawMap)
    WorldMapFrame:HookScript("OnShow", drawMap)
    return true
end
function UI:ShowOnMap(m)
    if not m or not m.mapID or m.mapID == 0 then return false, "no map for this" end
    if InCombatLockdown and InCombatLockdown() then return false, "not in combat" end
    if not hookMap() then return false, "world map not available" end
    shown = m
    if OpenWorldMap then OpenWorldMap(m.mapID)
    else
        if not WorldMapFrame:IsShown() then WorldMapFrame:Show() end
        WorldMapFrame:SetMapID(m.mapID)
    end
    drawMap()
    return true
end
function UI:ClearMap() shown = nil; if overlay then clearMap() end end

-- The game's own map pin, at the first loop stop or the densest spawn area.
function UI:Waypoint(m)
    local p = m and ((m.pts and m.pts[1]) or m.hot)
    if not p or not m.mapID or m.mapID == 0 then return false, "nothing to point at" end
    if not (C_Map and C_Map.SetUserWaypoint) then return false, "this client has no map pins" end
    if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(m.mapID) then return false, "the game does not allow a pin on that map" end
    local pos = CreateVector2D and CreateVector2D(p.x / 100, p.y / 100) or { x = p.x / 100, y = p.y / 100 }
    local ok = pcall(C_Map.SetUserWaypoint, { uiMapID = m.mapID, position = pos })
    if not ok then return false, "the game refused the pin" end
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true) end
    return true, string.format("%s %.1f, %.1f", m.name, p.x, p.y)
end

-- ------------------------------------------------------------------------------------------------------ window --
local ROW_H = 20
function UI:Build()
    if self.frame then return end
    settings()
    local f = CreateFrame("Frame", "AHProfitFarmFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    self.frame = f
    f:Hide()
    f:SetSize(600, 584)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    f:SetFrameStrata("MEDIUM")
    f:SetMovable(true); f:EnableMouse(true); f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    backdrop(f)
    if UISpecialFrames then UISpecialFrames[#UISpecialFrames + 1] = "AHProfitFarmFrame" end
    local title = label(f, "GameFontNormalLarge", "AH Profit: gold farming")
    title:SetPoint("TOPLEFT", 14, -12)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    self.status = label(f)
    self.status:SetPoint("TOPLEFT", 14, -34); self.status:SetPoint("TOPRIGHT", -14, -34)
    self.status:SetTextColor(GREY[1], GREY[2], GREY[3])

    -- setup row 1: level range and the character button
    local function box(key, x, y, w)
        local b = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
        b:SetSize(w or 36, 20); b:SetPoint("TOPLEFT", x, y)
        b:SetAutoFocus(false); b:SetNumeric(true); b:SetMaxLetters(3)
        local function apply()
            local v = math.max(1, tonumber(b:GetText()) or 1)
            S[key] = v
            if key == "lvMin" and S.lvMin > S.lvMax then S.lvMax = S.lvMin end
            if key == "lvMax" and S.lvMax < S.lvMin then S.lvMin = S.lvMax end
            UI:Refresh()
        end
        b:SetScript("OnEnterPressed", function() b:ClearFocus() end)
        b:SetScript("OnEscapePressed", function() b:ClearFocus() end)
        b:SetScript("OnEditFocusLost", apply)
        UI.boxes[key] = b
        return b
    end
    local function check(key, text, x, y)
        local c = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
        c:SetSize(22, 22); c:SetPoint("TOPLEFT", x, y)
        local t = label(f, "GameFontHighlightSmall", text); t:SetPoint("LEFT", c, "RIGHT", 0, 0)
        c.label = t
        c:SetScript("OnClick", function() S[key] = c:GetChecked() and true or false; UI:Refresh() end)
        UI.checks[key] = c
        return c
    end
    self.boxes, self.checks, self.setup = {}, {}, {}
    local l1 = label(f, nil, "Level"); l1:SetPoint("TOPLEFT", 14, -58)
    box("lvMin", 54, -54); local dash = label(f, nil, "to"); dash:SetPoint("TOPLEFT", 96, -58); box("lvMax", 116, -54)
    local me = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    me:SetSize(120, 22); me:SetPoint("TOPLEFT", 170, -53); me:SetText("Use my character")
    me:SetScript("OnClick", function() UI:Detect(S); UI:Refresh() end)
    self.setup = { l1, dash, me }
    check("mining", "Mining", 12, -78);          box("mSkill", 84, -80)
    check("herbalism", "Herbalism", 134, -78);   box("hSkill", 222, -80)
    check("blacksmithing", "Blacksmithing", 272, -78); box("bSkill", 380, -80)
    check("skinning", "Skinning", 432, -78)

    -- tabs
    self.tabs = {}
    for i, t in ipairs(TABS) do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(56, 24); b:SetPoint("TOPLEFT", 13 + (i - 1) * 57.5, -110)
        b:SetNormalFontObject("GameFontNormalSmall"); b:SetHighlightFontObject("GameFontHighlightSmall")
        b:SetText(t[2])
        b:SetScript("OnClick", function() S.tab = t[1]; UI.sel = nil; UI:Refresh() end)
        if (not Tl and not FARM_TAB[t[1]]) or (not X and EXTRA_TAB[t[1]]) then b:Hide() end
        self.tabs[t[1]] = b
    end
    -- what the three tool tabs say in place of the level and profession rows
    self.intro = label(f, "GameFontHighlightSmall"); self.intro:SetPoint("TOPLEFT", 14, -56); self.intro:SetPoint("TOPRIGHT", -14, -56)
    self.intro:SetJustifyV("TOP"); self.intro:SetSpacing(3)
    self.head = label(f, "GameFontNormal"); self.head:SetPoint("TOPLEFT", 16, -142); self.head:SetPoint("TOPRIGHT", -36, -142)

    -- list
    local sf = CreateFrame("ScrollFrame", "AHProfitFarmList", f, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 12, -160); sf:SetPoint("TOPRIGHT", -34, -160); sf:SetHeight(170)
    local child = CreateFrame("Frame", nil, sf); child:SetSize(550, 10); sf:SetScrollChild(child)
    self.list, self.rows = child, {}
    self.empty = label(f, "GameFontHighlight"); self.empty:SetPoint("TOPLEFT", 20, -170); self.empty:SetPoint("TOPRIGHT", -40, -170)

    -- detail
    local map = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    map:SetSize(130, 22); map:SetPoint("TOPLEFT", 14, -338); map:SetText("Show on map")
    map:SetScript("OnClick", function() UI:Act("map") end)
    local way = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    way:SetSize(130, 22); way:SetPoint("LEFT", map, "RIGHT", 6, 0); way:SetText("Set map pin")
    way:SetScript("OnClick", function() UI:Act("pin") end)
    local clr = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clr:SetSize(110, 22); clr:SetPoint("LEFT", way, "RIGHT", 6, 0); clr:SetText("Clear map")
    clr:SetScript("OnClick", function() UI:ClearMap(); UI.note:SetText("") end)
    self.mapBtn, self.wayBtn, self.clrBtn = map, way, clr
    self.note = label(f); self.note:SetPoint("LEFT", clr, "RIGHT", 8, 0); self.note:SetPoint("RIGHT", f, "RIGHT", -14, 0)
    local df = CreateFrame("ScrollFrame", "AHProfitFarmDetail", f, "UIPanelScrollFrameTemplate")
    df:SetPoint("TOPLEFT", 12, -366); df:SetPoint("BOTTOMRIGHT", -34, 12)
    local dchild = CreateFrame("Frame", nil, df); dchild:SetSize(550, 10); df:SetScrollChild(dchild)
    self.detail = label(dchild, "GameFontHighlightSmall")
    self.detail:SetPoint("TOPLEFT", 4, -2); self.detail:SetWidth(540); self.detail:SetJustifyV("TOP"); self.detail:SetSpacing(3)
    self.dchild, self.dframe = dchild, df

    -- session button and the material search box share the button row
    local sb = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    sb:SetSize(130, 22); sb:SetPoint("TOPLEFT", 14, -338)
    sb:SetScript("OnClick", function()
        if not Tl then return end
        if Tl.sessionOn() then Tl.sessionStop() else Tl.sessionStart() end
        UI.sel = nil; UI:Refresh()
    end)
    self.sessBtn = sb
    local q = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    q:SetSize(150, 20); q:SetPoint("TOPRIGHT", -36, -138); q:SetAutoFocus(false); q:SetMaxLetters(30)
    q:SetScript("OnEnterPressed", function() q:ClearFocus() end)
    q:SetScript("OnEscapePressed", function() q:ClearFocus() end)
    q:SetScript("OnTextChanged", function()
        local t = (q:GetText() or ""):lower():match("^%s*(.-)%s*$")
        if t ~= (UI.histQ or "") then UI.histQ = t; UI:Refresh() end
    end)
    self.search = q
    self.searchLabel = label(f, nil, "Search"); self.searchLabel:SetPoint("RIGHT", q, "LEFT", -8, 0)

    -- price graph, in place of the detail text on the Prices tab
    local g = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
    g:SetPoint("TOPLEFT", 12, -338); g:SetPoint("BOTTOMRIGHT", -12, 12)
    backdrop(g, 0.6)
    g.pool, g.used = { line = {}, dot = {} }, {}
    g.text = label(g, "GameFontHighlightSmall"); g.text:SetPoint("TOPLEFT", 10, -8); g.text:SetWidth(556); g.text:SetJustifyV("TOP"); g.text:SetSpacing(3)
    g.hi, g.lo, g.base, g.from, g.to = label(g), label(g), label(g), label(g), label(g)
    for _, l in ipairs({ g.hi, g.lo, g.base, g.from, g.to }) do l:SetTextColor(GREY[1], GREY[2], GREY[3]) end
    g.from:SetPoint("TOPLEFT", g, "TOPLEFT", PX, PY - PH - 4); g.to:SetPoint("TOPRIGHT", g, "TOPLEFT", PX + PW, PY - PH - 4)
    local ax = g:CreateTexture(nil, "BACKGROUND"); ax:SetColorTexture(1, 1, 1, 0.05); ax:SetSize(PW, PH); ax:SetPoint("TOPLEFT", g, "TOPLEFT", PX, PY)
    g:Hide()
    self.graph = g
end

function UI:Row(i)
    local r = CreateFrame("Button", nil, self.list)
    r:SetSize(550, ROW_H); r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints(r); r.bg:SetColorTexture(1, 0.82, 0, 0.18); r.bg:Hide()
    r.left = label(r, "GameFontHighlight"); r.left:SetPoint("LEFT", 6, 0)
    r.right = label(r, "GameFontHighlight"); r.right:SetPoint("RIGHT", -6, 0); r.right:SetJustifyH("RIGHT")
    r:SetScript("OnClick", function()
        local e = UI.entries and UI.entries[r.index]
        if e and e.pick then e.pick() end
        UI.sel = r.index; UI:Refresh()
    end)
    self.rows[i] = r
    return r
end

function UI:Act(what)
    local e = self.entries and self.entries[self.sel or 1]
    local m = e and e.map and e.map()
    local ok, msg
    if what == "map" then ok, msg = self:ShowOnMap(m) else ok, msg = self:Waypoint(m) end
    self.note:SetText(ok and (what == "pin" and ("Pin set: " .. msg) or "") or ("Cannot: " .. (msg or "?")))
end

local INTRO = {
    bags = "What to do with everything in your bags: auction it when the auction house leaves you more than a vendor after the cut, vendor it otherwise. Soulbound and quest items are left out of the auction side.",
    sess = "Measured gold per hour. It counts the coin you really receive and the items that really land in your bags, from the moment you press Start.",
    hist = "Pick a material to see its price day by day since day 1, the first day this addon's price feed recorded it.",
    deals = "Things you can buy cheap right now: auctions listed below what a vendor pays for the item, and materials well under their own usual price. Vendor prices are read from the game.",
    rec = "The recipes you know, with what each one earns: what it makes sells for, against buying the materials at their cheapest. The same lines show under your profession window.",
    auc = "Your own auctions as the game lists them: what you get if they sell, whether someone is cheaper, and how often each item sold or expired for you.",
}
function UI:Refresh()
    if not self.frame then return end
    settings()
    local farmTab = FARM_TAB[S.tab] == true
    if farmTab and not F.ready() then
        self.status:SetText("Farm data is missing. Run the updater, then /reload.")
        return
    end
    for k, b in pairs(self.boxes) do if not b:HasFocus() then b:SetText(tostring(S[k])) end end
    for k, c in pairs(self.checks) do c:SetChecked(S[k] and true or false) end
    for k, b in pairs(self.boxes) do b:SetShown(farmTab) end
    for _, c in pairs(self.checks) do c:SetShown(farmTab); if c.label then c.label:SetShown(farmTab) end end
    for _, w in ipairs(self.setup) do w:SetShown(farmTab) end
    if farmTab then
        self.boxes.mSkill:SetShown(S.mining); self.boxes.hSkill:SetShown(S.herbalism); self.boxes.bSkill:SetShown(S.blacksmithing)
    end
    self.intro:SetText(farmTab and "" or INTRO[S.tab])
    for k, b in pairs(self.tabs) do if k == S.tab then b:LockHighlight() else b:UnlockHighlight() end end
    local C = (AHProfitDB and AHProfitDB.cut) or 5
    if farmTab then
        local t = F.time()
        self.status:SetText("Auction prices from " .. date("%a %H:%M", t) .. " (" .. ns.age(t) .. "), " .. C .. "% cut taken off. Asking prices, not completed sales.")
    elseif S.tab == "hist" then
        local t = Tl.histTime()
        self.status:SetText(t and ("Price history up to " .. date("%a %H:%M", t) .. " (" .. ns.age(t) .. "). One point per day, from the hourly price feed.") or "Price history is missing. Run the updater, then /reload.")
    else
        local L = ns.live()
        self.status:SetText("Prices: " .. (L.full > 0 and ("your or a guild scan " .. ns.age(L.full) .. ", else ") or "") .. (ns.seed and ("the feed from " .. ns.age(ns.seed.t)) or "no feed") .. ". " .. C .. "% cut taken off.")
    end
    local list = self:Entries()
    self.entries = list
    if S.tab == "hist" then
        self.sel = 0
        for i, e in ipairs(list) do if e.id == S.histId then self.sel = i; break end end
    elseif not self.sel or self.sel > #list or self.sel < 1 then self.sel = 1 end
    if farmTab then
        local unit
        for _, x in ipairs(TABS) do if x[1] == S.tab then unit = x[3] end end
        self.head:SetText(#list > 0 and (#list .. " options, best first. Value is the average per " .. unit .. ".") or "")
    elseif S.tab == "bags" then
        local t, n = self.bagTot, 0
        for _, e in ipairs(list) do if e.verdict == "ah" and not e.bank then n = n + 1 end end
        local bt = self.bankTot
        self.head:SetText(t and ("Auction " .. n .. " for " .. coin(t.ah) .. ", vendor the rest for " .. coin(t.vendor) .. ": " .. coin(t.extra) .. " more than vendoring it all."
            .. (t.pending > 0 and grey("  " .. t.pending .. " still loading") or "")
            .. (bt and grey("  Bank (" .. ns.age(self.bankAt) .. "): " .. coin(bt.ah + bt.vendor)) or "")) or "")
        if t and t.pending > 0 and (self.retry or 0) < 4 and C_Timer and C_Timer.After then
            self.retry = (self.retry or 0) + 1
            C_Timer.After(1, function() if UI.frame:IsShown() and S.tab == "bags" then UI:Refresh() end end)
        elseif t and t.pending == 0 then self.retry = 0 end
    elseif S.tab == "sess" then
        self.head:SetText(#list > 0 and (#list .. " kinds of items gained this session, most valuable first.") or "")
    elseif S.tab == "hist" then
        self.head:SetText(#list .. " materials. Price now and change since day 1.")
    elseif S.tab == "deals" then
        local nv = 0
        for _, e in ipairs(list) do if e.sub:find("below vendor", 1, true) then nv = nv + 1 end end
        local _, unknown, busy = X.vendorState()
        self.head:SetText(#list > 0 and (nv .. " below vendor price, " .. (#list - nv) .. " under their usual price." .. ((busy or unknown > 0) and grey("  " .. unknown .. " vendor prices still loading") or "")) or "")
        if busy and (self.dealRetry or 0) < 40 and C_Timer and C_Timer.After then
            self.dealRetry = (self.dealRetry or 0) + 1
            C_Timer.After(3, function() if UI.frame:IsShown() and S.tab == "deals" then UI:Refresh() end end)
        elseif not busy then self.dealRetry = 0 end
    elseif S.tab == "rec" then
        local n = 0
        for _, e in ipairs(list) do if e.v > 0 then n = n + 1 end end
        self.head:SetText(#list > 0 and (#list .. " recipes you know, " .. n .. " earn something when you buy the materials. Profit per craft.") or "")
    else
        local t = self.aucTot
        self.head:SetText(t and (t.n + t.soldN) > 0 and (t.n .. " listed, " .. coin(t.asking) .. " if all sell" .. (t.under > 0 and (", " .. t.under .. " undercut") or "") .. (t.soldN > 0 and (", " .. t.soldN .. " sold") or "")
            .. grey("  read " .. ns.age(t.t))) or "")
    end
    for i, e in ipairs(list) do
        local r = self.rows[i] or self:Row(i)
        r.index = i
        r.left:SetText(e.left .. (e.sub ~= "" and ("  " .. grey(e.sub)) or ""))
        r.right:SetText(e.right)
        r.left:SetAlpha(e.dim and 0.5 or 1); r.right:SetAlpha(e.dim and 0.5 or 1)
        r.bg:SetShown(i == self.sel)
        r:Show()
    end
    for i = #list + 1, #self.rows do self.rows[i]:Hide() end
    self.list:SetHeight(math.max(10, #list * ROW_H))
    local e = list[self.sel]
    self.empty:SetText(#list > 0 and "" or self:EmptyText())
    local isHist, isSess = S.tab == "hist", S.tab == "sess"
    local lines = isSess and sessLines() or (e and not isHist and e.detail()) or nil
    self.detail:SetText(lines and table.concat(lines, "\n") or "")
    self.dchild:SetHeight(math.max(10, self.detail:GetStringHeight() + 8))
    self.dframe:SetShown(not isHist)
    self.graph:SetShown(isHist); self.search:SetShown(isHist); self.searchLabel:SetShown(isHist)
    if isHist then self:DrawGraph() end
    self.sessBtn:SetShown(isSess)
    if isSess then self.sessBtn:SetText(Tl.sessionOn() and "Stop session" or (self.sessR and "Start new session" or "Start session")) end
    local hasMap = farmTab and e and e.map and e.map() ~= nil
    self.mapBtn:SetShown(hasMap and true or false); self.wayBtn:SetShown(hasMap and true or false); self.clrBtn:SetShown(hasMap and true or false)
    if not farmTab then self.note:SetText("") end
end

-- Bags or money changed while the window shows a tool tab: show the new numbers.
function UI:OnTools(ev)
    if not (self.frame and self.frame:IsShown() and S) then return end
    if S.tab == "bags" or S.tab == "sess" then self:Refresh() end
end

-- Something the extras watch changed (bank, vendor prices, recipes, nodes, auctions): redraw the tab that shows it.
local SHOWS = { bags = { bags = true }, deals = { deals = true }, rec = { rec = true }, auc = { auc = true }, nodes = { mine = true, sess = true } }
function UI:OnExtra(kind)
    if not (self.frame and self.frame:IsShown() and S) then return end
    if SHOWS[kind] and SHOWS[kind][S.tab] then self:Refresh() end
end

local OPEN = { bags = "bags", session = "sess", prices = "hist", deals = "deals", recipes = "rec", auctions = "auc" }
function UI:Open(what)
    self:Build()
    if not Tl then return end
    S.tab = OPEN[what] or S.tab
    self.sel = nil
    self.frame:Show(); self:Refresh()
end

function UI:Toggle()
    self:Build()
    if self.frame:IsShown() then self.frame:Hide() else self.frame:Show(); self:Refresh() end
end
