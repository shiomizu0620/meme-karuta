/*
 * metrics.c - serializer サービスの軽量メトリクス収集モジュール。
 *
 * Prometheus 互換のテキスト形式で /metrics エンドポイントから露出させるための
 * 累計カウンタとヒストグラム計算を提供する。スレッドセーフ性は POSIX の
 * pthread_mutex で確保している（serializer.c の HTTP サーバーは accept 後に
 * 別スレッドへ振り分けるため）。
 */

#include "metrics.h"
#include <stdio.h>
#include <string.h>
#include <pthread.h>

/* ヒストグラムのバケット境界（ナノ秒）。シリアライズ処理は短いため細かめ。 */
static const long histogram_buckets_ns[METRICS_HIST_SIZE] = {
    1000L,        /* 1µs */
    5000L,        /* 5µs */
    25000L,       /* 25µs */
    100000L,      /* 100µs */
    500000L,      /* 500µs */
    1000000L,     /* 1ms */
    5000000L,     /* 5ms */
    25000000L,    /* 25ms */
    100000000L,   /* 100ms */
    500000000L,   /* 500ms */
};

static MetricsState g_state;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_initialized = 0;

void metrics_init(void)
{
    pthread_mutex_lock(&g_lock);
    if (!g_initialized) {
        memset(&g_state, 0, sizeof(g_state));
        g_initialized = 1;
    }
    pthread_mutex_unlock(&g_lock);
}

void metrics_record_pack(size_t card_count, size_t bytes_written, long elapsed_ns, int error_code)
{
    pthread_mutex_lock(&g_lock);
    g_state.packs_total++;
    if (error_code != 0) {
        g_state.packs_errors++;
    } else {
        g_state.cards_packed_total += (uint64_t)card_count;
        g_state.bytes_packed_total += (uint64_t)bytes_written;
        g_state.pack_elapsed_ns_sum += (uint64_t)elapsed_ns;
        g_state.pack_elapsed_ns_count++;
        for (int i = 0; i < METRICS_HIST_SIZE; ++i) {
            if (elapsed_ns <= histogram_buckets_ns[i]) {
                g_state.pack_hist[i]++;
                goto recorded;
            }
        }
        g_state.pack_hist[METRICS_HIST_SIZE]++;
    recorded: ;
    }
    pthread_mutex_unlock(&g_lock);
}

void metrics_record_unpack(size_t cards_read, long elapsed_ns, int error_code)
{
    pthread_mutex_lock(&g_lock);
    g_state.unpacks_total++;
    if (error_code != 0) {
        g_state.unpacks_errors++;
    } else {
        g_state.cards_unpacked_total += (uint64_t)cards_read;
        g_state.unpack_elapsed_ns_sum += (uint64_t)elapsed_ns;
        g_state.unpack_elapsed_ns_count++;
    }
    pthread_mutex_unlock(&g_lock);
}

void metrics_record_request(int status_code)
{
    pthread_mutex_lock(&g_lock);
    g_state.requests_total++;
    if (status_code >= 200 && status_code < 300)      g_state.requests_2xx++;
    else if (status_code >= 400 && status_code < 500) g_state.requests_4xx++;
    else if (status_code >= 500)                      g_state.requests_5xx++;
    pthread_mutex_unlock(&g_lock);
}

double metrics_pack_avg_ns(void)
{
    pthread_mutex_lock(&g_lock);
    double avg = 0.0;
    if (g_state.pack_elapsed_ns_count > 0) {
        avg = (double)g_state.pack_elapsed_ns_sum / (double)g_state.pack_elapsed_ns_count;
    }
    pthread_mutex_unlock(&g_lock);
    return avg;
}

int metrics_render_prometheus(char *out, size_t out_size)
{
    if (!out || out_size == 0) return -1;
    pthread_mutex_lock(&g_lock);
    int n = 0;
    n += snprintf(out + n, (n < (int)out_size) ? out_size - n : 0,
        "# HELP serializer_packs_total Total pack operations\n"
        "# TYPE serializer_packs_total counter\n"
        "serializer_packs_total %llu\n"
        "# HELP serializer_pack_errors_total Pack operations that returned an error\n"
        "# TYPE serializer_pack_errors_total counter\n"
        "serializer_pack_errors_total %llu\n"
        "# HELP serializer_unpacks_total Total unpack operations\n"
        "# TYPE serializer_unpacks_total counter\n"
        "serializer_unpacks_total %llu\n"
        "# HELP serializer_unpack_errors_total Unpack operations that returned an error\n"
        "# TYPE serializer_unpack_errors_total counter\n"
        "serializer_unpack_errors_total %llu\n"
        "# HELP serializer_cards_packed_total Cards successfully packed\n"
        "# TYPE serializer_cards_packed_total counter\n"
        "serializer_cards_packed_total %llu\n"
        "# HELP serializer_bytes_packed_total Bytes emitted by pack\n"
        "# TYPE serializer_bytes_packed_total counter\n"
        "serializer_bytes_packed_total %llu\n",
        (unsigned long long)g_state.packs_total,
        (unsigned long long)g_state.packs_errors,
        (unsigned long long)g_state.unpacks_total,
        (unsigned long long)g_state.unpacks_errors,
        (unsigned long long)g_state.cards_packed_total,
        (unsigned long long)g_state.bytes_packed_total);

    n += snprintf(out + n, (n < (int)out_size) ? out_size - n : 0,
        "# HELP serializer_requests_total HTTP requests by status class\n"
        "# TYPE serializer_requests_total counter\n"
        "serializer_requests_total{class=\"2xx\"} %llu\n"
        "serializer_requests_total{class=\"4xx\"} %llu\n"
        "serializer_requests_total{class=\"5xx\"} %llu\n",
        (unsigned long long)g_state.requests_2xx,
        (unsigned long long)g_state.requests_4xx,
        (unsigned long long)g_state.requests_5xx);

    uint64_t cum = 0;
    for (int i = 0; i < METRICS_HIST_SIZE; ++i) {
        cum += g_state.pack_hist[i];
        n += snprintf(out + n, (n < (int)out_size) ? out_size - n : 0,
            "serializer_pack_latency_ns_bucket{le=\"%ld\"} %llu\n",
            histogram_buckets_ns[i], (unsigned long long)cum);
    }
    cum += g_state.pack_hist[METRICS_HIST_SIZE];
    n += snprintf(out + n, (n < (int)out_size) ? out_size - n : 0,
        "serializer_pack_latency_ns_bucket{le=\"+Inf\"} %llu\n",
        (unsigned long long)cum);

    pthread_mutex_unlock(&g_lock);
    return n;
}

void metrics_reset(void)
{
    pthread_mutex_lock(&g_lock);
    memset(&g_state, 0, sizeof(g_state));
    pthread_mutex_unlock(&g_lock);
}
