#ifndef METRICS_H
#define METRICS_H

#include <stdint.h>
#include <stddef.h>

#define METRICS_HIST_SIZE 10

typedef struct {
    uint64_t packs_total;
    uint64_t packs_errors;
    uint64_t unpacks_total;
    uint64_t unpacks_errors;
    uint64_t cards_packed_total;
    uint64_t bytes_packed_total;
    uint64_t cards_unpacked_total;
    uint64_t pack_elapsed_ns_sum;
    uint64_t pack_elapsed_ns_count;
    uint64_t unpack_elapsed_ns_sum;
    uint64_t unpack_elapsed_ns_count;
    uint64_t pack_hist[METRICS_HIST_SIZE + 1];
    uint64_t requests_total;
    uint64_t requests_2xx;
    uint64_t requests_4xx;
    uint64_t requests_5xx;
} MetricsState;

void   metrics_init(void);
void   metrics_record_pack(size_t card_count, size_t bytes_written, long elapsed_ns, int error_code);
void   metrics_record_unpack(size_t cards_read, long elapsed_ns, int error_code);
void   metrics_record_request(int status_code);
double metrics_pack_avg_ns(void);
int    metrics_render_prometheus(char *out, size_t out_size);
void   metrics_reset(void);

#endif /* METRICS_H */
