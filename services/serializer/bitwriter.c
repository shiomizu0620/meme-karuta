/*
 * BitWriter / BitReader: ビット単位で書き込み・読み出しを行う小さなヘルパー。
 *
 * カードペイロードを圧縮するときに、フラグやインデックスをバイト境界を
 * またいで詰める用途で使う。「絵札を取得した bit map」などを 256 枚分
 * 30 バイト程度で表現できる。
 *
 * - リトルエンディアン MSB ファースト固定（プラットフォーム差分を避ける）
 * - バッファ溢れは ERR_OVERFLOW を返す
 */

#include "bitwriter.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

int bitwriter_init(BitWriter *bw, uint8_t *buf, size_t buf_size) {
    if (bw == NULL || buf == NULL) {
        return BIT_ERR_NULL;
    }
    bw->buf = buf;
    bw->buf_size = buf_size;
    bw->bit_pos = 0;
    memset(buf, 0, buf_size);
    return BIT_OK;
}

int bitwriter_write(BitWriter *bw, uint32_t value, uint8_t bits) {
    if (bw == NULL) {
        return BIT_ERR_NULL;
    }
    if (bits == 0 || bits > 32) {
        return BIT_ERR_INVALID;
    }

    size_t needed_bytes = (bw->bit_pos + bits + 7) / 8;
    if (needed_bytes > bw->buf_size) {
        return BIT_ERR_OVERFLOW;
    }

    for (int i = bits - 1; i >= 0; i--) {
        uint32_t bit = (value >> i) & 1u;
        size_t byte_idx = bw->bit_pos / 8;
        size_t bit_idx  = 7 - (bw->bit_pos % 8);
        if (bit) {
            bw->buf[byte_idx] |= (uint8_t)(1u << bit_idx);
        }
        bw->bit_pos++;
    }
    return BIT_OK;
}

size_t bitwriter_bytes_used(const BitWriter *bw) {
    if (bw == NULL) return 0;
    return (bw->bit_pos + 7) / 8;
}

void bitwriter_align_byte(BitWriter *bw) {
    if (bw == NULL) return;
    size_t remainder = bw->bit_pos % 8;
    if (remainder != 0) {
        bw->bit_pos += (8 - remainder);
    }
}

/* ---- BitReader ---- */

int bitreader_init(BitReader *br, const uint8_t *buf, size_t buf_size) {
    if (br == NULL || buf == NULL) {
        return BIT_ERR_NULL;
    }
    br->buf = buf;
    br->buf_size = buf_size;
    br->bit_pos = 0;
    return BIT_OK;
}

int bitreader_read(BitReader *br, uint8_t bits, uint32_t *out) {
    if (br == NULL || out == NULL) {
        return BIT_ERR_NULL;
    }
    if (bits == 0 || bits > 32) {
        return BIT_ERR_INVALID;
    }
    if ((br->bit_pos + bits + 7) / 8 > br->buf_size) {
        return BIT_ERR_OVERFLOW;
    }

    uint32_t value = 0;
    for (uint8_t i = 0; i < bits; i++) {
        size_t byte_idx = br->bit_pos / 8;
        size_t bit_idx  = 7 - (br->bit_pos % 8);
        uint32_t bit = (br->buf[byte_idx] >> bit_idx) & 1u;
        value = (value << 1) | bit;
        br->bit_pos++;
    }
    *out = value;
    return BIT_OK;
}
