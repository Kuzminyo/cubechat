import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// One gesture owner for zoom, paging and pull-to-close. A parent vertical
/// recognizer loses to InteractiveViewer's scale recognizer even at 1x.
class MediaPhotoSurface extends StatefulWidget {
  const MediaPhotoSurface({
    super.key,
    required this.child,
    required this.onDismissUpdate,
    required this.onDismissEnd,
    required this.onDismissCancel,
    required this.onPageUpdate,
    required this.onPageEnd,
  });
  final Widget child;
  final ValueChanged<double> onDismissUpdate;
  final ValueChanged<double> onDismissEnd;
  final VoidCallback onDismissCancel;
  final ValueChanged<double> onPageUpdate;
  final ValueChanged<double> onPageEnd;
  @override
  State<MediaPhotoSurface> createState() => _MediaPhotoSurfaceState();
}

class _MediaPhotoSurfaceState extends State<MediaPhotoSurface> {
  final _transform = TransformationController();
  Offset _origin = Offset.zero;
  Offset _previous = Offset.zero;
  Axis? _axis;
  bool _zoomed = false;
  bool _scaling = false;
  final _pointers = <int>{};
  bool _sequencePinched = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_zoomChanged);
  }

  void _zoomChanged() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _start(ScaleStartDetails details) {
    _origin = _previous = details.focalPoint;
    _axis = null;
    _scaling = _zoomed || _sequencePinched || details.pointerCount > 1;
  }

  void _update(ScaleUpdateDetails details) {
    if (_sequencePinched || details.pointerCount > 1 || _zoomed) {
      if (!_scaling) _cancel();
      _scaling = true;
      return;
    }
    // A pinch stays a pinch until every finger lifts, including after zooming
    // back to 1x; the remaining finger must not suddenly dismiss the photo.
    if (_scaling) return;
    final total = details.focalPoint - _origin;
    if (_axis == null) {
      if (total.distance < kTouchSlop) return;
      _axis = total.dy.abs() > total.dx.abs() ? Axis.vertical : Axis.horizontal;
    }
    final delta = details.focalPoint - _previous;
    _previous = details.focalPoint;
    if (_axis == Axis.vertical) {
      widget.onDismissUpdate(delta.dy);
    } else {
      widget.onPageUpdate(delta.dx);
    }
  }

  void _end(double dx, double dy) {
    if (_axis == Axis.vertical) widget.onDismissEnd(dy);
    if (_axis == Axis.horizontal) widget.onPageEnd(dx);
    _axis = null;
  }

  void _cancel() {
    if (_axis == Axis.vertical) widget.onDismissCancel();
    if (_axis == Axis.horizontal) widget.onPageEnd(0);
    _axis = null;
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (event) {
          if (_pointers.isEmpty) _sequencePinched = false;
          _pointers.add(event.pointer);
          if (_pointers.length > 1) {
            _sequencePinched = true;
            _cancel();
            _scaling = true;
          }
        },
        onPointerUp: (event) => _pointers.remove(event.pointer),
        onPointerCancel: (event) {
          _pointers.remove(event.pointer);
          _cancel();
          _scaling = true;
        },
        child: InteractiveViewer(
          transformationController: _transform,
          minScale: 1,
          maxScale: 8,
          panEnabled: _zoomed,
          onInteractionStart: _start,
          onInteractionUpdate: _update,
          onInteractionEnd: (details) => _end(
            details.velocity.pixelsPerSecond.dx,
            details.velocity.pixelsPerSecond.dy,
          ),
          child: widget.child,
        ),
      );
}
