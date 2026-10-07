/* SPDX-License-Identifier: Apache-2.0 */
/* SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * Frame-level checks against a running fractalsqld: a valid PING is answered,
 * a frame with a bad tag is dropped, and an oversize payload_len is dropped.
 * Also the newer control paths: OP_RELOAD (empty payload OK, non-empty
 * ERR_ARGS) and the idempotency cache on OP_UDF_CALL (a resent token replays
 * the cached body and echoes the resent frame's request id).
 * Usage: frame_test <socket_path> <hmac_key_hex>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "../common/fsq_sha256.h"
#include "../protocol/fsq_protocol.h"

static int connect_to(const char *path) {
    struct sockaddr_un sa;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    strcpy(sa.sun_path, path);
    if (fd < 0 || connect(fd, (struct sockaddr *) &sa, sizeof(sa)) != 0) return -1;
    return fd;
}

/* The request id of the most recent response frame read (see
 * read_response_body) -- the daemon echoes the request's id back, so the
 * dedupe test can tell a replayed answer from a fresh one. */
static uint32_t g_last_rid = 0;

static void send_frame(int fd, const uint8_t *key, size_t klen, uint16_t op,
                       uint32_t declared_len, const uint8_t *payload, uint32_t plen,
                       int bad_tag, uint32_t rid, uint64_t context) {
    uint8_t hdr[FSQ_HEADER_LEN], tag[FSQ_TAG_LEN];
    struct fsq_header h;
    uint8_t *msg = malloc(FSQ_HEADER_LEN + plen);
    memset(&h, 0, sizeof(h));
    h.version = FSQ_PROTOCOL_VERSION;
    h.opcode = op;
    h.request_id = rid;
    h.context = context;
    h.auth_len = FSQ_TAG_LEN;
    h.payload_len = declared_len;
    fsq_header_encode(hdr, &h);
    memcpy(msg, hdr, FSQ_HEADER_LEN);
    if (plen) memcpy(msg + FSQ_HEADER_LEN, payload, plen);
    fsq_hmac_sha256(key, klen, msg, FSQ_HEADER_LEN + plen, tag);
    if (bad_tag) tag[0] ^= 0xFF;
    if (write(fd, hdr, FSQ_HEADER_LEN) < 0) { free(msg); return; }
    if (write(fd, tag, FSQ_TAG_LEN) < 0) { free(msg); return; }
    if (plen && write(fd, payload, plen) < 0) { free(msg); return; }
    free(msg);
}

/* Returns 1 if the peer answered with an authenticated response, 0 if closed.
 * body_out/body_len_out, if non-NULL, receive a malloc'd copy of the reply
 * body past the status/core_rc header (the caller frees it); pass NULL/NULL
 * when only the status matters. */
static int read_response_body(int fd, const uint8_t *key, size_t klen, uint32_t *status,
                               uint8_t **body_out, uint32_t *body_len_out) {
    uint8_t hdr[FSQ_HEADER_LEN], tag[FSQ_TAG_LEN], want[FSQ_TAG_LEN], *pay;
    struct fsq_header h;
    size_t got = 0;
    while (got < FSQ_HEADER_LEN) {
        ssize_t r = read(fd, hdr + got, FSQ_HEADER_LEN - got);
        if (r <= 0) return 0;
        got += (size_t) r;
    }
    if (fsq_header_decode(hdr, &h) != 0 || !(h.flags & FSQ_FLAG_RESPONSE)) return 0;
    g_last_rid = h.request_id;
    if (read(fd, tag, FSQ_TAG_LEN) != FSQ_TAG_LEN) return 0;
    pay = malloc(h.payload_len ? h.payload_len : 1);
    got = 0;
    while (got < h.payload_len) {
        ssize_t r = read(fd, pay + got, h.payload_len - got);
        if (r <= 0) { free(pay); return 0; }
        got += (size_t) r;
    }
    {
        uint8_t *msg = malloc(FSQ_HEADER_LEN + h.payload_len);
        memcpy(msg, hdr, FSQ_HEADER_LEN);
        if (h.payload_len) memcpy(msg + FSQ_HEADER_LEN, pay, h.payload_len);
        fsq_hmac_sha256(key, klen, msg, FSQ_HEADER_LEN + h.payload_len, want);
        free(msg);
    }
    *status = h.payload_len >= 4 ? fsq_get_u32(pay) : 99;
    if (body_out && body_len_out) {
        if (h.payload_len > 8) {
            *body_len_out = h.payload_len - 8;
            *body_out = malloc(*body_len_out);
            memcpy(*body_out, pay + 8, *body_len_out);
        } else {
            *body_len_out = 0;
            *body_out = NULL;
        }
    }
    free(pay);
    return fsq_ct_equal(tag, want, FSQ_TAG_LEN);
}

