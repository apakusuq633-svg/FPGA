/* ps_ui_test.c —— 站 15（网页这一层）的板载自检，兼宿主机的语法闸门
 *
 * 它是**唯二**会实例化 ps_ui_page.h 的 TU（另一个是 sw/ps_ui.c），而 ps_ui.c 因为要
 * #include lwip、没法在宿主机上编，所以脚本 scripts/check_ps_apps.py 里登记的其实是
 * 这一个 —— 也就是说，网页这一层的 host 覆盖**全靠这个文件**。
 *
 * -- 查什么、怎么查 -------------------------------------------------------------------------
 *
 * 1. JSON 逐字节对拍。用一个**手填**的 struct diag_result，期望串写死在下面的 want[]
 *    里，整条 strcmp。手填而不是跑真链，就是为了这个"逐字节"：真链的类别由随机森林
 *    决定、帧与帧不同，拿它做断言只能查结构、查不了值。
 *    ⚠ 这条能抓住 JSON 里少个逗号、字段顺序变了、azim 的符号掉了 —— 这些在浏览器里
 *      表现为整页空白（JSON.parse 直接抛），在串口里一个错都不报。
 * 2. 路由。含三条**故意的**反面用例：/api/statusx（前缀陷阱）、/favicon.ico（浏览器
 *    一定会来问）、以及一行没有空格的垃圾请求。前两条必须 404，第三条不能死循环。
 * 3. 缓冲区不够时报 500，**不是**截断后照发 —— 半句 JSON 比 500 难查得多。
 * 4. 页面里没有一个非 ASCII 字节（串口/编辑器都按 cp936 看待这些字节）。
 * 5. 真链跑一帧，把它变成 JSON，查结构不变量（票数合计 = CLF_N_TREE）。
 *    它顺带把 ps_diag.h 里每个 static 函数都引用到。⚠ 这**不是**被谁强制要求的：
 *    实测（2026-10-08）`gcc -fsyntax-only -Wall -Wextra -Werror` **不跑** -Wunused-function
 *    与 -Wunused-const-variable 那两遍，所以宿主闸门对"头文件里有函数没人用"是瞎的。
 *    那条规矩的真正意义在别处：这是**唯一**会把这些函数实例化出来编译一次的 TU。
 *
 * **不**证明：页面在浏览器里好不好看、板子网口通不通。那两条只能上板（见 scripts/
 * run_board.tcl 与 docs），这里查的是"字节能对上"。
 *
 * -- 内存 -----------------------------------------------------------------------------------
 * 站 11 自己 320 KB + twiddle + 本文件的合成帧 320 KB，全在 DDR（static / .bss）。
 * **别往 DTCM 里放** —— DTCM 只有 16 KB，而且 PL 固件在用。
 */

#include <stdint.h>
#include <string.h>

#include "xil_io.h"
#include "xil_printf.h"

#include "ps_diag.h"        /* 站 11 -> 12 -> 13 的接缝 */
#include "ps_ui_page.h"     /* 本文件要查的那一层 */

static int g_fail;

static void check(int cond, const char *what)
{
    xil_printf("%s %s\r\n", cond ? "OK  " : "FAIL", what);
    if (!cond) {
        g_fail++;
    }
}

/* 全部字节可打印 ASCII（0x20..0x7e，含换行 0x0a）。 */
static int all_ascii(const char *s, int n)
{
    int i;

    for (i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c != '\n' && (c < 0x20 || c > 0x7e)) {
            return 0;
        }
    }
    return 1;
}

/* 手填一次诊断结果：内圈、96/100 票、格 (5,3)、方位 −60%、严重程度 96%。
 *
 * ⚠ 这个夹具必须是**链路真能产出的状态**，三处得自洽：
 *     cls=3 ⇒ 类别名 clf_class_names[2]="inner" ⇒ 赢家票必须落在 votes[2] ⇒ conf=96。
 *   别写成 "cls=inner 配 votes{96,0,3,1}" —— 那样赢家在 0 号位、cls 又指 inner、conf
 *   还说 96，三处互相矛盾，而夹具看不出自己矛盾。这条在这里格外要紧：**下面那个期望串
 *   是网页这一层的唯一判据**，夹具写错就等于判据错。
 *   取的就是本文件末尾真链跑出来的那一组（votes 3/1/96/0），所以期望串不是凭空凑的。 */
