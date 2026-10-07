/* SPDX-License-Identifier: Apache-2.0 */
/* SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fsqlctl: control-plane CLI and conformance client for fractalsqld.
 *
 * It speaks FSQ protocol v2 as written in protocol/SPEC.md. It includes no
 * header from the shim, the daemon, or the core, and it does not depend on
 * MariaDB. Frame authentication uses OpenSSL's HMAC.
 *
 * Usage: fsqlctl [-s socket] [-k keyfile] COMMAND [ARGS...]
 *   ping                        check that the daemon answers
 *   version                     print the daemon version
 *   check                       check the key file and the socket, then ping
 *   call FUNCTION [ARG...]      run a function and print its result
 *   cancel HANDLE_ID            mark a handle's next call to fail with BUSY
 *
 * Call arguments are s:TEXT (string), i:N (integer), r:X (real), or NULL.
 * A plain word is a string. Exit status: 0 success, 1 failure reported by
 * the daemon or the transport, 2 usage, 3 authentication or a closed
 * connection, 4 unknown function.
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>

#include "fsqlctl_functions.h"

#define FSQC_HDR          32u
#define FSQC_TAG          32u
#define FSQC_MAX_PAYLOAD  ((uint32_t) 80u * 1024u * 1024u)
#define FSQC_MAX_ARGS     64u
#define FSQC_MAX_FN_NAME  63u
#define FSQC_VERSION      2u
#define FSQC_MAX_KEY      64u
#define FSQC_KEY_TEXT     1024u

#define OP_PING     0x0001u
#define OP_VERSION  0x0002u
#define OP_INIT     0x0010u
#define OP_CALL     0x0011u
#define OP_DEINIT   0x0012u
#define OP_CANCEL   0x0013u
#define OP_RELOAD   0x0014u

#define T_NULL    0u
#define T_STRING  1u
#define T_INT     2u
#define T_REAL    3u

#define EXIT_OK       0
#define EXIT_FAIL     1
#define EXIT_USAGE    2
#define EXIT_AUTH     3
#define EXIT_NOFN     4

#define DEFAULT_SOCKET "/run/fractalsql/fractalsqld.sock"
#define DEFAULT_KEY    "/etc/fractalsql/hmac.key"

static const char *g_socket = NULL;
static const char *g_keyfile = NULL;
static uint8_t g_key[FSQC_MAX_KEY];
static size_t g_keylen = 0;

struct reply {
    uint32_t status;
    int32_t core_rc;
    uint8_t *body;
    uint32_t blen;
};

/* ------------------------------------------------------------------ */
/* Little-endian encoding                                              */
/* ------------------------------------------------------------------ */

static void put16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t) v;
    p[1] = (uint8_t) (v >> 8);
}

static void put32(uint8_t *p, uint32_t v) {
    for (int i = 0; i < 4; i++) p[i] = (uint8_t) (v >> (8 * i));
}

static void put64(uint8_t *p, uint64_t v) {
    for (int i = 0; i < 8; i++) p[i] = (uint8_t) (v >> (8 * i));
}

static uint16_t get16(const uint8_t *p) {
    return (uint16_t) (p[0] | (p[1] << 8));
}

