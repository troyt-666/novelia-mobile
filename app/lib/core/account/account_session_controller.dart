import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../gateway/novelia/novelia_auth_gateway.dart';
import 'account_models.dart';
import 'secure_session_store.dart';

class AccountSessionController extends ChangeNotifier {
  AccountSessionController({
    required this.gateway,
    required this.store,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final NoveliaAuthGateway gateway;
  final AccountSessionStore store;
  final DateTime Function() _now;

  AccountSessionSnapshot _snapshot = const AccountSessionSnapshot.signedOut();
  StoredAccountSession? _session;
  Future<StoredAccountSession?>? _refreshInFlight;
  var _epoch = 0;
  Future<void> _mutationQueue = Future<void>.value();

  AccountSessionSnapshot get snapshot => _snapshot;

  Future<T> _enqueueMutation<T>(Future<T> Function() action) {
    final result = Completer<T>();
    _mutationQueue = _mutationQueue.catchError((_) {}).then((_) async {
      try {
        result.complete(await action());
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  Future<void> restore() async {
    await _enqueueMutation(() async {
      _setSnapshot(const AccountSessionSnapshot.restoring());
      try {
        final stored = await store.read();
        if (stored == null) {
          await _clearLocalSession();
          return;
        }
        final profile = decodeNoveliaAccessToken(stored.accessToken);
        _session = stored;
        _setSnapshot(AccountSessionSnapshot.restoring(profile: profile));
      } on Object {
        await _clearLocalSession();
      }
    });
    await _refresh();
  }

  Future<void> login({
    required String username,
    required String password,
  }) async {
    final previous = _session;
    final session = await gateway.login(username: username, password: password);
    final profile = decodeNoveliaAccessToken(session.accessToken);
    await _enqueueMutation(() async {
      _epoch += 1;
      await store.write(session);
      _session = session;
      _refreshInFlight = null;
      _setSnapshot(AccountSessionSnapshot.signedIn(profile));
    });
    if (previous == null) return;
    try {
      await gateway.logout(previous);
    } on Object {
      // The new local session is authoritative. Expiring the previous remote
      // refresh cookie is best effort.
    }
  }

  Future<String?> accessToken({bool forceRefresh = false}) async {
    final session = _session;
    if (session == null) return null;
    try {
      final profile = decodeNoveliaAccessToken(session.accessToken);
      final refreshAt = profile.expiresAt.subtract(const Duration(minutes: 2));
      if (!forceRefresh && _now().toUtc().isBefore(refreshAt)) {
        return session.accessToken;
      }
      return (await _refresh(reportUnavailable: false))?.accessToken;
    } on Object {
      return null;
    }
  }

  Future<void> retry() async {
    if (_session == null) {
      await restore();
    } else {
      await _refresh();
    }
  }

  Future<void> logout() async {
    final session = _session;
    await _enqueueMutation(() async {
      await store.clear();
      _forgetSession();
    });
    if (session == null) return;
    try {
      await gateway.logout(session);
    } on Object {
      // Local credential deletion is authoritative. Remote expiry is best
      // effort and must never resurrect a locally logged-out session.
    }
  }

  Future<StoredAccountSession?> _refresh({bool reportUnavailable = true}) {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final session = _session;
    if (session == null) return Future.value(null);
    final future = _performRefresh(
      session,
      reportUnavailable: reportUnavailable,
    );
    _refreshInFlight = future;
    return future.whenComplete(() {
      if (identical(_refreshInFlight, future)) _refreshInFlight = null;
    });
  }

  Future<StoredAccountSession?> _performRefresh(
    StoredAccountSession current, {
    required bool reportUnavailable,
  }) async {
    final epoch = _epoch;
    try {
      final refreshed = await gateway.refresh(current);
      return await _enqueueMutation(() async {
        if (_epoch != epoch || !identical(_session, current)) return null;
        final profile = decodeNoveliaAccessToken(refreshed.accessToken);
        await store.write(refreshed);
        _session = refreshed;
        _setSnapshot(AccountSessionSnapshot.signedIn(profile));
        return refreshed;
      });
    } on Object catch (error) {
      // Success and failure belong to the session that started the request.
      // Serialize both with login/logout so an old response cannot alter a
      // newer account, including while credential storage is being written.
      return _enqueueMutation(() async {
        if (_epoch != epoch || !identical(_session, current)) return null;
        if (error is NoveliaAuthException && _invalidatesSession(error)) {
          await _clearLocalSession();
        } else if (reportUnavailable) {
          _setSnapshot(
            AccountSessionSnapshot.unavailable(
              decodeNoveliaAccessToken(current.accessToken),
              message: '暂时无法连接账号服务，本地阅读仍可使用',
            ),
          );
        }
        return null;
      });
    }
  }

  Future<void> _clearLocalSession() async {
    _forgetSession();
    try {
      await store.clear();
    } on Object {
      // Unusable credentials must leave memory even if storage cleanup fails.
    }
  }

  void _forgetSession() {
    _epoch += 1;
    _refreshInFlight = null;
    _session = null;
    _setSnapshot(const AccountSessionSnapshot.signedOut());
  }

  void _setSnapshot(AccountSessionSnapshot value) {
    _snapshot = value;
    notifyListeners();
  }

  static bool _invalidatesSession(NoveliaAuthException error) {
    return error.kind == NoveliaAuthFailureKind.sessionExpired ||
        error.kind == NoveliaAuthFailureKind.invalidResponse;
  }
}
