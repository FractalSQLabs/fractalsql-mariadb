-- demo/demo-vertical-outlier-interception-footprint.sql
--
-- Industry vertical: Automated-traffic interception: bot-farm and
-- invalid-traffic screening. DOMAIN kit: Screens proposed traffic sessions
-- against a history of known-abuse signatures with
-- `fractal_agent_outlier_intercept` (cosine by default, exact Euclidean
-- when magnitude should count), then uses `fractal_dimension_boxcount` on
-- click-coordinate clouds: organic traffic fills the page (a high
-- box-counting dimension) while an automated farm hammering a handful of
-- targets collapses onto a line (a dimension near 1).
--
--   1. fractal_agent_outlier_intercept: hold sessions that sit near a known
--      bot-farm signature.
--   2. The same screen under exact Euclidean distance (threshold 0.30),
--      where magnitude matters.
--   3. fractal_dimension_boxcount: the topological footprint of each
--      traffic source's click map.
--   4. A closing fractal_reason() writes the hold / release justification.
--
-- Prerequisites: SOURCE sql/install_udf.sql; SOURCE sql/install_agents.sql;
-- The closing fractal_reason() narrative and any shipped-agent rationale
-- columns need the reasoning plugin (docs/reasoning-setup.md); every other
-- step runs with no model.
--
-- Run:
--   mariadb -u root -p <your_database> < demo/demo-vertical-outlier-interception-footprint.sql
--
-- Safe to re-run: oif_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Session signature = [click velocity, IP-pool concentration, device
--     reuse, headless-UA ratio, geo mismatch].
--   * Click maps are 200 points each in the unit square: an organic spread
--     vs a collinear farm pattern.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

SELECT fractal_edition(), fractal_version();


-- === 1. Known abuse signatures + proposed traffic sessions ===
DROP TABLE IF EXISTS oif_known;
CREATE TABLE oif_known (
    id INT PRIMARY KEY,
    label VARCHAR(128),
    vec JSON,
    CONSTRAINT oif_known_dims CHECK (JSON_LENGTH(vec) = 5)
);
INSERT INTO oif_known (id, label, vec) VALUES
    (1, 'automated farm: one device pool, burst requests', '[0.95, 0.9, 0.85, 0.1, 0.2]'),
    (2, 'datacenter bot traffic, headless browsers', '[0.9, 0.05, 0.3, 0.95, 0.4]'),
    (3, 'residential-proxy request spoofing', '[0.05, 0.05, 0.1, 0.1, 0.95]'),
    (4, 'request-stacking ring', '[0.1, 0.8, 0.9, 0.85, 0.3]');
DROP TABLE IF EXISTS oif_proposed;
CREATE TABLE oif_proposed (
    id INT PRIMARY KEY,
    label VARCHAR(128),
    vec JSON,
    CONSTRAINT oif_proposed_dims CHECK (JSON_LENGTH(vec) = 5)
);
INSERT INTO oif_proposed (id, label, vec) VALUES
    (1, 'T1 burst requests from a shared device pool', '[0.92, 0.88, 0.8, 0.12, 0.18]'),
    (2, 'T2 organic referral session', '[0.02, 0, 0.05, 0, 0.05]'),
    (3, 'T3 returning user on a new device', '[0, 0.02, 0.7, 0.04, 0.05]'),
    (4, 'T4 faint headless traffic, far geo', '[0.4, 0.02, 0.12, 0.42, 0.16]');


-- === 2. fractal_agent_outlier_intercept (cosine, threshold 0.10) ===
DROP TABLE IF EXISTS oif_screen;
CREATE TABLE oif_screen (id INT, label VARCHAR(128), intercepted INT, metric VARCHAR(16));
DROP PROCEDURE IF EXISTS oif_screen_all;
DELIMITER $$
CREATE PROCEDURE oif_screen_all()
BEGIN
    DECLARE v_id INT; DECLARE v_label VARCHAR(128); DECLARE v_vec JSON; DECLARE v_done INT DEFAULT 0;
    DECLARE cur CURSOR FOR SELECT id, label, vec FROM oif_proposed ORDER BY id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
    OPEN cur;
    loop_p: LOOP
        FETCH cur INTO v_id, v_label, v_vec;
        IF v_done = 1 THEN LEAVE loop_p; END IF;
        CALL fractal_agent_outlier_intercept(v_vec, 'oif_known', 'vec', 0.1, 'cosine', @oif_screen_o);
        INSERT INTO oif_screen VALUES (v_id, v_label,
            IF(JSON_VALUE(@oif_screen_o, '$.intercepted') IN ('true', '1'), 1, 0), 'cosine');
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;
CALL oif_screen_all();
DROP PROCEDURE oif_screen_all;

