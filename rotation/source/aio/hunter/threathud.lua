-- Hunter Threat HUD
-- Standalone, large, movable threat overlay for the threat throttle. Shows the
-- big scaled threat % (color-coded by how close you are to pulling), a fill bar,
-- and a sub line with raw %, Feign Death cooldown, and the current throttle mode.
-- Separate from the shared dashboard so it can be big and front-and-centre.
-- Toggle: "Standalone Threat HUD" (threat_hud). Drag to move; x to hide.

local _G = _G
local A = _G.Action

if not A then return end
if A.PlayerClass ~= "HUNTER" then return end

local NS = _G.FluxAIO
if not NS then
    print("|cFFFF0000[Flux AIO Hunter Threat HUD]|r Core module not loaded!")
    return
end

local CreateFrame = _G.CreateFrame
local UIParent = _G.UIParent
local GetTime = _G.GetTime
local format = string.format
local math_sin, math_abs = math.sin, math.abs
local InMelee = NS.InMelee

local COLOR = {
    text   = { 0.92, 0.93, 0.96 },
    dim    = { 0.55, 0.57, 0.62 },
    green  = { 0.20, 0.90, 0.20 },
    yellow = { 0.95, 0.85, 0.20 },
    orange = { 1.00, 0.55, 0.10 },
    red    = { 1.00, 0.20, 0.20 },
}
local BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
}

local function setColor(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

-- Color by how close scaled% is to the pull point (100 retail / ~130 raw).
local function threatColor(pct, near_pull)
    if near_pull or pct >= 100 then return COLOR.red end
    if pct >= 80 then return COLOR.orange end
    if pct >= 50 then return COLOR.yellow end
    return COLOR.green
end

local HUD = { Frame = nil }
local hud_ctx = { settings = nil, in_melee_range = false }   -- reused (no per-frame alloc)

function HUD:Create()
    if self.Frame then return self.Frame end

    local f = CreateFrame("Frame", "FluxHunterThreatHUD", UIParent, "BackdropTemplate")
    f:SetSize(260, 112)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 220)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("HIGH")
    f:SetBackdrop(BACKDROP)
    f:SetBackdropColor(0.04, 0.05, 0.07, 0.85)
    f:SetBackdropBorderColor(0, 0, 0, 0.8)
    f:Hide()

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", f, "TOP", 0, -8)
    f.title:SetText("THREAT")
    setColor(f.title, COLOR.dim)

    local close = CreateFrame("Button", nil, f)
    close:SetSize(18, 18)
    close:SetPoint("TOPRIGHT", -3, -3)
    close.t = close:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    close.t:SetPoint("CENTER")
    close.t:SetText("x")
    setColor(close.t, COLOR.dim)
    close:SetScript("OnClick", function() f:Hide() end)

    -- Big scaled-% number (the at-a-glance readout)
    f.big = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.big:SetPoint("TOP", f.title, "BOTTOM", 0, -6)
    f.big:SetScale(2.2)
    f.big:SetText("--")
    setColor(f.big, COLOR.text)

    -- Fill bar (scaled to 130 so a raw-style server fills correctly; red >= 100)
    f.bar = CreateFrame("StatusBar", nil, f)
    f.bar:SetPoint("TOP", f.big, "BOTTOM", 0, -18)
    f.bar:SetPoint("LEFT", f, "LEFT", 14, 0)
    f.bar:SetPoint("RIGHT", f, "RIGHT", -14, 0)
    f.bar:SetHeight(14)
    f.bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    f.bar:SetMinMaxValues(0, 1)
    f.bar:SetValue(0)
    f.barBg = f.bar:CreateTexture(nil, "BACKGROUND")
    f.barBg:SetAllPoints(f.bar)
    f.barBg:SetColorTexture(1, 1, 1, 0.06)

    -- Sub line: raw %, Feign CD, throttle mode
    f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.sub:SetPoint("TOP", f.bar, "BOTTOM", 0, -10)
    f.sub:SetText("")
    setColor(f.sub, COLOR.dim)

    self.Frame = f
    return f
end

function HUD:Refresh()
    local f = self.Frame
    if not f or not f:IsShown() then return end

    local s = NS.cached_settings or {}

    -- Live scale from the slider
    local scale = tonumber(s.threat_hud_scale) or 1.5
    if math_abs((f:GetScale() or 1) - scale) > 0.01 then f:SetScale(scale) end

    local HT = NS.HunterThreat
    if not HT then
        f.big:SetText("n/a"); setColor(f.big, COLOR.dim)
        f.bar:SetValue(0)
        f.sub:SetText("threat module not loaded")
        return
    end

    local pct, near_pull, have_data, raw = HT.Read("target")
    if not have_data then
        f.big:SetText("--"); setColor(f.big, COLOR.dim)
        f.bar:SetValue(0); f.bar:SetStatusBarColor(0.3, 0.3, 0.3, 1)
        f.sub:SetText("no threat / no API")
        return
    end

    local color = threatColor(pct, near_pull)

    -- Big number, flashing red when we've actually pulled
    f.big:SetText(format("%d%%", pct))
    if near_pull then
        local k = 0.30 + 0.30 * math_sin(GetTime() * 8)
        f.big:SetTextColor(1, k, k)
    else
        setColor(f.big, color)
    end

    -- Bar (0..130)
    local capped = pct > 130 and 130 or pct
    f.bar:SetValue(capped / 130)
    f.bar:SetStatusBarColor(color[1], color[2], color[3], 1)

    -- Feign Death status
    local fd_cd = (A.FeignDeath and A.FeignDeath:GetCooldown()) or 0
    local fd_txt = fd_cd <= 0 and "FD ready" or format("FD %.0fs", fd_cd)

    -- Throttle mode (reuse the live decision)
    local mode
    if not s.threat_throttle_enabled then
        mode = "throttle off"
    else
        hud_ctx.settings = s
        hud_ctx.in_melee_range = (InMelee and InMelee("target")) or false
        local action = HT.Action(hud_ctx, "target")
        mode = (action == "fd" and "FEIGN") or (action == "hold" and "AUTO-ONLY") or "full DPS"
    end

    f.sub:SetText(format("raw %d%%  |  %s  |  %s%s", raw, fd_txt, mode, near_pull and "  AGGRO!" or ""))
end

function HUD:Show()
    self:Create()
    self.Frame:Show()
    self:Refresh()
end

function HUD:Hide()
    if self.Frame then self.Frame:Hide() end
end

NS.HunterThreatHUD = HUD

-- Show/hide watcher (throttled), mirrors the weave coach pattern.
local lastToggle = nil
local watch = CreateFrame("Frame")
watch.elapsed = 0
watch:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = self.elapsed + elapsed
    if self.elapsed < 0.05 then return end
    self.elapsed = 0
    local show = (NS.cached_settings and NS.cached_settings.threat_hud) or false
    if show ~= lastToggle then
        lastToggle = show
        if show then HUD:Show() else HUD:Hide() end
    end
    if show then HUD:Refresh() end
end)

print("|cFF00FF00[Flux AIO Hunter]|r Threat HUD module loaded")
