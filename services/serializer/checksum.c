/*
 * バイナリペイロードのチェックサム計算。
 *
 * シリアライズしたカードデータを WebSocket / HTTP で配信する際に、
 * 改ざんやネットワーク不正切断を検知するための CRC32 と
 * 軽量な fnv-1a ハッシュを実装する。
 *
 * CRC32 はテーブル駆動で初期化時に作る。fnv-1a はテーブル不要なので
 * 短い文字列に向く。両方提供して、用途に応じて使い分ける。
 */

#include "checksum.h"

#include <stddef.h>
#include <stdint.h>

/* ---- CRC32 (IEEE 802.3 多項式) ---- */

#define CRC32_POLY 0xEDB88320u

static uint32_t crc32_table[256];
static int      crc32_table_ready = 0;

static void crc32_build_table(void) {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int j = 0; j < 8; j++) {
            c = (c & 1u) ? (CRC32_POLY ^ (c >> 1)) : (c >> 1);
        }
        crc32_table[i] = c;
    }
    crc32_table_ready = 1;
}

uint32_t checksum_crc32(const uint8_t *data, size_t len) {
    if (data == NULL || len == 0) {
        return 0u;
    }
    if (!crc32_table_ready) {
        crc32_build_table();
    }
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) {
        uint8_t byte = data[i];
        crc = crc32_table[(crc ^ byte) & 0xFFu] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFFu;
}

/* ---- FNV-1a (32bit) ---- */

#define FNV_OFFSET 0x811C9DC5u
#define FNV_PRIME  0x01000193u

uint32_t checksum_fnv1a(const uint8_t *data, size_t len) {
    if (data == NULL || len == 0) {
        return FNV_OFFSET;
    }
    uint32_t hash = FNV_OFFSET;
    for (size_t i = 0; i < len; i++) {
        hash ^= data[i];
        hash *= FNV_PRIME;
    }
    return hash;
}

/* ---- 検証関数 ---- */

int checksum_verify_crc32(const uint8_t *data, size_t len, uint32_t expected) {
    if (data == NULL) {
        return CHECKSUM_ERR_NULL;
    }
    uint32_t actual = checksum_crc32(data, len);
    return (actual == expected) ? CHECKSUM_OK : CHECKSUM_ERR_MISMATCH;
}

int checksum_verify_fnv1a(const uint8_t *data, size_t len, uint32_t expected) {
    if (data == NULL) {
        return CHECKSUM_ERR_NULL;
    }
    uint32_t actual = checksum_fnv1a(data, len);
    return (actual == expected) ? CHECKSUM_OK : CHECKSUM_ERR_MISMATCH;
}

/* ---- 16進エンコード ---- */

static const char HEX_CHARS[] = "0123456789abcdef";

int checksum_to_hex(uint32_t value, char *out, size_t out_size) {
    if (out == NULL || out_size < 9) {
        return CHECKSUM_ERR_NULL;
    }
    for (int i = 7; i >= 0; i--) {
        out[i] = HEX_CHARS[value & 0xFu];
        value >>= 4;
    }
    out[8] = '\0';
    return CHECKSUM_OK;
}