SELECT id, label, intercepted, metric FROM oif_screen ORDER BY id;


-- === 3. Same screen under exact Euclidean distance (threshold 0.30) ===
DROP TABLE IF EXISTS oif_screen_l2;
CREATE TABLE oif_screen_l2 (id INT, label VARCHAR(128), intercepted INT, metric VARCHAR(16));
DROP PROCEDURE IF EXISTS oif_screen_l2_all;
DELIMITER $$
CREATE PROCEDURE oif_screen_l2_all()
BEGIN
    DECLARE v_id INT; DECLARE v_label VARCHAR(128); DECLARE v_vec JSON; DECLARE v_done INT DEFAULT 0;
    DECLARE cur CURSOR FOR SELECT id, label, vec FROM oif_proposed ORDER BY id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
    OPEN cur;
    loop_p: LOOP
        FETCH cur INTO v_id, v_label, v_vec;
        IF v_done = 1 THEN LEAVE loop_p; END IF;
        CALL fractal_agent_outlier_intercept(v_vec, 'oif_known', 'vec', 0.3, 'l2', @oif_screen_l2_o);
        INSERT INTO oif_screen_l2 VALUES (v_id, v_label,
            IF(JSON_VALUE(@oif_screen_l2_o, '$.intercepted') IN ('true', '1'), 1, 0), 'l2');
    END LOOP;
    CLOSE cur;
END$$
DELIMITER ;
CALL oif_screen_l2_all();
DROP PROCEDURE oif_screen_l2_all;

SELECT id, label, intercepted, metric FROM oif_screen_l2 ORDER BY id;


-- === 4. Click-map topology: organic traffic vs an automated farm ===
DROP TABLE IF EXISTS oif_clicks;
CREATE TABLE oif_clicks (
    ent VARCHAR(48),
    pt  INT,
    x   DOUBLE,
    y   DOUBLE
);
INSERT INTO oif_clicks (ent, pt, x, y)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 200),
     s(ent, p1) AS (
         SELECT 'organic-source', 1
         UNION ALL SELECT 'farm-ring', 0)
SELECT ent, g, ((g * 37) % 100) / 100.0, CASE WHEN p1 = 1 THEN ((g * 61) % 100) / 100.0 ELSE ((g * 37) % 100) / 200.0 + 0.002 * (g % 5) END
  FROM s, gs;
DROP TABLE IF EXISTS oif_dim;
CREATE TABLE oif_dim AS
SELECT ent, ROUND(fractal_dimension_boxcount(
           CONCAT('[', GROUP_CONCAT(CONCAT(ROUND(x, 4), ',', ROUND(y, 4)) ORDER BY pt), ']'), 2), 3) AS dim
  FROM oif_clicks GROUP BY ent ORDER BY ent;

SELECT ent, dim FROM oif_dim ORDER BY ent;


-- === 5. Reasoning: hold / release justification ===
SELECT fractal_reason(
    CONNECTION_ID(),
    'one-line justification for holding the flagged traffic and the topology evidence for an automated farm',
    JSON_OBJECT('held_session', (SELECT label FROM oif_screen WHERE id = 1), 'farm_dimension', (SELECT dim FROM oif_dim WHERE ent = 'farm-ring'), 'organic_dimension', (SELECT dim FROM oif_dim WHERE ent = 'organic-source'))) AS narrative;


-- === 6. Headline check ===
SELECT CONCAT('HEADLINE kit=outlier-interception-footprint ', CASE WHEN (SELECT intercepted FROM oif_screen WHERE id = 1) = 1 AND (SELECT intercepted FROM oif_screen WHERE id = 2) = 0 AND (SELECT intercepted FROM oif_screen WHERE id = 4) = 1 AND (SELECT dim FROM oif_dim WHERE ent = 'farm-ring') + 0.3 < (SELECT dim FROM oif_dim WHERE ent = 'organic-source') THEN 'ok' ELSE 'MISS' END) AS headline;


-- === Demo complete ===
-- Tables left in place for inspection. Clean up with:
-- DROP TABLE oif_known, oif_proposed, oif_screen, oif_screen_l2, oif_clicks, oif_dim;
