-- Hunter Rotation Module
-- OOC strategies + full combat rotation for the "ranged" playstyle

local _G, select = _G, select
local format = string.format
local A = _G.Action

if not A then return end
if A.PlayerClass ~= "HUNTER" then return end

local NS = _G.FluxAIO
if not NS then
    print("|cFFFF0000[Flux AIO Hunter Rotation]|r Core module not loaded!")
    return
end

local A = NS.A
local Player = NS.Player
local Unit = NS.Unit
local rotation_registry = NS.rotation_registry
local named = NS.named
local Constants = NS.Constants
local ARCANE_IMMUNE = NS.ARCANE_IMMUNE or (Constants and Constants.ARCANE_IMMUNE) or {}
local Pet = NS.Pet
local AtRange = NS.AtRange
local InMelee = NS.InMelee
local GetRange = NS.GetRange
local CheckImmuneOrDoNotAttack = NS.CheckImmuneOrDoNotAttack
local CheckCCImmune = NS.CheckCCImmune
local ShouldUseWingClip = NS.ShouldUseWingClip
local ShouldUseViperSting = NS.ShouldUseViperSting
local debug_print = NS.debug_print

-- Framework helpers
local CONST = A.Const
local GetGCD = A.GetGCD
local GetCurrentGCD = A.GetCurrentGCD
local GetLatency = A.GetLatency
local BurstIsON = A.BurstIsON
local is_force_active = NS.is_force_active
local IsUnitEnemy = A.IsUnitEnemy
local AuraIsValid = A.AuraIsValid
local MultiUnits = A.MultiUnits

local UnitIsUnit = _G.UnitIsUnit
local UnitExists = _G.UnitExists
local UnitIsDeadOrGhost = _G.UnitIsDeadOrGhost
local UnitGUID = _G.UnitGUID
local GetNumGroupMembers = _G.GetNumGroupMembers
local GetNumPartyMembers = _G.GetNumPartyMembers
local GetNumRaidMembers = _G.GetNumRaidMembers
local GetTime = _G.GetTime

local PLAYER_UNIT = "player"
local TARGET_UNIT = "target"
local next_pet_attack_at = 0
local next_start_attack_at = 0
local next_hunter_trace_at = 0

-- GGL v1 Readiness keybind workaround.
-- Under the v1 framework the engine doesn't recognize the Readiness icon as a
-- bindable rotation action, so the player can't map a key to it. Painting a
-- distinct, known texture (Inv_misc_bag_felclothbag, 133667) on the main-rotation
-- slot [3/4] gives a stable visual the player binds their Readiness key against.
-- The MetaEngine recognizes Readiness natively, so there we show the real action
-- untouched. Gate on the *selected* framework so MetaEngine users are never
-- affected; GetToggle(9,"Framework") returns "v1" or "MetaEngine" (default
-- "MetaEngine") and the check fails safe to the real icon if the toggle is absent.
local READINESS_V1_TEXTURE = 133667
local function ShowReadiness(icon)
    if A.GetToggle(9, "Framework") == "v1" then
        return A:Show(icon, READINESS_V1_TEXTURE)
    end
    return A.Readiness:Show(icon)
end

-- GGL v1 Haste Potion workaround.
-- Same idea as ShowReadiness: under v1 the sender can't bind the raw item icon,
-- so paint texture 176108 -- the texture GGL's v1 "Potion" keybind recognizes --
-- and the player points that Potion bind at their Haste Potion. MetaEngine reads
-- the real item untouched.
local HASTE_POTION_V1_TEXTURE = 176108
local function ShowHastePotion(icon)
    if A.GetToggle(9, "Framework") == "v1" then
        return A:Show(icon, HASTE_POTION_V1_TEXTURE)
    end
    return A.HastePotion:Show(icon)
end

local function BurnPhaseActive()
    return Unit(PLAYER_UNIT):HasBuffs(A.Heroism.ID) > 0
        or Unit(PLAYER_UNIT):HasBuffs(A.Bloodlust.ID) > 0
        or Unit(PLAYER_UNIT):HasBuffs(A.Drums.ID) > 0
end

local function BurstWindowOpen(unit, settings, context)
    local force_burst_on = is_force_active and is_force_active("force_burst")
    local auto_burst = context and NS.should_auto_burst(context)
    local autoSyncCDs = settings.auto_sync_cds

    if force_burst_on or auto_burst == true then return true end

    if not (BurstIsON(unit) or (not BurstIsON(unit) and autoSyncCDs)) then
        return false
    end

    return (autoSyncCDs and BurnPhaseActive()) or not autoSyncCDs
end

local function PetNeedsAttack(unit)
    if not UnitExists or not UnitExists("pet") or UnitIsDeadOrGhost("pet") then return false end
    if UnitExists("pettarget") and UnitIsUnit("pettarget", unit) then return false end

    local now = GetTime()
    if now < next_pet_attack_at then return false end
    next_pet_attack_at = now + 1.0
    return true
end

local function ShouldStartMeleeAttack()
    local now = GetTime()
    if now < next_start_attack_at then return false end
    next_start_attack_at = now + 0.75
    return true
end

local function RaptorQueueReady(unit)
    if not A.RaptorStrike then return false end
    if A.RaptorStrike:IsSpellCurrent() then return false end

    local spell = A.RaptorStrikeQueue or A.RaptorStrike
    if spell.IsReady and spell:IsReady(unit) then return true end
    if spell.GetCooldown then return (spell:GetCooldown() or 999) <= 0.15 end
    return false
end

