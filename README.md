# JSON Formatter

English | [简体中文](README_CN.md)

A local macOS SwiftUI app for formatting JSON. It supports formatting, compacting, escaping, tree browsing, search, JavaScript query expressions, and multiple external input flows.

## Features

- Format JSON with `Cmd+Enter`; plain `Enter` stays as a newline in the editor.
- Format, compact, escape, escape-and-copy JSON, copy result, and clear content.
- Format escaped JSON strings into decoded object or array pretty JSON when applicable; non-JSON strings keep the normal JSON string behavior.
- Smart quote normalization fallback for formatting, useful when JSON is copied from rich text sources.
- Output display modes: text view and tree view.
- Tree view supports expand all, collapse all, and search match highlighting.
- Search output with `Cmd+F` or `Ctrl+F`, including previous/next match navigation.
- Run local JavaScript query/processing expressions against the input JSON. Expressions can start with `.` or `[`, or use `value`, `input`, and `$` as root references. Evaluation uses a restricted JavaScriptCore environment.
- Virtualized/lazy rendering for large output. Search and highlighting may be paused for very large text output to keep the UI responsive, while copy still copies the full JSON.
- Dark and light mode toggle.
- Error display for parse or transform failures.
- External input support through URL schemes, launch arguments, `.json` / `.jsonc` / `.geojson` file open, macOS Services, and clipboard-assisted launch/reopen flows.
- GitHub Releases version check with a red `new` badge next to the current version when an update is available.

## Screenshots

Open JSON files quickly from Spotlight:

<img width="640" height="467" alt="Clipboard_Screenshot_1779088658" src="https://github.com/user-attachments/assets/08c5e82c-4b44-4e5d-a155-fc8ab19a52e0" />

Colorized JSON levels with keyword search:

<img width="900" height="672" alt="Clipboard_Screenshot_1779088750" src="https://github.com/user-attachments/assets/068d9951-34c9-4af0-91b4-ea5fcb5a9642" />

## Shortcuts and Common Actions

- `Cmd+Enter`: format the input JSON.
- `Enter`: insert a newline in the input editor.
- `Cmd+F` / `Ctrl+F`: search the output.
- Search works with both text output and tree output.

## JavaScript Query Examples

Expressions run locally. JSON data is not uploaded.

```text
.items.filter(x => x.enabled)
[0].name
value.items.map(x => x.id)
input.users.filter(u => u.age >= 18)
$.items.length
```

## Changelog

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

- Continued improvements to release manifest compatibility and update detection.

### JSON Formatter 1.0.6

- Improved update detection fallback behavior.

### JSON Formatter 1.0.5

- Fixed automatic update detection so version comparison issues do not show inaccurate update badges.

## Build

```bash
scripts/build_app.sh
```

Build artifacts:

```text
dist/JSON Formatter.app
dist/JSON Formatter.dmg
```

The script creates the app bundle, normalizes `CFBundleIdentifier`, fills required `Info.plist` fields, clears bundle extended attributes, and chooses a signing strategy based on environment variables.

The app display name remains `JSON Formatter`, while the internal executable name is `JSONFormatter` without spaces. This avoids issues in some macOS launch or distribution paths that do not handle executable names with spaces well.

- If `SIGN_IDENTITY` is set, the script signs with that real code signing identity:

  ```bash
  SIGN_IDENTITY="Certificate Name" scripts/build_app.sh
  ```

  This is the most reliable way to let other users open the app without running terminal commands, only approving it in System Settings > Privacy & Security when needed. The certificate name can be an existing Keychain code signing certificate, such as an Apple Development or Developer ID Application certificate.
- If `SIGN_IDENTITY` is not set, the script falls back to ad-hoc signing. After signing and verification, it creates a DMG containing the app bundle and an Applications shortcut. This is intended to reduce the chance that macOS marks an unsigned distribution as damaged and to make the app more likely to enter the System Settings > Privacy & Security > Open Anyway path, but ad-hoc signing does not guarantee that every Mac can approve it.

For fully smooth or stable public distribution, use Developer ID signing and notarization. The current script does not create certificates, modify the system Keychain, or run notarization.

The script builds a native executable for the current machine architecture using the local SwiftPM environment. For Intel / Apple Silicon cross-distribution, provide separate architecture builds or create a universal build in an environment with the required Xcode build support. The current script does not guarantee a universal app.

Install locally to Applications:

```bash
cp -R "dist/JSON Formatter.app" "/Applications/"
```

To distribute the app, send `dist/JSON Formatter.dmg`. Recipients can mount the DMG, drag `JSON Formatter.app` to Applications, and open it from the Applications folder. If macOS blocks it, builds signed with a real signing identity can usually be approved in System Settings > Privacy & Security > Open Anyway. Ad-hoc signed builds only reduce the damaged-app risk and cannot guarantee approval.

## External Invocation

macOS Spotlight does not pass arbitrary text typed after `Command+Space` as launch arguments to normal third-party apps. For example, typing `JSON Formatter {}` in Spotlight and pressing Enter is treated as a Spotlight search, not as app input. A “no results” state in that flow is normal macOS behavior.

Use one of the supported input flows below instead.

### URL Scheme Auto-Format

Supported schemes are `jsonformatter://` and `json-formatter://`. Supported query fields are `text`, `json`, `input`, and `q`:

```bash
open 'jsonformatter://format?text=%7B%22a%22%3A1%7D'
open 'json-formatter://format?json=%7B%22a%22%3A1%7D'
```

### Launch Argument Auto-Format

```bash
open -a "JSON Formatter" --args '{"a":1}'
```

### Open JSON Files

After installation, right-click a `.json`, `.jsonc`, or `.geojson` file and choose JSON Formatter from “Open With”.

### Spotlight with Clipboard

1. Copy JSON text.
2. Press `Command+Space` and open `JSON Formatter`.
3. When the copied text is valid JSON, the app can import and format it on launch or reopen.

### macOS Services

After installation, select text and choose `Format JSON` from the macOS Services menu to send it to the app for formatting. If the service does not appear immediately after installation, log in again or run:

```bash
/System/Library/CoreServices/pbs -flush
```
