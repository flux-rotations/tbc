#!/usr/bin/env node
/**
 * List a character's recent WCL reports as JSON: code, title, start/end
 * time, zone. Used by Prevelon's per-character history import to show a
 * player which of their past logs are not analyzed yet.
 *
 * Usage:
 *   node src/character-reports.js --name Himatt --server thunderstrike --region eu [--limit 10]
 *
 * One characterData GraphQL call: the character block resolves the WCL
 * identity (id, canonical server) and recentReports lists the logs that
 * character appears in, newest first. Output is a single JSON line on
 * stdout; failures exit non-zero with a message.
 */
import { graphql } from './api.js';
import { assertWclConfig } from './config.js';

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

const args = parseArgs(process.argv);
const limit = Math.min(Math.max(parseInt(args.limit ?? '10', 10) || 10, 1), 25);

if (!args.name || !args.server || !args.region) {
  console.error(
    'usage: node src/character-reports.js --name <character> --server <slug> --region <eu|us|...> [--limit N]'
  );
  process.exit(1);
}

assertWclConfig();

const data = await graphql(
  `
  query ($name: String!, $server: String!, $region: String!, $limit: Int!) {
    characterData {
      character(name: $name, serverSlug: $server, serverRegion: $region) {
        id
        name
        classID
        server { slug name region { slug } }
        recentReports(limit: $limit) {
          data {
            code
            title
            startTime
            endTime
            zone { name }
          }
        }
      }
    }
  }
`,
  {
    name: String(args.name).trim(),
    server: String(args.server).trim().toLowerCase(),
    region: String(args.region).trim().toLowerCase(),
    limit,
  }
);

const character = data.characterData?.character;
if (!character) {
  console.error(
    `Character "${args.name}" not found on ${args.server}-${args.region} - WCL only knows characters that appear in uploaded logs`
  );
  process.exit(1);
}

const rows = character.recentReports?.data ?? [];

console.log(
  JSON.stringify({
    character: {
      id: character.id,
      name: character.name,
      classID: character.classID ?? null,
      serverSlug: character.server?.slug ?? null,
      serverName: character.server?.name ?? null,
      region: character.server?.region?.slug ?? null,
    },
    reports: rows.map((r) => ({
      code: r.code,
      title: r.title,
      startTime: r.startTime,
      endTime: r.endTime,
      zone: r.zone?.name ?? null,
    })),
  })
);