static void fill_sample(struct diag_result *r)
{
    memset(r, 0, sizeof *r);
    r->cls = 3;                      /* clf_class_names[2] = "inner" */
    r->votes[0] = 3;
    r->votes[1] = 1;
    r->votes[2] = 96;
    r->votes[3] = 0;
    r->conf_pct = 96;
    r->grid = 53;
    r->grid_w = 16;
    r->gx = 5;
    r->gy = 3;
    r->azim_pct = out_azim_pct(3, 16);   /* 站 13 的映射：−60 */
    r->sev_pct = 96;
    r->med_milli = 1234;
}

/* ------------------------------------------------------------------------------------------
 * 1. JSON 逐字节。
 * ------------------------------------------------------------------------------------------ */
static void check_json_exact(void)
{
    static const char want[] =
        "{\"have\":1,\"synthetic\":1,\"frame\":7,\"age_ms\":250,\"cls\":\"inner\","
        "\"conf\":96,\"votes\":[3,1,96,0],\"grid_w\":16,\"grid\":53,\"gx\":5,\"gy\":3,"
        "\"azim\":-60,\"sev\":96,\"med\":1234}\n";
    char buf[UI_BODY_MAX];
    struct diag_result r;
    struct ui_status s;

    fill_sample(&r);

    /* 先查夹具自己是不是一个可能的状态，再查它能不能被打印成期望的那些字节。
     * 顺序是这样：夹具坏了的时候，"期望串对不上"这个报告会把人引到格式化函数上去，
     * 而错其实在这儿。这条断言就是我写这个夹具时踩的坑（cls 和赢家票指了两处）。 */
    check(r.cls >= 1 && r.cls <= CLF_N_CLASS &&
          r.conf_pct == (100 * r.votes[r.cls - 1]) / CLF_N_TREE,
          "fixture: conf is the winning class's vote share");

    ui_status_clear(&s);
    ui_status_put(&s, &r, 7u, 250u, 1);

    if (ui_json(buf, (int)sizeof buf, &s) < 0) {
        check(0, "json: full status fits in the response buffer");
        return;
    }
    check(strcmp(buf, want) == 0, "json: full status is byte-identical to the expected string");
    if (strcmp(buf, want) != 0) {          /* 对不上时把两边都打出来，省一次往返 */
        xil_printf("  got : %s\r\n", buf);
        xil_printf("  want: %s\r\n", want);
    }
    check(all_ascii(buf, (int)strlen(buf)), "json: every byte is printable ASCII");

    /* 没有方位的一帧：grid_w = 0，字段仍在，grid/gx/gy 报 −1 而不是悄悄少一段。 */
    r.grid_w = 0;
    ui_status_put(&s, &r, 8u, 0u, 1);
    check(ui_json(buf, (int)sizeof buf, &s) > 0 &&
          strstr(buf, "\"grid_w\":0,\"grid\":-1,\"gx\":-1,\"gy\":-1") != NULL,
          "json: a frame without a direction keeps its fields (grid=-1)");

    /* 还没跑过一帧。**不能**打一个全 0 的结果 —— 那看起来就是"正常"，
     * 而在没跑过的时候报 normal 是这套东西最坏的一种错。 */
    ui_status_clear(&s);
    check(ui_json(buf, (int)sizeof buf, &s) > 0 &&
          strcmp(buf, "{\"have\":0}\n") == 0,
          "json: before the first frame it says have=0, not a fake normal");

    /* 装不下就作废（返回 −1），不留半句。 */
    fill_sample(&r);
    ui_status_put(&s, &r, 7u, 250u, 1);
    check(ui_json(buf, 8, &s) < 0, "json: a too-small buffer fails instead of truncating");
}

/* ------------------------------------------------------------------------------------------
 * 2/3. 路由与应答头。
 * ------------------------------------------------------------------------------------------ */
