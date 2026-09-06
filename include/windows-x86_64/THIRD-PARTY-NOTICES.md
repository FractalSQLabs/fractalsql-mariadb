Third-Party Notices (Community Edition)

This file contains licensing and attribution notices for third-party
software components incorporated into FractalSQL Community. Any
enterprise-only algorithm attributions are in the enterprise tarball's
own THIRD-PARTY-NOTICES.md alongside the enterprise libraries -- see
that file for the current, authoritative list.

v2.x note: HNSW, DFA, box-counting, lacunarity, the domain-specific
geometry functions, and the portfolio optimizer are all
community-sovereign — same export map as enterprise, no enterprise-only
gate (see the "Algorithm Attributions" section below).

### 1. SFS (Stochastic Fractal Search) Algorithms
Component: SFS Core Math & Stochastic Convergence Logic
Source: Based on "Stochastic Fractal Search" (Salimi 2014)
License: BSD-2-Clause

Copyright (c) 2014, Hamid Salimi. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in
      the documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

-------------------------------------------------------------------------------

### 2. LuaJIT
Component: Just-In-Time Compiler and Execution Engine
Source: https://luajit.org/
License: MIT License

Copyright (C) 2005-2023 Mike Pall. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

-------------------------------------------------------------------------------

### 3. Algorithm Attributions (Original Implementations)

The components below are ORIGINAL C implementations of published algorithms/
methods (v2.x) — not ports or incorporations of existing third-party
source code, so no third-party license text applies.
Listed here as academic attribution for the published method each
implementation follows, per standard practice for algorithm-based (rather
than code-derived) components.

- **HNSW** (src/index/hnsw.c) — Malkov, Y. A., & Yashunin, D. A. (2016,
  revised 2018). "Efficient and Robust Approximate Nearest Neighbor Search
  Using Hierarchical Navigable Small World Graphs." Replaces SFS-based
  retrieval as of v2.x.
- **DFA — Detrended Fluctuation Analysis** (src/fractal_dim/dfa.c) — Peng,
  C.-K., Buldyrev, S. V., Havlin, S., Simons, M., Stanley, H. E., &
  Goldberger, A. L. (1994). "Mosaic organization of DNA nucleotides."
- **Box-counting (Minkowski-Bouligand) dimension**
  (src/fractal_dim/boxcount.c) — standard, widely-used fractal-dimension
  estimation technique; not attributed to a single originating paper.
- **Lacunarity, fixed-grid variant** (src/fractal_dim/lacunarity.c) —
  Plotnick, R. E., Gardner, R. H., & O'Neill, R. V. (1996). "Lacunarity
  indices as measures of landscape texture."
- **Gyrification Index** (src/fractal_dim/cortical.c) — Zilles, K.,
  Armstrong, E., Schleicher, A., & Kretschmann, H. J. (1988). "The human
  pattern of gyrification in the cerebral cortex."
- **Vascular tortuosity (arc-chord ratio) / branch density**
  (src/fractal_dim/vascular.c) — standard vascular morphometry measures,
  not attributed to a single originating paper.
- **Corneal Nerve Fractal Dimension (CNFrD) convention**
  (src/fractal_dim/nerve.c) — parameter conventions (fiber length density,
  branch density normalized by domain area, box-counting dimension) match
  those used by corneal confocal microscopy (CCM) analysis tools such as
  ACCMetrics.
- **Cardinality-constrained portfolio optimization**
  (src/optimize/portfolio.c) — a hardcoded objective template built on
  entry 1's SFS engine (project-then-evaluate against a Sharpe-ratio
  objective); not itself a port of a separate published algorithm.
