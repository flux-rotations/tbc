#!/usr/bin/env node
/**
 * List a guild's character roster as JSON: name, server, class, level and
 * guild rank. Used by Prevelon's "Sync roster from WCL" officer action to
 * reconcile a guild's billing seats against the live WCL roster.
 *
 * Usage:
 *   node src/guild-characters.js --id 807935
 *   node src/guild-characters.js --name MADDOGS --server thunderstrike --region eu
 *
 * Cheap by design: the first request carries the class-name table
 * (gameData.classes) alongside members page 1; further pages (100 members
 * each) only fetch when has_more_pages says so, capped at MAX_PAGES.
 * Output is a single JSON line on stdout; failures exit non-zero.
 */
import { graphql } from './api.js';
import { assertWclConfig } from './config.js';

/** 100 members per page; 8 pages = 800 characters, beyond any raid guild. */
const PAGE_SIZE = 100;
const MAX_PAGES = 8;

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i++) {
    const key = argv[i];
    if (!key.startsWith('--')) continue;
    args[key.slice(2)] = argv[i + 1];
    i++;
  }
  return args;
}

function usage() {
  console.error(
    'usage: node src/guild-characters.js (--id <guildID> | --name <guild> --server <slug> --region <eu|us|...>)'
  );
  process.exit(1);
}

const args = parseArgs(process.argv);
assertWclConfig();

/** guild(...) selector arguments for whichever identity we hold. */
let guildArgs;
let variables;
if (args.id) {
  const id = parseInt(args.id, 10);
  if (!id) usage();
  guildArgs = 'id: $id';
  variables = { id };
} else if (args.name && args.server && args.region) {
  guildArgs = 'name: $name, serverSlug: $server, serverRegion: $region';
  variables = {
    name: String(args.name).trim(),
    server: String(args.server).trim().toLowerCase(),
    region: String(args.region).trim().toLowerCase(),
  };
} else {
  usage();
}

const varDefs = args.id
  ? '$id: Int!, $page: Int!'
  : '$name: String!, $server: String!, $region: String!, $page: Int!';

const membersBlock = `
  members(limit: ${PAGE_SIZE}, page: $page) {
    total
    has_more_pages
    data {
      name
      classID
      level
      guildRank
      hidden
      server { slug name region { slug } }
    }
  }
`;

/** Page 1 piggybacks the classID -> name table; later pages skip it. */
function pageQuery(withClasses) {
  return `
    query (${varDefs}) {
      ${withClasses ? 'gameData { classes { id name } }' : ''}
      guildData {
        guild(${guildArgs}) {
          id
          name
          server { slug name region { slug } }
          ${membersBlock}
        }
      }
    }
  `;
}

const classNames = new Map();
let guildOut = null;
const members = [];
let total = 0;

for (let page = 1; page <= MAX_PAGES; page++) {
  const data = await graphql(pageQuery(page === 1), { ...variables, page });
  if (page === 1) {
    for (const c of data.gameData?.classes ?? []) classNames.set(c.id, c.name);
  }
  const guild = data.guildData?.guild;
  if (!guild) {
    console.error('Guild not found on Warcraft Logs for that identity');
    process.exit(1);
  }
  if (!guildOut) {
    guildOut = {
      id: guild.id,
      name: guild.name,
      serverSlug: guild.server?.slug ?? null,
      serverName: guild.server?.name ?? null,
      region: guild.server?.region?.slug ?? null,
    };
  }
  total = guild.members?.total ?? 0;
  const rows = guild.members?.data ?? [];
  for (const m of rows) {
    if (m.hidden) continue; // character opted out of public listing
    members.push({
      name: m.name,
      serverSlug: m.server?.slug ?? null,
      serverName: m.server?.name ?? null,
      class: classNames.get(m.classID) ?? null,
      level: m.level ?? null,
      rank: m.guildRank ?? null,
    });
  }
  if (!guild.members?.has_more_pages) break;
}

console.log(JSON.stringify({ guild: guildOut, total, characters: members }));
