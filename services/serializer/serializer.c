#include "serializer.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <ctype.h>

#ifdef _WIN32
  #include <winsock2.h>
  #include <ws2tcpip.h>
  #pragma comment(lib, "ws2_32.lib")
  typedef int ssize_t;
#else
  #include <sys/socket.h>
  #include <netinet/in.h>
  #include <arpa/inet.h>
  #include <unistd.h>
  #define closesocket close
#endif

/* ---- 内部マクロ ---- */

#define WRITE_U8(p, v)  do { *(p)++ = (uint8_t)(v); } while(0)
#define WRITE_U32(p, v) do { \
    uint32_t _v = (v); \
    *(p)++ = (_v >> 24) & 0xFF; \
    *(p)++ = (_v >> 16) & 0xFF; \
    *(p)++ = (_v >>  8) & 0xFF; \
    *(p)++ = (_v      ) & 0xFF; \
} while(0)

#define READ_U8(p)  (*(p)++)
#define READ_U32(p) (((uint32_t)(p)[0] << 24) | ((uint32_t)(p)[1] << 16) | \
                     ((uint32_t)(p)[2] <<  8) | ((uint32_t)(p)[3]), (p) += 4, \
                     ((uint32_t)((p)-4)[0] << 24) | ((uint32_t)((p)-4)[1] << 16) | \
                     ((uint32_t)((p)-4)[2] <<  8) | ((uint32_t)((p)-4)[3]))

/* ---- CRC-32 テーブル生成 ---- */

static uint32_t crc32_table[256];
static int      crc32_table_ready = 0;

static void crc32_init_table(void) {
    uint32_t i, j, c;
    for (i = 0; i < 256; i++) {
        c = i;
        for (j = 0; j < 8; j++)
            c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        crc32_table[i] = c;
    }
    crc32_table_ready = 1;
}

uint32_t crc32_compute(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFFu;
    size_t i;
    if (!crc32_table_ready) crc32_init_table();
    for (i = 0; i < len; i++)
        crc = crc32_table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}

int checksum_verify(const uint8_t *buf, size_t data_len, uint32_t expected) {
    return crc32_compute(buf, data_len) == expected ? SER_OK : SER_ERR_INVALID;
}

/* ---- バリデーション ---- */

int card_validate(const Card *card) {
    if (!card) return SER_ERR_NULL;
    if (card->id == 0) return SER_ERR_INVALID;
    if (card->fuda[0] == '\0') return SER_ERR_INVALID;
    if (card->yomi[0] == '\0') return SER_ERR_INVALID;
    if (card->image[0] == '\0') return SER_ERR_INVALID;
    if (strnlen(card->fuda,  MAX_FUDA_LEN)  == MAX_FUDA_LEN)  return SER_ERR_OVERFLOW;
    if (strnlen(card->yomi,  MAX_YOMI_LEN)  == MAX_YOMI_LEN)  return SER_ERR_OVERFLOW;
    if (strnlen(card->image, MAX_IMAGE_LEN) == MAX_IMAGE_LEN) return SER_ERR_OVERFLOW;
    return SER_OK;
}

int cards_validate_all(const Card *cards, uint32_t count) {
    uint32_t i;
    for (i = 0; i < count; i++) {
        int r = card_validate(&cards[i]);
        if (r != SER_OK) return r;
    }
    return SER_OK;
}

/* ---- 単体カードのエンコード ---- */

