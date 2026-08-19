import 'package:cubechat/features/chat/data/photo_albums.dart';
import 'package:cubechat/features/chat/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime(2026, 8, 11, 23, 30);

  Message photo(
    String id, {
    int second = 0,
    bool isMine = true,
    bool viewOnce = false,
    String? caption,
    String? authorId,
    String? albumId,
  }) =>
      Message(
        id: id,
        chatId: 'peer',
        text: caption ?? 'image/jpeg',
        sentAt: start.add(Duration(seconds: second)),
        isMine: isMine,
        kind: MessageKind.image,
        imagePath: '/tmp/$id.jpg',
        viewOnce: viewOnce,
        authorId: authorId,
        albumId: albumId,
      );

  Message words(String id, {int second = 0, bool isMine = true}) => Message(
        id: id,
        chatId: 'peer',
        text: 'hey',
        sentAt: start.add(Duration(seconds: second)),
        isMine: isMine,
      );

  test('a batch becomes one album, anchored on its first photo', () {
    final albums = groupPhotoAlbums([
      photo('a', second: 0),
      photo('b', second: 1),
      photo('c', second: 2),
    ]);

    expect(albums.albumAt('a')?.map((m) => m.id), ['a', 'b', 'c']);
    expect(albums.isFolded('a'), isFalse);
    expect(albums.isFolded('b'), isTrue);
    expect(albums.isFolded('c'), isTrue);
  });

  test('a tenth photo opens a second album', () {
    final albums = groupPhotoAlbums([
      for (var i = 0; i < 11; i++) photo('p$i', second: i),
    ]);

    expect(albums.albumAt('p0')?.length, kMaxAlbumPhotos);
    // The leftovers group among themselves rather than hiding behind a "+2".
    expect(albums.albumAt('p9')?.map((m) => m.id), ['p9', 'p10']);
  });

  test('a word between two photos means they were about different things', () {
    final albums = groupPhotoAlbums([
      photo('a', second: 0),
      words('t', second: 1),
      photo('b', second: 2),
    ]);

    expect(albums.isEmpty, isTrue);
  });

  test('a long pause ends the batch', () {
    final albums = groupPhotoAlbums([
      photo('a', second: 0),
      photo('b', second: 1),
      photo('c', second: 1 + kAlbumWindow.inSeconds + 1),
      photo('d', second: 2 + kAlbumWindow.inSeconds + 1),
    ]);

    expect(albums.albumAt('a')?.map((m) => m.id), ['a', 'b']);
    expect(albums.albumAt('c')?.map((m) => m.id), ['c', 'd']);
  });

  // The reported bug, 2026-08-17: five photos each way at the same time, and
  // one phone drew a tidy grid while the other drew a column of singles. Our
  // own batch mints every bubble before a byte is sent, so it is always
  // adjacent; the incoming five are stamped as each last chunk lands, with our
  // own sitting in the middle of them.
  test('two batches at once interleave without shredding each other', () {
    final albums = groupPhotoAlbums([
      photo('them1', second: 0, isMine: false),
      photo('them2', second: 2, isMine: false),
      photo('mine1', second: 3),
      photo('mine2', second: 3),
      photo('mine3', second: 3),
      photo('them3', second: 5, isMine: false),
      photo('them4', second: 8, isMine: false),
    ]);

    expect(
      albums.albumAt('them1')?.map((m) => m.id),
      ['them1', 'them2', 'them3', 'them4'],
    );
    expect(
      albums.albumAt('mine1')?.map((m) => m.id),
      ['mine1', 'mine2', 'mine3'],
    );
    // Each album still hangs at its own first photo, so the two batches keep
    // their order relative to each other.
    expect(albums.isFolded('them1'), isFalse);
    expect(albums.isFolded('mine1'), isFalse);
    expect(albums.isFolded('them3'), isTrue);
  });

  test('a word between two photos breaks both runs, not just the speaker\'s',
      () {
    final albums = groupPhotoAlbums([
      photo('them1', second: 0, isMine: false),
      photo('mine1', second: 1),
      words('said', second: 2),
      photo('them2', second: 3, isMine: false),
      photo('mine2', second: 4),
    ]);

    // One photo each side of the sentence, so nothing is an album at all.
    expect(albums.isEmpty, isTrue);
  });

  test('interleaved channel authors each keep their own album', () {
    final albums = groupPhotoAlbums([
      photo('a1', second: 0, isMine: false, authorId: 'anna'),
      photo('b1', second: 1, isMine: false, authorId: 'boris'),
      photo('a2', second: 2, isMine: false, authorId: 'anna'),
      photo('b2', second: 3, isMine: false, authorId: 'boris'),
    ]);

    expect(albums.albumAt('a1')?.map((m) => m.id), ['a1', 'a2']);
    expect(albums.albumAt('b1')?.map((m) => m.id), ['b1', 'b2']);
  });

  // Reported 2026-08-18: five photos, then five more, came out as a grid of
  // nine — the grid's own ceiling — with a tenth underneath. Both batches were
  // inside the gap window, which is all the old rule looked at.
  test('two batches from one sender stay two albums', () {
    final albums = groupPhotoAlbums([
      for (var i = 0; i < 5; i++) photo('first$i', second: i, albumId: 'A'),
      for (var i = 0; i < 5; i++) photo('second$i', second: 60 + i, albumId: 'B'),
    ]);

    expect(albums.albumAt('first0'), hasLength(5));
    expect(albums.albumAt('second0'), hasLength(5));
    expect(albums.isFolded('second0'), isFalse);
  });

  // Reported 2026-08-19, from the receiving phone: five photos, a sentence,
  // five more — and all ten came out as one grid. Nothing carries a batch id
  // over the wire, and the sentence cannot separate them either: it is tiny and
  // arrives while the photos are still transferring, so it is stamped *before*
  // them and never lands between the two runs. Only the pace tells them apart.
  test('a second batch does not glue itself onto the first', () {
    final albums = groupPhotoAlbums([
      // One batch, arriving about a second apart the way a relay delivers.
      for (var i = 0; i < 5; i++) photo('first$i', second: i, isMine: false),
      // The next lot, after the sender did something else.
      for (var i = 0; i < 5; i++)
        photo('second$i', second: 120 + i, isMine: false),
    ]);

    expect(albums.albumAt('first0'), hasLength(5));
    expect(albums.albumAt('second0'), hasLength(5));
    expect(albums.isFolded('second0'), isFalse);
  });

  test('a slow batch is still one batch', () {
    // Over Bluetooth a photo can take a minute, and an even minute-apart run is
    // one send — the adaptive limit has to scale with the link, not fight it.
    final albums = groupPhotoAlbums([
      for (var i = 0; i < 4; i++)
        photo('slow$i', second: i * 60, isMine: false),
    ]);

    expect(albums.albumAt('slow0'), hasLength(4));
  });

  test('a photo with a batch id never joins one without', () {
    // A single photo sent on its own carries no id, and must not be swallowed
    // by the batch that happens to sit next to it.
    final albums = groupPhotoAlbums([
      photo('batch0', second: 0, albumId: 'A'),
      photo('batch1', second: 1, albumId: 'A'),
      photo('lone', second: 2),
    ]);

    expect(albums.albumAt('batch0')?.map((m) => m.id), ['batch0', 'batch1']);
    expect(albums.isFolded('lone'), isFalse);
  });

  test('two people posting at once are not one album', () {
    final albums = groupPhotoAlbums([
      photo('mine', second: 0),
      photo('theirs', second: 1, isMine: false),
    ]);

    expect(albums.isEmpty, isTrue);
  });

  test('a channel keeps its authors apart', () {
    final albums = groupPhotoAlbums([
      photo('a', second: 0, isMine: false, authorId: 'ann'),
      photo('b', second: 1, isMine: false, authorId: 'bob'),
    ]);

    expect(albums.isEmpty, isTrue);
  });

  test('a view-once photo never joins a grid', () {
    // It is deliberately never drawn as a thumbnail; a cell of one in a grid of
    // ordinary pictures would be exactly the thumbnail it must not be.
    final albums = groupPhotoAlbums([
      photo('a', second: 0),
      photo('secret', second: 1, viewOnce: true),
      photo('b', second: 2),
    ]);

    expect(albums.isEmpty, isTrue);
  });
  test('a sticker never joins a photo grid', () {
    final albums = groupPhotoAlbums([
      photo('a', second: 0),
      photo('sticker', second: 1, caption: Message.stickerMarkerFor('😂')),
      photo('b', second: 2),
    ]);

    expect(albums.isEmpty, isTrue);
  });

  test('a lone photo is left alone', () {
    expect(groupPhotoAlbums([photo('a')]).isEmpty, isTrue);
    expect(groupPhotoAlbums(const []).isEmpty, isTrue);
  });
}
