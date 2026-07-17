-- Priest Class Module
-- Defines all Priest spells, constants, helper functions, and registers Priest as a class

local _G, setmetatable, pairs = _G, setmetatable, pairs
local A = _G.Action

if not A then return end
if A.PlayerClass ~= "PRIEST" then return end

local NS = _G.FluxAIO
if not NS then
    print("|cFFFF0000[Flux AIO Priest]|r Core module not loaded!")
    return
end

-- ============================================================================
-- ACTION DEFINITIONS
-- ============================================================================
local Create = A.Create

Action[A.PlayerClass] = {
    -- Racials
    ArcaneTorrent     = Create({ Type = "Spell", ID = 28730, Click = { unit = "player", type = "spell", spell = 28730 } }),
    Berserking        = Create({ Type = "Spell", ID = 26297, Click = { unit = "player", type = "spell", spell = 26297 } }),
    WilloftheForsaken = Create({ Type = "Spell", ID = 7744, Click = { unit = "player", type = "spell", spell = 7744 } }),

    -- Racial Priest Spells
    DesperatePrayer  = Create({ Type = "Spell", ID = 25437, Click = { unit = "player", type = "spell", spell = 25437 } }),
    Starshards       = Create({ Type = "Spell", ID = 25446 }),
    DevouringPlague  = Create({ Type = "Spell", ID = 2944, useMaxRank = true }),

    -- Core Shadow Damage
    ShadowWordPain   = Create({ Type = "Spell", ID = 589, useMaxRank = true }),
    MindBlast        = Create({ Type = "Spell", ID = 8092, useMaxRank = true }),
    MindFlay         = Create({ Type = "Spell", ID = 15407, useMaxRank = true }),
    VampiricTouch    = Create({ Type = "Spell", ID = 34914, useMaxRank = true }),
    ShadowWordDeath  = Create({ Type = "Spell", ID = 32379, useMaxRank = true }),

    -- Shadow Utility
    Shadowform       = Create({ Type = "Spell", ID = 15473, Click = { unit = "player", type = "spell", spell = 15473 } }),
    VampiricEmbrace  = Create({ Type = "Spell", ID = 15286 }),
    Silence          = Create({ Type = "Spell", ID = 15487 }),
    Shadowfiend      = Create({ Type = "Spell", ID = 34433, Click = { unit = "player", type = "spell", spell = 34433 } }),

    -- Holy Damage
    Smite            = Create({ Type = "Spell", ID = 585, useMaxRank = true }),
    HolyFire         = Create({ Type = "Spell", ID = 14914, useMaxRank = true }),
    HolyNova         = Create({ Type = "Spell", ID = 15237, useMaxRank = true }),

    -- Core Healing
    FlashHeal        = Create({ Type = "Spell", ID = 2061, useMaxRank = true }),
    GreaterHeal      = Create({ Type = "Spell", ID = 2060, useMaxRank = true }),
    Renew            = Create({ Type = "Spell", ID = 139, useMaxRank = true }),

    -- Explicit heal ranks for downranking. isRank forces the specific rank; we
    -- pick the rank ourselves via deficit math (see healing.lua select_rank).
    FlashHealR1  = Create({ Type = "Spell", ID = 2061,  isRank = 1 }),
    FlashHealR2  = Create({ Type = "Spell", ID = 9472,  isRank = 2 }),
    FlashHealR3  = Create({ Type = "Spell", ID = 9473,  isRank = 3 }),
    FlashHealR4  = Create({ Type = "Spell", ID = 9474,  isRank = 4 }),
    FlashHealR5  = Create({ Type = "Spell", ID = 10915, isRank = 5 }),
    FlashHealR6  = Create({ Type = "Spell", ID = 10916, isRank = 6 }),
    FlashHealR7  = Create({ Type = "Spell", ID = 10917, isRank = 7 }),
    FlashHealR8  = Create({ Type = "Spell", ID = 25233, isRank = 8 }),
    FlashHealR9  = Create({ Type = "Spell", ID = 25235, isRank = 9 }),

    GreaterHealR1 = Create({ Type = "Spell", ID = 2060,  isRank = 1 }),
    GreaterHealR2 = Create({ Type = "Spell", ID = 10963, isRank = 2 }),
    GreaterHealR3 = Create({ Type = "Spell", ID = 10964, isRank = 3 }),
    GreaterHealR4 = Create({ Type = "Spell", ID = 10965, isRank = 4 }),
    GreaterHealR5 = Create({ Type = "Spell", ID = 25314, isRank = 5 }),
    GreaterHealR6 = Create({ Type = "Spell", ID = 25210, isRank = 6 }),
    GreaterHealR7 = Create({ Type = "Spell", ID = 25213, isRank = 7 }),
    PrayerOfHealing  = Create({ Type = "Spell", ID = 596, useMaxRank = true }),
    PowerWordShield  = Create({ Type = "Spell", ID = 17, useMaxRank = true }),
    PrayerOfMending  = Create({ Type = "Spell", ID = 33076 }),
    CircleOfHealing  = Create({ Type = "Spell", ID = 34861, useMaxRank = true }),
    BindingHeal      = Create({ Type = "Spell", ID = 32546 }),

    -- Wand
    Shoot            = Create({ Type = "Spell", ID = 5019, QueueForbidden = true, BlockForbidden = true, Click = { macrobefore = "/castsequence [exists] !Shoot,!Shoot\n" } }),

    -- Cooldowns
    InnerFocus       = Create({ Type = "Spell", ID = 14751, Click = { unit = "player", type = "spell", spell = 14751 } }),
    PowerInfusion    = Create({ Type = "Spell", ID = 10060, Click = { unit = "player", type = "spell", spell = 10060 } }),
    PainSuppression  = Create({ Type = "Spell", ID = 33206 }),

    -- Defensive & Utility
    Fade             = Create({ Type = "Spell", ID = 586, useMaxRank = true, Click = { unit = "player", type = "spell" } }),
    FearWard         = Create({ Type = "Spell", ID = 6346, Click = { unit = "player", type = "spell", spell = 6346 } }),
    DispelMagic      = Create({ Type = "Spell", ID = 527, useMaxRank = true }),
    AbolishDisease   = Create({ Type = "Spell", ID = 552 }),
    PsychicScream    = Create({ Type = "Spell", ID = 8122, useMaxRank = true }),

    -- Self-Buffs
    InnerFire        = Create({ Type = "Spell", ID = 588, useMaxRank = true, Click = { unit = "player", type = "spell" } }),
    PowerWordFortitude    = Create({ Type = "Spell", ID = 1243, useMaxRank = true, Click = { unit = "player", type = "spell" } }),
    PrayerOfFortitude     = Create({ Type = "Spell", ID = 21562, useMaxRank = true, Click = { unit = "player", type = "spell" } }),
    DivineSpirit          = Create({ Type = "Spell", ID = 14752, useMaxRank = true, Click = { unit = "player", type = "spell" } }),
    PrayerOfSpirit        = Create({ Type = "Spell", ID = 27681, useMaxRank = true, Click = { unit = "player", type = "spell" } }),
    ShadowProtection      = Create({ Type = "Spell", ID = 976, useMaxRank = true, Click = { unit = "player", type = "spell" } }),
    PrayerOfShadowProtection = Create({ Type = "Spell", ID = 27683, useMaxRank = true, Click = { unit = "player", type = "spell" } }),

    -- Items
    SuperManaPotion    = Create({ Type = "Item", ID = 22832, Click = { unit = "player", type = "item", item = 22832 } }),
    SuperHealingPotion = Create({ Type = "Item", ID = 22829, Click = { unit = "player", type = "item", item = 22829 } }),
    MajorHealingPotion = Create({ Type = "Item", ID = 13446, Click = { unit = "player", type = "item", item = 13446 } }),
    DarkRune           = Create({ Type = "Item", ID = 20520, Click = { unit = "player", type = "item", item = 20520 } }),
    DemonicRune        = Create({ Type = "Item", ID = 12662, Click = { unit = "player", type = "item", item = 12662 } }),

    -- Healthstones
    HealthstoneMaster = Create({ Type = "Item", ID = 22105, Click = { unit = "player", type = "item", item = 22105 } }),
    HealthstoneMajor  = Create({ Type = "Item", ID = 22104, Click = { unit = "player", type = "item", item = 22104 } }),

    -- Buff tracking
    Heroism   = Create({ Type = "Spell", ID = 32182 }),
    Bloodlust = Create({ Type = "Spell", ID = 2825 }),
}

