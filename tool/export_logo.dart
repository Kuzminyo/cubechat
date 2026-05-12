// Renders [CubeLogoPainter] to a 1024×1024 PNG at `assets/logo/cube.png`.
//
// Usage:
//   flutter run -t tool/export_logo.dart -d windows
//      (or -d macos / -d linux — any desktop target works)
//
// The window will pop up briefly with the logo on a dark background, write
// the PNG to disk, and quit. After it finishes, regenerate launcher icons
// and splash:
//
//   dart run flutter_launcher_icons
//   dart run flutter_native_splash:create

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cubechat/core/widgets/cube_logo.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const _pngSize = 1024.0;
const _solidPath = 'assets/logo/cube.png';
const _transparentPath = 'assets/logo/cube_transparent.png';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _ExporterApp());
}

class _ExporterApp extends StatefulWidget {
  const _ExporterApp();

  @override
  State<_ExporterApp> createState() => _ExporterAppState();
}

class _ExporterAppState extends State<_ExporterApp> {
  String _status = 'Rendering…';

  @override
  void initState() {
    super.initState();
    // Run after first frame so the painter pipeline is warm.
    WidgetsBinding.instance.addPostFrameCallback((_) => _render());
  }

  Future<void> _render() async {
    try {
      final solid = await _rasterize(_pngSize.toInt(), solidBackground: true);
      await _write(_solidPath, solid);

      final transparent = await _rasterize(_pngSize.toInt(), solidBackground: false);
      await _write(_transparentPath, transparent);

      setState(() {
        _status = 'Wrote $_solidPath (${solid.length}B) + '
            '$_transparentPath (${transparent.length}B)';
      });
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (kDebugMode) {
        debugPrint('[export_logo] $_status');
      }
      exit(0);
    } catch (e, st) {
      setState(() => _status = 'FAILED: $e');
      debugPrint('[export_logo] $e\n$st');
    }
  }

  Future<void> _write(String path, Uint8List bytes) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  Future<Uint8List> _rasterize(int sidePx, {required bool solidBackground}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = Size(sidePx.toDouble(), sidePx.toDouble());

    if (solidBackground) {
      // Used for iOS launcher icons (no alpha allowed) + splash foreground.
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = const Color(0xFF06140D),
      );
    }

    // Drop the glow halo on the transparent variant so the foreground stays
    // tight to the cube silhouette (otherwise Android squeezes the foreground
    // into the safe zone and the glow gets cropped weirdly).
    CubeLogoPainter(glow: solidBackground).paint(canvas, size);

    final picture = recorder.endRecording();
    final image = await picture.toImage(sidePx, sidePx);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw StateError('toByteData returned null');
    }
    return byteData.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFF06140D),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 220, height: 220, child: CubeLogo(size: 220)),
              const SizedBox(height: 24),
              Text(
                _status,
                style: const TextStyle(color: Color(0xFFE8E8F0), fontSize: 13),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
