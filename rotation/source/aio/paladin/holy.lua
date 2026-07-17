--- Holy Paladin Module
--- HealingEngine owns targeting (see healing.lua prediction callback). We heal
--- HE's auto-target, choose Holy Light vs Flash of Light by situation + mana,
--- and downrank via deficit-based rank selection. No SetTarget anywhere.

local A_global = _G.Action
if not A_global or A_global.PlayerClass ~= "PALADIN" then return end

local NS = _G.FluxAIO
if not NS then
    print("|cFFFF0000[Flux AIO Holy]|r Core module not loaded!")
    return
end

local A = NS.A
local Constants = NS.Constants
local Unit = NS.Unit
local rotation_registry = NS.rotation_registry
local try_cast = NS.try_cast
local named = NS.named
local format = string.format
local PLAYER_UNIT = "player"
local TARGET_UNIT = "target"

local he_target_member = NS.he_target_member
local heal_auto = NS.heal_auto
local cast_ranked = NS.cast_ranked
local cast_cleanse = NS.cast_cleanse
local want_cleanse = NS.want_cleanse
local has_healing_reduction = NS.has_healing_reduction
local HOLY_LIGHT_RANKS = NS.HOLY_LIGHT_RANKS
local FLASH_OF_LIGHT_RANKS = NS.FLASH_OF_LIGHT_RANKS
local HL_COEFFICIENT = NS.HL_COEFFICIENT
local FOL_COEFFICIENT = NS.FOL_COEFFICIENT
local HEALING_LIGHT_MULT = NS.HEALING_LIGHT_MULT

-- Above this HP, a hit is "light" -> Flash of Light; below -> Holy Light.
local FOL_TOPOFF_HP = 75
-- Divine Favor is worth popping only for a real hit (big crit = big refund).
local DF_POP_HP = 75

-- Cancel-cast plumbing
local ACTION_CONST_STOPCAST = _G.ACTION_CONST_STOPCAST
local UnitExists = _G.UnitExists
local UnitIsDeadOrGhost = _G.UnitIsDeadOrGhost
local HL_NAME = A.HolyLight:Info()      -- localized "Holy Light" (same for all ranks)
local FOL_NAME = A.FlashOfLight:Info()  -- localized "Flash of Light"
-- Snapshot of HE's target when the CURRENT hard-heal cast began. HE excludes our
-- own in-flight heal from its prediction (GetOthersHealAmount), so if this moves
-- mid-cast the target genuinely no longer needs us.
local cast_snapshot_unit = nil
local cast_snapshot_guid = nil
local cast_snapshot_start = nil

-- ============================================================================
-- HOLY STATE (context_builder)
-- ============================================================================
local holy_state = {
    target = nil,               -- HE's auto-target entry, or nil when all healthy
    realhp = 100,
    cleanse_school = nil,
    conserving = false,
    divine_favor_active = false,
    divine_illumination_active = false,
    lights_grace_active = false,
    heal_casting = false,       -- currently hard-casting HL/FoL
    cast_left = 0,              -- seconds remaining on that cast
}
local target_entry = { unit = nil, realhp = 100, deficit = 0, is_tank = false, has_healing_reduction = false }

