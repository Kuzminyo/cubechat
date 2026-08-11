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

  test('a lone photo is left alone', () {
    expect(groupPhotoAlbums([photo('a')]).isEmpty, isTrue);
    expect(groupPhotoAlbums(const []).isEmpty, isTrue);
  });
}