local function HunterTrace(context, unit, reason, atRange, inMeleeRange)
    local settings = context.settings
    if not (settings and (settings.debug_mode or settings.debug_system) and debug_print) then return end

    local now = GetTime()
    if now < next_hunter_trace_at then return end
    next_hunter_trace_at = now + 0.50

    local raptorReady = A.RaptorStrike and A.RaptorStrike:IsReady(unit)
    local raptorCurrent = A.RaptorStrike and A.RaptorStrike:IsSpellCurrent()
    local petOnUnit = UnitExists and UnitExists("pettarget") and UnitIsUnit("pettarget", unit)
    local playerAggro = UnitExists and UnitExists("targettarget") and UnitIsUnit("targettarget", PLAYER_UNIT)
    local petAggro = UnitExists and UnitExists("targettarget") and UnitIsUnit("targettarget", "pet")
    local targetTargetGUID = UnitGUID and UnitGUID("targettarget") or "none"

    debug_print(format(
        "[HUNTER PATH] %s unit=%s atRange=%s inMelee=%s ctxMelee=%s targetRange=%s shoot=%.3f gcd=%.3f attacking=%s shooting=%s playerAggro=%s petAggro=%s targetTargetGUID=%s petOnUnit=%s raptorReady=%s raptorCurrent=%s",
        reason,
        unit,
        tostring(atRange),
        tostring(inMeleeRange),
        tostring(context.in_melee_range),
        tostring(context.target_range),
        context.shoot_timer or -1,
        context.gcd_remaining or -1,
        tostring(Player:IsAttacking()),
        tostring(Player:IsShooting()),
        tostring(playerAggro),
        tostring(petAggro),
        tostring(targetTargetGUID),
        tostring(petOnUnit),
        tostring(raptorReady),
        tostring(raptorCurrent)
    ))
end

-- ============================================================================
-- THREAT THROTTLE HELPERS
-- ============================================================================
-- Threat-based DPS throttle (opt-in). Pushes DPS to a threat ceiling, then dumps
-- with Feign Death (FD's 30s CD wipes threat, so in steady state it's back up by
-- the time threat rebuilds -> full DPS between Feigns). Only when FD is on cooldown
-- AT the ceiling does it hold to Auto Shot only -- the rare fallback. Threat is
-- read relative to whoever's tanking (party tank OR your pet), so it works
-- solo+pet. TBC 2.4.3 has no native threat API; this only does anything on a
-- server that exposes UnitDetailedThreatSituation / UnitThreatSituation (the same
-- API the Druid Bear rotation already uses). Where it's absent, the feature no-ops.

local function InGroup()
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then return true end
    if GetNumPartyMembers and GetNumPartyMembers() > 0 then return true end
    if GetNumGroupMembers and GetNumGroupMembers() > 0 then return true end
    return false
end

-- Aggro pulls at ~130% of the tank's threat at range but only ~110% in melee.
-- The killer case: sitting at e.g. 115 (safe at range, < 130) and then stepping
-- into melee to weave -> you're instantly past the 110 melee pull -> one-shot.
-- An in-melee-only clamp reacts a frame too late: the pull happens ON the step,
-- before in_melee_range flips. So when Weave-Safe is on we hold threat under the
-- MELEE pull point AT ALL TIMES (range included), dumping before you can ever be
-- caught high on a step-in. Sits ~20 under 110 because the pull actually triggers
-- when you perform a threat action in melee (your Raptor weave) -- a single big
-- Steady plus one stale threat read can overshoot a thinner margin before Feign
-- fires. No-op for conservative settings and for a retail-style scaled API (whose
-- value caps at 100, already range-correct).
-- Default for the "Melee Safety Cap" slider (threat_melee_ceiling); fallback if unloaded.
local MELEE_THREAT_CEILING = 90

-- Min threat (dashboard %) before we bother Feigning ahead of a Readiness cast.
-- Default for the "FD before Readiness Above" slider (threat_fd_readiness_pct).
local FD_READINESS_THREAT_PCT = 30

-- Live threat read vs `unit`, shared by the throttle and the pre-Readiness FD
-- check. Returns (pct, near_pull, have_data):
--   pct       = the threat % the dashboard bar shows (0..~130; 100 if pulled)
--   near_pull = true once we're the primary target (isTanking)
--   have_data = false when the server has no threat API / we're not on the table
-- Read LIVE from _G (never load-captured): the API is server-provided (or could be
-- injected by an addon that loads after us). Mirrors Druid Bear's live read. The
-- detailed API's 3rd return is the threat % vs the tank -- retail caps it at 100
-- (=pull); on THIS server it climbs toward ~130 for ranged before you pull (the
-- dashboard threat bar scales to 130), so thresholds are tuned against that number.
local function ReadThreatPct(unit)
    local detailed = _G.UnitDetailedThreatSituation
    if detailed then
        local isTanking, status, scaledPct = detailed(PLAYER_UNIT, unit)
        if status == nil then return 0, false, false end   -- not on threat table
        return scaledPct or (isTanking and 100) or 0, (isTanking and true or false), true
    end
    -- Degraded: status-only API (0=safe, 1=over tank, 2/3=tanking). No %, so we
    -- only know "at/over the tank" (treat as 100 / near-pull) vs not.
    local simple = _G.UnitThreatSituation
    if simple then
        local status = simple(PLAYER_UNIT, unit)
        if status == nil then return 0, false, false end
        if status >= 1 then return 100, true, true end
        return 0, false, true
    end
    return 0, false, false                                  -- no threat API on this server
end