local function get_holy_state(context)
    if context._holy_valid then return holy_state end
    context._holy_valid = true

    holy_state.divine_favor_active = (Unit(PLAYER_UNIT):HasBuffs(Constants.BUFF_ID.DIVINE_FAVOR) or 0) > 0
    holy_state.divine_illumination_active = (Unit(PLAYER_UNIT):HasBuffs(Constants.BUFF_ID.DIVINE_ILLUMINATION) or 0) > 0
    holy_state.lights_grace_active = (Unit(PLAYER_UNIT):HasBuffs(Constants.BUFF_ID.LIGHTS_GRACE) or 0) > 0
    holy_state.conserving = context.mana_pct < (context.settings.holy_conserve_pct or 40)

    -- Track our own hard-heal cast + snapshot HE's target at cast start.
    local castName, castStartTime, castEndTime = Unit(PLAYER_UNIT):IsCasting()
    if castName == HL_NAME or castName == FOL_NAME then
        holy_state.heal_casting = true
        holy_state.cast_left = ((castEndTime or 0) - (_G.TMW.time * 1000)) / 1000
        if castStartTime ~= cast_snapshot_start then
            cast_snapshot_start = castStartTime
            local HE = A.HealingEngine
            if HE and HE.GetTarget then
                cast_snapshot_unit, cast_snapshot_guid = HE.GetTarget()
            else
                cast_snapshot_unit, cast_snapshot_guid = nil, nil
            end
        end
    else
        holy_state.heal_casting = false
        holy_state.cast_left = 0
        cast_snapshot_start = nil
        cast_snapshot_unit = nil
        cast_snapshot_guid = nil
    end

    local m = he_target_member()
    if m then
        target_entry.unit = m.Unit
        target_entry.realhp = m.realHP or 100
        target_entry.deficit = (m.MHP or 0) - (m.realAHP or 0)
        target_entry.is_tank = (m.Role == "TANK")
        target_entry.has_healing_reduction = has_healing_reduction(m.Unit)
        holy_state.target = target_entry
        holy_state.realhp = target_entry.realhp
        holy_state.cleanse_school = want_cleanse(m.Unit)
    else
        holy_state.target = nil
        holy_state.realhp = 100
        holy_state.cleanse_school = nil
    end

    return holy_state
end

-- Pick the heal family for HE's target. Returns (rank_table, coeff, mult, label).
local function choose_ranks(context, state)
    if state.divine_favor_active then return HOLY_LIGHT_RANKS, HL_COEFFICIENT, HEALING_LIGHT_MULT, "HL(DF)" end        -- use the crit on a big heal
    if state.target.has_healing_reduction then return HOLY_LIGHT_RANKS, HL_COEFFICIENT, HEALING_LIGHT_MULT, "HL(MS)" end -- FoL can't keep up under MS
    if state.conserving then return FLASH_OF_LIGHT_RANKS, FOL_COEFFICIENT, HEALING_LIGHT_MULT, "FoL(conserve)" end       -- low mana -> efficient FoL
    if state.realhp >= FOL_TOPOFF_HP then return FLASH_OF_LIGHT_RANKS, FOL_COEFFICIENT, HEALING_LIGHT_MULT, "FoL" end     -- light hit -> FoL
    return HOLY_LIGHT_RANKS, HL_COEFFICIENT, HEALING_LIGHT_MULT, "HL"                                                     -- real hit, mana ok -> HL
end

-- ============================================================================
-- STRATEGIES
-- ============================================================================
do

