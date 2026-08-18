import 'dart:convert';

enum AccountSessionStatus { signedOut, restoring, signedIn, unavailable }

class ReaderAccountProfile {
  const ReaderAccountProfile({
    required this.username,
    required this.role,
    required this.issuedAt,
    required this.createdAt,
    required this.expiresAt,
  });

  final String username;
  final String role;
  final DateTime issuedAt;
  final DateTime createdAt;
  final DateTime expiresAt;

  bool isExpiredAt(DateTime now) => !expiresAt.isAfter(now.toUtc());
}

class StoredAccountSession {
  const StoredAccountSession({
    required this.cookieHeader,
    required this.accessToken,
  });

  final String cookieHeader;
  final String accessToken;

  String encode() => jsonEncode({
    'version': 1,
    'cookieHeader': cookieHeader,
    'accessToken': accessToken,
  });

  static StoredAccountSession decode(String encoded) {
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      throw const FormatException('Stored account session is not an object.');
    }
    if (decoded['version'] != 1 ||
        decoded['cookieHeader'] is! String ||
        decoded['accessToken'] is! String) {
      throw const FormatException('Stored account session has invalid fields.');
    }
    final cookieHeader = decoded['cookieHeader'] as String;
    final accessToken = decoded['accessToken'] as String;
    if (cookieHeader.trim().isEmpty || accessToken.trim().isEmpty) {
      throw const FormatException('Stored account session is empty.');
    }
    return StoredAccountSession(
      cookieHeader: cookieHeader,
      accessToken: accessToken,
    );
  }
}

class AccountSessionSnapshot {
  const AccountSessionSnapshot._({
    required this.status,
    required this.profile,
    required this.message,
  });

  const AccountSessionSnapshot.signedOut()
    : this._(
        status: AccountSessionStatus.signedOut,
        profile: null,
        message: null,
      );

  const AccountSessionSnapshot.restoring({ReaderAccountProfile? profile})
    : this._(
        status: AccountSessionStatus.restoring,
        profile: profile,
        message: null,
      );

  const AccountSessionSnapshot.signedIn(ReaderAccountProfile profile)
    : this._(
        status: AccountSessionStatus.signedIn,
        profile: profile,
        message: null,
      );

  const AccountSessionSnapshot.unavailable(
    ReaderAccountProfile profile, {
    required String message,
  }) : this._(
         status: AccountSessionStatus.unavailable,
         profile: profile,
         message: message,
       );

  final AccountSessionStatus status;
  final ReaderAccountProfile? profile;
  final String? message;

  bool get isSignedIn => status == AccountSessionStatus.signedIn;
  bool get hasStoredAccount => profile != null;
}

ReaderAccountProfile decodeNoveliaAccessToken(String token) {
  final segments = token.trim().split('.');
  if (segments.length != 3 || segments.any((segment) => segment.isEmpty)) {
    throw const FormatException('Access token is not a JWT.');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(segments[1]))),
    );
  } on Object {
    throw const FormatException('Access token payload is malformed.');
  }
  if (decoded is! Map) {
    throw const FormatException('Access token payload is not an object.');
  }
  final username = decoded['sub'];
  final role = decoded['role'];
  final expiresAt = _epochSeconds(decoded['exp'], 'exp');
  final issuedAt = _epochSeconds(decoded['iat'], 'iat');
  final createdAt = decoded['crat'] == null
      ? issuedAt
      : _epochSeconds(decoded['crat'], 'crat');
  if (username is! String || username.trim().isEmpty || role is! String) {
    throw const FormatException('Access token identity claims are invalid.');
  }
  return ReaderAccountProfile(
    username: username,
    role: role,
    issuedAt: issuedAt,
    createdAt: createdAt,
    expiresAt: expiresAt,
  );
}

DateTime _epochSeconds(Object? value, String field) {
  if (value is! num || !value.isFinite || value != value.roundToDouble()) {
    throw FormatException('Access token $field claim is invalid.');
  }
  return DateTime.fromMillisecondsSinceEpoch(value.toInt() * 1000, isUtc: true);
}
