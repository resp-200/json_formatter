# JSON Formatter

[English](README.md) | 简体中文

一款本地运行的 macOS SwiftUI JSON 格式化与对比工具，支持格式化、压缩、转义、语义化 JSON Diff、树形浏览、搜索、JS 表达式处理和多种外部输入方式。

## 功能

- 输入 JSON 后按 `Cmd+Enter` 格式化，普通 `Enter` 保留为换行。
- 支持格式化、压缩、转义、转义并复制 JSON、复制结果、清空。
- JSON Diff 模式支持左右两份 JSON 同时编辑；任意层级的对象键顺序不同不会产生差异，数组顺序仍参与比较，并以稳定 JSON 路径展示新增、删除和值变化。
- 支持将 JSON 转义字符串格式化为解码后的对象或数组；若字符串内容不是合法 JSON，则保持 JSON 字符串行为。
- 格式化时支持智能双引号兼容兜底，减少从富文本环境复制 JSON 时的失败概率。
- 输出支持文本视图和树形视图。
- 树形视图支持全部展开、全部折叠和搜索命中高亮。
- 支持 `Cmd+F` 或 `Ctrl+F` 搜索输出内容，并可跳转上一个/下一个匹配项。
- 支持本地 JS 查询/处理表达式，可使用以 `.` 或 `[` 开头的链式表达式，也可用 `value`、`input`、`$` 引用根 JSON；执行基于受限 JavaScriptCore 环境。
- 大输出内容使用虚拟化/懒加载渲染；超大文本输出可暂停搜索和高亮以保持流畅，复制仍会复制完整 JSON。
- 支持深色/浅色模式切换。
- JSON 解析或转换失败时展示错误提示。
- 支持通过 URL Scheme、启动参数、`.json` / `.jsonc` / `.geojson` 文件、系统 Services 和剪贴板辅助启动/重开流程传入 JSON 并自动格式化。
- 启动后检测 GitHub Releases，新版本会在当前版本号后显示红色 `new` 标签，点击可前往下载。

## 效果图

使用聚焦搜索快速打开 JSON 文件：

<img width="640" height="467" alt="Clipboard_Screenshot_1779088658" src="https://github.com/user-attachments/assets/08c5e82c-4b44-4e5d-a155-fc8ab19a52e0" />

不同层级使用不同颜色展示，支持关键字搜索：

<img width="900" height="672" alt="Clipboard_Screenshot_1779088750" src="https://github.com/user-attachments/assets/068d9951-34c9-4af0-91b4-ea5fcb5a9642" />

## 快捷键与常用操作

- `Cmd+Enter`：格式化输入 JSON；在 JSON Diff 模式下比较左右两份 JSON。
- `Enter`：在输入框内换行。
- `Cmd+F` / `Ctrl+F`：搜索输出内容。
- 文本输出和树形输出都可配合搜索使用。

## JS 查询表达式示例

表达式会在本地执行，不会上传 JSON 数据。

```text
.items.filter(x => x.enabled)
[0].name
value.items.map(x => x.id)
input.users.filter(u => u.age >= 18)
$.items.length
```

## 更新记录

### JSON Formatter 1.4.0

- JSON Diff 重做：点击「对比」自动格式化并回填两侧，直接在「原始 JSON」「修改后 JSON」编辑器内以整行底色标注差异——左侧删除/变更行标红，右侧新增/变更行标绿。
- 顶栏新增差异统计芯片（删除 / 新增 / 变更数量），一眼掌握差异规模。
- 移除下方独立的「比较结果」差异列表，差异信息统一由两侧高亮与统计芯片呈现，版面更聚焦。

### JSON Formatter 1.3.0

- 设置改为居中弹窗，聚合语言、外观、编辑器字号、自动保存四类偏好。
- 外观新增「跟随系统」选项，可随系统浅色/深色自动切换，与原有 Light、Dark 模式并存。
- 新增编辑器字号调节（12–24px），实时作用于输入与输出编辑器。
- 新增自动保存：开启后编辑内容防抖后自动落盘，页面不再显示「未保存」。

### JSON Formatter 1.2.0

- 新增语义化 JSON Diff：任意层级的对象键顺序不同不再算作差异，数组顺序仍参与比较，并以稳定 JSON 路径展示新增、删除和值变化。
- 修复长 JSON 滚动到底部后持续下滑并出现白屏的问题，覆盖格式化模式输入框及 JSON Diff 左、右两个输入框。

### JSON Formatter 1.1.0

#### 新增/优化

- 侧边栏页面卡片整块可点击选中，提升多页面切换命中范围与操作体验。
- 页面重命名支持回车、失焦或完成编辑时自动保存，减少改名后遗漏保存的情况。

#### Bug Fix

- JSON 小数格式化不再出现二进制浮点展开，常见经纬度、小数金额等值保持更符合用户预期的可读输出。
- smart quote fallback 失败时保留原始 strict parse 错误，避免兼容兜底掩盖真实 JSON 语法错误。
- 重命名无实际变化时不再触发无意义持久化。
- 重命名自动保存不再顺带保存未手动保存的 JSON 正文，继续遵循 JSON 正文需手动保存的策略。

### JSON Formatter 1.0.9

- 修复剪贴板存在 JSON 时启动/重开应用会覆盖最近一次 JSON 的问题，改为自动新建 tab 并回显剪贴板内容。
- 调整 JSON 内容保存策略：不再因编辑、格式化、切换 tab 或关闭窗口自动保存，改为用户手动点击保存或按 `Cmd+S` 后才写入工作区。
- 左侧 tab 增加未保存状态区分：展开侧边栏显示“未保存”标识，收起侧边栏显示橙色圆点。
- 保留删除 tab 后立即保存工作区结构，避免已删除 tab 在重启后恢复。

### JSON Formatter 1.0.8

- 侧边栏支持收缩，减少编辑 JSON 时的界面占用。
- 支持多 JSON tab，并可新增、删除和重命名 tab。
- 修正 `Command+T` 新建 tab 行为，支持 `Command+S` 保存当前工作区。
- 自动持久化保存 JSON tab 与侧边栏状态，重启后可继续上次工作。

### JSON Formatter 1.0.7

- 继续完善版本检测与发布清单兼容性。

### JSON Formatter 1.0.6

- 改进更新检测的回退逻辑。

### JSON Formatter 1.0.5

- bug fix：修复自动检测更新逻辑，避免版本比较异常导致新版本提示不准确。

## 构建

```bash
scripts/build_app.sh
```

构建产物：

```text
dist/JSON Formatter.app
dist/JSON Formatter.dmg
```

脚本会生成 App Bundle，并在签名前规范 `CFBundleIdentifier`、补齐基础 `Info.plist` 字段、清理 bundle 扩展属性，然后根据环境变量选择签名方式。

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

可使用以下入口达到等价效果。

### URL Scheme 自动格式化

支持 `jsonformatter://` 和 `json-formatter://`，查询参数支持 `text`、`json`、`input`、`q`：

```bash
open 'jsonformatter://format?text=%7B%22a%22%3A1%7D'
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
3. 若复制内容是合法 JSON，App 会在启动或重开时导入并格式化。

### 系统 Services

安装后，选中文本并在 macOS 服务菜单中选择 `Format JSON`，即可把选中文本发送到 App 格式化。首次安装后如果服务未立即出现，可重新登录或运行：

```bash
/System/Library/CoreServices/pbs -flush
```





<center>该项目已在 [LINUX DO](https://linux.do) 社区分享。</center>
