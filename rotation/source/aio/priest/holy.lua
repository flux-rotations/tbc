-- Priest Holy Healing Module
-- HealingEngine owns targeting (see healing.lua prediction callback). Each
-- strategy acts on HE's current auto-target, sizes direct heals by REAL HP, and
-- downranks Flash Heal via deficit-based rank selection. No SetTarget anywhere.

local _G = _G
local A = _G.Action

if not A then return end
if A.PlayerClass ~= "PRIEST" then return end

local NS = _G.FluxAIO
if not NS then
    print("|cFFFF0000[Flux AIO Priest Holy]|r Core module not loaded!")
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
local FLASH_HEAL_COEFF = NS.FLASH_HEAL_COEFF
local PRIEST_HEAL_MULT = NS.PRIEST_HEAL_MULT

local PLAYER_UNIT = "player"
local PS = "holy"

-- ============================================================================
-- HOLY STATE (per-frame cache)
-- ============================================================================
local holy_state = {
    target = nil,          -- HE's auto-target entry, or nil when all healthy
    realhp = 100,          -- REAL hp% of the target (heal sizing)
    group_damaged = 0,
    clearcasting = false,
    surge_of_light = false,
    pom_ready = false,
    coh_ready = false,
    conserving = false,    -- mana below floor: ride the efficient instant kit
}

-- Pre-allocated entry (no table creation in combat)
local target_entry = { unit = nil, realhp = 100, deficit = 0, is_tank = false }

local function get_holy_state(context)
    if context._holy_valid then return holy_state end
    context._holy_valid = true

    local m = he_target_member()
    if m then
        target_entry.unit = m.Unit
        target_entry.realhp = m.realHP or 100
        target_entry.deficit = (m.MHP or 0) - (m.realAHP or 0)
        target_entry.is_tank = (m.Role == "TANK")
        holy_state.target = target_entry
        holy_state.realhp = target_entry.realhp
    else
        holy_state.target = nil
        holy_state.realhp = 100
    end

    holy_state.group_damaged = he_count_below(context.settings.holy_aoe_hp or 80)
    holy_state.conserving = context.mana_pct < (context.settings.holy_conserve_pct or 40)
    holy_state.clearcasting = context.has_clearcasting
    holy_state.surge_of_light = context.has_surge_of_light
    holy_state.pom_ready = is_spell_available(A.PrayerOfMending) and A.PrayerOfMending:IsReady(PLAYER_UNIT)
    holy_state.coh_ready = is_spell_available(A.CircleOfHealing) and A.CircleOfHealing:IsReady(PLAYER_UNIT)

    return holy_state
end

