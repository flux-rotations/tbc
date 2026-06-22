-- Hunter Melee Weave Coach
-- Read-only traffic-light UI for manual Raptor Strike weaving.

local _G, string, math = _G, string, math
local format = string.format
local math_max = math.max
local math_min = math.min
local math_sin = math.sin
local math_abs = math.abs

local A = _G.Action
if not A then return end
if A.PlayerClass ~= "HUNTER" then return end

local NS = _G.FluxAIO
if not NS then
    print("|cFFFF0000[Flux AIO Hunter Weave]|r Core module not loaded!")
    return
end

local HA               = NS.A
local Player           = NS.Player
local Unit             = NS.Unit
local CreateFrame      = _G.CreateFrame
local UIParent         = _G.UIParent
local GetTime          = _G.GetTime
local GetSpellInfo     = _G.GetSpellInfo
local UnitGUID         = _G.UnitGUID
local UnitRangedDamage = _G.UnitRangedDamage
local CombatLogGetCurrentEventInfo = _G.CombatLogGetCurrentEventInfo
local GetNetStats      = _G.GetNetStats
local Listener         = A.Listener

local BACKDROP = {
    bgFile   = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
}

local RAPTOR_NAME = GetSpellInfo and GetSpellInfo(2973) or "Raptor Strike"

local THEME = {
    panel    = { 0.059, 0.059, 0.075, 1 },
    text     = { 0.90, 0.90, 0.94, 1 },
    dim      = { 0.58, 0.58, 0.66, 1 },
    gray     = { 0.30, 0.32, 0.36, 1 },
    green    = { 0.10, 0.78, 0.28, 1 },
    yellow   = { 0.95, 0.82, 0.18, 1 },
    orange   = { 1.00, 0.55, 0.12, 1 },
    red      = { 1.00, 0.18, 0.18, 1 },
}

local STATES = {
    GRAY   = { color = THEME.gray },
    GREEN  = { color = THEME.green },
    ORANGE = { color = THEME.orange },
    RED    = { color = THEME.red },
}

-- rangeState -> which zone cell (MELEE/IDEAL/FAR) lights up; nil = none lit
local ZONE_OF = {
    MELEE = "MELEE", IDEAL = "IDEAL", FAR = "FAR", RANGED = "FAR",
}
local ZONE_TEXT_ON = { 0.05, 0.05, 0.06, 1 }

local Coach = {
    Frame = nil,
    IsVisible = false,
    State = {},
    LastRaptorPromptAt = nil,
    RaptorPendingUntil = nil,
    RaptorPendingStartedAt = nil,
    LastMeleeRemaining = nil,
}

local function settingSeconds(key, fallbackMs)
    local s = NS.cached_settings or {}
    local v = tonumber(s[key]) or fallbackMs
    return v / 1000
end

local function fmtSeconds(v)
    if not v or v <= 0 then return "0.00s" end
    return format("%.2fs", v)
end

local function cooldownRemaining(spell)
    if not spell or not spell.GetCooldown then return 999 end
    return spell:GetCooldown() or 0
end

local function isReadySoon(spell, unit, lead)
    if not spell then return false end
    if spell.IsReady and spell:IsReady(unit) then return true end
    return cooldownRemaining(spell) <= (lead or 0.15)
end

local function getRangedTiming()
    local adaptive = NS.HunterAdaptive
    if adaptive and adaptive.GetState then
        local st = adaptive.GetState()
        if st and st.rangedSpeed and st.rangedSpeed > 0 and st.rangedWindup and st.rangedWindup > 0 then
            return st.rangedSpeed, st.rangedWindup, st.hasteMult or 1
        end
    end

    local speed = 0
    if UnitRangedDamage then
        speed = select(1, UnitRangedDamage("player")) or 0
    end
    if speed <= 0 then speed = 2.8 end

    local s = NS.cached_settings or {}
    local base = tonumber(s.weapon_speed) or speed
    local haste = base / math_max(0.1, speed)
    return speed, 0.5 / haste, haste
end

