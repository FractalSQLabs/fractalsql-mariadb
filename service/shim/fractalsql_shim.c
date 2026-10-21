/* SPDX-License-Identifier: GPL-2.0-only */
/* SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * fractalsql.so: thin UDF shim that runs inside mariadbd. It forwards each
 * call to fractalsqld over a local socket (protocol: ../protocol). It holds
 * no core code and includes no core header. It references no OpenSSL symbol.
 */

#include <mysql.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#ifdef _WIN32
#  define _CRT_RAND_S  /* rand_s: CSPRNG for the idempotency token base */
#endif
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#  define WIN32_LEAN_AND_MEAN
#  include <Windows.h>
#  define FSQ_EXPORT __declspec(dllexport)
#  define FSQ_SHIM_CONFIG_DEFAULT "C:\\ProgramData\\FractalSQL\\fractalsql.conf"
typedef SRWLOCK fsq_mutex;
#  define FSQ_MUTEX_INIT SRWLOCK_INIT
#  define FSQ_LOCK(m) AcquireSRWLockExclusive(&(m))
#  define FSQ_UNLOCK(m) ReleaseSRWLockExclusive(&(m))
#else
#  include <fcntl.h>
#  include <pthread.h>
#  include <sys/socket.h>
#  include <sys/un.h>
#  include <unistd.h>
#  define FSQ_EXPORT
#  define FSQ_SHIM_CONFIG_DEFAULT "/etc/fractalsql/fractalsql.conf"
typedef pthread_mutex_t fsq_mutex;
#  define FSQ_MUTEX_INIT PTHREAD_MUTEX_INITIALIZER
#  define FSQ_LOCK(m) pthread_mutex_lock(&(m))
#  define FSQ_UNLOCK(m) pthread_mutex_unlock(&(m))
#endif

/* Socket handle: a descriptor on POSIX, an overlapped pipe handle on Windows. */
#ifdef _WIN32
typedef HANDLE fsq_sock;
#  define FSQ_SOCK_INVALID INVALID_HANDLE_VALUE
#  define FSQ_SOCK_VALID(s) ((s) != INVALID_HANDLE_VALUE)
#else
typedef int fsq_sock;
#  define FSQ_SOCK_INVALID (-1)
#  define FSQ_SOCK_VALID(s) ((s) >= 0)
#endif

#include "../common/fsq_sha256.h"
#include "../protocol/fsq_protocol.h"

#define FSQ_SHIM_CONFIG_ENV     "FRACTALSQL_CONFIG"
#ifdef _WIN32
/* A named pipe path, not a sun_path: the pipe namespace has its own
 * (longer) limit, and nothing here copies it into a fixed struct. */
#  define FSQ_SOCKET_PATH_MAX 108
#else
/* The socket path is copied into sockaddr_un.sun_path, whose size is
 * 108 bytes on Linux but only 104 on macOS/BSD. Sizing this buffer to
 * the field itself makes the config-load length check and the
 * fsq_connect() copy the SAME bound, so a path that does not fit is
 * refused when the config is read instead of overrunning the stack
 * later -- and the shim runs INSIDE mariadbd, where a stack smash
 * takes the whole database server down with it. */
#  define FSQ_SOCKET_PATH_MAX sizeof(((struct sockaddr_un *)0)->sun_path)
#endif
#define FSQ_IO_TIMEOUT_CALL_S   60
#define FSQ_IO_TIMEOUT_INIT_S   5
#define FSQ_MAX_ARG_BYTES       ((size_t) FSQ_MAX_PAYLOAD - 4096u)
#define FSQ_MAX_RESULT_BYTES    ((unsigned long) 64u * 1024u * 1024u)

/* ------------------------------------------------------------------ */
/* Configuration: shim reads socket_path and hmac_key_file only.       */
/* ------------------------------------------------------------------ */

static fsq_mutex g_mu = FSQ_MUTEX_INIT;
static int g_configured = 0;
static char g_socket_path[FSQ_SOCKET_PATH_MAX];
static uint8_t g_key[64];
static size_t g_key_len = 0;
static fsq_sock g_fd = FSQ_SOCK_INVALID;
static uint32_t g_next_request_id = 1;

/* ------------------------------------------------------------------ */
/* Idempotency tokens (protocol v2's context field on UDF_CALL frames) */
/* ------------------------------------------------------------------ */

/* A stateful call dropped mid-transport must not silently re-execute:
 * the shim resends its frames with the SAME token in the context u64 and
 * the daemon replays the cached response (fractalsqld.c's cache) instead
 * of running the call again. The token is g_idem_base + a per-call
 * counter. The base is fresh CSPRNG per mariadbd process, so no token can
 * accidentally replay a response cached under a PREVIOUS daemon lifetime
 * or a previous server lifetime. Minted once per logical call, held
 * constant across a call's resend attempts. */
static uint64_t g_idem_base = 0;
static uint64_t g_idem_counter = 0;

/* ------------------------------------------------------------------ */
/* The connection generation                                           */
/* ------------------------------------------------------------------ */

/* A statement handle lives on the daemon side, and the daemon scopes a
 * handle to the connection that created it: a connection's handles are
 * freed when that connection closes. The shim's socket, meanwhile, is
 * process-wide and can be replaced at any time -- the daemon closes an
 * idle connection, a transport failure drops it, the daemon restarts.
 * A statement whose handle was minted on an older connection is then
 * simply not there any more, and the next call for it would be refused
 * with "unknown handle" (the daemon's answer to a handle it cannot
 * find).
 *
 * So the shim counts connections: every time it establishes a NEW one
 * it bumps this counter, and a statement remembers the generation it
 * was opened on. When the two disagree, the statement is re-opened on
 * the current connection before its next call -- the same UDF_INIT the
 * statement started with, sent again, which yields a fresh handle for
 * the connection the calls now travel on.
 *
 * The counter is bumped under g_mu, which every roundtrip holds, so
 * there is no race between a reconnect and a statement reading it. */
static uint64_t g_conn_gen = 0;

