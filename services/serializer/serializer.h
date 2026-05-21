#ifndef SERIALIZER_H
#define SERIALIZER_H

#include <stdint.h>
#include <stddef.h>

/* ---- バイナリプロトコル定数 ---- */

#define MAGIC_NUMBER      0x4B525455u   /* "KRTU" */
#define FORMAT_VERSION    1
#define MAX_CARDS         256
#define MAX_FUDA_LEN      64
#define MAX_YOMI_LEN      256
#define MAX_IMAGE_LEN     256
#define MAX_PAYLOAD_SIZE  65536

/* エラーコード */
#define SER_OK               0
#define SER_ERR_NULL        -1
#define SER_ERR_OVERFLOW    -2
#define SER_ERR_MAGIC       -3
#define SER_ERR_VERSION     -4
#define SER_ERR_TRUNCATED   -5
#define SER_ERR_INVALID     -6
#define SER_ERR_TOO_MANY    -7

/* ---- カードの構造体 ---- */

typedef struct {
    uint32_t id;
    char     fuda[MAX_FUDA_LEN];
    char     yomi[MAX_YOMI_LEN];
    char     image[MAX_IMAGE_LEN];
} Card;

typedef struct {
    uint32_t magic;
    uint8_t  version;
    uint8_t  reserved[3];
    uint32_t card_count;
} CardPacketHeader;

typedef struct {
    CardPacketHeader header;
    Card             cards[MAX_CARDS];
    uint32_t         checksum;
} CardPacket;

/* ---- シリアライズ/デシリアライズ関数 ---- */

int  card_pack(const Card *cards, uint32_t count, uint8_t *out, size_t out_size, size_t *written);
int  card_unpack(const uint8_t *buf, size_t buf_size, Card *cards_out, uint32_t max_cards, uint32_t *count_out);

/* ---- 単体カード操作 ---- */

int  card_encode_single(const Card *card, uint8_t *out, size_t out_size, size_t *written);
int  card_decode_single(const uint8_t *buf, size_t buf_size, Card *card_out, size_t *consumed);

/* ---- JSON変換 ---- */

int  card_to_json(const Card *card, char *out, size_t out_size);
int  cards_to_json_array(const Card *cards, uint32_t count, char *out, size_t out_size);
int  card_from_json(const char *json, size_t json_len, Card *card_out);

/* ---- バリデーション ---- */

int  card_validate(const Card *card);
int  cards_validate_all(const Card *cards, uint32_t count);

/* ---- チェックサム ---- */

uint32_t crc32_compute(const uint8_t *data, size_t len);
int      checksum_verify(const uint8_t *buf, size_t data_len, uint32_t expected);

/* ---- HTTP サーバー ---- */

typedef struct {
    int    port;
    int    backlog;
    int    timeout_sec;
} ServerConfig;

void server_run(const ServerConfig *cfg, const Card *cards, uint32_t card_count);

/* ---- ユーティリティ ---- */

void card_print(const Card *card);
void cards_print_all(const Card *cards, uint32_t count);
const char *ser_strerror(int code);

#endif /* SERIALIZER_H */
