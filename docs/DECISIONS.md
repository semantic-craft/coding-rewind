# 工程约束与决策记录

本文档记录代码自身无法直接表达的操作系统、宿主代理、外部接口与静态扫描约束。修改受影响符号前先核对对应条目。

## ADR-001 离线队列使用独立 `.lock` 旁路文件执行 `flock`

- **受影响文件与符号**，`Sources/CodingRewindCore/PlatformStorage.swift` 中的 `OfflineOutbox.withFileLock` 与 `OfflineOutbox.writeEntries`。
- **外部约束**，`OfflineOutbox.writeEntries` 通过 `AtomicFile.writeUTF8` 先写临时文件再 `rename` 覆盖 `outbox.jsonl`，每次原子写入都会替换目标路径的 inode。POSIX `flock` 绑定在打开文件描述符指向的底层 inode 上，若直接锁 `outbox.jsonl`，并发写入者在 `rename` 后会锁住不同 inode，导致互斥失效与丢写。
- **工程决定**，`OfflineOutbox.withFileLock` 固定打开并锁定从不被替换的旁路锁文件 `outbox.jsonl.lock`，所有队列事务共享同一个稳定 inode。

## ADR-002 DSH 本地桥接允许回环 `Host` 下的空 `Origin` 请求

- **受影响文件与符号**，`dsh-plugin/coding-rewind-dsh/lib/index.js` 中的 `validateApiRequest`。
- **外部约束**，DSH Desktop 基于 Electron 自定义协议 `dsh-app://app` 运行前端，其内置协议代理在将渲染层 `fetch` 转发至本机回环 `ctx.webServer` 之前，会剥离 `Origin` 与 `Sec-Fetch-Site` 请求头。若强制要求所有请求携带非空 `Origin`，真实 DSH 桌面端前端长轮询与回执上报会被全部拦截为 `403 forbidden_origin`。
- **工程决定**，当 `Origin` 缺失或为空串时，仅在 `Host` 严格匹配回环地址且 `Sec-Fetch-Site` 为空、`none` 或 `same-origin` 时放行；任何显式携带 `cross-site`、`same-site` 或非回环 `Origin` 的跨站请求一律拒绝。

## ADR-003 进度校验对 GitHub 文件列表执行 `< 3000` 与末页 `< 100` 双重门禁

- **受影响文件与符号**，`progress/progress.py` 中的 `github_files`。
- **外部约束**，GitHub REST API 的 `pulls/{pull_number}/files` 与 `commits/{ref}` 两个端点最多只返回 3,000 个文件（按 `per_page=100` 共 30 页）。超过上限时 `gh api --paginate` 跟踪完所有 `Link` 翻页头后仍会静默截断，不会报错，因此无法单凭翻页结束判定文件集合完整，满 100 条的末页同样无法排除恰好在边界被截断。
- **工程决定**，`github_files` 同时要求 `len(files) < 3000` 且末页 `len(batches[-1]) < 100`，一旦触及上限立即按列表不完整拒绝，防止超大提交绕过 `progress/` 路径隔离审计。

## ADR-004 静态进度页自包含扫描的词法与相对路径顺序

- **受影响文件与符号**，`progress/progress.py` 中的 `normalized_css`、`srcset_urls`、`HTML.javascript` 与 `relative_target`。
- **外部约束**：
  1. CSS 允许用注释包裹无效片段并用反斜杠十六进制转义拼写字符（如 `\68\74\74\70` 表示 `http`），未解码前匹配 URL 会漏检外部资源。
  2. HTML `srcset` 规范允许 `data:` URL 本身包含英文逗号，只有空白符之后的宽度或像素密度描述符才以逗号收尾，按逗号直接 `split(',')` 会截断合法内联资源。
  3. JavaScript 模块说明符（如 `"https://..."`）内部含有 `//` 子串，若先用正则剥离行注释再提取字符串，会从 `//` 处截断字符串并漏报外部脚本依赖。
  4. RFC 3986 相对路径解析以引用所在文档路径为基准，而非软链接指向的物理目标目录。
- **工程决定**，`normalized_css` 先剔除 `/*...*/` 再解码 CSS 转义后才提取资源；`srcset_urls` 先按非空白读取完整 URL token，仅当该 token 未以逗号结尾时才消费后续描述符至下一个逗号；`HTML.javascript` 在同一词法正则中将 `string` 分支置于 `comment` 分支之前；`relative_target` 先用 `os.path.normpath` 按引用位置折叠 `..`，再用 `resolve().is_relative_to(ROOT.resolve())` 校验物理越界。
