# 本机 Agent API 与 CLI

`devicebridge-agent` 从 stdin 读取一个 JSON 请求，通过本机 Unix socket 调用正在运行的 DeviceBridge 应用，并在 stdout 输出一个 JSON 响应。当前提供设备信息读取、Android Shell 以及操作查询与取消；与界面共用当前设备、忙碌状态和结果。

先启动应用，在界面选择并授权设备，按需要完成扩展准备。CLI 不会启动应用、ADB 或 runner，不会选择设备或自动准备扩展。接口实现和打包路径不代表所有真机与完整 Release 验收已通过；验收项目见[设备信息与 Shell Quickstart](../specs/002-device-info-shell/quickstart.md)。

## 找到 CLI

按当前 Release 构建脚本，CLI 随应用放在 `DeviceBridge.app/Contents/MacOS/devicebridge-agent`。安装在“应用程序”时：

```sh
agent_cli='/Applications/DeviceBridge.app/Contents/MacOS/devicebridge-agent'
```

开发者在仓库根目录构建后使用 SwiftPM 的 debug 产物：

```sh
swift build --package-path packages/DeviceBridgeCore --product devicebridge-agent
agent_cli="$PWD/packages/DeviceBridgeCore/.build/debug/devicebridge-agent"
```

以上变量只指定本地 CLI 路径。每次调用的请求均经 stdin 传入，不把命令或设备标识放在进程参数中。CLI 每次处理一个请求后退出；stdout 只含 JSON，stderr 仅用于不含请求载荷的诊断。

## v1 请求与响应

请求必须且只能包含以下四个字段；`params` 内也拒绝未知、多余、缺失或类型错误的字段。

| 字段 | 类型与要求 |
| --- | --- |
| `apiVersion` | 整数 `1`。其他整数版本返回 `unsupported_version`。 |
| `requestID` | 调用方生成的标准 36 字符 UUID 字符串。新调用使用新 UUID；恢复同一次已接受调用时保留原 UUID 和参数。 |
| `method` | 下表中的五个名称之一。 |
| `params` | 与方法精确匹配的 JSON 对象。 |

| 方法 | `params` | 返回和行为 |
| --- | --- | --- |
| `device.current` | `{}` | 当前会话、设备和能力状态；不触发设备操作。 |
| `device.info.read` | `{"sessionKey":"…"}` | 启动一次信息读取，返回 `accepted` 与 `operationID`。 |
| `android.shell.run` | `{"sessionKey":"…","command":"…"}` | 在当前 Android 会话执行原始命令，返回 `accepted` 与 `operationID`。 |
| `operation.get` | `{"sessionKey":"…","operationID":"UUID"}` | 查询该会话中 Agent 来源操作的当前状态或保留结果。 |
| `operation.cancel` | `{"sessionKey":"…","operationID":"UUID"}` | 对匹配的 Agent 操作请求取消，并返回当前状态；已完成则返回已有结果。 |

`sessionKey` 是应用返回的不透明字符串，最多 512 字节 UTF-8，不能空白或包含 NUL。不要解析或自行拼装。`operationID` 必须是标准 UUID。`command` 不能全为空白或包含 NUL，最多 16 KiB UTF-8；验证不会裁剪或改写命令。

响应含 `apiVersion: 1`、对应的 `requestID`，以及互斥的对象 `result` 或 `error`。无法从非法输入识别 UUID 时，错误响应中的 `requestID` 为 `null`。错误对象含 `code`、`message`，可选 `recoveryAction`；不要按说明文字判断程序行为。

```json
{"apiVersion":1,"requestID":"11111111-1111-4111-8111-111111111111","error":{"code":"stale_session","message":"The device session key is no longer active."}}
```

CLI 退出码 `0` 表示取得 `result`，`1` 表示 API 错误或通信/输出失败，`2` 表示输入 schema、版本或大小校验失败。**`accepted` 只表示已接纳，CLI 退出码也不是设备命令退出码。** 即使设备操作失败或实际退出码是 255，`operation.get` 仍可成功返回 `result`，必须读取其 `state` 和 `exitCode`。

## 示例：当前会话 → 信息读取 → 查询

以下示例只展示调用格式。执行前把示例 `requestID` 换成自己生成的 UUID，把 `SESSION_KEY_FROM_DEVICE_CURRENT` 换成当前响应的 `sessionKey`，把示例 `operationID` 换成启动响应返回的真实 UUID。不要用空标识或默认“第一台设备”执行。

获取当前会话：

```sh
"$agent_cli" <<'JSON'
{"apiVersion":1,"requestID":"11111111-1111-4111-8111-111111111111","method":"device.current","params":{}}
JSON
```

没有当前会话时，`result` 为 `{"status":"no_active_session"}`。已有会话时，`result.status` 为 `active`，并带 `sessionKey`、`device` 和 `capabilities`：

- `device` 包含 `name`、`identifier`、`platform`（`android` 或 `ios`）、`transportID` 和 `generation`。
- `capabilities.deviceInformation` 与 `capabilities.androidShell` 各包含布尔 `available` 和说明 `reason`。状态只反映当前可调用性；调用时仍会重新准入，可能返回 `busy`。