local function getMeleeSwingRemaining()
    if not Player then return 0, 0 end

    -- Player:GetSwing(slot) already returns the time REMAINING until the next
    -- swing (Env.SwingDuration = period - elapsed), despite the "duration" name.
    -- The old code did (start + GetSwing) - now, mis-reading it as a full swing
    -- duration; with GetSwing as remaining that evaluates to period - 2*elapsed,
    -- which bottoms out at the swing midpoint. Use the remaining value directly.
    local remaining = Player.GetSwing and Player:GetSwing(1) or 0
    if remaining <= 0 or remaining > 10 then remaining = 0 end

    local period = Player.GetSwingMax and (Player:GetSwingMax(1) or 0) or 0
    if period <= 0 then period = remaining end

    return remaining, period
end

local function getTargetRange(unit)
    if NS.GetRange then
        return NS.GetRange(unit) or 0
    end
    if Unit and Unit(unit) and Unit(unit).GetRange then
        return Unit(unit):GetRange() or 0
    end
    return 0
end

local function getRangeBucket(range, inMelee, atRange, deadzone)
    if inMelee then
        return "melee"
    end
    if deadzone then
        return "deadzone"
    end
    if not range or range <= 0 then
        return "range unknown"
    end
    if range >= 5 and range <= 7 then
        return "ideal 5-7"
    end
    if range > 7 and range <= 10 then
        return "too far 7-10"
    end
    if atRange then
        return "ranged"
    end
    return "far"
end

local function getRangeState(range, inMelee, atRange, deadzone, farRange)
    if inMelee then
        return "MELEE"
    end
    if deadzone then
        return "DEAD"
    end
    if not range or range <= 0 then
        return "UNKNOWN"
    end
    if range >= 5 and range <= 7 then
        return "IDEAL"
    end
    if range > 7 and range <= 10 then
        return "FAR"
    end
    if farRange then
        return "OUT"
    end
    if atRange then
        return "RANGED"
    end
    return "OUT"
end

local function severityColor(severity)
    if severity == "RED" then return THEME.red end
    if severity == "ORANGE" then return THEME.orange end
    if severity == "YELLOW" then return THEME.yellow end
    if severity == "GREEN" then return THEME.green end
    return THEME.gray
end

local function getLastAutoBadge()
    local tracker = NS.HunterClipTracker
    if not tracker or not tracker.GetLastAutoResult then
        return "AUTO --", THEME.gray
    end

    local result = tracker:GetLastAutoResult()
    if not result then
        return "AUTO --", THEME.gray
    end

    local clip = result.clipDuration or 0
    if clip <= 0.001 then
        if result.verdict == "HASTE" then
            return "AUTO HASTE RESET", THEME.gray
        elseif result.verdict == "SYNC" or result.verdict == "RESET" then
            return "AUTO SYNC", THEME.gray
        end
        return "AUTO CLEAN", THEME.green
    end

    return format("CLIP +%.2fs", clip), severityColor(result.severity)
end

local function setTextColor(t, color)
    t:SetTextColor(color[1], color[2], color[3], color[4] or 1)
end

function Coach:MarkRaptorPending(now, meleeRemaining)
    now = now or GetTime()
    local hold = math_max(0.45, math_min(3, (meleeRemaining or 0) + 0.35))
    self.RaptorPendingStartedAt = self.RaptorPendingStartedAt or now
    self.RaptorPendingUntil = now + hold
end

function Coach:ClearRaptorPending()
    self.RaptorPendingUntil = nil
    self.RaptorPendingStartedAt = nil
end

function Coach:IsRaptorPending(now)
    return self.RaptorPendingUntil and self.RaptorPendingUntil > (now or GetTime())
end

