# Build profiles: modern vs legacy

Both packages expose the same binary contract; they differ only in
the glibc ceiling their embedded `libfractalsql-*.a` was compiled
for.

| Profile | glibc | Base | Artifact suffix | Use when |
|---|---|---|---|---|
| modern (default) | 2.34 | `rockylinux:9` | *(none)* | RHEL 9+, Ubuntu 22.04+, Debian 12+, SLES 15 SP5+ |
| legacy | 2.28 | `quay.io/pypa/manylinux_2_28_x86_64` | `-legacy` | RHEL 8, Ubuntu 20.04, Debian 10, SLES 15 base |

## How `build.sh` reads the profile

`build.sh` reads `PROFILE` from env or the `--profile=` CLI flag,
defaulting to `modern`. The matching `PROFILE` Dockerfile build-arg
controls the build stage. When `PROFILE=legacy`, the build:

1. Switches the base image to `quay.io/pypa/manylinux_2_28_x86_64`
2. Links `include/libfractalsql-community-minimal-c-legacy.a`
   instead of the modern `.a`
3. Tags the resulting binary with the `-legacy` suffix

## Invocation

```bash
./build.sh amd64                 # modern
PROFILE=legacy ./build.sh amd64  # -> dist/amd64/fractalsql-legacy.so
```

## Consumer's perspective

Consumers install from the matching channel:

```bash
# RHEL 9:
sudo yum install fractalsql-mariadb

# RHEL 8:
sudo yum install fractalsql-mariadb-legacy
```

`yum` / `dnf` resolve naturally: users pick the channel that
matches their host glibc. No runtime detection, no runtime
surprises.

## Status

- `build.sh`: `PROFILE` arg implemented.
- `scripts/package.sh`: reads `$PROFILE` and appends `-legacy` to
  the package name and binary filename when set, producing the
  `.deb`/`.rpm` for whichever channel `build.sh` already built.