-- Decide what the threat throttle should do against `unit` this frame:
--   "fd"   -> Feign Death now (it's up): proactive dump above the FD-on-CD floor,
--             OR emergency dump near/at the pull.
--   "hold" -> near/at the pull but FD is down: Auto-Shot-only so we don't pull.
--   nil    -> nothing to do (below the floor, or no threat data) -> full DPS.
--
-- Two thresholds, both read against the same live % the dashboard threat bar
-- shows (see below): threat_fd_cooldown_pct (the main lever -- Feign on cooldown
-- to KEEP threat low) and threat_hold_pct (the backstop -- when FD is down, stop
-- specials before the pull). Weave-Safe caps the backstop to the melee pull point.
local function ThreatAction(context, unit)
    local hold_at = context.settings.threat_hold_pct or 95

    -- Weave-Safe: hold under the melee pull point even at range, so a step-in
    -- can't insta-pull. (Without it, only clamp once we're actually in melee.)
    -- Fail safe -- treat an unloaded setting as weave-safe rather than open.
    local melee_cap = context.settings.threat_melee_ceiling or MELEE_THREAT_CEILING
    local weave_safe = context.settings.threat_weave_safe
    if weave_safe == nil then weave_safe = true end
    if (weave_safe or context.in_melee_range) and hold_at > melee_cap then
        hold_at = melee_cap
    end

    local fd_at = context.settings.threat_fd_cooldown_pct or 60
    if fd_at > hold_at then fd_at = hold_at end        -- keep the floor at/under the backstop

    local pct, near_pull, have_data = ReadThreatPct(unit)
    if not have_data then return nil end               -- no threat API / not on table

    -- No real threat, or below the proactive floor and not near the pull -> run DPS.
    if not near_pull and (pct <= 0 or pct < fd_at) then return nil end

    -- Feign Death readiness (cooldown + per-NPC exclusion list).
    local fd_ready = A.FeignDeath:IsReady(PLAYER_UNIT)
    if fd_ready then
        local npcID = select(6, Unit(unit):InfoGUID())
        if NS.NO_FEIGN and NS.NO_FEIGN[npcID] then fd_ready = false end
    end

    -- Near/at the pull: FD if we can, else hold specials to avoid pulling.
    if near_pull or pct >= hold_at then
        return fd_ready and "fd" or "hold"
    end

    -- Proactive band (>= floor, below the backstop): Feign ON COOLDOWN to keep
    -- threat low. If FD is down here we're still well clear of the pull, so full DPS.
    return fd_ready and "fd" or nil
end

-- "Feign Death before Readiness": Readiness resets ALL hunter cooldowns, so if we
-- Feign the frame BEFORE Readiness, the FD is free (Readiness hands it right back)
-- and it wipes our threat to ~0 -- so the post-Readiness burst climbs from a clean
-- slate. Only worth it when we already hold real threat (> FD_READINESS_THREAT_PCT)
-- and FD is actually up. True => show FD this frame instead of Readiness.
local function FDBeforeReadiness(context, unit)
    if not context.settings.fd_before_readiness then return false end
    if not A.FeignDeath:IsReady(PLAYER_UNIT) then return false end     -- FD on CD -> can't pre-cast
    local npcID = select(6, Unit(unit):InfoGUID())
    if NS.NO_FEIGN and NS.NO_FEIGN[npcID] then return false end        -- excluded NPC
    local floor = context.settings.threat_fd_readiness_pct or FD_READINESS_THREAT_PCT
    local pct, _, have_data = ReadThreatPct(unit)
    if not have_data or pct <= floor then return false end
    return true
end

-- Wraps a Readiness cast: Feign Death first when FDBeforeReadiness applies,
-- otherwise show Readiness (honoring the GGL v1 keybind texture). One frame later
-- FD is on cooldown, so this falls through and Readiness proceeds (resetting FD).
local function ShowReadinessStep(icon, context, log)
    if FDBeforeReadiness(context, TARGET_UNIT) then
        return A.FeignDeath:Show(icon), "[THREAT] Feign Death (pre-Readiness)"
    end
    return ShowReadiness(icon), log
end

-- ============================================================================
-- STRATEGIES
-- ============================================================================
local strategies = {}

-- ============================================================================
-- 1. INTERRUPT (highest priority in combat)
-- ============================================================================
strategies[#strategies + 1] = named("Interrupt", {
    requires_combat = true,

    matches = function(context)
        if not context.has_valid_enemy_target then return false end
        local castLeft, _, _, _, notKickAble = Unit(TARGET_UNIT):IsCastingRemains()
        if castLeft <= GetGCD() + GetLatency() then return false end
        return true
    end,

    execute = function(icon, context)
        local castLeft, _, _, _, notKickAble = Unit(TARGET_UNIT):IsCastingRemains()

        if not notKickAble and A.SilencingShot:IsReadyByPassCastGCD(TARGET_UNIT, nil, nil, true) and A.SilencingShot:IsInRange() then
            return A.SilencingShot:Show(icon), "[INT] Silencing Shot"
        end

        if A.ScatterShot:IsReadyByPassCastGCD(TARGET_UNIT, nil, nil, true) and A.ScatterShot:IsInRange() and not CheckCCImmune(TARGET_UNIT) then
            return A.ScatterShot:Show(icon), "[INT] Scatter Shot"
        end

        return nil
    end,
})

