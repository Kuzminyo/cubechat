import 'dart:io';
import 'dart:typed_data';

import 'package:cubechat/core/transport/inner_payload.dart';
import 'package:cubechat/core/transport/mtu_budget.dart';
import 'package:cubechat/core/util/image_encode.dart';
import 'package:cubechat/features/profile/data/media_quality_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:image/image.dart' as img;

import 'support/hive_settle.dart';

/// A 2400x1600 picture with detail in it, standing in for a camera photo.
///
/// Detail, not size, is what makes a JPEG heavy, so a flat fill would pass
/// every budget at the first rung and prove nothing about the ladder. This
/// has texture everywhere, the way leaves or a crowd do.
Uint8List _detailedPhoto() {
  final photo = img.Image(width: 2400, height: 1600);
  for (var y = 0; y < photo.height; y++) {
    for (var x = 0; x < photo.width; x++) {
      photo.setPixelRgb(
        x,
        y,
        (x * 7 ^ y * 13) & 0xFF,
        (x * 3 + y * 5) & 0xFF,
        (x ^ y) & 0xFF,
      );
    }
  }
  return Uint8List.fromList(img.encodeJpg(photo, quality: 95));
}

/// The bad-connection mode's "choose the media quality": three budgets for an
/// outgoing photo, picked by the sender.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the encoder', () {
    late Uint8List source;
    setUpAll(() => source = _detailedPhoto());

    for (final quality in MediaQuality.values) {
      test('${quality.name} stays inside its own budget', () async {
        final wire = await encodeBytesForMesh(source, quality: quality);
        expect(wire, isNotNull);
        expect(wire!.length, lessThanOrEqualTo(quality.maxBytes));
        final decoded = img.decodeJpg(wire)!;
        expect(decoded.width, lessThanOrEqualTo(quality.largestSide));
      });
    }

    test('each step up sends a larger picture', () async {
      final widths = <MediaQuality, int>{};
      for (final quality in MediaQuality.values) {
        final wire = await encodeBytesForMesh(source, quality: quality);
        widths[quality] = img.decodeJpg(wire!)!.width;
      }
      expect(
        widths[MediaQuality.economy],
        lessThan(widths[MediaQuality.standard]!),
      );
      expect(
        widths[MediaQuality.standard],
        lessThan(widths[MediaQuality.high]!),
      );
    });

    test('with no choice made, a photo is sent exactly as before', () async {
      // Standard is the budget every earlier build used; a caller that never
      // heard of the setting must still get it.
      expect(MediaQuality.standard.maxBytes, kMaxOutgoingImageBytes);
      final plain = await encodeBytesForMesh(source);
      final standard =
          await encodeBytesForMesh(source, quality: MediaQuality.standard);
      expect(plain, standard);
    });
  });

  test('every ladder starts at its largest side and only goes down', () {
    for (final quality in MediaQuality.values) {
      final sizes = quality.rungs.map((r) => r.size).toList();
      expect(sizes.first, quality.largestSide, reason: quality.name);
      for (var i = 1; i < sizes.length; i++) {
        expect(sizes[i], lessThan(sizes[i - 1]), reason: quality.name);
      }
    }
  });

  test('a high-quality photo still fits the chunk count on the worst link', () {
    // The narrowest link bleMediaChunkData can be handed is 20 bytes of
    // effective payload; past 8192 chunks the transfer cannot be encoded at
    // all, so this is the ceiling that decides how high "high" may go.
    final perChunk = bleMediaChunkData(20, ceiling: ImageChunk.maxDataBytes);
    final chunks = (MediaQuality.high.maxBytes / perChunk).ceil();
    expect(chunks, lessThanOrEqualTo(ImageChunk.maxChunks));
  });

  group('the setting', () {
    late Directory tempDir;
    late ProviderContainer container;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('cubechat_quality_');
      Hive.init(tempDir.path);
      container = ProviderContainer();
    });

    tearDown(() async {
      await settleBackgroundStorage();
      container.dispose();
      await Hive.close();
      try {
        if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows can retain a Hive handle briefly after close.
      }
    });

    test('is standard until somebody changes it', () async {
      final quality = container.read(mediaQualityProvider.notifier);
      expect(await quality.resolved(), MediaQuality.standard);
    });

    test('survives a restart', () async {
      final quality = container.read(mediaQualityProvider.notifier);
      await quality.loaded;
      await quality.set(MediaQuality.economy);
      await settleBackgroundStorage();

      final next = ProviderContainer();
      addTearDown(next.dispose);
      expect(
        await next.read(mediaQualityProvider.notifier).resolved(),
        MediaQuality.economy,
      );
    });

    test('a choice made while the box is still opening is kept', () async {
      // Set without waiting for the load: the box is not open yet, and the
      // load that finishes afterwards must not put the default back.
      final quality = container.read(mediaQualityProvider.notifier);
      await quality.set(MediaQuality.high);
      expect(container.read(mediaQualityProvider), MediaQuality.high);
      await settleBackgroundStorage();

      final next = ProviderContainer();
      addTearDown(next.dispose);
      expect(
        await next.read(mediaQualityProvider.notifier).resolved(),
        MediaQuality.high,
      );
    });

    test('a wipe puts it back to a fresh install', () async {
      final quality = container.read(mediaQualityProvider.notifier);
      await quality.set(MediaQuality.high);
      await quality.reset();
      expect(container.read(mediaQualityProvider), MediaQuality.standard);
      await settleBackgroundStorage();

      final next = ProviderContainer();
      addTearDown(next.dispose);
      expect(
        await next.read(mediaQualityProvider.notifier).resolved(),
        MediaQuality.standard,
      );
    });
  });
}
