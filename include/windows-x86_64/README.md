# fractalsql-core 2.0.18 - Community Edition (windows-x86_64-msvc)

This tarball ships the FractalSQL Core Community Edition libraries
for windows-x86_64-msvc, built and validated by the foundry's CI on the v2.0.18
release tag.

## Contents

```
.\
├── README.md                     (this file)
├── LICENSE                       (Apache-2.0 - foundry's own copyright)
├── THIRD-PARTY-NOTICES.md        (third-party attributions)
├── VERSION                       (commit SHA + build host
│                                  fingerprint + ISO timestamp)
├── fractalsql.h                  (public C API)
├── fractalsql_sql.h              (sovereign-tier SQL public API)
├── sfs_core_c.h                  (internal SFS header)
├── fractalsql-community-minimal-c.lib    (static /MT - embedders)
├── fractalsql-community-sovereign-c.lib  (static /MT, v2 sovereign)
├── fractalsql-community-minimal-c.dll    (loadable - direct loaders)
├── fractalsql-community-sovereign-c.dll  (loadable, v2 sovereign)
├── fractalsql-community-minimal-c-import.lib    (MSVC /MD .dll import lib)
├── fractalsql-community-sovereign-c-import.lib  (MSVC /MD .dll import lib)
└── .artifacts.sha256             (per-file integrity manifest)
```

## Verification

After downloading:

```powershell
# Verify the tarball matches SHA256SUMS on the release page
Get-FileHash -Algorithm SHA256 fractalsql-core-2.0.18-community-windows-x86_64-msvc.tar.gz

# Extract + verify the per-file manifest inside
tar -xzf fractalsql-core-2.0.18-community-windows-x86_64-msvc.tar.gz
cd fractalsql-core-2.0.18-community-windows-x86_64-msvc
Get-FileHash -Algorithm SHA256 *.dll *.lib *.h VERSION   # compare against .artifacts.sha256
```

## Linking with MSVC

Static link (one .lib per edition variant):

```
cl /MT your_app.c fractalsql-community-sovereign-c.lib
```

The /MT flag is required - these archives are built with /MT (static
CRT) and consumers MUST also use /MT or /MTd to avoid CRT mismatch.
The sovereign .lib calls BCryptGenRandom, so also link bcrypt.lib.

Dynamic load (no link step): direct loaders (.NET P/Invoke, Python
ctypes, Java FFM, node) load fractalsql-community-sovereign-c.dll at
runtime. Its export table is exactly the public ABI (pinned via .def);
it bundles the CRT (/MT) and depends only on bcrypt.dll (a core OS DLL).

Dynamic load (no link step): direct loaders (.NET P/Invoke, Python
ctypes, Java FFM, node) load fractalsql-community-sovereign-c.dll at
runtime. Its export table is exactly the public ABI (pinned via .def)
and it bundles the CRT (/MT), so it has no MSVCR* redistributable dep.

## Edition note

Both editions ship the same public C ABI documented in fractalsql.h
and fractalsql_sql.h. Implementation behind the API differs.
Switching from community to the other edition is a re-link, not a
code change.
