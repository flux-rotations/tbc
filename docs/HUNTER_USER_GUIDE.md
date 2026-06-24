# Flux AIO — Hunter User Guide

> **Status: DRAFT for review.** Hunter-focused: how the rotation plays, the Hunter
> settings worth knowing, the Hunter tools, and the v1 binding + Readiness workaround.

---

## 1. How the Hunter rotation plays

You hold one **Rotation** key; Flux picks the best shot each moment and shows it on the
rotation icon. You drive **movement, targeting, and burst timing** — Flux owns the shot
priority. At a high level it:

- Keeps **Auto Shot** rolling and weaves **Steady Shot** in the gaps (the core of TBC Hunter DPS).
- Uses an **Adaptive engine** to time casts against your Auto Shot clock so Steady/Arcane don't *clip* (delay) your next Auto Shot.
- Layers in **Kill Command**, **stings**, **Multi-Shot** (AoE), **Hunter's Mark**, aspects, pet care, and aggro tools (Concussive / Intimidation / Freezing Trap / Feign Death) as conditions allow.
- Fires burst CDs (**Rapid Fire, Bestial Wrath, Readiness**, racial, trinkets) when you call burst.

Because Adaptive times against *your* weapon, **set your ranged Weapon Speed** (Rotation tab)
to your unbuffed bow/gun/crossbow speed — it's the single most important number for clean DPS.

---

## 2. Hunter settings worth knowing

(Defaults in parentheses — these ship as the profile defaults. Stings are **off** by default;
turn on what your spec uses.)

**Shot priority**
- **Weapon Speed** *(3.0)* — your unbuffed ranged speed. Drives the Adaptive haste math. Set this first.
- **Use Arcane Shot** *(on)*, **Min Mana** *(15%)* — weave Arcane when mana allows.
- **Sting Selection** *(all off)* — Serpent Sting (DoT, top sting), Scorpid Sting (boss only), Viper Sting (PvE mana drain). Listed in priority order.
- **Mana Save %** *(15)* — below this, skip expensive shots (Multi, Arcane, stings); Steady always fires.

**Hunter's Mark**
- **Static Mark** *(on)* — don't re-mark a new target until the mark expires.
- **Boss Only Mark** *(on)*, **Mark Refresh Lead** *(3s)* — re-mark this many seconds before it drops so the ramped AP isn't lost.

**Aspects** (auto-swap)
- **Hawk** *(on, in combat)*, **Cheetah** *(off)*, **Viper** *(on, low mana)* with **Viper On/Off %** thresholds *(on below 10%, off above 30%)*.

**Traps & aggro**
- **Freezing Trap on Adds** *(off)*, **Protect Frozen Target** *(off)*, **Concussive Shot (PvE)** *(on)*, **Intimidation (PvE)** *(on)*, **Feign Death (Threat)** *(off)*, **Wing Clip (Melee)** *(off)*.
- *Explosive Trap auto-cast is disabled* — queue it through GGL when you want it (it would break CC otherwise).

**Cooldowns**
- **Bestial Wrath / Rapid Fire / Readiness / Racial** toggles.
- **Readiness Target** — Reset Rapid Fire *(on)*, Reset Misdirection *(off)*: what Readiness waits to reset before firing.
- **Trinket 1/2** *(Offensive)* — Off / Offensive (burst) / Defensive.
- **Sync CDs with Bloodlust/Drums**, **Haste Potion (burst)**.

**Pet**
- **Mend Pet HP %** *(60)*, **Experimental Pet Controller** *(off)*.

**PvP** (own tab)
- Per-class **Viper Sting** targets + skip-below-HP threshold; **Wing Clip** PvP/PvE HP gates.

---

## 3. Hunter tools (overlays)

All toggled in **Pet & Diag** (or `/flux`):

| Tool | What it shows |
|---|---|
| **Melee Weave Coach** | Read-only traffic-light timer for manually weaving **Raptor Strike** into Auto Shot downtime. Tunable: Round Trip Budget *(384ms)*, Exit Buffer *(234ms)*, Step-In Lead *(150ms)*, HUD Width *(320px)*. **Manual Melee Control** is **on by default** — turn it OFF if you still use WoW's "Auto Attack / Auto Shot" swap (full macro setup in §6). |
| **Auto Shot Clip Tracker** | Tracks and color-codes how badly you're clipping Auto Shot; optional post-combat summary. Green/Yellow/Orange/Red ms thresholds. |
| **Debug Panel** | Live hunter state — range band, swing/shoot timers, pet, context. |
| **Adaptive Engine Panel** | Per-tick Adaptive scores, derived stats, and recent fires (why it chose each shot). |

