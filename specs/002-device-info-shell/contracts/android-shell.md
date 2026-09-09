# Contract: Android 非交互式 Shell

覆盖 FR-009–021、FR-024–025。只实现本地 ADB server 所需服务，不构造通用ADB客户端，不使用宿主shell解释命令。

## 用户输入与执行语义

- 仅当前已授权且连接可用的Android可运行；原始命令UTF-8≤16KiB、非全空白、无NUL。换行、引号、管道与重定向保留原样；不增加wrapper、marker、环境变量或自动重试。
- 一次显式运行一次独立设备Shell；不持久保持cd/env，不提供PTY、stdin或后台执行队列。
- 显式运行可来自界面或[Agent接口](agent-api.md)；两者共用一个执行/清理占用、结果及历史owner。Agent不能绕过当前会话或限额，界面显示调用来源并可取消。
- service可能已经送达但结果丢失时，状态为结果未知。只有确认在service提交之前失败才称为未启动；不得根据重试能否成功来推断之前未执行。

## 连接与归属准入

1. 在Store原子准入captured session，并捕获当前ADB epoch。server地址只允许loopback及本产品支持的本地端口（默认5037）；不继承未经验证的远程ADB_SERVER_SOCKET，不自行启动/重启server。
2. 查询精确route的features并要求 `shell_v2`，查询本身不能当成执行连接的身份绑定。无能力时明确不可用，不退化为普通CLI。
3. 打开本次执行socket，发送 `host:tport:serial:<captured adbSerial>`。读取 `OKAY` 后读取8字节little-endian实际transport ID，必须与captured ID一致；拒绝缺失/重复serial及改变的tuple。
4. Wi-Fi route使用既有可信helper context核验同一captured route的设备身份。执行socket选中后，第二条验证socket同样核对epoch和tport tuple，再发送 `localabstract:<AndroidHelperManager.socketName>` 服务并使用既有HelperFrameCodec/HelperWireCodec交换identity；验证requestID、nonce上下文、helperDeviceID、版本和结果schema。该流只做identity，不调用既有会创建forward的verifyIdentity，不创建/删除任何端口映射。验证流关闭并完成读写清理后重查session/epoch，继续使用原执行socket。不能重开执行连接，不以IP:port当设备身份。无可信依据时不给执行入口。
5. 在原socket发送 `shell,v2,raw:<original command>`；仅一次，检查service的 `OKAY/FAIL`。可能已发送的失败不能标记为肯定未执行。
6. server观察连接 `host:track-devices` 丢失使本epoch失效并清空对应历史；观察重建只供未来显式操作，不重放当前命令。observer不是零延迟物理身份证明，固定socket及helper核验仍必须成立。

smart-socket请求的4字节ASCII十六进制长度按UTF-8字节计，最大65535。Shell service前缀13字节，16KiB命令合计16397，不超过上限。status/FAIL长度、tport响应及features都严格限额与完整读取，禁止用单次receive假设整帧到达。features/observer单条记录上限1MiB；不足以处理的记录明确报协议限制，不静默截断后选择目标。

## Shell-v2 帧

每帧为1字节ID + 4字节little-endian payload长度 + payload。仅接受当前服务需要的类型：

| ID | 方向 | 处理 |
| --- | --- | --- |
| 1 | device→host | stdout原始字节 |
| 2 | device→host | stderr原始字节 |
| 3 | device→host | exit，payload必须恰好1字节；0…255均为真实设备退出码 |
| 4 | host→device | CloseStdin，payload长度0，字节 `04 00 00 00 00` |

service成功后启动读循环并发送CloseStdin，不用socket half-close代替协议动作。CloseStdin写失败不能立即提交断连：远端可能已发送有效exit并关闭，必须在剩余期限内继续读取退出证据；有效exit优先于该写错误，无exit的EOF才报告未知/断连，已接受的用户取消/总期限仍生效。stdout/stderr按有界块流式消费，单次网络读取缓冲≤64KiB，不按不可信payload length一次分配。单帧声明大于1MiB、未知ID、错误exit长度、截断header/payload均失败；合计输出越界只保留配额内前缀并关闭。退出帧前EOF或读取错误没有退出码，包括已收到输出后断开。

只承诺两路各自的字节顺序。输出用纯文本呈现，不执行ANSI/HTML或可点击命令，非UTF-8标明解码替换。valid exit后提交一个终态并关闭本次socket，不等待额外EOF无限挂起。

## 期限、取消与预算

| 边界 | 限额及失败行为 |
| --- | --- |
| 命令输入 | 16KiB UTF-8；发送前拒绝 |
| 本次执行 | 从用户运行准入开始总共30秒，含连接、身份和输出；期限到达停止连接并报告timeout |
| 输出 | stdout+stderr≤1MiB原始bytes；越界保留前缀并报告不完整 |
| 本地清理 | 正常条件≤2秒目标；超时仍保持清理中，阻止下一条，不伪造结束 |
| 历史 | 20条且command+raw outputs≤2MiB，FIFO；明示淘汰 |
| 显示缓存 | 当前可见解码输出合计≤256KiB UTF-8，按需分页/完整复制 |

关闭涉及本次执行socket、identity验证socket及其读写任务；临时features查询同样必须收尾。会话server observer由单独的会话owner关闭，不因一条普通命令完成而撤销epoch；不创建forward资源。不声称撤销已发生副作用或终止已脱离连接的设备后台进程。取消、超时、断连的单次仲裁与Store draining规则见[数据模型](../data-model.md)。现有HostCommandRunner不承担此Shell执行，但信息查询的有界进程修正须保留旧行为安全网。

## 必须阻止开放执行的失败

假server不能区分exit255与缺失exit、server重启后可能执行到替代route、Wi-Fi identity证据无法绑定固定socket、清理前允许新执行，任一出现都不能开放相应路径。不得通过CLI fallback、stderr关键词或增加随机marker绕过门禁。
