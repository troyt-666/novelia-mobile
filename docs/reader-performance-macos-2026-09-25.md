# macOS 原生阅读性能复查 · 2026-09-25

用户报告鸿蒙第 22 版网文上下拖动掉帧，纯文字和插图区域都有；文库左右翻页感觉
偏慢，随后补充可能主要是动画节奏，并要求先在 Mac 原生版验证。

## 结论

- EPUB 的主要等待来自平滑翻页：原生 WKWebView 中，点击处理到发出滚动指令约
  0–1ms，首次采到页面移动约 22ms，移动结束并稳定约 222ms。续读落盘开启前后
  基本相同。此翻页路径在第 21 版已经存在。
- 没有后台下载任务时，纯文字和离线插图的连续正反向滚动没有复现持续掉帧。
  插图场景出现一次 33.871ms 的 Raster 尖峰；不能说完全没有慢帧。
- **后台为旧下载补存图片可以在 Mac 复现帧启动延迟。** 24 张约 1.53MB 的生成
  PNG 在补存期间出现 21 次超过 16.67ms 的帧启动延迟，慢样本中位数 31.667ms、
  最大 43.123ms。约 6.04MB 的图片把慢样本中位数推到 124.702ms。
  同期 UI 构建与 Raster 很快，单看这两项会漏掉界面线程被阻塞的问题。

补图是第 22 版新增路径；这是共用 Dart/SQLite 路径上的可复现性能风险，
不是只能在鸿蒙出现的绘制问题。尚未在鸿蒙真机采样，也不知道用户当时是否正在
补图，因此不能认定它解释了用户报告的全部掉帧。本轮只增加诊断测试，没有修改
阅读器实现，没有发布新版本。

## 环境与测量边界

- 源码基线：`ddd3d93`，产品代码与 `v1.0.0+22` 相同；本轮改动均为测试代码。
- MacBook Pro，Apple M1 Max，64GB，macOS 26.5.1；Flutter Profile 构建。
- Flutter 窗口 800×600 逻辑单位，DPR 2，报告显示器刷新率 120Hz。
  EPUB 宿主实际视口 430×600，每章虚构中日文 180 对段落，共 3 章；当前章 91 页。
- 使用原生 Flutter macOS 应用及其 WKWebView，不使用浏览器预览。临时 SQLite、
  EPUB 与图片均为生成的虚构数据，不读取用户书籍或账号，不操作用户设备安装。
- 网文包含 200 章，每章 6 个对齐文本块；插图样本每 3 章附一张 1600×2200 的
  本机 PNG，不访问图片网络。通过实际应用路由进入阅读器，包含阅读窗口追加、
  裁剪和本机进度写入；正文由 fixture coordinator 提供，没有覆盖真实内容服务。
- 两次预热滑动后采样：向后阅读 18 次、继续 48 次、反向 16 次，每次拖动 350ms，
  位移为视口高度的 75%，随后等待滚动停止。
- UI/Raster 超预算数是阶段耗时指标，不是操作系统实际呈现丢帧率。
  后台补图另采 `FrameTiming.vsyncOverhead`（vsync 到 buildStart）和 `totalSpan`。
  该监听覆盖前后批次，样本数比 `watchPerformance` 略多；不把两者逐项配对。
- EPUB 从 DOM click 事件开始计时，经真实网页→Flutter→网页通道执行；不含
  操作系统输入传递或显示器扫描输出。首次移动在 requestAnimationFrame 观察，
  稳定判据是连续两帧到达目标位置，约 222ms 包含最后一帧的确认时间。

## 网文空闲状态

耗时单位为 ms，分位数采用 nearest-rank。超过帧预算指 UI 或 Raster 任一阶段
超出阈值。

| 样本 | 帧数 | UI P99 / 最大 | Raster P99 / 最大 | 超 8.33ms | 超 16.67ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| 纯文字，第 2→18 章 | 2214 | 1.274 / 4.211 | 2.006 / 8.374 | 1 | 0 |
| 纯文字，第 18→59 章 | 5797 | 1.255 / 13.201 | 2.174 / 3.878 | 1 | 0 |
| 纯文字，反向 59→45 章 | 1973 | 0.987 / 5.318 | 2.224 / 4.542 | 0 | 0 |
| 含插图，第 2→13 章 | 2209 | 1.042 / 4.682 | 2.421 / 33.871 | 1 | 1 |
| 含插图，第 13→44 章 | 5803 | 1.002 / 4.962 | 2.024 / 3.516 | 0 | 0 |
| 含插图，反向 44→33 章 | 1976 | 1.351 / 3.628 | 2.200 / 3.018 | 0 | 0 |

纯文字共 9,984 帧，含插图共 9,988 帧。两种场景均完整通过；没有启用增强 CPU
采样或在正式采样中操作辅助功能树。

## 后台补图对照

