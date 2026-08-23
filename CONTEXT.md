# Novelia Reader

This context describes a focused bilingual reading product for Novelia-compatible content. Community features such as forums are outside this context.

## Language

**Bilingual Reader**:
A leisure-reading experience in which a Chinese Translation is primary and its Japanese Original remains readily available for verification. It remains usable offline.
_Avoid_: Novelia client, forum client, general-purpose reader

**Novelia-compatible Content**:
A work whose reading structure provides Japanese original text with one or more associated Chinese translations in a form the Bilingual Reader supports.
_Avoid_: Novelia-owned content, scraped content

**Chinese Translation**:
The primary Chinese reading text derived from a Japanese Original.
_Avoid_: Chinese original, secondary text, sub text

**Japanese Original**:
The source-language text associated with a Chinese Translation and consulted when the translation appears unreliable.
_Avoid_: main text, primary text, translation source

**Aligned Block**:
A semantic reading unit anchored by one Japanese Original and an optional Chinese Translation from each Translation Source. When both are shown, the Chinese Translation appears first and the Japanese Original underneath.
_Avoid_: reading pair, rendered-line pair, paragraph pair

**Reading Mode**:
The chosen language visibility for Aligned Blocks: Chinese-only or Chinese followed by Japanese.
_Avoid_: translation mode, language order

**Translation Source**:
The named producer or version of a Chinese Translation, such as Youdao, GPT, or Sakura.
_Avoid_: source, content source, API source

**Cache Copy**:
An automatically retained offline copy that is expendable and may be evicted.
_Avoid_: download, saved book

**Offline Download**:
A reader-requested, protected offline copy containing the Japanese Original and the selected Translation Source, retained until deliberately removed. Complete chapters are snapshots of the revision stored at download or at the last Translation Pending refresh; they are not revalidated while the intent remains. A single-chapter Offline Download remains fixed to that chapter; a Novel Download also acquires future chapters and rechecks Translation Pending chapters. Downloaded content survives removal of its source content from the service.
_Avoid_: cache, saved book

**Novel Download**:
An ongoing Offline Download intent for a whole Web Novel. While enabled, newly published chapters are queued automatically with their Japanese Original and the novel's selected Translation Source.
_Avoid_: one-time novel snapshot, Cache Copy, chapter download

**Web Novel**:
A chapter-based Novelia-compatible work whose content is read as Aligned Blocks.
_Avoid_: Wenku work, EPUB, book

**Wenku Novel**:
A volume-based Novelia-compatible work whose readable editions are provided as Wenku EPUBs rather than chapter content.
_Avoid_: Web Novel, local book, EPUB file

**Wenku EPUB**:
A downloadable EPUB edition of one Wenku Novel volume that contains its Japanese Original and a selected Chinese Translation for bilingual reading.
_Avoid_: Web Novel EPUB, chapter download, source EPUB

**Reader Account**:
The Novelia identity whose Favorites and Reading History synchronize across reader installations.
_Avoid_: local profile, device account

**Favorite**:
A service-confirmed, account-scoped membership that places a Web Novel in a Favorite Folder.
_Avoid_: bookmark, download, saved book

**Favorite Folder**:
An account-scoped collection required to organize Favorites.
_Avoid_: library, download folder, cache folder

**Novel Comment**:
A service-hosted reader remark attached to a Web Novel and used as context when deciding whether to start or continue it. A Novel Comment may have replies, but it is not a Forum Post or an annotation on the text.
_Avoid_: review, Forum Post, bookmark note, chapter annotation

**Comment Page**:
One bounded, service-ordered page of read-only top-level Novel Comments shown beneath a Web Novel's chapter catalog, with all replies on that page expanded. Readers move between pages explicitly rather than extending an endless comment feed.
_Avoid_: forum page, reader page, infinite comments

**Novel Details**:
The decision screen for a Web Novel: Chinese and Japanese titles, author, publication state, length, last update, tags, synopsis, translation coverage, source points or views, source navigation, chapter catalog, and paginated Novel Comments.
_Avoid_: reader, catalog card, workspace

**Discover**:
The top-level browsing destination containing Continue Reading, Most Clicked, Recently Updated, search and filtered catalog access, and a secondary Rankings destination.
_Avoid_: Library, home page, forum feed

**Discovery List**:
A continuously loading mobile list of catalog or Ranking results that preserves its filters, loaded position, and retry state across navigation. It is distinct from explicitly paginated Comment Pages.
_Avoid_: Comment Page, reader stream, numbered catalog page

**Reading History**:
The account-scoped record of the most recent reading activity and position for a Web Novel. Newer activity supersedes older history, even when it is earlier in the novel.
_Avoid_: farthest progress, bookmark

**Continuous Reading Stream**:
The ordered sequence of Aligned Blocks that flows across adjacent chapter boundaries without page transitions.
_Avoid_: infinite scroll, chapter pagination, endless feed

**Reader Chrome**:
The transient top and bottom controls for leaving the reader, identifying or selecting a chapter, changing Reading Mode or Translation Source, opening settings, and creating a Bookmark. An otherwise unhandled tap in the central reading area toggles it without changing Reading Position.
_Avoid_: navigation page, permanent toolbar, center button

**Reading Position**:
A restorable location identified by chapter, Aligned Block, and a location within that block.
_Avoid_: pixel offset, scroll offset, page number

**Bookmark**:
A device-local saved Reading Position with no highlight, annotation, or account synchronization.
_Avoid_: Favorite, Reading History, note

**Library**:
The reader-facing collection of Continue Reading positions, Favorite Folders, Offline Downloads, Bookmarks, and Reading History.
_Avoid_: Favorite Folder, catalog, cache

**Chapter Revision**:
The coherent observed state of a chapter's Japanese Original and available Chinese Translations. A newly available translation creates a new revision even when the original is unchanged.
_Avoid_: cached chapter, file version

**Translation Pending**:
A temporary chapter state in which the Japanese Original is available but the selected Chinese Translation has not been generated yet.
_Avoid_: untranslated chapter, failed translation, permanently unavailable

**Availability Boundary**:
The end of the currently readable Continuous Reading Stream, reached at the latest published chapter or when the next chapter is unavailable locally while offline.
_Avoid_: end of novel, load failure, pagination boundary
