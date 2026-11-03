# 上传前本地核验

- 对应observer源码configs/profiles/scripts/sw共615文件逐字节一致；正式算法未为本次上传修改。
- release/program.ps1默认本地校验：FULL_GUI9_FILES_PASS；未加-Program，未访问板卡。
- node tests/score_view_test.js：SCORE_VIEW_STATE_PASS。
- python project/scripts/test_gsc_gui_output.py（在project目录运行）：合成输出路径检查通过，1536 active samples；关闭/初始冻结等于DAS、名义PS参考一致。不是实板或声学效果验收。
- check_gsc9_hotpath.py未完成：脚本引用本机不存在的C:/msys64环境，编译输出解码失败；未为上传改动原测试脚本，不声称该项通过。
- 本次没有重新ARM编译，上传的是既有归档ELF，哈希见SOURCE_PROVENANCE.json和release/manifest.json；外部Vitis/BSP依赖未打包。
- 主分支现有文件保留；只新增版本目录及根README入口。不含双模式候选、B/D实验、实测录音或整个工作目录。
- 已知历史GSC实时性失败及当前抑制收益未证明：见README和docs/VALIDATION_REVOKED.md。
