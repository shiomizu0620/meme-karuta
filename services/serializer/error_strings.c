/* 各モジュールのエラーコードを文字列に変換するヘルパー。 */

#include "serializer.h"
#include "checksum.h"

const char *serializer_strerror(int code) {
    switch (code) {
        case SER_OK:            return "ok";
        case SER_ERR_NULL:      return "null";
        case SER_ERR_OVERFLOW:  return "overflow";
        case SER_ERR_MAGIC:     return "bad magic";
        case SER_ERR_VERSION:   return "bad version";
        case SER_ERR_TRUNCATED: return "truncated";
        case SER_ERR_INVALID:   return "invalid";
        case SER_ERR_TOO_MANY:  return "too many";
        default:                return "unknown";
    }
}
