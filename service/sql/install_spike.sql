-- SPDX-License-Identifier: Apache-2.0
-- Spike install: the two UDFs the Phase 1 shim exports.
-- Load into a server whose --plugin-dir contains the shim's fractalsql.so.
DROP FUNCTION IF EXISTS fractal_version;
CREATE FUNCTION fractal_version RETURNS STRING SONAME 'fractalsql.so';
DROP FUNCTION IF EXISTS fractal_vector_dims;
CREATE FUNCTION fractal_vector_dims RETURNS INTEGER SONAME 'fractalsql.so';