int card_encode_single(const Card *card, uint8_t *out, size_t out_size, size_t *written) {
    uint8_t *p = out;
    size_t fuda_len, yomi_len, img_len, total;
    int r;

    if (!card || !out || !written) return SER_ERR_NULL;
    r = card_validate(card);
    if (r != SER_OK) return r;

    fuda_len = strlen(card->fuda);
    yomi_len = strlen(card->yomi);
    img_len  = strlen(card->image);
    total    = 4 + 2 + fuda_len + 2 + yomi_len + 2 + img_len;

    if (out_size < total) return SER_ERR_OVERFLOW;

    /* id (4 bytes big-endian) */
    *p++ = (card->id >> 24) & 0xFF;
    *p++ = (card->id >> 16) & 0xFF;
    *p++ = (card->id >>  8) & 0xFF;
    *p++ = (card->id      ) & 0xFF;

    /* fuda: length-prefixed (2 bytes) */
    *p++ = (fuda_len >> 8) & 0xFF;
    *p++ = fuda_len & 0xFF;
    memcpy(p, card->fuda, fuda_len);
    p += fuda_len;

    /* yomi: length-prefixed (2 bytes) */
    *p++ = (yomi_len >> 8) & 0xFF;
    *p++ = yomi_len & 0xFF;
    memcpy(p, card->yomi, yomi_len);
    p += yomi_len;

    /* image: length-prefixed (2 bytes) */
    *p++ = (img_len >> 8) & 0xFF;
    *p++ = img_len & 0xFF;
    memcpy(p, card->image, img_len);
    p += img_len;

    *written = (size_t)(p - out);
    return SER_OK;
}

/* ---- 単体カードのデコード ---- */

int card_decode_single(const uint8_t *buf, size_t buf_size, Card *card_out, size_t *consumed) {
    const uint8_t *p = buf;
    size_t remaining;
    uint16_t flen, ylen, ilen;

    if (!buf || !card_out || !consumed) return SER_ERR_NULL;
    if (buf_size < 10) return SER_ERR_TRUNCATED;

    memset(card_out, 0, sizeof(Card));

    card_out->id  = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
                  | ((uint32_t)p[2] <<  8) |  (uint32_t)p[3];
    p += 4;

    remaining = buf_size - 4;

    if (remaining < 2) return SER_ERR_TRUNCATED;
    flen = ((uint16_t)p[0] << 8) | p[1];
    p += 2; remaining -= 2;
    if (remaining < flen || flen >= MAX_FUDA_LEN) return SER_ERR_TRUNCATED;
    memcpy(card_out->fuda, p, flen);
    card_out->fuda[flen] = '\0';
    p += flen; remaining -= flen;

    if (remaining < 2) return SER_ERR_TRUNCATED;
    ylen = ((uint16_t)p[0] << 8) | p[1];
    p += 2; remaining -= 2;
    if (remaining < ylen || ylen >= MAX_YOMI_LEN) return SER_ERR_TRUNCATED;
    memcpy(card_out->yomi, p, ylen);
    card_out->yomi[ylen] = '\0';
    p += ylen; remaining -= ylen;

    if (remaining < 2) return SER_ERR_TRUNCATED;
    ilen = ((uint16_t)p[0] << 8) | p[1];
    p += 2; remaining -= 2;
    if (remaining < ilen || ilen >= MAX_IMAGE_LEN) return SER_ERR_TRUNCATED;
    memcpy(card_out->image, p, ilen);
    card_out->image[ilen] = '\0';
    p += ilen;

    *consumed = (size_t)(p - buf);
    return SER_OK;
}

/* ---- 複数カードのシリアライズ ---- */

