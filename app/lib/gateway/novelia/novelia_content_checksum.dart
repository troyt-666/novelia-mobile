import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Stable SHA-256 checksum of JSON content. Map insertion order is part of
/// the caller-owned canonical representation used by persisted revision IDs.
String noveliaContentChecksum(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

final _sha256RevisionPattern = RegExp(r'^[0-9a-f]{64}$');

bool isNoveliaSha256Revision(String? revision) {
  return revision != null && _sha256RevisionPattern.hasMatch(revision);
}
