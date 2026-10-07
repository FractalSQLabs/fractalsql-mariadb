SELECT fractal_audit_log('test', '{"a":1}');
SELECT fractal_audit_unpack('deadbeef');
SELECT fractal_ledger_verify(101), fractal_ledger_verify(101, 'truth');
SELECT fractal_ledger_truth_count(101), fractal_ledger_shadow_count(101);
SELECT fractal_ledger_flush(101), fractal_ledger_load(101), fractal_ledger_compact(101);
SELECT fractal_ledger_reset_soft(101), fractal_ledger_reset_hard(101);