int card_pack(const Card *cards, uint32_t count, uint8_t *out, size_t out_size, size_t *written) {
    uint8_t *p = out;
    uint32_t i;
    size_t card_bytes;
    int r;

    if (!cards || !out || !written) return SER_ERR_NULL;
    if (count > MAX_CARDS) return SER_ERR_TOO_MANY;
    if (out_size < 16) return SER_ERR_OVERFLOW;

    r = cards_validate_all(cards, count);
    if (r != SER_OK) return r;

    /* ヘッダー書き込み */
    *p++ = (MAGIC_NUMBER >> 24) & 0xFF;
    *p++ = (MAGIC_NUMBER >> 16) & 0xFF;
    *p++ = (MAGIC_NUMBER >>  8) & 0xFF;
    *p++ = (MAGIC_NUMBER      ) & 0xFF;
    *p++ = FORMAT_VERSION;
    *p++ = 0; *p++ = 0; *p++ = 0;       /* reserved */
    *p++ = (count >> 24) & 0xFF;
    *p++ = (count >> 16) & 0xFF;
    *p++ = (count >>  8) & 0xFF;
    *p++ = (count      ) & 0xFF;

    for (i = 0; i < count; i++) {
        r = card_encode_single(&cards[i], p, out_size - (size_t)(p - out), &card_bytes);
        if (r != SER_OK) return r;
        p += card_bytes;
    }

    /* チェックサム */
    {
        size_t data_len = (size_t)(p - out);
        uint32_t crc    = crc32_compute(out, data_len);
        if (out_size - data_len < 4) return SER_ERR_OVERFLOW;
        *p++ = (crc >> 24) & 0xFF;
        *p++ = (crc >> 16) & 0xFF;
        *p++ = (crc >>  8) & 0xFF;
        *p++ = (crc      ) & 0xFF;
    }

    *written = (size_t)(p - out);
    return SER_OK;
}

/* ---- 複数カードのデシリアライズ ---- */

int card_unpack(const uint8_t *buf, size_t buf_size, Card *cards_out, uint32_t max_cards, uint32_t *count_out) {
    const uint8_t *p = buf;
    uint32_t magic, version, count, i, stored_crc, computed_crc;
    size_t consumed;
    int r;

    if (!buf || !cards_out || !count_out) return SER_ERR_NULL;
    if (buf_size < 16) return SER_ERR_TRUNCATED;

    magic = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
          | ((uint32_t)p[2] <<  8) |  (uint32_t)p[3];
    if (magic != MAGIC_NUMBER) return SER_ERR_MAGIC;
    p += 4;

    version = *p++;
    if (version != FORMAT_VERSION) return SER_ERR_VERSION;
    p += 3;  /* reserved */

    count = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
          | ((uint32_t)p[2] <<  8) |  (uint32_t)p[3];
    p += 4;

    if (count > max_cards) return SER_ERR_TOO_MANY;

    for (i = 0; i < count; i++) {
        r = card_decode_single(p, buf_size - (size_t)(p - buf) - 4, &cards_out[i], &consumed);
        if (r != SER_OK) return r;
        p += consumed;
    }

    /* チェックサム検証 */
    if (buf_size - (size_t)(p - buf) < 4) return SER_ERR_TRUNCATED;
    stored_crc   = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16)
                 | ((uint32_t)p[2] <<  8) |  (uint32_t)p[3];
    computed_crc = crc32_compute(buf, (size_t)(p - buf));
    if (stored_crc != computed_crc) return SER_ERR_INVALID;

    *count_out = count;
    return SER_OK;
}

/* ---- JSON 出力 ---- */

static void json_escape_string(const char *src, char *dst, size_t dst_size) {
    size_t i = 0, j = 0;
    while (src[i] && j + 4 < dst_size) {
        switch (src[i]) {
            case '"':  dst[j++] = '\\'; dst[j++] = '"';  break;
            case '\\': dst[j++] = '\\'; dst[j++] = '\\'; break;
            case '\n': dst[j++] = '\\'; dst[j++] = 'n';  break;
            case '\r': dst[j++] = '\\'; dst[j++] = 'r';  break;
            case '\t': dst[j++] = '\\'; dst[j++] = 't';  break;
            default:   dst[j++] = src[i];
        }
        i++;
    }
    dst[j] = '\0';
}

