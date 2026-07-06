<div align="center">
  <img src="docs/assets/clamless-readme-icon.png" width="184" alt="Clamless app icon">

  <h1>Clamless</h1>

  <p><strong>开着 MacBook，只用外接显示器。</strong></p>
  <p>不合盖，不调暗，不盖黑窗；Touch ID、摄像头、键盘和麦克风照常可用。</p>

  <p>
    <a href="https://github.com/TCXM/clamless/actions/workflows/release.yml"><img alt="Release" src="https://github.com/TCXM/clamless/actions/workflows/release.yml/badge.svg"></a>
    <a href="https://github.com/TCXM/clamless/releases/latest"><img alt="GitHub release" src="https://img.shields.io/github/v/release/TCXM/clamless?style=flat-square"></a>
    <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square"></a>
    <img alt="Platform: macOS Apple Silicon" src="https://img.shields.io/badge/platform-macOS%20Apple%20Silicon-black?style=flat-square">
  </p>

  <p>
    <a href="https://clamless.yuxiaozhu.me/zh.html">官网</a> ·
    <a href="#安装">下载</a> ·
    <a href="#菜单栏应用">菜单栏应用</a> ·
    <a href="#自动开关">自动开关</a> ·
    <a href="#工作原理">工作原理</a> ·
    <a href="#cli">CLI</a>
  </p>
</div>

<p align="center">
  <strong>语言：</strong>
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>

> [!NOTE]
> Clamless 面向 Apple Silicon MacBook，要求 macOS 13 或更新版本。当前公开构建是 ad-hoc 签名，还没有 Apple notarize。第一次打开时如果 macOS 拦截，请右键点击 `Clamless.app` 并选择 **打开**。

## 为什么需要它？

很多外接屏用户只是想把 MacBook 打开放在桌上，继续用 Touch ID、摄像头、键盘和麦克风，但又不希望内置屏参与桌面布局。

macOS 原生给你的选择通常是合盖、调亮度、或者手动改显示器排列。这些都不是同一件事：鼠标和窗口仍然可能跑进内屏，系统也没有真正把它从当前桌面布局里移除。

Clamless 做的就是补上这个缺口：MacBook 保持开盖，macOS 只把外接显示器当作可用桌面。

## 它做了什么

点击关闭内屏时，`clamless-display off` 会连续做三件事：

1. 清掉可能让 macOS 进入镜像/共享显示状态的 mirroring 配置。
2. 将内置显示器从 macOS 当前 active screen arrangement 中移除。
3. 请求 Apple Silicon 内置面板 framebuffer 进入低功耗/关闭状态。

最终你会看到：

- 外接显示器保持可用；
- 内置显示器从鼠标和窗口布局中消失；
- 鼠标不会再进入内置屏幕；
- 内置面板会被请求熄屏。

实际体验接近 Lunar BlackOut / BetterDisplay 的内置显示器 disconnect 功能。

## 工作原理

Clamless 同时操作 macOS 的两层显示系统：

1. **WindowServer / SkyLight 布局控制。** helper 动态加载私有的
   `SkyLight.framework` 符号 `SLSGetDisplayList` 和
   `SLSConfigureDisplayEnabled`。这一层负责把内置显示器从 macOS 桌面排列中移除或恢复，所以鼠标不能进入内置屏幕。
2. **Apple Silicon 面板电源控制。** helper 动态加载私有的
   `IOMobileFramebuffer.framework`，并调用
   `IOMobileFramebufferRequestPowerChange`。这一层负责请求物理内置面板关闭或唤醒。

关闭内屏的流程是：

```text
清理 mirroring
-> 在 SkyLight 布局里 disable 内置显示器
-> 通过 IOMobileFramebuffer 请求关闭内置面板
```

恢复内屏的流程是：

```text
通过 IOMobileFramebuffer 请求唤醒内置面板
-> 在 SkyLight 布局里 enable 内置显示器
```

一个重要细节是：软件断开内置显示器后，macOS 有时会暂时不再通过 SkyLight 列出内置屏。遇到这种状态时，Clamless 会回退到内置 `IOMobileFramebuffer` 服务（`disp0,...`），并用 `IOMobileFramebufferGetID` 找回 `SLSConfigureDisplayEnabled` 需要的 display ID。

## 它不是什么

Clamless 不是：

- 调低亮度；
- 覆盖黑色窗口；
- 合盖模式；
- 只修改显示器排列的 workaround；
- 让内置面板从 IORegistry 里物理消失。

内置面板是 MacBook 的内部硬件，所以它仍然可能出现在底层系统注册表中。对用户真正重要的是 WindowServer/CoreGraphics 的 active display layout。

## 安装

