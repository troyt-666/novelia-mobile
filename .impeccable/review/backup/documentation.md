# 备份与恢复：设计文档交接

日期：2026-09-16。范围为既有设置界面的普通扩展，模式为 Operate。
文档核对基于当前工作区；基准提交为
`87412aac2c7412f1d2eb818c438f143b8e59505e`，本功能包含未提交改动，截图不代表该提交的原样构建。

## 判定

**文档交接完成。** 本次实现沿用既有视觉系统，无需更新全局设计规范。
保留根目录 [DESIGN.md](../../../DESIGN.md)，未生成或改写
`.impeccable/design.json`。本次没有新的随应用发布的栅格图像；下列 PNG 为运行评审证据，
不属于品牌或界面资源。

[最终评审](review.md) 的 `ship` 只针对其两项原始发现：补全书籍与下载记录统计，
以及说明备份内书签与冲突位置另存书签的区别。这不扩大为全界面、所有设备或所有原生交互通过。

## 与既有设计的核对

核对了 [PRODUCT.md](../../../PRODUCT.md)、[DESIGN.md](../../../DESIGN.md)、
[设置界面约定](../../surfaces/app-lib-features-shell-settings-screen-dart.md) 和 Impeccable
`reference/document.md`，并检查以下实现：

- [settings_screen.dart](../../../app/lib/features/shell/settings_screen.dart)：
  “存储与隐私”内加入“备份与恢复”标准设置行，保留图标、说明、行尾箭头与既有描边卡片分组。
- [backup_screen.dart](../../../app/lib/features/backup/backup_screen.dart)：
  标准 AppBar、纵向滚动、描边卡片、开关、单选和主题按钮；标题使用 `TextTheme`，错误使用
  `colorScheme.error`。没有单独引入颜色、字体、阴影或形状系统。
- [main.dart](../../../app/lib/main.dart)：
  两套绿色种子主题、Material 3 和系统中日文字体回退与既有 DESIGN.md 一致；备份页接入现有壳层，
  合并后刷新本机书架与设置状态。

内容最大宽度 680、左右留白 20、卡片内容留白 16 均为该页源码中的局部选择，
不升级为全局布局 token。导出为填充按钮，选择导入文件为描边按钮；预览中“确认合并”为填充按钮，
取消为文字按钮。页面以中文任务说明组织流程，保留下载记录、离线正文、阅读缓存和云端收藏的区别。

预览明确显示备份内的总量和预期新增量，并在冲突存在时说明未选位置另存为书签；完成反馈报告实际
新增书籍、书签、下载记录、正文及更新进度。这是本页的最终统计呈现约定，不是全应用的新组件规范。

## 已查看的运行证据

逐一打开并查看了五张 1080×2400 Android 模拟器原生 Flutter 截图：

| 文件 | 已观察的状态 |
| --- | --- |
| [backup-phone.png](backup-phone.png) | 浅色初始导出／导入操作与正文开关 |
| [backup-phone-preview.png](backup-phone-preview.png) | 备份统计、预计新增、逐书进度单选、合并与取消 |
| [backup-phone-success.png](backup-phone-success.png) | 实际合并结果与返回初始操作区 |
| [backup-phone-error.png](backup-phone-error.png) | 可读的损坏文件反馈与重新选择入口 |
| [backup-phone-dark-large-preview.png](backup-phone-dark-large-preview.png) | 深色、文字缩放 1.6 的预览上部；统计和说明自然换行 |

截图场景与 [backup_ux_test.dart](../../../app/integration_test/backup_ux_test.dart) 的名称、
操作顺序和合成书籍／进度数据一致；[fixture](../../../app/test/support/backup_screen_fixture.dart)
使用内存数据库、模拟文件服务及与生产相同的绿色种子主题。普通截图文字缩放为 1.0。
这些可见状态没有表现出与既有绿色、中文优先、系统控件身份的冲突。

这轮仅检查现有截图、代码和评审结论，没有重新运行测试或开启新的缺陷搜索。
大字截图只覆盖预览上部，不能单凭该图认证屏幕下方全部控件。

## 边界与既有差异

- Fixture 把备份页作为 home，截图没有生产页面栈的返回按钮；它不能证明生产入口、系统返回手势或
  文件选择器行为。状态反馈使用 `Semantics(liveRegion: true)` 是源码事实，屏幕阅读器效果未观察。
- Fixture 字体回退少了生产主题最后一项 `Hiragino Sans`；未更改该既有测试配置，Android 截图不能
  建立 Apple 平台字体效果。
- 原生文件选择器行为由主任务另行测试。HarmonyOS 手机已连接，但本交接没有其运行证据，
  也没有 iOS、平板或折叠姿态证据，不宣称这些平台成功。
- 根 DESIGN.md 的日期和“尚未进行本轮截图评审”等文字来自此前基线。其历史措辞未包含这次备份页
  的局部评审；本文件记录新增证据，未顺带刷新既有设计文档。核对范围内未发现需要改变全局 token
  的实现漂移。

应用代码与 `docs/reader-backups.md` 不在本次文档交接的写入范围内，未修改。
