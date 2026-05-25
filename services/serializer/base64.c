/*
 * Base64 エンコーダ / デコーダ。
 *
 * バイナリにシリアライズしたカードペイロードを JSON や URL に埋める時に使う。
 * 標準ライブラリには入っていないので自前で実装する。
 *
 * - RFC 4648 準拠（標準 Base64、パディングあり）
 * - URL-safe バリアント（'-' と '_'）も提供
 * - 入力長から必要な出力長を予め計算できるユーティリティを用意
 */

#include "base64.h"

#include <stddef.h>
#include <stdint.h>

static const char STD_ALPHABET[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static const char URL_ALPHABET[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/* 不正文字を示すセンチネル */
#define BAD 0xFF

static uint8_t decode_table_std[256];
static uint8_t decode_table_url[256];
static int     decode_tables_ready = 0;

static void build_decode_tables(void) {
    for (int i = 0; i < 256; i++) {
        decode_table_std[i] = BAD;
        decode_table_url[i] = BAD;
    }
    for (int i = 0; i < 64; i++) {
        decode_table_std[(int)STD_ALPHABET[i]] = (uint8_t)i;
        decode_table_url[(int)URL_ALPHABET[i]] = (uint8_t)i;
    }
    decode_tables_ready = 1;
}

size_t base64_encoded_size(size_t input_len) {
    return ((input_len + 2) / 3) * 4 + 1; /* +1 for NUL */
}

size_t base64_decoded_size(size_t input_len) {
    /* 上限。実際のサイズは末尾の '=' で減る */
    return (input_len / 4) * 3 + 1;
}

static int do_encode(
    const uint8_t *in, size_t in_len,
    char *out, size_t out_size,
    const char *alphabet,
    int with_padding
) {
    if (in == NULL || out == NULL) {
        return BASE64_ERR_NULL;
    }
    size_t needed = base64_encoded_size(in_len);
    if (out_size < needed) {
        return BASE64_ERR_OVERFLOW;
    }

    size_t i = 0, j = 0;
    while (i + 3 <= in_len) {
        uint32_t triple = ((uint32_t)in[i] << 16) | ((uint32_t)in[i+1] << 8) | (uint32_t)in[i+2];
        out[j++] = alphabet[(triple >> 18) & 0x3F];
        out[j++] = alphabet[(triple >> 12) & 0x3F];
        out[j++] = alphabet[(triple >> 6) & 0x3F];
        out[j++] = alphabet[triple & 0x3F];
        i += 3;
    }

    size_t rem = in_len - i;
    if (rem == 1) {
        uint32_t v = (uint32_t)in[i] << 16;
        out[j++] = alphabet[(v >> 18) & 0x3F];
        out[j++] = alphabet[(v >> 12) & 0x3F];
        if (with_padding) {
            out[j++] = '=';
            out[j++] = '=';
        }
    } else if (rem == 2) {
        uint32_t v = ((uint32_t)in[i] << 16) | ((uint32_t)in[i+1] << 8);
        out[j++] = alphabet[(v >> 18) & 0x3F];
        out[j++] = alphabet[(v >> 12) & 0x3F];
        out[j++] = alphabet[(v >> 6) & 0x3F];
        if (with_padding) {
            out[j++] = '=';
        }
    }

    out[j] = '\0';
    return (int)j;
}

int base64_encode(const uint8_t *in, size_t in_len, char *out, size_t out_size) {
    return do_encode(in, in_len, out, out_size, STD_ALPHABET, 1);
}

int base64_encode_url(const uint8_t *in, size_t in_len, char *out, size_t out_size) {
    return do_encode(in, in_len, out, out_size, URL_ALPHABET, 0);
}

static int do_decode(
    const char *in, size_t in_len,
    uint8_t *out, size_t out_size,
    const uint8_t *decode_table
) {
    if (in == NULL || out == NULL) {
        return BASE64_ERR_NULL;
    }
    if (!decode_tables_ready) {
        build_decode_tables();
    }

    /* パディングを取り除いた実効長を計算 */
    while (in_len > 0 && in[in_len - 1] == '=') {
        in_len--;
    }

    size_t out_pos = 0;
    uint32_t buffer = 0;
    int bits = 0;

    for (size_t i = 0; i < in_len; i++) {
        uint8_t v = decode_table[(uint8_t)in[i]];
        if (v == BAD) {
            return BASE64_ERR_INVALID;
        }
        buffer = (buffer << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (out_pos >= out_size) {
                return BASE64_ERR_OVERFLOW;
            }
            out[out_pos++] = (uint8_t)((buffer >> bits) & 0xFFu);
        }
    }
    return (int)out_pos;
}

int base64_decode(const char *in, size_t in_len, uint8_t *out, size_t out_size) {
    if (!decode_tables_ready) {
        build_decode_tables();
    }
    return do_decode(in, in_len, out, out_size, decode_table_std);
}

int base64_decode_url(const char *in, size_t in_len, uint8_t *out, size_t out_size) {
    if (!decode_tables_ready) {
        build_decode_tables();
    }
    return do_decode(in, in_len, out, out_size, decode_table_url);
}