/* Called by fsq_roundtrip before the request frame goes out, so the
 * caller can refresh whatever the frame refers to on the daemon side (a
 * statement handle, which lives and dies with its connection). Returns
 * 0 to continue; a non-zero return aborts the roundtrip. The error
 * buffer is the roundtrip's own, so the hook can say WHY the refresh
 * failed instead of leaving the caller with a bare "could not
 * re-open".
 *
 * The return value also says whether a retry could help: a refresh
 * that failed because the TRANSPORT gave up (the daemon is restarting,
 * say) is worth another attempt, while a refresh the daemon REFUSED is
 * not -- the same refusal would come back. */
#define FSQ_HOOK_OK        0
#define FSQ_HOOK_RETRY     1   /* transport-level: the attempt budget applies */
#define FSQ_HOOK_FATAL  (-1)   /* the daemon refused: retrying cannot help */

typedef int (*fsq_reconnect_fn)(void *ctx, char *err, size_t errlen);

/* The retry class comes from protocol/functions.def (r/s/e) through
 * shim_udfs.h: pure functions reconnect and re-send; stateful functions
 * get one idempotent resend of the same token; expensive/LLM calls retry
 * nothing (re-running them asks an external model the same question
 * again and costs money/time for no new information). */
#define FSQ_ATTEMPTS_R 3
#define FSQ_ATTEMPTS_S 2
#define FSQ_ATTEMPTS_E 1

static unsigned fsq_attempts_for(char cls) {
    switch (cls) {
        case 'r': return FSQ_ATTEMPTS_R;
        case 's': return FSQ_ATTEMPTS_S;
        default:  return FSQ_ATTEMPTS_E;
    }
}

static uint64_t fsq_self_pid(void) {
#ifdef _WIN32
    return (uint64_t) GetCurrentProcessId();
#else
    return (uint64_t) getpid();
#endif
}

/* Draws the per-process token base. CSPRNG where the platform has one;
 * the weak fallback mixes an address and the pid, which is only used
 * when neither is available and beats a constant for replay defense
 * (and it must stay off <time.h>: the shim's include list is a
 * license-boundary check, not a style rule -- see boundary_check.sh). */
static uint64_t fsq_idem_draw_base(void) {
#ifdef _WIN32
    unsigned int r1 = 0, r2 = 0;
    if (rand_s(&r1) == 0 && rand_s(&r2) == 0) {
        return ((uint64_t) r1 << 32) | r2;
    }
#else
    {
        uint64_t v = 0;
        FILE *f = fopen("/dev/urandom", "rb");
        if (f) {
            if (fread(&v, 1, sizeof(v), f) == sizeof(v)) { fclose(f); return v; }
            fclose(f);
        }
    }
#endif
    return ((uint64_t) (uintptr_t) &g_key * 0x9E3779B97F4A7C15ull)
         ^ (fsq_self_pid() << 47);
}

static int fsq_hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int fsq_load_key(const char *path) {
    FILE *f = fopen(path, "r");
    char buf[256];
    size_t n = 0;
    int hi = -1;
    if (!f) return -1;
    while (n < 256) {
        int c = fgetc(f);
        if (c == EOF) break;
        if (c == '\n' || c == '\r' || c == ' ' || c == '\t') continue;
        buf[n++] = (char) c;
    }
    fclose(f);
    if (n == 0 || n % 2 != 0 || n / 2 > sizeof(g_key)) return -1;
    g_key_len = 0;
    for (size_t i = 0; i < n; i++) {
        int v = fsq_hex_nibble(buf[i]);
        if (v < 0) return -1;
        if (hi < 0) hi = v;
        else { g_key[g_key_len++] = (uint8_t) ((hi << 4) | v); hi = -1; }
    }
    return 0;
}

static int fsq_load_config(void) {
    const char *path = getenv(FSQ_SHIM_CONFIG_ENV);
    char key_path[512] = "";
    char line[1024];
    FILE *f;
    if (!path) path = FSQ_SHIM_CONFIG_DEFAULT;
    f = fopen(path, "r");
    if (!f) return -1;
    while (fgets(line, sizeof(line), f)) {
        char *eq = strchr(line, '=');
        char *k, *v;
        if (!eq || line[0] == '#') continue;
        *eq = '\0';
        k = line;
        v = eq + 1;
        while (*k == ' ' || *k == '\t') k++;
        for (char *e = k + strlen(k); e > k && (e[-1] == ' ' || e[-1] == '\t'); e--) e[-1] = '\0';
        while (*v == ' ' || *v == '\t') v++;
        for (char *e = v + strlen(v); e > v && (e[-1] == '\n' || e[-1] == '\r' || e[-1] == ' '); e--) e[-1] = '\0';
        if (strcmp(k, "socket_path") == 0) {
            if (strlen(v) >= sizeof(g_socket_path)) { fclose(f); return -1; }
            strcpy(g_socket_path, v);
        } else if (strcmp(k, "hmac_key_file") == 0) {
            if (strlen(v) >= sizeof(key_path)) { fclose(f); return -1; }
            strcpy(key_path, v);
        }
    }
    fclose(f);
    if (g_socket_path[0] == '\0' || key_path[0] == '\0') return -1;
    return fsq_load_key(key_path);
}

/* ------------------------------------------------------------------ */
/* Framing                                                             */
/* ------------------------------------------------------------------ */

#ifdef _WIN32
/* Named pipe I/O is overlapped so each transfer honours the call timeout.
 * fsq_xfer returns bytes moved, or -1 on error or timeout. */
static DWORD g_io_timeout_ms = 60000;

static void fsq_sock_set_timeout(fsq_sock s, unsigned secs) {
    (void) s;
    g_io_timeout_ms = (DWORD) secs * 1000u;
}

static void fsq_sock_close(fsq_sock s) {
    if (FSQ_SOCK_VALID(s)) CloseHandle(s);
}

static int fsq_sock_alive(fsq_sock s) {
    DWORD avail = 0;
    return PeekNamedPipe(s, NULL, 0, NULL, &avail, NULL) != 0;
}

