# JSON Formatter

macOS 下的一款本地 JSON 格式化 App。

## 功能

- 输入 JSON 后按 `Cmd+Enter` 格式化
- 普通 `Enter` 保留为换行
- 支持格式化、压缩、复制结果、清空
- JSON 解析失败时展示错误提示
- 支持通过 URL Scheme 或启动参数传入 JSON 并自动格式化

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

macOS Spotlight 不会把 `Command+Space` 后继续输入的任意文本传给普通第三方 App，因此无法直接用 “Spotlight + Tab + JSON” 作为 App 输入。

可使用 URL Scheme 调起并自动格式化：

```bash
open 'jsonformatter://format?text=%7B%22a%22%3A1%7D'
```

也可以通过启动参数传入：

```bash
open -a "JSON Formatter" --args '{"a":1}'
```
