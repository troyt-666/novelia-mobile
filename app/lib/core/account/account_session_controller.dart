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

  AccountSessionSnapshot get snapshot => _snapshot;

  Future<void> restore() async {
    _setSnapshot(const AccountSessionSnapshot.restoring());
    StoredAccountSession? stored;
    try {
      stored = await store.read();
    } on Object {
      await _clearLocalSession();
      return;
    }
    if (stored == null) {
      _setSnapshot(const AccountSessionSnapshot.signedOut());
      return;
    }
    ReaderAccountProfile profile;
    try {
      profile = decodeNoveliaAccessToken(stored.accessToken);
    } on FormatException {
      await _clearLocalSession();
      return;
    }
    _session = stored;
    _setSnapshot(AccountSessionSnapshot.restoring(profile: profile));
    try {
      await _refresh();
    } on NoveliaAuthException catch (error) {
      if (_invalidatesSession(error)) {
        await _clearLocalSession();
      } else {
        _setSnapshot(
          AccountSessionSnapshot.unavailable(
            profile,
            message: '暂时无法连接账号服务，本地阅读仍可使用',
          ),
        );
      }
    } on Object {
      _setSnapshot(
        AccountSessionSnapshot.unavailable(
          profile,
          message: '暂时无法读取账号状态，本地阅读仍可使用',
        ),
      );
    }
  }

  Future<void> login({
    required String username,
    required String password,
  }) async {
    final session = await gateway.login(username: username, password: password);
    final profile = decodeNoveliaAccessToken(session.accessToken);
    await store.write(session);
    _session = session;
    _setSnapshot(AccountSessionSnapshot.signedIn(profile));
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
      return (await _refresh())?.accessToken;
    } on NoveliaAuthException catch (error) {
      if (_invalidatesSession(error)) await _clearLocalSession();
      return null;
    } on Object {
      return null;
    }
  }

  Future<void> retry() async {
    if (_session == null) {
      await restore();
      return;
    }
    try {
      await _refresh();
    } on NoveliaAuthException catch (error) {
      if (_invalidatesSession(error)) {
        await _clearLocalSession();
        return;
      }
      final profile = _snapshot.profile;
      if (profile != null) {
        _setSnapshot(
          AccountSessionSnapshot.unavailable(
            profile,
            message: '账号服务仍不可用，请稍后重试',
          ),
        );
      }
    }
  }

  Future<void> logout() async {
    final session = _session;
    await _clearLocalSession();
    if (session == null) return;
    try {
      await gateway.logout(session);
    } on Object {
      // Local credential deletion is authoritative. Remote expiry is best
      // effort and must never resurrect a locally logged-out session.
    }
  }

  Future<StoredAccountSession?> _refresh() {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final session = _session;
    if (session == null) return Future.value(null);
    final future = _performRefresh(session);
    _refreshInFlight = future;
    return future.whenComplete(() {
      if (identical(_refreshInFlight, future)) _refreshInFlight = null;
    });
  }

  Future<StoredAccountSession?> _performRefresh(
    StoredAccountSession current,
  ) async {
    final refreshed = await gateway.refresh(current);
    if (!identical(_session, current)) return _session;
    final profile = decodeNoveliaAccessToken(refreshed.accessToken);
    await store.write(refreshed);
    if (!identical(_session, current)) return _session;
    _session = refreshed;
    _setSnapshot(AccountSessionSnapshot.signedIn(profile));
    return refreshed;
  }

  Future<void> _clearLocalSession() async {
    _session = null;
    try {
      await store.clear();
    } on Object {
      // The in-memory session is still removed. A later restore will fail
      // closed if platform storage remains unavailable.
    }
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