static int fsq_xfer(fsq_sock s, void *buf, DWORD n, int writing) {
    OVERLAPPED ov;
    DWORD got = 0;
    BOOL ok;
    memset(&ov, 0, sizeof(ov));
    ov.hEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
    if (!ov.hEvent) return -1;
    ok = writing ? WriteFile(s, buf, n, NULL, &ov) : ReadFile(s, buf, n, NULL, &ov);
    if (!ok) {
        if (GetLastError() != ERROR_IO_PENDING) { CloseHandle(ov.hEvent); return -1; }
        if (WaitForSingleObject(ov.hEvent, g_io_timeout_ms) != WAIT_OBJECT_0) {
            CancelIoEx(s, &ov);
            WaitForSingleObject(ov.hEvent, INFINITE);
            CloseHandle(ov.hEvent);
            return -1;
        }
    }
    ok = GetOverlappedResult(s, &ov, &got, FALSE);
    CloseHandle(ov.hEvent);
    return ok ? (int) got : -1;
}

static int fsq_write_all(fsq_sock s, const uint8_t *p, size_t n) {
    while (n > 0) {
        int w = fsq_xfer(s, (void *) p, (DWORD) n, 1);
        if (w <= 0) return -1;
        p += w;
        n -= (size_t) w;
    }
    return 0;
}

static int fsq_read_all(fsq_sock s, uint8_t *p, size_t n) {
    while (n > 0) {
        int r = fsq_xfer(s, p, (DWORD) n, 0);
        if (r <= 0) return -1;
        p += r;
        n -= (size_t) r;
    }
    return 0;
}

static fsq_sock fsq_connect(char *err, size_t errlen) {
    HANDLE h = INVALID_HANDLE_VALUE;
    int tries;
    for (tries = 0; tries < 3; tries++) {
        /* SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION: the client
         * grants the daemon identification-level impersonation of this
         * token. Without SQOS, npfs assigns SecurityAnonymous (confirmed
         * live: the daemon's cross-account vetting fell back to
         * ImpersonateNamedPipeClient, which failed with
         * ERROR_CANNOT_IMPERSONATE/1368), and its OpenProcess fallback
         * is also denied across service accounts -- so the identity
         * check would refuse every connection. Identification is the
         * right level here: the daemon only reads the token's user SID
         * against its allow-list. */
        h = CreateFileA(g_socket_path, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                        OPEN_EXISTING,
                        FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                        NULL);
        if (h != INVALID_HANDLE_VALUE) return h;
        if (GetLastError() != ERROR_PIPE_BUSY) break;
        WaitNamedPipeA(g_socket_path, 5000);
    }
    snprintf(err, errlen, "fractalsql: fractalsqld is not reachable at %s (error %lu)",
             g_socket_path, (unsigned long) GetLastError());
    return FSQ_SOCK_INVALID;
}
#else
static void fsq_sock_set_timeout(fsq_sock s, unsigned secs) {
    struct timeval tv;
    tv.tv_sec = secs;
    tv.tv_usec = 0;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

static void fsq_sock_close(fsq_sock s) {
    close(s);
}

/* A closed peer makes the next recv() return 0 or fail hard; an idle live
 * peer makes it fail with EAGAIN. */
static int fsq_sock_alive(fsq_sock s) {
    char probe;
    ssize_t pr = recv(s, &probe, 1, MSG_PEEK | MSG_DONTWAIT);
    return !(pr == 0 || (pr < 0 && errno != EAGAIN && errno != EWOULDBLOCK));
}

/* MSG_NOSIGNAL (suppress SIGPIPE on a write to a peer that already
 * closed) is Linux-only. Darwin has no such send() flag; fsq_connect
 * below sets SO_NOSIGPIPE on the socket itself instead, once. */
#ifndef MSG_NOSIGNAL
#  define MSG_NOSIGNAL 0
#endif

static int fsq_write_all(fsq_sock fd, const uint8_t *p, size_t n) {
    while (n > 0) {
        ssize_t w = send(fd, p, n, MSG_NOSIGNAL);
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        p += w;
        n -= (size_t) w;
    }
    return 0;
}

static int fsq_read_all(fsq_sock fd, uint8_t *p, size_t n) {
    while (n > 0) {
        ssize_t r = recv(fd, p, n, 0);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) return -1;
        p += r;
        n -= (size_t) r;
    }
    return 0;
}

static fsq_sock fsq_connect(char *err, size_t errlen) {
    struct sockaddr_un sa;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { snprintf(err, errlen, "fractalsql: socket(): %s", strerror(errno)); return FSQ_SOCK_INVALID; }
    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    strcpy(sa.sun_path, g_socket_path);
    if (connect(fd, (struct sockaddr *) &sa, sizeof(sa)) != 0) {
        snprintf(err, errlen, "fractalsql: fractalsqld is not reachable at %s (%s)",
                 g_socket_path, strerror(errno));
        close(fd);
        return FSQ_SOCK_INVALID;
    }
#ifdef __APPLE__
    { int one = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one)); }
#endif
    return fd;
}
#endif

static void fsq_mac(const uint8_t *hdr, const uint8_t *payload, size_t plen, uint8_t tag[32]) {
    /* HMAC over header || payload. Build the message once with a streaming copy. */
    uint8_t *msg = malloc(FSQ_HEADER_LEN + plen);
    if (!msg) { memset(tag, 0, 32); return; }
    memcpy(msg, hdr, FSQ_HEADER_LEN);
    if (plen) memcpy(msg + FSQ_HEADER_LEN, payload, plen);
    fsq_hmac_sha256(g_key, g_key_len, msg, FSQ_HEADER_LEN + plen, tag);
    free(msg);
}

/* One request/response exchange, with retries. max_attempts bounds how
 * many times a transport/protocol failure is retried: every terminal
 * path below has already closed the connection, so "retry" means the
 * next attempt re-probes and reconnects (the probe below), with a fresh
 * request_id and the SAME context token, so the daemon can replay a
 * stateful call it had already completed before the drop. Status-level
 * failures (the daemon answered, cleanly or not) are never retried --
 * those are the function's own verdict, not a transport event. On success
 * *body is malloc'd with *status, *core_rc filled. The caller frees *body.
 * max_attempts == 1 is today's behavior. Caller holds g_mu. */
