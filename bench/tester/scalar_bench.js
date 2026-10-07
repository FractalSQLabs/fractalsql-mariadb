// bench/tester/scalar_bench.js
//
// Scalar round-trip latency driver. Calls fractal_vector_dims() (near-zero
// compute: string-parse + count) BENCH_ITERATIONS times over a persistent
// connection and reports mean / p50 / p95 / p99. Near-zero compute makes
// the measured time almost entirely call overhead, so this isolates the
// cost of one shim-to-daemon round trip per UDF call.
//
// Env knobs:
//   BENCH_ITERATIONS (default 3000)
//   MYSQL_SOCKET (unix socket path; takes priority over host/port if set)
//   MYSQL_HOST / MYSQL_PORT / MYSQL_USER / MYSQL_PASSWORD / MYSQL_DATABASE

import mysql from "mysql2/promise";

const env = process.env;
const ITERATIONS = Number(env.BENCH_ITERATIONS ?? 3000);

function quantile(sorted, q) {
  if (sorted.length === 0) return Number.NaN;
  const i = Math.min(sorted.length - 1, Math.floor(q * sorted.length));
  return sorted[i];
}

async function main() {
  const conn = await mysql.createConnection(env.MYSQL_SOCKET ? {
    socketPath: env.MYSQL_SOCKET,
    user:     env.MYSQL_USER     ?? "root",
    password: env.MYSQL_PASSWORD ?? "",
    database: env.MYSQL_DATABASE ?? "fractalsql_demo",
  } : {
    host:     env.MYSQL_HOST     ?? "127.0.0.1",
    port:     Number(env.MYSQL_PORT ?? 3306),
    user:     env.MYSQL_USER     ?? "root",
    password: env.MYSQL_PASSWORD ?? "",
    database: env.MYSQL_DATABASE ?? "fractalsql_demo",
  });

  console.log(`[bench] connected. iters=${ITERATIONS}`);
  // warm up (connection pooling, query plan, TCP slow start) before timing.
  for (let i = 0; i < 50; i++) await conn.query("SELECT fractal_vector_dims('[1,2,3]')");

  const timings = [];
  for (let i = 0; i < ITERATIONS; i++) {
    const t0 = process.hrtime.bigint();
    await conn.query("SELECT fractal_vector_dims('[1,2,3]') AS r");
    const t1 = process.hrtime.bigint();
    timings.push(Number(t1 - t0) / 1e3);   // microseconds
  }

  timings.sort((a, b) => a - b);
  const mean = timings.reduce((a, b) => a + b, 0) / timings.length;
  console.log("----------------------------------------");
  console.log(`mean  ${mean.toFixed(1)} us`);
  console.log(`p50   ${quantile(timings, 0.50).toFixed(1)} us`);
  console.log(`p95   ${quantile(timings, 0.95).toFixed(1)} us`);
  console.log(`p99   ${quantile(timings, 0.99).toFixed(1)} us`);
  console.log("----------------------------------------");

  await conn.end();
}

main().catch(err => { console.error(err); process.exit(1); });
