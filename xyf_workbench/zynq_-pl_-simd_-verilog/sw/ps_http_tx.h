#ifndef PS_HTTP_TX_H
#define PS_HTTP_TX_H
#include <stdint.h>
typedef struct { uint16_t length, queued; } http_tx_state;
typedef int (*http_tx_write_fn)(void *, const char *, uint16_t);
/* One bounded write per service call; 1 from writer means retry later. */
static inline int http_tx_step(http_tx_state *s, const char *data,
                               uint16_t room, http_tx_write_fn writer, void *ctx)
{
    uint16_t n;
    int rc;
    if (s->queued >= s->length) return 0;
    n = (uint16_t)(s->length - s->queued);
    if (n > room) n = room;
    if (n > 1460) n = 1460;
    if (!n) return 0;
    rc = writer(ctx, data + s->queued, n);
    if (rc) return rc < 0 ? -1 : 0;
    s->queued = (uint16_t)(s->queued + n);
    return 1;
}
#endif
