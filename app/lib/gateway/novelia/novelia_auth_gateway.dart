import '../../core/account/account_models.dart';

enum NoveliaAuthFailureKind {
  invalidCredentials,
  sessionExpired,
  timeout,
  network,
  invalidResponse,
  server,
}

class NoveliaAuthException implements Exception {
  const NoveliaAuthException(
    this.kind,
    this.message, {
    this.statusCode,
    this.diagnosticCode,
  });

  final NoveliaAuthFailureKind kind;
  final String message;
  final int? statusCode;
  final String? diagnosticCode;

  @override
  String toString() =>
      'NoveliaAuthException($kind, $message'
      '${diagnosticCode == null ? '' : ', $diagnosticCode'})';
}

abstract interface class NoveliaAuthGateway {
  Future<StoredAccountSession> login({
    required String username,
    required String password,
  });

  Future<StoredAccountSession> refresh(StoredAccountSession session);

  Future<void> logout(StoredAccountSession session);
}
