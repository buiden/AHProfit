-- AH Profit scan progress: a small movable window while a full auction house scan runs, with the reason when a scan
-- stops early. It is a plain frame on UIParent: it is never parented to the auction house window and hooks none of
-- its functions, so it cannot taint it. By default it sits top right, clear of the auction house list; it can be
-- dragged anywhere.
-- Saved: AHProfitDB.progress (false = chat lines only) and AHProfitDB.progressPos (where it was dragged to).
local _, ns = ...
local P = {}
ns.progress = P

local frame, token, closedFor, state = nil, 0, nil, nil
local estimate, count = nil, 0
local POINTS = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }

local function on() local DB = ns.db(); return DB ~= nil and DB.progress ~= false end
local function num(n)                                           -- 5200 -> "5,200"
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end
P.num = num

local function place(f)
    f:ClearAllPoints()
    local p = ns.db() and ns.db().progressPos
    if type(p) == "table" and POINTS[p[1]] and POINTS[p[2]] and type(p[3]) == "number" and type(p[4]) == "number"
        and math.abs(p[3]) <= 10000 and math.abs(p[4]) <= 10000 then
        if pcall(f.SetPoint, f, p[1], UIParent, p[2], p[3], p[4]) then return end
        f:ClearAllPoints()
    end
    f:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -60, -140)     -- default: top right, clear of the auction house
end

local function build()
    if frame then return frame end
    local f = CreateFrame("Frame", "AHProfitScanProgress", UIParent)
    f:SetSize(280, 74)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint(1)
        local DB = ns.db()
        if DB and POINTS[p] and POINTS[rp] and type(x) == "number" and type(y) == "number" then
            DB.progressPos = { p, rp, math.floor(x + 0.5), math.floor(y + 0.5) }
        end
    end)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(f)
    bg:SetColorTexture(0, 0, 0, 0.75)
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -8)
    f.title:SetText("AH Profit: scanning the auction house")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", 2, 2)
    close:SetScript("OnClick", function() closedFor = token; f:Hide() end)   -- this scan only
    f.close = close
    local bar = CreateFrame("StatusBar", nil, f)
    bar:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -28)
    bar:SetSize(260, 12)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.2, 0.7, 0.2)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    f.bar = bar
    f.line = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.line:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -4)
    f.state = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.state:SetPoint("TOPLEFT", f.line, "BOTTOMLEFT", 0, -2)
    f:Hide()
    place(f)
    frame = f
    P.frame = f                                                  -- for tests
    return f
end

local function show()
    if not on() or closedFor == token then return end
    build():Show()
end
local function paint()
    if not frame then return end
    local bar = frame.bar
    if estimate and estimate > 0 then
        bar:SetMinMaxValues(0, estimate); bar:SetValue(math.min(count, estimate)); bar:SetAlpha(1)
        frame.indeterminate = false
    else                                                         -- first scan: no estimate, a dim full bar
        bar:SetMinMaxValues(0, 1); bar:SetValue(1); bar:SetAlpha(0.35)
        frame.indeterminate = true
    end
    frame.line:SetText(num(count) .. " items" .. (estimate and estimate > 0 and (" of about " .. num(estimate)) or "")
        .. " · keep the auction house open")
end

-- A scan begins (or waits to begin). est = items in the last full scan, own or guild, or nil.
function P.start(est, waiting)
    token = token + 1
    closedFor, estimate, count = nil, (type(est) == "number" and est > 0) and est or nil, 0
    state = waiting and "waiting" or "scanning"
    if not on() then return end
    show()
    frame.title:SetText("AH Profit: scanning the auction house")
    frame.bar:SetStatusBarColor(0.2, 0.7, 0.2)
    paint()
    frame.state:SetText(waiting and "waiting for the server" or "")
end
function P.count(n)
    count = n
    if frame and state ~= "done" and state ~= "failed" then paint() end
end
-- "scanning", "paused" (selling) or "waiting" (the server's request limit)
function P.state(s)
    if state == "done" or state == "failed" or s == state then return end
    state = s
    if not frame then return end
    frame.state:SetText(s == "paused" and "paused while you sell" or s == "waiting" and "waiting for the server" or "")
end
function P.done(text)
    state = "done"
    if not frame or not on() then return end
    frame.title:SetText("AH Profit: scan finished")
    if estimate then frame.bar:SetMinMaxValues(0, 1) end
    frame.bar:SetValue(1); frame.bar:SetAlpha(1)
    frame.line:SetText(text)
    frame.state:SetText("")
    local mine = token
    C_Timer.After(5, function() if token == mine and frame then frame:Hide() end end)   -- unless a newer scan has it
end
-- The scan stopped early: the reason stays until the window is closed or the auction house is opened again.
function P.fail(text)
    state = "failed"
    if not on() then return end
    show()
    if not frame or not frame:IsShown() then return end
    frame.title:SetText("AH Profit: scan stopped")
    frame.bar:SetStatusBarColor(0.8, 0.2, 0.2)
    frame.line:SetText(text)
    frame.state:SetText("")
end
function P.opened()                                              -- the auction house opened: an old reason goes away
    if state == "scanning" or state == "paused" or state == "waiting" then return end   -- (opened again mid-scan)
    if frame and state == "failed" then frame:Hide() end
    state = nil
end
function P.state_() return state end                             -- for tests

-- /ahp progress on | off | reset
function P.slash(arg)
    local DB = ns.db()
    if arg == "on" or arg == "off" then
        DB.progress = arg == "on"
        if arg == "off" and frame then frame:Hide() end
        if arg == "on" and (state == "scanning" or state == "paused" or state == "waiting") then   -- a scan is running
            show(); paint()
            frame.title:SetText("AH Profit: scanning the auction house")
            frame.bar:SetStatusBarColor(0.2, 0.7, 0.2)
            frame.state:SetText(state == "paused" and "paused while you sell" or state == "waiting" and "waiting for the server" or "")
        end
        ns.say("scan progress window " .. arg .. "." .. (arg == "off" and " Scan results still show in chat." or ""))
        return true
    elseif arg == "reset" then
        DB.progressPos = { "CENTER", "CENTER", 0, 0 }
        if frame then place(frame) end
        ns.say("scan progress window moved back to the centre.")
        return true
    end
    return false
end
