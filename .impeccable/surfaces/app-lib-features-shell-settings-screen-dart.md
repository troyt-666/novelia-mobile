---
version: 1
slug: "app-lib-features-shell-settings-screen-dart"
primary_target: "app/lib/features/shell/settings_screen.dart"
related_targets: ["app/lib/features/backup/backup_screen.dart"]
---

## Direction contract

THESIS: 在设置的“备份与恢复”入口完成文件迁移。导入先比较再合并，不用整库覆盖，也不让重合小说悄悄丢掉记录。

OWN-WORLD: 沿用 Material 3、现有绿色语义颜色、系统中文字体和设置行。根据设备主题适应白天或夜间阅读环境。没有新品牌图像。

STORY: 选择导出记录，可选正文；或选备份文件，查看统计和重合进度。按修改时间给出默认选择，可以逐书改变。合并后报告新增和保留数量。

FIRST VIEWPORT: 标题和返回按钮在顶部，导出和导入是两项明确操作。预览先给小说、进度、书签和正文数量，再显示冲突列表；底部显示合并按钮。长书名和放大字体自然换行。

FORM: 扩展现有设置操作，不做视觉概念竞选。独立详情页承载较长冲突列表，标准开关和单选处理选项；失败留在当前步骤，取消不写数据库。

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Final scoped decisions

模式：Operate。2026-09-16 完成普通设置扩展的文档交接；沿用根 DESIGN.md，未改变全局设计系统。

- 备份页采用标准 Material 3 控件，纵向滚动区域最大宽度为 680，左右留白为 20；这些是局部页面选择。
- 预览统计区分备份内记录与预计新增记录，包含书籍、进度、书签、下载记录和正文；冲突位置另存书签
  的规则在合并前说明。完成反馈显示实际新增与更新数量。
- 进度冲突仍逐书选择；是否导入阅读设置为独立可选项。正文开关默认关闭，取消预览不合并。
- [最终评审](../review/backup/review.md) 的 ship 仅关闭两项原始统计与说明问题。
  [文档交接](../review/backup/documentation.md) 记录源码比较、五张 Android fixture 截图和平台证据限制。
  生产页面栈返回、系统文件选择器和 HarmonyOS 运行结果需使用主任务的独立证据；本记录不宣称其成功。
