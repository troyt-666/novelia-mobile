# 文库本评论接入

2026-09-18 核对时，应用的文库详情页只有简介、阅读设置与 EPUB 卷列表，
没有评论请求或评论区域；网络小说已有只读分页评论。

## 网页依据

网站页脚当时标识部署提交为
[`ac0875439a3d24d6287c620f85617755389ba75a`](https://github.com/auto-novel/auto-novel/commit/ac0875439a3d24d6287c620f85617755389ba75a)。
匿名打开[文库详情示例](https://n.novelia.cc/wenku/6450c50a84972153850fa9c6)，
实际看到卷目录下方的评论、回复与分页。未保存真实评论正文、用户名或封面作为测试数据。

该部署版本的
[WenkuNovel.vue](https://github.com/auto-novel/auto-novel/blob/ac0875439a3d24d6287c620f85617755389ba75a/web/src/pages/novel/WenkuNovel.vue)、
[WebNovelNarrow.vue](https://github.com/auto-novel/auto-novel/blob/ac0875439a3d24d6287c620f85617755389ba75a/web/src/pages/novel/components/WebNovelNarrow.vue)
和宽屏 WebNovelWide.vue 使用同一个 CommentList：

- 文库作品：`site=wenku-{novelId}`。
- 网络作品：`site=web-{providerId}-{novelId}`。
- 共用 `GET /api/comment`，`page` 从 0 开始，默认每页 10 条顶层评论。
- 响应 `pageNumber` 是总页数，不是评论总条数。
- 返回的 `replies` 随顶层评论展示；网页版另支持回复分页。

接口依据为同提交的
[CommentApi.ts](https://github.com/auto-novel/auto-novel/blob/ac0875439a3d24d6287c620f85617755389ba75a/web/src/api/novel/CommentApi.ts)
及 [useComment.ts](https://github.com/auto-novel/auto-novel/blob/ac0875439a3d24d6287c620f85617755389ba75a/web/src/repos/useComment.ts)。

## 应用行为

两类详情共用 `NovelCommentsSection`，保留现有网络小说的只读约定：
显示作者、日期、正文与响应中附带的回复，明确翻页而不追加整条评论流。
文库评论位于 EPUB 卷列表下方，即使没有可读 EPUB 也显示评论。
加载、空结果与失败分别显示；失败重试请求原来的页码；隐藏评论使用占位文案。
评论失败不阻断详情、阅读设置或下载。接口未提供总评论数时只显示总页数。

本次没有添加发帖、回复发表或单条评论的额外回复分页，范围与应用原有网络评论一致。

## 验证

自动化测试使用虚构作品和评论，覆盖请求参数、回复解析、隐藏内容、分页替换、
上一页／下一页边界、失败重试、无 EPUB 的空评论、深色大字体，以及原有 EPUB 下载设置锁定。
网络小说已有评论回归测试同时保留。

`flutter test` 全部 384 项通过。Dart MCP 对改动源码分析无错误；
`flutter analyze lib test integration_test test_driver` 无问题。
直接分析整个 app 目录会误包含本地 `build/scroll-diagnosis-20260910/` 中的旧 Flutter
源码副本，因此使用明确的应用源码及测试目录范围；未改动这些旧诊断文件。

Android 16 / API 36 的 `novelia_api36` 模拟器原生场景已通过，使用 1080 × 2400
物理分辨率、420 dpi（约 411 × 914 逻辑尺寸），基于 `5da6e20` 加本次工作区改动。
浅色默认字号及深色 1.5 倍字号下均检查了评论、回复和分页；另外采集加载、空评论与
失败状态。大字体长用户名与日期之间增加 8 个逻辑单位的间隔。
截图及日志位于忽略目录 `app/build/ui-ux/2026-09-18/`：

- `wenku-comments-light.png`、`wenku-comments-dark-large.png`
- `wenku-comments-loading.png`、`wenku-comments-empty.png`、`wenku-comments-error.png`
- `native.log`、`tests.log`、`analyze.log`

原生测试最初把断言放在数据加载回调中，在真实异步绘制时触发了测试框架的调用限制，
被界面当作加载异常处理；现已改为记录请求参数并在测试主体中断言。
生产界面的错误处理保持不变。

本机 `simctl` 查询和 Gradle 文件系统扫描曾卡住，后者留下仍被系统进程持有的缓存锁。
验证通过临时开发工具路径、临时 Gradle 全局／项目缓存和关闭文件监听参数完成，
没有修改用户的持久构建配置或处理系统挂载。复现此次隔离验证可使用：

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
GRADLE_USER_HOME=/tmp/novelia-wenku-gradle \
GRADLE_OPTS='-Dorg.gradle.vfs.watch=false' \
flutter --no-version-check drive --no-pub -d emulator-5554 \
  --android-project-cache-dir=/tmp/novelia-wenku-project-cache \
  --driver=test_driver/wenku_comments_driver.dart \
  --target=integration_test/wenku_comments_test.dart
```

本次没有验证 iOS、macOS 或 HarmonyOS 的原生界面，不将 Android 结果视为这些平台的设备证据。
