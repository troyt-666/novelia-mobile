import '../core/model/reader_models.dart';

const _allSources = [
  TranslationSource.youdao,
  TranslationSource.gpt,
  TranslationSource.sakura,
];

AlignedBlock _block({
  required String chapter,
  required int ordinal,
  required String chinese,
  required String japanese,
  AlignedBlockKind kind = AlignedBlockKind.paragraph,
  bool sakuraPending = false,
}) {
  return AlignedBlock(
    id: '$chapter-$ordinal',
    ordinal: ordinal,
    japanese: japanese,
    kind: kind,
    translations: {
      for (final source in _allSources)
        if (!(sakuraPending && source == TranslationSource.sakura))
          source: switch (source) {
            TranslationSource.youdao => chinese,
            TranslationSource.gpt => chinese,
            TranslationSource.sakura => chinese,
          },
    },
  );
}

final ReaderNovel fixtureNovel = ReaderNovel(
  id: 'fixture-night-train',
  chineseTitle: '驶向星港的夜行列车',
  japaneseTitle: '星港へ向かう夜行列車',
  author: '青井遥',
  chapters: [
    NovelChapter(
      id: 'chapter-1',
      index: 1,
      chineseTitle: '雨夜的站台',
      japaneseTitle: '雨のホーム',
      publishedAt: DateTime(2026, 4, 3),
      blocks: [
        _block(
          chapter: 'c1',
          ordinal: 0,
          chinese: '最后一班列车进站时，雨正沿着站台的玻璃顶棚向下流。',
          japanese: '最終列車が入ってきたとき、雨はホームのガラス屋根を伝って流れていた。',
        ),
        _block(
          chapter: 'c1',
          ordinal: 1,
          chinese: '澪把旅行箱拉到脚边，重新确认了票面上那行陌生的终点。',
          japanese: '澪は旅行鞄を足元に引き寄せ、切符に記された見知らぬ終点をもう一度確かめた。',
        ),
        _block(
          chapter: 'c1',
          ordinal: 2,
          chinese: '“星港——真的有这个地方吗？”',
          japanese: '「星港なんて、本当にあるのかな」',
          kind: AlignedBlockKind.dialogue,
        ),
        _block(
          chapter: 'c1',
          ordinal: 3,
          chinese: '没有人回答。车门却像听见了似的，在她面前安静地打开。',
          japanese: '答える者はいなかった。それでも扉は聞こえていたかのように、彼女の前で静かに開いた。',
        ),
        _block(
          chapter: 'c1',
          ordinal: 4,
          chinese: '车厢里只有暖黄色的灯和一位坐在最远处的少年。',
          japanese: '車内には暖かな黄色い灯りと、いちばん奥に座る少年だけがいた。',
        ),
        _block(
          chapter: 'c1',
          ordinal: 5,
          chinese: '列车启动后，城市的灯火很快被雨幕吞没。',
          japanese: '列車が動き出すと、街の灯はたちまち雨の幕に飲み込まれた。',
        ),
      ],
    ),
    NovelChapter(
      id: 'chapter-2',
      index: 2,
      chineseTitle: '没有时刻表的列车',
      japaneseTitle: '時刻表にない列車',
      publishedAt: DateTime(2026, 4, 10),
      blocks: [
        _block(
          chapter: 'c2',
          ordinal: 0,
          chinese: '检票员没有来，广播也始终保持沉默。',
          japanese: '車掌は来ず、車内放送もずっと沈黙したままだった。',
        ),
        _block(
          chapter: 'c2',
          ordinal: 1,
          chinese: '窗外不再是郊外，而是一片倒映着星光的黑色海面。',
          japanese: '窓の外はもう郊外ではなく、星明かりを映す黒い海だった。',
        ),
        _block(
          chapter: 'c2',
          ordinal: 2,
          chinese: '远处的少年终于起身，把一本没有封面的书递给澪。',
          japanese: '遠くにいた少年がようやく立ち上がり、表紙のない本を澪に差し出した。',
        ),
        _block(
          chapter: 'c2',
          ordinal: 3,
          chinese: '“到站之前，请替我保管它。”',
          japanese: '「着くまで、これを預かってください」',
          kind: AlignedBlockKind.dialogue,
        ),
        _block(
          chapter: 'c2',
          ordinal: 4,
          chinese: '书页上写着她今天没有说出口的每一句话。',
          japanese: 'ページには、彼女が今日口にできなかった言葉が一つ残らず書かれていた。',
        ),
        _block(
          chapter: 'c2',
          ordinal: 5,
          chinese: '澪合上书时，车轮的声音忽然变成了缓慢的心跳。',
          japanese: '澪が本を閉じると、車輪の音はゆっくりとした鼓動に変わった。',
        ),
      ],
    ),
    NovelChapter(
      id: 'chapter-3',
      index: 3,
      chineseTitle: '翻译尚未抵达',
      japaneseTitle: '翻訳はまだ届かない',
      publishedAt: DateTime(2026, 4, 17),
      blocks: [
        _block(
          chapter: 'c3',
          ordinal: 0,
          chinese: '黎明之前，列车在一座没有名字的小站停下。',
          japanese: '夜明け前、列車は名もない小さな駅に停まった。',
          sakuraPending: true,
        ),
        _block(
          chapter: 'c3',
          ordinal: 1,
          chinese: '月台上站着许多撑着透明雨伞的人。',
          japanese: 'ホームには透明な傘を差した人々が立っていた。',
          sakuraPending: true,
        ),
        _block(
          chapter: 'c3',
          ordinal: 2,
          chinese: '他们没有上车，只是目送车窗里的每一位旅客。',
          japanese: '彼らは乗り込まず、窓の中の乗客を一人ずつ見送っていた。',
          sakuraPending: true,
        ),
        _block(
          chapter: 'c3',
          ordinal: 3,
          chinese: '少年低声说，这里是忘记某件事的人才会看见的车站。',
          japanese: '少年は、ここは何かを忘れた人にだけ見える駅なのだと小声で言った。',
          sakuraPending: true,
        ),
        _block(
          chapter: 'c3',
          ordinal: 4,
          chinese: '澪望向手里的书，第一次不敢翻开下一页。',
          japanese: '澪は手の中の本を見つめ、初めて次のページを開くことを恐れた。',
          sakuraPending: true,
        ),
      ],
    ),
    NovelChapter(
      id: 'chapter-4',
      index: 4,
      chineseTitle: '星港',
      japaneseTitle: '星港',
      publishedAt: DateTime(2026, 4, 24),
      blocks: [
        _block(
          chapter: 'c4',
          ordinal: 0,
          chinese: '天空泛白时，海面上出现了一座由无数灯塔组成的城市。',
          japanese: '空が白み始めるころ、海の上に無数の灯台からできた街が現れた。',
        ),
        _block(
          chapter: 'c4',
          ordinal: 1,
          chinese: '每一束光都指向不同的远方，也照亮一段被遗忘的道路。',
          japanese: 'それぞれの光は違う遠方を指し、忘れられた道を一本ずつ照らしていた。',
        ),
        _block(
          chapter: 'c4',
          ordinal: 2,
          chinese: '“到了。”少年说，“接下来要去哪里，由你自己决定。”',
          japanese: '「着きました」と少年は言った。「ここからどこへ行くかは、あなたが決めることです」',
          kind: AlignedBlockKind.dialogue,
        ),
        _block(
          chapter: 'c4',
          ordinal: 3,
          chinese: '车门打开，带着盐味的风吹进车厢，书页在她掌心自行翻动。',
          japanese: '扉が開き、塩の匂いを含んだ風が車内へ吹き込み、本のページが掌の上でひとりでにめくれた。',
        ),
        _block(
          chapter: 'c4',
          ordinal: 4,
          chinese: '最后一页仍是空白。澪笑了，把自己的名字写在最上方。',
          japanese: '最後のページだけは白紙だった。澪は笑い、いちばん上に自分の名前を書いた。',
        ),
      ],
    ),
  ],
);
