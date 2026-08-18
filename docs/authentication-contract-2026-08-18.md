# Novelia authentication compatibility contract — 2026-08-18

Status: public-client contract plus owned-account login, refresh, secure macOS
restoration, and favorite-folder listing verified on 2026-08-18. No credential,
cookie value, token value, account identifier, folder title, or novel identity
was recorded.

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
  `GET /api/user/favored-web/{folderId}?page={zeroBased}&pageSize=30` and pages
  Reading History with
  `GET /api/user/read-history?page={zeroBased}&pageSize=30`.
- Both page responses use the ordinary Web Novel outline page shape (`items`
  plus `pageNumber`). The app applies its existing general-content validation
  before displaying or caching an account row.
- Creating a Web Novel folder uses an exact `application/json` request. Reading
  History updates send the chapter ID as a raw UTF-8 body without inventing a
  content type, matching the current public client.

## Native-flow finding

The hosted page has no observed OAuth/OIDC authorization endpoint, PKCE
parameters, custom-scheme redirect, or universal-link callback. When embedded
by the website it sends a `login_success` message to its parent frame; when
opened as a top-level browser page it redirects to the website. Therefore a
system-browser login cannot currently return a session to this app.

The app may use the same direct password exchange as a compatibility flow. It
must never persist or log the password. The returned refresh cookie and access
token belong only in Keychain/Keystore-backed storage, must be deleted on
logout, and must never enter SQLite, preferences, diagnostics, or fixtures.

## Live-test rule

All deterministic tests use fake or loopback services. A real login, refresh,
favorite mutation, or history mutation is opt-in and must use an owned test
account. Credentials are entered into the running app and are never passed in
source files, shell arguments, logs, screenshots, or chat.

## Still to verify with an owned account

- refresh-cookie expiry and logout invalidation;
- access-token lifetime and expired-session status codes;
- live favorite-folder creation, add/remove mutation status codes, and
  cross-device visibility;
- live favorite-page and Reading History page schemas when they contain rows;
- Reading History write status and cross-device conflict behavior;
- whether concurrent refresh requests invalidate an earlier rotated cookie.