function Coach:Evaluate(unit)
    unit = unit or "target"
    local now = GetTime()
    local s = NS.cached_settings or {}

    local targetExists = Unit and Unit(unit):IsExists() or false
    local atRange = targetExists and HA.ArcaneShot and HA.ArcaneShot:IsInRange(unit) or false
    local inMelee = targetExists and HA.WingClip and HA.WingClip:IsInRange(unit) or false
    local targetRange = targetExists and getTargetRange(unit) or 0
    local deadzone = targetExists and (not atRange) and (not inMelee) and (targetRange <= 0 or targetRange <= 8)
    local farRange = targetExists and (not atRange) and (not inMelee) and targetRange > 8
    local rangeBucket = getRangeBucket(targetRange, inMelee, atRange, deadzone)
    local rangeState = getRangeState(targetRange, inMelee, atRange, deadzone, farRange)

    local shootRemaining = Player and Player.GetSwingShoot and (Player:GetSwingShoot() or 0) or 0
    local rangedSpeed, rangedWindup, haste = getRangedTiming()
    local exitBuffer = settingSeconds("weave_exit_buffer_ms", 300)
    local roundTrip = settingSeconds("weave_round_trip_ms", 900)
    local rangedDeadline = shootRemaining - rangedWindup - exitBuffer
    local safeWindow = math_max(0, rangedDeadline)
    -- Entry gate uses the window BEFORE exit_buffer. round_trip already covers the
    -- full in+out macro trip, so subtracting exit_buffer here too would double-book
    -- the walk-out. exit_buffer is only the back-out (stuck-in-melee) reserve.
    local entryWindow = math_max(0, shootRemaining - rangedWindup)
    -- round_trip is a fixed, measured macro runtime (step in + step out), so it does
    -- NOT scale with range -- the iCUE weave takes the same time at 5yd or 7yd.
    local requiredWindow = roundTrip
    local warningWindow = requiredWindow * 0.55

    local raptorCD = cooldownRemaining(HA.RaptorStrike)
    local raptorReady = targetExists and isReadySoon(HA.RaptorStrike, unit, 0.15)
    local raptorQueued = HA.RaptorStrike and HA.RaptorStrike.IsSpellCurrent and HA.RaptorStrike:IsSpellCurrent() or false
    local meleeRemaining, meleeDuration = getMeleeSwingRemaining()
    local shooting = Player and Player.IsShooting and Player:IsShooting() or false
    local recentRaptorPrompt = self.LastRaptorPromptAt and (now - self.LastRaptorPromptAt) <= 1.2

    -- Step-in lead = your forward-step travel time + live world latency. STEP IN
    -- only lights when the white swing will tick within this lead, so it lands as
    -- you arrive in melee. swingKnown gates it: if the melee swing clock is not
    -- live at range, fall back to the gap-only GO IN behaviour.
    local swingKnown = meleeRemaining and meleeRemaining > 0
    local worldLatency = 0
    if GetNetStats then
        local _, _, _, w = GetNetStats()
        worldLatency = (tonumber(w) or 0) / 1000
    end
    local stepInLead = settingSeconds("weave_stepin_lead_ms", 150) + worldLatency

    if inMelee and raptorQueued then
        self:MarkRaptorPending(now, meleeRemaining)
    elseif inMelee and recentRaptorPrompt and raptorCD > 0.15 and meleeRemaining > 0.05 then
        self:MarkRaptorPending(now, meleeRemaining)
    elseif self.RaptorPendingUntil and self.RaptorPendingUntil <= now then
        self:ClearRaptorPending()
    end

    local raptorPending = self:IsRaptorPending(now)
    if raptorPending and self.LastMeleeRemaining and meleeRemaining > self.LastMeleeRemaining + 0.35
       and now - (self.RaptorPendingStartedAt or now) > 0.10 then
        self:ClearRaptorPending()
        raptorPending = false
    end

    local state = "GRAY"
    local action = "HOLD RANGE"
    local reason = "No weave window"

    if not s.show_melee_weave_coach then
        reason = "Disabled"
    elseif not targetExists then
        reason = "No target"
    elseif (inMelee or deadzone) and rangedDeadline <= 0 and not raptorPending then
        state = "RED"
        action = "BACK OUT"
        reason = "Ranged Auto deadline"
    elseif deadzone then
        state = "RED"
        action = "MOVE OUT"
        reason = "Deadzone"
    elseif inMelee then
        if raptorPending or raptorQueued then
            state = "ORANGE"
            action = "WAIT HIT"
            reason = "Raptor queued - hold melee"
        elseif raptorReady and safeWindow > 0.05 and (meleeRemaining <= 0 or meleeRemaining <= safeWindow + 0.20) then
            state = "GREEN"
            action = "RAPTOR"
            reason = "Queue Raptor now"
            self.LastRaptorPromptAt = now
        else
            state = "RED"
            action = "BACK OUT"
            if raptorCD > 0.15 then
                reason = "Raptor cooldown - leave melee"
            elseif meleeRemaining > safeWindow then
                reason = "Melee swing too late"
            else
                reason = "Bad melee window"
            end
        end
    elseif farRange then
        state = "GRAY"
        action = "HOLD RANGE"
        reason = "Out of range"
    elseif not shooting then
        state = "GRAY"
        action = "START AUTO"
        reason = "Auto Shot is not active"
    elseif atRange then
        if raptorCD > 0.15 then
            state = "GRAY"
            action = "HOLD RANGE"
            reason = "Raptor cooldown"
        elseif rangeState == "FAR" then
            state = "RED"
            action = "CLOSER"
            reason = "Need 5-7yd"
        elseif entryWindow >= requiredWindow then
            if (not swingKnown) or meleeRemaining <= stepInLead + 0.05 then
                state = "GREEN"
                action = "STEP IN"
                reason = swingKnown and "Swing up - step in" or "Gap open (swing n/a)"
            else
                state = "ORANGE"
                action = "READY"
                reason = "Gap open, swing soon"
            end
        elseif entryWindow >= warningWindow then
            state = "ORANGE"
            action = "READY"
            reason = "Window soon"
        elseif rangedDeadline > 0 then
            state = "GRAY"
            action = "HOLD RANGE"
            reason = "Window too small"
        else
            state = "GRAY"
            action = "HOLD RANGE"
            reason = "Waiting for Auto"
        end
    else
        state = "GRAY"
        action = "HOLD RANGE"
        reason = "Out of range"
    end

    local ringTotal = math_max(0.1, rangedSpeed - rangedWindup - exitBuffer)
    local ringRemaining = math_min(ringTotal, safeWindow)
    local ringLabel = "Ranged deadline"
    if state == "GRAY" and raptorCD > 0.15 and raptorCD < 999 then
        ringTotal = 6
        ringRemaining = math_min(6, raptorCD)
        ringLabel = "Raptor cooldown"
    end

    -- ============================================================
    -- HUD presentation: one fill bar that sweeps out (BUILD) then
    -- retreats back right->left (WINDOW) then bleeds red (TOO LATE),
    -- plus a centered countdown and a flash on GO. The green window
    -- width IS stepInLead, so the in-game lead slider tunes true<->padded.
    -- ============================================================
    local reactFloor = math_max(worldLatency, 0.06)         -- below this you can't arrive in time
    local buildHorizon = math_max(stepInLead * 4, 1.0)      -- how early the orange fill starts climbing
    local barValue, barColor, countText, fire = 0, STATES[state].color, "", false

    if action == "RAPTOR" then
        barValue, barColor, countText, fire = 1, THEME.green, "now", true
    elseif action == "WAIT HIT" then
        local dur = math_max(0.1, meleeDuration or 0.1)
        barValue = swingKnown and math_min(1, meleeRemaining / dur) or 1
        barColor = THEME.orange
        countText = swingKnown and fmtSeconds(meleeRemaining) or "hold"
    elseif action == "BACK OUT" or action == "MOVE OUT" then
        barValue = (ringTotal > 0) and math_max(0, math_min(1, ringRemaining / ringTotal)) or 0
        barColor, countText = THEME.red, "out"
    elseif state == "GREEN" or (state == "ORANGE" and action == "READY") then
        if not swingKnown then
            barValue, barColor, countText, fire = 1, THEME.green, "go", true
            state, action = "GREEN", "STEP IN"
        elseif meleeRemaining > stepInLead then            -- BUILD: orange fill climbs left->right
            local span = math_max(0.01, buildHorizon - stepInLead)
            barValue = 1 - math_min(1, math_max(0, (meleeRemaining - stepInLead) / span))
            barColor, countText = THEME.orange, fmtSeconds(meleeRemaining - stepInLead)
            state, action = "ORANGE", "READY"
        elseif meleeRemaining > reactFloor then            -- WINDOW: green, retreats right->left
            barValue = math_max(0, math_min(1, meleeRemaining / math_max(0.01, stepInLead)))
            barColor, countText, fire = THEME.green, fmtSeconds(meleeRemaining), true
            state, action = "GREEN", "STEP IN"
        else                                                -- TOO LATE: red tail
            barValue = math_max(0, meleeRemaining / reactFloor)
            barColor, countText = THEME.red, "too late"
            state, action = "RED", "TOO LATE"
        end
    elseif raptorCD > 0.15 and raptorCD < 30 then           -- RAPTOR on cooldown: fill toward ready
        local maxCD = 6                                     -- Raptor Strike base cooldown
        barValue = math_max(0, 1 - raptorCD / maxCD)
        barColor, countText = THEME.gray, fmtSeconds(raptorCD)
        if state == "GRAY" then action = "RAPTOR CD" end
    end

    local color = STATES[state].color
    local zoneLabel = ZONE_OF[rangeState]

    self.State = {
        now = now,
        state = state,
        action = action,
        reason = reason,
        color = color,
        targetExists = targetExists,
        atRange = atRange,
        inMelee = inMelee,
        deadzone = deadzone,
        farRange = farRange,
        targetRange = targetRange,
        rangeBucket = rangeBucket,
        rangeState = rangeState,
        shootRemaining = shootRemaining,
        rangedSpeed = rangedSpeed,
        rangedWindup = rangedWindup,
        haste = haste,
        exitBuffer = exitBuffer,
        roundTrip = roundTrip,
        requiredWindow = requiredWindow,
        warningWindow = warningWindow,
        rangedDeadline = rangedDeadline,
        safeWindow = safeWindow,
        raptorCD = raptorCD,
        raptorReady = raptorReady,
        raptorQueued = raptorQueued,
        raptorPending = raptorPending,
        meleeRemaining = meleeRemaining,
        meleeDuration = meleeDuration,
        swingKnown = swingKnown,
        stepInLead = stepInLead,
        ringTotal = ringTotal,
        ringRemaining = ringRemaining,
        ringLabel = ringLabel,
        barValue = barValue,
        barColor = barColor,
        countText = countText,
        fire = fire,
        zoneLabel = zoneLabel,
    }
    self.LastMeleeRemaining = meleeRemaining
    return self.State
