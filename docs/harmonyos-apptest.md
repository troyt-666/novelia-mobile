# 鸿蒙内部测试分发

JFZ Reader 使用现有国内开发者账号的 AppTest 内部测试。APP ID 为
`6917616114030016453`，包名固定为 `io.github.troyt666.jfzreader.hm`。
“内部测试”群组目前只有账号本人。

## 发布新版

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