int card_to_json(const Card *card, char *out, size_t out_size) {
    char fuda[MAX_FUDA_LEN * 2], yomi[MAX_YOMI_LEN * 2], image[MAX_IMAGE_LEN * 2];
    int n;
    if (!card || !out) return SER_ERR_NULL;
    json_escape_string(card->fuda,  fuda,  sizeof(fuda));
    json_escape_string(card->yomi,  yomi,  sizeof(yomi));
    json_escape_string(card->image, image, sizeof(image));
    n = snprintf(out, out_size,
        "{\"id\":%u,\"fuda\":\"%s\",\"yomi\":\"%s\",\"image\":\"%s\"}",
        card->id, fuda, yomi, image);
    return (n >= 0 && (size_t)n < out_size) ? SER_OK : SER_ERR_OVERFLOW;
}

int cards_to_json_array(const Card *cards, uint32_t count, char *out, size_t out_size) {
    char card_buf[1024];
    size_t pos = 0;
    uint32_t i;
    int r;
    if (!cards || !out) return SER_ERR_NULL;
    if (out_size < 3) return SER_ERR_OVERFLOW;

    out[pos++] = '[';
    for (i = 0; i < count; i++) {
        r = card_to_json(&cards[i], card_buf, sizeof(card_buf));
        if (r != SER_OK) return r;
        size_t clen = strlen(card_buf);
        if (pos + clen + 3 >= out_size) return SER_ERR_OVERFLOW;
        if (i > 0) out[pos++] = ',';
        memcpy(out + pos, card_buf, clen);
        pos += clen;
    }
    out[pos++] = ']';
    out[pos]   = '\0';
    return SER_OK;
}

/* ---- 表示 ---- */

void card_print(const Card *card) {
    if (!card) return;
    printf("Card { id=%u, fuda=\"%s\", yomi=\"%s\", image=\"%s\" }\n",
           card->id, card->fuda, card->yomi, card->image);
}

void cards_print_all(const Card *cards, uint32_t count) {
    uint32_t i;
    printf("=== %u cards ===\n", count);
    for (i = 0; i < count; i++) card_print(&cards[i]);
}

const char *ser_strerror(int code) {
    switch (code) {
        case SER_OK:           return "OK";
        case SER_ERR_NULL:     return "null pointer";
        case SER_ERR_OVERFLOW: return "buffer overflow";
        case SER_ERR_MAGIC:    return "invalid magic number";
        case SER_ERR_VERSION:  return "unsupported format version";
        case SER_ERR_TRUNCATED:return "truncated data";
        case SER_ERR_INVALID:  return "invalid data / checksum mismatch";
        case SER_ERR_TOO_MANY: return "too many cards";
        default:               return "unknown error";
    }
}

/* ---- HTTP サーバー（最小実装） ---- */

static int send_all(int fd, const char *buf, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, buf + sent, len - sent, 0);
        if (n <= 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}

static void http_response(int fd, int status, const char *body, size_t body_len) {
    char header[256];
    const char *status_text = (status == 200) ? "OK" : "Not Found";
    snprintf(header, sizeof(header),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: application/json; charset=utf-8\r\n"
        "Content-Length: %zu\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Connection: close\r\n"
        "\r\n",
        status, status_text, body_len);
    send_all(fd, header, strlen(header));
    send_all(fd, body, body_len);
}

static void handle_connection(int client_fd, const Card *cards, uint32_t count) {
    char req_buf[2048] = {0};
    ssize_t n = recv(client_fd, req_buf, sizeof(req_buf) - 1, 0);
    if (n <= 0) goto done;
    req_buf[n] = '\0';

    if (strncmp(req_buf, "GET /health", 11) == 0) {
        const char *body = "{\"status\":\"ok\"}";
        http_response(client_fd, 200, body, strlen(body));
    } else if (strncmp(req_buf, "GET /serial/cards", 17) == 0) {
        char json[MAX_PAYLOAD_SIZE];
        int r = cards_to_json_array(cards, count, json, sizeof(json));
        if (r == SER_OK) {
            http_response(client_fd, 200, json, strlen(json));
        } else {
            const char *err = "{\"error\":\"serialization failed\"}";
            http_response(client_fd, 500, err, strlen(err));
        }
    } else if (strncmp(req_buf, "GET /serial/binary", 18) == 0) {
        uint8_t binary[MAX_PAYLOAD_SIZE];
        size_t written = 0;
        int r = card_pack(cards, count, binary, sizeof(binary), &written);
        if (r == SER_OK) {
            char header[256];
            snprintf(header, sizeof(header),
                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n"
                "Content-Length: %zu\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
                written);
            send_all(client_fd, header, strlen(header));
            send_all(client_fd, (const char *)binary, written);
        } else {
            const char *err = "{\"error\":\"pack failed\"}";
            http_response(client_fd, 500, err, strlen(err));
        }
    } else {
        const char *err = "{\"error\":\"not found\"}";
        http_response(client_fd, 404, err, strlen(err));
    }
done:
    closesocket(client_fd);
}