static int fsq_roundtrip(uint16_t opcode, uint64_t context,
                         const uint8_t *req, uint32_t req_len, unsigned timeout_s,
                         unsigned max_attempts,
                         uint32_t *status, int32_t *core_rc,
                         uint8_t **body, uint32_t *body_len, char *err, size_t errlen,
                         fsq_reconnect_fn on_reconnect, void *hook_ctx) {
    uint8_t hdr[FSQ_HEADER_LEN], rhdr[FSQ_HEADER_LEN], rtag[FSQ_TAG_LEN], want[FSQ_TAG_LEN];
    struct fsq_header rh;
    struct fsq_header h;
    uint8_t tag[FSQ_TAG_LEN];
    uint8_t *rpay = NULL;
    unsigned attempt;

    for (attempt = 1; attempt <= max_attempts; attempt++) {
        /* Each attempt reports its own outcome: a reason left over from
         * an earlier attempt must not survive into this one, or a later
         * success would still be carrying a stale failure text. */
        if (err != NULL && errlen > 0) err[0] = '\0';
        /* gcc -Werror=maybe-uninitialized can't prove rh is only read
         * after fsq_header_decode fills it (the failure paths continue
         * or return; a partial-read attempt re-enters this loop), so
         * zero it per attempt instead of arguing with the optimizer. */
        memset(&rh, 0, sizeof(rh));
        /* The daemon closes idle connections (idle_timeout_secs). Probe
         * before sending, so a closed peer costs a reconnect rather than
         * a failed call; each retry attempt also lands here, since every
         * failure path below closes and clears g_fd. */
        if (FSQ_SOCK_VALID(g_fd) && !fsq_sock_alive(g_fd)) {
            fsq_sock_close(g_fd);
            g_fd = FSQ_SOCK_INVALID;
        }
        if (!FSQ_SOCK_VALID(g_fd)) {
            g_fd = fsq_connect(err, errlen);
            if (!FSQ_SOCK_VALID(g_fd)) {
                /* The daemon is unreachable (restarting, say): retryable --
                 * the next attempt reconnects from scratch. */
                if (attempt < max_attempts) continue;
                return -1;
            }
            /* A new connection: the connection generation moves on, and
             * anything the request refers to on the daemon side (a
             * statement handle) has to be re-established on it before
             * the frame goes out. */
            g_conn_gen++;
        }

        /* Give the caller the chance to refresh whatever the frame
         * refers to on the daemon side, BEFORE the frame goes out.
         *
         * This runs on EVERY attempt, not only right after a connect.
         * A statement can be stale on a connection that is itself
         * current: another statement's call reconnected in between, so
         * the generation moved on while this statement kept the old
         * handle. The refresh is what notices that, and it is a no-op
         * when the statement is still bound to the live connection. */
        if (on_reconnect) {
            int hook_rc = on_reconnect(hook_ctx, err, errlen);
            if (hook_rc != FSQ_HOOK_OK) {
                fsq_sock_close(g_fd);
                g_fd = FSQ_SOCK_INVALID;
                /* A refresh that failed for transport reasons gets the
                 * attempt budget the call's own retry tier allows: the
                 * next attempt reconnects and tries the refresh again.
                 * A refusal from the daemon does not -- the same
                 * refusal would come straight back. */
                if (hook_rc == FSQ_HOOK_RETRY && attempt < max_attempts)
                    goto fsq_retry;
                if (err[0] == '\0')
                    snprintf(err, errlen,
                             "fractalsql: could not re-open the statement on the current connection to fractalsqld");
                return -1;
            }
        }
        /* After the refresh, which is a roundtrip of its own and sets
         * its own timeout on the same socket. */
        fsq_sock_set_timeout(g_fd, timeout_s);

        memset(&h, 0, sizeof(h));
        h.version = FSQ_PROTOCOL_VERSION;
        h.opcode = opcode;
        h.request_id = g_next_request_id++;   /* fresh per attempt */
        h.context = context;                  /* stable across attempts */
        h.auth_len = FSQ_TAG_LEN;
        h.payload_len = req_len;
        fsq_header_encode(hdr, &h);
        fsq_mac(hdr, req, req_len, tag);

/* A transport or protocol failure. The socket is closed and the next
 * attempt re-probes and reconnects, so "retry" means a clean socket
 * with a fresh request id and the same context token.
 *
 * WHY A GOTO AND NOT `continue`: this macro is a do/while(0), and a
 * `continue` inside a do/while(0) applies to THAT loop -- it
 * evaluates the (false) condition and falls out of the macro, straight
 * into the code after the macro invocation, with the socket already
 * closed and the reply buffer already freed. The fall-through then
 * read a response frame from a dead socket and dereferenced the
 * freed payload (memcpy from NULL, then fsq_get_u32(NULL)): a crash
 * inside mariadbd, on the shim's own thread. It also meant the retry
 * NEVER happened -- the loop's next iteration was unreachable from
 * every failure site, so the documented retry contract (and the
 * daemon's stateful-replay path behind it) was dead code.
 *
 * The label at the end of the loop body is the retry point: control
 * reaches the loop's increment from there, and the next iteration
 * re-memsets the response header. */
#define FSQ_TR_FAIL(text)                                                     \
        do {                                                                  \
            fsq_sock_close(g_fd); g_fd = FSQ_SOCK_INVALID;                    \
            if (attempt < max_attempts) goto fsq_retry;                       \
            snprintf(err, errlen, text " (after %u attempt(s))", attempt);    \
            return -1;                                                        \
        } while (0)

        if (fsq_write_all(g_fd, hdr, FSQ_HEADER_LEN) != 0 ||
            fsq_write_all(g_fd, tag, FSQ_TAG_LEN) != 0 ||
            (req_len && fsq_write_all(g_fd, req, req_len) != 0)) {
            FSQ_TR_FAIL("fractalsql: lost connection to fractalsqld while sending");
        }

        if (fsq_read_all(g_fd, rhdr, FSQ_HEADER_LEN) != 0 ||
            fsq_header_decode(rhdr, &rh) != 0 ||
            rh.version != FSQ_PROTOCOL_VERSION ||
            rh.auth_len != FSQ_TAG_LEN ||
            rh.payload_len > FSQ_MAX_PAYLOAD ||
            rh.request_id != h.request_id ||
            !(rh.flags & FSQ_FLAG_RESPONSE)) {
            FSQ_TR_FAIL("fractalsql: bad response frame from fractalsqld (check protocol version and hmac_key_file)");
        }
        if (fsq_read_all(g_fd, rtag, FSQ_TAG_LEN) != 0) {
            FSQ_TR_FAIL("fractalsql: lost connection to fractalsqld while reading");
        }
        if (rh.payload_len) {
            rpay = malloc(rh.payload_len);
            if (!rpay || fsq_read_all(g_fd, rpay, rh.payload_len) != 0) {
                free(rpay);
                rpay = NULL;
                FSQ_TR_FAIL("fractalsql: lost connection to fractalsqld while reading");
            }
        }
        fsq_mac(rhdr, rpay, rh.payload_len, want);
        if (!fsq_ct_equal(rtag, want, FSQ_TAG_LEN)) {
            free(rpay);
            rpay = NULL;
            FSQ_TR_FAIL("fractalsql: response authentication failed (check hmac_key_file)");
        }
#undef FSQ_TR_FAIL

        if (rh.payload_len < 8) {
            free(rpay);
            /* A well-formed frame with a nonsense payload is a deterministic
             * protocol violation, not a transport event: no retry. */
            snprintf(err, errlen, "fractalsql: short response from fractalsqld");
            return -1;
        }
        *status = fsq_get_u32(rpay);
        *core_rc = (int32_t) fsq_get_u32(rpay + 4);
        *body_len = rh.payload_len - 8;
        *body = malloc(*body_len ? *body_len : 1);
        if (!*body) { free(rpay); snprintf(err, errlen, "fractalsql: out of memory"); return -1; }
        if (*body_len) memcpy(*body, rpay + 8, *body_len);
        free(rpay);
        return 0;

    fsq_retry:
        /* Reached only through FSQ_TR_FAIL's goto. The socket is closed
         * and the reply buffer is gone; drop it again (NULL at every
         * failure site today) so the next attempt starts from a clean
         * socket with a fresh request id and the same context token. */
        free(rpay);
        rpay = NULL;
        continue;
    }
    /* Unreachable: the loop returns or continues. */
    snprintf(err, errlen, "fractalsql: internal retry error");
    return -1;
}

