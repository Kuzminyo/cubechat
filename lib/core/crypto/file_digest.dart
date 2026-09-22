import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// SHA-256 of the file at [path], computed on an isolate of its own.
///
/// A file transfer commits to its contents in the signed manifest, so the
/// sender hashes the whole file before the first chunk and the receiver hashes
/// it again after the last. The hash is pure Dart, and on the UI isolate it
/// was the single longest block of work in the 1105 log of a 115 MB video:
/// `file-hash 1× 1318 ms`, streamed in 64 KiB pieces between reads, so the
/// screen got a frame in edgeways for over a second before anything had been
/// sent. Here it reads and hashes where no frame is waiting on it.
///
/// Streamed as before, so the cost in memory is one read buffer, not the file.
Future<Uint8List> sha256OfFile(String path) => Isolate.run(
      () async {
        final sink = Sha256().newHashSink();
        await for (final part in File(path).openRead()) {
          sink.add(part);
        }
        sink.close();
        return Uint8List.fromList((await sink.hash()).bytes);
      },
      debugName: 'file-hash',
    );
