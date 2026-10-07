/* SPDX-License-Identifier: MIT */
/* SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
 *
 * FSQ wire protocol v2. Shared by the GPL-2.0-only shim and the Apache-2.0
 * daemon. This header must not include any core header. Functions are
 * called by name (see UDF_INIT/UDF_CALL in SPEC.md and functions.def), not
 * by a per-function opcode; v1 used a numeric opcode per function, which
 * this version drops.
 */
#ifndef FSQ_PROTOCOL_H
#define FSQ_PROTOCOL_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define FSQ_MAGIC            "FSQ1"
#define FSQ_PROTOCOL_VERSION 2u
#define FSQ_HEADER_LEN       32u
#define FSQ_TAG_LEN          32u
#define FSQ_MAX_PAYLOAD      ((uint32_t) 80u * 1024u * 1024u)
#define FSQ_MAX_ARGS         64u
#define FSQ_MSG_MAX          512u
#define FSQ_MAX_FN_NAME      63u   /* fits a u8 length prefix; MariaDB identifiers are at most 64 bytes */

#define FSQ_FLAG_RESPONSE 0x1u
#define FSQ_FLAG_ERROR    0x2u

enum fsq_status {
    FSQ_OK = 0,
    FSQ_ERR_ARGS = 1,
    FSQ_ERR_LIMIT = 2,
    FSQ_ERR_CORE = 3,
    FSQ_ERR_NOT_LICENSED = 4,
    FSQ_ERR_AUTH = 5,
    FSQ_ERR_INTERNAL = 6,
    FSQ_ERR_NOTSUP = 7,
    FSQ_ERR_BUSY = 8
};

/* TLV type codes. Argument types 1-4 match the coercions the shim requests. */
enum fsq_type {
    FSQ_T_NULL = 0,
    FSQ_T_STRING = 1,
    FSQ_T_INT = 2,
    FSQ_T_REAL = 3,
    FSQ_T_DECIMAL = 4,
    FSQ_T_BINARY = 5
};

enum fsq_opcode {
#define X(name, code) FSQ_OP_##name = (code),
#include "opcodes.def"
#undef X
};

static inline void fsq_put_u16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t) v; p[1] = (uint8_t) (v >> 8);
}
static inline void fsq_put_u32(uint8_t *p, uint32_t v) {
    for (int i = 0; i < 4; i++) p[i] = (uint8_t) (v >> (8 * i));
}
static inline void fsq_put_u64(uint8_t *p, uint64_t v) {
    for (int i = 0; i < 8; i++) p[i] = (uint8_t) (v >> (8 * i));
}
static inline uint16_t fsq_get_u16(const uint8_t *p) {
    return (uint16_t) (p[0] | (p[1] << 8));
}
static inline uint32_t fsq_get_u32(const uint8_t *p) {
    return (uint32_t) p[0] | ((uint32_t) p[1] << 8) |
           ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}
static inline uint64_t fsq_get_u64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

/* Header layout (offsets in bytes, all little-endian):
 *   0 magic[4]  4 version u16  6 opcode u16  8 flags u32  12 request_id u32
 *   16 context u64  24 auth_len u32  28 payload_len u32
 * The tag follows at 32 and is HMAC-SHA256 over (header || payload). */
struct fsq_header {
    uint16_t version;
    uint16_t opcode;
    uint32_t flags;
    uint32_t request_id;
    uint64_t context;
    uint32_t auth_len;
    uint32_t payload_len;
};

static inline void fsq_header_encode(uint8_t out[FSQ_HEADER_LEN], const struct fsq_header *h) {
    memcpy(out, FSQ_MAGIC, 4);
    fsq_put_u16(out + 4, h->version);
    fsq_put_u16(out + 6, h->opcode);
    fsq_put_u32(out + 8, h->flags);
    fsq_put_u32(out + 12, h->request_id);
    fsq_put_u64(out + 16, h->context);
    fsq_put_u32(out + 24, h->auth_len);
    fsq_put_u32(out + 28, h->payload_len);
}

/* Returns 0 on success, -1 on bad magic. Length and version checks are the
 * caller's job, so both sides enforce them in one place each. */
static inline int fsq_header_decode(const uint8_t in[FSQ_HEADER_LEN], struct fsq_header *h) {
    if (memcmp(in, FSQ_MAGIC, 4) != 0) return -1;
    h->version = fsq_get_u16(in + 4);
    h->opcode = fsq_get_u16(in + 6);
    h->flags = fsq_get_u32(in + 8);
    h->request_id = fsq_get_u32(in + 12);
    h->context = fsq_get_u64(in + 16);
    h->auth_len = fsq_get_u32(in + 24);
    h->payload_len = fsq_get_u32(in + 28);
    return 0;
}

/* Constant-time comparison of two tags. */
static inline int fsq_ct_equal(const uint8_t *a, const uint8_t *b, size_t n) {
    uint8_t diff = 0;
    for (size_t i = 0; i < n; i++) diff |= (uint8_t) (a[i] ^ b[i]);
    return diff == 0;
}

#endif