-- ============================================================================
-- HOLY STRATEGIES  (priority order)
-- ============================================================================
rotation_registry:register("holy", {

    -- [1] Inner Focus (off-GCD, free next big heal) — before a Greater Heal
    named("InnerFocus", {
        is_gcd_gated = false,
        is_burst = true,
        matches = function(context, state)
            if not context.in_combat then return false end
            if not context.settings.holy_use_inner_focus then return false end
            if context.has_inner_focus then return false end
            if not is_spell_available(A.InnerFocus) then return false end
            if not A.InnerFocus:IsReady(PLAYER_UNIT) then return false end
            if not state.target then return false end
            -- Pop only for a real hit (so the free Greater Heal is worth it)
            return state.realhp < (context.settings.holy_flash_heal_hp or 50)
        end,
        execute = function(icon, context, state)
            return try_cast_fmt(A.InnerFocus, icon, PLAYER_UNIT, "[P15]", "Inner Focus", "(+ Greater Heal)")
        end,
    }),

    -- [2] Racial (off-GCD)
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
                return A.Berserking:Show(icon), "[HOLY] Berserking"
            end
            if is_spell_available(A.ArcaneTorrent) and A.ArcaneTorrent:IsReady(PLAYER_UNIT) then
                return A.ArcaneTorrent:Show(icon), "[HOLY] Arcane Torrent"
            end
            return nil
        end,
    }),

    -- [3] PW:S (Holy: emergency band only, gated inside want_shield)
    named("PowerWordShield", {
        matches = function(context, state)
            if not state.target then return false end
            return want_shield(state.target.unit, state.realhp, state.target.is_tank, PS)
        end,
        execute = function(icon, context, state)
            return heal_auto(A.PowerWordShield, icon, "[P14]", "PW:S",
                "on %s (%.0f%%)", state.target.unit, state.realhp)
        end,
    }),

    -- [4] Emergency Flash Heal (max rank — throughput over efficiency)
    named("EmergencyFlashHeal", {
        matches = function(context, state)
            if context.is_moving then return false end
            if not state.target then return false end
            return state.realhp < (context.settings.holy_emergency_hp or 30)
        end,
        execute = function(icon, context, state)
            return heal_auto(A.FlashHeal, icon, "[P13]", "EMERGENCY FH",
                "on %s (%.0f%%)", state.target.unit, state.realhp)
        end,
    }),

    -- [5] Dispel (Magic / Disease)
    named("Dispel", {
        matches = function(context, state)
            if not state.target then return false end
            state._dispel = want_dispel(state.target.unit, PS)
            return state._dispel ~= nil
        end,
        execute = function(icon, context, state)
            return cast_dispel(state._dispel, state.target.unit, icon, "[P12]")
        end,
    }),

    -- [6] Prayer of Mending (instant, on CD — PRE-PULL capable)
    named("PrayerOfMending", {
        matches = function(context, state)
            if not state.pom_ready then return false end
            if not state.target then return false end
            if not context.in_combat and not context.settings.holy_prepull_pom then return false end
            return true
        end,
        execute = function(icon, context, state)
            return heal_auto(A.PrayerOfMending, icon, "[P11]", "Prayer of Mending",
                "on %s (%.0f%%)", state.target.unit, state.realhp)
        end,
    }),

    -- [7] Circle of Healing (instant AoE)
    named("CircleOfHealing", {
        matches = function(context, state)
            if not context.in_combat then return false end
            if not context.settings.holy_use_coh then return false end
            if not state.coh_ready then return false end
            if not state.target then return false end
            return state.group_damaged >= (context.settings.holy_aoe_count or 3)
        end,
        execute = function(icon, context, state)
            return heal_auto(A.CircleOfHealing, icon, "[P10]", "Circle of Healing",
                "on %s (%d hurt)", state.target.unit, state.group_damaged)
        end,
    }),

    -- [8] Free Greater Heal (Inner Focus or Holy Concentration proc — max rank)
    -- TBC holy casts Greater Heal almost only when it's free (logs: 1 GH vs 23
    -- Flash). Paid single-target healing is Flash Heal (strategy below).
    named("FreeGreaterHeal", {
        matches = function(context, state)
            if not context.in_combat then return false end
            if context.is_moving then return false end
            if not state.target then return false end
            if not state.clearcasting and not context.has_inner_focus then return false end
            return state.realhp < 95
        end,
        execute = function(icon, context, state)
            local why = context.has_inner_focus and "Inner Focus" or "Clearcasting"
            return heal_auto(A.GreaterHeal, icon, "[P9]", why .. " GH",
                "on %s (%.0f%%)", state.target.unit, state.realhp)
        end,
    }),

    -- [9] Renew (tank maintenance / injured — weave before non-urgent heals)
    named("Renew", {
        matches = function(context, state)
            if not state.target then return false end
            if state.realhp < (context.settings.holy_flash_heal_hp or 50) then return false end
            return want_renew(state.target.unit, state.realhp, state.target.is_tank, PS)
        end,
        execute = function(icon, context, state)
            return heal_auto(A.Renew, icon, "[P8]", "Renew",
                "on %s (%.0f%%)", state.target.unit, state.realhp)
        end,
    }),

    -- [10] Flash Heal (downranked) — the PRIMARY single-target heal.
    -- Mana healthy: covers the whole band (throughput = best parse).
    -- Conserving: threshold slides down so we stop topping off and ride the
    -- cheap instant kit (Renew/CoH/PoM), reserving Flash for real damage.
    named("FlashHeal", {
        matches = function(context, state)
            if context.is_moving then return false end
            if not state.target then return false end
            local ceiling = state.conserving
                and (context.settings.holy_flash_heal_hp or 50)
                or (context.settings.holy_renew_hp or 90)
            return state.realhp < ceiling
        end,
        execute = function(icon, context, state)
            return cast_ranked(FLASH_HEAL_RANKS, FLASH_HEAL_COEFF, PRIEST_HEAL_MULT,
                state.target.unit, state.target.deficit, icon, "[P7]", "Flash Heal")
        end,
    }),

    -- [12] Binding Heal (self + target both damaged)
    named("BindingHeal", {
        matches = function(context, state)
            if not context.in_combat then return false end
            if context.is_moving then return false end
            if not context.settings.holy_use_binding_heal then return false end
            if context.hp > (context.settings.holy_binding_self_hp or 80) then return false end
            if not state.target then return false end
            return is_spell_available(A.BindingHeal)
        end,
        execute = function(icon, context, state)
            return heal_auto(A.BindingHeal, icon, "[P5]", "Binding Heal",
                "on %s (self %.0f%%)", state.target.unit, context.hp)
        end,
    }),

    -- [13] Prayer of Healing (channeled AoE — heals caster's party)
    named("PrayerOfHealing", {
        matches = function(context, state)
            if not context.in_combat then return false end
            if context.is_moving then return false end
            if not context.settings.holy_use_poh then return false end
            return state.group_damaged >= (context.settings.holy_aoe_count or 3)
        end,
        execute = function(icon, context, state)
            if is_spell_available(A.PrayerOfHealing) and A.PrayerOfHealing:IsReady(PLAYER_UNIT) then
                return try_cast_fmt(A.PrayerOfHealing, icon, PLAYER_UNIT, "[P4]", "Prayer of Healing",
                    "%d hurt", state.group_damaged)
            end
            return nil
        end,
    }),

    -- [14] Surge of Light Smite (free instant proc when nobody needs healing)
    named("SurgeOfLightSmite", {
        matches = function(context, state)
            if not context.in_combat then return false end
            if not state.surge_of_light then return false end
            if not context.has_valid_enemy_target then return false end
            if state.target then return false end
            return true
        end,
        execute = function(icon, context, state)
            return try_cast_fmt(A.Smite, icon, "target", "[P3]", "Surge of Light Smite", "")
        end,
    }),

    -- [15] Idle SW:P (DPS when nobody needs healing)
    named("IdleSWP", {
        matches = function(context, state)
            if not context.in_combat then return false end
            if not context.settings.holy_dps_when_idle then return false end
            if not context.has_valid_enemy_target then return false end
            if state.target then return false end
            if context.mana_pct < (context.settings.holy_dps_mana_floor or 70) then return false end
            if (Unit("target"):HasDeBuffs(Constants.DEBUFF_ID.SHADOW_WORD_PAIN, "player", true) or 0) > 0 then return false end
            return A.ShadowWordPain:IsReady("target")
        end,
        execute = function(icon, context, state)
            return try_cast_fmt(A.ShadowWordPain, icon, "target", "[P2]", "Idle SW:P", "")
        end,
    }),

    -- [16] Idle Holy Fire / Smite (DPS filler)
    named("IdleDamage", {
        matches = function(context, state)
            if not context.in_combat then return false end
            if context.is_moving then return false end
            if not context.settings.holy_dps_when_idle then return false end
            if not context.has_valid_enemy_target then return false end
            if state.target then return false end
            if context.mana_pct < (context.settings.holy_dps_mana_floor or 70) then return false end
            return true
        end,
        execute = function(icon, context, state)
            if is_spell_available(A.HolyFire) and A.HolyFire:IsReady("target")
                and (Unit("target"):HasDeBuffs(Constants.DEBUFF_ID.HOLY_FIRE_DOT, "player", true) or 0) == 0 then
                return try_cast_fmt(A.HolyFire, icon, "target", "[P1]", "Idle Holy Fire", "")
            end
            if A.Smite:IsReady("target") then
                return try_cast_fmt(A.Smite, icon, "target", "[P1]", "Idle Smite", "")
            end
            return nil
        end,
    }),

}, {
    context_builder = get_holy_state,
})

-- ============================================================================
-- MODULE LOADED
-- ============================================================================
print("|cFF00FF00[Flux AIO Priest]|r Holy rotation loaded (HE-driven + downranking)")