读取设备信息（Android 与 iOS 使用相同方法）：

```sh
"$agent_cli" <<'JSON'
{"apiVersion":1,"requestID":"22222222-2222-4222-8222-222222222222","method":"device.info.read","params":{"sessionKey":"SESSION_KEY_FROM_DEVICE_CURRENT"}}
JSON
```

接纳响应示意：

```json
{"apiVersion":1,"requestID":"22222222-2222-4222-8222-222222222222","result":{"state":"accepted","operationID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","origin":"agent","sessionKey":"SESSION_KEY_FROM_DEVICE_CURRENT"}}
```

查询返回的操作 ID：

```sh
"$agent_cli" <<'JSON'
{"apiVersion":1,"requestID":"33333333-3333-4333-8333-333333333333","method":"operation.get","params":{"sessionKey":"SESSION_KEY_FROM_DEVICE_CURRENT","operationID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}}
JSON
```

信息操作的 `state` 为 `running`、`cancelling`、`completed`、`cancelled` 或 `failed`。结果包含 `operationID`、`origin: "agent"`、`sessionKey`、`deviceIdentifier`、`transportID`、`startedAt`，结束后可含 `finishedAt`、`failure` 和本次 `report`。失败或取消不保证有报告，也不会把界面保留的上次报告冒充为本次结果。

报告包含 `id`、`deviceName`、`session`、`queryStartedAt`、`queryFinishedAt`、`sections` 和 `warnings`；操作与报告的日期均为 ISO 8601 字符串。`completed` 的报告仍可能部分可用，应逐字段检查 `availability` 并读取 `warnings`，不要推断全部字段成功。

字段使用 Core Codable 的带标签枚举结构，**值不是直接的 JSON 数字或字符串**。例如，下面是 `sections[].fields[]` 中两个字段的结构示意，不是一次真实设备采样：

```json
[
  {
    "id":"memory.total",
    "title":"Physical memory",
    "availability":{"available":{
      "value":{"integer":{"_0":8589934592}},
      "unit":"bytes",
      "source":{"kind":"iosRuntime","queriedAt":"2026-09-09T08:00:00Z","freshness":"live"}
    }}
  },
  {
    "id":"battery.voltage",
    "title":"Battery voltage",
    "availability":{"unavailable":{"reason":"unsupported"}}
  }
]
```

`availability` 恰有 `available` 或 `unavailable` 一项。可用字段内含 `value`、可选 `unit` 和 `source`；不可用字段内含 `reason` 和可选 `recoveryAction`。`value` 的标签为 `text`、`integer`、`decimal` 或 `texts`，实际载荷都在 `_0`；`texts._0` 是字符串数组。容量原始单位为 bytes。

`source.kind` 为 `adb`、`coreDevice`、`iosRuntime` 或 `session`；`freshness` 为 `live`、`possiblyCached` 或 `sessionSnapshot`。来源含 `queriedAt` 和可选 `sourceTime`，不能用报告完成时间替代字段源时间。不可用原因包括 `notRead`、`unsupported`、`notReturned`、`permissionDenied`、`runtimeNotReady`、`busy`、`timedOut`、`invalidData` 和 `disconnected`。

## 示例：Android 只读命令与取消

确认 `device.current` 返回 Android 会话及可用的 `androidShell` 后，可显式运行以下只输出文本的命令。JSON 中的 `\\n` 会作为命令里的反斜线与字母 `n` 传给 Android `printf`。

```sh
"$agent_cli" <<'JSON'
{"apiVersion":1,"requestID":"44444444-4444-4444-8444-444444444444","method":"android.shell.run","params":{"sessionKey":"SESSION_KEY_FROM_DEVICE_CURRENT","command":"printf 'hello\\n'"}}
JSON
```

用前述 `operation.get` 查询这次 Shell 返回的 `operationID`。活动状态为 `running`、`cancelling` 或 `draining`。终态为 `remoteExit`、`cancelled`、`timedOut`、`outputLimitExceeded`、`connectionLost`、`resultUnknown`、`protocolFailure` 或 `notStarted`。

Shell 终态结果除归属与时间外，还含原始 `command`、`stdout`、`stderr` 和 `outputTruncated`；`notStarted` 可含结构化 `failure`。两路输出分别保存原始字节，格式为 `{"encoding":"base64","data":"…"}`。先解 Base64，再根据实际内容选择文本解码；无效 UTF-8 不能丢弃，且不保证重建两路输出的交错顺序。例如 `aGVsbG8K` 解码后是 `hello` 加换行。

仅 `state: "remoteExit"` 存在真实 `exitCode`（0…255），非零退出不丢弃已接收输出，255 会保留为 255。其他终态没有退出码；尤其 `connectionLost` 或 `resultUnknown` 不证明命令未执行或没有副作用。

对尚未结束的 Agent 操作请求取消：

```sh
"$agent_cli" <<'JSON'
{"apiVersion":1,"requestID":"55555555-5555-4555-8555-555555555555","method":"operation.cancel","params":{"sessionKey":"SESSION_KEY_FROM_DEVICE_CURRENT","operationID":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}}
JSON
```