/* Converts a local failure into the caller's error buffer. An empty
 * `text` would produce an empty error message, which MariaDB renders
 * as a NULL result with no explanation -- never leave the user with
 * nothing. The generic fallback keeps the message non-empty. */
static void fsq_set_msg(char *message, const char *text) {
    size_t n;
    if (text == NULL || text[0] == '\0') {
        text = "fractalsql: unspecified failure";
    }
    n = strlen(text);
    if (n >= FSQ_MSG_MAX) n = FSQ_MSG_MAX - 1;
    memcpy(message, text, n);
    message[n] = '\0';
}

/* The RUNTIME path has nowhere to put a reason: MariaDB's UDF ABI
 * carries a single error FLAG, and a flag surfaces as the bare "Can't
 * initialize function" with no text. A call that fails in the shim --
 * the daemon is down, the statement could not be re-opened, the reply
 * was malformed -- would therefore reach the user as an unexplained
 * error and reach the operator as nothing at all.
 *
 * The shim runs INSIDE mariadbd, so stderr lands in the server's own
 * error log: the one place an operator looks when a query fails. The
 * reason is written there, once per failed call, with the function's
 * name so the log line says which call failed. */
static void fsq_log_call_failure(const char *fn_name, const char *text) {
    if (text == NULL || text[0] == '\0') text = "unspecified failure";
    fprintf(stderr, "fractalsql: %s failed: %s\n",
            fn_name != NULL ? fn_name : "(unknown function)", text);
    fflush(stderr);
}

/* Maps a wire ARG type to the TLV type code. */
static uint8_t fsq_wire_type(enum Item_result t) {
    switch (t) {
        case STRING_RESULT:  return FSQ_T_STRING;
        case INT_RESULT:     return FSQ_T_INT;
        case REAL_RESULT:    return FSQ_T_REAL;
        case DECIMAL_RESULT: return FSQ_T_DECIMAL;
        default:             return FSQ_T_NULL;
    }
}

static enum Item_result fsq_server_type(uint8_t t) {
    switch (t) {
        case FSQ_T_INT:     return INT_RESULT;
        case FSQ_T_REAL:    return REAL_RESULT;
        case FSQ_T_DECIMAL: return DECIMAL_RESULT;
        default:            return STRING_RESULT;
    }
}

/* ------------------------------------------------------------------ */
/* Lifecycle: UDF_INIT returns a daemon handle, UDF_CALL and UDF_DEINIT   */
/* carry it. The handle is stored in initid->ptr for the statement.       */
/* ------------------------------------------------------------------ */

/* Shared failure path: a transport or protocol error reaches the caller
 * as the message text, so the server shows the same error text it would for
 * an in-process failure. */
/* Per-statement state, reached through initid->ptr. MariaDB gives a STRING
 * UDF a result buffer of about 255 bytes, so a longer result has to come
 * back from memory this struct owns (freed in deinit). Copying it into the
 * result buffer smashes the server's stack. */
struct fsq_stmt {
    uint64_t handle;
    char *out;
    /* The connection generation this handle belongs to, and the
     * UDF_INIT frame that opened it. A handle is scoped to the
     * connection that created it, so when the connection is replaced
     * the statement is re-opened with this same frame and the new
     * handle replaces the old one. */
    uint64_t gen;
    uint8_t *init_req;
    uint32_t init_req_len;
};

#define FSQ_STR_INLINE_MAX 255u

static char *fsq_return_string(UDF_INIT *initid, char *result, unsigned long *length,
                               const uint8_t *bytes, uint32_t blen) {
    struct fsq_stmt *st = (struct fsq_stmt *) initid->ptr;
    char *out;
    if (blen <= FSQ_STR_INLINE_MAX) {
        if (blen) memcpy(result, bytes, blen);
        *length = blen;
        return result;
    }
    if (!st) return NULL;
    out = malloc(blen);
    if (!out) return NULL;
    memcpy(out, bytes, blen);
    free(st->out);
    st->out = out;
    *length = blen;
    return out;
}

