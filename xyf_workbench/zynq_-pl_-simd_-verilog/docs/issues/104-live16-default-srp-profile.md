# 104 16麦已存在1024格配置，但默认构建仍落入256格

状态：已修。

**症状**：显式LIVE16_LOCALIZATION=1时是120对×1024格，单独选择DAS_ACTIVE_CHANNELS=16却仍保留旧4对×256格实例，PS默认选择固定方向版本。

**误判**：看到了1024格模块验收与位流，就认为所有16麦构建入口都自动使用该配置。

**根因**：固定DAS第一阶段要求定位关闭，旧默认0留在RTL、Vivado脚本和PS构建入口；新生产配置没有成为16麦默认值。

**修法**：16麦默认启用定位；同步RTL参数、Vivado BD绑定、PS宏和ARM构建脚本。历史固定方向版使用LIVE16_LOCALIZATION=0与`-FixedDas16`显式选择，四麦仍为256格。

**复现/指纹**：`python scripts/check_live16_localization.py --skip-soc`的`SRP_PROFILES_PASS`同时检查默认16麦、显式固定16麦与四麦。ARM使用`-Live -MatchingPlWindow -ActiveChannels 16`不加Localization16也构建定位版；实际BD wrapper须绑定LIVE16_LOCALIZATION(1)。