-- ============================================================================
-- CLASS-SPECIFIC FRAMEWORK REFERENCES
-- ============================================================================
local A = setmetatable(Action[A.PlayerClass], { __index = Action })
NS.A = A

-- Downranking rank tables (highest -> lowest) with TBC base heal min/max, for
-- explicit deficit-based rank selection (the framework's PredictHeal errors on
-- bare isRank objects, so we do the math ourselves).
NS.FLASH_HEAL_RANKS = {
    { spell = A.FlashHealR9, base_min = 1101, base_max = 1310 },
    { spell = A.FlashHealR8, base_min = 913,  base_max = 1084 },
    { spell = A.FlashHealR7, base_min = 812,  base_max = 968 },
    { spell = A.FlashHealR6, base_min = 644,  base_max = 773 },
    { spell = A.FlashHealR5, base_min = 517,  base_max = 621 },
    { spell = A.FlashHealR4, base_min = 400,  base_max = 482 },
    { spell = A.FlashHealR3, base_min = 329,  base_max = 397 },
    { spell = A.FlashHealR2, base_min = 258,  base_max = 314 },
    { spell = A.FlashHealR1, base_min = 202,  base_max = 247 },
}
NS.GREATER_HEAL_RANKS = {
    { spell = A.GreaterHealR7, base_min = 2314, base_max = 2591 },
    { spell = A.GreaterHealR6, base_min = 1953, base_max = 2181 },
    { spell = A.GreaterHealR5, base_min = 1516, base_max = 1694 },
    { spell = A.GreaterHealR4, base_min = 1470, base_max = 1642 },
    { spell = A.GreaterHealR3, base_min = 1275, base_max = 1428 },
    { spell = A.GreaterHealR2, base_min = 1090, base_max = 1225 },
    { spell = A.GreaterHealR1, base_min = 924,  base_max = 1039 },
}
-- Direct-heal coefficients (castTime / 3.5) and assumed 5/5 Spiritual Healing.
NS.FLASH_HEAL_COEFF = 0.4286
NS.GREATER_HEAL_COEFF = 0.8571
NS.PRIEST_HEAL_MULT = 1.10

