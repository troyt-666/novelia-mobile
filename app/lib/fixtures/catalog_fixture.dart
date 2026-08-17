import '../core/model/reader_models.dart';
import '../features/discover/catalog_models.dart';
import 'reader_fixture.dart';

AlignedBlock _fixtureBlock({
  required String novelId,
  required String chapterId,
  required int ordinal,
  required String chinese,
  required String japanese,
}) {
  return AlignedBlock(
    id: '$novelId-$chapterId-$ordinal',
    ordinal: ordinal,
    japanese: japanese,
    translations: {
      TranslationSource.youdao: chinese,
      TranslationSource.gpt: chinese,
      TranslationSource.sakura: chinese,
    },
  );
}

ReaderNovel _shortReaderNovel({
  required String id,
  required String chineseTitle,
  required String japaneseTitle,
  required String author,
  required List<(String, String)> chapterTitles,
}) {
  return ReaderNovel(
    id: id,
    chineseTitle: chineseTitle,
    japaneseTitle: japaneseTitle,
    author: author,
    chapters: [
      for (var index = 0; index < chapterTitles.length; index++)
        NovelChapter(
          id: '$id-chapter-${index + 1}',
          index: index + 1,
          chineseTitle: chapterTitles[index].$1,
          japaneseTitle: chapterTitles[index].$2,
          publishedAt: DateTime(2026, 6, 2 + index * 5),
          blocks: [
            _fixtureBlock(
              novelId: id,
              chapterId: 'chapter-${index + 1}',
              ordinal: 0,
              chinese: '风从城市尽头吹来，将少年手中的地图翻到了下一页。',
              japanese: '街の果てから風が吹き、少年の手の中の地図を次のページへめくった。',
            ),
            _fixtureBlock(
              novelId: id,
              chapterId: 'chapter-${index + 1}',
              ordinal: 1,
              chinese: '他终于看见了那行只在夜里出现的文字。',
              japanese: '彼はようやく、夜にしか現れないその文字を見つけた。',
            ),
          ],
        ),
    ],
  );
}

List<CatalogChapterSection> _singleSection(ReaderNovel novel, String title) {
  return [
    CatalogChapterSection(
      title: title,
      chapterIds: [for (final chapter in novel.chapters) chapter.id],
    ),
  ];
}

final _sharedComments = [
  NovelComment(
    id: 'comment-1',
    author: '山雀',
    body: '前三章的节奏很稳，世界观是通过对话慢慢放出来的。',
    createdAt: DateTime(2026, 7, 18, 21, 40),
    replies: [
      NovelCommentReply(
        id: 'reply-1',
        author: '海盐汽水',
        body: '同感，第二卷会开始回收前面的线索。',
        createdAt: DateTime(2026, 7, 19, 9, 12),
      ),
    ],
  ),
  NovelComment(
    id: 'comment-2',
    author: '远灯',
    body: '机翻的人名偶尔会飘，建议对照日文看，其他部分很流畅。',
    createdAt: DateTime(2026, 7, 16, 12, 5),
  ),
  NovelComment(
    id: 'comment-3',
    author: '旧纸张',
    body: '慢热，但角色关系写得很细，不是爽文路线。',
    createdAt: DateTime(2026, 7, 12, 8, 22),
    replies: [
      NovelCommentReply(
        id: 'reply-2',
        author: '十七',
        body: '第八章之后主线会比较明确。',
        createdAt: DateTime(2026, 7, 12, 13, 47),
      ),
      NovelCommentReply(
        id: 'reply-3',
        author: '旧纸张',
        body: '读到了，确实开始好看了。',
        createdAt: DateTime(2026, 7, 13, 18, 3),
      ),
    ],
  ),
  NovelComment(
    id: 'comment-4',
    author: '清晨四点',
    body: '已追到最新章，目前没有明显的烂尾迹象。',
    createdAt: DateTime(2026, 7, 8, 4, 10),
  ),
  NovelComment(
    id: 'comment-5',
    author: '翠雨',
    body: '喜欢冒险和日常交替的可以试试，感情线很淡。',
    createdAt: DateTime(2026, 6, 30, 19, 32),
  ),
];

