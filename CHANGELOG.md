# Changelog

## v0.3.0 — 2026-09-30

- 新增 DevOps 分组：Docker Mirror、Docker Transfer、Nginx Formatter。
- 将 replaceDocker / pullAndPush 的命令生成工作流迁入原生界面，支持可配置仓库、镜像命名空间及端口、平台、sudo、可选标签清理、分步复制与 Shell 脚本导出。
- 新增原生 Nginx 双栏格式化、结构检查、缩进及 LF/CRLF、UTF-8/Latin-1 文件导入和另存为；保留注释、引号、转义和变量。
- 搜索支持原工具名称与中文关键词；新增 9 项 DevOps 服务测试，合计 26 项。

## v0.2.0 — 2026-09-30

首个公开版本。原生 macOS 开发工具箱，支持 macOS 14 及以上。

- SwiftUI 分栏界面、系统外观、工具搜索、收藏及最近使用记录。
- JSON 格式化、压缩、校验与语法高亮；Base64、时间戳转换和 UUID 批量生成。
- TCP 端口检测、超时设置与最近端点记录。
- Codex 真实账户额度、重置时间、本机会话与 Token 统计、缓存率、上下文估算和用量图表。
- Codex 增量日志读取、分页/归档合并及重复响应去重；自动和手动刷新。
- 菜单栏入口、原生设置与键盘快捷键。
- SwiftPM / Xcode 工程、17 项服务测试及可复现的 Release 打包脚本。

首版二进制为 Apple Silicon（arm64），使用 ad hoc 签名，尚未进行 Apple Developer ID 签名与公证。Intel Mac 可从源码自行编译。Token Calculator、HTTP Client、DNS Lookup、PostgreSQL 和 Redis 暂仅提供导航入口。
