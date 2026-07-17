-- Priest Discipline Healing Module
-- HealingEngine owns targeting (see healing.lua prediction callback). Each
-- strategy acts on HE's current auto-target, sizes direct heals by REAL HP, and
-- downranks Flash/Greater Heal via deficit-based rank selection. No SetTarget.
-- Discipline is shield-forward: PW:S maintenance runs ahead of direct heals.

local _G = _G
local A = _G.Action

if not A then return end
if A.PlayerClass ~= "PRIEST" then return end

local NS = _G.FluxAIO
if not NS then
    print("|cFFFF0000[Flux AIO Priest Disc]|r Core module not loaded!")
    return
end

local A = NS.A
local Unit = NS.Unit
local rotation_registry = NS.rotation_registry
local Constants = NS.Constants
local is_spell_available = NS.is_spell_available
local try_cast_fmt = NS.try_cast_fmt
local named = NS.named

local he_target_member = NS.he_target_member
local he_count_below = NS.he_count_below
local heal_auto = NS.heal_auto
local cast_ranked = NS.cast_ranked
local cast_dispel = NS.cast_dispel
local want_shield = NS.want_shield
local want_renew = NS.want_renew
local want_dispel = NS.want_dispel
local FLASH_HEAL_RANKS = NS.FLASH_HEAL_RANKS
local GREATER_HEAL_RANKS = NS.GREATER_HEAL_RANKS
local FLASH_HEAL_COEFF = NS.FLASH_HEAL_COEFF
local GREATER_HEAL_COEFF = NS.GREATER_HEAL_COEFF
local PRIEST_HEAL_MULT = NS.PRIEST_HEAL_MULT

local PLAYER_UNIT = "player"
local PS = "discipline"

-- ============================================================================
-- DISCIPLINE STATE (per-frame cache)
-- ============================================================================
local disc_state = {
    target = nil,
    realhp = 100,
    group_damaged = 0,
    pom_ready = false,
    conserving = false,    -- mana below floor: drop hard-cast Greater Heal
}

local target_entry = { unit = nil, realhp = 100, deficit = 0, is_tank = false }

local function get_disc_state(context)
    if context._disc_valid then return disc_state end
    context._disc_valid = true

    local m = he_target_member()
    if m then
        target_entry.unit = m.Unit
        target_entry.realhp = m.realHP or 100
        target_entry.deficit = (m.MHP or 0) - (m.realAHP or 0)
        target_entry.is_tank = (m.Role == "TANK")
        disc_state.target = target_entry
        disc_state.realhp = target_entry.realhp
    else
        disc_state.target = nil
        disc_state.realhp = 100
    end

    disc_state.group_damaged = he_count_below(context.settings.disc_shield_hp or 90)
    disc_state.conserving = context.mana_pct < (context.settings.disc_conserve_pct or 35)
    disc_state.pom_ready = is_spell_available(A.PrayerOfMending) and A.PrayerOfMending:IsReady(PLAYER_UNIT)

    return disc_state
end

