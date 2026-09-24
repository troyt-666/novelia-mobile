# 鸿蒙内部测试分发

JFZ Reader 使用现有国内开发者账号的 AppTest 内部测试。APP ID 为
`6917616114030016453`，包名固定为 `io.github.troyt666.jfzreader.hm`。
“内部测试”群组目前只有账号本人。

## 命令行发布

`app/tool/harmony_apptest.py` 使用华为官方 Connect / Testing API。
2026-09-18 已用第 20 版跑通本机构建、发布签名、API 上传、内部群组绑定和提交，
并实际验证重复执行只查询既有版本，不会再次上传或创建版本。

### 首次配置

在 AGC「用户与访问 → API 密钥 → Connect API → Service Account」创建
开发者级服务账号，角色为 **APP 管理员**。提交测试版本接口要求该角色或管理员，
仅运营角色不能提交。该权限包含应用管理能力，并不限于 AppTest 上传。

将下载的 JSON 凭据保存在仓库外：
`~/development/jfzreader-signing/agc-service-account.json`，权限设为 `600`。
脚本拒绝使用仓库内或对其他用户开放的凭据文件。不要把密钥内容贴进终端命令、
提交到 Git 或写进发布日志。

运行环境使用 Python 3.11+、Node、Java 和现有 HarmonyOS SDK，无额外 Python 依赖。
Node 在内存中生成 Service Account 的 PS256 JWT；每次调用自行认证，无需网页登录。

### 发布步骤

递增 `app/pubspec.yaml` 和 `app/ohos/AppScope/app.json5` 的构建号，然后在 `app` 目录：

```sh
source ~/development/harmony-env.sh
python3 tool/harmony_apptest.py build
python3 tool/harmony_apptest.py groups
```

准备一份 UTF-8 更新说明文件。以第 20 版为例：

```sh
python3 tool/harmony_apptest.py publish \
  --package build/apptest-20/JFZ-Reader-1.0.0-20-AppTest.app \
  --notes-file build/apptest-20/release-notes.txt \
  --group 内部测试
```

命令执行：核验发布包 → 查询现有内部群组 → 上传 APP → 等待包解析 →
创建邀请测试版本 → 继承应用介绍并更新说明、群组和期限 → 回读核对 → 提交。
默认测试期限为当天起 90 个自然日，不生成公开链接，不额外发送通知，
不执行正式上架自检。凭据可通过全局参数 `--credentials /仓库外/凭据.json` 指定。

返回“AGC accepted submission”只说明提交已接受，华为预审和生效仍需等待。
可独立查询版本状态：

```sh
python3 tool/harmony_apptest.py status
python3 tool/harmony_apptest.py status --version-id 测试版本ID
```

实测版本列表的 `state` 可能在提交后仍返回 `7`（准备提交），而版本详情已经
返回 `releaseState: 12`（预审中）。命令会额外读取详情，以详情中的状态显示
中文结果，不能仅用版本列表判断是否提交成功。

`build/apptest-<构建号>/publication.json` 保存包哈希、群组、测试期限和各阶段结果。
相同输入重跑会复用已确认的上传、软件包和测试版本；已提交的版本只查询状态。
网络中断导致某次修改结果不确定时，脚本停止并保留 `pending`，不会盲目重发。
此时先在 AGC 对照包名、版本号、版本 ID 核实结果，再修正本地状态；不要直接
删除状态文件后重发。包名、构建号、签名 Profile 或群组不匹配时拒绝发布。

签名密码由 Java 进程从本机文件读取，不放入进程参数；API JWT、上传临时凭据和
完整应用联系信息不输出到日志。上传过程中不跟随重定向。

离线回归验证：

```sh
python3 -m unittest discover -s tool -p 'test_harmony_apptest.py' -v
```

覆盖重复提交、网络结果不确定、输入变化、API 业务错误、内部群组选择、
错误包、更新说明继承和提交前远端信息核对。

