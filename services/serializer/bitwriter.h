#ifndef BITWRITER_H
#define BITWRITER_H

#include <stddef.h>
#include <stdint.h>

#define BIT_OK            0
#define BIT_ERR_NULL     -1
#define BIT_ERR_OVERFLOW -2
#define BIT_ERR_INVALID  -3

typedef struct {
    uint8_t *buf;
    size_t   buf_size;
    size_t   bit_pos;
} BitWriter;

typedef struct {
    const uint8_t *buf;
    size_t         buf_size;
    size_t         bit_pos;
} BitReader;

int    bitwriter_init(BitWriter *bw, uint8_t *buf, size_t buf_size);
int    bitwriter_write(BitWriter *bw, uint32_t value, uint8_t bits);
size_t bitwriter_bytes_used(const BitWriter *bw);
void   bitwriter_align_byte(BitWriter *bw);

int bitreader_init(BitReader *br, const uint8_t *buf, size_t buf_size);
int bitreader_read(BitReader *br, uint8_t bits, uint32_t *out);

/* 最大ビット幅。32bit ワード単位の書き込みを保証する。 */
#define BIT_MAX_WIDTH 32

#endif /* BITWRITER_H */