local Player = NS.Player
local Unit = NS.Unit
local rotation_registry = NS.rotation_registry

-- Framework helpers
local MultiUnits = A.MultiUnits

-- ============================================================================
-- CONSTANTS
-- ============================================================================
local Constants = {
    BUFF_ID = {
        SHADOWFORM       = 15473,
        INNER_FOCUS      = 14751,
        POWER_INFUSION   = 10060,
        PAIN_SUPPRESSION = 33206,
        INNER_FIRE       = 25431,
        POWER_WORD_SHIELD = 25218,
        FEAR_WARD        = 6346,
        SURGE_OF_LIGHT   = 33151,
        HOLY_CONCENTRATION = 34754,  -- Clearcasting
        INSPIRATION      = 15363,
    },

    DEBUFF_ID = {
        SHADOW_WORD_PAIN = 25368,
        VAMPIRIC_TOUCH   = 34917,
        SHADOW_WEAVING   = 15258,
        VAMPIRIC_EMBRACE = 15290,
        DEVOURING_PLAGUE = 25467,
        HOLY_FIRE_DOT    = 25384,
        WEAKENED_SOUL    = 6788,
    },

    -- Inner Fire buff IDs (all ranks for detection)
    INNER_FIRE_IDS = { 25431, 25432, 10952, 10951, 7128, 602, 1006, 588 },

    -- Fortitude buff IDs (single + group, all ranks)
    FORTITUDE_IDS = { 25389, 25392, 21564, 21562, 10938, 2791, 1245, 1243 },

    -- Divine Spirit buff IDs (single + group, all ranks)
    DIVINE_SPIRIT_IDS = { 25312, 32999, 27681, 14819, 14818, 14752 },

    -- Shadow Protection buff IDs (single + group, all ranks)
    SHADOW_PROT_IDS = { 25433, 39374, 27683, 10958, 976 },
}