static uint32_t get32(const uint8_t *p) {
    return (uint32_t) p[0] | ((uint32_t) p[1] << 8) |
           ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

static uint64_t get64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

/* ------------------------------------------------------------------ */
/* Key file                                                            */
/* ------------------------------------------------------------------ */

static int hex_val(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Reads the hex key file. Whitespace is ignored. Returns 0 on success. */
static int load_key(const char *path) {
    FILE *f = fopen(path, "r");
    char text[FSQC_KEY_TEXT];
    size_t n = 0;
    int hi = -1, c;

    if (!f) return -1;
    while ((c = fgetc(f)) != EOF) {
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') continue;
        if (n == sizeof(text)) { fclose(f); return -1; }
        text[n++] = (char) c;
    }
    fclose(f);
    if (n == 0 || n % 2 != 0 || n / 2 > FSQC_MAX_KEY) return -1;

    g_keylen = 0;
    for (size_t i = 0; i < n; i++) {
        int v = hex_val((unsigned char) text[i]);
        if (v < 0) return -1;
        if (hi < 0) {
            hi = v;
        } else {
            g_key[g_keylen++] = (uint8_t) ((hi << 4) | v);
            hi = -1;
        }
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Socket I/O                                                          */
/* ------------------------------------------------------------------ */

static int connect_daemon(const char *path) {
    struct sockaddr_un sa;
    int fd;
    if (strlen(path) >= sizeof(sa.sun_path)) {
        fprintf(stderr, "fsqlctl: socket path is too long: %s\n", path);
        return -1;
    }
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        fprintf(stderr, "fsqlctl: socket(): %s\n", strerror(errno));
        return -1;
    }
    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    strcpy(sa.sun_path, path);
    if (connect(fd, (struct sockaddr *) &sa, sizeof(sa)) != 0) {
        fprintf(stderr, "fsqlctl: cannot reach fractalsqld at %s: %s\n", path, strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static int write_all(int fd, const uint8_t *p, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += w;
        n -= (size_t) w;
    }
    return 0;
}

static int read_all(int fd, uint8_t *p, size_t n) {
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (r == 0) return -1;
        p += r;
        n -= (size_t) r;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* Frames                                                              */
/* ------------------------------------------------------------------ */

/* Tag = HMAC-SHA256(key, header || payload). */
static int frame_tag(const uint8_t *hdr, const uint8_t *payload, uint32_t plen, uint8_t tag[FSQC_TAG]) {
    uint8_t *msg = malloc(FSQC_HDR + (size_t) plen);
    unsigned int outlen = 0;
    if (!msg) return -1;
    memcpy(msg, hdr, FSQC_HDR);
    if (plen) memcpy(msg + FSQC_HDR, payload, plen);
    HMAC(EVP_sha256(), g_key, (int) g_keylen, msg, FSQC_HDR + (size_t) plen, tag, &outlen);
    free(msg);
    return outlen == FSQC_TAG ? 0 : -1;
}

enum rt {
    RT_OK = 0,
    RT_IO = -1,
    RT_CLOSED = -2,
    RT_AUTH = -3,
    RT_BAD = -4
};

/* One request and its response. The daemon closes the connection on a bad
 * frame or a bad tag, so a closed connection is reported as RT_CLOSED. */
static int roundtrip(int fd, uint16_t opcode, const uint8_t *req, uint32_t rlen, struct reply *out) {
    static uint32_t next_id = 1;
    uint32_t reqid = next_id++;
    uint8_t hdr[FSQC_HDR], tag[FSQC_TAG], rhdr[FSQC_HDR], rtag[FSQC_TAG], want[FSQC_TAG];
    uint8_t *rpay = NULL;
    uint32_t plen;

    memcpy(hdr, "FSQ1", 4);
    put16(hdr + 4, FSQC_VERSION);
    put16(hdr + 6, opcode);
    put32(hdr + 8, 0);
    put32(hdr + 12, reqid);
    put64(hdr + 16, 0);
    put32(hdr + 24, FSQC_TAG);
    put32(hdr + 28, rlen);

    if (rlen > FSQC_MAX_PAYLOAD || frame_tag(hdr, req, rlen, tag) != 0) return RT_IO;
    if (write_all(fd, hdr, FSQC_HDR) != 0 || write_all(fd, tag, FSQC_TAG) != 0 ||
        (rlen && write_all(fd, req, rlen) != 0))
        return RT_IO;

    if (read_all(fd, rhdr, FSQC_HDR) != 0) return RT_CLOSED;
    if (memcmp(rhdr, "FSQ1", 4) != 0 || get16(rhdr + 4) != FSQC_VERSION || get32(rhdr + 24) != FSQC_TAG)
        return RT_BAD;
    plen = get32(rhdr + 28);
    if (plen > FSQC_MAX_PAYLOAD) return RT_BAD;
    if (!(get32(rhdr + 8) & 1u) || get32(rhdr + 12) != reqid) return RT_BAD;

    if (read_all(fd, rtag, FSQC_TAG) != 0) return RT_CLOSED;
    if (plen) {
        rpay = malloc(plen);
        if (!rpay || read_all(fd, rpay, plen) != 0) {
            free(rpay);
            return RT_CLOSED;
        }
    }
    if (frame_tag(rhdr, rpay, plen, want) != 0 || CRYPTO_memcmp(rtag, want, FSQC_TAG) != 0) {
        free(rpay);
        return RT_AUTH;
    }
    if (plen < 8) {
        free(rpay);
        return RT_BAD;
    }
    out->status = get32(rpay);
    out->core_rc = (int32_t) get32(rpay + 4);
    out->blen = plen - 8;
    out->body = malloc(out->blen ? out->blen : 1);
    if (!out->body) {
        free(rpay);
        return RT_IO;
    }
    if (out->blen) memcpy(out->body, rpay + 8, out->blen);
    free(rpay);
    return RT_OK;
}

static const char *status_name(uint32_t s) {
    switch (s) {
        case 0: return "OK";
        case 1: return "ARGS";
        case 2: return "LIMIT";
        case 3: return "CORE";
        case 4: return "NOT_LICENSED";
        case 5: return "AUTH";
        case 6: return "INTERNAL";
        case 7: return "NOTSUP";
        case 8: return "BUSY";
        default: return "UNKNOWN";
    }
}

/* Maps a transport result to an exit status and a message. */
static int transport_fail(int rc, const char *what) {
    switch (rc) {
        case RT_CLOSED:
            fprintf(stderr, "fsqlctl: %s: the daemon closed the connection (authentication failed or bad frame)\n", what);
            return EXIT_AUTH;
        case RT_AUTH:
            fprintf(stderr, "fsqlctl: %s: response authentication failed (check the key file)\n", what);
            return EXIT_AUTH;
        case RT_BAD:
            fprintf(stderr, "fsqlctl: %s: malformed response from fractalsqld\n", what);
            return EXIT_FAIL;
        default:
            fprintf(stderr, "fsqlctl: %s: I/O error: %s\n", what, strerror(errno));
            return EXIT_FAIL;
    }
}

/* Checks a response's status. Returns EXIT_OK for OK, otherwise an exit code
 * after printing the daemon's message. */
static int status_fail(const struct reply *r, const char *what) {
    if (r->status == 0) return EXIT_OK;
    fprintf(stderr, "fsqlctl: %s failed: %s", what, status_name(r->status));
    if (r->status == 7) fprintf(stderr, " (unknown opcode or function)");
    if (r->blen) fprintf(stderr, ": %.*s", (int) r->blen, (const char *) r->body);
    fputc('\n', stderr);
    return EXIT_FAIL;
}

/* ------------------------------------------------------------------ */
/* Commands                                                            */
/* ------------------------------------------------------------------ */

static int cmd_ping(int fd) {
    struct reply r;
    int rc = roundtrip(fd, OP_PING, NULL, 0, &r);
    if (rc != RT_OK) return transport_fail(rc, "ping");
    if (r.status != 0 || r.blen != 2) {
        int code = status_fail(&r, "ping");
        free(r.body);
        return code ? code : EXIT_FAIL;
    }
    printf("pong: protocol %u\n", (unsigned) get16(r.body));
    free(r.body);
    return EXIT_OK;
}

static int cmd_version(int fd) {
    struct reply r;
    int rc = roundtrip(fd, OP_VERSION, NULL, 0, &r);
    if (rc != RT_OK) return transport_fail(rc, "version");
    if (r.status != 0) {
        int code = status_fail(&r, "version");
        free(r.body);
        return code;
    }
    printf("%.*s\n", (int) r.blen, (const char *) r.body);
    free(r.body);
    return EXIT_OK;
}

static int cmd_check(void) {
    struct stat st;
    int fd, code;
    struct reply r;

    if (stat(g_keyfile, &st) != 0) {
        fprintf(stderr, "fsqlctl: key file %s: %s\n", g_keyfile, strerror(errno));
        return EXIT_FAIL;
    }
    if (st.st_mode & 077) {
        fprintf(stderr, "fsqlctl: warning: key file %s is readable by group or others (mode %03o)\n",
                g_keyfile, (unsigned) (st.st_mode & 0777));
    }
    if (load_key(g_keyfile) != 0) {
        fprintf(stderr, "fsqlctl: key file %s is not a hex key of 2 to 128 digits\n", g_keyfile);
        return EXIT_FAIL;
    }
    printf("key file: ok (%zu bytes)\n", g_keylen);

    fd = connect_daemon(g_socket);
    if (fd < 0) return EXIT_FAIL;
    printf("socket: ok (%s)\n", g_socket);

    {
        int rc = roundtrip(fd, OP_PING, NULL, 0, &r);
        if (rc != RT_OK) {
            code = transport_fail(rc, "check");
        } else if (r.status != 0 || r.blen != 2) {
            code = r.status ? status_fail(&r, "check") : EXIT_FAIL;
            if (!r.status) fprintf(stderr, "fsqlctl: check: malformed ping reply\n");
            free(r.body);
        } else {
            printf("ping: ok (protocol %u)\n", (unsigned) get16(r.body));
            free(r.body);
            code = EXIT_OK;
        }
    }
    close(fd);
    return code;
}

/* A parsed call argument. */
struct farg {
    char kind;          /* 's', 'i', 'r' or 'n' */
    const char *text;
};

static int parse_arg(const char *s, struct farg *a) {
    if (strcmp(s, "NULL") == 0) {
        a->kind = 'n';
        a->text = NULL;
        return 0;
    }
    if (strlen(s) >= 2 && s[1] == ':' && (s[0] == 's' || s[0] == 'i' || s[0] == 'r')) {
        a->kind = s[0];
        a->text = s + 2;
        return 0;
    }
    a->kind = 's';
    a->text = s;
    return 0;
}

static uint32_t wire_type(char kind) {
    switch (kind) {
        case 'i': return T_INT;
        case 'r': return T_REAL;
        case 'n': return T_STRING;
        default:  return T_STRING;
    }
}

/* Appends one TLV argument to buf (type, is_null, len, bytes). Returns the
 * new length, or 0 on a bad integer or real. */
static size_t put_tlv(uint8_t *buf, size_t off, const struct farg *a, const char **err) {
    uint8_t vbuf[8];
    const uint8_t *val = NULL;
    uint32_t vlen = 0;

    buf[off] = (uint8_t) wire_type(a->kind);
    buf[off + 1] = (uint8_t) (a->kind == 'n' ? 1 : 0);
    if (a->kind == 'i') {
        char *end = NULL;
        long long v;
        errno = 0;
        v = strtoll(a->text, &end, 10);
        if (errno != 0 || end == a->text || *end != '\0') { *err = "integer argument is not a valid integer"; return 0; }
        put64(vbuf, (uint64_t) v);
        val = vbuf;
        vlen = 8;
    } else if (a->kind == 'r') {
        char *end = NULL;
        double d;
        uint64_t bits;
        errno = 0;
        d = strtod(a->text, &end);
        if (errno != 0 || end == a->text || *end != '\0') { *err = "real argument is not a valid number"; return 0; }
        memcpy(&bits, &d, 8);
        put64(vbuf, bits);
        val = vbuf;
        vlen = 8;
    } else if (a->kind == 's') {
        val = (const uint8_t *) a->text;
        vlen = (uint32_t) strlen(a->text);
    }
    put32(buf + off + 2, vlen);
    if (vlen) memcpy(buf + off + 6, val, vlen);
    return off + 6 + vlen;
}

/* Upper bound on one TLV entry's size, for buffer sizing. */
static size_t tlv_bound(const struct farg *a) {
    if (a->kind == 'n') return 6;
    if (a->kind == 'i' || a->kind == 'r') return 14;
    return 6 + strlen(a->text);
}

static int cmd_call(int fd, const char *name, int nargs, char **argv) {
    uint8_t namelen;
    int found = 0;
    struct farg *args;
    uint8_t *req;
    size_t reqcap = 0, off;
    struct reply r;
    uint64_t handle;
    uint32_t nres;
    int rc, code;
    const char *err = NULL;

    for (size_t i = 0; i < sizeof(fsqlctl_fns) / sizeof(fsqlctl_fns[0]); i++) {
        if (strcmp(fsqlctl_fns[i], name) == 0) { found = 1; break; }
    }
    if (!found) {
        fprintf(stderr, "fsqlctl: unknown function %s\n", name);
        return EXIT_NOFN;
    }
    if (strlen(name) > FSQC_MAX_FN_NAME) {
        fprintf(stderr, "fsqlctl: function name is too long\n");
        return EXIT_USAGE;
    }
    namelen = (uint8_t) strlen(name);
    if ((unsigned) nargs > FSQC_MAX_ARGS) {
        fprintf(stderr, "fsqlctl: at most %u arguments\n", (unsigned) FSQC_MAX_ARGS);
        return EXIT_USAGE;
    }

    args = calloc(nargs ? (size_t) nargs : 1, sizeof(*args));
    if (!args) return EXIT_FAIL;
    for (int i = 0; i < nargs; i++) parse_arg(argv[i], &args[i]);

    /* UDF_INIT: namelen, name, argument count, TLVs. The daemon takes the
     * declared types from these TLVs, and returns them in the reply. */
    for (int i = 0; i < nargs; i++) reqcap += tlv_bound(&args[i]);
    req = malloc(1 + namelen + 4 + reqcap);
    if (!req) { free(args); return EXIT_FAIL; }
    req[0] = namelen;
    memcpy(req + 1, name, namelen);
    put32(req + 1 + namelen, (uint32_t) nargs);
    off = 1 + (size_t) namelen + 4;
    for (int i = 0; i < nargs; i++) {
        off = put_tlv(req, off, &args[i], &err);
        if (off == 0) {
            fprintf(stderr, "fsqlctl: argument %d: %s\n", i + 1, err);
            free(req); free(args);
            return EXIT_USAGE;
        }
    }
    rc = roundtrip(fd, OP_INIT, req, (uint32_t) off, &r);
    free(req);
    if (rc != RT_OK) { free(args); return transport_fail(rc, "init"); }
    if (r.status != 0) {
        code = status_fail(&r, "init");
        free(r.body); free(args);
        return code;
    }
    if (r.blen < 17) {
        fprintf(stderr, "fsqlctl: malformed init reply\n");
        free(r.body); free(args);
        return EXIT_FAIL;
    }
    handle = get64(r.body);
    nres = get32(r.body + 13);
    if (nres != (uint32_t) nargs || r.blen != 17 + nres) {
        fprintf(stderr, "fsqlctl: init reply does not match the argument count\n");
        free(r.body); free(args);
        return EXIT_FAIL;
    }
    free(r.body);

    /* UDF_CALL: namelen, name, handle, count, TLVs. */
    reqcap = 1 + namelen + 12;
    for (int i = 0; i < nargs; i++) reqcap += tlv_bound(&args[i]);
    req = malloc(reqcap);
    if (!req) { free(args); return EXIT_FAIL; }
    req[0] = namelen;
    memcpy(req + 1, name, namelen);
    put64(req + 1 + namelen, handle);
    put32(req + 1 + namelen + 8, (uint32_t) nargs);
    off = 1 + (size_t) namelen + 12;
    for (int i = 0; i < nargs; i++) off = put_tlv(req, off, &args[i], &err);
    rc = roundtrip(fd, OP_CALL, req, (uint32_t) off, &r);
    free(req);
    if (rc != RT_OK) { free(args); return transport_fail(rc, "call"); }
    if (r.status != 0) {
        code = status_fail(&r, "call");
        free(r.body);
        goto deinit;
    }
    if (r.blen < 6 || r.blen != 6 + get32(r.body + 2)) {
        fprintf(stderr, "fsqlctl: malformed call reply\n");
        free(r.body);
        code = EXIT_FAIL;
        goto deinit;
    }
    if (r.body[1]) {
        printf("NULL\n");
    } else if (r.body[0] == T_INT && get32(r.body + 2) == 8) {
        printf("%lld\n", (long long) (int64_t) get64(r.body + 6));
    } else if (r.body[0] == T_REAL && get32(r.body + 2) == 8) {
        uint64_t bits = get64(r.body + 6);
        double d;
        memcpy(&d, &bits, 8);
        printf("%.17g\n", d);
    } else {
        printf("%.*s\n", (int) get32(r.body + 2), (const char *) r.body + 6);
    }
    free(r.body);
    code = EXIT_OK;

deinit:
    {
        uint8_t dreq[8];
        struct reply dr;
        put64(dreq, handle);
        if (roundtrip(fd, OP_DEINIT, dreq, 8, &dr) == RT_OK) free(dr.body);
    }
    free(args);
    return code;
}

static int cmd_cancel(int fd, const char *idtext) {
    uint8_t req[8];
    char *end = NULL;
    unsigned long long id;
    struct reply r;
    int rc, code;

    errno = 0;
    id = strtoull(idtext, &end, 10);
    if (errno != 0 || end == idtext || *end != '\0') {
        fprintf(stderr, "fsqlctl: cancel: '%s' is not a valid handle id\n", idtext);
        return EXIT_USAGE;
    }
    put64(req, (uint64_t) id);
    rc = roundtrip(fd, OP_CANCEL, req, 8, &r);
    if (rc != RT_OK) return transport_fail(rc, "cancel");
    code = status_fail(&r, "cancel");
    free(r.body);
    if (code == EXIT_OK) printf("cancelled: handle %llu\n", id);
    return code;
}

/* Re-parse the daemon's config file into a fresh snapshot. All-or-nothing
 * on the daemon side; an old daemon (no RELOAD opcode) answers NOTSUP. */
static int cmd_reload(int fd) {
    struct reply r;
    int rc, code;
    rc = roundtrip(fd, OP_RELOAD, NULL, 0, &r);
    if (rc != RT_OK) return transport_fail(rc, "reload");
    code = status_fail(&r, "reload");
    free(r.body);
    if (code == EXIT_OK) printf("reloaded: configuration swapped in\n");
    return code;
}

/* ------------------------------------------------------------------ */
/* Main                                                                */
/* ------------------------------------------------------------------ */

static void usage(FILE *out) {
    fprintf(out,
            "usage: fsqlctl [-s socket] [-k keyfile] COMMAND [ARGS...]\n"
            "  ping                      check that the daemon answers\n"
            "  version                   print the daemon version\n"
            "  check                     check the key file and the socket, then ping\n"
            "  call FUNCTION [ARG...]    run a function; args are s:TEXT, i:N, r:X, NULL\n"
            "  cancel HANDLE_ID          mark a handle: its running in-repo work stops, its next call fails with BUSY (one-shot)\n"
            "  reload                    re-read the daemon's config file (socket_path/hmac_key_file changes refused)\n"
            "defaults: socket %s (env FSQLCTL_SOCKET), key %s (env FSQLCTL_KEY)\n",
            DEFAULT_SOCKET, DEFAULT_KEY);
}

int main(int argc, char **argv) {
    int opt, fd, code;
    const char *cmd;

    g_socket = getenv("FSQLCTL_SOCKET");
    g_keyfile = getenv("FSQLCTL_KEY");
    if (!g_socket) g_socket = DEFAULT_SOCKET;
    if (!g_keyfile) g_keyfile = DEFAULT_KEY;

    while ((opt = getopt(argc, argv, "s:k:h")) != -1) {
        switch (opt) {
            case 's': g_socket = optarg; break;
            case 'k': g_keyfile = optarg; break;
            case 'h': usage(stdout); return EXIT_OK;
            default:  usage(stderr); return EXIT_USAGE;
        }
    }
    if (optind >= argc) { usage(stderr); return EXIT_USAGE; }
    cmd = argv[optind];

    if (strcmp(cmd, "check") == 0) return cmd_check();

    if (load_key(g_keyfile) != 0) {
        fprintf(stderr, "fsqlctl: cannot read a hex key from %s\n", g_keyfile);
        return EXIT_FAIL;
    }
    fd = connect_daemon(g_socket);
    if (fd < 0) return EXIT_FAIL;

    if (strcmp(cmd, "ping") == 0) {
        code = cmd_ping(fd);
    } else if (strcmp(cmd, "version") == 0) {
        code = cmd_version(fd);
    } else if (strcmp(cmd, "call") == 0) {
        if (optind + 1 >= argc) {
            fprintf(stderr, "fsqlctl: call needs a function name\n");
            code = EXIT_USAGE;
        } else {
            code = cmd_call(fd, argv[optind + 1], argc - optind - 2, argv + optind + 2);
        }
    } else if (strcmp(cmd, "cancel") == 0) {
        if (optind + 1 >= argc) {
            fprintf(stderr, "fsqlctl: cancel needs a handle id\n");
            code = EXIT_USAGE;
        } else {
            code = cmd_cancel(fd, argv[optind + 1]);
        }
    } else if (strcmp(cmd, "reload") == 0) {
        code = cmd_reload(fd);
    } else {
        fprintf(stderr, "fsqlctl: unknown command %s\n", cmd);
        usage(stderr);
        code = EXIT_USAGE;
    }
    close(fd);
    return code;
}
