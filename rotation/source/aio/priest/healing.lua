-- Priest Healing Engine glue (Holy + Discipline)
--
-- HealingEngine (HE) OWNS targeting. It sorts every raid/party member by
-- effective HP each ~0.3s and injects [@unit,help] into the rotation macro.
-- We make its target selection smart by registering the same per-unit hook the
-- framework's own GGL profiles use (TMW_ACTION_HEALINGENGINE_UNIT_UPDATE): when
-- a unit needs a dispel / shield / HoT, we lower its sort-HP so HE surfaces it.
-- The rotation then casts the matching spell on whatever HE surfaced, sizing
-- direct heals by real HP deficit and downranking via base-heal rank math.
--
-- Split of responsibility:
--   prediction callback  -> WHO to target (this file)
--   rotation strategies  -> WHAT to cast on HE's target (holy.lua / discipline.lua)
-- The shared want_* predicates below are used by BOTH so they never disagree.

local _G = _G
local A = _G.Action

if not A then return end
if A.PlayerClass ~= "PRIEST" then return end

local NS = _G.FluxAIO
if not NS then
    print("|cFFFF0000[Flux AIO Priest Healing]|r Core module not loaded!")
    return
end

local A = NS.A
local Unit = NS.Unit
local Constants = NS.Constants
local is_spell_available = NS.is_spell_available
local format = string.format
local TMW = _G.TMW
local GetSpellBonusHealing = _G.GetSpellBonusHealing
local IsSpellKnown = _G.IsSpellKnown
local get_spell_mana_cost = NS.get_spell_mana_cost
local Player = NS.Player
local GetToggle = A.GetToggle
local AuraIsValid = A.AuraIsValid
local UnitAffectingCombat = _G.UnitAffectingCombat

local PLAYER_UNIT = "player"
local WEAKENED_SOUL = Constants.DEBUFF_ID.WEAKENED_SOUL

-- ============================================================================
-- PER-UNIT AURA PROBES
-- ============================================================================
local function has_weakened_soul(unit)
    if not unit or not _G.UnitExists(unit) then return true end
    return (Unit(unit):HasDeBuffs(WEAKENED_SOUL) or 0) > 0
end

local function has_renew(unit)
    if not unit or not _G.UnitExists(unit) then return false end
    return (Unit(unit):HasBuffs(A.Renew.ID, "player") or 0) > 0
end

local function has_pws(unit)
    if not unit or not _G.UnitExists(unit) then return false end
    return (Unit(unit):HasBuffs(Constants.BUFF_ID.POWER_WORD_SHIELD, nil, true) or 0) > 0
end

local function in_combat()
    return UnitAffectingCombat(PLAYER_UNIT)
end

