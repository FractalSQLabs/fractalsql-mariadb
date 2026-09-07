// bench/tester/run.js
//
// Minimal Node.js 24 driver for the fractalsql-mariadb UDF. Generates a
// random corpus + query in JS, calls fractal_search() BENCH_ITERATIONS
// times, records wall-clock latency, and prints mean / p50 / p95 / p99.
//
// Env knobs:
//   BENCH_N, BENCH_DIM, BENCH_K, BENCH_ITERATIONS
//   MYSQL_HOST / MYSQL_PORT / MYSQL_USER / MYSQL_PASSWORD / MYSQL_DATABASE

import mysql from "mysql2/promise";

const env = process.env;
const N          = Number(env.BENCH_N          ?? 1000);
const DIM        = Number(env.BENCH_DIM        ?? 128);
const K          = Number(env.BENCH_K          ?? 10);
const ITERATIONS = Number(env.BENCH_ITERATIONS ?? 500);

function randomUnit(dim) {
  const v = new Array(dim);
  let sq = 0;
  for (let i = 0; i < dim; i++) { v[i] = Math.random() * 2 - 1; sq += v[i] * v[i]; }
  const norm = Math.sqrt(sq) || 1;
  return v.map(x => x / norm);
}

function corpusCsv(n, dim) {
  const rows = [];
  for (let i = 0; i < n; i++) rows.push(randomUnit(dim).join(","));
  return "[[" + rows.join("],[") + "]]";
}

function queryCsv(dim) {
  return randomUnit(dim).join(",");
}

function quantile(sorted, q) {
  if (sorted.length === 0) return NaN;
  const i = Math.min(sorted.length - 1, Math.floor(q * sorted.length));
  return sorted[i];
}

async function waitForReady(conn, retries = 30) {
  for (let i = 0; i < retries; i++) {
    try {
      const [rows] = await conn.query(
        "SELECT COUNT(*) AS c FROM mysql.func WHERE name = 'fractal_search'");
      if (rows[0].c === 1) return;
    } catch (e) { /* retry */ }
    await new Promise(r => setTimeout(r, 1000));
  }
  throw new Error("fractal_search UDF never became available");
}

async function main() {
  const conn = await mysql.createConnection({
    host:     env.MYSQL_HOST     ?? "127.0.0.1",
    port:     Number(env.MYSQL_PORT ?? 3306),
    user:     env.MYSQL_USER     ?? "root",
    password: env.MYSQL_PASSWORD ?? "",
    database: env.MYSQL_DATABASE ?? "fractal",
    multipleStatements: false,
  });

  console.log(`[bench] connecting... N=${N} dim=${DIM} k=${K} iters=${ITERATIONS}`);
  await waitForReady(conn);

  const corpus = corpusCsv(N, DIM);
  const params = JSON.stringify({
    iterations: 30, population_size: 50, diffusion_factor: 2, walk: 0.5
  });

  const timings = [];
  for (let i = 0; i < ITERATIONS; i++) {
    const q = queryCsv(DIM);
    const t0 = process.hrtime.bigint();
    await conn.query("SELECT fractal_search(?, ?, ?, ?) AS r",
                     [corpus, q, K, params]);
    const t1 = process.hrtime.bigint();
    timings.push(Number(t1 - t0) / 1e6);   // ms
    if ((i + 1) % 50 === 0)
      console.log(`[bench] ${i + 1}/${ITERATIONS}`);
  }

  timings.sort((a, b) => a - b);
  const mean = timings.reduce((a, b) => a + b, 0) / timings.length;
  console.log("----------------------------------------");
  console.log(`mean  ${mean.toFixed(2)} ms`);
  console.log(`p50   ${quantile(timings, 0.50).toFixed(2)} ms`);
  console.log(`p95   ${quantile(timings, 0.95).toFixed(2)} ms`);
  console.log(`p99   ${quantile(timings, 0.99).toFixed(2)} ms`);
  console.log("----------------------------------------");

  await conn.end();
}

main().catch(err => { console.error(err); process.exit(1); });
