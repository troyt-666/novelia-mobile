# UI/UX 工作入口

## 已完成的设置

- 项目级技能：`../.agents/skills/impeccable/`，从仓库根目录或 `app/` 工作均可发现。
- [PRODUCT.md](../PRODUCT.md)：从仓库整理的产品背景与已知约束。
- [DESIGN.md](../DESIGN.md)：从代码提取的视觉与交互基线，待实际界面评审。
- 根目录及 `app/AGENTS.md` 仅在 UI/UX 工作时引用这些资料。

最初的工具设置阶段只准备了技能和项目背景，没有更换视觉风格。随后已按用户确认
的方案实施书架改版，行为与原生证据见 [书架改版记录](library-ux-proposal-2026-09-14.md)。
以后新建界面时再按实际任务决定设计方式；
没有预存图像优先或代码优先的偏好。

## Impeccable 来源与运行

安装来源为 [pbakaus/impeccable](https://github.com/pbakaus/impeccable)，
固定提交为
[`cb56ed6c19a07329a9fa0cd4e657bee040156593`](https://github.com/pbakaus/impeccable/tree/cb56ed6c19a07329a9fa0cd4e657bee040156593)，
安装日期为 2026-09-14。使用 Codex 的 skill-installer，从该提交复制
`.agents/skills/impeccable`，技能版本为 **4.3.1**，运行引擎为 **0.1.5**。
上游 `LICENSE` 与 `NOTICE.md` 随副本保留；未修改技能正文。

本机运行引擎已由随包启动器下载，并通过上游 SHA-256 校验。其他开发机首次运行
需要访问上游发布页并写入用户级运行缓存。更新时应显式更新固定来源、检查变更，
再同步本文件中的版本记录；不要把技能版本、npm 安装器版本和引擎版本混淆。

Codex 下一轮对话可使用 `$impeccable`；未出现时重新打开项目或重启 Codex。
项目技能位置和发现规则见 [Codex 官方说明](https://learn.chatgpt.com/docs/build-skills)。

采用原生 App 审查流程：Flutter 代码、Dart 工具、原生运行截图和对应设备交互。
依据随包 `reference/audit.native.md`，网页检测器不适用于 Flutter 原生界面，
因此本次没有安装网页编辑 hook、浏览器 live 模式或 HTML/CSS 组件预览 sidecar。
UI UX Pro Max 留待具体资料需求出现时再补充。

## 建议的第一次评审

用户已将重点明确为书架：续读最近作品与从大量下载中选书都很常见。
初步结构建议见 [书架 UX 改版建议](library-ux-proposal-2026-09-14.md)。
书架和设置页属于工具操作界面；阅读正文的重点是持续阅读与理解。
按具体界面选择 Impeccable 模式，避免把全 App 固定为一种模式。

可在下一条消息直接使用：

```text
$impeccable critique app/lib/features/shell/library_screen.dart

结合 PRODUCT.md、DESIGN.md、书架改版建议、当前实现和实际运行结果，评审书架，
重点验证续读与离线列表变长时的操作成本。目标是更快选书或恢复阅读。
保留 JFZ Reader 的中文优先、绿色主题和现有功能。

按影响排序报告最多 5 个有证据的 UI/UX 问题：受影响的用户任务、
视觉/交互/平台类别、代码或截图证据、建议改法、如何验证。
重点检查类别入口、搜索与状态保留、长标题、字体缩放、点击区域、空/加载/失败状态。
区分代码推测与实际观察，未运行的平台明确标为待验证，不凑数。
使用虚构数据。本轮只评审和提出方案，不修改应用代码。
```

## 证据与验证

先遵循 [应用开发约定](../app/AGENTS.md)，使用已有 fixture 与测试支持构造可重复
页面。普通生产入口会访问真实服务，不能把它误当成 fixture 入口。
截图注明日期、提交、平台、设备或窗口尺寸、主题、文字缩放和数据场景。

首轮覆盖正常内容、长中日文及多标签、空、加载、失败与离线状态，检查浅色、深色
和放大文字。可先用 macOS 定位问题；影响移动体验的结论在 Android 或 iOS 模拟器
验证，HarmonyOS 特有的手势、WebView、折叠姿态与性能用对应设备补证据。
设备暂不可用时继续源码评审，明确保留待验证项。

后续选择一个问题或一组相关问题实施，再跑与行为变化相关的检查；应用修改按
现有约定执行分析与测试。纯文档与工具设置只验证安装、引用和配置。
截图放在忽略的 `app/build/ui-ux/`，有价值的评审结论写入 `docs/`，最终确认的
共用设计决定更新到 `DESIGN.md`。