使用已有 42 本下载的虚构书架，为其中 24 本的一个已存章节加入缺失插图。
测试注入的图片加载器每 400ms 返回一张有效 PNG，实际执行
`AsyncNoveliaDownloadCoordinator.synchronizeIntent` 的旧下载补图逻辑、图片编码、
数据库提交与回读，同时在另一部纯文字小说中滚动 18 次。结束后验证 24 张图片
确实补存完整。图片为确定性灰度噪声，体积分别为 1,527,558 / 6,039,553 字节，
用于控制写入量，不代表用户插图的大小或真实网络速度。

| 场景 | 调度样本数 | 启动延迟 P99 | 最大启动延迟 | 超 16.67ms | 慢样本中位数 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 相同书架，不执行补图 | 2391 | 0.842ms | 3.513ms | 0 | — |
| 24 张 1.53MB PNG | 2330 | 2.040ms | 43.123ms | 21 | 31.667ms |
| 24 张 6.04MB PNG | 2131 | 115.834ms | 135.466ms | 25 | 124.702ms |

1.53MB 场景的 UI / Raster 最大值仅为 3.399 / 3.329ms；6.04MB 场景为
4.264 / 4.198ms。这解释了为什么原先只看 build/raster 的性能测试会放过此类卡顿。
同一书架、不启动补图的对照中，最大帧启动延迟仅 3.513ms，没有超 16.67ms 样本。
三个场景均完整通过；每次为新建临时数据库，未在采样期间访问辅助功能树。

源码对应路径：`main.dart` 启动与恢复下载意图，下载协调器首先补存旧章节缺失插图；
`sqlite_offline_repository.dart` 将图片 base64/JSON 编码并同步写入 SQLite，读取时
也同步解码。它们运行在界面 isolate。实验确认了整条补图路径的影响，尚未采集
CPU 栈来分摊编码、数据库、重复回读各自的耗时，不将峰值全算在某个函数上。

优先修复方向是让图片编码、持久化及读取避免阻塞阅读界面，并在同样的后台补图
场景下复测。不能用暂停或限制离线内容访问来消除这项负载。

## EPUB 翻页

每组先双向预热，再记录 12 次左右交替翻页。下表均为中位数，单位 ms。
直调与无动画仅在测试 WebView 中覆盖，不改变产品实现。

| 场景 | 发出滚动指令 | 首次观察到移动 | 到达目标且稳定 |
| --- | ---: | ---: | ---: |
| 正常通道，不保存续读 | 1.0 | 21.5 | 222.0 |
| 正常通道，保存续读 | 1.0 | 22.0 | 221.5 |
| 网页直接翻页，保存续读 | 0.0 | 12.5 | 213.0 |
| 正常通道，临时关闭动画并保存续读 | 1.0 | 5.0 | 21.0 |

正常动画各组稳定时间最大值为 230ms。续读写入 66 次，中位数 1.88ms、最大
5.69ms，没有等待写入后再翻页。跨章节各测 6 次，新文档 ready 的中位数为
76.66ms（不保存）与 80.61ms（保存），最大 86.58ms；该测量包含 20ms 轮询粒度。

与第 21 版源码对比，网页→Flutter→网页通道及 `behavior: smooth` 已经存在。
第 22 版增加了续读保存和隐藏窗口初始化回退，但没有改变普通页内翻页动画。
本轮没有旧版安装包的同机完整对照，不推算版本间整体性能改善或退化百分比。

## 复现与原始材料

在 `app/` 下运行，Mac 需解锁且窗口可见；测量中不要用辅助功能工具操作窗口。

```sh
PROFILE_OUTPUT_DIRECTORY=build/macos-reading-profile PROFILE_OUTPUT_NAME=web-text-frames \
caffeinate -di flutter --no-version-check drive --profile --no-dds --no-pub \
  --dart-define=PROFILE_READER_ONLY=true \
  --driver=test_driver/performance_driver.dart \
  --target=integration_test/performance_profile_test.dart -d macos
```

插图场景追加 `--dart-define=PROFILE_ILLUSTRATIONS=true` 并换输出文件名。
后台补图追加 `--dart-define=PROFILE_BACKGROUND_REPAIR=true`；较小图片追加
`--dart-define=PROFILE_REPAIR_IMAGE_WIDTH=600 --dart-define=PROFILE_REPAIR_IMAGE_HEIGHT=800`；
相同数据但不执行补图的对照再追加 `--dart-define=PROFILE_REPAIR_DRY_RUN=true`。

```sh
caffeinate -di flutter --no-version-check drive --profile --no-dds --no-pub \
  --driver=test_driver/wenku_latency_driver.dart \
  --target=integration_test/wenku_latency_profile_test.dart -d macos
```

原始 JSON 与日志保存在忽略目录 `app/build/macos-reading-profile/`：
`epub-latency.json`、`web-text-frames.json`、`web-image-frames.json`、
`web-repair-frames.json`、`web-repair-small-frames.json`、`web-repair-control-frames.json`
及对应 `*-run.log`。

首次锁屏采样（`locked-*`）已排除。第一次解锁网文采样期间使用辅助功能检查窗口，
触发 integration_test 收尾的 SemanticsHandle 检查失败（`web-text-observed-*`），
也已由独立完整通过的复测替代。补图测试准备阶段的段落数量与滚动定位问题已经
修正，不作为产品故障或性能样本。
