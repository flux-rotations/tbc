#!/usr/bin/env node
/**
 * Gear / consumable extraction for one player in one WCL report.
 *
 * Cheap by design: one fights+master query, one aliased CombatantInfo events
 * query covering every boss kill, one aliased Buffs-table query per report,
 * and one gameData query for item names. No event pagination, no rankings,
 * no top-parse fetches - this never approaches the cost of a review run.
 *
 * Per kill fight it emits the player's full gear array (item id/name/ilvl,
 * permanent enchant, temporary enchant such as stones/oils, socketed gems)
 * plus every aura from WCL's Buffs table (id, name, applications, uptime).
 * Classification of what counts as a flask, elixir, food or potion is left
 * to the consumer - this script only records what the log says.
 *
 * Usage: node src/gear-audit.js --report <urlOrCode> --player <name> [--out <file>]
 * Default output: data/gear-audit/<code>-<playerslug>.json
 */

import fs from 'fs/promises';
import path from 'path';
import { graphql } from './api.js';
import { config } from './config.js';

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

function argValue(flag, fallback) {
  const args = process.argv.slice(2);
  const i = args.indexOf(flag);
  return i !== -1 && args[i + 1] ? args[i + 1] : fallback;
}

function extractReportCode(value) {
  if (!value) return null;
  const match = String(value).match(/reports\/([A-Za-z0-9]+)/);
  return match ? match[1] : String(value).trim();
}

function slugify(v) {
  return String(v || 'unknown').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}

const REPORT = extractReportCode(argValue('--report', process.argv[2]));
const PLAYER = argValue('--player', null);

if (!REPORT || !PLAYER) {
  console.error('usage: node src/gear-audit.js --report <urlOrCode> --player <name> [--out <file>]');
  process.exit(1);
}

async function fetchReportShell(code) {
  const data = await graphql(`
    query {
      reportData {
        report(code: "${code}") {
          title
          fights { id name encounterID startTime endTime kill }
          masterData { actors(type: "Player") { id name subType server } }
        }
      }
    }
  `);
  const report = data.reportData.report;
  if (!report) throw new Error(`Report ${code} not found`);
  return report;
}

/** One aliased query: CombatantInfo events for every kill fight at once. */
async function fetchCombatantInfo(code, fights) {
  const aliases = fights
    .map(
      (f) =>
        `f${f.id}: events(fightIDs: [${f.id}], dataType: CombatantInfo, startTime: ${f.startTime}, endTime: ${f.endTime}, limit: 500) { data }`
    )
    .join('\n');
  const data = await graphql(`
    query { reportData { report(code: "${code}") { ${aliases} } } }
  `);
  const out = new Map();
  for (const f of fights) {
    out.set(f.id, data.reportData.report[`f${f.id}`]?.data ?? []);
  }
  return out;
}

/** One aliased query: the player's Buffs table for every kill fight at once. */
async function fetchBuffTables(code, fights, sourceID) {
  const aliases = fights
    .map(
      (f) =>
        `f${f.id}: table(dataType: Buffs, fightIDs: [${f.id}], startTime: ${f.startTime}, endTime: ${f.endTime}, sourceID: ${sourceID})`
    )
    .join('\n');
  const data = await graphql(`
    query { reportData { report(code: "${code}") { ${aliases} } } }
  `);
  const out = new Map();
  for (const f of fights) {
    const raw = data.reportData.report[`f${f.id}`];
    const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;
    out.set(f.id, parsed?.data?.auras ?? []);
  }
  return out;
}

/** Item names for the ids we saw, one aliased gameData query. Best-effort. */
async function fetchItemNames(ids) {
  const unique = [...new Set(ids)].filter((id) => id > 0);
  if (unique.length === 0) return new Map();
  const aliases = unique.map((id) => `i${id}: item(id: ${id}) { name }`).join('\n');
  try {
    const data = await graphql(`query { gameData { ${aliases} } }`);
    const names = new Map();
    for (const id of unique) {
      const name = data.gameData?.[`i${id}`]?.name;
      if (name) names.set(id, name);
    }
    return names;
  } catch (err) {
    console.warn(`Item name lookup failed (continuing without names): ${err.message}`);
    return new Map();
  }
}

function shapeGear(gear, itemNames) {
  return (gear ?? [])
    .map((item, slot) => ({ slot, item }))
    .filter(({ item }) => item && item.id > 0)
    .map(({ slot, item }) => ({
      slot,
      id: item.id,
      name: itemNames.get(item.id) ?? null,
      icon: item.icon ?? null,
      item_level: item.itemLevel ?? 0,
      quality: item.quality ?? 0,
      permanent_enchant: item.permanentEnchant ?? null,
      temporary_enchant: item.temporaryEnchant ?? null,
      gems: (item.gems ?? []).map((g) => ({ id: g.id, item_level: g.itemLevel ?? 0 })),
    }));
}

function shapeBuffs(auras) {
  return (auras ?? []).map((a) => ({
    id: a.guid,
    name: a.name,
    uses: a.totalUses ?? 0,
    uptime_ms: a.totalUptime ?? 0,
  }));
}

async function main() {
  console.log(`Gear audit: report ${REPORT}, player ${PLAYER}...`);
  const report = await fetchReportShell(REPORT);
  const actor = report.masterData.actors.find(
    (a) => a.name.toLowerCase() === PLAYER.toLowerCase()
  );
  if (!actor) {
    throw new Error(
      `Player "${PLAYER}" not found in report. Names: ${report.masterData.actors.map((a) => a.name).join(', ')}`
    );
  }

  const kills = report.fights.filter((f) => f.kill && f.encounterID > 0);
  if (kills.length === 0) throw new Error('No killed boss fights found in report.');
  console.log(`${kills.length} boss kills. Fetching combatant info + buff tables...`);

  const combatantInfo = await fetchCombatantInfo(REPORT, kills);
  await delay(config.requestDelayMs);
  const buffTables = await fetchBuffTables(REPORT, kills, actor.id);
  await delay(config.requestDelayMs);

  const allItemIds = [];
  for (const events of combatantInfo.values()) {
    const mine = events.find((e) => e.sourceID === actor.id);
    for (const item of mine?.gear ?? []) if (item.id > 0) allItemIds.push(item.id);
  }
  const itemNames = await fetchItemNames(allItemIds);

  const fights = kills.map((f) => {
    const mine = (combatantInfo.get(f.id) ?? []).find((e) => e.sourceID === actor.id);
    return {
      fight_id: f.id,
      boss: f.name,
      slug: slugify(f.name),
      kill: f.kill,
      duration_sec: Math.round((f.endTime - f.startTime) / 100) / 10,
      gear: shapeGear(mine?.gear, itemNames),
      buffs: shapeBuffs(buffTables.get(f.id)),
    };
  });

  const out = {
    report_code: REPORT,
    title: report.title,
    player: actor.name,
    server: actor.server ?? null,
    class: actor.subType ?? null,
    generated: new Date().toISOString(),
    fights,
  };

  const outFile = path.resolve(
    argValue('--out', path.join(config.dataDir, 'gear-audit', `${REPORT}-${slugify(actor.name)}.json`))
  );
  await fs.mkdir(path.dirname(outFile), { recursive: true });
  await fs.writeFile(outFile, JSON.stringify(out, null, 2));
  const withGear = fights.filter((f) => f.gear.length > 0).length;
  console.log(`Saved gear audit (${withGear}/${fights.length} fights with gear) -> ${outFile}`);
}

main().catch((err) => {
  console.error(`Fatal: ${err.message}`);
  process.exit(1);
});
