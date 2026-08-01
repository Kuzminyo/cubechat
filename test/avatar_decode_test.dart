import 'dart:typed_data';

import 'package:cubechat/core/identity/avatar_controller.dart';
import 'package:cubechat/core/widgets/identity_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Uint8List _jpeg(int side) {
  final im = img.Image(width: side, height: side);
  img.fill(im, color: img.ColorRgb8(20, 200, 120));
  return Uint8List.fromList(img.encodeJpg(im, quality: 80));
}

/// Every ResizeImage the tree is currently asking the cache for.
List<ResizeImage> _resizeRequests(WidgetTester tester) {
  final out = <ResizeImage>[];
  for (final element in find.byType(Container).evaluate()) {
    final decoration = (element.widget as Container).decoration;
    final image = decoration is BoxDecoration ? decoration.image?.image : null;
    if (image is ResizeImage) out.add(image);
  }
  return out;
}

Future<void> _pump(WidgetTester tester, double size, double dpr) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(devicePixelRatio: dpr),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: IdentityAvatar(
            seed: 'seed',
            label: 'K',
            size: size,
            imageBytes: _jpeg(64),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a small circle never decodes the full-size avatar',
      (tester) async {
    // The stored avatar is full HD so the profile cover stays sharp. Handing
    // those bytes to a 44px row avatar unscaled would put 1920*1920*4 bytes —
    // about 15 MB — into the image cache, and a list pays it per distinct size.
    await _pump(tester, 44, 3);

    final requests = _resizeRequests(tester);
    expect(requests, hasLength(1));
    expect(requests.single.width, isNotNull);
    expect(
      requests.single.width!,
      lessThan(AvatarController.storedSize),
      reason: 'a 44pt circle must not decode at the stored size',
    );
  });

  testWidgets('decode sizes land on shared buckets, not one per call site',
      (tester) async {
    // The cache keys on the decode size, so 44pt and 48pt asking for slightly
    // different pixel counts would each hold their own full copy of the photo.
    await _pump(tester, 44, 3);
    final at44 = _resizeRequests(tester).single.width;

    await _pump(tester, 48, 3);
    final at48 = _resizeRequests(tester).single.width;

    expect(at44, at48, reason: 'nearby sizes should share one cache entry');
  });

  testWidgets('a large circle is allowed a larger decode', (tester) async {
    // The other half of the bargain: bucketing must not cap the cover at a
    // thumbnail, or full HD would have bought nothing.
    await _pump(tester, 44, 3);
    final small = _resizeRequests(tester).single.width!;

    await _pump(tester, 400, 3);
    final large = _resizeRequests(tester).single.width!;

    expect(large, greaterThan(small));
    expect(large, lessThanOrEqualTo(AvatarController.storedSize));
  });

  testWidgets('the generated gradient asks the cache for nothing',
      (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: IdentityAvatar(seed: 'seed', label: 'K')),
      ),
    );
    expect(_resizeRequests(tester), isEmpty);
  });
}
