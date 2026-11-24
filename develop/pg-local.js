#!/usr/bin/env node
'use strict';
// Starts an embedded PostgreSQL instance on macOS and applies DocumentServer's schema.
const fs = require('fs');
const path = require('path');
const { pathToFileURL } = require('url');

const depsDir = process.env.EO_PG_DEPS_DIR || '/Users/max/Projects/Euro-Office/ds-local-deps';
const pgDir = process.env.EO_PG_DATA_DIR || path.join(depsDir, 'pgdata');
const schemaPath = path.join(__dirname, '..', 'server', 'schema', 'postgresql', 'createdb.sql');

(async () => {
  const { default: EmbeddedPostgres } = await import(
    pathToFileURL(path.join(depsDir, 'node_modules', 'embedded-postgres', 'dist', 'index.js')).href
  );
  const pg = new EmbeddedPostgres({
    databaseDir: pgDir,
    user: process.env.EO_DB_USER || 'onlyoffice',
    password: process.env.EO_DB_PASS || 'onlyoffice',
    port: Number(process.env.EO_DB_PORT || 5432),
    persistent: true
  });

  if (!fs.existsSync(path.join(pgDir, 'PG_VERSION'))) {
    console.log('[pg-local] initializing database cluster at', pgDir);
    await pg.initialise();
  }

  await pg.start();
  console.log('[pg-local] PostgreSQL started on port', process.env.EO_DB_PORT || 5432);

  const dbName = process.env.EO_DB_NAME || 'onlyoffice';
  try {
    await pg.createDatabase(dbName);
    console.log('[pg-local] created database', dbName);
  } catch (e) {
    if (!String(e.message || e).includes('already exists')) throw e;
  }

  const client = pg.getPgClient(dbName);
  await client.connect();
  const sql = fs.readFileSync(schemaPath, 'utf8');
  await client.query(sql);
  await client.end();
  if (process.env.EO_PG_READY_FILE) {
    fs.writeFileSync(process.env.EO_PG_READY_FILE, String(process.pid));
  }
  console.log('[pg-local] schema applied; ready');

  const stop = async () => {
    try { await pg.stop(); } catch (_) {}
    process.exit(0);
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
  setInterval(() => {}, 60000);
})().catch((err) => {
  console.error('[pg-local] fatal:', err);
  process.exit(1);
});
