import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../core/widgets/glass_toast.dart';

/// In-app camera: a live preview with a shutter, front/back flip and a flash
/// cycle. Pops with the captured photo's JPEG bytes, or null if the user backs
/// out. The caller decides what happens next (here: hand the bytes to the image
/// editor, then send).
///
/// Kept self-contained and Riverpod-free — it owns a [CameraController] for its
/// lifetime and nothing outside needs to observe it.
class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  int _cameraIndex = 0;
  FlashMode _flash = FlashMode.off;
  bool _initializing = true;
  bool _capturing = false;
  bool _unavailable = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bootstrap();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    // The OS reclaims the camera when the app backgrounds; tear the controller
    // down so we don't hold a dead handle, and rebuild it on the way back.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      controller.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      unawaitedInit();
    }
  }

  Future<void> _bootstrap() async {
    try {
      _cameras = await availableCameras();
    } catch (_) {
      _cameras = const [];
    }
    if (_cameras.isEmpty) {
      if (mounted) setState(() {
        _unavailable = true;
        _initializing = false;
      });
      return;
    }
    await _use(_cameraIndex);
  }

  /// Non-throwing re-init used from the lifecycle resume path.
  void unawaitedInit() {
    if (_cameras.isEmpty) return;
    _use(_cameraIndex);
  }

  Future<void> _use(int index) async {
    if (_cameras.isEmpty) return;
    if (mounted) setState(() => _initializing = true);
    final old = _controller;
    _controller = null;
    await old?.dispose();

    final controller = CameraController(
      _cameras[index],
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await controller.initialize();
      await controller.setFlashMode(_flash);
      _controller = controller;
      _cameraIndex = index;
    } catch (_) {
      await controller.dispose();
      if (mounted) setState(() => _unavailable = true);
    } finally {
      if (mounted) setState(() => _initializing = false);
    }
  }

  Future<void> _flip() async {
    if (_cameras.length < 2 || _initializing) return;
    await _use((_cameraIndex + 1) % _cameras.length);
  }

  Future<void> _cycleFlash() async {
    final controller = _controller;
    if (controller == null) return;
    // off → auto → torch → off. Plain and predictable; no metering UI.
    final next = switch (_flash) {
      FlashMode.off => FlashMode.auto,
      FlashMode.auto => FlashMode.torch,
      _ => FlashMode.off,
    };
    try {
      await controller.setFlashMode(next);
      if (mounted) setState(() => _flash = next);
    } catch (_) {
      // Some front cameras reject flash — leave it off silently.
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) {
      return;
    }
    setState(() => _capturing = true);
    try {
      final shot = await controller.takePicture();
      final bytes = await shot.readAsBytes();
      if (mounted) Navigator.of(context).pop<Uint8List>(bytes);
    } catch (e) {
      if (mounted) {
        setState(() => _capturing = false);
        showGlassToast(context, 'Capture failed: $e', tone: ToastTone.danger);
      }
    }
  }

  IconData get _flashIcon => switch (_flash) {
        FlashMode.off => Icons.flash_off,
        FlashMode.auto => Icons.flash_auto,
        _ => Icons.flash_on,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _preview(),
          // Top bar: close + flash.
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  if (_controller != null && !_unavailable)
                    IconButton(
                      icon: Icon(_flashIcon, color: Colors.white),
                      onPressed: _cycleFlash,
                    ),
                ],
              ),
            ),
          ),
          if (!_unavailable) _controls(),
        ],
      ),
    );
  }

  Widget _preview() {
    if (_unavailable) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined,
                color: Colors.white54, size: 56),
            const SizedBox(height: 12),
            Text('Camera unavailable',
                style: TextStyle(color: AppColors.textOnGlassDim, fontSize: 13)),
          ],
        ),
      );
    }
    final controller = _controller;
    if (_initializing || controller == null || !controller.value.isInitialized) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.brandPrimary),
      );
    }
    // Fill the screen and crop, the way a camera app previews, rather than
    // letterboxing the sensor's aspect ratio into the middle of a black screen.
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: controller.value.previewSize?.height ?? 1,
        height: controller.value.previewSize?.width ?? 1,
        child: CameraPreview(controller),
      ),
    );
  }

  Widget _controls() {
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 28),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              const SizedBox(width: 56),
              _shutter(),
              SizedBox(
                width: 56,
                child: _cameras.length > 1
                    ? IconButton(
                        icon: const Icon(Icons.cameraswitch,
                            color: Colors.white, size: 28),
                        onPressed: _flip,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shutter() {
    return GestureDetector(
      onTap: _capture,
      child: Container(
        width: 74,
        height: 74,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
          color: Colors.white24,
        ),
        child: _capturing
            ? const Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              )
            : Center(
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                  ),
                ),
              ),
      ),
    );
  }
}
