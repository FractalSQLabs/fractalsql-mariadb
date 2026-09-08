# Build profile: modern glibc

One shipped profile, matching the vendored core drop in
`include/linux-<arch>/`:

| Profile | glibc | Base | Use when |
|---|---|---|---|
| modern | 2.34 | `rockylinux:9` | RHEL 9+, Ubuntu 22.04+, Debian 12+, SLES 15 SP5+ |

## Invocation

```bash
./build.sh amd64                 # -> dist/amd64/fractalsql.so
```