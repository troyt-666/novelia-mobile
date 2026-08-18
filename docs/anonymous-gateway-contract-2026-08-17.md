# Anonymous Novelia gateway contract

Date: 2026-08-17  
Status: verified, undocumented external contract  
Scope: signed-out, read-only Web Novel integration against `https://n.novelia.cc`

## Purpose and boundary

This document is the implementation contract for the Phase 2 anonymous
`NoveliaGateway`. It records the request and response behavior verified from the
live signed-out website, anonymous HTTP requests, and the source commit exposed
by the website itself.

The contract covers:

- the general-rated Web Novel catalog and search;
- Novel Details and its Chapter List;
- Chapter Content and available Chinese Translations;
- Web Novel Rankings; and
- read-only Novel Comments.

It does not authorize API or content reuse. It does not cover authentication,
account data, comment posting, translation submission, other mutations, Wenku,
the forum, or the website workspace. The gateway must not use browser cookies,
extract website credentials, probe restricted content, or work around a `401`,
rate limit, or other access control.

## Evidence

The signed-out website showed build commit
[`f5a6a8b403e1`](https://github.com/auto-novel/auto-novel/commit/f5a6a8b403e1a23a13807ca1a2a97331f9e3c2e4)
and build time 2026-08-16 01:31:24. Its homepage successfully rendered the
general-rated Web Novel shelf without signing in.

Contract evidence at that commit:

- [frontend API client](https://github.com/auto-novel/auto-novel/blob/f5a6a8b403e1a23a13807ca1a2a97331f9e3c2e4/web/src/api/novel/client.ts)
- [Web Novel requests](https://github.com/auto-novel/auto-novel/blob/f5a6a8b403e1a23a13807ca1a2a97331f9e3c2e4/web/src/api/novel/WebNovelApi.ts)
- [catalog defaults and pagination](https://github.com/auto-novel/auto-novel/blob/f5a6a8b403e1a23a13807ca1a2a97331f9e3c2e4/web/src/repos/useWebNovel.ts)
- [catalog and ranking option mappings](https://github.com/auto-novel/auto-novel/blob/f5a6a8b403e1a23a13807ca1a2a97331f9e3c2e4/web/src/pages/list/option.ts)
- [Web Novel server routes and DTOs](https://github.com/auto-novel/auto-novel/blob/f5a6a8b403e1a23a13807ca1a2a97331f9e3c2e4/server/src/main/kotlin/api/RouteWebNovel.kt)
- [server Web Novel models](https://github.com/auto-novel/auto-novel/blob/f5a6a8b403e1a23a13807ca1a2a97331f9e3c2e4/server/src/main/kotlin/infra/web/WebNovel.kt)
- [comment requests](https://github.com/auto-novel/auto-novel/blob/f5a6a8b403e1a23a13807ca1a2a97331f9e3c2e4/web/src/api/novel/CommentApi.ts)
- [comment server route and DTO](https://github.com/auto-novel/auto-novel/blob/f5a6a8b403e1a23a13807ca1a2a97331f9e3c2e4/server/src/main/kotlin/api/RouteComment.kt)
- [JSON serialization policy](https://github.com/auto-novel/auto-novel/blob/f5a6a8b403e1a23a13807ca1a2a97331f9e3c2e4/server/src/main/kotlin/api/plugins/ContentNegotiation.kt)

Live HTTP checks used ordinary anonymous `GET` requests with no bearer token or
cookie jar. They verified:

- safe catalog and author search responses;
- one general-rated Novel Detail and Chapter List;
- an early fully translated chapter and a later partially translated chapter;
- Syosetu and Kakuyomu ranking response envelopes; and
- one Web Novel's top-level Comment page with embedded replies.

Samples were inspected only for field names, types, optionality, pagination,
and array lengths. Proprietary novel prose and user comment text must not be
committed as fixtures.

## Base HTTP policy

| Property | Contract |
| --- | --- |
| Origin | `https://n.novelia.cc` |
| API prefix | `/api` |
| Supported method in this scope | `GET` |
| Request body | None |
| Anonymous authorization | No `Authorization` header |
| Cookie dependency | None observed or required by the verified requests |
| Successful media type | `application/json` |
| Time representation | Unix epoch seconds |
| Nullable JSON fields | Omitted instead of emitted as `null` |

Only `gateway/novelia` may know these paths or DTO names. Domain and feature
code must consume normalized models rather than raw response maps.

The gateway must use HTTPS and an explicit host allowlist. The APK's alternate
hosts and cleartext update URL are not part of this contract. Do not silently
switch hosts after a transport, parsing, or authorization failure.

## Catalog and search

### Request

```http
GET /api/novel?page={page}&pageSize={pageSize}&query={query}&provider={providers}&type={type}&level={level}&translate={translate}&sort={sort}
```

There is no request body. Query parameter order is not significant.

| Parameter | Meaning | Values used by the website |
| --- | --- | --- |
| `page` | Page index | Zero-based integer |
| `pageSize` | Requested item count | `20` |
| `query` | Chinese/Japanese title or author query | String; empty is accepted |
| `provider` | Provider IDs | Comma-separated list |
| `type` | Publication state | `0` all, `1` ongoing, `2` completed, `3` short |
| `level` | Content level | `0` all, `1` general, `2` R18 |
| `translate` | Translation filter | `0` all, `1` GPT, `2` Sakura |
| `sort` | Ordering | `0` updated, `1` visits, `2` relevance |

Provider IDs exposed by the signed-out website are:

```text
kakuyomu,syosetu,novelup,hameln,pixiv,alphapolis
```

An empty `provider` produces an empty page; it does not mean all providers.

### Required anonymous defaults

Every signed-out catalog or search request must explicitly send:

```text
provider=kakuyomu,syosetu,novelup,hameln,pixiv,alphapolis
level=1
```

The default catalog request is therefore:

```http
GET /api/novel?page=0&pageSize=20&query=&provider=kakuyomu,syosetu,novelup,hameln,pixiv,alphapolis&type=0&level=1&translate=0&sort=0
```

The homepage's “most visited” shelf uses the same safe provider and level
values with `sort=1`. Search is the same endpoint with a non-empty `query`;
`sort=2` is the user-selectable relevance order, not an automatic consequence
of supplying a query.

This is a fail-closed rule, not a convenience default. The server defines both
`level=0` and `level=2` as requiring NSFW access. A live anonymous request with
`level=0` returned:

```text
HTTP 401
Content-Type: text/plain; charset=UTF-8
游客没有权限执行此操作
```

The gateway must never retry that response with a different level, token,
cookie, host, or hidden browser session. It may offer the safe `level=1`
catalog as a separate normal request.

### Response

```text
Page<WebNovelOutlineDto> {
  items: WebNovelOutlineDto[]
  pageNumber: number
}

WebNovelOutlineDto {
  providerId: string
  novelId: string
  titleJp: string
  titleZh?: string
  type?: "连载中" | "已完结" | "短篇"
  attentions: string[]
  keywords: string[]
  extra?: string
  favored?: string
  lastReadAt?: number
  total: number
  jp: number
  baidu: number
  youdao: number
  gpt: number
  sakura: number
  updateAt?: number
}
```

`pageNumber` is the total page count, not the requested page index. The live
default catalog returned 20 items with `pageNumber: 500`; a live author search
returned one item with `pageNumber: 1`.

`favored` and `lastReadAt` are signed-in enrichment fields and were absent from
the anonymous samples. `extra` appeared on ranking items but not normal catalog
items. The gateway decoder must tolerate all nullable fields being absent.

An opt-in live ranking smoke on 2026-08-18 observed a transient synchronization
race in which a positive Translation count exceeded `total` by one. For ranking
rows only, the client may cap a positive over-report to `total`, because no
readable translated chapter can exist beyond the reported original catalog.
Negative counts, and the same inconsistency in ordinary Catalog or Novel Detail
responses, remain invalid and must fail closed.

## Novel Details and Chapter List

### Request

```http
GET /api/novel/{providerId}/{novelId}
```

There is no query string or request body.

### Response

```text
NovelDto {
  wenkuId?: string
  titleJp: string
  titleZh?: string
  authors: AuthorDto[]
  type?: "连载中" | "已完结" | "短篇"
  attentions: string[]
  keywords: string[]
  points?: number
  totalCharacters?: number
  introductionJp: string
  introductionZh?: string
  glossary: { [japanese: string]: string }
  toc: NovelTocItemDto[]
  visited: number
  syncAt: number
  favored?: string
  lastReadChapterId?: string
  jp: number
  baidu: number
  youdao: number
  gpt: number
  sakura: number
}

AuthorDto {
  name: string
  link?: string
}

NovelTocItemDto {
  titleJp: string
  titleZh?: string
  chapterId?: string
  createAt?: number
}
```

The Chapter List is the `toc` array. It deliberately mixes:

- section rows, which have titles but no `chapterId`; and
- readable chapter rows, which have a `chapterId` and may have `createAt`.

Section rows must remain available to the presentation model, but they must
never generate a Chapter Content request. `createAt` and `syncAt` are epoch
seconds. Anonymous responses omit `favored` and `lastReadChapterId`.

### Anonymous content gate

Unlike catalog search, the detail and chapter paths do not accept `level=1`.
The mobile app must therefore enforce its own fail-closed navigation rule:

1. Decode Novel Details before exposing its introduction, Chapter List, or
   comment entry point.
2. If `attentions` contains `R18`, do not expose the novel in anonymous mode.
3. Fetch Chapter Content only for a novel whose decoded details passed that
   check during the current or locally verified revision.
4. Do not probe arbitrary chapter URLs to determine whether restricted content
   is accessible.

This is an application safety assumption, not a claim that the server enforces
the same rule on every direct detail URL. Direct R18 behavior was intentionally
not tested.

## Chapter Content and translations

### Request

```http
GET /api/novel/{providerId}/{novelId}/chapter/{chapterId}
```

There is no query string or request body.

### Response

```text
ChapterDto {
  titleJp: string
  titleZh?: string
  novelTitleJp: string
  novelTitleZh?: string
  prevId?: string
  nextId?: string
  paragraphs: string[]
  baiduParagraphs?: string[]
  youdaoParagraphs?: string[]
  gptParagraphs?: string[]
  sakuraParagraphs?: string[]
}
```

`paragraphs` is the Japanese Original and defines the canonical source-index
space. Each Chinese Translation array is independently optional. The first or
last chapter omits `prevId` or `nextId`, respectively.

The live DTO contains `baiduParagraphs`, even though the deployed frontend's
TypeScript model omits it. The live outline and detail DTOs likewise contain a
`baidu` count. This is direct evidence that gateway decoding must not depend on
the frontend type declarations alone.

### Omission and alignment behavior

The server uses `explicitNulls = false`. An unavailable title, neighbor ID, or
Translation array is absent from the JSON object; it is not reliably present
with a `null` value.

Observed chapters behaved as follows:

- a fully translated chapter had Japanese, Baidu, Youdao, GPT, and Sakura
  arrays of length 55; and
- a later chapter had Japanese, Youdao, and Sakura arrays of length 223 while
  Baidu and GPT arrays were omitted.

All observed arrays included empty-string entries used as aligned separators.
The gateway must preserve those entries and their indices. It must not trim,
filter, collapse, or infer paragraph boundaries from blank strings.

Normalization rules:

1. Emit one Aligned Block for every `paragraphs[index]`, including empty
   strings.
2. Attach a Chinese Translation only when the selected array is present and
   its length exactly equals the Japanese Original array length.
3. An absent array means Translation Pending or unavailable for that source;
   retain and render the complete Japanese Original.
4. Any shorter or longer array is an invalid Translation Revision. Hide that
   source's complete Chinese Translation, retain and render every Japanese
   block, and expose a refresh/error state; never guess or partially repair the
   pairing.
5. Treat an empty translation entry in an otherwise length-matched array as
   data. Do not reinterpret it as an
   omitted Translation without a separate service signal.
6. Record source name, original count, translation count, provider ID, novel
   ID, and chapter ID in a redacted mismatch diagnostic. Never log prose.

Equal lengths are an observation, not a service guarantee. Contract fixtures
must include absent, shorter, longer, and empty-string Translation cases.

## Rankings

### Request

```http
GET /api/novel/rank/{providerId}?{providerSpecificParameters}
```

There is no request body. The response is `Page<WebNovelOutlineDto>` with the
same field and omission behavior as catalog results.

The endpoint forwards provider-specific Chinese labels rather than stable
numeric enums.

#### Syosetu

| Website ranking | Query parameters |
| --- | --- |
| Genre | `type=流派&genre={genre}&range={range}&status={status}&page={page}` |
| Overall | `type=综合&range={range}&status={status}&page={page}` |
| Isekai transfer/reincarnation | `type=异世界转生/转移&genre={genre}&range={range}&status={status}&page={page}` |

Syosetu ranking `page` is one-based.

- Ranges: `总计`, `每年`, `季度`, `每月`, `每周`, `每日`.
- Statuses: `全部`, `短篇`, `连载`, `完结`.
- Genres are the labels defined by the deployed
  [ranking option mapping](https://github.com/auto-novel/auto-novel/blob/f5a6a8b403e1a23a13807ca1a2a97331f9e3c2e4/web/src/pages/list/option.ts).

The verified default request was:

```http
GET /api/novel/rank/syosetu?type=流派&genre=恋爱：异世界&range=总计&status=全部&page=1
```

It returned 50 items with `pageNumber: 2`.

#### Kakuyomu

```http
GET /api/novel/rank/kakuyomu?genre={genre}&range={range}&status={status}
```

The deployed client does not send a page parameter for Kakuyomu.

- Genres: `综合`, `异世界幻想`, `现代幻想`, `科幻`, `恋爱`, `浪漫喜剧`,
  `现代戏剧`, `恐怖`, `推理`, `散文·纪实`, `历史·时代·传奇`,
  `创作论·评论`, `诗·童话·其他`.
- Ranges: `总计`, `每年`, `每月`, `每周`, `每日`.
- Statuses: `全部`, `长篇`, `短篇`.

The verified default request returned a valid empty envelope:
`{"items":[],"pageNumber":1}`. That result establishes the response shape but
does not prove that every Kakuyomu option is currently populated.

### Anonymous ranking safety

The ranking endpoint has no `level` parameter. Before returning ranking items
to anonymous feature code, the gateway must discard any outline whose
`attentions` contains `R18`. Opening a surviving result is still subject to the
Novel Details content gate above.

## Per-novel comments

### Request

```http
GET /api/comment?site=web-{providerId}-{novelId}&page={page}&pageSize={pageSize}
```

The exact site key uses hyphens:

```text
web-{providerId}-{novelId}
```

It is not a slash-delimited novel path. For example:

```text
web-syosetu-n8439ed
```

| Parameter | Meaning | Website value |
| --- | --- | --- |
| `site` | Comment thread identity | Exact key above |
| `page` | Page index | Zero-based |
| `pageSize` | Top-level comments per page | `10` |
| `parentId` | Optional parent comment ID for reply pagination | Omitted for the top level |

There is no request body. The same endpoint with `parentId={commentId}` returns
a page of replies.

### Response

```text
Page<CommentDto> {
  items: CommentDto[]
  pageNumber: number
}

CommentDto {
  id: string
  user: {
    username: string
  }
  content: string
  hidden: boolean
  createAt: number
  numReplies: number
  replies: CommentDto[]
}
```

Top-level comments are returned newest-first and include up to ten replies per
item. A request with `parentId` returns replies without further embedded reply
lists. `createAt` is epoch seconds. For an anonymous caller, a hidden comment
retains `hidden: true` while `content` is an empty string.

Comment text and usernames are untrusted remote content. Do not interpret HTML,
load embedded resources, or place comments into an unrestricted WebView. Logs,
analytics, crash reports, and fixtures must not contain comment bodies or
usernames.

Comment creation, deletion, hiding, and unhiding are authenticated mutations
and are outside this contract.

## Parsing and schema-drift policy

Gateway DTO parsing must be tolerant where the external service is explicitly
optional and strict where the domain cannot be constructed safely.

- Ignore unknown JSON fields.
- Accept an omitted nullable field and an explicit `null` defensively, even
  though the current server omits nulls.
- Treat missing required identifiers, original paragraph arrays, or page
  envelopes as a parse failure.
- Validate values before domain conversion: page counts and translation counts
  must be non-negative; arrays must contain strings; IDs must be non-empty. The
  ranking-only positive-counter normalization above is the sole documented
  exception to the usual `translation <= total` invariant.
- Do not treat a missing translated title or Translation array as a whole-page
  failure.
- Do not silently substitute a different Translation Source.
- Keep raw DTOs inside the gateway boundary. Persist normalized domain records,
  schema version, retrieval time, and content revision metadata.

The live `baidu` field absent from the web TypeScript model is the concrete
schema-drift case that this policy must cover.

## Transport, security, and error handling

The gateway must classify failures without destroying verified local state:

| Failure | Required behavior |
| --- | --- |
| Offline, DNS, TLS, or timeout | Serve verified local content when available; expose retry |
| `401` or `403` | Treat as access denied; do not change credentials, level, host, or cookies automatically |
| `404` | Mark only the requested remote entity unavailable; retain downloads, cache, and reading state |
| `429` | Honor `Retry-After` when present; do not poll aggressively |
| Other `4xx` | Surface a request error without automatic parameter guessing |
| `5xx` | Retain current data and use bounded retry only for user-visible idempotent GETs |
| Invalid JSON or required-field mismatch | Suspend only the affected refresh and record redacted schema diagnostics |
| Translation length mismatch | Reject that complete Translation Revision, preserve every Japanese block, and expose refresh/error state |

Error bodies are not a stable JSON schema. The observed anonymous catalog
denial was `text/plain`; decoders must not assume an object such as
`{"error": ...}` for non-success responses.

Retries must remain idempotent, bounded, and cancellable. A parsing error must
never trigger a retry loop. No failure may clear the local database, Reading
Position, Bookmarks, Favorites, Cache Copies, or Offline Downloads.

Diagnostics may include:

- HTTP method;
- endpoint template rather than full content-bearing URL;
- status code;
- provider, novel, and chapter identifiers;
- pagination numbers;
- DTO field names and array counts; and
- a server request identifier when one is returned.

Diagnostics must redact authorization values, cookies, query text, titles,
introductions, glossary entries, paragraphs, comments, usernames, and complete
response bodies.

## Contract verification requirements

Before feature code uses the live gateway:

1. Add sanitized fixtures for every DTO above.
2. Include fixtures with omitted optional fields and unknown fields.
3. Include Chapter Content fixtures for full, absent, short, long, and
   empty-string Translation arrays.
4. Contract-test the safe catalog defaults, especially `level=1` and the
   explicit provider list.
5. Contract-test the exact hyphenated Novel Comment site key.
6. Verify that anonymous ranking and deep-link navigation reject R18 metadata.
7. Verify that all parser and transport failures preserve previously verified
   local content.
8. Keep live smoke tests opt-in, low-volume, read-only, and out of routine CI.

## Unverified limits

The following remain intentionally unverified:

- whether third-party mobile use of these APIs and content is permitted;
- any formal compatibility, availability, versioning, or deprecation promise;
- the deployed backend's build identity—the site exposes only the frontend
  commit, although live responses matched its server source;
- authentication, refresh, logout, and signed-in enrichment behavior;
- every R18 response path, which was not probed;
- every provider, ranking combination, error response, and `parentId` reply
  page on the live service;
- maximum accepted page sizes, rate-limit thresholds, and retry headers;
- a service guarantee that Chinese Translation arrays always match Japanese
  paragraph counts;
- cache validators, revision identifiers, and conflict behavior;
- the APK's alternate `sakura-share.one` hosts and any custom-base-URL
  compatibility; and
- all write and upload endpoints.

Until service permission and a supported authentication flow are established,
this contract authorizes only the narrow anonymous read slice described above.
