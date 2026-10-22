# 097：首页超过 TCP 发送缓冲区后返回空响应

**症状**：增加电平卡片后，浏览器提示“192.168.2.10 未发送任何数据”；curl 返回 52。较短的 `/api/status` 仍能持续刷新。

**误判**：只通过网页字符串长度、JavaScript 和 API 监测，未检查完整首页传输；因此曾误认为页面已可用。

**根因**：旧代码一次 `tcp_write` 整个应答，BSP 的 TCP_SND_BUF 为 8192；英文首页增至 8927 字节，写入返回 ERR_MEM，旧错误路径立即关闭连接。

**修复**：各连接保留独立应答和已排队游标，按 `tcp_sndbuf` 的可用空间每次最多排队 1460 字节。ERR_MEM 保留游标等待重试；主循环持续服务发送，累计收到整个应答的 ACK 后关闭连接。正常 Content-Length 应答，不使用 HTTP chunked 编码。调试页面同时中文化，中文首页为 11992 字节，仍在 16384 字节 body 上限内。HTML 使用实体、JS 使用 Unicode 转义，API 字段和类别名保持原格式。

**复现与验证**：`sw/ps_http_tx_test.c` 使用真实首页检查零空间、临时内存不足、致命失败及完整内容。`node scripts/check_ui_page.js` 验证中文动态状态和图表。中文 ELF 已重新下载至四麦实板：20/20 次 HTTP 200，11992 字节与源码逐字节一致，日志 `build/das4/homepage_cn_http_1.json`。并发监测 30 秒：57 次状态请求、29 个新帧、2282 个新块、最大诊断 323 ms，PL/PS 丢样和段重置均为 0；日志 `build/das4/live_board_cn_http_1.json`。
