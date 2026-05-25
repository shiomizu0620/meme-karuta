#ifndef CHECKSUM_H
#define CHECKSUM_H

#include <stddef.h>
#include <stdint.h>

/* チェックサムリターンコード */
#define CHECKSUM_OK            0
#define CHECKSUM_ERR_NULL     -1
#define CHECKSUM_ERR_MISMATCH -2

/* CRC32 (IEEE 802.3 多項式) を計算する。 */
uint32_t checksum_crc32(const uint8_t *data, size_t len);

/* FNV-1a 32bit ハッシュを計算する。短い文字列向き。 */
uint32_t checksum_fnv1a(const uint8_t *data, size_t len);

/* 期待値と一致するか検証する。一致なら CHECKSUM_OK。 */
int checksum_verify_crc32(const uint8_t *data, size_t len, uint32_t expected);
int checksum_verify_fnv1a(const uint8_t *data, size_t len, uint32_t expected);

/* 32bit 値を 8 文字 + NUL の小文字 16 進文字列に書く。 */
int checksum_to_hex(uint32_t value, char *out, size_t out_size);

#endif /* CHECKSUM_H */
