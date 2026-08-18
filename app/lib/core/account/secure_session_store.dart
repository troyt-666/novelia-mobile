import 'package:flutter/services.dart';

import 'account_models.dart';

abstract interface class AccountSessionStore {
  Future<StoredAccountSession?> read();

  Future<void> write(StoredAccountSession session);

  Future<void> clear();
}

/// Stores the complete account session as one encrypted platform value.
///
/// Keeping one value avoids exposing a partially updated access-token/cookie
/// pair after a refresh. The native channel is intentionally account-specific
/// rather than a general arbitrary-key storage API.
class MethodChannelAccountSessionStore implements AccountSessionStore {
  const MethodChannelAccountSessionStore();

  static const _channel = MethodChannel('dev.novelia/account_session');

  @override
  Future<StoredAccountSession?> read() async {
    final encoded = await _channel.invokeMethod<String>('read');
    if (encoded == null) return null;
    return StoredAccountSession.decode(encoded);
  }

  @override
  Future<void> write(StoredAccountSession session) {
    return _channel.invokeMethod<void>('write', session.encode());
  }

  @override
  Future<void> clear() {
    return _channel.invokeMethod<void>('clear');
  }
}

class InMemoryAccountSessionStore implements AccountSessionStore {
  InMemoryAccountSessionStore([this.value]);

  StoredAccountSession? value;

  @override
  Future<void> clear() async => value = null;

  @override
  Future<StoredAccountSession?> read() async => value;

  @override
  Future<void> write(StoredAccountSession session) async => value = session;
}