NS.Constants = Constants

-- ============================================================================
-- CLASS REGISTRATION
-- ============================================================================
rotation_registry:register_class({
    name = "Priest",
    version = "v1.10.0",
    playstyles = { "shadow", "smite", "holy", "discipline" },
    idle_playstyle_name = nil,

    get_active_playstyle = function(context)
        return context.settings.playstyle or "shadow"
    end,

    get_idle_playstyle = nil,

    playstyle_spells = {
        shadow = {
            { spell = A.ShadowWordPain, name = "Shadow Word: Pain", required = true },
            { spell = A.MindBlast, name = "Mind Blast", required = true },
            { spell = A.MindFlay, name = "Mind Flay", required = false, note = "Shadow talent" },
            { spell = A.VampiricTouch, name = "Vampiric Touch", required = false, note = "41pt Shadow talent" },
            { spell = A.ShadowWordDeath, name = "Shadow Word: Death", required = false },
            { spell = A.Shadowform, name = "Shadowform", required = false, note = "Shadow talent" },
            { spell = A.VampiricEmbrace, name = "Vampiric Embrace", required = false, note = "Shadow talent" },
            { spell = A.Silence, name = "Silence", required = false, note = "Shadow talent" },
            { spell = A.Starshards, name = "Starshards", required = false, note = "Night Elf racial" },
            { spell = A.DevouringPlague, name = "Devouring Plague", required = false, note = "Undead racial" },
        },
        smite = {
            { spell = A.Smite, name = "Smite", required = true },
            { spell = A.ShadowWordPain, name = "Shadow Word: Pain", required = true },
            { spell = A.HolyFire, name = "Holy Fire", required = false },
            { spell = A.MindBlast, name = "Mind Blast", required = false },
            { spell = A.ShadowWordDeath, name = "Shadow Word: Death", required = false },
            { spell = A.Starshards, name = "Starshards", required = false, note = "Night Elf racial" },
            { spell = A.DevouringPlague, name = "Devouring Plague", required = false, note = "Undead racial" },
        },
        holy = {
            { spell = A.FlashHeal, name = "Flash Heal", required = true },
            { spell = A.GreaterHeal, name = "Greater Heal", required = true },
            { spell = A.Renew, name = "Renew", required = true },
            { spell = A.PrayerOfMending, name = "Prayer of Mending", required = false },
            { spell = A.CircleOfHealing, name = "Circle of Healing", required = false, note = "41pt Holy talent" },
            { spell = A.BindingHeal, name = "Binding Heal", required = false },
            { spell = A.PrayerOfHealing, name = "Prayer of Healing", required = false },
            { spell = A.PowerWordShield, name = "Power Word: Shield", required = false },
        },
        discipline = {
            { spell = A.FlashHeal, name = "Flash Heal", required = true },
            { spell = A.GreaterHeal, name = "Greater Heal", required = true },
            { spell = A.PowerWordShield, name = "Power Word: Shield", required = true },
            { spell = A.Renew, name = "Renew", required = true },
            { spell = A.PrayerOfMending, name = "Prayer of Mending", required = false },
            { spell = A.PainSuppression, name = "Pain Suppression", required = false, note = "41pt Disc talent" },
            { spell = A.PowerInfusion, name = "Power Infusion", required = false, note = "Disc talent" },
            { spell = A.InnerFocus, name = "Inner Focus", required = false, note = "Disc talent" },
            { spell = A.PrayerOfHealing, name = "Prayer of Healing", required = false },
        },
    },

    extend_context = function(ctx)
        local moving = Player:IsMoving()
        ctx.is_moving = moving ~= nil and moving ~= false and moving ~= 0
        ctx.is_mounted = Player:IsMounted()
        ctx.combat_time = Unit("player"):CombatTime() or 0
        ctx.in_shadowform = (Unit("player"):HasBuffs(Constants.BUFF_ID.SHADOWFORM) or 0) > 0
        ctx.has_inner_focus = (Unit("player"):HasBuffs(Constants.BUFF_ID.INNER_FOCUS) or 0) > 0
        ctx.has_power_infusion = (Unit("player"):HasBuffs(Constants.BUFF_ID.POWER_INFUSION) or 0) > 0
        ctx.has_surge_of_light = (Unit("player"):HasBuffs(Constants.BUFF_ID.SURGE_OF_LIGHT) or 0) > 0
        ctx.has_clearcasting = (Unit("player"):HasBuffs(Constants.BUFF_ID.HOLY_CONCENTRATION) or 0) > 0
        ctx.has_inner_fire = (Unit("player"):HasBuffs(Constants.INNER_FIRE_IDS) or 0) > 0
        ctx.enemy_count = MultiUnits:GetByRangeInCombat(30)
        ctx.has_valid_enemy_target = ctx.target_exists and ctx.target_enemy

        -- Cache invalidation for per-playstyle builders
        ctx._shadow_valid = false
        ctx._smite_valid = false
        ctx._holy_valid = false
        ctx._disc_valid = false
    end,

    dashboard = {
        resource = { type = "mana", label = "Mana" },
        cooldowns = {
            shadow = { A.Shadowfiend, A.InnerFocus, A.Trinket1, A.Trinket2 },
            smite = { A.InnerFocus, A.Shadowfiend, A.Trinket1, A.Trinket2 },
            holy = { A.InnerFocus, A.Shadowfiend, A.Trinket1, A.Trinket2 },
            discipline = { A.InnerFocus, A.PowerInfusion, A.PainSuppression, A.Shadowfiend, A.Trinket1, A.Trinket2 },
        },
        buffs = {
            shadow = {
                { id = Constants.BUFF_ID.INNER_FOCUS, label = "IF" },
            },
            smite = {
                { id = Constants.BUFF_ID.INNER_FOCUS, label = "IF" },
                { id = Constants.BUFF_ID.SURGE_OF_LIGHT, label = "SoL" },
            },
            holy = {
                { id = Constants.BUFF_ID.INNER_FOCUS, label = "IF" },
                { id = Constants.BUFF_ID.SURGE_OF_LIGHT, label = "SoL" },
            },
            discipline = {
                { id = Constants.BUFF_ID.INNER_FOCUS, label = "IF" },
                { id = Constants.BUFF_ID.POWER_INFUSION, label = "PI" },
            },
        },
        swing_label = "Wand",
        debuffs = {
            shadow = {
                { id = Constants.DEBUFF_ID.SHADOW_WORD_PAIN, label = "SWP", target = true },
                { id = Constants.DEBUFF_ID.VAMPIRIC_TOUCH, label = "VT", target = true },
                { id = Constants.DEBUFF_ID.SHADOW_WEAVING, label = "SW", target = true, show_stacks = true },
            },
            smite = {
                { id = Constants.DEBUFF_ID.HOLY_FIRE_DOT, label = "HF", target = true },
                { id = Constants.DEBUFF_ID.SHADOW_WORD_PAIN, label = "SWP", target = true },
            },
        },
    },
})

-- ============================================================================
-- MODULE LOADED
-- ============================================================================
print("|cFF00FF00[Flux AIO Priest]|r Class module loaded")
