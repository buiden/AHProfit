-- AH Profit bags-full advisor: when the bags are full, says which slot is the least valuable to destroy, or a free
-- fix first (merging stacks). Advice only: nothing here deletes, moves, picks up, sells or uses anything.
-- Saved: DB.keep (item ids never suggested, at most KEEP_MAX), DB.bagfull (alert threshold, -1 = off) and
-- DB.bagAlertPos (the alert's position). Optional fields; older versions of the addon ignore them.
local _, ns = ...
local B = {}
ns.bags = B

local function secret(v) return issecretvalue ~= nil and issecretvalue(v) end
local function num(v) return type(v) == "number" and not secret(v) end
local function str(v) return type(v) == "string" and not secret(v) end
local function db() return ns.db and ns.db() end
local KEEP_MAX = 500
B.KEEP_MAX = KEEP_MAX

-- Never suggested by id: hearthstone, gathering and crafting tools, and class reagents (all classes; only the
-- player's own class needs them, but any of them in the bags is there on purpose).
local TOOLS = {
    [6948] = true,                                               -- Hearthstone
    [2901] = true, [7005] = true, [5956] = true, [9149] = true, [4471] = true, [6219] = true, [10498] = true, -- pick, knife, hammer, philosopher's stone, flint, spanner, micro-adjustor
    [6256] = true, [6365] = true, [6366] = true, [6367] = true, [12225] = true, [19022] = true, [19970] = true, -- fishing poles
    [6218] = true, [6339] = true, [11130] = true, [11145] = true, [16207] = true, -- runed enchanting rods
}
local REAGENTS = {
    ROGUE = { 5140, 5530 }, MAGE = { 17020, 17031, 17032, 17056 }, PRIEST = { 17028, 17029, 17056 }, PALADIN = { 17033, 21177 },
    DRUID = { 17021, 17026, 17034, 17035, 17036, 17037, 17038 }, SHAMAN = { 17030, 17057, 17058 }, WARLOCK = { 6265, 5565, 16583 },
}
local function classReagents()
    local ok, _, token = pcall(function() return UnitClass("player") end)
    local set = {}
    if ok and str(token) and REAGENTS[token] then for _, id in ipairs(REAGENTS[token]) do set[id] = true end end
    return set, ok and str(token) and token or nil
end

-- name, link, quality, max stack, vendor price, class, bind type, icon. nil name: not loaded yet.
local function info(id)
    if not (C_Item and C_Item.GetItemInfo) then return nil end
    local ok, name, link, quality, _, _, _, _, maxStack, _, icon, vendor, classID, _, bind = pcall(C_Item.GetItemInfo, id)
    if not ok or secret(name) or secret(quality) or secret(maxStack) or secret(vendor) or secret(classID) or secret(bind) then return nil end
    return name, link, quality, maxStack, vendor, classID, bind, icon
end
local function band(a, b)                                        -- bitwise and of two small non-negative integers
    local r, bit = 0, 1
    while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then r = r + bit end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return r
end
local function itemFamily(id)
    local fn = (C_Item and C_Item.GetItemFamily) or GetItemFamily
    if not fn then return 0 end
    local ok, f = pcall(fn, id)
    return (ok and num(f)) and f or 0
end
-- Whether an item of family itemFam can go into a bag of family bagFam (0 = a general bag takes anything).
local function fits(bagFam, itemFam) return bagFam == 0 or band(bagFam, itemFam or 0) ~= 0 end
B.fits = fits

-- Bag slots of the equipment manager's sets (when the client has it): never suggested.
local function setSlots()
    local out = {}
    if not (C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs and C_EquipmentSet.GetItemLocations and EquipmentManager_UnpackLocation) then return out end
    pcall(function()
        for _, sid in ipairs(C_EquipmentSet.GetEquipmentSetIDs() or {}) do
            for _, loc in pairs(C_EquipmentSet.GetItemLocations(sid) or {}) do
                if num(loc) and loc > 0 then
                    local _, _, inBags, _, slot, bag = EquipmentManager_UnpackLocation(loc)
                    if inBags and num(bag) and num(slot) then out[bag .. ":" .. slot] = true end
                end
            end
        end
    end)
    return out
end

-- The carried bags (backpack and bags 1-4): { bag, family, size, free } and every slot { bag, slot, id, n, bound,
-- quest }. Unreadable bags or slots are skipped.
function B.scan()
    local C = C_Container
    if not (C and C.GetContainerNumSlots and C.GetContainerItemInfo) then return nil end
    local bags, slots = {}, {}
    for bag = 0, 4 do
        local ok, size = pcall(C.GetContainerNumSlots, bag)
        if ok and num(size) and size > 0 then
            local fam = 0
            if C.GetContainerNumFreeSlots then
                local ok2, _, f = pcall(C.GetContainerNumFreeSlots, bag)
                if ok2 and num(f) then fam = f end
            end
            local b = { bag = bag, family = fam, size = size, free = 0 }
            bags[#bags + 1] = b
            for slot = 1, size do
                local ok3, x = pcall(C.GetContainerItemInfo, bag, slot)
                if ok3 and x == nil then b.free = b.free + 1
                elseif ok3 and type(x) == "table" and num(x.itemID) and num(x.stackCount) then
                    local quest = false
                    if C.GetContainerItemQuestInfo then
                        local ok4, q = pcall(C.GetContainerItemQuestInfo, bag, slot)
                        quest = ok4 and type(q) == "table" and (q.isQuestItem == true or (num(q.questID) and q.questID > 0))
                    end
                    slots[#slots + 1] = { bag = bag, slot = slot, family = fam, id = x.itemID, n = x.stackCount,
                        bound = x.isBound == true, quest = quest, link = str(x.hyperlink) and x.hyperlink or nil,
                        icon = num(x.iconFileID) and x.iconFileID or nil }
                end
            end
        end
    end
    return bags, slots
end

-- Unit value of an item: the vendor price, or the auction price after the cut when that is higher and the item is
-- not bound. nil: unknown (no vendor price and no auction price). how: "vendor" or "ah".
local function unitValue(id, bound)
    local _, _, _, _, vendor = info(id)
    local v = (num(vendor) and vendor > 0) and vendor or nil
    local how = v and "vendor" or nil
    if not bound and ns.lookup then
        local ok, p = pcall(ns.lookup, id)
        if ok and num(p) and p > 0 then
            local cut = (db() and db().cut) or 5
            local net = math.floor(p * (100 - cut) / 100)
            if not v or net > v then v, how = net, "ah" end
        end
    end
    return v, how
end
B.unitValue = unitValue

local function keepList()
    local D = db()
    if not D then return {} end
    if type(D.keep) ~= "table" then D.keep = {} end
    return D.keep
end
-- Why a slot is never suggested, or nil when it may be.
local function protected(s, reagents, sets, keep)
    if keep[s.id] then return "on your keep list" end
    if sets[s.bag .. ":" .. s.slot] then return "in an equipment set" end
    if TOOLS[s.id] then return "a tool" end
    if reagents[s.id] then return "a class reagent" end
    if s.quest then return "a quest item" end
    local name, _, quality, _, vendor, classID = info(s.id)
    if not str(name) then return "not loaded yet" end            -- the client has not loaded the item: skipped
    if classID == 12 then return "a quest item" end
    if classID == 6 then return "ammunition" end
    if classID == 13 then return "a key" end
    if quality == 0 then return nil end                          -- grey: always allowed
    if classID == 0 then return "food, drink or a potion" end
    if s.bound and not (num(vendor) and vendor > 0) then return "bound, no vendor price" end
    return nil
end
B.protected = function(s) return protected(s, classReagents(), setSlots(), keepList()) end

-- The advice for an incoming item (id; nil means any general item):
--   nil                                   the item fits (a free usable slot or a partial stack of it)
--   { kind = "merge", id, link, frees }   merging partial stacks frees a usable slot
--   { kind = "destroy", slot, value, how, grey, unknown }  the least valuable eligible slot in a usable bag
--   { kind = "none" }                     the bags are full and nothing may be suggested
function B.advise(incoming, threshold, scanned)
    local bags, slots
    if scanned then bags, slots = scanned[1], scanned[2] else bags, slots = B.scan() end
    if not bags or #bags == 0 then return nil end                -- nothing readable: no advice
    local fam = incoming and itemFamily(incoming) or 0
    local free = 0
    for _, b in ipairs(bags) do if fits(b.family, fam) then free = free + b.free end end
    if free > (threshold or 0) then return nil end
    local maxOf = {}
    local function maxStack(id)
        if maxOf[id] == nil then local _, _, _, m = info(id); maxOf[id] = num(m) and m > 0 and m or 1 end
        return maxOf[id]
    end
    if incoming and free > 0 then return nil end
    if incoming then                                             -- stacks onto a partial stack of its own: fits
        for _, s in ipairs(slots) do
            if s.id == incoming and fits(s.family, fam) and s.n < maxStack(s.id) then return nil end
        end
    end
    -- free fix: partial stacks of one item in usable bags whose total fits in fewer slots
    local partial = {}
    for _, s in ipairs(slots) do
        if fits(s.family, fam) and s.n < maxStack(s.id) then
            local p = partial[s.id] or { n = 0, slots = 0, link = s.link }
            p.n, p.slots = p.n + s.n, p.slots + 1
            partial[s.id] = p
        end
    end
    local best
    for id, p in pairs(partial) do
        local frees = p.slots - math.ceil(p.n / maxStack(id))
        if frees > 0 and (not best or frees > best.frees or (frees == best.frees and id < best.id)) then
            best = { kind = "merge", id = id, link = p.link, frees = frees }
        end
    end
    if best then return best end
    local reagents, sets, keep = classReagents(), setSlots(), keepList()
    local cands = {}
    for _, s in ipairs(slots) do
        if fits(s.family, fam) and not protected(s, reagents, sets, keep) then
            local each, how = unitValue(s.id, s.bound)
            local _, _, quality = info(s.id)
            cands[#cands + 1] = { slot = s, value = each and each * s.n or nil, each = each, how = how, grey = quality == 0 }
        end
    end
    if #cands == 0 then return { kind = "none" } end
    table.sort(cands, function(a, b)
        if (a.value == nil) ~= (b.value == nil) then return a.value ~= nil end   -- known values before unknown
        if a.value and a.value ~= b.value then return a.value < b.value end      -- the cheapest slot first
        if a.grey ~= b.grey then return a.grey end              -- at the same value, grey first
        if a.slot.bag ~= b.slot.bag then return a.slot.bag < b.slot.bag end
        return a.slot.slot < b.slot.slot
    end)
    local c = cands[1]
    return { kind = "destroy", slot = c.slot, value = c.value, each = c.each, how = c.how, grey = c.grey, unknown = c.value == nil }
end

-- Loot window open and the bags full: the most valuable drop that does not fit, against the cheapest slot it
-- could replace. Returns { drop = { id, n, value }, advice, skip } or nil.
function B.lootCompare()
    if not (GetNumLootItems and GetLootSlotLink and GetLootSlotInfo) then return nil end
    local ok, n = pcall(GetNumLootItems)
    if not ok or not num(n) then return nil end
    local bags, slots = B.scan()
    if not bags then return nil end
    local scanned = { bags, slots }                              -- one read of the bags for every drop
    local best
    for i = 1, n do
        local okL, link = pcall(GetLootSlotLink, i)
        local id = okL and str(link) and tonumber(link:match("item:(%d+)"))
        if id then
            local okI, _, _, qty = pcall(GetLootSlotInfo, i)
            qty = (okI and num(qty) and qty > 0) and qty or 1
            local adv = B.advise(id, 0, scanned)
            if adv and adv.kind == "destroy" then
                local each = unitValue(id, false)
                local v = each and each * qty or nil
                if not best or (v or -1) > (best.drop.value or -1) then best = { drop = { id = id, n = qty, value = v, link = link }, advice = adv } end
            end
        end
    end
    if best then
        local a = best.advice
        best.skip = best.drop.value ~= nil and a.value ~= nil and best.drop.value < a.value
    end
    return best
end

-- --------------------------------------------------------------------------------------------- keep list --
local function idOf(s)
    if not str(s) then return nil end
    local id = tonumber(s:match("item:(%d+)") or s:match("^%s*(%d+)%s*$"))
    return (id and id > 0 and id < 1e7) and id or nil
end
function B.keep(id)
    local K = keepList()
    if K[id] then return true end
    local n = 0
    for _ in pairs(K) do n = n + 1 end
    if n >= KEEP_MAX then return false end
    K[id] = true
    return true
end
function B.unkeep(id) local K = keepList(); local had = K[id] ~= nil; K[id] = nil; return had end
-- Checks the saved keep list at load: ids only, at most KEEP_MAX.
local function loadKeep()
    local D = db()
    if not D then return end
    if ns.sharedOK and not ns.sharedOK() then return end        -- a save from a newer version is left as it is
    if D.keep ~= nil and type(D.keep) ~= "table" then D.keep = {} end
    local n = 0
    for id, v in pairs(D.keep or {}) do
        if not (num(id) and id > 0 and id < 1e7 and id == math.floor(id) and v == true) or n >= KEEP_MAX then D.keep[id] = nil
        else n = n + 1 end
    end
    if D.bagfull ~= nil and not (num(D.bagfull) and D.bagfull >= -1 and D.bagfull <= 20 and D.bagfull == math.floor(D.bagfull)) then D.bagfull = nil end
end
B.loadKeep = loadKeep

local function say(m) if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffffd100AH Profit|r " .. m) end end
-- /ahp keep <item link or id>, /ahp unkeep <...>, /ahp bagfull <0-20 | off>. Returns true when handled.
-- msg arrives lower-cased; item links keep their item:id part.
function B.slash(msg)
    local cmd, rest = msg:match("^(%a+)%s*(.-)$")
    if cmd == "keep" or cmd == "unkeep" then
        local id = idOf(rest)
        if not id then say("/ahp " .. cmd .. " <item link or item id>"); return true end
        if cmd == "keep" then say(B.keep(id) and ("item " .. id .. " is never suggested to destroy.") or ("the keep list is full (" .. KEEP_MAX .. ")."))
        else say(B.unkeep(id) and ("item " .. id .. " can be suggested again.") or ("item " .. id .. " was not on the keep list.")) end
        return true
    elseif cmd == "bagfull" then
        local D = db()
        if not D then return true end
        if rest == "off" then D.bagfull = -1; say("bags-full advice off.")
        else
            local n = tonumber(rest)
            if n and n >= 0 and n <= 20 and n == math.floor(n) then D.bagfull = n; say("bags-full advice when " .. n .. " or fewer general slots are free.")
            else say("/ahp bagfull <0-20> or /ahp bagfull off") end
        end
        return true
    end
    return false
end

-- --------------------------------------------------------------------------------------------------- text --
local function money(c) return ns.money and ns.money(c) or (tostring(c) .. "c") end
local function nameOf(id, link)
    if link then return link end
    local name = info(id)
    return str(name) and name or ("item " .. id)
end
-- Lines for an advice (and a loot comparison): plain text the alert and the tests show.
function B.text(adv, loot)
    if not adv then return nil end
    if adv.kind == "merge" then
        return { "Merge " .. nameOf(adv.id, adv.link) .. " (frees " .. adv.frees .. " slot" .. (adv.frees > 1 and "s" or "") .. ")" }
    elseif adv.kind == "none" then
        return { "Bags full; nothing in them may be suggested (quest items, tools, food, your keep list)." }
    end
    local s = adv.slot
    local why = adv.grey and "grey" or adv.unknown and "value unknown" or (adv.how == "ah" and "cheapest at the auction house" or "cheapest at a vendor")
    local L = { "Cheapest slot: " .. nameOf(s.id, s.link) .. (s.n > 1 and (" x" .. s.n) or "") .. ", "
        .. (adv.value and money(adv.value) or "value unknown") .. " (" .. why .. ")" }
    if loot then
        local d = loot.drop
        if d.value and adv.value then
            L[#L + 1] = "Drop is worth " .. money(d.value) .. ", your cheapest slot is " .. money(adv.value) .. "."
            if loot.skip then L[#L + 1] = "Keep your bags; skip this drop." end
        elseif d.value then
            L[#L + 1] = "Drop is worth " .. money(d.value) .. "; your cheapest slot's value is not known."
        elseif adv.value then
            L[#L + 1] = "The drop's value is not known; your cheapest slot is " .. money(adv.value) .. "."
        else
            L[#L + 1] = "Neither the drop's value nor your cheapest slot's is known."
        end
    end
    return L
end

-- -------------------------------------------------------------------------------------------------- alert --
-- A small movable frame: icon, the advice, Show (opens the bags and marks the slot), Keep, and close. Plain
-- frames only; nothing secure, nothing that acts on items.
local alert, current
-- Marks the slot when its bag is open: the open bag frames' item buttons (pooled, unnamed on this client) are
-- found through EnumerateValidItems, and a frame of our own is laid over the button. The bags are never opened
-- from here (that could taint the game's buttons), and nothing of the game's is changed.
local function bagFrames()
    local out = {}
    pcall(function()
        if ContainerFrameUtil_EnumerateContainerFrames then
            for _, fr in ContainerFrameUtil_EnumerateContainerFrames() do out[#out + 1] = fr end
        end
    end)
    if ContainerFrameCombinedBags then out[#out + 1] = ContainerFrameCombinedBags end
    return out
end
local function glow(bag, slot)
    local found
    for _, fr in ipairs(bagFrames()) do
        if found then break end
        pcall(function()
            if not (fr.IsShown and fr:IsShown() and fr.EnumerateValidItems) then return end
            for _, b in fr:EnumerateValidItems() do
                local okB, bb = pcall(b.GetBagID, b)
                local okS, ss = pcall(b.GetID, b)
                if okB and okS and bb == bag and ss == slot then found = b; return end
            end
        end)
    end
    if alert.mark then alert.mark:Hide() end
    if found then
        if not alert.mark then
            alert.mark = CreateFrame("Frame", nil, UIParent)
            alert.mark:SetFrameStrata("TOOLTIP")
            local t = alert.mark:CreateTexture(nil, "OVERLAY"); t:SetAllPoints(); t:SetColorTexture(1, 0.2, 0.2, 0.35)
        end
        alert.mark:ClearAllPoints(); alert.mark:SetAllPoints(found); alert.mark:Show()
        B.marked = found
    else
        B.marked = nil
    end
    say("bag " .. (bag + 1) .. ", slot " .. slot .. (found and "." or " (open your bags to see it)."))
end
-- Whether the shown slot still holds what the advice says (the bags may have been sorted or changed since).
local function stillThere(adv)
    local s = adv and adv.slot
    if not s then return true end
    local C = C_Container
    if not (C and C.GetContainerItemInfo) then return true end
    B.reads = B.reads + 1
    local ok, x = pcall(C.GetContainerItemInfo, s.bag, s.slot)
    return ok and type(x) == "table" and x.itemID == s.id and x.stackCount == s.n
end
B.reads = 0
local function build()
    if alert then return alert end
    local f = CreateFrame("Frame", "AHProfitBagAlert", UIParent)
    f:SetSize(360, 96); f:SetFrameStrata("DIALOG"); f:SetClampedToScreen(true)
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        local D = db(); if D and num(x) and num(y) then D.bagAlertPos = { p, rp, math.floor(x), math.floor(y) } end
    end)
    local bg = f:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetColorTexture(0, 0, 0, 0.8)
    f.icon = f:CreateTexture(nil, "ARTWORK"); f.icon:SetSize(32, 32); f.icon:SetPoint("TOPLEFT", 8, -8)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); f.text:SetPoint("TOPLEFT", 48, -8); f.text:SetWidth(300); f.text:SetJustifyH("LEFT")
    local function button(label, x, fn)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(70, 20); b:SetPoint("BOTTOMLEFT", x, 8); b:SetText(label); b:SetScript("OnClick", fn)
        return b
    end
    f.show = button("Show", 48, function()
        if not (current and current.slot) then return end
        if not stillThere(current) then B.check(nil, true) end     -- re-advise first: never point at what moved
        if current and current.slot then glow(current.slot.bag, current.slot.slot) end
    end)
    f.keepBtn = button("Keep", 124, function()
        if not (current and current.slot) then return end
        if B.keep(current.slot.id) then say("kept; it will not be suggested again (/ahp unkeep to undo)."); B.check(nil, true)
        else say("the keep list is full (" .. KEEP_MAX .. "); /ahp unkeep an item first.") end
    end)
    f.close = button("Close", 200, function() f:Hide() end)
    local D = db()
    local pos = D and type(D.bagAlertPos) == "table" and D.bagAlertPos
    local placed = pos and str(pos[1]) and str(pos[2]) and num(pos[3]) and num(pos[4])
        and pcall(f.SetPoint, f, pos[1], UIParent, pos[2], pos[3], pos[4])
    if not placed then f:ClearAllPoints(); f:SetPoint("TOP", UIParent, "TOP", 0, -140) end
    f:Hide()
    alert = f
    return f
end
function B.frame() return alert end                              -- for tests
function B.show(adv, loot)
    local L = B.text(adv, loot)
    if not L then if alert then alert:Hide() end return end
    local f = build()
    current = adv
    if alert.mark then alert.mark:Hide() end
    local id = adv.slot and adv.slot.id or adv.id
    local _, _, _, _, _, _, _, icon = info(id)
    f.icon:SetTexture((adv.slot and adv.slot.icon) or icon or 134400)
    f.text:SetText(table.concat(L, "\n"))
    if adv.slot then f.show:Enable(); f.keepBtn:Enable() else f.show:Disable(); f.keepBtn:Disable() end
    f:Show()
    B.lastText = L
end

-- ------------------------------------------------------------------------------------------------- events --
local lootOpen, alerted = false, false
-- Free slots in the general carried bags, from the free-slot count only (cheap: no slot is read). nil: unknown.
local function generalFree()
    local C = C_Container
    if not (C and C.GetContainerNumFreeSlots) then return nil end
    local n = 0
    for bag = 0, 4 do
        local ok, free, fam = pcall(C.GetContainerNumFreeSlots, bag)
        if ok and num(free) and (not num(fam) or fam == 0) then n = n + free end
    end
    return n
end
B.generalFree = generalFree
local function threshold() local D = db(); return (D and num(D.bagfull)) and D.bagfull or 0 end
local function clock() return (GetTime and GetTime()) or ns.now() end
local lastErrAt = -1e9
-- Shows the advice when it is due. err: an "inventory is full" error just happened. force: show again (Keep, or
-- the shown slot changed).
function B.check(err, force)
    local th = threshold()
    if th < 0 then alerted = false; return end
    if err and not force then                                    -- a burst of errors (spam-looting): one scan
        local t = clock()
        if t - lastErrAt < 0.5 and alerted then return end
        lastErrAt = t
    end
    if lootOpen and err then
        local loot = B.lootCompare()
        if loot then alerted = true; B.show(loot.advice, loot); return end
    end
    if not err then                                              -- the frequent bag update: count free slots first
        local free = generalFree()
        if free and free > th then alerted = false; if alert and alert:IsShown() then alert:Hide() end return end
        if alerted and not force then                            -- still full: only check the slot that is shown
            if alert and alert:IsShown() and current and current.slot and not stillThere(current) then force = true
            else return end
        end
    end
    local adv = B.advise(nil, err and 0 or th)
    if not adv then alerted = false; if alert and alert:IsShown() and not err then alert:Hide() end return end
    if alerted and not err and not force then return end        -- one alert per time the bags fill up
    alerted = true
    B.show(adv)
end
local function isFullError(msg)
    if not str(msg) then return false end
    for _, k in ipairs({ "ERR_INV_FULL", "ERR_LOOT_INVENTORY_FULL" }) do  -- the second only where the client has it
        local v = _G[k]
        if str(v) and msg == v then return true end
    end
    return false
end
B.isFullError = isFullError
B.events = { "UI_ERROR_MESSAGE", "BAG_UPDATE_DELAYED", "LOOT_OPENED", "LOOT_READY", "LOOT_CLOSED" }
function B.event(ev, a1, a2)
    if ev == "UI_ERROR_MESSAGE" then
        local msg = str(a2) and a2 or a1                         -- (errorType, message) or (message)
        if isFullError(msg) then B.check(true) end
    elseif ev == "BAG_UPDATE_DELAYED" then B.check(false)
    elseif ev == "LOOT_OPENED" or ev == "LOOT_READY" then lootOpen = true
    elseif ev == "LOOT_CLOSED" then lootOpen = false end
end
local f = CreateFrame("Frame")
f:Hide()
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(_, ev, ...)
    if ev == "PLAYER_LOGIN" then
        loadKeep()
        for _, e in ipairs(B.events) do pcall(f.RegisterEvent, f, e) end   -- an event this client does not have is skipped
        return
    end
    B.event(ev, ...)
end)