end

function Coach:Create()
    if self.Frame then return self.Frame end

    local width = (NS.cached_settings and tonumber(NS.cached_settings.weave_hud_width)) or 550
    local margin = 16

    -- borderless: no outer backdrop, the frame is just an invisible movable hit area
    local f = CreateFrame("Frame", "HunterMeleeWeaveCoachFrame", UIParent)
    f:SetSize(width, 128)
    f:SetPoint("CENTER", UIParent, "CENTER", 270, 0)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("HIGH")
    f:Hide()

    local close = CreateFrame("Button", nil, f)
    close:SetSize(16, 16)
    close:SetPoint("TOPRIGHT", -2, -2)
    close.text = close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    close.text:SetPoint("CENTER")
    close.text:SetText("x")
    setTextColor(close.text, THEME.dim)
    close:SetScript("OnClick", function() f:Hide() end)

    -- zone cells (MELEE / IDEAL / FAR), centered as a group around IDEAL
    local function zoneCell(text)
        local c = CreateFrame("Frame", nil, f, "BackdropTemplate")
        c:SetSize(72, 20)
        c:SetBackdrop(BACKDROP)
        c.t = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        c.t:SetPoint("CENTER")
        c.t:SetText(text)
        return c
    end
    f.zoneIdeal = zoneCell("IDEAL")
    f.zoneIdeal:SetPoint("TOP", f, "TOP", 0, -8)
    f.zoneMelee = zoneCell("MELEE")
    f.zoneMelee:SetPoint("RIGHT", f.zoneIdeal, "LEFT", -5, 0)
    f.zoneFar = zoneCell("FAR")
    f.zoneFar:SetPoint("LEFT", f.zoneIdeal, "RIGHT", 5, 0)
    f.zones = { MELEE = f.zoneMelee, IDEAL = f.zoneIdeal, FAR = f.zoneFar }

    -- big centered action word
    f.action = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.action:SetPoint("TOP", f.zoneIdeal, "BOTTOM", 0, -10)
    f.action:SetScale(1.7)
    f.action:SetText("HOLD")
    setTextColor(f.action, THEME.text)

    -- hero fill bar: anchored to both sides so it stretches with the frame width
    f.bar = CreateFrame("StatusBar", nil, f)
    f.bar:SetPoint("TOP", f.action, "BOTTOM", 0, -12)
    f.bar:SetPoint("LEFT", f, "LEFT", margin, 0)
    f.bar:SetPoint("RIGHT", f, "RIGHT", -margin, 0)
    f.bar:SetHeight(22)
    f.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    f.bar:SetMinMaxValues(0, 1)
    f.bar:SetValue(0)

    f.barBg = f.bar:CreateTexture(nil, "BACKGROUND")
    f.barBg:SetAllPoints(f.bar)
    f.barBg:SetColorTexture(1, 1, 1, 0.06)

    f.count = f.bar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.count:SetPoint("CENTER", f.bar, "CENTER", 0, 0)
    f.count:SetText("")
    setTextColor(f.count, THEME.text)

    -- AUTO CLEAN feedback, centered under the bar
    f.clipText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.clipText:SetPoint("TOP", f.bar, "BOTTOM", 0, -8)
    f.clipText:SetText("AUTO --")
    setTextColor(f.clipText, THEME.dim)

    self.Frame = f
    return f
