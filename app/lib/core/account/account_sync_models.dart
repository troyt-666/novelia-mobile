class RemoteFavoriteFolder {
  const RemoteFavoriteFolder({required this.id, required this.title});

  final String id;
  final String title;
}

class RemoteHistoryOutboxEntry {
  RemoteHistoryOutboxEntry({
    required this.novelId,
    required this.providerId,
    required this.serviceNovelId,
    required this.chapterId,
    required this.occurredAt,
  }) {
    if (novelId.isEmpty ||
        providerId.isEmpty ||
        serviceNovelId.isEmpty ||
        chapterId.isEmpty) {
      throw ArgumentError('Remote history identifiers must be non-empty.');
    }
  }

  final String novelId;
  final String providerId;
  final String serviceNovelId;
  final String chapterId;
  final DateTime occurredAt;
}
