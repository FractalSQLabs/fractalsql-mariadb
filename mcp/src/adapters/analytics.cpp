// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
// Analytics tier tools. Every array argument is a CSV-or-bracketed-
// JSON-array STRING at the SQL layer; the tool schemas declare JSON arrays
// (numbers, or nested arrays for point clouds/matrices) and the adapter packs
// them through parameter binding. Optional trailing scalars bundle into one
// trailing JSON params string per the docs.
//
// Minimum-input-size caveats stated here are the REAL, empirically-verified
// minimums (this repo's own testing), not each primitive's optimistic
// documented one.

#include "analytics.h"
#include "helpers.h"
#include "../db.h"
#include "../tool_param_helpers.h"

namespace fsqlmcp
{
    std::vector<ToolSpec> buildAnalyticsTools( Db& db, const RowLimitConfig& rowCfg )
    {
        using namespace adap;
        (void)rowCfg;    // analytics results are scalars/short arrays; only mine_topology_negatives caps k
        std::vector<ToolSpec> t;

        auto dormant = []( const char* toolName ) -> ToolError
        {
            return ToolError( ErrorClass::Engine,
                std::string( toolName ) + ": enterprise tier not loaded (engine returned "
                "NULL-dormant; see docs/enterprise.md)" );
        };

        t.push_back( mkTool( "fractal_dimension_dfa", "analytics", "pure", ToolClass::Cheap,
            "DFA scaling exponent (alpha) of a time series - noise vs. pink noise vs. Brownian "
            "motion. Documented minimum 16 points, but 16 is necessary, not sufficient: the "
            "underlying check rejects every series shorter than 24 points in practice (and fails "
            "silently - the read-side minimum of this engine's UDF errors is NULL). Use >= 24.",
            { Vec( "series", true, "the time series (>=24 points to be safe)" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_dimension_dfa(?)",
                    { SqlValue( packVector( a.at( "series" ), "series" ) ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_dimension_boxcount", "analytics", "pure", ToolClass::Cheap,
            "Minkowski-Bouligand box-counting dimension of a point cloud. Documented minimum '>= "
            "8 points and a non-degenerate bounding box', but a stable estimate empirically needs "
            "hundreds of points (500 uniform-random 2-D points succeeded in testing; 64 did not) - "
            "its internal eps-sweep needs enough intermediate octave levels.",
            { Mat( "points", true, "point cloud, one [dim]-vector per entry (flattened row-major at the SQL layer)" ),
              Int( "dim", true, "point dimensionality (>= 1)" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_dimension_boxcount(?, ?)",
                    { SqlValue( packFlat( flattenMatrix( a.at( "points" ), "points" ), "points" ) ),
                      SqlValue( a.at( "dim" ).get<std::int64_t>() ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_dimension_drift", "analytics", "pure", ToolClass::Cheap,
            "Regime-change detection: recent-window DFA exponent vs. baseline -> {drift, "
            "recent_alpha, baseline_alpha}. Requires n >= win + 16 and win >= 16.",
            { Vec( "series", true, "the time series" ),
              Int( "win", false, "window size (>= 16)", 16 ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_dimension_drift(?, ?)",
                    { SqlValue( packVector( a.at( "series" ), "series" ) ),
                      SqlValue( static_cast<std::int64_t>(
                          a.contains( "win" ) && a.at( "win" ).is_number_integer() ? a.at( "win" ).get<int>() : 16 ) ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_change_point_detect", "analytics", "pure", ToolClass::Cheap,
            "Change-point detection: localizes WHERE a series' mean and/or variance shifted, "
            "via a sliding two-sample test over adjacent windows. Returns {'indices':[...]}, "
            "ascending, up to max_points. The complement of fractal_dimension_dfa, which "
            "measures how complex a series is rather than where it changed.",
            { Vec( "series", true, "the time-ordered series" ),
              Int( "window", true, "sliding window size (requires n >= 2*window)" ),
              Num( "threshold", false, "pooled-stddev units to flag a boundary", 2.0 ),
              Int( "max_points", false, "maximum number of boundaries returned", 16 ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_change_point_detect(?, ?, ?, ?)",
                    { SqlValue( packVector( a.at( "series" ), "series" ) ),
                      SqlValue( a.at( "window" ).get<std::int64_t>() ),
                      SqlValue( a.contains( "threshold" ) && a.at( "threshold" ).is_number()
                                  ? a.at( "threshold" ).get<double>() : 2.0 ),
                      SqlValue( static_cast<std::int64_t>(
                          a.contains( "max_points" ) && a.at( "max_points" ).is_number_integer()
                            ? a.at( "max_points" ).get<int>() : 16 ) ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_periodogram", "analytics", "pure", ToolClass::Cheap,
            "Classical periodogram via an exact O(n^2) DFT (not an FFT). Returns "
            "{'freqs':[...],'power':[...]}: the top max_peaks bins, descending power. "
            "Catches periodic behaviour (network beaconing, retry cadence) that "
            "fractal_dimension_dfa alone misses. Requires n >= 4.",
            { Vec( "series", true, "the time-ordered series (>= 4 points)" ),
              Int( "max_peaks", false, "number of peak bins to return", 8 ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_periodogram(?, ?)",
                    { SqlValue( packVector( a.at( "series" ), "series" ) ),
                      SqlValue( static_cast<std::int64_t>(
                          a.contains( "max_peaks" ) && a.at( "max_peaks" ).is_number_integer()
                            ? a.at( "max_peaks" ).get<int>() : 8 ) ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_spectrogram_entropy", "analytics", "pure", ToolClass::Cheap,
            "Short-time spectral entropy: slides a window over a series and returns, per "
            "frame, the normalized Shannon entropy (0..1) of its power spectrum (mean "
            "removed, Hann tapered). Low = energy in a few frequencies (beacon, retry "
            "loop, locked carrier); high = spread across the band (noise, jamming, lost "
            "structure). A constant frame reports 0.0, never NaN. Returns {'entropy':[...]}, "
            "one value per frame; feed it to fractal_change_point_detect to localize WHEN "
            "the structure changed. Requires n >= window.",
            { Vec( "series", true, "the time-ordered series (n >= window)" ),
              Int( "window", false, "frame length, 8..512", 64 ),
              Int( "hop", false, "samples between frame starts, >= 1", 32 ),
              Int( "max_frames", false, "maximum frames returned, 1..4096", 4096 ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                auto optInt = [ &a ]( const char* key, int dflt )
                {
                    return SqlValue( static_cast<std::int64_t>(
                        a.contains( key ) && a.at( key ).is_number_integer() ? a.at( key ).get<int>() : dflt ) );
                };
                Json frames = db.callScalarBind( "SELECT fractal_spectrogram_entropy(?, ?, ?, ?)",
                    { SqlValue( packVector( a.at( "series" ), "series" ) ),
                      optInt( "window", 64 ), optInt( "hop", 32 ), optInt( "max_frames", 4096 ) } );
                // The UDF refuses bad arguments by returning NULL (no init
                // message), which would otherwise surface as {"entropy":null}.
                if( frames.is_null() )
                    throw ToolError( ErrorClass::Schema,
                        "fractal_spectrogram_entropy: refused - needs window in [8,512], hop >= 1, "
                        "max_frames in [1,4096], at least `window` samples, and finite values" );
                return Json{ { "entropy", frames } };
            }, true ) );

        t.push_back( mkTool( "fractal_tda_persistence_diagram", "analytics", "pure", ToolClass::Cheap,
            "Topological persistence over a point cloud's Vietoris-Rips filtration. Returns "
            "{'n_h0_bars':N,'h0_bars':[{birth,death}...],'betti1':N|null}. betti1 is the "
            "underlying GRAPH's cycle rank, NOT full simplicial H1 - it over-counts whenever "
            "a filled triangle exists in the data. The point cloud is size-capped at 512 points.",
            { Mat( "points", true, "the point cloud, one [dim]-vector per entry (flattened row-major at the SQL layer)" ),
              Int( "dim", true, "spatial dimension of the points (>= 1)" ),
              Int( "max_dim", false, "0 (h0_bars only) or 1 (also the Betti-1 cycle-rank estimate)", 0 ),
              Num( "max_thresh", true, "filtration threshold (> 0)" ),
              Int( "max_h0_bars", false, "maximum number of h0 bars returned", 64 ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_tda_persistence_diagram(?, ?, ?, ?, ?)",
                    { SqlValue( packFlat( flattenMatrix( a.at( "points" ), "points" ), "points" ) ),
                      SqlValue( a.at( "dim" ).get<std::int64_t>() ),
                      SqlValue( static_cast<std::int64_t>(
                          a.contains( "max_dim" ) && a.at( "max_dim" ).is_number_integer()
                            ? a.at( "max_dim" ).get<int>() : 0 ) ),
                      SqlValue( a.at( "max_thresh" ).get<double>() ),
                      SqlValue( static_cast<std::int64_t>(
                          a.contains( "max_h0_bars" ) && a.at( "max_h0_bars" ).is_number_integer()
                            ? a.at( "max_h0_bars" ).get<int>() : 64 ) ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_state_fingerprint", "analytics", "pure", ToolClass::Cheap,
            "Random-hyperplane SimHash fingerprint of a state vector -> JSON array of the "
            "(n_bits+7)/8 packed bytes, MSB-first. Engine caveat: SimHash collapses near-identical "
            "states to one fingerprint (a period-2 wobble can read as a period-1 stream) - see "
            "fractal_agent_detect_loop for the composition that watches for it.",
            { Vec( "vector", true, "the state vector" ),
              Int( "n_bits", false, "", 64 ),
              Num( "seed", false, "", 42.0 ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_state_fingerprint(?, ?, ?)",
                    { SqlValue( packVector( a.at( "vector" ), "vector" ) ),
                      SqlValue( static_cast<std::int64_t>(
                          a.contains( "n_bits" ) && a.at( "n_bits" ).is_number_integer()
                            ? a.at( "n_bits" ).get<int>() : 64 ) ),
                      SqlValue( a.contains( "seed" ) && a.at( "seed" ).is_number()
                                  ? a.at( "seed" ).get<double>() : 42.0 ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_cycle_detect", "analytics", "pure", ToolClass::Cheap,
            "Brent's-algorithm streaming cycle detection over a FINGERPRINT BYTE STREAM -> "
            "{detected, cycle_len, at_index} or {detected:false}. The stream is the concatenated "
            "fingerprint bytes, exactly n_fingerprints * n_bytes values; hamming_threshold 0 = "
            "byte-exact. State does NOT survive across separate calls.",
            { Vec( "fingerprints", true, "concatenated fingerprint byte values, exactly n_fingerprints * n_bytes long" ),
              Int( "n_bytes", true, "bytes per fingerprint (>= 1)" ),
              Int( "hamming_threshold", false, "", 0 ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_cycle_detect(?, ?, ?)",
                    { SqlValue( packFlat( a.at( "fingerprints" ), "fingerprints" ) ),
                      SqlValue( a.at( "n_bytes" ).get<std::int64_t>() ),
                      SqlValue( static_cast<std::int64_t>(
                          a.contains( "hamming_threshold" ) && a.at( "hamming_threshold" ).is_number_integer()
                            ? a.at( "hamming_threshold" ).get<int>() : 0 ) ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_vector_lp_distance", "analytics", "pure", ToolClass::Cheap,
            "Generalized L_p distance, any p > 0. For 0 < p < 1 this is NOT a proper metric - "
            "never substitute it silently for the search primitives' own cosine.",
            { Vec( "a", true, "first vector" ), Vec( "b", true, "second vector" ),
              Num( "p", true, "2 = Euclidean", nullptr ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                const double p = a.at( "p" ).get<double>();
                if( p <= 0.0 )
                    throw ToolError( ErrorClass::Schema, "p must be > 0 (exclusiveMinimum)" );
                return db.callScalarBind( "SELECT fractal_vector_lp_distance(?, ?, ?)",
                    { SqlValue( packVector( a.at( "a" ), "a" ) ),
                      SqlValue( packVector( a.at( "b" ), "b" ) ),
                      SqlValue( p ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_vector_quantize_int8", "analytics", "pure", ToolClass::Cheap,
            "Symmetric int8 quantization, 4x compression -> {scale, values}.",
            { Vec( "vector", true, "the vector to quantize" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_vector_quantize_int8(?)",
                    { SqlValue( packVector( a.at( "vector" ), "vector" ) ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_vector_quantize_binary", "analytics", "pure", ToolClass::Cheap,
            "1-bit quantization, 32x compression -> JSON array of packed bytes "
            "(bit i is 1 if v[i] >= 0, packed MSB-first).",
            { Vec( "vector", true, "the vector to quantize" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_vector_quantize_binary(?)",
                    { SqlValue( packVector( a.at( "vector" ), "vector" ) ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_vector_hamming_distance", "analytics", "pure", ToolClass::Cheap,
            "Hamming distance between two QUANTIZED vectors (the packed-byte outputs of "
            "fractal_vector_quantize_binary; equal byte counts required) - cheap pre-filter "
            "ahead of a full-precision re-rank.",
            { Vec( "a_bytes", true, "first vector's packed bytes" ),
              Vec( "b_bytes", true, "second vector's packed bytes" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_vector_hamming_distance(?, ?)",
                    { SqlValue( packFlat( a.at( "a_bytes" ), "a_bytes" ) ),
                      SqlValue( packFlat( a.at( "b_bytes" ), "b_bytes" ) ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_vector", "analytics", "pure", ToolClass::Cheap,
            "Builds the zero vector of the given dimension in the CANONICAL form: a fixed binary "
            "layout (uint16 dim LE, uint16 reserved, then dim little-endian float32 values) "
            "carried as lowercase hex, so it is byte-stable, charset-safe, and storable in a "
            "VARCHAR or a BLOB column. UNHEX() turns it back into the binary bytes. Every "
            "fractal_vector_* function accepts the canonical form as input as well as the "
            "JSON/CSV text form.",
            { Int( "dim", true, "dimension (1-32767)" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_vector(?)",
                    { SqlValue( a.at( "dim" ).get<std::int64_t>() ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_vector_from_text", "analytics", "pure", ToolClass::Cheap,
            "Converts a vector to the canonical form. Accepts the canonical hex form OR the "
            "JSON/CSV text form ('[1,2,3]' / '1,2,3'); returns the canonical hex form.",
            { Str( "text", true, "the vector, as canonical hex or as JSON/CSV text" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_vector_from_text(?)",
                    { SqlValue( a.at( "text" ).get<std::string>() ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_vector_to_json", "analytics", "pure", ToolClass::Cheap,
            "Renders a vector as a JSON array of numbers. Accepts the canonical hex form OR the "
            "JSON/CSV text form. This is the bridge to MariaDB 11.7+'s native VECTOR(n) type: "
            "VEC_FROMTEXT(fractal_vector_to_json(v)).",
            { Str( "vector", true, "the vector, as canonical hex or as JSON/CSV text" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_vector_to_json(?)",
                    { SqlValue( a.at( "vector" ).get<std::string>() ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_vascular_network", "analytics", "pure", ToolClass::Cheap,
            "Vessel-network tortuosity + branch-density + fractal dimension from PRE-extracted "
            "graph geometry (nodes/edges/arc-lengths, not an image). {mean_tortuosity, "
            "branch_density, fractal_dimension}.",
            { Mat( "node_coords", true, "node coordinate rows" ),
              Vec( "edges", true, "flat index pairs: [from,to, from,to, ...]" ),
              Vec( "edge_arc_length", true, "one true arc length per edge (>= straight-line length for tortuosity)" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_vascular_network(?, ?, ?)",
                    { SqlValue( packFlat( flattenMatrix( a.at( "node_coords" ), "node_coords" ), "node_coords" ) ),
                      SqlValue( packFlat( a.at( "edges" ), "edges" ) ),
                      SqlValue( packFlat( a.at( "edge_arc_length" ), "edge_arc_length" ) ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_cortical_folding", "analytics", "pure", ToolClass::Cheap,
            "Gyrification Index from a PRE-extracted brain-surface mesh -> {mesh_area, "
            "hull_area, gyrification_index}. Requires >= 4 non-coplanar vertices.",
            { Mat( "vertices", true, "mesh vertex rows" ),
              Vec( "faces", true, "flat vertex-index triples" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_cortical_folding(?, ?)",
                    { SqlValue( packFlat( flattenMatrix( a.at( "vertices" ), "vertices" ), "vertices" ) ),
                      SqlValue( packFlat( a.at( "faces" ), "faces" ) ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_nerve_plexus_metric", "analytics", "pure", ToolClass::Cheap,
            "Nerve-fiber plexus density + dimension from PRE-extracted skeleton geometry -> "
            "{fiber_length_density, branch_density, fractal_dimension}.",
            { Mat( "node_coords", true, "node coordinate rows" ),
              Int( "dim", true, "point dimensionality (>= 1)" ),
              Vec( "edges", true, "flat index pairs" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_nerve_plexus_metric(?, ?, ?)",
                    { SqlValue( packFlat( flattenMatrix( a.at( "node_coords" ), "node_coords" ), "node_coords" ) ),
                      SqlValue( a.at( "dim" ).get<std::int64_t>() ),
                      SqlValue( packFlat( a.at( "edges" ), "edges" ) ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_morphological_complexity", "analytics", "pure", ToolClass::Cheap,
            "Box-counting dimension + lacunarity of a PRE-segmented mask's occupied points -> "
            "{dimension, lacunarity}. Same box-count stability caveat as "
            "fractal_dimension_boxcount: a meaningful estimate needs a large occupied set.",
            { Mat( "points", true, "occupied-point rows" ),
              Int( "dim", true, "point dimensionality (>= 1)" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callScalarBind( "SELECT fractal_morphological_complexity(?, ?)",
                    { SqlValue( packFlat( flattenMatrix( a.at( "points" ), "points" ), "points" ) ),
                      SqlValue( a.at( "dim" ).get<std::int64_t>() ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_optimize_portfolio", "analytics", "pure", ToolClass::Cheap,
            "SFS cardinality-constrained Sharpe-ratio maximizer -> {sharpe, weights}. cov is "
            "flat, row-major n x n. Knobs via params: seed (0), use_obl (false), diffusion_mode "
            "(\"gaussian\", one of gaussian/levy - OBL / Levy-flight diffusion).",
            { Vec( "mu", true, "expected returns per asset" ),
              Vec( "cov", true, "covariance, flattened 1-D row-major (n*n values)" ),
              Int( "k", true, "max nonzero assets (>= 1)" ),
              Obj( "params", false, "{\"seed\":0, \"use_obl\":false, \"diffusion_mode\":\"gaussian\"|\"levy\"}" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                const Json empty = Json::object();
                return db.callScalarBind( "SELECT fractal_optimize_portfolio(?, ?, ?, ?)",
                    { SqlValue( packVector( a.at( "mu" ), "mu" ) ),
                      SqlValue( packVector( a.at( "cov" ), "cov" ) ),
                      SqlValue( a.at( "k" ).get<std::int64_t>() ),
                      SqlValue( packParams( a.contains( "params" ) ? a.at( "params" ) : empty ) ) } );
            }, true ) );

        // NULL-dormant enterprise trio: a NULL-family result on Community maps to
        // the suite's own clean, named, documented condition, never a
        // silently-returned {"value": null}.
        auto rejectDormant = [ dormant ]( const Json& result, const char* toolName ) -> Json
        {
            if( resultIsNull( result ) ) throw dormant( toolName );
            return result;
        };

        t.push_back( mkTool( "fractal_optimize_portfolio_multimodal", "analytics", "pure", ToolClass::Cheap,
            "ENTERPRISE TIER - returns a clean dormant 'enterprise tier not loaded' condition on "
            "a Community install (the UDF is NULL-dormant there). Multi-restart diverse-candidate "
            "sibling -> {n_found, candidates:[{sharpe, weights}]}, Sharpe descending. All seven "
            "arguments are required and positional (no default-argument syntax in this engine's "
            "UDF ABI). Writes a kind=2 audit-chain entry when enterprise is active.",
            { Vec( "mu", true, "expected returns per asset" ),
              Vec( "cov", true, "covariance, flattened 1-D row-major" ),
              Int( "k", true, "max nonzero assets (>= 1)" ),
              Int( "n_restarts", true, "restarts (>= 1)" ),
              Num( "overlap_threshold", true, "[0,1]" ),
              Num( "quality_frac", true, "[0,1]" ),
              Int( "seed", true, "RNG seed" ) },
            [ &db, rejectDormant ]( const Json& a, CallCtx& )
            {
                Json result = db.callScalarBind(
                    "SELECT fractal_optimize_portfolio_multimodal(?, ?, ?, ?, ?, ?, ?)",
                    { SqlValue( packVector( a.at( "mu" ), "mu" ) ),
                      SqlValue( packVector( a.at( "cov" ), "cov" ) ),
                      SqlValue( a.at( "k" ).get<std::int64_t>() ),
                      SqlValue( a.at( "n_restarts" ).get<std::int64_t>() ),
                      SqlValue( a.at( "overlap_threshold" ).get<double>() ),
                      SqlValue( a.at( "quality_frac" ).get<double>() ),
                      SqlValue( a.at( "seed" ).get<std::int64_t>() ) } );
                return rejectDormant( result, "fractal_optimize_portfolio_multimodal" );
            }, true ) );

        t.push_back( mkTool( "fractal_optimize_portfolio_multimodal_ex", "analytics", "pure", ToolClass::Cheap,
            "ENTERPRISE TIER (NULL-dormant on Community) - MariaDB-only separate 9-arg symbol "
            "carrying the OBL/Levy-flight knobs on the multimodal path (no default-argument "
            "syntax in MariaDB's UDF ABI). diffusion_mode: 'gaussian' or 'levy'; use_obl given "
            "as 0/1. On a pre-_ex enterprise library, requesting either knob returns NULL.",
            { Vec( "mu", true, "expected returns per asset" ),
              Vec( "cov", true, "covariance, flattened 1-D row-major" ),
              Int( "k", true, "max nonzero assets (>= 1)" ),
              Int( "n_restarts", true, "restarts (>= 1)" ),
              Num( "overlap_threshold", true, "[0,1]" ),
              Num( "quality_frac", true, "[0,1]" ),
              Int( "seed", true, "RNG seed" ),
              Int( "use_obl", true, "opposition-based learning: 0 or 1" ),
              StrEnum( "diffusion_mode", true, "'gaussian' or 'levy'" ) },
            [ &db, rejectDormant ]( const Json& a, CallCtx& )
            {
                const int obl = a.at( "use_obl" ).get<int>();
                if( obl != 0 && obl != 1 )
                    throw ToolError( ErrorClass::Schema, "use_obl must be 0 or 1" );
                const std::string dm = a.at( "diffusion_mode" ).get<std::string>();
                if( dm != "gaussian" && dm != "levy" )
                    throw ToolError( ErrorClass::Schema, "diffusion_mode is 'gaussian' or 'levy'" );
                Json result = db.callScalarBind(
                    "SELECT fractal_optimize_portfolio_multimodal_ex(?, ?, ?, ?, ?, ?, ?, ?)",
                    { SqlValue( packVector( a.at( "mu" ), "mu" ) ),
                      SqlValue( packVector( a.at( "cov" ), "cov" ) ),
                      SqlValue( a.at( "k" ).get<std::int64_t>() ),
                      SqlValue( a.at( "n_restarts" ).get<std::int64_t>() ),
                      SqlValue( a.at( "overlap_threshold" ).get<double>() ),
                      SqlValue( a.at( "quality_frac" ).get<double>() ),
                      SqlValue( a.at( "seed" ).get<std::int64_t>() ),
                      SqlValue( static_cast<std::int64_t>( obl ) ),
                      SqlValue( dm ) } );
                return rejectDormant( result, "fractal_optimize_portfolio_multimodal_ex" );
            }, true ) );

        t.push_back( mkTool( "fractal_optimize_portfolio_multimodal_pareto", "analytics", "pure", ToolClass::Cheap,
            "ENTERPRISE TIER (NULL-dormant on Community; no fallback to a base symbol) - Pareto-"
            "front sibling: same restarts, scored by decomposed (return, risk), NSGA-II "
            "crowding-distance truncated -> {n_found, candidates:[{return, risk, sharpe, "
            "weights}]}. sharpe is informational, not the selection criterion. "
            "1 <= max_front <= n_restarts.",
            { Vec( "mu", true, "expected returns per asset" ),
              Vec( "cov", true, "covariance, flattened 1-D row-major" ),
              Int( "k", true, "max nonzero assets (>= 1)" ),
              Int( "n_restarts", true, "restarts (>= 1)" ),
              Int( "max_front", true, "1 <= max_front <= n_restarts" ),
              Int( "seed", true, "RNG seed" ),
              Int( "use_obl", false, "0 (default) or 1", 0 ),
              StrEnum( "diffusion_mode", false, "'gaussian' (default) or 'levy'" ) },
            [ &db, rejectDormant ]( const Json& a, CallCtx& )
            {
                Json result = db.callScalarBind(
                    "SELECT fractal_optimize_portfolio_multimodal_pareto(?, ?, ?, ?, ?, ?, ?, ?)",
                    { SqlValue( packVector( a.at( "mu" ), "mu" ) ),
                      SqlValue( packVector( a.at( "cov" ), "cov" ) ),
                      SqlValue( a.at( "k" ).get<std::int64_t>() ),
                      SqlValue( a.at( "n_restarts" ).get<std::int64_t>() ),
                      SqlValue( a.at( "max_front" ).get<std::int64_t>() ),
                      SqlValue( a.at( "seed" ).get<std::int64_t>() ),
                      SqlValue( static_cast<std::int64_t>(
                          a.contains( "use_obl" ) && a.at( "use_obl" ).is_number_integer()
                            ? a.at( "use_obl" ).get<int>() : 0 ) ),
                      SqlValue( a.contains( "diffusion_mode" ) && !a.at( "diffusion_mode" ).is_null()
                                  ? a.at( "diffusion_mode" ).get<std::string>() : std::string( "gaussian" ) ) } );
                return rejectDormant( result, "fractal_optimize_portfolio_multimodal_pareto" );
            }, true ) );

        t.push_back( mkTool( "fractal_optimize_subset", "analytics", "pure", ToolClass::Cheap,
            "Value-weighted k-subset allocation over any scored item list with per-item upper "
            "bounds -> {score, weights}. upper_bounds may be omitted ('' at the engine's own "
            "grammar) for the core default ([0,1] per item); the sum of the k largest bounds "
            "must reach 1.0 or no feasible k-subset exists. params: {seed}.",
            { Vec( "item_values", true, "per-item values" ),
              Vec( "upper_bounds", false, "per-item upper bounds; omit for [0,1] per item" ),
              Int( "k", true, "subset size" ),
              Obj( "params", false, "{\"seed\":0}" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                const bool hasBounds = a.contains( "upper_bounds" ) && !a.at( "upper_bounds" ).is_null();
                const Json empty = Json::object();
                return db.callScalarBind( "SELECT fractal_optimize_subset(?, ?, ?, ?)",
                    { SqlValue( packVector( a.at( "item_values" ), "item_values" ) ),
                      SqlValue( hasBounds ? packVector( a.at( "upper_bounds" ), "upper_bounds" )
                                           : std::string() ),
                      SqlValue( a.at( "k" ).get<std::int64_t>() ),
                      SqlValue( packParams( a.contains( "params" ) ? a.at( "params" ) : empty ) ) } );
            }, true ) );

        t.push_back( mkTool( "fractal_store_morphology", "analytics", "stateful", ToolClass::Cheap,
            "Upserts a feature vector against a doc_id in the generic per-item feature store "
            "(fractalsql_feature_store) that fractal_mine_topology_negatives scans. Void "
            "procedure.",
            { Int( "doc_id", true, "item id (>= 0)" ),
              Vec( "feature_array", true, "the feature vector" ) },
            [ &db ]( const Json& a, CallCtx& )
            {
                return db.callProc( "fractal_store_morphology",
                    { SqlValue( a.at( "doc_id" ).get<std::int64_t>() ),
                      SqlValue( packVector( a.at( "feature_array" ), "feature_array" ) ) },
                    {}, MergeMode::None );
            } ) );

        t.push_back( mkTool( "fractal_mine_topology_negatives", "analytics", "stateful", ToolClass::Cheap,
            "Brute-force k-NN scan over the morphology feature store -> [{doc_id, dist}] "
            "ascending (squared Euclidean, O(n) per call, no index) - intended for a curated "
            "store, not a full corpus scan.",
            { Vec( "surrogate_vector", true, "the query feature vector" ),
              Int( "k", false, "neighbors to return", 5 ),
              RowLimit() },
            [ &db, &rowCfg ]( const Json& a, CallCtx& )
            {
                limitKCheck( a, rowCfg );
                const int k = std::min<int>(
                    a.contains( "k" ) && a.at( "k" ).is_number_integer() ? a.at( "k" ).get<int>() : 5,
                    effectiveLimit( a, rowCfg ) );
                Json result = db.callProc( "fractal_mine_topology_negatives",
                    { SqlValue( packVector( a.at( "surrogate_vector" ), "surrogate_vector" ) ),
                      SqlValue( static_cast<std::int64_t>( k ) ) },
                    { "result" }, MergeMode::Single );
                return truncateResult( std::move( result ), effectiveLimit( a, rowCfg ) );
            }, true ) );

        return t;
    }
}