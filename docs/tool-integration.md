# 三个工具的分析与原生集成

分析日期：2026-09-30。输入为用户提供的 replaceDocker、pullAndPush、nginxfmt 三个可执行文件。

## 分析方式

三个文件均为 arm64 Mach-O，使用 PyInstaller 打包 Python 3.13 和 Tkinter。通过静态读取包目录、入口字节码、函数名和常量确认行为；没有运行它们，也没有执行原工具生成的 Docker 命令。原可执行文件不加入源码仓库或应用包。

| 原工具 | 确认的行为 | App 入口 |
| --- | --- | --- |
| replaceDocker | 输入 image:tag，生成代理仓库 pull、恢复原始标签 tag、清理代理标签 rmi，以及镜像查询命令；只输出文本 | DevOps → Docker Mirror |
| pullAndPush | Local 模式拉取 linux/amd64 镜像，重新标记并推送到固定私库；Cloud 模式从私库拉取、恢复原始名称并清理私库标签；只输出文本 | DevOps → Docker Transfer |
| nginxfmt | 读取配置，处理空白、分号及大括号，按默认 4 空格缩进，另存为文件；包含 UTF-8/Latin-1 文件读取与命令行格式化相关函数，入口为 Tkinter GUI | DevOps → Nginx Formatter |

前两个工具的图形界面中没有 Docker 执行逻辑。新的 App 同样以生成、预览、复制和导出命令为工作流，生成时不会联系镜像仓库。

## Docker 工作流

原实现使用简单冒号分割镜像字符串，无法正确区分 `registry.example.com:5000/team/app:v1` 中的端口和标签。新的解析器只读取最后一个路径组件的标签，保留命名空间，支持缺省 `latest`。

- **Mirror**：代理镜像 → 原始镜像名。支持 Docker Hub 镜像及 `docker.io/` 前缀；其他源仓库通过 Transfer 处理。
- **Local → Registry**：拉取原始镜像 → 标记为目标仓库镜像 → 推送 → 查询。
- **Registry → Local**：从目标仓库拉取 → 恢复输入的原始镜像名 → 查询。
- **可选清理**：只移除本机的临时仓库标签，保留原始本机标签；不会删除远端仓库镜像。
- **平台**：Automatic、linux/amd64 或 linux/arm64。Mirror 默认 Automatic，Transfer 默认 linux/amd64。
- **sudo**：由用户选择。命令参数使用 Shell 引号；输入另有镜像名、标签、仓库主机和端口检查。
- **地址**：代理及私库均可配置并保存在本机。Mirror 保留原工具的代理默认值；原私库地址改为用户输入，不将内网地址写入公开源码。
- **预览**：展示源和目标及每个步骤。输入或选项改变时撤销旧预览，避免复制旧命令。脚本以 `&&` 连接各步骤，任何失败都会停止后续操作。

使用范围为带标签的镜像重命名流程；暂不支持 digest 重标记、IPv6 注册表地址、批量镜像或自动执行。生成命令不要求 Docker 已安装，实际运行时需要 Docker daemon 及相应仓库登录状态。

命名结构与平台参数依据 [Docker image tag](https://docs.docker.com/reference/cli/docker/image/tag/) 和 [Docker image pull](https://docs.docker.com/reference/cli/docker/image/pull/) 文档核对。

## Nginx 格式化

原 nginxfmt 的嵌入元数据标识版本 1.2.3、作者 Michał Słomkowski、Apache 2.0，指向 [nginx-config-formatter](https://github.com/slomkowski/nginx-config-formatter)。本次依据原工具的操作流程独立实现 Swift 格式化器，没有复制上游 Python 源码或嵌入原二进制，应用仍无 Python 运行依赖。

新的格式化器按词法状态处理配置文本，避免把引号内的 `;`、`#`、`{}` 当作指令或块分隔符，并保留转义及 `${variable}`。相邻参数的空白会规范化，引号内部内容、注释内容和多行字符串保留。提供 2/4/8 空格缩进、LF/CRLF、最多两个相邻空白行及结尾换行。

导入支持 UTF-8 和 Latin-1，另存为沿用导入编码；手工输入使用 UTF-8。默认新文件名为 `<原名称>.formatted.conf`。只有用户在原生保存面板确认后才写入目标文件，使用原子写入。

结构检测包含未闭合引号、未闭合或额外的大括号、缺失指令分号、悬空转义和未闭合变量。它不是 Nginx 指令解析器，也不会启动或重载 Nginx，不读取 include 引用的其他文件。完整验证需在部署环境运行 `nginx -t`；Nginx 配置结构参见 [官方入门指南](https://nginx.org/en/docs/beginners_guide.html)。

配置上限为 2 MB、嵌套上限 128 层；格式化在后台线程执行，输入修改后不会把旧任务的输出覆盖回界面。仅处理 Nginx 指令结构，不支持块内嵌入 Lua 等其他语言；这些配置应使用对应语言的格式化器。

## 原生工具箱集成与验证

三个入口加入 DevOps 分组、收藏、最近使用和命令搜索。搜索支持原文件名以及“镜像代理”“拉取”“推送”“配置”“格式化”等关键词。Nginx 和 Docker 脚本编辑器支持 ⌘F，Nginx 支持 ⌘R 格式化。

新增 9 项测试，连同现有服务合计 26 项。Docker 的 Shell 测试使用假函数记录参数，验证 retag 失败后不会执行 push 或清理，不访问实际仓库。Nginx 测试覆盖嵌套、多行、注释、引号、变量、转义、不同缩进、换行、幂等性和错误结构。

已通过原生界面验证命令生成的两个迁移方向、脚本导出、Nginx 配置导入、格式化预览及另存为；未在本次开发中执行真实 Docker 拉取、推送、清理或 Nginx 部署。
