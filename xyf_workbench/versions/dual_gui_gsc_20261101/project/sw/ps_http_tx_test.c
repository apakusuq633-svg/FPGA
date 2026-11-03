#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "ps_ui_page.h"
#include "ps_http_tx.h"
static char received[UI_BODY_MAX];
static unsigned used;
static int outcome;
static int write_mock(void *ctx, const char *data, uint16_t n)
{
    (void)ctx;
    assert(n <= 1460);
    if (outcome) return outcome;
    memcpy(received + used, data, n);
    used += n;
    return 0;
}
int main(void)
{
    http_tx_state tx = {(uint16_t)strlen(UI_PAGE_HTML), 0};
    unsigned steps = 0;
    assert(tx.length > 8192);
    assert(http_tx_step(&tx, UI_PAGE_HTML, 0, write_mock, NULL) == 0);
    outcome = 1;
    assert(http_tx_step(&tx, UI_PAGE_HTML, 8192, write_mock, NULL) == 0);
    assert(tx.queued == 0);
    outcome = -1;
    assert(http_tx_step(&tx, UI_PAGE_HTML, 8192, write_mock, NULL) == -1);
    assert(tx.queued == 0);
    outcome = 0;
    while (tx.queued < tx.length) {
        assert(++steps < 1000);
        http_tx_step(&tx, UI_PAGE_HTML, steps % 3 ? 8192 : 127, write_mock, NULL);
    }
    assert(used == tx.length);
    assert(memcmp(received, UI_PAGE_HTML, used) == 0);
    assert(http_tx_step(&tx, UI_PAGE_HTML, 8192, write_mock, NULL) == 0);
    printf("PASS: complete %u-byte homepage with backpressure and bounded TCP writes\n", used);
    return 0;
}
