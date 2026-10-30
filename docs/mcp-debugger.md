# MCP 调试器

入口：AI → MCP 调试器；搜索关键词：MCP、stdio、resources、prompts。

## 连接

本机 stdio 使用所选程序的绝对路径与独立参数数组。例如 Python 服务：

```text
可执行文件：/opt/homebrew/bin/python3
参数：["-u", "/absolute/path/server.py"]
```

程序须已安装。环境变量在继承的 App 环境上覆盖；默认 PATH 补充 `/opt/homebrew/bin` 与 `/usr/local/bin`。依赖其他运行时的程序可在高级设置明确设置 PATH。不会读取 Shell 启动文件或展开 `$VAR`、管道与命令替换。连接会实际启动所选程序，包运行器是否下载软件由其参数决定。

Streamable HTTP 使用单一 MCP endpoint，例如 `http://127.0.0.1:3000/mcp`。Bearer Token 为独立安全输入框；其他认证方式可用自定义请求头。认证头、环境变量不主动加入协议日志，但服务返回或 stderr 可能再次包含这些内容。

连接依次完成 initialize、版本协商、initialized 通知，再加载当前目录。支持协议版本 2025-11-25、2025-06-18、2025-03-26；stdio 另支持 2024-11-05。服务选择其他版本时明确失败。HTTP 保留初始化返回的会话 ID，后续携带协商版本；握手通知须获 HTTP 202 后才继续发现。不会自动跟随重定向或重试操作。

## 操作

- 工具：发现、搜索、查看完整 inputSchema 与 annotations，生成起始参数，编辑 JSON 对象后确认调用。示例不是完整 Schema 校验器，最终参数校验由服务端执行。
- 资源：发现并读取 URI；URI 由已连接服务处理，客户端不直接读取对应本地文件。
- 资源模板：查看定义，手动将 URI 占位符替换为实际值后读取。
- Prompts：查看参数定义，以 JSON 字符串对象提供参数，获取消息预览；不会联系模型。
- 结果：正文与完整 JSON 可切换。图片、音频、结构化数据等保留在 JSON 中，首版不渲染二进制媒体。`isError` 与 JSON-RPC、HTTP、传输错误分别处理。
- 日志：查看发送/接收消息、通知与 stderr。服务通知只记录，不触发调用；客户端仅自动响应 ping，其他服务端请求返回不支持。能力变化后可手动刷新目录。

客户端不声明 sampling、elicitation、roots 或异步任务能力。HTTP 接收每次 POST 的 JSON / SSE 响应，不打开独立 GET 通知流；不支持旧版 HTTP+SSE、OAuth 登录、断线恢复、资源订阅、自动调用工具和异步任务。需要 taskSupport=required 的工具会明确拒绝。

## 生命周期与限制

切换到其他工具会断开连接。断开 stdio 时先关闭输入，随后对尚未退出的所启动进程发送 SIGTERM，必要时 SIGKILL；不结束任意其他进程。HTTP 会话存在 ID 时尽力发送 DELETE。重新连接需要用户操作。

单次请求默认 30 秒，高级设置可调整为 10、30、60、120、300 秒。停止与超时会停止等待，并对可取消的请求尽力发送取消通知；已经发生的服务端副作用不会撤销。不会自动重发工具调用。

单条 JSON 消息、请求或单次 HTTP 响应上限为 4 MiB；复用的 SSE 解析器单事件上限 1 MiB。目录每类最多 100 页、2,000 项、累计 16 MiB 定义，游标重复或条目重复明确报错。日志只保留最近 200 条，每条最多 16,384 字符；导出日志也是这些预览，结果页与结果导出保留完整返回。

配置与内容只在 App 内存中保留；不自动写设置、历史、Keychain 或应用日志。显式复制、导出包含所选内容，可能有敏感数据。本地演示使用内存中的模拟 MCP 服务，走相同握手、发现与调用逻辑，不启动外部程序、不联网。

## 验证与参考

测试包含本地演示全流程、握手顺序、分页、业务/RPC 错误、取消与迟到响应、超时、服务端请求、日志限制和配置检查，并通过 Python 测试服务验证真实 stdio 分片与 HTTP JSON/SSE、会话头、认证、拒绝重定向行为。不需要外部账号或付费模型。

- [MCP 生命周期](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)
- [MCP 传输](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [工具](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)、[资源](https://modelcontextprotocol.io/specification/2025-11-25/server/resources)、[Prompts](https://modelcontextprotocol.io/specification/2025-11-25/server/prompts)
