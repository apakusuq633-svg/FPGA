# 103 四麦转向LUT顺序与硬件查询不一致

状态：已修。LUT独立核对与17帧/34535样点完整SoC通过，实板待测。

**症状**：四麦SRP有点位，DAS加载的延迟却与几何不一致。256个候选格全部存在有效通道补偿差异；格197旧LUT读出[0,0,0,0]，正确补偿应为Q4[20,30,7,0]。

**误判**：认为只有四个有效麦，8通道转向封装自动补零就够了，或认为定位结果正确就证明DAS用了正确延迟。

**根因**：`build_debug4.py`生成grid-major表，硬件地址为`mic*N_GRID+grid`，要求microphone-major。四个无效通道克隆CH0并不改变地址顺序。

**修法**：生成器按麦克风优先展平；独立宿主调用固件距离核，核对2048个转向条目和1024个SRP条目，重新生成嵌入PS的映像。四麦真实引脚/通道映射保持既有确认值。

**复现/指纹**：`python scripts/build_debug4.py`、`python scripts/check_debug4_geometry.py`，`DEBUG4_GEOMETRY_PASS`且wrong_cells=0。检查格197补偿Q4[20,30,7,0]，不能只比较LUT总长度。
