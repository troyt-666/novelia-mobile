# HarmonyOS 真机调试

此目录是 `io.github.troyt666.jfzreader` 的鸿蒙原生入口。Flutter 页面和 SQLite
数据模型与其他平台共用；增加鸿蒙的路径、WebView、加密会话、版本号和外链实现。

2026-09-10 已在 HUAWEI Pura X View 上验证主界面加载，并通过原生存储/WebView
专项测试与登录、搜索、阅读翻页及进度恢复、离线下载四条虚构数据流程。
原有 Flutter 的 51 项主应用测试和四条流程测试也通过。

## 已使用的环境

- macOS Apple Silicon
- Flutter OHOS `3.44.9+ohos-0.0.1-canary1`，Dart 3.12.2
- 华为 Command Line Tools `26.0.0.821`
- DevEco CLI `1.3.0-stable`

独立 Flutter OHOS SDK 来自
[CPF-Flutter/flutter_flutter](https://gitcode.com/CPF-Flutter/flutter_flutter)，
标签对应提交 `39285df71a97ffe0c23241dcc459d997a9d8b7c6`。
路径与 WebView 插件在 `pubspec.yaml` 中固定到上游提交。

## 构建与安装

先载入本机已经配置的环境，再从 `app` 目录运行：

```sh
source ~/development/harmony-env.sh
python3 tool/flutter_harmony.py
hdc list targets
hdc -t DEVICE_ID install build/harmony/app/build/ohos/hap/entry-default-signed.hap
hdc -t DEVICE_ID shell aa start -a EntryAbility -b io.github.troyt666.jfzreader
```

新电脑需先安装上述工具，将 Flutter OHOS、DevEco CLI、CLT 的 `bin` 和
`tool/node/bin` 加入 PATH，并设置 `DEVECO_CLI_CLT_PATH`、`DEVECO_SDK_HOME`
与 `DEVECO_NODE_HOME`。本机环境脚本只在调用的终端生效。
CLT 26 的目录名是 `tool`，而此版 Flutter 在 macOS 上查找 `tools`；本机已在
CLT 根目录创建 `tools → tool` 符号链接。新装同版本 CLT 时也需补上此链接。

首次签名需运行 `devecocli auth login` 扫码登录，并在 AppGallery Connect 的
“证书、APP ID 和 Profile → 设备”登记测试手机。可用
`hdc -t DEVICE_ID shell bm get --udid` 获取 UDID。构建入口会在需要时调用
`devecocli signature generate`。

构建入口在忽略目录 `build/harmony/app` 中编译，签名配置与私钥引用只保留在那里。
不要把生成的签名配置复制回源码目录。

## SQLite 与工具链修补

当前 Flutter OHOS 对第三方原生构建钩子报告 Linux。直接构建会误用 Linux 版 SQLite；
本入口下载并校验 SQLite 3.53.4 官方源码，用鸿蒙 Clang 和 sysroot 编译。
仅构建副本追加 sqlite3 hook 设置，其他平台继续使用原有配置。

Canary 1 还遗漏 `NativeAssetsManifest.json`，导致真机找不到已打包的 SQLite 符号。
入口会在独立鸿蒙 SDK 需要时应用 `tool/flutter_ohos_native_assets.patch`，
使用与 Flutter Android 相同的清单打包方式，并重建工具缓存。

## 真机验证

以下测试使用虚构数据。Flutter 的设备测试结束后会卸载测试应用，因此只在专用测试
安装上执行；保留真实阅读数据的日常安装不要使用该命令。

```sh
source ~/development/harmony-env.sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 tool/flutter_harmony.py \
  test integration_test/harmony_native_test.dart \
  integration_test/critical_user_journeys_test.dart \
  -d DEVICE_ID --reporter expanded
```

`DEVELOPER_DIR` 仅隔离本次鸿蒙测试，避免本机 iOS 模拟器发现过程阻塞。
原生测试覆盖路径获取、SQLite 建库/重开读取、超过 4KB 的加密会话更新/清除，以及
WebView 本地页面和 JavaScript。已有流程测试使用虚构账号与书籍检查登录、搜索、阅读、
离线下载和进度恢复。测试结束后重新构建并安装正式入口。

## 当前限制

- 当前交付为有设备签名的 Debug 包。此版本工具链的 Release AOT 编译在
  Flutter `_window_ohos.dart` 的 `_Rect` 处崩溃；较新的上游开发版也复现。
- 鸿蒙暂时关闭 GitHub 应用内更新检查；已有发布流程没有鸿蒙更新包。
- 真正的服务端账号登录和远端站点验证，需要用户使用自己的账号验收。