-- ============================================================================
-- SHARED NEED PREDICATES
-- Used by the prediction callback (to prioritize a unit for targeting) AND by
-- the rotation (to cast the matching spell on HE's chosen target). Keeping them
-- shared guarantees "who HE targets" and "what we cast" always agree.
-- ps = playstyle string ("holy" | "discipline").
-- ============================================================================

-- Returns "Magic" / "Disease" if we can dispel this unit right now, else nil.
local function want_dispel(unit, ps)
    if not GetToggle(2, ps == "holy" and "holy_use_dispel" or "disc_use_dispel") then return nil end
    if AuraIsValid(unit, "UseDispel", "Magic") and A.DispelMagic:IsReadyByPassCastGCD(unit) then
        return "Magic"
    end
    if AuraIsValid(unit, "UseDispel", "Disease")
        and (Unit(unit):HasBuffs(A.AbolishDisease.ID) or 0) == 0
        and A.AbolishDisease:IsReadyByPassCastGCD(unit) then
        return "Disease"
    end
    return nil
end

-- Should this unit get a fresh PW:S? Holy shields reactively (emergency band);
-- Discipline shields proactively (shield band, or tank pre-pull).
local function want_shield(unit, realhp, is_tank, ps)
    if ps == "discipline" then
        if GetToggle(2, "disc_shield_tank_only") and not is_tank then return false end
        if in_combat() then
            if realhp > (GetToggle(2, "disc_shield_hp") or 90) then return false end
        else
            if not GetToggle(2, "disc_prepull_shield") or not is_tank then return false end
        end
    else
        if not GetToggle(2, "holy_use_pws") then return false end
        if realhp > (GetToggle(2, "holy_pws_hp") or 30) then return false end
    end
    if (Unit(unit):HasDeBuffs(WEAKENED_SOUL) or 0) > 0 then return false end
    if has_pws(unit) then return false end
    return A.PowerWordShield:IsReadyByPassCastGCD(unit)
end

-- Should this unit get a Renew? Tanks are kept HoT-rolling whenever it drops;
-- injured non-tanks get it below the renew band; pre-pull it's tank-only.
-- Never doubles our own existing Renew. (Urgency vs. a direct heal is decided
-- by strategy ordering, not here.)
local function want_renew(unit, realhp, is_tank, ps)
    if has_renew(unit) then return false end
    if not A.Renew:IsReadyByPassCastGCD(unit) then return false end
    if not in_combat() then
        local prepull = (ps == "discipline") and GetToggle(2, "disc_prepull_renew") or GetToggle(2, "holy_prepull_renew")
        return prepull and is_tank
    end
    if is_tank then return realhp < 100 end
    local band = (ps == "discipline") and (GetToggle(2, "disc_renew_hp") or 85) or (GetToggle(2, "holy_renew_hp") or 90)
    return realhp <= band
end

-- ============================================================================
-- HEALINGENGINE READERS
-- ============================================================================

-- The member HE is auto-targeting: SortedUnitIDs[1] (lowest post-prediction HP).
-- Returns nil when nobody needs attention. .HP here is the prediction-adjusted
-- sort value; use .realHP / deficit for heal sizing, never .HP.
local function he_target_member()
    local HE = A.HealingEngine
    if not HE or not HE.GetMembersAll then return nil end
    local members = HE.GetMembersAll()
    local first = members and members[1]
    if not first or (first.HP or 100) >= 100 then return nil end
    return first
end

-- Count of members at/below a raw HP% (HE's own helper, uses realHP).
local function he_count_below(hp)
    local HE = A.HealingEngine
    if not HE or not HE.GetBelowHealthPercentUnits then return 0 end
    return HE.GetBelowHealthPercentUnits(hp) or 0
end

-- ============================================================================
-- PREDICTION CALLBACK  (WHO to target)
-- Mirrors the framework's PerformByProfileHP: for each raid/party member, if it
-- needs a dispel / shield / HoT, lower its sort-HP so HE surfaces it as the
-- auto-target. QueueOrder ensures only one unit per role is bumped per need.
-- ============================================================================
-- Absolute sort-HP ceilings a surfaced unit is pulled down to (min(ceiling, HP),
-- so genuinely wounded units are never raised, and real damage below the ceiling
-- always out-prioritizes maintenance). Tune here if targeting feels too eager.
local CEIL_DISPEL = 40   -- dispels matter, but not over a dying unit
local CEIL_MAINT  = 85   -- shield/HoT maintenance surfaces only when nobody is < 85%

local function prediction(_, thisUnit, db, QueueOrder)
    if not thisUnit or not thisUnit.isPlayer or not thisUnit.Enabled then return end

    local ps = GetToggle(2, "playstyle")
    if ps ~= "holy" and ps ~= "discipline" then return end

    local unit = thisUnit.Unit
    local role = thisUnit.Role
    local realhp = thisUnit.realHP
    local is_tank = (role == "TANK")

    -- Dispel (highest priority)
    if thisUnit.useDispel and not QueueOrder.useDispel[role] and want_dispel(unit, ps) then
        QueueOrder.useDispel[role] = true
        thisUnit:SetupOffsets(0, CEIL_DISPEL)
        return
    end

    -- Shield
    if thisUnit.useShields and (not QueueOrder.useShields[role] or QueueOrder.useShields[role] > realhp)
        and want_shield(unit, realhp, is_tank, ps) then
        QueueOrder.useShields[role] = realhp
        thisUnit:SetupOffsets(0, CEIL_MAINT)
        return
    end

    -- HoT
    if thisUnit.useHoTs and (not QueueOrder.useHoTs[role] or QueueOrder.useHoTs[role] > realhp)
        and want_renew(unit, realhp, is_tank, ps) then
        QueueOrder.useHoTs[role] = realhp
        thisUnit:SetupOffsets(0, CEIL_MAINT)
        return
    end
end

if TMW and TMW.RegisterCallback then
    TMW:RegisterCallback("TMW_ACTION_HEALINGENGINE_UNIT_UPDATE", prediction)
end

-- ============================================================================
-- CAST HELPERS  (all on HE's auto-target — MetaEngine injects [@unit,help])
-- IsReady(unit) is unreliable for party/raid IDs, so casts check "player".
-- ============================================================================

-- Fire a max-rank heal on HE's auto-target.
local function heal_auto(spell, icon, prefix, name, info_fmt, ...)
    if not is_spell_available(spell) then return nil end
    if not spell:IsReady(PLAYER_UNIT) then return nil end
    local result = spell:Show(icon)
    if not result then return nil end
    if info_fmt then
        return result, format("%s %s - " .. info_fmt, prefix, name, ...)
    end
    return result, format("%s %s", prefix, name)
end

-- Downranked heal via explicit base-heal math (the framework's PredictHeal
-- errors on bare isRank objects). Walks the rank table high->low and returns the
-- highest castable rank whose expected heal fits the deficit within 30% overheal,
-- else the most mana-efficient castable rank. rank_table entries are
-- { spell, base_min, base_max }. Casts on HE's auto-target (Show, no SetTarget).
local function select_rank(rank_table, coeff, mult, deficit)
    local bonus = GetSpellBonusHealing() or 0
    local best_spell, best_eff
    for i = 1, #rank_table do
        local e = rank_table[i]
        local spell = e.spell
        if IsSpellKnown(spell.ID) then
            local cost = get_spell_mana_cost(spell)
            if cost == 0 or Player:Mana() >= cost then
                local heal = ((e.base_min + e.base_max) * 0.5 + bonus * coeff) * mult
                if heal <= deficit * 1.3 then
                    return spell
                end
                local eff = (cost > 0) and (heal / cost) or heal
                if not best_spell or eff > best_eff then
                    best_spell, best_eff = spell, eff
                end
            end
        end
    end
    return best_spell
end

local function cast_ranked(rank_table, coeff, mult, unit, deficit, icon, prefix, name)
    if not unit then return nil end
    local spell = select_rank(rank_table, coeff, mult, deficit)
    if not spell then return nil end
    local result = spell:Show(icon)
    if not result then return nil end
    return result, format("%s %s R%s -> %s", prefix, name, tostring(spell.isRank or "?"), unit)
end

-- Dispel HE's target (school from want_dispel).
local function cast_dispel(school, unit, icon, prefix)
    local spell = (school == "Disease") and A.AbolishDisease or A.DispelMagic
    local result = spell:Show(icon)
    if not result then return nil end
    return result, format("%s Dispel %s -> %s", prefix, school, unit)
end

-- ============================================================================
-- EXPORT TO NAMESPACE
-- ============================================================================
NS.has_weakened_soul = has_weakened_soul
NS.has_renew = has_renew
NS.has_pws = has_pws
NS.priest_in_combat = in_combat

NS.want_dispel = want_dispel
NS.want_shield = want_shield
NS.want_renew = want_renew

NS.he_target_member = he_target_member
NS.he_count_below = he_count_below

NS.heal_auto = heal_auto
NS.cast_ranked = cast_ranked
NS.cast_dispel = cast_dispel

print("|cFF00FF00[Flux AIO Priest]|r Healing engine glue loaded (HE-driven + prediction)")
