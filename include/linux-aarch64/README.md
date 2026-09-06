# fractalsql-core 2.0.18 — Community Edition (linux-aarch64-glibc-2.34)

This tarball ships the FractalSQL Core Community Edition libraries
for linux-aarch64-glibc-2.34, built and validated by the foundry's CI on the v2.0.18
release tag.

## Contents

```
.
├── README.md                     (this file)
├── LICENSE                       (MIT — foundry's own copyright)
├── THIRD-PARTY-NOTICES.md        (third-party attributions:
│                                  SFS Salimi (BSD-2-Clause), LuaJIT (MIT))
├── VERSION                       (commit SHA + build host
│                                  fingerprint + ISO timestamp)
├── fractalsql.h                  (public C API)
├── fractalsql_sql.h              (sovereign-tier SQL public API)
├── sfs_core_c.h                  (internal SFS header)
├── sfs_core_bc.h                 (LuaJIT bytecode bundle)
├── libfractalsql-community-minimal-c
├── libfractalsql-community-sovereign-c                              (.a + .so each)
└── .artifacts.sha256             (per-file integrity manifest)
```

## Verification

Verify the tarball matches the SHA256SUMS published on the release
page:

```bash
sha256sum --check SHA256SUMS    # downloads/SHA256SUMS in your release dir
```

After extracting, verify the per-file manifest inside the tarball:

```bash
cd fractalsql-core-2.0.18-community-linux-aarch64-glibc-2.34/
sha256sum --check .artifacts.sha256
```

Both checks must pass before the bytes are trusted for deployment.

## Linking

Static link (one .a per edition variant):

```
gcc your_app.c -L. \
    -l:libfractalsql-community-sovereign-c.a \
    -lpthread -lm -ldl
```

Dynamic link (.so co-located with the executable or in LD_LIBRARY_PATH):

```
gcc your_app.c -L. -lfractalsql-community-sovereign-c
LD_LIBRARY_PATH=. ./a.out
```

The minimal-c variant has the same ABI as the sovereign-c variant but
omits the SQL surface. Link against minimal-c if your application
does not need fsql_sql_exec() and friends.

## Source + issue tracker

  - Source: https://github.com/dnj/fractalsql-core (tag v2.0.18)
  - Issues / security disclosures: see SECURITY.md in the source tree
  - License: MIT (this LICENSE file). See THIRD-PARTY-NOTICES.md for
    bundled-component attributions.

## Edition note

The Community Edition libraries expose the public C ABI
documented in fractalsql.h (and fractalsql_sql.h for sovereign-tier).
Both editions ship the same public API; the implementation behind it
differs. Switching from community to enterprise libraries is a
re-link, not a code change.