final _clockworkNovel = _shortReaderNovel(
  id: 'fixture-clockwork-library',
  chineseTitle: '齿轮图书馆的守夜人',
  japaneseTitle: '歯車図書館の宿直人',
  author: '九条真帆',
  chapterTitles: const [
    ('不会停的时钟', '止まらない時計'),
    ('深夜的还书口', '真夜中の返却口'),
    ('被删去的目录', '消された目録'),
  ],
);

final _gardenNovel = _shortReaderNovel(
  id: 'fixture-sky-garden',
  chineseTitle: '云上庭园的邮差',
  japaneseTitle: '雲上庭園の郵便屋',
  author: '朝仓森',
  chapterTitles: const [('寄往晴天的信', '晴れの日への手紙'), ('第十三号浮岛', '十三番目の浮島')],
);

final _alchemistNovel = _shortReaderNovel(
  id: 'fixture-rain-alchemist',
  chineseTitle: '雨声炼金术师',
  japaneseTitle: '雨音の錬金術師',
  author: '藤堂玲',
  chapterTitles: const [('银色的雨', '銀色の雨')],
);

final _summerNovel = _shortReaderNovel(
  id: 'fixture-summer-loop',
  chineseTitle: '夏日循环与最后一支冰棒',
  japaneseTitle: '夏のループと最後のアイス',
  author: '小川结',
  chapterTitles: const [('八月三十二日', '8月32日'), ('没有融化的冰', '溶けない氷')],
);

