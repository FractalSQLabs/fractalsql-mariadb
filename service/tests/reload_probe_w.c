/* SPDX-License-Identifier: Apache-2.0 */
/* SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * service/tests/reload_probe_w.c - the Windows named-pipe client for
 * OP_RELOAD. fsqlctl is a POSIX-only CLI (AF_UNIX transport, getopt), but
 * the reload path itself is cross-platform: the daemon serves RELOAD over
 * the named pipe (fractalsqld.c's handle_reload, SPEC.md's reload
 * section). This probe speaks the same wire format as frame_test.c over
 * CreateFileA, so build_test.ps1's gate 29 proves the conf live-reload
 * scenario the way build_test.sh does with fsqlctl.
 *
 * Usage: reload_probe_w <pipe_name> <hmac_key_file>
 * Sends RELOAD with an empty payload, prints the reply body text, and
 * exits 0 iff the daemon answered with status OK.
 */
#ifndef _WIN32
#error reload_probe_w targets the Windows named-pipe transport; use frame_test.c (with fsqlctl over AF_UNIX) on POSIX
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

#include "../common/fsq_sha256.h"
#include "../protocol/fsq_protocol.h"

static HANDLE
open_pipe(const char *path)
{
    HANDLE h = INVALID_HANDLE_VALUE;
    int tries;
    for (tries = 0; tries < 3; tries++) {
        /* Same SQOS flags as the shim (fractalsql_shim.c): without
         * SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION the daemon's
         * cross-account vetting falls back to ImpersonateNamedPipeClient,
         * which fails with ERROR_CANNOT_IMPERSONATE (1368) and refuses
         * the connection. */
        h = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                        OPEN_EXISTING,
                        FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                        NULL);
        if (h != INVALID_HANDLE_VALUE) return h;
        if (GetLastError() != ERROR_PIPE_BUSY) break;
        WaitNamedPipeA(path, 5000);
    }
    fprintf(stderr, "reload_probe_w: cannot connect to %s (error %lu)\n",
            path, (unsigned long) GetLastError());
    return INVALID_HANDLE_VALUE;
}

static int
write_all(HANDLE h, const void *buf, size_t len)
{
    const char *p = (const char *) buf;
    while (len > 0) {
        DWORD w;
        if (!WriteFile(h, p, (DWORD) len, &w, NULL) || w == 0) return 0;
        p += w;
        len -= w;
    }
    return 1;
}

static int
read_all(HANDLE h, void *buf, size_t len)
{
    char *p = (char *) buf;
    while (len > 0) {
        DWORD r;
        if (!ReadFile(h, p, (DWORD) len, &r, NULL) || r == 0) return 0;
        p += r;
        len -= r;
    }
    return 1;
}

/* Reads the hex key file the same way the daemon and fsqlctl do: hex
 * digits only, whitespace ignored, 2..128 digits (fsqlctl's limit) --
 * 2..64 decoded bytes. Returns the byte length, or 0 on failure. */
static size_t
load_key(const char *path, uint8_t key[64])
{
    uint8_t digits[128];
    char text[4096];
    size_t i, n, nd = 0;
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    n = fread(text, 1, sizeof(text), f);
    fclose(f);
    for (i = 0; i < n; i++) {
        char c = text[i];
        if (c == '\n' || c == '\r' || c == ' ' || c == '\t') continue;
        if (nd >= sizeof(digits)) return 0;
        if (c >= '0' && c <= '9') digits[nd] = (uint8_t) (c - '0');
        else if (c >= 'a' && c <= 'f') digits[nd] = (uint8_t) (c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') digits[nd] = (uint8_t) (c - 'A' + 10);
        else return 0;
        nd++;
    }
    if (nd < 2 || (nd & 1)) return 0;
    for (i = 0; i < nd / 2; i++)
        key[i] = (uint8_t) ((digits[2 * i] << 4) | digits[2 * i + 1]);
    return nd / 2;
}

/* Sends the header, then the HMAC tag, then (there is none) the payload.
 * frame_test.c uses the same three-write order over AF_UNIX; the daemon
 * reads the stream sequentially on both transports. */
static int
send_reload(HANDLE h, const uint8_t *key, size_t klen)
{
    uint8_t hdr[FSQ_HEADER_LEN], tag[FSQ_TAG_LEN];
    struct fsq_header hq;
    memset(&hq, 0, sizeof(hq));
    hq.version = FSQ_PROTOCOL_VERSION;
    hq.opcode = FSQ_OP_RELOAD;
    hq.request_id = 1;
    hq.context = 0;
    hq.auth_len = FSQ_TAG_LEN;
    hq.payload_len = 0;
    fsq_header_encode(hdr, &hq);
    fsq_hmac_sha256(key, klen, hdr, FSQ_HEADER_LEN, tag);
    return write_all(h, hdr, FSQ_HEADER_LEN) && write_all(h, tag, FSQ_TAG_LEN);
}

int
main(int argc, char **argv)
{
    uint8_t key[64];
    size_t klen;
    HANDLE h;
    uint32_t status = FSQ_ERR_INTERNAL;

    if (argc != 3) {
        fprintf(stderr, "usage: reload_probe_w <pipe> <hex key file>\n");
        return 2;
    }
    klen = load_key(argv[2], key);
    if (klen == 0) {
        fprintf(stderr, "reload_probe_w: cannot read a hex key from %s\n", argv[2]);
        return 2;
    }
    h = open_pipe(argv[1]);
    if (h == INVALID_HANDLE_VALUE) return 2;
    if (!send_reload(h, key, klen)) return 2;

    {
        uint8_t rhdr[FSQ_HEADER_LEN], rtag[FSQ_TAG_LEN], *rpay;
        struct fsq_header rr;
        uint32_t plen;
        if (!read_all(h, rhdr, FSQ_HEADER_LEN) ||
            fsq_header_decode(rhdr, &rr) != 0 ||
            !(rr.flags & FSQ_FLAG_RESPONSE) ||
            !read_all(h, rtag, FSQ_TAG_LEN)) {
            fprintf(stderr, "reload_probe_w: no protocol-valid reply\n");
            return 1;
        }
        plen = rr.payload_len;
        rpay = malloc(plen ? plen : 1);
        if (plen && !read_all(h, rpay, plen)) {
            fprintf(stderr, "reload_probe_w: truncated reply\n");
            free(rpay);
            return 1;
        }
        {
            uint8_t want[FSQ_TAG_LEN];
            uint8_t *msg = malloc(FSQ_HEADER_LEN + plen);
            memcpy(msg, rhdr, FSQ_HEADER_LEN);
            if (plen) memcpy(msg + FSQ_HEADER_LEN, rpay, plen);
            fsq_hmac_sha256(key, klen, msg, FSQ_HEADER_LEN + plen, want);
            free(msg);
            if (!fsq_ct_equal(rtag, want, FSQ_TAG_LEN)) {
                fprintf(stderr, "reload_probe_w: reply tag mismatch\n");
                free(rpay);
                return 1;
            }
        }
        status = plen >= 4 ? fsq_get_u32(rpay) : FSQ_ERR_INTERNAL;
        /* Body after the status/core_rc 8-byte prefix (SPEC.md section 3). */
        if (plen > 8) fwrite(rpay + 8, 1, plen - 8, stdout);
        putchar('\n');
        free(rpay);
    }
    CloseHandle(h);
    return status == FSQ_OK ? 0 : 1;
}