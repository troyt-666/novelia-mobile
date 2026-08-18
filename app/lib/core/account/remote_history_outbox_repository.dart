import 'account_sync_models.dart';

abstract interface class RemoteHistoryOutboxRepository {
  /// Keeps only the most recent activity for a novel.
  void queueRemoteHistory(RemoteHistoryOutboxEntry entry);

  List<RemoteHistoryOutboxEntry> listRemoteHistoryOutbox();

  /// Removes the row only if no newer activity replaced [entry].
  bool removeRemoteHistoryIfUnchanged(RemoteHistoryOutboxEntry entry);

  void clearRemoteHistoryOutbox();
}