从 [GitHub Releases](https://github.com/TCXM/clamless/releases/latest) 下载最新的 `Clamless-<version>.dmg`，打开后把 `Clamless.app` 拖进 `Applications`。

在完成 Developer ID 签名和 Apple notarization 之前，macOS 首次启动可能会显示未知开发者提示。这时请右键点击 `Clamless.app`，选择 **打开**。

## 系统要求

- Apple Silicon MacBook
- macOS 13 或更新版本
- 断开内置显示器前，至少需要一个已经激活的外接显示器
- 如果从源码构建，需要 Xcode Command Line Tools

## 从源码构建

```sh
make build
```

会生成：

```text
.build/clamless-display
.build/Clamless.app
```

## 从源码安装

```sh
make install
```

菜单栏应用会安装到：

```text
~/Applications/Clamless.app
```

打开它：

```sh
open "$HOME/Applications/Clamless.app"
```

## 发布版本

公开 release 由 GitHub Actions 在推送版本 tag 时自动构建：

```sh
git tag -a v0.1.8 -m "Clamless 0.1.8"
git push origin v0.1.8
```

release workflow 会在 macOS arm64 runner 上构建 DMG、校验 checksum、创建 GitHub Release，并上传 `.dmg` 和 `.sha256` 文件。

如果 tag 在 workflow 加入前已经存在，可以手动运行 `Release` workflow，并把 `release_tag` 设置成已有 tag，例如 `v0.1.8`。

本地测试打包：

```sh
make dmg
```

会生成：

```text
dist/Clamless-<version>.dmg
dist/Clamless-<version>.dmg.sha256
```

为了获得更顺滑的公开安装体验，后续 release 最好使用 Developer ID Application 证书签名，并在上传 DMG 前完成 notarization。

## 菜单栏应用

菜单栏应用提供：

- 一个根据当前状态关闭或恢复内置显示器的开关；
- 设置窗口，用于自动开关、开机自启和检查更新；
- 退出应用命令。

菜单栏标题和菜单文本会跟随系统首选语言。中文环境使用中文，其他环境默认英文。

应用调用同一个内置的 `clamless-display` helper，不维护第二套显示控制逻辑。

## 自动开关

Clamless 可以在可信外接显示器连接后自动关闭内置显示器，并在该外接显示器断开后恢复内置显示器。

自动开关基于白名单：

- 已连接的外接显示器会出现在设置里；
- 新显示器默认不可信；
- 只有勾选过的显示器可以触发自动关闭内屏；
- Clamless 只会自动恢复它自己自动关闭过的内屏状态。

设置窗口使用 CoreGraphics 显示当前 active external display 名称。白名单 display key 来自 `IOMobileFramebuffer.DisplayAttributes.ProductAttributes`。

自动开关同时使用多种信号，因为在这个状态下没有单一 macOS 显示源是完全可靠的：

- 自适应状态轮询：显示状态稳定前短时间 1 秒刷新一次，稳定后只保留较慢的保活刷新；
- CoreGraphics display reconfiguration callback；
- IORegistry display-port service interest notification；
- 更底层的 `AppleATCDPAltModePort.EventLog` `Plug` / `Unplug` 时间戳；
- 当内置显示器已断开但 active CoreGraphics 外接屏数量降到 0 时，触发安全恢复。

状态机把 unplug 视为恢复优先事件。后续出现的低层 `Plug` 事件不能取消已经挂起的恢复，因为 DP Alt Mode relink 或 WindowServer 恢复过程可能产生新的 plug-like event，即使用户并没有主动重新插入显示器。

## CLI

```sh
clamless-display status
clamless-display off --commit session
clamless-display on --commit session
clamless-display panel-on
```

更底层的命令：

```sh
clamless-display layout-off
clamless-display layout-on
clamless-display panel-off
clamless-display panel-on
clamless-display panel-request 0
clamless-display panel-request 1
```

`panel-on` 只会唤醒物理内置面板，不会把显示器恢复到 macOS 布局里。

## 开机自启

打开 Clamless 设置并启用 **开机自启**。

源码构建时，也可以使用 helper scripts。它们调用和 app 相同的 macOS Login Items API，并会清理旧版 LaunchAgent 文件：

```sh
make login-install
```

移除：

```sh
make login-uninstall
```

## 隐私

Clamless 不收集 telemetry，也不会把显示器信息发送到任何地方。菜单栏应用只会通过 macOS `UserDefaults` 在本地保存设置，bundle identifier 是 `local.clamless.menu`。

## 风险和限制

这个项目使用 macOS 私有 API：

- `SkyLight.framework` 显示拓扑 API
- `IOMobileFramebuffer.framework` Apple Silicon 面板电源 API

Apple 未来可能修改这些 API。Clamless 应被视为一个实用型本地工具，而不是 App Store 式的官方稳定集成。

软件断开内置显示器后，某些 macOS 状态下 reconnect 可能失败。如果发生这种情况，先使用 emergency panel wake，再尝试通过 macOS 显示器设置、合盖/开盖、重新插拔外接线缆或重启恢复布局。

## License

MIT