官方文档：[Testing API 指南](https://developer.huawei.com/consumer/cn/doc/doccenter-submission/agc-help-test-api-guide-0000002236015562)、
[服务端授权](https://developer.huawei.com/consumer/cn/doc/doccenter-submission/agc-help-connect-api-obtain-server-auth-0000002271134661)、
[提交测试版本](https://developer.huawei.com/consumer/cn/doc/doccenter-submission/agc-help-test-api-submit-test-version-0000002236201334)。

## 网页发布（备用）

1. 递增 `app/pubspec.yaml` 和 `app/ohos/AppScope/app.json5` 的构建版本号。
2. 在 `app` 目录生成未签名 APP：

   ```sh
   source ~/development/harmony-env.sh
   python3 tool/flutter_harmony.py build app --release --no-codesign
   ```

3. 用发布证书和发布 Profile 签名整个
   `build/harmony/app/build/ohos/app/ohos-default-unsigned.app`。
   工具为 `$DEVECO_SDK_HOME/default/openharmony/toolchains/lib/hap-sign-tool.jar`，
   使用 `sign-app -mode localSign`、`-signAlg SHA256withECDSA`、
   `-compatibleVersion 18`，并传入 `-appCertFile`、`-profileFile`、
   `-keystoreFile`、`-keyAlias`、密码、输入与输出路径。
   完成后用同一工具的 `verify-app` 验证输出 APP。
4. AGC → JFZ Reader → 软件包管理，上传签名 APP，使用场景选择“仅测试”。
5. 应用测试 → 测试版本列表 → 创建测试版本，选择“邀请测试”和新包；
   填写测试时间、简短更新说明，软件包加密选择“加密（推荐）”。
6. 选择“内部测试”群组并发送测试通知，点击“保存”并确认。
   以列表实际状态为准，等到“测试中”后再在手机安装。

不要拆出 HAP 签名后重新压成 APP：这种包缺少外层 APP 签名，AGC 会报 991。
2026-09-15 已确认直接签名原始 APP 的 `1.0.0（18）` 包上传成功。

## 本机签名材料

材料在仓库外的 `~/development/jfzreader-signing/harmony-release/`：
`jfzreader-release.p12`、`jfzreader-release.cer`、`jfzreader-release.p7b`
及 `keystore-password.txt`。别名为 `jfzreader-release`。
密码由本机脚本读取，不写入命令历史、日志或仓库。
华为证书“JFZ Reader Release”和 Profile“JFZ Reader AppTest”有效期至 2029-09-15。
绑定设备的调试签名配置与这套发布材料分别保存。

## 手机安装和后续更新

首次在手机打开华为测试邀请邮件，点“前往 AppTest 查看”，按提示安装 AppTest、
使用受邀华为账号接受邀请并安装 JFZ Reader。后续新版通过 AppTest 更新，无需 USB。
本地调试安装与 AppTest 发布包的 app-identifier 不同，手机已出现覆盖安装失败。
第 19 版提供“设置 → 备份与恢复”。原安装已经同签名升级并导出完整备份，
且在独立测试安装中验证恢复、重复导入和进度冲突合并。
等手机 AppTest 中出现可安装的 `1.0.0（19）` 后，再卸载原安装、安装 AppTest 版，
导入 Download 中的完整备份并重新登录。不要先安装不含恢复功能的第 18 版。
迁移验证详情见[阅读数据备份](reader-backups.md)。

测试期限和已安装测试包的使用期限都有限制：测试时间最长 90 天，
安装后的测试包最多使用 90 天。到期前发布并在手机更新新版；仅延长后台时间
不能替代更新已安装的旧包。

隐私政策使用[项目公开文档](https://github.com/troyt-666/novelia-mobile/blob/main/docs/privacy-harmonyos.md)。
应用分类为“阅读与工具书”，主标签“小说”。

2026-09-15 23:31，`1.0.0（18）` 已提交内部测试发布。列表显示内部组、邀请量 1、
“自检中”，状态仍为“准备提交”；页面提示自动预审通常需要 30–40 分钟。
当时尚未确认“测试中”，也未验证手机安装。

2026-09-16 再次查看时，第 18 版已显示“应用上架审核通过”，下载次数为 2，
安装设备量为 0；列表状态仍显示“准备提交”，因此最终可安装性以手机 AppTest 为准。

2026-09-16 约 01:34，`1.0.0（19）` 已提交到同一个内部测试组，邀请成员 1 人，
开启测试通知，测试截止时间为 2026-12-14 23:59:59。测试版本 ID 为
`2040288235124484416`。更新内容为备份恢复、记录合并、可选离线正文和启动章节修复。
发布包签名与本地校验通过，AGC 已解析并接受该包；提交后进入自动预审，
页面提示通常需 30–40 分钟。此时尚未确认第 19 版可在手机安装，也未卸载原安装。

华为说明：[发布测试版](https://developer.huawei.com/consumer/cn/doc/doccenter-submission/agc-help-apptest-release-testapp-0000002292711385)、
[邀请测试用户](https://developer.huawei.com/consumer/cn/doc/doccenter-submission/agc-help-apptest-invite-testuser-0000002258071224)。

2026-09-18 再次查看，第 19 版显示“应用上架审核通过”“上架自检通过”，
下载次数 2，安装设备量 1；列表状态仍为“准备提交”。
第 20 版包含文库小说详情分页评论，已构建并完成发布签名校验：
`JFZ-Reader-1.0.0-20-AppTest.app`，13,450,690 字节，SHA-256：
`37e39437cf9629d913006e27bad23aeaf9e1b1e5afbf0f5964c2c2b363015d5b`。

2026-09-18 约 06:53，通过命令行上传并提交第 20 版，测试版本 ID 为
`2041901103724947776`，软件包 ID 为 `2041900584864353856`。
已回读确认构建号、更新说明和唯一绑定的“内部测试”群组（1 人），软件包加密开启。
测试结束时间为 2026-12-16 23:59:59（北京时间）。
提交接口返回成功，版本详情先显示“预审中”，随后进入“正在审核”，
尚未验证手机实际更新安装。相同接口确认第 19 版为“正在测试”。
用同一条发布命令再次执行，脚本报告已提交，只查询原版本，没有产生重复版本。
服务账号凭据已保存在上述仓库外路径；下载目录中的原文件也限制为仅当前用户可读写。

2026-09-18 约 11:13，使用同一命令行流程提交 `1.0.0（21）`，修复文库 R18
男性向和女性向筛选、请求登录状态及凭据过期刷新，并补充访问权限提示。
发布源码标签为 `v1.0.0+21`，提交 `9142848`；修复提交为 `c6145ed`。
测试版本 ID 为 `2042032117323458880`，软件包 ID 为 `2042031592750191616`。
发布签名包 `JFZ-Reader-1.0.0-21-AppTest.app` 为 13,450,055 字节，SHA-256：
`dbaa98a527f4c5af882f8518a4b0df69abb02112aefce535b35bd6b9de5c2707`。
签名、发布 Profile、包名和构建号校验通过；只绑定原有“内部测试”群组，成员 1 人，
未创建公开邀请链接或额外发送通知，测试截止时间为 2026-12-16 23:59:59（北京时间）。
AGC 已接受提交，详情回读为“预审中”（`releaseState: 12`）；这不代表已可在手机更新。

同版未签名 HAP 已附在
[GitHub Release](https://github.com/troyt-666/novelia-mobile/releases/tag/v1.0.0%2B21)，
从本次新建的未签名 APP 内提取，避免误用旧的独立 HAP 输出。
HAP 为 28,359,640 字节，SHA-256：
`66857f17a3033799cfbf34ae1daaa0d9d2643934f28d108035a23d47dec2c968`，
与 GitHub 附件摘要一致；签名工具确认无 HAP 签名块。
本次通过 390 项 Flutter 回归、静态检查、macOS 原生虚构数据流程和 10 项发布工具测试。
未启动 Android 模拟器，也未执行鸿蒙真机更新安装。

## 2026-09-25 · 第 22 版离线修复

`1.0.0（22）` 的源码标签为 `v1.0.0+22`，提交 `66d36e1`；离线修复提交为
`d6e463f` 和 `c7a0eeb`。本版移除本机数据的联网验证限制，修复离线续读与下载
列表回退，持久保存网文和文库插图，并补齐文库下载管理、容量统计、备份及本机
收藏/阅读历史列表快照。详细验证见[离线复查](offline-audit-2026-09-24.md)。

2026-09-25 约 03:54（北京时间），AppTest 接受第 22 版提交。测试版本 ID 为
`2046884154167037504`，软件包 ID 为 `2046883607481454144`。详情回读为“预审中”
（`releaseState: 12`），尚未验证手机实际更新。沿用“内部测试”群组（1 人），
未创建公开邀请链接或额外发送通知，测试截止为 2026-12-23 23:59:59（北京时间）。

随后回读确认“应用上架审核通过”，状态已变为“正在测试”（`releaseState: 0`）。
本次只验证后台发布状态，未在用户手机执行更新安装。

签名 APP `JFZ-Reader-1.0.0-22-AppTest.app` 为 13,567,337 字节，SHA-256：
`974276f9a9a86e706f09c920adbee09262f6cfef18b749c4987ee73d2f4468f1`。
包名、版本、发布证书及 AppTest Profile 校验通过。

从同次新建的未签名 APP 提取的 `JFZ-Reader-v1.0.0+22-harmony-unsigned.hap`
为 28,589,124 字节，SHA-256：
`fcafc3964e6539b04ad8531b147990a58ab3b0921797aaca954e502c5afada72`。
签名工具确认没有 HAP 签名块，GitHub 附件摘要与本地相同。

发布前通过 418 项 Flutter 回归、静态检查、macOS 原生断网图片与备份恢复流程、
7 项版本/产物检查及 10 项 AppTest 发布工具测试。鸿蒙 release 构建和发布签名已
完成，没有操作用户设备的安装或数据。

AppTest 提交成功后，推送 `v1.0.0+22` 启动
[GitHub 发布流程](https://github.com/troyt-666/novelia-mobile/actions/runs/36051286292)。
全部检查、Android 签名 APK、iOS 未签名 IPA、macOS DMG、附件上传及更新源部署
均成功。[第 22 版 Release](https://github.com/troyt-666/novelia-mobile/releases/tag/v1.0.0%2B22)
包含上述三个平台与鸿蒙未签名 HAP 共四个附件。

已回读公开的 `latest.json`、AltStore 源和 Sparkle appcast，均为 `1.0.0（22）`；
下载地址、文件大小和 SHA-256 与 GitHub 附件一致，macOS 更新包含 Sparkle 签名。
Android APK 为 66,114,880 字节，SHA-256：
`5406ae1f20bd1afd7a450e4c9c3a0f454d83cd172c571577ca55ebf5c95512a3`；
iOS IPA 为 10,468,081 字节，SHA-256：
`d6e1750bad6f1d3e32751602afe689af9e192ef50cb0e59effb219be37335433`；
macOS DMG 为 28,275,934 字节，SHA-256：
`be3551c6cf628a4fe42d37b0a41de4af52a415ee4d9fa1ffcd7c73ad074ab07f`。
