# JSON Formatter

macOS 下的一款本地 JSON 格式化 App。

## 功能

- 输入 JSON 后按 `Cmd+Enter` 格式化
- 普通 `Enter` 保留为换行
- 支持格式化、压缩、复制结果、清空
- JSON 解析失败时展示错误提示
- 支持通过 URL Scheme、启动参数、JSON 文件、系统 Services/剪贴板入口传入 JSON 并自动格式化

## 构建

```bash
scripts/build_app.sh
```

构建产物：

```text
dist/JSON Formatter.app
```

安装到应用程序目录：

```bash
cp -R "dist/JSON Formatter.app" "/Applications/"
```

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