end

function Coach:Refresh()
    if not self.Frame or not self.Frame:IsShown() then return end
    if NS.refresh_settings then NS.refresh_settings() end

    local d = self:Evaluate("target")
    local f = self.Frame
    local color = d.color or THEME.gray
    local barColor = d.barColor or color
    local clipText, clipColor = getLastAutoBadge()

    -- live width from the in-game slider; bar restretches automatically
    local width = (NS.cached_settings and tonumber(NS.cached_settings.weave_hud_width)) or 550
    if math_abs(f:GetWidth() - width) > 0.5 then f:SetWidth(width) end

    -- zone cells: light the active one in the state color, dim the rest
    for label, cell in pairs(f.zones) do
        if label == d.zoneLabel then
            cell:SetBackdropColor(color[1], color[2], color[3], 0.95)
            cell:SetBackdropBorderColor(color[1], color[2], color[3], 1)
            setTextColor(cell.t, ZONE_TEXT_ON)
        else
            cell:SetBackdropColor(0.10, 0.11, 0.13, 0.5)
            cell:SetBackdropBorderColor(0, 0, 0, 0)
            setTextColor(cell.t, THEME.dim)
        end
    end

    -- action word (arrows bracket it when it's a GO moment)
    f.action:SetText(d.fire and (">  " .. d.action .. "  <") or d.action)
    setTextColor(f.action, color)

    -- fill bar + flash on GO
    local r, g, b = barColor[1], barColor[2], barColor[3]
    if d.fire then
        local k = 0.25 + 0.25 * math_sin(GetTime() * 9)
        r = r + (1 - r) * k; g = g + (1 - g) * k; b = b + (1 - b) * k
    end
    f.bar:SetValue(d.barValue or 0)
    f.bar:SetStatusBarColor(r, g, b, 1)

    f.count:SetText(d.countText or "")
    f.clipText:SetText(clipText)
    setTextColor(f.clipText, clipColor)
end

function Coach:Show()
    self:Create()
    self.Frame:Show()
    self.IsVisible = true
    self:Refresh()
end

function Coach:Hide()
    if self.Frame then self.Frame:Hide() end
    self.IsVisible = false
end

function Coach:GetState()
    return self.State
end

NS.HunterMeleeWeaveCoach = Coach

local playerGUID = nil
local function OnCLEU()
    if not (NS.cached_settings and NS.cached_settings.show_melee_weave_coach) then return end
    if not CombatLogGetCurrentEventInfo then return end
    local _, subevent, _, sourceGUID, _, _, _, _, _, _, _, spellID, spellName = CombatLogGetCurrentEventInfo()
    if not playerGUID and UnitGUID then playerGUID = UnitGUID("player") end
    if sourceGUID ~= playerGUID then return end

    local now = GetTime()
    if (spellID == 2973 or spellName == RAPTOR_NAME)
       and (subevent == "SPELL_DAMAGE" or subevent == "SPELL_MISSED" or subevent == "SPELL_ABSORBED") then
        Coach:ClearRaptorPending()
    elseif Coach:IsRaptorPending(now) and (subevent == "SWING_DAMAGE" or subevent == "SWING_MISSED")
       and now - (Coach.RaptorPendingStartedAt or now) > 0.10 then
        Coach:ClearRaptorPending()
    end
end

if Listener and Listener.Add then
    Listener:Add("FLUX_HUNTER_WEAVE_CLEU", "COMBAT_LOG_EVENT_UNFILTERED", OnCLEU)
end

local lastToggle = nil
local watch = CreateFrame("Frame")
watch.elapsed = 0
watch:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = self.elapsed + elapsed
    if self.elapsed >= 0.05 then
        self.elapsed = 0
        local show = NS.cached_settings and NS.cached_settings.show_melee_weave_coach or false
        if show ~= lastToggle then
            lastToggle = show
            if show then Coach:Show() else Coach:Hide() end
        end
        if show then Coach:Refresh() end
    end
end)

print("|cFF00FF00[Flux AIO Hunter]|r Melee weave coach loaded")
