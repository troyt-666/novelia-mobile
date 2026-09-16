## verdict

- **P2 — resolved.** The recaptured preview now shows total books and download records, plus their expected additions; the completion capture shows added books and download records. `app/lib/features/backup/backup_screen.dart:110` and `:233` use the new values. Source inspection confirms that `ReaderBackup.downloadCount`, `BackupPreview.newDownloads`, and `BackupMergeResult.downloadsAdded` derive from download intents. Record-only migration no longer lacks a visible category in the summary.
- **P3 — resolved.** The preview now scopes its counts to “备份中的记录” and explicitly states “未选的进度位置另存为书签。” The recaptured success still shows the actual total of two bookmarks, and the distinction is explained before confirmation.

Reopened all five original screenshot paths after recapture: `backup-phone.png`, `backup-phone-preview.png`, `backup-phone-success.png`, `backup-phone-error.png`, and `backup-phone-dark-large-preview.png`. All remain valid 1080×2400 Android emulator fixture app captures. The updated summary wraps without overlap in the dark capture at Flutter text scale 1.6. No regressions from this narrow fix batch were observed. This verdict scores the two original findings only; no new defect hunt was performed.

## remaining

Clear for the two scored fixes. The parent reports the Android integration flow passing again and 17 focused backup tests passing; the 379-test full suite passed before this narrow summary patch. Tests were not rerun by the reviewer. Existing evidence limitations remain: these fixture captures do not establish real system-picker behavior, production-route back gestures, tablet layout, screen-reader operation, or native iOS/HarmonyOS runtime correctness. The fixture mounts this screen as its home. HarmonyOS compilation and macOS picker testing remain separate evidence owned by the main task. No web detector, comp, or new shipping raster applies to this Material 3 extension. No app code was changed by the reviewer.

disposition: ship