static my_bool fsq_udf_init(UDF_INIT *initid, UDF_ARGS *args, char *message,
                            const char *fn_name) {
    uint8_t *req = NULL, *body = NULL, *init_copy = NULL;
    uint32_t status = 0, body_len = 0, req_len, i, nargs;
    uint8_t namelen = (uint8_t) strlen(fn_name);
    int32_t core_rc = 0;
    char err[FSQ_MSG_MAX] = { 0 };
    uint64_t handle;
    uint64_t gen = 0;
    struct fsq_stmt *st;
    int rc;

    if (args->arg_count > FSQ_MAX_ARGS) {
        fsq_set_msg(message, "fractalsql: too many arguments for this function");
        return 1;
    }
    nargs = args->arg_count;
    /* Same argument encoding as a call. MariaDB gives init the value of each
     * constant argument and NULL for the rest, so only constants carry bytes. */
    req_len = 1 + namelen + 4;
    for (i = 0; i < nargs; i++) {
        uint32_t vlen = 0;
        if (args->args[i] != NULL) {
            vlen = (args->arg_type[i] == INT_RESULT || args->arg_type[i] == REAL_RESULT)
                       ? 8 : (uint32_t) args->lengths[i];
        }
        req_len += 6 + vlen;
    }
    req = malloc(req_len);
    if (!req) { fsq_set_msg(message, "fractalsql: out of memory"); return 1; }
    req[0] = namelen;
    memcpy(req + 1, fn_name, namelen);
    fsq_put_u32(req + 1 + namelen, nargs);
    {
        uint8_t *p = req + 1 + namelen + 4;
        for (i = 0; i < nargs; i++) {
            uint8_t is_null = args->args[i] == NULL ? 1 : 0;
            uint32_t vlen = 0;
            *p++ = fsq_wire_type(args->arg_type[i]);
            *p++ = is_null;
            if (!is_null) {
                if (args->arg_type[i] == INT_RESULT) {
                    vlen = 8;
                    fsq_put_u64(p + 4, (uint64_t) *(long long *) args->args[i]);
                } else if (args->arg_type[i] == REAL_RESULT) {
                    uint64_t bits;
                    vlen = 8;
                    memcpy(&bits, args->args[i], 8);
                    fsq_put_u64(p + 4, bits);
                } else {
                    vlen = (uint32_t) args->lengths[i];
                    memcpy(p + 4, args->args[i], vlen);
                }
            }
            fsq_put_u32(p, vlen);
            p += 4 + vlen;
        }
    }

    /* Keep a copy of the frame that opened the statement. A handle is
     * scoped to the connection that created it, so a statement whose
     * connection is later replaced has to be re-opened -- and the
     * re-open is this same frame, sent again. */
    init_copy = (uint8_t *) malloc(req_len);
    if (!init_copy) {
        free(req);
        fsq_set_msg(message, "fractalsql: out of memory");
        return 1;
    }
    memcpy(init_copy, req, req_len);

    FSQ_LOCK(g_mu);
    if (!g_configured) {
        if (fsq_load_config() != 0) {
            FSQ_UNLOCK(g_mu);
            free(req);
            free(init_copy);
            fsq_set_msg(message, "fractalsql: cannot read fractalsql.conf (socket_path, hmac_key_file)");
            return 1;
        }
        g_configured = 1;
        g_idem_base = fsq_idem_draw_base();
    }
    rc = fsq_roundtrip(FSQ_OP_UDF_INIT, 0, req, req_len, FSQ_IO_TIMEOUT_INIT_S, 1,
                       &status, &core_rc, &body, &body_len, err, sizeof(err),
                       NULL, NULL);
    /* The generation the handle was minted on, read INSIDE the lock. The
     * counter is bumped by every roundtrip that connects, and those
     * roundtrips hold this same lock, so reading it here pairs the
     * handle with the connection it belongs to. Reading it after the
     * unlock would open a window in which another connection could
     * reconnect and bump the counter: the statement
     * would then be stamped with a generation NEWER than the one its
     * handle was minted on, the re-open hook would compare the two,
     * find them equal, skip the re-open, and the call would go out
     * carrying a handle the daemon no longer knows. */
    gen = g_conn_gen;
    FSQ_UNLOCK(g_mu);
    free(req);

    if (rc != 0) { fsq_set_msg(message, err); free(body); free(init_copy); return 1; }
    if (status != FSQ_OK) {
        size_t n = body_len < FSQ_MSG_MAX ? body_len : FSQ_MSG_MAX - 1;
        memcpy(message, body, n);
        message[n] = '\0';
        free(body);
        free(init_copy);
        return 1;
    }
    /* Body: handle u64, max_length u32, maybe_null u8, nargs u32, types[nargs] u8 */
    if (body_len < 17 || fsq_get_u32(body + 13) != nargs || body_len < 17 + nargs) {
        free(body);
        free(init_copy);
        fsq_set_msg(message, "fractalsql: malformed init reply");
        return 1;
    }
    handle = fsq_get_u64(body);
    if (handle == 0) {
        free(body);
        free(init_copy);
        fsq_set_msg(message, "fractalsql: fractalsqld returned no handle");
        return 1;
    }
    st = calloc(1, sizeof(*st));
    if (!st) {
        free(body);
        free(init_copy);
        fsq_set_msg(message, "fractalsql: out of memory");
        return 1;
    }
    st->handle = handle;
    st->gen = gen;
    st->init_req = init_copy;
    st->init_req_len = req_len;
    initid->ptr = (char *) st;
    initid->max_length = fsq_get_u32(body + 8);
    if (initid->max_length > FSQ_MAX_RESULT_BYTES) initid->max_length = (unsigned long) FSQ_MAX_RESULT_BYTES;
    initid->maybe_null = body[12] ? 1 : 0;
    for (i = 0; i < nargs; i++) args->arg_type[i] = fsq_server_type(body[17 + i]);
    free(body);
    return 0;
}

