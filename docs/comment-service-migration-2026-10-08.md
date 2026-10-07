# 评论服务迁移修复

2026-10-08 核对网站时，APP 使用的
`GET https://n.novelia.cc/api/comment?site=…&page=0&pageSize=10`
返回 HTTP 404，导致网络小说和文库小说都进入评论加载失败状态。

网站部署标识为
[`301812072a7c5805eaa114957a9d287828c13b2b`](https://github.com/auto-novel/auto-novel/commit/301812072a7c5805eaa114957a9d287828c13b2b)，
构建时间为 2026-10-07 13:27:04 UTC。这是核对时的版本，不代表迁移首次发生的时间。

该版本的 [CommentApi.ts](https://github.com/auto-novel/auto-novel/blob/301812072a7c5805eaa114957a9d287828c13b2b/web/src/api/novel/CommentApi.ts)
和 [config.ts](https://github.com/auto-novel/auto-novel/blob/301812072a7c5805eaa114957a9d287828c13b2b/web/src/config.ts)
表明小说评论已转到 `forum.novelia.cc`。具体协议见网站锁定依赖版本的
[forum-api](https://github.com/auto-novel/forum/blob/afeac411d0243d1167e19193ad84f98192b777b9/packages/forum-api/src/api.ts)。

| 项目 | 旧协议 | 当前协议 |
| --- | --- | --- |
| 路径 | `/api/comment?site={subject}` | `/api/v1/external/comment/novel/{subject}` |
| 页码 | `page=0` 起 | `page=1` 起 |
| 每页条数 | `pageSize` | `page_size` |
| 分页数据 | `pageNumber` 总页数 | `total` 顶层评论总条数 |
| 评论 ID | 字符串 | 整数 |
| 作者 | `user.username` | `authorUsername` |
| 时间 | `createAt` 秒时间戳 | `createdAt` ISO 8601 |
| 状态 | `hidden` | `status`: 0 正常、1 隐藏、2 删除 |
| 内嵌回复 | `replies` 数组 | `replies.items`，附带 `total` |

subject 仍是 `web-{providerId}-{novelId}` 或 `wenku-{novelId}`。

## 修复

两个 HTTP 网关使用独立、可注入的评论服务地址；保留网关对调用方的零基页码，
请求时转换为一基页码。解析器按请求页大小计算总页数，将整数 ID 和 ISO 时间
转换成现有领域模型，并隐藏状态为隐藏或删除的正文。新增论坛 HTTPS 域名到
请求允许列表，沿用现有鉴权、超时、响应大小限制及禁止自动重定向的策略。

界面保持既有只读评论与明确翻页约定；展示本页响应附带的回复，不额外抓取所有回复。
本次没有修改 UI 布局或交互。

## 验证

- 旧接口实测 HTTP 404，新接口匿名请求实测 HTTP 200。
- 修复后的 Dart HTTP 网关直接读取文库 `6450c50a84972153850fa9c6` 和网络小说
  `syosetu/n8439ed` 的第一页、第二页均成功，每页 10 条；当时分别为 5 页和 392 页。
- 新解析器解析文库真实响应成功，包括首页附带的 7 条回复；真实正文和用户名不写入仓库。
- 网关、领域转换、内容协调器及文库详情的 66 项回归测试通过，覆盖新协议、
  页数边界、内嵌回复、隐藏/删除状态、异常字段和原有分页重试。
- 网络小说所在的目录/详情组件与请求策略另有 40 项测试通过，合计 106 项。
- Dart MCP 对改动网关及测试文件静态分析无错误。

线上验证是 Dart 网关请求证据；组件测试采用虚构数据。未重新安装手机应用，
也未将本次验证视为 Android、iOS 或 HarmonyOS 原生界面验证。
