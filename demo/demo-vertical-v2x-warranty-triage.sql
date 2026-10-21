-- demo/demo-vertical-v2x-warranty-triage.sql
--
-- Industry vertical: connected-vehicle (V2X) diagnostics -- routing an
-- incoming trouble-code event to the right repair workflow and recalling
-- similar historical warranty claims.  AGENTIC kit: two installed agents
-- are chained, shown hand-composed first and then as the shipped
-- one-call agents.
--
--   1. fractal_agent_route_task -- matches the incoming telemetry event
--      to the best-capable sub-agent / repair workflow under a token
--      budget, exactly its designed contract.
--   2. fractal_agent_recall_hybrid -- fuses a strict metadata filter
--      (component) with drift-vector search to recall similar historical
--      claims; a two-predicate cohort (model year AND component) is shown
--      with fractal_hybrid_clinical_search.
--   3. A closing fractal_reason() produces the dispatch + claim-context
--      summary.
--
-- Structural notes (see sql/install_agents.sql's own header):
--   - Agents and the search primitives are PROCEDUREs with a trailing OUT
--     result JSON param.  There is no id-column argument: route_task
--     returns the capability table's own PRIMARY KEY as `routed_to`
--     (joined below to the workflow name), and recall_hybrid returns the
--     claim's PRIMARY KEY as `mem_id`.
--   - recall_hybrid is pure retrieval, so @r is a JSON ARRAY of
--     {mem_id, content} objects, exploded with JSON_TABLE.
--
-- Prerequisites:
--   1. SOURCE sql/install_udf.sql;      (the base UDF set)
--   2. SOURCE sql/install_agents.sql;   (the sixteen agents)
--   3. Reasoning configured (see docs/reasoning-setup.md) -- route_task
--      and Section 5 call fractal_reason.  recall_hybrid and the hand-
--      composed steps need no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-v2x-warranty-triage.sql
--
-- Safe to re-run: v2x_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixture (no RAND()).
--   * Capability and claim vectors are JSON arrays; the DTC event
--     embedding shares the capability table's 3 dimensions.  In
--     production the embeddings come from your embedding endpoint (see
--     docs/vectorizer-setup.md); here they are hand-placed so the routing
--     and recall answers are readable.

-- === 0. Sanity check: extension loaded? ===
SELECT fractal_edition(), fractal_version();

-- ------------------------------------------------------------------
-- 1. Repair-workflow capability table and the historical claims table.
-- ------------------------------------------------------------------
-- === 1. Capability table + historical warranty claims ===

DROP TABLE IF EXISTS v2x_capabilities;
CREATE TABLE v2x_capabilities (
    id       INT AUTO_INCREMENT PRIMARY KEY,
    workflow VARCHAR(64),
    emb      JSON,
    CONSTRAINT v2x_cap_dims CHECK (JSON_LENGTH(emb) = 3)
);
INSERT INTO v2x_capabilities (workflow, emb) VALUES
    ('battery-thermal-service',  '[0.90, 0.10, 0.10]'),
    ('powertrain-inverter-swap', '[0.10, 0.90, 0.10]'),
    ('adas-sensor-recalibration','[0.10, 0.10, 0.90]'),
    ('software-ota-reflash',     '[0.50, 0.50, 0.50]');

DROP TABLE IF EXISTS v2x_claims;
CREATE TABLE v2x_claims (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    vin        VARCHAR(16),
    model_year INT,
    component  VARCHAR(32),
    note       TEXT,
    drift_vec  JSON,
    CONSTRAINT v2x_claim_dims CHECK (JSON_LENGTH(drift_vec) = 4)
);
INSERT INTO v2x_claims (vin, model_year, component, note, drift_vec) VALUES
    ('VIN-A01', 2023, 'battery-pack', 'coolant pump intermittent, pack temp spike on fast charge', '[0.80, 0.60, 0.10, 0.10]'),
    ('VIN-A02', 2023, 'battery-pack', 'cell imbalance after winter, SoH below threshold',          '[0.70, 0.20, 0.60, 0.10]'),
    ('VIN-A03', 2024, 'battery-pack', 'pack temp spike on fast charge, coolant valve stuck',       '[0.82, 0.58, 0.12, 0.08]'),
    ('VIN-A04', 2024, 'battery-pack', 'contactor chatter at low state of charge',                  '[0.20, 0.10, 0.90, 0.30]'),
    ('VIN-B01', 2023, 'inverter',     'inverter overtemp derate under tow load',                   '[0.55, 0.85, 0.10, 0.20]'),
    ('VIN-B02', 2024, 'inverter',     'phase current ripple, NVH complaint',                       '[0.15, 0.30, 0.20, 0.90]'),
    ('VIN-C01', 2023, 'adas-sensor',  'forward radar misalignment after windshield replacement',   '[0.10, 0.20, 0.30, 0.70]'),
    ('VIN-C02', 2024, 'adas-sensor',  'camera calibration drift, lane-keep disengages',            '[0.12, 0.18, 0.28, 0.75]');

SELECT component, COUNT(*) AS claims FROM v2x_claims GROUP BY component ORDER BY component;

-- ------------------------------------------------------------------
-- 2. Step 1, hand-composed: route the incoming event.  The DTC event is
-- a battery thermal fault -- its embedding sits nearest the battery-
-- thermal workflow.  confidence = 1/(1+distance).
-- ------------------------------------------------------------------
-- === 2. Step 1 (hand-composed): route the incoming DTC event ===

CALL fractal_search_telemetry('v2x_capabilities', 'emb', '[0.85, 0.15, 0.12]', 1, @v2x_t);

SELECT c.workflow                       AS routed_to,
       ROUND(1.0 / (1.0 + jt.dist), 4)  AS confidence,
       1000 - 150                       AS remaining_budget   -- budget less one routing decision
  FROM JSON_TABLE(@v2x_t, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
  JOIN v2x_capabilities c ON c.id = jt.doc_id;

-- --- the shipped agent: same composition, one call (reasoning plugin) ---
CALL fractal_agent_route_task('[0.85, 0.15, 0.12]', 'v2x_capabilities', 'emb', 1000, 150, @v2x_route);
SELECT c.workflow AS routed_to,
       JSON_VALUE(@v2x_route, '$.confidence')       AS confidence,
       JSON_VALUE(@v2x_route, '$.remaining_budget') AS remaining_budget,
       JSON_VALUE(@v2x_route, '$.rationale')        AS rationale
  FROM v2x_capabilities c
 WHERE c.id = JSON_VALUE(@v2x_route, '$.routed_to');

-- ------------------------------------------------------------------
-- 3. Step 2, hand-composed: two-predicate cohort (model year 2024 AND
-- battery pack), then a vector search restricted to it -- the cohort a
-- single (filter_col, filter_val) pair cannot express.
-- ------------------------------------------------------------------
-- === 3. Step 2 (hand-composed): similar 2024 battery-pack claims ===

CALL fractal_hybrid_clinical_search('v2x_claims', 'drift_vec', '[0.80, 0.60, 0.10, 0.10]',
    (SELECT CONCAT('[', GROUP_CONCAT(id ORDER BY id), ']') FROM v2x_claims
      WHERE model_year = 2024 AND component = 'battery-pack'),
    3, @v2x_h);

SELECT c.vin, c.model_year, c.note, ROUND(jt.dist, 4) AS distance
  FROM JSON_TABLE(@v2x_h, '$[*]' COLUMNS (doc_id INT PATH '$.doc_id', dist DOUBLE PATH '$.dist')) jt
  JOIN v2x_claims c ON c.id = jt.doc_id
 ORDER BY jt.dist;

-- ------------------------------------------------------------------
-- 4. Step 2, productized: fractal_agent_recall_hybrid with a strict
-- metadata filter (component = 'battery-pack'); pure retrieval, no
-- model.  mem_id / content are the real claim id and note.
-- ------------------------------------------------------------------
-- === 4. Step 2 (shipped agent): fractal_agent_recall_hybrid ===

CALL fractal_agent_recall_hybrid('v2x_claims', 'drift_vec', '[0.80, 0.60, 0.10, 0.10]',
    'component', 'battery-pack', 3, 'note', @v2x_recall);
SELECT mem_id, content
  FROM JSON_TABLE(@v2x_recall, '$[*]' COLUMNS (
           mem_id  VARCHAR(32) PATH '$.mem_id',
           content TEXT        PATH '$.content')) AS jt;

-- ------------------------------------------------------------------
-- 5. Reasoning: the dispatch + claim-context summary (needs the
-- reasoning plugin).
-- ------------------------------------------------------------------
-- === 5. Reasoning: dispatch + claim-context summary ===

SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line dispatch recommendation plus warranty context for this connected-vehicle fault',
    JSON_OBJECT('routing', JSON_EXTRACT(@v2x_route, '$'),
                'similar_claims', JSON_EXTRACT(@v2x_recall, '$'))) AS summary;

-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
--   DROP TABLE v2x_capabilities, v2x_claims;