*(There's also a general combat dashboard via `/flux status`, and `/flux burst` to pop CDs — those are shared Flux features, not Hunter-specific.)*

---

## 4. Binding the Hunter rotation for v1

In v1 the GGL key-sender **reads the on-screen icon texture** and presses the matching key.
So each ability the rotation can show needs a key in **both** the Loader `Config.ini`
(`[TBC Hunter]`) **and** the in-game Hotkeys tab — and the two must match. A key left blank
in either place means that ability silently no-ops.

Most of the rotation's abilities come pre-filled in your config; just confirm they mirror the
in-game Hotkeys tab. Abilities the rotation can output include: Auto Shot, Steady Shot, Arcane
Shot, Multi-Shot, Kill Command, Raptor Strike, Wing Clip, Concussive Shot, Hunter's Mark,
Tranquilizing Shot, Rapid Fire, Bestial Wrath, **Readiness** (special — see the note below),
Intimidation, Feign Death, the aspects, Blood Fury (racial), pet control, and runes.

**Currently unbound but the rotation can output them** — assign keys if your spec uses them:
**Serpent / Scorpid / Viper Sting, Freezing Trap, Silencing Shot (Interrupt), Scatter Shot,
Trueshot Aura, Misdirection.**

> **Readiness (v1-only workaround).** The v1 sender misreads the Readiness icon, so a normal
> bind never fires (MetaEngine reads it fine — Readiness is the only affected ability). Instead,
> Flux paints texture `Inv_misc_bag_felclothbag` (133667) on the slot when Readiness should fire,
> which GGL recognizes as the generic **`Universal1`** entry. So: give `Universal1` a hotkey,
> bind that same key in-game to `/cast Readiness`, leave the literal `Readiness=` line blank, and
> turn on **Use Readiness**.

---

## 5. Quick start (v1)

1. Loader: `Framework = v1`. Confirm `[TBC Hunter]` keys mirror your in-game Hotkeys tab.
2. Bind **Readiness** in-game to whatever key you gave `Universal1` (see the Readiness note in §4).
3. `/flux` → set **Weapon Speed** to your ranged weapon speed.
4. Turn on the stings / Arcane / aspects you want (stings are off by default).
5. Hold your **Rotation** key and play; call burst with `/flux burst`.
6. (Optional) Enable the Weave Coach / Clip Tracker if you weave Raptor in melee — full macro setup in §6.

---

## 6. Setting up the melee-weave macro

The Weave Coach (§3) tells you *when* to weave; a **hardware macro** on your mouse or keyboard
does the actual step-in/step-out so you aren't feathering the keys by hand. This is the setup the
tuned weave defaults assume.

1. **Disable WoW's "Auto Attack / Auto Shot"** (Interface → Combat options). With it on, WoW
   auto-swaps between melee and Auto Shot by range and will fight your weave.
2. **Confirm Manual Melee Control is on** (`weave_manual_melee`, Pet & Diag → Melee Weave Coach —
   it's on by default). With WoW's swap off, this makes Flux start your melee swing the moment you
   reach melee, so Raptor's on-next-swing has a white hit to land on. *(If you do **not** weave,
   turn this off so it doesn't interfere with normal Auto Shot.)*
3. **Make a mouse macro that presses _forward_ then _back_** — e.g. if forward is `W` and back is
   `S`, the macro taps `W` → `S`. How you build it depends on your mouse/keyboard software
   (Corsair iCUE, Razer Synapse, Logitech G HUB, …) — search a tutorial for your specific brand.
4. **Tune the hold times.** How long you hold *forward* sets how deep you dip into melee (longer =
   more wiggle room for positioning); the *back* hold has to cover the same distance at the slower
   backpedal speed:

   `back = forward / 0.64` — backpedal runs at ~0.64× your forward speed. (A Minor Speed boots
   enchant speeds both directions equally, so the ratio is unchanged — no adjustment needed.)

   *Example:* hold forward `0.096s` → hold back `0.096 / 0.64 = 0.15s`.

   Fire the macro on the coach's **GREEN**. These hold times map to the coach's **Step-In Lead**
   (forward) and **Round Trip Budget** (forward + back) — the shipped defaults *(150 / 384 ms)*
   reflect a ~150 ms-in / ~234 ms-out weave.

---

*Feedback welcome — especially on the binding mechanics and exact default keys (those come
from your Loader config), and anything Hunter-specific I got thin or wrong.*
