import 'dart:convert';
import 'dart:typed_data';

/// No service credentials or absolute paths are part of a portable EPUB record.
class WenkuBackupEntry {
  WenkuBackupEntry({
    required this.fileName,
    required this.title,
    this.volumeId,
    this.order,
    this.spineIndex,
    this.fraction,
    this.bytes,
  }) {
    if (!RegExp(r'^[a-zA-Z0-9_-]+\.epub$').hasMatch(fileName) ||
        (order != null &&
            order != 'chineseFirst' &&
            order != 'japaneseFirst') ||
        (spineIndex == null) != (fraction == null) ||
        (spineIndex != null && spineIndex! < 0) ||
        (fraction != null &&
            (!fraction!.isFinite || fraction! < 0 || fraction! > 1))) {
      throw const FormatException('Invalid EPUB backup record.');
    }
  }
  final String fileName;
  final String title;
  final String? volumeId;
  final String? order;
  final int? spineIndex;
  final double? fraction;
  final Uint8List? bytes;

  Map<String, Object?> toJson() => {
    'fileName': fileName,
    'title': title,
    'volumeId': volumeId,
    'order': order,
    'spineIndex': spineIndex,
    'fraction': fraction,
    if (bytes != null) 'epub': base64Encode(bytes!),
  };

  static WenkuBackupEntry fromJson(Object? value) {
    final data = value as Map<String, dynamic>;
    if (data.keys.any(
      (key) => !const [
        'fileName',
        'title',
        'volumeId',
        'order',
        'spineIndex',
        'fraction',
        'epub',
      ].contains(key),
    )) {
      throw const FormatException('Unknown EPUB backup field.');
    }
    return WenkuBackupEntry(
      fileName: data['fileName'] as String,
      title: data['title'] as String,
      volumeId: data['volumeId'] as String?,
      order: data['order'] as String?,
      spineIndex: data['spineIndex'] as int?,
      fraction: (data['fraction'] as num?)?.toDouble(),
      bytes: data['epub'] == null ? null : base64Decode(data['epub'] as String),
    );
  }
}
