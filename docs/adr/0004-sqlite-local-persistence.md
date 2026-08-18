---
status: accepted
---

# SQLite local persistence

Use an application-support-directory SQLite database as the durable local
source of truth for download intents and tasks, offline-copy records, Reading
Positions, Bookmarks, last-route restoration, device-only recent searches, and
reader/application settings.
Keep repository interfaces independent of SQLite so deterministic in-memory
implementations remain available to UI fixtures and tests.

The current integrated database is schema version 5: version 1 contains
download state, version 2 adds local reader/application state, version 3 adds
bounded recent-search history, and version 4 adds normalized cached novel
outlines, details, ordered section/chapter catalogs, exact chapter payloads,
and payload references from offline copies. Version 5 adds a credential-free,
latest-activity-wins remote Reading History outbox; account tokens and cookies
remain outside SQLite. Migration tests start from earlier schemas and prove
that existing download, local-state, and search records survive the complete
forward migration.

The database has an explicit monotonically increasing schema version and
forward-only, transactional migrations. Opening an older supported database
migrates it without discarding verified records. A database created by a newer
application version is refused rather than guessed at or downgraded. Failed
migrations roll back atomically, integrity checks are available for diagnosis,
and corrupt or unrecognized persisted enum/state values fail locally instead
of silently rewriting data.

Persist Cache Copies and Offline Downloads as different retention classes.
Cache Copies remain expendable and eligible for deterministic least-recently-
read eviction, subject to active-chapter protection. Offline Downloads remain
protected until their owning download intent is explicitly removed; cache
pressure must never evict them. Download-task completion stores its matching
Offline Download record and final task state in one transaction.

Cache Copy identity is stable per novel, chapter, and Translation Source, so a
new fetch replaces and garbage-collects the prior semantic copy instead of
inflating storage accounting with timestamp-derived duplicates. Removing
expendable cached novel data retains its outline/detail/TOC manifest whenever a
protected copy or enabled download intent still needs that novel, preserving
offline Library discovery and launch after process restart.

`CachedChapterPayload` stores exact Japanese blocks plus the structurally
validated state and blocks of every supported Chinese Translation Source.
Ordinary reads commit a payload and its evictable Cache Copy atomically.
Explicit downloads commit the payload, protected Offline Download, and final
task transition in one transaction, so a task can never claim success without
readable content.

A Japanese-only chapter whose selected translation has not been generated is
stored as Translation Pending rather than discarded. Foreground/startup
download reconciliation rechecks a bounded number of pending protected copies.
When translation later appears, the repository atomically repoints the same
protected copy to the new content revision while leaving its already-stored
task identity and revision intact. Older or mismatched refreshes fail closed;
the prior readable payload remains referenced until a valid replacement
commits, and is garbage-collected only when no copy still references it.

On startup or foreground reconciliation, active, paused, and retryable-failed
tasks under an enabled intent are requeued in one transaction. The restart
transition clears byte counters and partial transfer metadata because the
current HTTP implementation restarts whole responses rather than promising
range resume. Bounded pending-translation refresh batches rotate candidates so
one repeatedly failing prefix cannot starve later protected chapters.