final List<CatalogNovel> fixtureCatalogNovels = [
  CatalogNovel(
    id: fixtureNovel.id,
    chineseTitle: fixtureNovel.chineseTitle,
    japaneseTitle: fixtureNovel.japaneseTitle,
    author: fixtureNovel.author,
    source: 'Kakuyomu',
    publicationState: NovelPublicationState.ongoing,
    wordCount: 128400,
    updatedAt: DateTime(2026, 8, 16, 22, 10),
    tags: const ['幻想', '铁路', '少女', '悬疑'],
    synopsis: '一张不存在于时刻表的车票，将澄带上了通往星港的夜行列车。每一站都收藏着一段被乘客遗忘的记忆。',
    points: 18420,
    views: 287000,
    translationCoverage: const [
      TranslationCoverage(
        source: '有道',
        translatedChapters: 4,
        totalChapters: 4,
      ),
      TranslationCoverage(
        source: 'GPT',
        translatedChapters: 4,
        totalChapters: 4,
      ),
      TranslationCoverage(
        source: 'Sakura',
        translatedChapters: 3,
        totalChapters: 4,
      ),
    ],
    readerNovel: fixtureNovel,
    chapterSections: [
      CatalogChapterSection(
        title: '第一部　离站',
        chapterIds: const ['chapter-1', 'chapter-2'],
      ),
      CatalogChapterSection(
        title: '第二部　星港',
        chapterIds: const ['chapter-3', 'chapter-4'],
      ),
    ],
    comments: _sharedComments,
    originalUrl: Uri.parse('https://example.invalid/fixture-night-train'),
  ),
  CatalogNovel(
    id: _clockworkNovel.id,
    chineseTitle: _clockworkNovel.chineseTitle,
    japaneseTitle: _clockworkNovel.japaneseTitle,
    author: _clockworkNovel.author,
    source: 'Syosetu',
    publicationState: NovelPublicationState.completed,
    wordCount: 312000,
    updatedAt: DateTime(2026, 8, 15, 9, 30),
    tags: const ['奇幻', '推理', '完结'],
    synopsis: '只在凌晨开门的图书馆里，守夜人负责修复被时间删去的书页。',
    points: 42100,
    views: 814000,
    translationCoverage: const [
      TranslationCoverage(
        source: '有道',
        translatedChapters: 3,
        totalChapters: 3,
      ),
      TranslationCoverage(
        source: 'GPT',
        translatedChapters: 3,
        totalChapters: 3,
      ),
      TranslationCoverage(
        source: 'Sakura',
        translatedChapters: 3,
        totalChapters: 3,
      ),
    ],
    readerNovel: _clockworkNovel,
    chapterSections: _singleSection(_clockworkNovel, '齿轮图书馆'),
    comments: _sharedComments.take(3).toList(),
  ),
  CatalogNovel(
    id: _gardenNovel.id,
    chineseTitle: _gardenNovel.chineseTitle,
    japaneseTitle: _gardenNovel.japaneseTitle,
    author: _gardenNovel.author,
    source: 'Novelup',
    publicationState: NovelPublicationState.ongoing,
    wordCount: 94600,
    updatedAt: DateTime(2026, 8, 17, 6, 15),
    tags: const ['治愈', '旅行', '日常'],
    synopsis: '新人邮差驾着小飞艇，在浮岛之间送出那些无法到达地面的信。',
    points: 12600,
    views: 163000,
    translationCoverage: const [
      TranslationCoverage(
        source: '有道',
        translatedChapters: 2,
        totalChapters: 2,
      ),
      TranslationCoverage(
        source: 'GPT',
        translatedChapters: 2,
        totalChapters: 2,
      ),
      TranslationCoverage(
        source: 'Sakura',
        translatedChapters: 1,
        totalChapters: 2,
      ),
    ],
    readerNovel: _gardenNovel,
    chapterSections: _singleSection(_gardenNovel, '第一卷'),
    comments: _sharedComments.skip(1).take(4).toList(),
  ),
  CatalogNovel(
    id: _alchemistNovel.id,
    chineseTitle: _alchemistNovel.chineseTitle,
    japaneseTitle: _alchemistNovel.japaneseTitle,
    author: _alchemistNovel.author,
    source: 'Hameln',
    publicationState: NovelPublicationState.shortStory,
    wordCount: 18400,
    updatedAt: DateTime(2026, 8, 12, 17, 45),
    tags: const ['短篇', '炼金术', '雨'],
    synopsis: '一场永远不会停的雨，与一位尝试从雨声中炼出星光的学徒。',
    points: 8700,
    views: 97000,
    translationCoverage: const [
      TranslationCoverage(
        source: '有道',
        translatedChapters: 1,
        totalChapters: 1,
      ),
      TranslationCoverage(
        source: 'GPT',
        translatedChapters: 1,
        totalChapters: 1,
      ),
      TranslationCoverage(
        source: 'Sakura',
        translatedChapters: 1,
        totalChapters: 1,
      ),
    ],
    readerNovel: _alchemistNovel,
    chapterSections: _singleSection(_alchemistNovel, '全一篇'),
    comments: _sharedComments.take(2).toList(),
  ),
  CatalogNovel(
    id: _summerNovel.id,
    chineseTitle: _summerNovel.chineseTitle,
    japaneseTitle: _summerNovel.japaneseTitle,
    author: _summerNovel.author,
    source: 'Kakuyomu',
    publicationState: NovelPublicationState.completed,
    wordCount: 76400,
    updatedAt: DateTime(2026, 8, 10, 11, 20),
    tags: const ['青春', '时间循环', '夏天'],
    synopsis: '暑假的最后一天反复到来，只有便利店冰柜里的最后一支冰棒正在一点点融化。',
    points: 22300,
    views: 354000,
    translationCoverage: const [
      TranslationCoverage(
        source: '有道',
        translatedChapters: 2,
        totalChapters: 2,
      ),
      TranslationCoverage(
        source: 'GPT',
        translatedChapters: 2,
        totalChapters: 2,
      ),
      TranslationCoverage(
        source: 'Sakura',
        translatedChapters: 2,
        totalChapters: 2,
      ),
    ],
    readerNovel: _summerNovel,
    chapterSections: _singleSection(_summerNovel, '全章'),
    comments: _sharedComments.skip(2).toList(),
  ),
];
