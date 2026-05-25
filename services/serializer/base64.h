#ifndef BASE64_H
#define BASE64_H

#include <stddef.h>
#include <stdint.h>

/* Base64 リターンコード（正の値は書き込みバイト数） */
#define BASE64_ERR_NULL     -1
#define BASE64_ERR_OVERFLOW -2
#define BASE64_ERR_INVALID  -3

/* 入出力長を計算するユーティリティ（NUL を含む） */
size_t base64_encoded_size(size_t input_len);
size_t base64_decoded_size(size_t input_len);

/* 標準 Base64 (RFC 4648, パディングあり) */
int base64_encode(const uint8_t *in, size_t in_len, char *out, size_t out_size);
int base64_decode(const char *in, size_t in_len, uint8_t *out, size_t out_size);

/* URL-safe バリアント (パディングなし) */
int base64_encode_url(const uint8_t *in, size_t in_len, char *out, size_t out_size);
int base64_decode_url(const char *in, size_t in_len, uint8_t *out, size_t out_size);

#endif /* BASE64_H */