/* The reconnect hook for a call: re-opens the statement on the new
 * connection and patches the fresh handle into the request about to be
 * sent. A handle is scoped to the connection that created it, so a
 * statement carried across a connection change would be refused with
 * "unknown handle"; the re-open sends the statement's own UDF_INIT
 * frame again, which yields a handle valid on the current connection.
 *
 * The idempotency token is NOT part of this: the token belongs to the
 * logical CALL, and it travels with the resend so the daemon can
 * answer from its cache if the call had already run. */
struct fsq_call_ctx {
    struct fsq_stmt *st;
    uint8_t *req;          /* the CALL request being sent */
    uint32_t handle_off;   /* where its handle field sits */
};

static int fsq_call_reconnect(void *vctx, char *err, size_t errlen) {
    struct fsq_call_ctx *c = (struct fsq_call_ctx *) vctx;
    struct fsq_stmt *st = c->st;
    uint32_t status = 0, body_len = 0;
    int32_t core_rc = 0;
    uint8_t *body = NULL;
    char local_err[FSQ_MSG_MAX] = { 0 };
    uint64_t handle;
    int rc;

    if (!st || !st->init_req) return 0;   /* nothing to re-open */
    if (st->gen == g_conn_gen) return 0;  /* the handle still belongs here */

    rc = fsq_roundtrip(FSQ_OP_UDF_INIT, 0, st->init_req, st->init_req_len,
                       FSQ_IO_TIMEOUT_INIT_S, 1, &status, &core_rc, &body,
                       &body_len, local_err, sizeof(local_err), NULL, NULL);
    if (rc != 0 || status != FSQ_OK || body_len < 17) {
        free(body);
        snprintf(err, errlen, "fractalsql: could not re-open the statement on the "
                              "current connection to fractalsqld: %s",
                 local_err[0] ? local_err : "the daemon refused the re-open");
        /* A roundtrip that did not complete is a transport event, and
         * the call's own retry tier can have another go at it. A
         * completed roundtrip whose answer was a refusal is not. */
        return rc != 0 ? FSQ_HOOK_RETRY : FSQ_HOOK_FATAL;
    }
    handle = fsq_get_u64(body);
    free(body);
    if (handle == 0) {
        snprintf(err, errlen, "fractalsql: could not re-open the statement on the "
                              "current connection to fractalsqld: no handle");
        return FSQ_HOOK_FATAL;
    }

    st->handle = handle;
    st->gen = g_conn_gen;
    fsq_put_u64(c->req + c->handle_off, handle);
    return 0;
}

/* Packs the args, calls the daemon, returns the TLV result. cls is the
 * function's retry class from functions.def ('r'/'s'/'e'). The idempotency
 * token is minted ONCE for this logical call and sent on every attempt. */
static int fsq_udf_call(UDF_INIT *initid, UDF_ARGS *args, const char *fn_name,
                        char cls,
                        uint8_t *out_null, uint8_t **out_bytes, uint32_t *out_len,
                        char *is_null, char *error) {
    uint8_t namelen = (uint8_t) strlen(fn_name);
    size_t total = 1 + namelen + 8 + 4;
    uint8_t *req, *p, *body = NULL;
    uint32_t status = 0, body_len = 0, i;
    int32_t core_rc = 0;
    char err[FSQ_MSG_MAX] = { 0 };
    uint64_t handle = initid->ptr ? ((struct fsq_stmt *) initid->ptr)->handle : 0;
    uint64_t token;
    unsigned attempts = fsq_attempts_for(cls);
    struct fsq_call_ctx cctx;
    int rc;

    if (handle == 0 || args->arg_count > FSQ_MAX_ARGS) { *error = 1; return -1; }
    for (i = 0; i < args->arg_count; i++) {
        size_t len = 0;
        if (args->args[i]) {
            if (args->arg_type[i] == INT_RESULT || args->arg_type[i] == REAL_RESULT) len = 8;
            else len = args->lengths[i];
        }
        total += 6 + len;
        if (total > FSQ_MAX_ARG_BYTES) { *error = 1; return -1; }
    }
    req = malloc(total);
    if (!req) { *error = 1; return -1; }
    p = req;
    *p++ = namelen;
    memcpy(p, fn_name, namelen); p += namelen;
    fsq_put_u64(p, handle); p += 8;
    fsq_put_u32(p, args->arg_count); p += 4;
    for (i = 0; i < args->arg_count; i++) {
        uint32_t len = 0;
        uint8_t null_flag = args->args[i] == NULL ? 1 : 0;
        *p++ = fsq_wire_type(args->arg_type[i]);
        *p++ = null_flag;
        if (!null_flag) {
            if (args->arg_type[i] == INT_RESULT) {
                len = 8;
                fsq_put_u64(p + 4, (uint64_t) *(long long *) args->args[i]);
            } else if (args->arg_type[i] == REAL_RESULT) {
                uint64_t bits;
                len = 8;
                memcpy(&bits, args->args[i], 8);
                fsq_put_u64(p + 4, bits);
            } else {
                len = (uint32_t) args->lengths[i];
                memcpy(p + 4, args->args[i], len);
            }
        }
        fsq_put_u32(p, len);
        p += 4 + len;
    }

    FSQ_LOCK(g_mu);
    token = g_idem_base + g_idem_counter++;
    /* The hook re-opens the statement if this call has to travel on a
     * connection the statement was not opened on (the daemon scopes a
     * handle to its connection), and patches the fresh handle into the
     * request built above. */
    cctx.st    = (struct fsq_stmt *) initid->ptr;
    cctx.req   = req;
    cctx.handle_off = 1 + namelen;
    rc = fsq_roundtrip(FSQ_OP_UDF_CALL, token, req, (uint32_t) (p - req),
                       FSQ_IO_TIMEOUT_CALL_S, attempts,
                       &status, &core_rc, &body, &body_len, err, sizeof(err),
                       fsq_call_reconnect, &cctx);
    FSQ_UNLOCK(g_mu);
    free(req);

    if (rc != 0 || status != FSQ_OK || body_len < 6) {
        char why[FSQ_MSG_MAX];
        *error = 1;
        /* The reason cannot ride back to the client -- MariaDB's UDF ABI
         * has no error text on the runtime path -- so it goes to the
         * server's own error log instead, where an operator will find
         * it. */
        if (rc != 0)
            snprintf(why, sizeof why, "%s", err);
        else if (status != FSQ_OK)
            snprintf(why, sizeof why, "the daemon refused the call (status %u)",
                     (unsigned) status);
        else
            snprintf(why, sizeof why, "the daemon sent a malformed reply");
        fsq_log_call_failure(fn_name, why);
        free(body);
        return -1;
    }
    *out_null = body[1];
    *out_len = fsq_get_u32(body + 2);
    if (*out_len > body_len - 6) {
        fsq_log_call_failure(fn_name, "the daemon sent a reply of the wrong length");
        *error = 1; free(body); return -1;
    }
    *out_bytes = malloc(*out_len ? *out_len : 1);
    if (!*out_bytes) {
        fsq_log_call_failure(fn_name, "out of memory");
        *error = 1; free(body); return -1;
    }
    if (*out_len) memcpy(*out_bytes, body + 6, *out_len);
    free(body);
    *is_null = *out_null ? 1 : 0;
    return 0;
}

