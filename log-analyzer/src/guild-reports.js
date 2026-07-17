#!/usr/bin/env node
/**
 * List a guild's recent WCL reports as JSON: code, title, start/end time,
 * zone. Used by Prevelon's guild auto-ingest poller to discover new logs.
 *
 * Usage:
 *   node src/guild-reports.js --name MADDOGS --server thunderstrike --region eu [--limit 10]
 *   node src/guild-reports.js --id 123456 [--limit 10]
 *   node src/guild-reports.js --from-report hYTpgfjPCk4qt78F [--limit 10]
 *
 * --from-report resolves the owning guild from an existing report first -
 * handy for verifying a guild identity against a known log. Output is a
 * single JSON line on stdout; failures exit non-zero with a message.
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

function usage() {
  console.error(
    'usage: node src/guild-reports.js (--name <guild> --server <slug> --region <eu|us|...> | --id <guildID> | --from-report <code>) [--limit N]'
  );
  process.exit(1);
}

assertWclConfig();

/** The reports(...) selector for whichever guild identity we hold. */
let selector;
let guildOut;

if (args['from-report']) {
  const code = String(args['from-report']).trim();
  const data = await graphql(
    `
    query ($code: String!) {
      reportData {
        report(code: $code) {
          guild { id name server { slug name region { slug } } }
        }
      }
    }
  `,
    { code }
  );
  const guild = data.reportData?.report?.guild;
  if (!guild) {
    console.error(`Report ${code} not found or has no guild attached`);
    process.exit(1);
  }
  selector = { kind: 'id', id: guild.id };
  guildOut = {
    id: guild.id,
    name: guild.name,
    serverSlug: guild.server?.slug ?? null,
    serverName: guild.server?.name ?? null,
    region: guild.server?.region?.slug ?? null,
  };
} else if (args.id) {
  const id = parseInt(args.id, 10);
  if (!id) usage();
  selector = { kind: 'id', id };
} else if (args.name && args.server && args.region) {
  selector = {
    kind: 'name',
    name: String(args.name).trim(),
    server: String(args.server).trim().toLowerCase(),
    region: String(args.region).trim().toLowerCase(),
  };
} else {
  usage();
}

const reportFields = `
  data {
    code
    title
    startTime
    endTime
    zone { name }
    guild { id name server { slug name region { slug } } }
  }
`;

let data;
if (selector.kind === 'id') {
  data = await graphql(
    `
    query ($id: Int!, $limit: Int!) {
      reportData {
        reports(guildID: $id, limit: $limit) { ${reportFields} }
      }
    }
  `,
    { id: selector.id, limit }
  );
} else {
  data = await graphql(
    `
    query ($name: String!, $server: String!, $region: String!, $limit: Int!) {
      reportData {
        reports(
          guildName: $name
          guildServerSlug: $server
          guildServerRegion: $region
          limit: $limit
        ) { ${reportFields} }
      }
    }
  `,
    { name: selector.name, server: selector.server, region: selector.region, limit }
  );
}

const rows = data.reportData?.reports?.data ?? [];
if (!guildOut) {
  const g = rows[0]?.guild;
  guildOut = g
    ? {
        id: g.id,
        name: g.name,
        serverSlug: g.server?.slug ?? null,
        serverName: g.server?.name ?? null,
        region: g.server?.region?.slug ?? null,
      }
    : selector.kind === 'name'
      ? { id: null, name: selector.name, serverSlug: selector.server, serverName: null, region: selector.region }
      : { id: selector.id, name: null, serverSlug: null, serverName: null, region: null };
}

console.log(
  JSON.stringify({
    guild: guildOut,
    reports: rows.map((r) => ({
      code: r.code,
      title: r.title,
      startTime: r.startTime,
      endTime: r.endTime,
      zone: r.zone?.name ?? null,
    })),
  })
);
