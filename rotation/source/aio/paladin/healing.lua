-- Paladin Healing Engine glue (Holy)
--
-- HealingEngine (HE) owns targeting: it sorts raid/party by effective HP each
-- ~0.3s and injects [@unit,help] into the rotation macro. Paladin is single-
-- target, so HE's lowest-HP pick is usually exactly who we heal. The one thing
-- that isn't HP-driven is CLEANSE, so we register the framework's per-unit hook
-- (TMW_ACTION_HEALINGENGINE_UNIT_UPDATE) to surface a unit needing a cleanse.
-- The rotation then heals/cleanses HE's target and downranks HL/FoL via
-- deficit-based rank selection. No SetTarget anywhere.

local A_global = _G.Action
if not A_global or A_global.PlayerClass ~= "PALADIN" then return end

local NS = _G.FluxAIO
if not NS then
    print("|cFFFF0000[Flux AIO Paladin Healing]|r Core module not loaded!")
    return
end

local A = NS.A
local Unit = NS.Unit
local Constants = NS.Constants
local is_spell_available = NS.is_spell_available
local HEALING_REDUCTION_DEBUFFS = NS.HEALING_REDUCTION_DEBUFFS or {}
local format = string.format
local TMW = _G.TMW
local GetToggle = A.GetToggle
local AuraIsValid = A.AuraIsValid
local UnitAffectingCombat = _G.UnitAffectingCombat
local GetSpellBonusHealing = _G.GetSpellBonusHealing
local IsSpellKnown = _G.IsSpellKnown
local get_spell_mana_cost = NS.get_spell_mana_cost
local Player = NS.Player

local PLAYER_UNIT = "player"

-- ============================================================================
-- HELPERS
-- ============================================================================
local function in_combat()
    return UnitAffectingCombat(PLAYER_UNIT)
end

-- True if the unit carries a healing-reduction debuff (MS/Wound Poison/etc).
local function has_healing_reduction(unit)
    for i = 1, #HEALING_REDUCTION_DEBUFFS do
        if (Unit(unit):HasDeBuffs(HEALING_REDUCTION_DEBUFFS[i]) or 0) > 0 then
            return true
        end
    end
    return false
end

-- Returns the dispel school ("Poison"/"Disease"/"Magic") we can Cleanse off this
-- unit right now, or nil. Shared by the prediction callback and the rotation.
local function want_cleanse(unit)
    if not GetToggle(2, "holy_use_cleanse") then return nil end
    if not A.Cleanse:IsReadyByPassCastGCD(unit) then return nil end
    if AuraIsValid(unit, "UseDispel", "Magic") then return "Magic" end
    if AuraIsValid(unit, "UseDispel", "Poison") then return "Poison" end
    if AuraIsValid(unit, "UseDispel", "Disease") then return "Disease" end
    return nil
end

-- ============================================================================
-- HEALINGENGINE READERS
-- ============================================================================

-- The member HE is auto-targeting (SortedUnitIDs[1]). nil when nobody needs it.
-- .HP is the prediction-adjusted sort value; use .realHP / deficit for sizing.
local function he_target_member()
    local HE = A.HealingEngine
    if not HE or not HE.GetMembersAll then return nil end
    local members = HE.GetMembersAll()
    local first = members and members[1]
    if not first or (first.HP or 100) >= 100 then return nil end
    return first
end

-- ============================================================================
-- PREDICTION CALLBACK  (WHO to target — cleanse only for paladin)
-- ============================================================================
local CEIL_CLEANSE = 40  -- sort-HP ceiling a cleanse target drops to
local EXCLUDE_HP = 500   -- sort-HP that removes a unit from HE targeting (never < 100)

-- Healing-focus filter: is this unit one of the roles we're assigned to heal?
-- Unset settings default to allow (heal everyone). Tank uses threat detection so
-- it works even when raid roles aren't set. isSelf is checked first.
local function heal_focus_allows(thisUnit)
    if thisUnit.isSelf then return GetToggle(2, "holy_heal_self") ~= false end
    local role = thisUnit.Role
    if role == "TANK" or Unit(thisUnit.Unit):IsTank() then return GetToggle(2, "holy_heal_tanks") ~= false end
    if role == "HEALER" or Unit(thisUnit.Unit):IsHealer() then return GetToggle(2, "holy_heal_healers") ~= false end
    return GetToggle(2, "holy_heal_dps") ~= false
end

local function prediction(_, thisUnit, db, QueueOrder)
    if not thisUnit or not thisUnit.isPlayer or not thisUnit.Enabled then return end
    if GetToggle(2, "playstyle") ~= "holy" then return end

    -- Assignment filter: drop out-of-focus roles from targeting entirely.
    if not heal_focus_allows(thisUnit) then
        thisUnit.HP = EXCLUDE_HP
        return
    end

    local role = thisUnit.Role
    if thisUnit.useDispel and not QueueOrder.useDispel[role] and want_cleanse(thisUnit.Unit) then
        QueueOrder.useDispel[role] = true
        thisUnit:SetupOffsets(0, CEIL_CLEANSE)
    end
end

if TMW and TMW.RegisterCallback then
    TMW:RegisterCallback("TMW_ACTION_HEALINGENGINE_UNIT_UPDATE", prediction)
end

-- ============================================================================
-- CAST HELPERS  (all on HE's auto-target — MetaEngine injects [@unit,help])
-- ============================================================================

-- Max-rank / instant heal on HE's auto-target (Holy Shock, Lay on Hands, ...).
local function heal_auto(spell, icon, log_message)
    if not is_spell_available(spell) then return nil end
    if not spell:IsReady(PLAYER_UNIT) then return nil end
    local result = spell:Show(icon)
    if result then return result, log_message end
    return nil
end

-- Downranked heal via explicit base-heal math (no framework PredictHeal, which
-- errors on bare isRank objects). Walks the rank table high->low and returns the
-- highest castable rank whose expected heal fits the deficit within 30% overheal;
-- otherwise the most mana-efficient castable rank. rank_table entries are
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

local function cast_ranked(rank_table, coeff, mult, unit, deficit, icon, label)
    if not unit then return nil end
    local spell = select_rank(rank_table, coeff, mult, deficit)
    if not spell then return nil end
    local result = spell:Show(icon)
    if not result then return nil end
    return result, format("[HOLY] %s R%s -> %s", label, tostring(spell.isRank or "?"), unit)
end

local function cast_cleanse(unit, icon, school)
    local result = A.Cleanse:Show(icon)
    if not result then return nil end
    return result, format("[HOLY] Cleanse %s -> %s", school, unit)
end

-- ============================================================================
-- EXPORTS
-- ============================================================================
NS.paladin_in_combat = in_combat
NS.has_healing_reduction = has_healing_reduction
NS.want_cleanse = want_cleanse
NS.he_target_member = he_target_member
NS.heal_auto = heal_auto
NS.cast_ranked = cast_ranked
NS.cast_cleanse = cast_cleanse

print("|cFF00FF00[Flux AIO Paladin]|r Healing engine glue loaded (HE-driven + downranking)")