-- ============================================================================
-- 2. OOC: ASPECT OF VIPER (mana recovery)
-- ============================================================================
strategies[#strategies + 1] = named("OOC_AspectViper", {
    matches = function(context)
        if not context.settings.aspect_viper then return false end
        if context.is_mounted then return false end
        if Unit(PLAYER_UNIT):HasBuffs(A.AspectoftheViper.ID, true) > 0 then return false end
        local manaViperStart = context.settings.mana_viper_start or 10
        if context.mana_pct >= manaViperStart then return false end
        return A.AspectoftheViper:IsReady(PLAYER_UNIT)
    end,

    execute = function(icon, context)
        return A.AspectoftheViper:Show(icon), "[OOC] Aspect of the Viper"
    end,
})

-- ============================================================================
-- 3. OOC: ASPECT OF CHEETAH (travel)
-- ============================================================================
strategies[#strategies + 1] = named("OOC_AspectCheetah", {
    requires_combat = false,

    matches = function(context)
        if not context.settings.aspect_cheetah then return false end
        if context.is_mounted then return false end
        if context.in_combat then return false end
        if IsUnitEnemy(TARGET_UNIT) then return false end
        if Unit(PLAYER_UNIT):HasBuffs(A.AspectoftheCheetah.ID, true) > 0 then return false end
        -- Don't use cheetah if we should be in viper
        if context.settings.aspect_viper then
            local manaViperEnd = context.settings.mana_viper_end or 30
            if context.mana_pct <= manaViperEnd then return false end
        end
        return A.AspectoftheCheetah:IsReady(PLAYER_UNIT)
    end,

    execute = function(icon, context)
        return A.AspectoftheCheetah:Show(icon), "[OOC] Aspect of the Cheetah"
    end,
})

-- ============================================================================
-- 3b. OOC: TRUESHOT AURA (maintain buff)
-- ============================================================================
strategies[#strategies + 1] = named("OOC_TrueshotAura", {
    matches = function(context)
        if context.is_mounted then return false end
        if (Unit(PLAYER_UNIT):HasBuffs(A.TrueshotAura.ID, true) or 0) > 0 then return false end
        return A.TrueshotAura:IsReady(PLAYER_UNIT)
    end,

    execute = function(icon, context)
        return A.TrueshotAura:Show(icon), "[OOC] Trueshot Aura"
    end,
})

-- ============================================================================
-- 4. OOC: CALL PET
-- ============================================================================
strategies[#strategies + 1] = named("OOC_CallPet", {
    matches = function(context)
        if Pet:IsActive() then return false end
        if UnitIsDeadOrGhost("pet") then return false end
        if not Pet:CanCall() then return false end
        return A.CallPet:IsReady(PLAYER_UNIT)
    end,

    execute = function(icon, context)
        return A.CallPet:Show(icon), "[OOC] Call Pet"
    end,
})

-- ============================================================================
-- 5. OOC: REVIVE PET
-- ============================================================================
strategies[#strategies + 1] = named("OOC_RevivePet", {
    matches = function(context)
        if not (UnitIsDeadOrGhost("pet") or Unit("pet"):IsDead()) then return false end
        return A.RevivePet:IsReady(PLAYER_UNIT)
    end,

    execute = function(icon, context)
        return A.RevivePet:Show(icon), "[OOC] Revive Pet"
    end,
})

-- ============================================================================
-- THREAT THROTTLE (optional: Feign on cooldown to keep threat low; hold near pull)
-- ============================================================================
-- Sits just above the combat rotation: Interrupt still wins, but when threat is
-- being managed this short-circuits CombatRotation (Feign Death, or auto-only if
-- FD is down near the pull). Only the current target's threat is considered (not
-- mouseover); active whenever a pet or group can hold the mob.
strategies[#strategies + 1] = named("ThreatThrottle", {
    requires_combat = true,
    requires_enemy = true,
    setting_key = "threat_throttle_enabled",
    -- Feign Death is off-GCD: evaluate even during the GCD so the threat dump
    -- isn't delayed ~1.5s after a Steady Shot -- exactly the mid-weave moment we
    -- must react in. The auto-only/PoolResource fallbacks are display-only and
    -- don't consume a GCD, so running them off-GCD is harmless.
    is_gcd_gated = false,

    matches = function(context)
        -- Need something else that can hold the mob: a live pet or a group.
        if not (context.pet_active or InGroup()) then return false end
        if not IsUnitEnemy(TARGET_UNIT) then return false end
        return ThreatAction(context, TARGET_UNIT) ~= nil
    end,

    execute = function(icon, context)
        local action = ThreatAction(context, TARGET_UNIT)

        -- Feign Death: proactive dump above the FD-on-cooldown floor (keeps threat
        -- low so you rarely approach the pull), or emergency dump at/over the pull.
        if action == "fd" then
            return A.FeignDeath:Show(icon), "[THREAT] Feign Death"
        end

        -- action == "hold": near/at the pull but FD is down -- Auto Shot only until
        -- FD returns or threat drops, so we don't pull.
        if not Player:IsShooting() then
            return A:Show(icon, CONST.AUTOSHOOT), "[THREAT] Auto Shot only (FD down)"
        end
        return A.PoolResource:Show(icon), "[THREAT] Holding specials (FD down)"
    end,
})

