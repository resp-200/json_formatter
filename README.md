# JSON Formatter

macOS 下的一款本地 JSON 格式化 App。

## 功能

- 输入 JSON 后按 `Cmd+Enter` 格式化
- 普通 `Enter` 保留为换行
- 支持格式化、压缩、转义、转义并复制 JSON、复制结果、清空
- JSON 解析失败时展示错误提示
- 支持通过 URL Scheme、启动参数、JSON 文件、系统 Services/剪贴板入口传入 JSON 并自动格式化
- 启动后检测 GitHub Releases，新版本会在当前版本号后显示红色 `new` 标签，点击可前往下载

## 效果图

使用聚焦搜索快速打开json文件
<img width="640" height="467" alt="Clipboard_Screenshot_1779088658" src="https://github.com/user-attachments/assets/08c5e82c-4b44-4e5d-a155-fc8ab19a52e0" />

不同层级使用不同颜色展示，支持关键字搜索
<img width="900" height="672" alt="Clipboard_Screenshot_1779088750" src="https://github.com/user-attachments/assets/068d9951-34c9-4af0-91b4-ea5fcb5a9642" />


## 构建

```bash
scripts/build_app.sh
```

构建产物：

```text
dist/JSON Formatter.app
dist/JSON Formatter.dmg
```

脚本会生成 App Bundle，并在签名前规范 `CFBundleIdentifier`、补齐基础 `Info.plist` 字段、清理 bundle 扩展属性，然后根据环境变量选择签名方式：

App 显示名保持为 `JSON Formatter`，内部可执行文件名使用无空格的 `JSONFormatter`，避免部分 macOS 启动或分发链路对带空格可执行名处理异常。

- 如果设置了 `SIGN_IDENTITY`，脚本会使用该真实代码签名身份签名：

  ```bash
  SIGN_IDENTITY="证书名" scripts/build_app.sh
  ```

  这是最可靠达成“别人拿到包后，不执行命令，只在系统设置的隐私与安全性中放行”的方式。证书名可用 Keychain 中已有的代码签名证书名称，例如 Apple Development 或 Developer ID Application 证书名称。
- 如果未设置 `SIGN_IDENTITY`，脚本会退回 ad-hoc 签名。脚本会在签名和校验之后生成包含 App Bundle 和 Applications 快捷入口的 DMG 分发包，这些处理是为了尽量避免无证书分发时被 macOS 直接判定为 damaged，并尽量进入“系统设置 → 隐私与安全性 → 仍要打开”的路径，但 ad-hoc 签名不保证所有 Mac 都可放行。

如果需要完全无弹窗或最稳定的对外分发，需要使用 Developer ID 签名并进行 notarization（公证）。当前脚本不自动创建证书、不修改系统 Keychain，也不执行公证流程。

当前脚本默认使用本机 SwiftPM 环境构建当前架构的可执行文件；跨 Intel / Apple Silicon 分发需要分别提供对应架构产物，或在具备相应 Xcode 构建能力的环境中制作 universal 构建。当前脚本不承诺生成 universal App。

本机安装到应用程序目录：

```bash
cp -R "dist/JSON Formatter.app" "/Applications/"
```

分发给他人时，发送 `dist/JSON Formatter.dmg`。对方双击 DMG 挂载后，把 `JSON Formatter.app` 拖到 `Applications`，再从“应用程序”目录双击打开；如果 macOS 拦截，真实签名身份构建的包通常可前往“系统设置 → 隐私与安全性”点击“仍要打开”。ad-hoc 签名包仅是尽量降低 damaged 风险，不保证满足这一目标。

## 外部调用

macOS Spotlight 不会把 `Command+Space` 后继续输入的任意文本作为启动参数传给普通第三方 App，所以不能原生支持 “Spotlight 中输入 `JSON Formatter {}` 后回车” 这种形式。该输入会被 Spotlight 当成搜索关键字，截图中的“无结果”是系统行为。

可使用以下入口达到等价效果：

### URL Scheme 自动格式化

```bash
open 'jsonformatter://format?text=%7B%22a%22%3A1%7D'
```

也支持更易读的 scheme 别名和参数名：

```bash
open 'json-formatter://format?json=%7B%22a%22%3A1%7D'
```

### 启动参数自动格式化

```bash
open -a "JSON Formatter" --args '{"a":1}'
```

### 打开 JSON 文件自动格式化

安装后，可右键 `.json` / `.jsonc` / `.geojson` 文件，选择“打开方式”中的 JSON Formatter。

### 从 Spotlight 配合剪贴板使用

1. 复制 JSON 文本。
2. 按 `Command+Space` 搜索并打开 `JSON Formatter`。
3. App 检测到剪贴板文本后会显示“格式化剪贴板”提示，点击即可导入并格式化。

### 系统 Services

安装后，选中文本并在 macOS 服务菜单中选择 `Format JSON`，即可把选中文本发送到 App 格式化。首次安装后如果服务未立即出现，可重新登录或运行：

```bash
/System/Library/CoreServices/pbs -flush
```