static void check_routes(void)
{
    char body[UI_BODY_MAX];
    struct ui_status s;
    struct diag_result r;
    struct ui_reply rep;

    fill_sample(&r);
    ui_status_clear(&s);
    ui_status_put(&s, &r, 1u, 0u, 1);

    rep = ui_route("GET / HTTP/1.1\r\n", &s, body, (int)sizeof body);
    check(rep.code == 200 && rep.len == (int)strlen(UI_PAGE_HTML) &&
          memcmp(body, UI_PAGE_HTML, (size_t)rep.len) == 0,
          "route: / serves the page verbatim");
    check(strncmp(rep.ctype, "text/html", 9) == 0, "route: / is served as text/html");
    check(all_ascii(body, rep.len), "route: the page has no non-ASCII byte");

    rep = ui_route("GET /api/status HTTP/1.1\r\n", &s, body, (int)sizeof body);
    check(rep.code == 200 && strncmp(rep.ctype, "application/json", 16) == 0 &&
          strstr(body, "\"cls\":\"inner\"") != NULL,
          "route: /api/status serves the JSON");

    rep = ui_route("GET /api/status?t=1 HTTP/1.1\r\n", &s, body, (int)sizeof body);
    check(rep.code == 200, "route: a query string after the path is tolerated");

    /* 反面用例：这三条都必须是非 200，且不能拿别人的 body 冒充。 */
    rep = ui_route("GET /api/statusx HTTP/1.1\r\n", &s, body, (int)sizeof body);
    check(rep.code == 404, "route: /api/statusx is NOT /api/status (prefix trap)");
    rep = ui_route("GET /favicon.ico HTTP/1.1\r\n", &s, body, (int)sizeof body);
    check(rep.code == 404, "route: /favicon.ico is 404 (the browser will ask)");
    rep = ui_route("noseparator", &s, body, (int)sizeof body);
    check(rep.code == 404, "route: a request line with no space is 404, not a crash");

    /* 缓冲区不够时 500，不是截断。 */
    rep = ui_route("GET / HTTP/1.1\r\n", &s, body, 64);
    check(rep.code == 500 && rep.len == 0, "route: a too-small buffer is 500, not a truncated page");
}

/* ------------------------------------------------------------------------------------------
 * 4. 真链跑一帧，再把它变成 JSON —— 查的是结构不变量，值不查（值由随机森林定）。
 *    这个函数也是本 TU 引用 ps_diag.h 全部 static 函数的地方。
 * ------------------------------------------------------------------------------------------ */
static void check_live_frame(void)
{
    static double x[FRAME_N];
    char buf[UI_BODY_MAX];
    struct diag_result r;
    struct ui_status s;
    uint32_t t0, t1, st = 0;
    int dir_ok, i, sum = 0;

    /* 纯整数，宿主机上也是这个答案：1e6 拍 = 3 ms */
    check(dia_ticks_to_ms(1000000u) == 3u, "timer ticks -> ms is 3 ns per tick");
    check(dia_ticks_to_ms(0u) == 0u, "timer ticks -> ms at zero");

    dia_gtimer_start();

    dia_synth_frame(x, FRAME_N);
    t0 = dia_gtimer_now();
    dir_ok = dia_frame(x, FRAME_N, PL_SRP_GRID_W, &r, &st);
    t1 = dia_gtimer_now();

    for (i = 0; i < CLF_N_CLASS; i++) {
        sum += r.votes[i];
    }
    check(sum == CLF_N_TREE, "live: votes add up to the tree count");
    check(r.cls >= 1 && r.cls <= CLF_N_CLASS, "live: the class is in range");

    if (!dir_ok) {
        xil_printf("PL  : no steering result yet (status=0x%x)\r\n", (unsigned)st);
    }
    xil_printf("TIME: station 11+12 %u ticks = %u ms\r\n",
               (unsigned)(t1 - t0), dia_ticks_to_ms(t1 - t0));

    ui_status_clear(&s);
    ui_status_put(&s, &r, 1u, 0u, 1);
    check(ui_json(buf, (int)sizeof buf, &s) > 0, "live: a real result fits the response buffer");
    check(strstr(buf, "\"have\":1") != NULL, "live: the JSON reports a result");
    xil_printf("JSON: %s", buf);

    /* 串口这一行与上面那行 JSON 是同一帧，逐字段对照用的（见 docs 的上板步骤） */
    out_print_human(&r);
    if (!out_print_diag(&r)) {
        check(0, "live: station 13 class name lookup");
    }
}

int main(void)
{
    g_fail = 0;

    xil_printf("ps_ui_test: station 15 (browser view)\r\n");

    /* 站 11 的 setup 必须在任何一帧之前：H、Hann、twiddle 都在这儿定 */
    fea_setup(FRAME_FS, 1400.0, 4600.0);

    check_json_exact();
    check_routes();
    check_live_frame();

    xil_printf("FDIAG_RESULT_%s (%d failures)\r\n", g_fail == 0 ? "PASS" : "FAIL", g_fail);
    return g_fail;
}