/* Releases the daemon-side handle for a statement. Failures are ignored: the
 * daemon drops handles for closed connections, and there is no way to report
 * an error from a UDF deinit. */
static void fsq_udf_deinit(UDF_INIT *initid) {
    uint64_t handle = initid->ptr ? ((struct fsq_stmt *) initid->ptr)->handle : 0;
    uint8_t req[8], *body = NULL;
    uint32_t status = 0, body_len = 0;
    int32_t core_rc = 0;
    char err[FSQ_MSG_MAX] = { 0 };
    struct fsq_stmt *st = (struct fsq_stmt *) initid->ptr;
    if (!st) return;
    if (handle != 0) {
        fsq_put_u64(req, handle);
        FSQ_LOCK(g_mu);
        fsq_roundtrip(FSQ_OP_UDF_DEINIT, 0, req, 8, FSQ_IO_TIMEOUT_INIT_S, 1,
                      &status, &core_rc, &body, &body_len, err, sizeof(err),
                      NULL, NULL);
        FSQ_UNLOCK(g_mu);
        free(body);
    }
    free(st->out);
    free(st->init_req);
    free(st);
    initid->ptr = NULL;
}

/* ------------------------------------------------------------------ */
/* Per-UDF stubs. shim_udfs.h is generated from protocol/functions.def,
 * whose retry class (r/s/e, the retry column) is threaded through to the
 * call below as cls. */

#define FSQ_UDF_STR(name, cls)                                                            \
    FSQ_EXPORT my_bool name##_init(UDF_INIT *initid, UDF_ARGS *args, char *message) {               \
        return fsq_udf_init(initid, args, message, #name);                               \
    }                                                                                    \
    FSQ_EXPORT void name##_deinit(UDF_INIT *initid) { fsq_udf_deinit(initid); }                     \
    FSQ_EXPORT char *name(UDF_INIT *initid, UDF_ARGS *args, char *result,                 \
               unsigned long *length, char *is_null, char *error) {                      \
        uint8_t null_flag = 0, *bytes = NULL;                                            \
        uint32_t blen = 0;                                                               \
        char *out;                                                                       \
        if (fsq_udf_call(initid, args, #name, cls, &null_flag, &bytes, &blen,            \
                         is_null, error) != 0) {                                         \
            *length = 0;                                                                 \
            return NULL;                                                                 \
        }                                                                                \
        if (null_flag) { *length = 0; free(bytes); return NULL; }                        \
        if (blen > initid->max_length) { *error = 1; free(bytes); *length = 0; return NULL; } \
        out = fsq_return_string(initid, result, length, bytes, blen);                    \
        free(bytes);                                                                     \
        if (!out) { *error = 1; *length = 0; return NULL; }                              \
        return out;                                                                      \
    }

#define FSQ_UDF_INT(name, cls)                                                            \
    FSQ_EXPORT my_bool name##_init(UDF_INIT *initid, UDF_ARGS *args, char *message) {               \
        return fsq_udf_init(initid, args, message, #name);                               \
    }                                                                                    \
    FSQ_EXPORT void name##_deinit(UDF_INIT *initid) { fsq_udf_deinit(initid); }                     \
    FSQ_EXPORT long long name(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error) {       \
        uint8_t null_flag = 0, *bytes = NULL;                                            \
        uint32_t blen = 0;                                                               \
        long long v = 0;                                                                 \
        if (fsq_udf_call(initid, args, #name, cls, &null_flag, &bytes, &blen,           \
                         is_null, error) != 0) return 0;                                \
        if (null_flag) { free(bytes); return 0; }                                        \
        if (blen == 8) v = (long long) fsq_get_u64(bytes);                               \
        free(bytes);                                                                     \
        return v;                                                                        \
    }

#define FSQ_UDF_REAL(name, cls)                                                           \
    FSQ_EXPORT my_bool name##_init(UDF_INIT *initid, UDF_ARGS *args, char *message) {               \
        return fsq_udf_init(initid, args, message, #name);                               \
    }                                                                                    \
    FSQ_EXPORT void name##_deinit(UDF_INIT *initid) { fsq_udf_deinit(initid); }                     \
    FSQ_EXPORT double name(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error) {          \
        uint8_t null_flag = 0, *bytes = NULL;                                            \
        uint32_t blen = 0;                                                               \
        double v = 0.0;                                                                  \
        uint64_t bits;                                                                   \
        if (fsq_udf_call(initid, args, #name, cls, &null_flag, &bytes, &blen,            \
                         is_null, error) != 0) return 0.0;                               \
        if (null_flag) { free(bytes); return 0.0; }                                      \
        if (blen == 8) { bits = fsq_get_u64(bytes); memcpy(&v, &bits, 8); }              \
        free(bytes);                                                                     \
        return v;                                                                        \
    }

#include "shim_udfs.h"
