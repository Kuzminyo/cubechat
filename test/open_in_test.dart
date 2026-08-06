import 'package:cubechat/core/util/open_in.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Dart half of the iOS "Open in…" hand-off. The native half — the
/// `UIDocumentInteractionController` that actually switches apps — only exists
/// on a device, so what is pinned here is the contract with it: what goes over
/// the channel, and that every way it can fail lands back on the share sheet
/// instead of on the user.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(OpenIn.channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  const anchor = Rect.fromLTWH(300, 48, 40, 40);

  group('on iOS', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    test('asks for the file, with somewhere to put the menu', () async {
      MethodCall? seen;
      messenger.setMockMethodCallHandler(OpenIn.channel, (call) async {
        seen = call;
        return true;
      });

      expect(await OpenIn.handOff('/tmp/log.txt', anchor: anchor), isTrue);
      expect(seen?.method, 'openIn');
      final args = (seen!.arguments as Map).cast<String, dynamic>();
      expect(args['path'], '/tmp/log.txt');
      // Not decoration: UIKit presents the menu as a popover and refuses an
      // empty source rect, which is the same failure that made the log button
      // do nothing at all.
      expect(args['anchor'], {
        'x': 300.0,
        'y': 48.0,
        'width': 40.0,
        'height': 40.0,
      });
    });

    test('an empty menu is a no, not a dead end', () async {
      // Nothing installed claims this type. The caller falls back to the share
      // sheet, so this must report the failure rather than swallow it.
      messenger.setMockMethodCallHandler(OpenIn.channel, (_) async => false);
      expect(await OpenIn.handOff('/tmp/log.txt', anchor: anchor), isFalse);
    });

    test('a build without the plugin falls back instead of throwing', () async {
      // No handler at all — MissingPluginException. A tap must not die here.
      expect(await OpenIn.handOff('/tmp/log.txt', anchor: anchor), isFalse);
    });

    test('a native failure falls back too', () async {
      messenger.setMockMethodCallHandler(
        OpenIn.channel,
        (_) async => throw PlatformException(code: 'boom'),
      );
      expect(await OpenIn.handOff('/tmp/log.txt', anchor: anchor), isFalse);
    });
  });

  test('android never asks: a share intent already opens the real app',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    var called = false;
    messenger.setMockMethodCallHandler(OpenIn.channel, (_) async {
      called = true;
      return true;
    });

    expect(OpenIn.isSupported, isFalse);
    expect(await OpenIn.handOff('/tmp/log.txt', anchor: anchor), isFalse);
    expect(called, isFalse);
  });
}