-- [0] Cancel a wasted hard-heal. HE excludes our own in-flight heal from its
-- prediction, so if HE's target moves off our cast target (or the target died),
-- the heal is no longer needed -> /stopcasting so we re-fire on the right unit.
-- Gated on cast-time-remaining so we never abandon a near-complete cast.
local Holy_StopWastedHeal = {
    is_gcd_gated = false,
    matches = function(context, state)
        if not context.settings.holy_cancel_wasted then return false end
        if not state.heal_casting then return false end
        local min_left = context.settings.holy_cancel_min_left or 0.8
        if state.cast_left < min_left then return false end

        local HE = A.HealingEngine
        local now_unit, now_guid
        if HE and HE.GetTarget then now_unit, now_guid = HE.GetTarget() end

        if not cast_snapshot_guid then
            -- Cast started with no HE target (e.g. Light's Grace weave / idle):
            -- abandon it only if a real heal target has now appeared.
            return now_unit ~= nil
        end
        -- Snapshot target dead -> definitely wasted.
        if cast_snapshot_unit and (not UnitExists(cast_snapshot_unit) or UnitIsDeadOrGhost(cast_snapshot_unit)) then
            return true
        end
        -- HE moved on -> target no longer the priority.
        return now_guid ~= cast_snapshot_guid
    end,
    execute = function(icon, context, state)
        return A:Show(icon, ACTION_CONST_STOPCAST), "[HOLY] Cancel wasted heal"
    end,
}

-- [1] Divine Illumination (off-GCD, -50% mana cost)
local Holy_DivineIllumination = {
    is_gcd_gated = false,
    spell = A.DivineIllumination,
    spell_target = PLAYER_UNIT,
    setting_key = "holy_use_divine_illumination",
    matches = function(context, state)
        if not context.in_combat then return false end
        return context.mana_pct <= (context.settings.holy_divine_illumination_pct or 60)
    end,
    execute = function(icon, context, state)
        return try_cast(A.DivineIllumination, icon, PLAYER_UNIT,
            format("[HOLY] Divine Illumination - Mana: %.0f%%", context.mana_pct))
    end,
}

-- [2] Divine Favor (off-GCD, next heal guaranteed crit -> Illumination refund)
local Holy_DivineFavor = {
    is_gcd_gated = false,
    spell = A.DivineFavor,
    spell_target = PLAYER_UNIT,
    setting_key = "holy_use_divine_favor",
    matches = function(context, state)
        if not state.target then return false end
        -- Pop for a real hit we'll answer with Holy Light (not a FoL top-off / conserve)
        if state.conserving then return false end
        if state.target.has_healing_reduction then return true end
        return state.realhp < DF_POP_HP
    end,
    execute = function(icon, context, state)
        return try_cast(A.DivineFavor, icon, PLAYER_UNIT, "[HOLY] Divine Favor (crit + mana refund)")
    end,
}

-- [3] Racial (off-GCD — Stoneform defensive, Gift of the Naaru heal)
local Holy_Racial = {
    is_gcd_gated = false,
    setting_key = "use_racial",
    matches = function(context, state)
        if A.Stoneform:IsReady(PLAYER_UNIT) then return true end
        if A.GiftOfTheNaaru and state.target and state.realhp < 60 then return true end
        return false
    end,
    execute = function(icon, context, state)
        if A.Stoneform:IsReady(PLAYER_UNIT) then
            return A.Stoneform:Show(icon), "[HOLY] Stoneform"
        end
        if A.GiftOfTheNaaru and state.target and state.realhp < 60 then
            return heal_auto(A.GiftOfTheNaaru, icon,
                format("[HOLY] Gift of the Naaru -> %s (%.0f%%)", state.target.unit, state.realhp))
        end
        return nil
    end,
}

-- [4] Lay on Hands (emergency, full heal)
local Holy_LayOnHands = {
    spell = A.LayOnHands,
    spell_target = PLAYER_UNIT,
    matches = function(context, state)
        if not state.target then return false end
        if state.realhp > 15 then return false end
        if context.forbearance_active then return false end
        return true
    end,
    execute = function(icon, context, state)
        return heal_auto(A.LayOnHands, icon,
            format("[HOLY] Lay on Hands -> %s (%.0f%%)", state.target.unit, state.realhp))
    end,
}

-- [5] Cleanse (HE-surfaced dispel target)
local Holy_Cleanse = {
    spell = A.Cleanse,
    spell_target = PLAYER_UNIT,
    matches = function(context, state)
        return state.target ~= nil and state.cleanse_school ~= nil
    end,
    execute = function(icon, context, state)
        return cast_cleanse(state.target.unit, icon, state.cleanse_school)
    end,
}

-- [7] Heal target (Holy Light vs Flash of Light + downrank + conserve)
local Holy_HealTarget = {
    spell_target = PLAYER_UNIT,
    matches = function(context, state)
        if not state.target then return false end
        if context.is_moving then return false end
        return state.realhp < 95   -- real damage (cleanse-only targets sit near full)
    end,
    execute = function(icon, context, state)
        local ranks, coeff, mult, label = choose_ranks(context, state)
        return cast_ranked(ranks, coeff, mult, state.target.unit, state.target.deficit, icon, label)
    end,
}

-- [8] Judgement maintain (off-GCD, keep JoL/JoW on boss when safe)
local Holy_JudgementMaintain = {
    requires_enemy = true,
    is_gcd_gated = false,
    spell = A.Judgement,
    matches = function(context, state)
        local judge_type = context.settings.holy_judge_debuff or "light"
        if judge_type == "none" then return false end
        if state.target and state.realhp < 60 then return false end  -- don't judge mid-emergency
        if judge_type == "light" and (Unit(TARGET_UNIT):HasDeBuffs(Constants.DEBUFF_ID.JUDGEMENT_LIGHT) or 0) > 0 then return false end
        if judge_type == "wisdom" and (Unit(TARGET_UNIT):HasDeBuffs(Constants.DEBUFF_ID.JUDGEMENT_WISDOM) or 0) > 0 then return false end
        return context.has_any_seal
    end,
    execute = function(icon, context, state)
        local judge_type = context.settings.holy_judge_debuff or "light"
        if judge_type == "light" and not context.seal_light_active then
            if A.SealOfLight:IsReady(PLAYER_UNIT) then return A.SealOfLight:Show(icon), "[HOLY] Seal of Light (for JoL)" end
            return nil
        elseif judge_type == "wisdom" and not context.seal_wisdom_active then
            if A.SealOfWisdom:IsReady(PLAYER_UNIT) then return A.SealOfWisdom:Show(icon), "[HOLY] Seal of Wisdom (for JoW)" end
            return nil
        end
        return try_cast(A.Judgement, icon, TARGET_UNIT, "[HOLY] Judgement (maintain debuff)")
    end,
}

-- [10] Light's Grace weave (self-cast HL R1 to keep the -0.5s HL buff warm).
-- Pure filler: only in a genuine safe window with healthy mana, so the 2.5s
-- throwaway cast never gets caught out or burns mana when it matters.
local Holy_LightsGraceWeave = {
    matches = function(context, state)
        if not context.settings.holy_lights_grace_weave then return false end
        if not context.in_combat then return false end
        if context.is_moving then return false end
        if state.conserving then return false end
        if context.mana_pct < 65 then return false end
        if state.lights_grace_active then return false end
        -- Nothing urgent: HealTarget declined (target near-full or absent)
        if state.target and state.realhp < 95 then return false end
        return _G.IsSpellKnown(635)
    end,
    execute = function(icon, context, state)
        -- HL R1 is a non-max rank; bypass IsReady and Show directly.
        return A.HolyLightR1Self:Show(icon), "[HOLY] Light's Grace weave (HL R1 self)"
    end,
}

-- [9] Seal maintain (keep chosen seal up)
local Holy_SealMaintain = {
    matches = function(context, state)
        local seal = context.settings.holy_seal_choice or "wisdom"
        if seal == "none" then return false end
        if seal == "wisdom" and context.seal_wisdom_active then return false end
        if seal == "light" and context.seal_light_active then return false end
        return true
    end,
    execute = function(icon, context, state)
        local seal = context.settings.holy_seal_choice or "wisdom"
        if seal == "wisdom" and A.SealOfWisdom:IsReady(PLAYER_UNIT) then
            return A.SealOfWisdom:Show(icon), "[HOLY] Seal of Wisdom"
        elseif seal == "light" and A.SealOfLight:IsReady(PLAYER_UNIT) then
            return A.SealOfLight:Show(icon), "[HOLY] Seal of Light"
        end
        return nil
    end,
}

rotation_registry:register("holy", {
    named("StopWastedHeal",     Holy_StopWastedHeal),
    named("DivineIllumination", Holy_DivineIllumination),
    named("DivineFavor",        Holy_DivineFavor),
    named("Racial",             Holy_Racial),
    named("LayOnHands",         Holy_LayOnHands),
    named("Cleanse",            Holy_Cleanse),
    named("HealTarget",         Holy_HealTarget),
    named("JudgementMaintain",  Holy_JudgementMaintain),
    named("SealMaintain",       Holy_SealMaintain),
    named("LightsGraceWeave",   Holy_LightsGraceWeave),
}, {
    context_builder = get_holy_state,
})

end -- scope block

print("|cFF00FF00[Flux AIO Paladin]|r Holy module loaded (HE-driven + downranking)")
