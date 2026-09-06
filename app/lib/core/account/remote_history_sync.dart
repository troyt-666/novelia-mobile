import 'dart:async';

import '../../gateway/novelia/novelia_account_gateway.dart';
import '../model/reader_models.dart';
import 'account_models.dart';
import 'account_session_controller.dart';
import 'account_sync_models.dart';
import 'remote_history_outbox_repository.dart';

/// Owns account-scoped history deduplication and the durable latest-read outbox.
class RemoteHistorySync {
  RemoteHistorySync({
    required this.repository,
    required this.sessionController,
    required this.gateway,
  });

  final RemoteHistoryOutboxRepository repository;
  final AccountSessionController? sessionController;
  final NoveliaAccountGateway? gateway;
  bool _ownerInitialized = false;
  String? _owner;
  bool _flushing = false;
  bool _disposed = false;
  final Map<String, String> _lastChapterByNovel = {};

  void dispose() => _disposed = true;

  void signedOut() {
    clear();
    _owner = null;
    _ownerInitialized = true;
  }

  void updateSession(AccountSessionSnapshot? session) {
    if (session == null) return;
    if (session.status == AccountSessionStatus.restoring &&
        session.profile == null) {
      return;
    }
    final username = session.profile?.username;
    if (!_ownerInitialized) {
      _owner = username;
      _ownerInitialized = true;
      if (session.status == AccountSessionStatus.signedOut) {
        clear();
      }
      return;
    }
    if (username == _owner) return;
    clear();
    _owner = username;
  }

  void clear() {
    repository.clearRemoteHistoryOutbox();
    _lastChapterByNovel.clear();
  }

  void record(
    ReaderNovel novel,
    ReadingPosition position,
    DateTime occurredAt,
  ) {
    if (sessionController?.snapshot.hasStoredAccount != true ||
        gateway == null ||
        _lastChapterByNovel[novel.id] == position.chapterId) {
      return;
    }
    final separator = novel.id.indexOf('/');
    final key = separator <= 0 || separator == novel.id.length - 1
        ? null
        : (novel.id.substring(0, separator), novel.id.substring(separator + 1));
    if (key == null) return;
    _lastChapterByNovel[novel.id] = position.chapterId;
    repository.queueRemoteHistory(
      RemoteHistoryOutboxEntry(
        novelId: novel.id,
        providerId: key.$1,
        serviceNovelId: key.$2,
        chapterId: position.chapterId,
        occurredAt: occurredAt,
      ),
    );
    unawaited(flush());
  }

  Future<void> flush() async {
    final accountGateway = gateway;
    if (_disposed ||
        _flushing ||
        accountGateway == null ||
        sessionController?.snapshot.isSignedIn != true) {
      return;
    }
    _flushing = true;
    try {
      while (!_disposed && sessionController?.snapshot.isSignedIn == true) {
        final entries = repository.listRemoteHistoryOutbox();
        if (entries.isEmpty) break;
        final entry = entries.first;
        try {
          await accountGateway.updateReadHistory(
            providerId: entry.providerId,
            novelId: entry.serviceNovelId,
            chapterId: entry.chapterId,
          );
          if (_disposed) return;
          repository.removeRemoteHistoryIfUnchanged(entry);
        } on Object {
          break;
        }
      }
    } finally {
      _flushing = false;
    }
  }
}
