import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/theme/colors.dart';

/// "Telegram circle" capture screen. Opens with the front camera in low-
/// resolution preview, square-cropped (BoxFit.cover into a 1:1 box), with
/// a big red record button. Tap to start / tap to stop. Auto-stops at
/// [maxDurationSeconds].
///
/// Pops the modal route with `({path, durationMs})` on success, or null
/// on cancel.
class CircleRecorderScreen extends StatefulWidget {
  const CircleRecorderScreen({super.key});

  static const int maxDurationSeconds = 10;

  @override
  State<CircleRecorderScreen> createState() => _CircleRecorderScreenState();
}

class _CircleRecorderScreenState extends State<CircleRecorderScreen> {
  CameraController? _controller;
  bool _initialized = false;
  bool _recording = false;
  DateTime? _startedAt;
  Timer? _tick;
  Duration _elapsed = Duration.zero;
  String? _initError;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _initError = 'no cameras');
        return;
      }
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      final c = CameraController(
        front,
        // Low resolution keeps file size in a transmittable range for BLE.
        // 320x240 @ ~150kbps × 10s ≈ 200KB — still slow over BLE but
        // doesn't take all day.
        ResolutionPreset.low,
        enableAudio: true,
      );
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _initialized = true;
      });
    } catch (e, st) {
      debugPrint('camera init failed: $e\n$st');
      if (mounted) setState(() => _initError = '$e');
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized || _recording) return;
    try {
      await c.startVideoRecording();
      setState(() {
        _recording = true;
        _startedAt = DateTime.now();
        _elapsed = Duration.zero;
      });
      _tick = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted || !_recording || _startedAt == null) return;
        final el = DateTime.now().difference(_startedAt!);
        setState(() => _elapsed = el);
        if (el.inSeconds >= CircleRecorderScreen.maxDurationSeconds) {
          unawaited(_stop());
        }
      });
    } catch (e) {
      debugPrint('startVideoRecording failed: $e');
    }
  }

  Future<void> _stop() async {
    final c = _controller;
    if (c == null || !_recording) return;
    _tick?.cancel();
    _tick = null;
    try {
      final file = await c.stopVideoRecording();
      final started = _startedAt;
      setState(() {
        _recording = false;
        _startedAt = null;
      });
      // Copy into our cache dir so the path is stable + namespaced.
      final dir = Directory(
        '${(await getApplicationCacheDirectory()).path}/cubechat/video',
      );
      if (!await dir.exists()) await dir.create(recursive: true);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final dst = '${dir.path}/cap-$stamp.mp4';
      await File(file.path).copy(dst);
      final durationMs = started == null
          ? 0
          : DateTime.now().difference(started).inMilliseconds;
      if (!mounted) return;
      Navigator.of(context).pop(
        (path: dst, durationMs: durationMs, mime: 'video/mp4'),
      );
    } catch (e) {
      debugPrint('stopVideoRecording failed: $e');
      if (mounted) setState(() => _recording = false);
    }
  }

  void _cancel() {
    _tick?.cancel();
    if (_recording) {
      _controller?.stopVideoRecording().ignore();
    }
    Navigator.of(context).pop();
  }

  String _fmtElapsed() {
    final s = _elapsed.inSeconds;
    final remaining =
        (CircleRecorderScreen.maxDurationSeconds - s).clamp(0, 999);
    return '$s / ${CircleRecorderScreen.maxDurationSeconds}s '
        '($remaining left)';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _initError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'camera unavailable: $_initError',
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : !_initialized
                ? const Center(
                    child: CircularProgressIndicator(
                      color: AppColors.brandPrimary,
                    ),
                  )
                : _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    final c = _controller!;
    return Column(
      children: [
        const Spacer(),
        AspectRatio(
          aspectRatio: 1,
          child: ClipOval(
            child: FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: c.value.previewSize?.height ?? 480,
                height: c.value.previewSize?.width ?? 480,
                child: CameraPreview(c),
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
        Text(
          _recording ? _fmtElapsed() : 'tap to record (max 10s)',
          style: TextStyle(
            color: _recording ? AppColors.danger : Colors.white70,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 24),
        GestureDetector(
          onTap: _recording ? _stop : _start,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.danger,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.9),
                width: 4,
              ),
              boxShadow: _recording
                  ? [
                      BoxShadow(
                        color: AppColors.danger.withValues(alpha: 0.6),
                        blurRadius: 24,
                        spreadRadius: 4,
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              _recording ? Icons.stop : Icons.fiber_manual_record,
              color: Colors.white,
              size: 32,
            ),
          ),
        ),
        const Spacer(),
        TextButton(
          onPressed: _cancel,
          child: const Text(
            'cancel',
            style: TextStyle(color: Colors.white60),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