void server_run(const ServerConfig *cfg, const Card *cards, uint32_t card_count) {
    int server_fd, client_fd;
    struct sockaddr_in addr;
    socklen_t addr_len = sizeof(addr);

#ifdef _WIN32
    WSADATA wsa; WSAStartup(MAKEWORD(2, 2), &wsa);
#endif

    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) { perror("socket"); return; }

    {
        int opt = 1;
        setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&opt, sizeof(opt));
    }

    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port        = htons((uint16_t)cfg->port);

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); closesocket(server_fd); return;
    }
    if (listen(server_fd, cfg->backlog) < 0) {
        perror("listen"); closesocket(server_fd); return;
    }

    printf("serializer listening on :%d\n", cfg->port);

    while (1) {
        client_fd = accept(server_fd, (struct sockaddr *)&addr, &addr_len);
        if (client_fd < 0) continue;
        handle_connection(client_fd, cards, card_count);
    }

    closesocket(server_fd);
}

/* ---- エントリポイント ---- */

int main(void) {
    Card cards[] = {
        {1, "\xe3\x81\x9d\xe3\x81\x86\xe3\x81\xaf\xe3\x81\xaa\xe3\x82\x89\xe3\x82\x93\xe3\x82\x84\xe3\x82\x8d",
            "\xe8\xaa\xb0\xe3\x81\x8c\xe3\x81\xa9\xe3\x81\x86\xe8\xa6\x8b\xe3\x81\xa6\xe3\x82\x82\xe3\x81\x9d\xe3\x81\x86\xe3\x81\xaa\xe3\x82\x8b\xe3\x81\xae\xe3\x81\xab",
            "/images/souhanarannyaro.jpg"},
        {2, "\xe3\x82\x84\xe3\x82\x81\xe3\x82\x8d",
            "\xe8\xa6\x8b\xe3\x81\xa6\xe3\x81\x84\xe3\x82\x8b\xe3\x81\xa0\xe3\x81\x91\xe3\x81\xa7\xe8\x83\x83\xe3\x81\x8c\xe7\x97\x9b\xe3\x81\x8f\xe3\x81\xaa\xe3\x82\x8b",
            "/images/yamero.jpg"},
        {3, "\xe3\x82\x8f\xe3\x81\x8b\xe3\x82\x8b",
            "\xe8\xa8\x80\xe8\xaa\x9e\xe5\x8c\x96\xe3\x81\xa7\xe3\x81\x8d\xe3\x81\xaa\xe3\x81\x8b\xe3\x81\xa3\xe3\x81\x9f\xe6\x84\x9f\xe6\x83\x85\xe3\x82\x92\xe3\x82\xba\xe3\x83\x90\xe3\x83\xaa\xe8\xa8\x80\xe3\x81\x84\xe5\xbd\x93\xe3\x81\xa6\xe3\x82\x89\xe3\x82\x8c\xe3\x81\x9f",
            "/images/wakaru.jpg"},
    };
    uint32_t count = sizeof(cards) / sizeof(cards[0]);

    ServerConfig cfg = { .port = 5004, .backlog = 16, .timeout_sec = 30 };
    server_run(&cfg, cards, count);
    return 0;
}
