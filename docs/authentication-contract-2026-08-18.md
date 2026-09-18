# Novelia authentication compatibility contract — 2026-08-18

Status: public-client contract plus owned-account login, refresh, macOS
prompt-free restoration, favorite-folder metadata, a row-bearing Favorite page,
Favorite add/remove, populated Reading History loading and writing, and logout
with local-state retention verified on 2026-08-18. No credential, cookie value,
token value, account identifier, folder title, or novel identity was recorded.

## Boundary

- Authentication is hosted at `https://auth.novelia.cc` and content APIs remain
  at `https://n.novelia.cc/api`.
- The hosted login form sends `POST /api/v1/auth/login` with JSON fields `app`,
  `username`, and `password`. The website uses `app=n`. The live service checks
  the media type unusually strictly: send exactly `Content-Type:
  application/json`; it rejects `application/json; charset=utf-8` with HTTP
  415 even though that parameter is normally valid.
- A successful login establishes an HttpOnly refresh cookie. The website then
  sends `POST /api/v1/auth/refresh?app=n` with credentials included and treats
  the response body as a bearer access token.
- The credentialed login response itself also contained a JWT access token and
  set an HttpOnly cookie named `refresh-token`. The native compatibility flow
  still performs the same immediate refresh used when the main website takes
  over after hosted login, so one path validates both the cookie session and
  refresh endpoint before it persists anything.
- A subsequent refresh returned a JWT without rotating the cookie. The client
  therefore retains the existing cookie unless a valid replacement is set.
- Logout uses `POST /api/v1/auth/logout` with the refresh cookie.
- The access token is a JWT whose public claims include the username (`sub`),
  role, audience array, issued time, account creation time, and expiry.

## Authenticated content boundary

- `GET /api/user/favored` returned JSON fields `favoredWeb` and
  `favoredWenku`, each containing folder objects with string `id` and `title`.
- The current public client pages Web Novel favorites with
  `GET /api/user/favored-web/{folderId}` plus the complete catalog query
  (`page`, `pageSize`, `query`, `provider`, `type`, `level`, `translate`, and
  `sort`). Omitting the catalog filter fields returned HTTP 404 in the owned
  account smoke, while the ordinary catalog's numeric sort code returned HTTP
  500; this endpoint expects the string `sort=update` or `sort=create`. The app
  originally fixed `level=1`, `sort=update`, and the six supported catalog
  providers at this boundary. As of 2026-09-15, authenticated Favorites use
  `level=0` (all ratings accessible to the account), matching signed-in catalog
  behavior; retaining the anonymous `level=1` default hid R18 favorites.
  Favorite Folder screens now pass title/author search, multi-select providers,
  publication type, rating, translation and update/creation sorting through to
  that endpoint. Defaults remain all providers, all ratings and `sort=update`.
  An empty provider selection stays empty rather than silently broadening the
  query. The filter snapshot is retained across pages and retries; changes start
  at page zero. Reading History pages with
  `GET /api/user/read-history?page={zeroBased}&pageSize=30`.
- Both page responses use the ordinary Web Novel outline page shape (`items`
  plus `pageNumber`). The app uses the current account session to allow R18
  rows before displaying or caching them. The Favorites correction is covered
  by loopback HTTP and signed-in app fixture tests, not a live-account probe.
- Creating a Web Novel folder uses an exact `application/json` request. Reading
  History updates send the chapter ID as a raw UTF-8 body without inventing a
  content type, matching the current public client.

## Wenku access correction — 2026-09-18

The Wenku gateway now obtains the current session's bearer token for each
request, matching the Web Novel gateway. Previously the production bootstrap
created an anonymous Wenku gateway even when the reader had signed in, so both
R18 catalog filters and restricted novel details failed authorization. A 401
with an existing token triggers one forced refresh and one retry; anonymous
requests and 403 responses do not trigger refresh. Logout takes effect on the
next request. Existing host pinning and the single same-origin EPUB redirect
restriction remain in force.

The public server contract maps `level=5` to R18男性向 and `level=6` to R18女性向.
Both catalog filters and restricted novel details call `requireNsfwAccess`,
which requires a signed-in account created at least 30 days earlier. Both a
missing session and an account that is too new return 401, so the app's access
message mentions both login and the site's access conditions. Sources are
[`RouteWenkuNovel.kt`](https://github.com/auto-novel/auto-novel/blob/ac0875439a3d24d6287c620f85617755389ba75a/server/src/main/kotlin/api/RouteWenkuNovel.kt)
and [`Authentication.kt`](https://github.com/auto-novel/auto-novel/blob/ac0875439a3d24d6287c620f85617755389ba75a/server/src/main/kotlin/api/plugins/Authentication.kt).

Loopback HTTP tests cover both filter codes, pagination, query preservation,
token replacement, logout, expired-token refresh, failed refresh and access
denial. The macOS native fixture uses the real HTTP gateway against a loopback
server to cover anonymous failure, successful retry after token refresh, both
filters, search, pagination and opening restricted details. It uses synthetic
tokens and content and never opens the reader database or stored session.
The native entry is `app/integration_test/wenku_filters_test.dart`, with driver
`app/test_driver/wenku_filters_driver.dart`. Screenshots are saved under ignored
`app/build/ui-ux/2026-09-18/wenku-r18-macos-*.png` (800 × 600 Flutter viewport,
light theme, default text scale). Android was not launched for this correction,
and no live-account access was tested.

## Native login flow

The hosted page has no observed OAuth/OIDC authorization endpoint, PKCE
parameters, custom-scheme redirect, or universal-link callback. When embedded
by the website it sends a `login_success` message to its parent frame; when
opened as a top-level browser page it redirects to the website. Therefore a
system-browser login cannot currently return a session to this app.

The app may use the same direct password exchange as a compatibility flow. It
must never persist or log the password. Android and iOS keep the refresh cookie
and access token in their protected credential stores. By explicit product
choice, macOS keeps the combined session in user-scoped app preferences so
ad-hoc development builds do not repeatedly request the login Keychain
password. This macOS value is not encrypted; logout deletes it. Sessions must
never enter SQLite, diagnostics, or fixtures.

## Live-test rule

All deterministic tests use fake or loopback services. A real login, refresh,
favorite mutation, or history mutation is opt-in and must use an owned test
account. Credentials are entered into the running app and are never passed in
source files, shell arguments, logs, screenshots, or chat.

## Still to verify with an owned account

- refresh-cookie expiry and server-side logout invalidation;
- access-token lifetime and expired-session status codes;
- live favorite-folder creation and cross-device visibility;
- Reading History cross-device conflict behavior;
- whether concurrent refresh requests invalidate an earlier rotated cookie.