-- ============================================================================
-- 6. COMBAT ROTATION (the full EnemyRotation as one strategy)
-- ============================================================================
strategies[#strategies + 1] = named("CombatRotation", {
    matches = function(context)
        -- Need either a mouseover enemy or target enemy
        if context.settings.mouseover and IsUnitEnemy("mouseover") then return true end
        if IsUnitEnemy(TARGET_UNIT) then return true end
        return false
    end,

    execute = function(icon, context)
        local s = context.settings
        local CT = NS.HunterClipTracker

        -- Internal EnemyRotation for a given unit
        local function EnemyRotation(unit)
            local npcID = select(6, Unit(unit):InfoGUID())
            local atRange = AtRange(unit)
            local inMeleeRange = InMelee(unit)
            local targetRange = context.target_range or math.huge
            local shouldMeleeRecover = (not atRange) and (inMeleeRange == true or targetRange <= 5)
            local weave = nil

            -- [R-1] Stop attacking if target is immune
            if CheckImmuneOrDoNotAttack(unit) then
                return A.PoolResource:Show(icon)
            end

            -- TTD gate for burst CDs (cd_min_ttd setting)
            local min_ttd = s.cd_min_ttd or 0
            local ttd_ok = min_ttd == 0 or not context.ttd or context.ttd <= 0 or context.ttd >= min_ttd

            -- [R-2] Tranquilizing Shot (enrage dispel) — Flux by-ID list (enrages
            -- are self-buffs on the creature) OR the framework's "Enrage" category.
            if A.TranquilizingShot:IsReady(unit)
               and ((Unit(unit):HasBuffs(Constants.TRANQ_ENRAGE, nil, true) or 0) > 0
                    or AuraIsValid(unit, nil, "Enrage")) then
                return A.TranquilizingShot:Show(icon), "[RANGED] Tranq Shot"
            end

            -- [R-3] Aspect of the Hawk (in combat)
            if s.aspect_hawk then
                local manaViperEnd = s.mana_viper_end or 30
                local viperOff = (context.mana_pct > manaViperEnd and s.aspect_viper) or not s.aspect_viper
                if A.AspectoftheHawk:IsReady(PLAYER_UNIT) and Unit(PLAYER_UNIT):HasBuffs(A.AspectoftheHawk.ID, true) == 0
                   and (context.in_combat or IsUnitEnemy(unit)) and viperOff and not context.is_mounted then
                    return A.AspectoftheHawk:Show(icon), "[RANGED] Aspect of the Hawk"
                end
            end

            -- [R-4] Readiness controller (outside burst)
            if s.use_readiness and A.Readiness:IsReady(PLAYER_UNIT) then
                if s.readiness_rapid_fire and ttd_ok then
                    -- Pair Readiness with the re-cast RF: only fire once the RF buff has
                    -- dropped (see [R-15]) so its GCD lands next to the 2nd RF, not while RF
                    -- is still up. The old gate required RF's CD to be ~full (just cast),
                    -- which can never coincide with the buff being down ~15s later -- so the
                    -- buff gate replaces it: fire whenever RF is still meaningfully on CD.
                    if A.RapidFire:GetCooldown() >= 60
                       and Unit(PLAYER_UNIT):HasBuffs(A.RapidFire.ID, true) == 0 then
                        return ShowReadinessStep(icon, context, "[RANGED] Readiness (Rapid Fire)")
                    end
                end
                if s.readiness_misdirection then
                    if A.Misdirection:GetCooldown() >= 10 then
                        return ShowReadinessStep(icon, context, "[RANGED] Readiness (Misdirection)")
                    end
                end
            end

            -- [R-5] Protect frozen target (auto-switch)
            if s.protect_freeze and Unit("target"):HasDeBuffs(A.FreezingTrapDebuff.ID) > 0 and MultiUnits:GetActiveEnemies() >= 2 then
                return A:Show(icon, CONST.AUTOTARGET)
            end

            -- [R-6] Freezing Trap on adds
            if A.FreezingTrap:IsReady(PLAYER_UNIT) and s.freezing_trap_pve and MultiUnits:GetActiveEnemies() >= 2 and MultiUnits:GetByRangeInCombat(5, 1, 5) >= 1 and not CheckCCImmune(unit) then
                return A.FreezingTrap:Show(icon), "[RANGED] Freezing Trap"
            end

            -- [R-7] Mend Pet
            local mendPetHP = s.mend_pet_hp or 30
            if A.MendPet:IsReady(PLAYER_UNIT) and context.pet_hp < mendPetHP and context.pet_active and Unit("pet"):HasBuffs(A.MendPet.ID, true) == 0 then
                return A.MendPet:Show(icon), "[RANGED] Mend Pet"
            end

            -- [R-8] Hunter's Mark — refresh "mark_refresh" sec before expiry so
            -- the ramping AP bonus isn't lost on drop. 0 = re-apply only once
            -- fully gone. markRemaining is 0 when the mark is absent, so a fresh
            -- cast still passes the <= test. Static Mark only guards re-marking a
            -- *different* target (markRemaining == 0), never the current refresh.
            local markRemaining = Unit(unit):HasDeBuffs(A.HuntersMark.ID, true)
            if A.HuntersMark:IsReady(unit) and markRemaining <= (s.mark_refresh or 0)
               and (markRemaining > 0 or not s.static_mark
                    or Player:GetDeBuffsUnitCount(A.HuntersMark.ID) == 0)
               and Unit(unit):TimeToDie() > 2
               and not ARCANE_IMMUNE[npcID]
               and ((Unit(unit):IsBoss() and s.boss_mark) or not s.boss_mark) then
                return A.HuntersMark:Show(icon), "[RANGED] Hunter's Mark"
            end

            -- [R-9] Experimental pet controller. Do not let pet attack block
            -- melee recovery; if we are in melee, player startattack/Raptor owns it.
            if s.experimental_pet and context.pet_active and not shouldMeleeRecover then
                if PetNeedsAttack(unit) and context.pet_hp > mendPetHP - 20 then
                    HunterTrace(context, unit, "return_petattack", atRange, inMeleeRange)
                    return A.PetAttack:Show(icon), "[RANGED] Pet Attack"
                end
            end

            -- [R-10] Kill Command is off-GCD, so firing it in a cast gap costs nothing:
            -- the clicker presses KC, then the next GCD shot on the following read-cycle
            -- -- both land inside the ~1s gap between casts. The old gate only showed KC
            -- while the GCD was LOCKED, which is exactly when a Steady is mid-cast and KC
            -- can't fire; it stopped painting KC the instant the open GCD (the gap it's
            -- actually castable in) arrived. Fire ASAP when ready and let IsReady gate
            -- castability. KC isn't a GCD shot, so it never enters the auto-shot clip math.
            if not shouldMeleeRecover and ttd_ok and A.KillCommand:IsReady(unit) then
                return A.KillCommand:Show(icon), "[RANGED] Kill Command"
            end

            if shouldMeleeRecover then
                HunterTrace(context, unit, "melee_precheck", atRange, inMeleeRange)
            elseif context.in_melee_range and atRange then
                HunterTrace(context, unit, "ctx_melee_ignored_ranged_ok", atRange, inMeleeRange)
            end

            if s.show_melee_weave_coach and NS.HunterMeleeWeaveCoach then
                weave = NS.HunterMeleeWeaveCoach:Evaluate(unit)
            end

            -- Manual-only Raptor queue window. The main rotation must not
            -- auto-prequeue Raptor from fuzzy close range; use /flux raptor
            -- when intentionally weaving in.
            if is_force_active and is_force_active("force_raptor") and RaptorQueueReady(unit)
                and (inMeleeRange == true or (targetRange > 0 and targetRange <= 7)) then
                -- Manual melee control: if we're truly in melee but the white swing
                -- isn't running yet (WoW Auto Attack/Auto Shot swap off), start it FIRST
                -- so the forced Raptor has a swing to fire on instead of whiffing.
                if s.weave_manual_melee and A.StartAttack and inMeleeRange == true
                   and not Player:IsAttacking() and ShouldStartMeleeAttack() then
                    HunterTrace(context, unit, "return_startattack_manual_force", atRange, inMeleeRange)
                    return A.StartAttack:Show(icon), "[WEAVE] Start Attack (manual force)"
                end
                HunterTrace(context, unit, "return_manual_raptor_queue", atRange, inMeleeRange)
                return (A.RaptorStrikeQueue or A.RaptorStrike):Show(icon), "[WEAVE] Manual Raptor Queue"
            end

            -- ============================================
            -- RANGED ROTATION (at range)
            -- ============================================
            if atRange then
                -- [R-11] Auto Shoot
                if not Player:IsShooting() then
                    HunterTrace(context, unit, "return_autoshoot", atRange, inMeleeRange)
                    return A:Show(icon, CONST.AUTOSHOOT), "[RANGED] Auto Shoot"
                end

                -- [R-12] Intimidation (PvE aggro)
                if A.Intimidation:IsReady(unit) and s.intimidation_pve and UnitIsUnit("targettarget", PLAYER_UNIT) and Unit("target"):IsControlAble("stun") and not CheckCCImmune(unit) then
                    return A.Intimidation:Show(icon), "[RANGED] Intimidation"
                end

                -- [R-13] Concussive Shot (PvE)
                if A.ConcussiveShot:IsReady(unit) and s.concussive_shot_pve and not Unit(unit):IsBoss()
                   and Unit("target"):IsMelee() and UnitIsUnit("targettarget", PLAYER_UNIT)
                   and A.LastPlayerCastName ~= A.Intimidation:Info()
                   and (not A.Intimidation:IsReady(unit) or Unit("pet"):HasBuffs(A.Intimidation.ID) == 0 or not s.intimidation_pve)
                   and Unit(unit):HasDeBuffs(A.WingClip.ID) < GetGCD()
                   and not ARCANE_IMMUNE[npcID] and not CheckCCImmune(unit) then
                    HunterTrace(context, unit, "return_concussive_pve_player_aggro", atRange, inMeleeRange)
                    return A.ConcussiveShot:Show(icon), "[RANGED] Concussive Shot (PvE)"
                end

                -- [R-13b] PvP Concussive Shot
                if A.IsInPvP and A.ConcussiveShot:IsReady(unit) and not CheckCCImmune(unit) and Unit(unit):HasDeBuffs(A.WingClip.ID) < GetGCD() then
                    local range = GetRange(unit)
                    if range > 0 and (range < 10 or range > 25) then
                        if Unit(unit):HasDeBuffs(A.ConcussiveShot.ID, true) < 2 then
                            return A.ConcussiveShot:Show(icon), "[RANGED] Concussive Shot (PvP)"
                        end
                    end
                end

                -- [R-14] PvP Viper Sting
                if A.IsInPvP and A.ViperSting:IsReady(unit) then
                    if ShouldUseViperSting(unit) then
                        if Unit(unit):HasDeBuffs(A.ViperSting.ID, true) <= GetGCD() then
                            return A.ViperSting:Show(icon), "[RANGED] Viper Sting (PvP)"
                        end
                    end
                end

                -- [R-15] Burst Cooldowns
                local useAoE = s.aoe
                if BurstWindowOpen(unit, s, context) then
                    if ttd_ok and A.BestialWrath:IsReady(PLAYER_UNIT) and s.use_bestial_wrath and context.pet_active then
                        return A.BestialWrath:Show(icon), "[BURST] Bestial Wrath"
                    end

                    if ttd_ok and A.RapidFire:IsReady(PLAYER_UNIT) and s.use_rapid_fire and Unit(PLAYER_UNIT):HasBuffs(A.RapidFire.ID, true) == 0 then
                        return A.RapidFire:Show(icon), "[BURST] Rapid Fire"
                    end

                    if ttd_ok and A.Readiness:IsReady(PLAYER_UNIT) and s.use_readiness then
                        -- Fire Readiness only once the RF buff has dropped, so it pairs with
                        -- the re-cast Rapid Fire instead of burning its ~1s GCD in the opener.
                        -- RF's buff is 15s and you can't re-RF until it expires, so resetting
                        -- the CD earlier just makes Readiness's GCD delay your haste CDs for
                        -- nothing. Matches the top-parse pattern: RF -> ~15s -> Readiness -> RF.
                        if s.readiness_rapid_fire then
                            if A.RapidFire:GetCooldown() >= 60
                               and Unit(PLAYER_UNIT):HasBuffs(A.RapidFire.ID, true) == 0 then
                                return ShowReadinessStep(icon, context, "[BURST] Readiness (Rapid Fire)")
                            end
                        end
                        if s.readiness_misdirection then
                            if A.Misdirection:GetCooldown() > 30 then
                                return ShowReadinessStep(icon, context, "[BURST] Readiness (Misdirection)")
                            end
                        end
                    end

                    if ttd_ok and A.BloodFury:IsReady(PLAYER_UNIT) and s.use_racial then
                        return A.BloodFury:Show(icon), "[BURST] Blood Fury"
                    end

                    if ttd_ok and A.Berserking:IsReady(PLAYER_UNIT) and s.use_racial then
                        return A.Berserking:Show(icon), "[BURST] Berserking"
                    end

                    if ttd_ok and s.use_haste_potion and A.HastePotion:IsReady(PLAYER_UNIT) then
                        return ShowHastePotion(icon), "[BURST] Haste Potion"
                    end

                    -- Trinkets (legacy Hunter_Goob_opt parity: fire inline on GGL Burst)
                    if ttd_ok and s.trinket1_mode == "offensive" and A.Trinket1 and A.Trinket1:IsReady(PLAYER_UNIT) then
                        return A.Trinket1:Show(icon), "[BURST] Trinket 1"
                    end
                    if ttd_ok and s.trinket2_mode == "offensive" and A.Trinket2 and A.Trinket2:IsReady(PLAYER_UNIT) then
                        return A.Trinket2:Show(icon), "[BURST] Trinket 2"
                    end
                end

                -- [R-16] Moving Arcane Shot
                local useArcane = s.use_arcane
                local arcaneShotMana = s.arcane_shot_mana or 15
                local manaSave = s.mana_save or 30

                if context.is_moving and useArcane and A.ArcaneShot:IsReady(unit) and not ARCANE_IMMUNE[npcID] and context.mana_pct > arcaneShotMana then
                    return A.ArcaneShot:Show(icon), "[RANGED] Arcane Shot (moving)"
                end

                -- [R-17] Shot Weaving
                local ShootTimer = context.shoot_timer

                -- [R-17a] Adaptive DPS Rotation (port of wowsims rotation.go:139-280).
                -- Per-tick DPS-weighted shot choice. Stings get pre-priority.
                -- On shoot/none, no special is cast and auto-shot continues.
                if NS.HunterAdaptive then
                    if s.use_serpent_sting and A.SerpentSting:IsReady(unit)
                       and Unit(unit):HasDeBuffs(A.SerpentSting.ID, true) <= GetGCD()
                       and Unit(unit):TimeToDie() >= 4 and context.mana_pct > manaSave then
                        if CT then CT:RecordSuggestion("Serpent Sting", ShootTimer) end
                        return A.SerpentSting:Show(icon), "[ADAPT] Serpent Sting"
                    end
                    if s.use_scorpid_sting and A.ScorpidSting:IsReady(unit)
                       and Unit(unit):HasDeBuffs(A.ScorpidSting.ID, true) <= GetGCD() + 0.5
                       and Unit(unit):IsBoss() and context.mana_pct > manaSave then
                        if CT then CT:RecordSuggestion("Scorpid Sting", ShootTimer) end
                        return A.ScorpidSting:Show(icon), "[ADAPT] Scorpid Sting"
                    end
                    if s.use_viper_sting_pve and A.ViperSting:IsReady(unit)
                       and Unit(unit):PowerType() == "MANA" and Unit(unit):Power() >= 10
                       and context.mana_pct > manaSave then
                        if CT then CT:RecordSuggestion("Viper Sting", ShootTimer) end
                        return A.ViperSting:Show(icon), "[ADAPT] Viper Sting"
                    end

                    local choice = NS.HunterAdaptive.ChooseAction(unit, {
                        useMulti = useAoE,
                        useArcane = useArcane,
                        arcaneImmune = ARCANE_IMMUNE[npcID],
                        manaPct = context.mana_pct,
                        manaSaveFloor = manaSave,
                        arcaneManaFloor = arcaneShotMana,
                    })
                    local sqw = tonumber(_G.GetCVar and _G.GetCVar("SpellQueueWindow")) or 0
                    local queueWindow = math.max(0.10, math.min(0.40, sqw / 1000))
                    local gcdLeftForQueue = context.gcd_remaining or GetCurrentGCD() or 0
                    local steadyQueueable = (not context.is_moving) and gcdLeftForQueue <= queueWindow
                    if choice == "steady" and (A.SteadyShot:IsReady(unit) or steadyQueueable) then
                        if CT then CT:RecordSuggestion("Steady Shot", ShootTimer) end
                        return A.SteadyShot:Show(icon), "[ADAPT] Steady Shot"
                    elseif choice == "multi" and A.MultiShot:IsReady(unit) and useAoE and context.mana_pct > manaSave then
                        if CT then CT:RecordSuggestion("Multi-Shot", ShootTimer) end
                        return A.MultiShot:Show(icon), "[ADAPT] Multi-Shot"
                    elseif choice == "arcane" and A.ArcaneShot:IsReady(unit)
                           and not ARCANE_IMMUNE[npcID]
                           and context.mana_pct > arcaneShotMana then
                        if CT then CT:RecordSuggestion("Arcane Shot", ShootTimer) end
                        return A.ArcaneShot:Show(icon), "[ADAPT] Arcane Shot"
                    end
                    -- choice == "shoot"/"none" -> no special; auto-shot continues
                end
            end -- end AtRange

            -- Off-GCD fallback after ranged GCD shots had first chance.
            if (atRange or not shouldMeleeRecover) and ttd_ok and A.KillCommand:IsReady(unit) then
                return A.KillCommand:Show(icon), "[RANGED] Kill Command"
            end

            -- ============================================
            -- MELEE ROTATION (in melee range)
            -- ============================================
            if shouldMeleeRecover then
                HunterTrace(context, unit, "melee_branch", atRange, inMeleeRange)

                -- [R-18] Explosive Trap (AoE in melee) -- DISABLED.
                -- Auto-dropping Explosive Trap breaks CC (its ~20s fire DoT keeps
                -- breaking Freezing Trap / sleeps on nearby adds), and it conflicts
                -- with the rotation's own auto Freezing Trap on adds. Queue it manually
                -- via GGL's queue (forces it to the top of the rotation and drops it)
                -- instead of auto-casting here.

                -- [R-18.5] Manual melee control. With WoW's "Auto Attack / Auto Shot"
                -- swap disabled, the melee white swing does NOT auto-engage when you
                -- enter melee, so Raptor (on-next-swing) has nothing to fire on. Start
                -- the swing FIRST -- before any Raptor queue below -- so Raptor lands on
                -- the next pass. Opt-in; off = unchanged upstream behaviour.
                if s.weave_manual_melee and A.StartAttack and not Player:IsAttacking()
                   and ShouldStartMeleeAttack() then
                    HunterTrace(context, unit, "return_startattack_manual", atRange, inMeleeRange)
                    return A.StartAttack:Show(icon), "[MELEE] Start Attack (manual)"
                end

                -- [R-19] Raptor Strike queue for deliberate melee weaving
                if s.show_melee_weave_coach and A.RaptorStrikeQueue and NS.HunterMeleeWeaveCoach then
                    weave = weave or NS.HunterMeleeWeaveCoach:Evaluate(unit)
                    if weave and weave.state == "GREEN" and weave.action == "RAPTOR"
                       and A.RaptorStrikeQueue:IsReady(unit) and not A.RaptorStrike:IsSpellCurrent() then
                        return A.RaptorStrikeQueue:Show(icon), "[WEAVE] Raptor Strike Queue"
                    end
                end

                -- [R-20] Wing Clip
                if ShouldUseWingClip(unit) and A.WingClip:IsReady(unit) and Unit(unit):HasDeBuffs(A.WingClip.ID, true) <= GetGCD()
                   and A.WingClip:AbsentImun(unit, Constants.Temp.TotalAndPhysAndCC) and not CheckCCImmune(unit) then
                    HunterTrace(context, unit, "return_wingclip", atRange, inMeleeRange)
                    return A.WingClip:Show(icon), "[MELEE] Wing Clip"
                end

                -- [R-21] Raptor Strike. In melee recovery, this should be allowed
                -- even if Auto Shot still reports active; Raptor itself is the
                -- important queued action once we are truly in melee range.
                if A.RaptorStrike:IsReady(unit) and not A.RaptorStrike:IsSpellCurrent() then
                    HunterTrace(context, unit, "return_raptor", atRange, inMeleeRange)
                    return A.RaptorStrike:Show(icon), "[MELEE] Raptor Strike"
                end

                -- [R-22] Auto Attack
                if A.StartAttack and not Player:IsAttacking() and not Player:IsShooting()
                    and ShouldStartMeleeAttack() then
                    HunterTrace(context, unit, "return_startattack_melee_fallback", atRange, inMeleeRange)
                    return A.StartAttack:Show(icon), "[MELEE] Start Attack"
                elseif not Player:IsAttacking() and Player:IsShooting() then
                    HunterTrace(context, unit, "skip_startattack_while_shooting", atRange, inMeleeRange)
                end
            end -- end InMelee

            if shouldMeleeRecover or atRange then
                HunterTrace(context, unit, "return_nil", atRange, inMeleeRange)
            end
            return nil
        end -- end EnemyRotation

        -- Check mouseover first, then target
        if s.mouseover and IsUnitEnemy("mouseover") then
            local result, log = EnemyRotation("mouseover")
            if result then return result, log end
        end

        if IsUnitEnemy(TARGET_UNIT) then
            local result, log = EnemyRotation(TARGET_UNIT)
            if result then return result, log end
        end

        return nil
    end,
})

-- ============================================================================
-- REGISTER ALL STRATEGIES
-- ============================================================================
rotation_registry:register("ranged", strategies)

-- ============================================================================
-- MODULE LOADED
-- ============================================================================
print("|cFF00FF00[Flux AIO Hunter]|r Rotation module loaded (" .. #strategies .. " strategies)")