把上例操作 ID 替换成要取消的实际操作。取消响应可能仍为 `cancelling` 或 `draining`；继续查询直到终态，不能据此立即启动另一条 Shell。取消已完成的操作返回已有结果。接口不能取消 UI 来源或其他会话的操作；界面可以取消当前 Agent 操作。

## 重复请求、会话与结果保留

相同会话中，已接受启动请求的同一个 `requestID` 与相同方法/参数再次到达，只返回原 `operationID`，不会重放操作；改动方法或参数则返回 `invalid_request`。查询和取消请使用各自的新 `requestID`，不要复用启动请求 ID。

连接断开或响应丢失不代表取消。可以使用已知 `operationID` 查询，或以原 `requestID` 和完全相同的启动请求取回关联；**不能换一个 ID 自动重试命令**。设备切换、连接/ADB epoch 失效或应用重启后，旧 `sessionKey` 被撤销，需重新调用 `device.current` 获取当前 key，再由调用方明确决定下一步。旧 key 不会恢复执行。

每会话最多记录 128 个已接受启动请求关联，用满后新的启动请求返回 `busy`；不会通过淘汰旧请求 ID 来允许重放，查询与取消仍可使用。按错误说明重新选择设备会建立新会话关联。

接口不额外保存输出：信息只保留最近一次操作元数据及当前报告，后续读取会替换旧操作；Shell 使用当前执行或界面既有历史。结果被替换、清空或历史淘汰后返回 `result_unavailable`。Shell 历史最多 20 条且命令与输出合计最多 2 MiB，按先入先出淘汰；会话改变会清空历史。

## 错误码

| `error.code` | 含义 |
| --- | --- |
| `unsupported_version` | 不支持请求的 API 版本。 |
| `invalid_request` | schema、参数或命令非法，或已用请求 ID 的方法/参数不一致。 |
| `app_unavailable` | CLI 无法连接应用，或应用工作区不可用。先检查应用是否运行；CLI 不自动启动它。 |
| `no_active_session` | v1 定义的错误码；当前 `device.current` 无会话时实际使用 `result.status: "no_active_session"`。 |
| `stale_session` | key 已失效、设备归属改变，或准备响应期间会话改变。 |
| `unsupported_capability` | 当前平台或连接不具备所请求能力。 |
| `busy` | 模块运行/清理中、连接未就绪，或本会话已用满 128 个启动请求 ID。 |
| `operation_not_found` | 操作不属于当前会话的 Agent 调用关联。 |
| `result_unavailable` | 操作关联存在，但结果已替换、清空或淘汰。 |
| `request_too_large` | 单次请求超过 128 KiB。 |
| `response_too_large` | 输出响应或信息报告超过序列化限额。 |
| `internal_error` | 无法生成合法响应。 |

表中是 API 错误；设备操作的 `result.failure.code` 属于操作失败模型，不是同一组错误码。

## 本机边界与限额

默认目录为 `~/.devicebridge-agent`（0700），端点为 `agent.sock`（0600），固定锁文件为 `owner.lock`（0600）。两端核对 OS 返回的本机 UID。应用必须持有独占生命周期锁才能处理残留 socket 和绑定端点；第二实例不能覆盖活跃 owner。退出先关闭监听与连接，再清理身份仍匹配的本次端点并释放锁，锁文件保留。

启动拒绝符号链接、错误属主或不安全权限的目录/锁，以及不安全端点。该接口服务同一用户授权运行的本机程序，不隔离同 UID 的恶意程序，也不提供网络监听、HTTP 或 MCP server。

| 限额 | 当前值 |
| --- | --- |
| 单次请求 / 响应 JSON | 128 KiB / 2 MiB |
| Shell 命令 / 单次两路原始输出总量 | 16 KiB UTF-8 / 1 MiB |
| 信息报告 / 单字段文本 | 64 KiB 序列化 / 1 KiB UTF-8 |
| 全局已接纳连接 / 在途响应 | 最多 4 条 / 4 份，不设置无界队列 |
| 每连接 | 一个请求、一个响应；不能复用或流水发送 |
| IPC 请求帧读取 / 响应写出 | 各 5 秒绝对期限；超时关闭客户端 |
| 设备信息 / Shell 执行期限 | 默认 20 秒 / 30 秒，与 IPC 期限分开 |

底层帧为 4 字节大端无符号长度加 UTF-8 JSON 正文；零长度或超限帧拒绝。达到连接上限时可直接关闭连接，CLI 可能报告 `app_unavailable`，不保证收到 `busy` JSON。查询连接的读写超时不会自动取消已接受操作。使用配套 CLI 无需自行实现帧协议。

协议实现见 [AgentAPIProtocol.swift](../packages/DeviceBridgeCore/Sources/DeviceBridgeCore/AgentAPI/AgentAPIProtocol.swift)、[AgentIPC.swift](../packages/DeviceBridgeCore/Sources/DeviceBridgeCore/AgentAPI/AgentIPC.swift)；业务响应映射见 [AgentAPIController.swift](../apps/macos/DeviceBridgeApp/AgentAPI/AgentAPIController.swift)。