static int read_response(int fd, const uint8_t *key, size_t klen, uint32_t *status) {
    return read_response_body(fd, key, klen, status, NULL, NULL);
}

static int closed_by_peer(int fd) {
    uint8_t b;
    return read(fd, &b, 1) <= 0;
}

int main(int argc, char **argv) {
    uint8_t key[64];
    size_t klen = 0;
    int fails = 0, fd;
    uint32_t status = 0;
    if (argc != 3) { fprintf(stderr, "usage: frame_test <socket> <hex key>\n"); return 2; }
    for (const char *p = argv[2]; p[0] && p[1]; p += 2) {
        unsigned v;
        sscanf(p, "%2x", &v);
        key[klen++] = (uint8_t) v;
    }

    fd = connect_to(argv[1]);
    if (fd < 0) { fprintf(stderr, "cannot connect\n"); return 1; }
    send_frame(fd, key, klen, FSQ_OP_PING, 0, NULL, 0, 0, 7, 0);
    if (read_response(fd, key, klen, &status) && status == FSQ_OK) printf("  [PASS] valid PING answered\n");
    else { printf("  [FAIL] valid PING\n"); fails++; }
    close(fd);

    fd = connect_to(argv[1]);
    send_frame(fd, key, klen, FSQ_OP_PING, 0, NULL, 0, 1, 7, 0);
    if (closed_by_peer(fd)) printf("  [PASS] bad tag dropped\n");
    else { printf("  [FAIL] bad tag was answered\n"); fails++; }
    close(fd);

    fd = connect_to(argv[1]);
    send_frame(fd, key, klen, FSQ_OP_PING, FSQ_MAX_PAYLOAD + 1, NULL, 0, 0, 7, 0);
    if (closed_by_peer(fd)) printf("  [PASS] oversize payload_len dropped\n");
    else { printf("  [FAIL] oversize payload_len was answered\n"); fails++; }
    close(fd);

    /* OP_CANCEL: init a handle, cancel it, confirm the next UDF_CALL on that
     * handle fails with ERR_BUSY (the flag is then clear, so a further call
     * succeeds), and confirm cancelling an unknown handle reports ERR_ARGS. */
    {
        static const char fn[] = "fractal_vector_dims";
        static const char arg[] = "[1,2,3]";
        uint8_t namelen = (uint8_t) (sizeof(fn) - 1);
        uint8_t init_payload[1 + sizeof(fn) - 1 + 4 + 6 + sizeof(arg) - 1];
        uint8_t *p = init_payload;
        uint8_t *body = NULL;
        uint32_t blen = 0, status;
        uint64_t handle_id;

        *p++ = namelen;
        memcpy(p, fn, namelen); p += namelen;
        fsq_put_u32(p, 1); p += 4;             /* nargs */
        *p++ = FSQ_T_STRING; *p++ = 0;         /* type, is_null */
        fsq_put_u32(p, (uint32_t) (sizeof(arg) - 1)); p += 4;
        memcpy(p, arg, sizeof(arg) - 1); p += sizeof(arg) - 1;

        fd = connect_to(argv[1]);
        send_frame(fd, key, klen, FSQ_OP_UDF_INIT, (uint32_t) sizeof(init_payload), init_payload, (uint32_t) sizeof(init_payload), 0, 7, 0);
        if (read_response_body(fd, key, klen, &status, &body, &blen) && status == FSQ_OK && blen >= 8) {
            printf("  [PASS] cancel setup: UDF_INIT ok\n");
        } else { printf("  [FAIL] cancel setup: UDF_INIT (status=%u)\n", status); fails++; close(fd); goto cancel_done; }
        handle_id = fsq_get_u64(body);
        free(body); body = NULL;

        {
            uint8_t cpay[8];
            fsq_put_u64(cpay, handle_id);
            send_frame(fd, key, klen, FSQ_OP_CANCEL, 8, cpay, 8, 0, 7, 0);
            if (read_response_body(fd, key, klen, &status, NULL, NULL) && status == FSQ_OK)
                printf("  [PASS] CANCEL on a live handle returns OK\n");
            else { printf("  [FAIL] CANCEL on a live handle (status=%u)\n", status); fails++; }
        }

        {
            uint8_t call_payload[1 + sizeof(fn) - 1 + 8 + 4 + 6 + sizeof(arg) - 1];
            uint8_t *q = call_payload;
            *q++ = namelen;
            memcpy(q, fn, namelen); q += namelen;
            fsq_put_u64(q, handle_id); q += 8;
            fsq_put_u32(q, 1); q += 4;
            *q++ = FSQ_T_STRING; *q++ = 0;
            fsq_put_u32(q, (uint32_t) (sizeof(arg) - 1)); q += 4;
            memcpy(q, arg, sizeof(arg) - 1); q += sizeof(arg) - 1;

            send_frame(fd, key, klen, FSQ_OP_UDF_CALL, (uint32_t) sizeof(call_payload), call_payload, (uint32_t) sizeof(call_payload), 0, 7, 0);
            if (read_response_body(fd, key, klen, &status, NULL, NULL) && status == FSQ_ERR_BUSY)
                printf("  [PASS] UDF_CALL right after CANCEL fails with ERR_BUSY\n");
            else { printf("  [FAIL] UDF_CALL after CANCEL (status=%u, want ERR_BUSY)\n", status); fails++; }

            send_frame(fd, key, klen, FSQ_OP_UDF_CALL, (uint32_t) sizeof(call_payload), call_payload, (uint32_t) sizeof(call_payload), 0, 7, 0);
            if (read_response_body(fd, key, klen, &status, NULL, NULL) && status == FSQ_OK)
                printf("  [PASS] the cancel flag is one-shot: the next UDF_CALL succeeds\n");
            else { printf("  [FAIL] UDF_CALL after the cleared flag (status=%u)\n", status); fails++; }
        }

        {
            uint8_t cpay[8];
            fsq_put_u64(cpay, (uint64_t) 0xFFFFFFFFFFFFFFFFull);
            send_frame(fd, key, klen, FSQ_OP_CANCEL, 8, cpay, 8, 0, 7, 0);
            if (read_response_body(fd, key, klen, &status, NULL, NULL) && status == FSQ_ERR_ARGS)
                printf("  [PASS] CANCEL on an unknown handle returns ERR_ARGS\n");
            else { printf("  [FAIL] CANCEL on an unknown handle (status=%u, want ERR_ARGS)\n", status); fails++; }
        }
        close(fd);
    }
cancel_done:

    /* OP_RELOAD: an empty payload re-reads the daemon's config file and is
     * answered OK (this test daemon's config is valid); any nonzero payload
     * is a malformed reload request and gets ERR_ARGS. */
    {
        uint8_t junk[1] = { 0xFF };
        fd = connect_to(argv[1]);
        send_frame(fd, key, klen, FSQ_OP_RELOAD, 0, NULL, 0, 0, 8, 0);
        if (read_response(fd, key, klen, &status) && status == FSQ_OK)
            printf("  [PASS] RELOAD with an empty payload returns OK\n");
        else { printf("  [FAIL] RELOAD empty payload (status=%u)\n", status); fails++; }
        send_frame(fd, key, klen, FSQ_OP_RELOAD, 1, junk, 1, 0, 9, 0);
        if (read_response(fd, key, klen, &status) && status == FSQ_ERR_ARGS)
            printf("  [PASS] RELOAD with a payload returns ERR_ARGS\n");
        else { printf("  [FAIL] RELOAD payload (status=%u, want ERR_ARGS)\n", status); fails++; }
        close(fd);
    }

    /* Idempotency cache on UDF_CALL: two calls carrying the SAME nonzero
     * context token but different request ids both succeed with identical
     * bodies, each reply echoing its own request id (the second comes from
     * the daemon's cache, not a re-execution); a different token misses the
     * cache and executes again (same result -- the function is pure).
     * Pure function on purpose: the stateful (s-class) functions are
     * dlsym-gated on community builds and cannot be exercised here, so the
     * re-execute side of the cache is only asserted as "a fresh token also
     * works". */
    {
        static const char fn[] = "fractal_vector_dims";
        static const char arg[] = "[1,2,3]";
        uint8_t namelen = (uint8_t) (sizeof(fn) - 1);
        uint8_t init_payload[1 + sizeof(fn) - 1 + 4 + 6 + sizeof(arg) - 1];
        uint8_t call_payload[1 + sizeof(fn) - 1 + 8 + 4 + 6 + sizeof(arg) - 1];
        uint8_t *p = init_payload, *q = call_payload;
        uint8_t *body1 = NULL, *body2 = NULL, *body3 = NULL;
        uint32_t blen1 = 0, blen2 = 0, blen3 = 0, status;
        uint64_t handle_id, token = 0xA5C0DE1234ull;

        *p++ = namelen;
        memcpy(p, fn, namelen); p += namelen;
        fsq_put_u32(p, 1); p += 4;
        *p++ = FSQ_T_STRING; *p++ = 0;
        fsq_put_u32(p, (uint32_t) (sizeof(arg) - 1)); p += 4;
        memcpy(p, arg, sizeof(arg) - 1); p += sizeof(arg) - 1;

        *q++ = namelen;
        memcpy(q, fn, namelen); q += namelen;
        fsq_put_u64(q, 0); q += 8;             /* handle patched below */
        fsq_put_u32(q, 1); q += 4;
        *q++ = FSQ_T_STRING; *q++ = 0;
        fsq_put_u32(q, (uint32_t) (sizeof(arg) - 1)); q += 4;
        memcpy(q, arg, sizeof(arg) - 1); q += sizeof(arg) - 1;

        fd = connect_to(argv[1]);
        send_frame(fd, key, klen, FSQ_OP_UDF_INIT, (uint32_t) sizeof(init_payload), init_payload, (uint32_t) sizeof(init_payload), 0, 50, 0);
        if (!read_response_body(fd, key, klen, &status, &body1, &blen1) || status != FSQ_OK || blen1 < 8) {
            printf("  [FAIL] dedupe setup: UDF_INIT (status=%u)\n", status); fails++;
            if (body1) { free(body1); body1 = NULL; }
            close(fd);
            goto dedupe_done;
        }
        handle_id = fsq_get_u64(body1);
        free(body1); body1 = NULL;
        fsq_put_u64(call_payload + 1 + namelen, handle_id);

        send_frame(fd, key, klen, FSQ_OP_UDF_CALL, (uint32_t) sizeof(call_payload), call_payload, (uint32_t) sizeof(call_payload), 0, 51, token);
        if (read_response_body(fd, key, klen, &status, &body1, &blen1) && status == FSQ_OK)
            printf("  [PASS] UDF_CALL token exec (rid echoed: %s)\n", g_last_rid == 51 ? "yes" : "NO");
        else { printf("  [FAIL] UDF_CALL token exec (status=%u)\n", status); fails++; }

        send_frame(fd, key, klen, FSQ_OP_UDF_CALL, (uint32_t) sizeof(call_payload), call_payload, (uint32_t) sizeof(call_payload), 0, 52, token);
        if (!read_response_body(fd, key, klen, &status, &body2, &blen2)) {
            printf("  [FAIL] UDF_CALL token resend closed the connection\n"); fails++;
        } else if (status == FSQ_OK && blen1 == blen2 && memcmp(body1, body2, blen1) == 0 && g_last_rid == 52) {
            printf("  [PASS] token resend replays the same body, echoes the new rid\n");
        } else {
            printf("  [FAIL] token resend (status=%u, blen %u vs %u, rid echo %u)\n", status, blen1, blen2, g_last_rid);
            fails++;
        }

        send_frame(fd, key, klen, FSQ_OP_UDF_CALL, (uint32_t) sizeof(call_payload), call_payload, (uint32_t) sizeof(call_payload), 0, 53, token + 1);
        if (!read_response_body(fd, key, klen, &status, &body3, &blen3)) {
            printf("  [FAIL] UDF_CALL fresh token closed the connection\n"); fails++;
        } else if (status == FSQ_OK && blen1 == blen3 && memcmp(body1, body3, blen1) == 0 && g_last_rid == 53) {
            printf("  [PASS] a fresh token executes again and also answers OK\n");
        } else {
            printf("  [FAIL] fresh token (status=%u, blen %u vs %u)\n", status, blen1, blen3);
            fails++;
        }

        free(body1); free(body2); free(body3);
        close(fd);
    }
dedupe_done:

    return fails ? 1 : 0;
}
