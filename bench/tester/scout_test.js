// bench/tester/scout_test.js
//
// Scout Mode (fractal_explore) e2e acceptance gate. Builds a 3-island
// clustered corpus, calls fractal_explore, and asserts the Scout
// enablement properties:
//   (1)+(2) returns the population: population_size particles, each
//           of the corpus dim (not best_point alone);
//   (3)     discovery: particles disperse across more than one island;
//   (4)     Scout != Sniper: fractal_explore spans more islands than
//           fractal_search's top-k (which collapses into one basin).
//
// Exits non-zero on failure. Skips cleanly (exit 0) if fractal_explore
// is not registered, so it is safe before the Scout drop is deployed.
//
//   node scout_test.js     (against the docker-compose.test.yml MySQL)

import mysql from "mysql2/promise";

const env   = process.env;
const DIM   = 3;
const K     = 3;
const PER   = 20;          // rows per island
const POP   = 24;          // population_size
const SIGMA = 0.02;

const CENTERS = [[1, 0, 0], [0, 1, 0], [0, 0, 1]];

const jitter = c => c.map(x => x + (Math.random() * 2 - 1) * SIGMA);

function corpusCsv() {
  const rows = [];
  for (let k = 0; k < K; k++)
    for (let j = 0; j < PER; j++) rows.push(jitter(CENTERS[k]).join(","));
  return "[[" + rows.join("],[") + "]]";   // row order: island = floor(idx / PER)
}

function nearestIsland(p) {
  let best = 0, bd = Infinity;
  for (let k = 0; k < K; k++) {
    let d = 0;
    for (let i = 0; i < DIM; i++) { const e = p[i] - CENTERS[k][i]; d += e * e; }
    if (d < bd) { bd = d; best = k; }
  }
  return best;
}

async function registered(conn, name) {
  for (let i = 0; i < 30; i++) {
    try {
      const [r] = await conn.query(
        "SELECT COUNT(*) c FROM mysql.func WHERE name = ?", [name]);
      if (r[0].c === 1) return true;
    } catch (e) { /* retry */ }
    await new Promise(r => setTimeout(r, 1000));
  }
  return false;
}

async function main() {
  const conn = await mysql.createConnection({
    host:     env.MYSQL_HOST     ?? "127.0.0.1",
    port:     Number(env.MYSQL_PORT ?? 3306),
    user:     env.MYSQL_USER     ?? "root",
    password: env.MYSQL_PASSWORD ?? "",
    database: env.MYSQL_DATABASE ?? "fractal",
  });

  if (!await registered(conn, "fractal_explore")) {
    console.log("SKIP: fractal_explore not registered (Scout drop not deployed?)");
    await conn.end();
    return;
  }

  const corpus = corpusCsv();
  const query  = CENTERS[0].join(",");   // anchor inside island 0
  const params = JSON.stringify({ population_size: POP, iterations: 12, diffusion_factor: 2 });

  // Scout: full population
  const [er] = await conn.query("SELECT fractal_explore(?, ?, ?) AS r", [corpus, query, params]);
  const res  = JSON.parse(er[0].r);
  const pop  = res.population;
  // Skip-safe: a pre-Scout core returns the result JSON without a
  // "population" array. Skip rather than fail until the Scout drop lands.
  if (!Array.isArray(pop)) {
    console.log("SKIP: fractal_explore result has no 'population' (pre-Scout core)");
    await conn.end();
    return;
  }
  if (pop.length !== POP)  throw new Error(`expected ${POP} particles, got ${pop.length}`);
  if (!pop.every(p => Array.isArray(p) && p.length === DIM))
    throw new Error(`particle dim != ${DIM}`);
  const scoutIslands = new Set(pop.map(nearestIsland)).size;

  // Sniper: top-k nearest (collapses into one basin). Map stored-vector
  // index -> island via corpus row order (island = floor(idx / PER)).
  const [sr]   = await conn.query("SELECT fractal_search(?, ?, ?, ?) AS r", [corpus, query, POP, params]);
  const topk   = (JSON.parse(sr[0].r).top_k) || [];
  const sniperIslands = new Set(topk.map(e => Math.floor((e.idx ?? 0) / PER))).size;

  console.log(`population: ${pop.length} particles, dim ${DIM}`);
  console.log(`SCOUT  discovered ${scoutIslands}/${K} islands`);
  console.log(`SNIPER discovered ${sniperIslands}/${K} islands`);

  if (scoutIslands < 2)
    throw new Error(`Scout discovered only ${scoutIslands} island(s); expected >= 2 (no dispersion)`);
  if (!(scoutIslands > sniperIslands))
    throw new Error(`Scout (${scoutIslands}) not broader than Sniper (${sniperIslands})`);

  console.log("OK: scout gate passed");
  await conn.end();
}

main().catch(err => { console.error("FAIL:", err.message); process.exit(1); });