-- ============================================================================
-- DISCIPLINE STRATEGIES  (priority order)
-- ============================================================================
rotation_registry:register("discipline", {

    -- [1] Pain Suppression (off-GCD, critical tank)
    named("PainSuppression", {
        is_gcd_gated = false,
        matches = function(context, state)
            if not context.in_combat then return false end
            if not context.settings.disc_use_pain_suppression then return false end
            if not state.target or not state.target.is_tank then return false end
            if state.realhp >= (context.settings.disc_pain_suppression_hp or 20) then return false end
            return is_spell_available(A.PainSuppression) and (A.PainSuppression:GetCooldown() or 0) < 0.5
        end,
        execute = function(icon, context, state)
            return heal_auto(A.PainSuppression, icon, "[P15]", "Pain Suppression",
                "on %s (%.0f%%)", state.target.unit, state.realhp)
        end,
    }),

    -- [2] Inner Focus (off-GCD, free next big heal)
    named("InnerFocus", {
        is_gcd_gated = false,
        is_burst = true,
        matches = function(context, state)
            if not context.in_combat then return false end
            if not context.settings.disc_use_inner_focus then return false end
            if context.has_inner_focus then return false end
            if not state.target then return false end
            if state.realhp >= (context.settings.disc_renew_hp or 85) then return false end
            return is_spell_available(A.InnerFocus) and A.InnerFocus:IsReady(PLAYER_UNIT)
        end,
        execute = function(icon, context, state)
            return try_cast_fmt(A.InnerFocus, icon, PLAYER_UNIT, "[P14]", "Inner Focus", "(+ heal)")
        end,
    }),

    -- [3] Power Infusion (off-GCD, self)
    named("PowerInfusion", {
        is_gcd_gated = false,
        is_burst = true,
        matches = function(context, state)
            if not context.in_combat then return false end
            if not context.settings.disc_use_power_infusion then return false end
            if context.has_power_infusion then return false end
            return is_spell_available(A.PowerInfusion) and (A.PowerInfusion:GetCooldown() or 0) < 0.5
        end,
        execute = function(icon, context, state)
            return try_cast_fmt(A.PowerInfusion, icon, PLAYER_UNIT, "[P13]", "Power Infusion", "(self)")
        end,
    }),

    -- [4] Racial (off-GCD)
    named("Racial", {
        is_gcd_gated = false,
        setting_key = "use_racial",
        matches = function(context, state)
            if not context.in_combat then return false end
            if is_spell_available(A.Berserking) and A.Berserking:IsReady(PLAYER_UNIT) then return true end
            if is_spell_available(A.ArcaneTorrent) and A.ArcaneTorrent:IsReady(PLAYER_UNIT) then return true end
            return false
        end,
        execute = function(icon, context, state)
            if is_spell_available(A.Berserking) and A.Berserking:IsReady(PLAYER_UNIT) then
                return A.Berserking:Show(icon), "[DISC] Berserking"
            end
            if is_spell_available(A.ArcaneTorrent) and A.ArcaneTorrent:IsReady(PLAYER_UNIT) then
                return A.ArcaneTorrent:Show(icon), "[DISC] Arcane Torrent"
            end
            return nil
        end,
    }),

    -- [5] Emergency Flash Heal (max rank)
    named("EmergencyFlashHeal", {
        matches = function(context, state)
            if context.is_moving then return false end
            if not state.target then return false end
            return state.realhp < (context.settings.disc_emergency_hp or 25)
        end,
        execute = function(icon, context, state)
            return heal_auto(A.FlashHeal, icon, "[P12]", "EMERGENCY FH",
                "on %s (%.0f%%)", state.target.unit, state.realhp)
        end,
    }),

    -- [6] Dispel (Magic / Disease)
    named("Dispel", {
        matches = function(context, state)
            if not state.target then return false end
            state._dispel = want_dispel(state.target.unit, PS)
            return state._dispel ~= nil
        end,
        execute = function(icon, context, state)
            return cast_dispel(state._dispel, state.target.unit, icon, "[P11]")
        end,
    }),

    -- [7] Power Word: Shield (shield-forward maintenance / prevention)
    named("PowerWordShield", {
        matches = function(context, state)
            if not state.target then return false end
            return want_shield(state.target.unit, state.realhp, state.target.is_tank, PS)
        end,
        execute = function(icon, context, state)
            return heal_auto(A.PowerWordShield, icon, "[P10]", "PW:S",
                "on %s (%.0f%%)", state.target.unit, state.realhp)
        end,
    }),

    -- [8] Prayer of Mending (instant, on CD)
    named("PrayerOfMending", {
        matches = function(context, state)
            if not context.in_combat then return false end
            if not state.pom_ready then return false end
            return state.target ~= nil
        end,
        execute = function(icon, context, state)
            return heal_auto(A.PrayerOfMending, icon, "[P9]", "Prayer of Mending",
                "on %s (%.0f%%)", state.target.unit, state.realhp)
        end,
    }),

    -- [9] Renew (tank maintenance / injured — weave before non-urgent heals)
    named("Renew", {
        matches = function(context, state)
            if not state.target then return false end
            if state.realhp < (context.settings.disc_flash_heal_hp or 50) then return false end
            return want_renew(state.target.unit, state.realhp, state.target.is_tank, PS)
        end,
        execute = function(icon, context, state)
            return heal_auto(A.Renew, icon, "[P8]", "Renew",
                "on %s (%.0f%%)", state.target.unit, state.realhp)
        end,
    }),

    -- [10] Flash Heal (downranked — urgent, below flash band)
    named("FlashHeal", {
        matches = function(context, state)
            if context.is_moving then return false end
            if not state.target then return false end
            return state.realhp < (context.settings.disc_flash_heal_hp or 50)
        end,
        execute = function(icon, context, state)
            return cast_ranked(FLASH_HEAL_RANKS, FLASH_HEAL_COEFF, PRIEST_HEAL_MULT,
                state.target.unit, state.target.deficit, icon, "[P7]", "Flash Heal")
        end,
    }),

    -- [11] Greater Heal (downranked — sustained, up to renew band).
    -- Dropped while conserving: ride PW:S/Renew/Flash instead of hard-casting.
    named("GreaterHeal", {
        matches = function(context, state)
            if context.is_moving then return false end
            if not state.target then return false end
            if state.conserving then return false end
            return state.realhp < (context.settings.disc_renew_hp or 85)
        end,
        execute = function(icon, context, state)
            return cast_ranked(GREATER_HEAL_RANKS, GREATER_HEAL_COEFF, PRIEST_HEAL_MULT,
                state.target.unit, state.target.deficit, icon, "[P6]", "Greater Heal")
        end,
    }),

    -- [12] Prayer of Healing (group damage)
    named("PrayerOfHealing", {
        matches = function(context, state)
            if not context.in_combat then return false end
            if context.is_moving then return false end
            return state.group_damaged >= (context.settings.disc_aoe_count or 3)
        end,
        execute = function(icon, context, state)
            if is_spell_available(A.PrayerOfHealing) and A.PrayerOfHealing:IsReady(PLAYER_UNIT) then
                return try_cast_fmt(A.PrayerOfHealing, icon, PLAYER_UNIT, "[P5]", "Prayer of Healing",
                    "%d hurt", state.group_damaged)
            end
            return nil
        end,
    }),

}, {
    context_builder = get_disc_state,
})

-- ============================================================================
-- MODULE LOADED
-- ============================================================================
print("|cFF00FF00[Flux AIO Priest]|r Discipline rotation loaded (HE-driven + downranking)")
