// ============================================================================
// GlobeOrFlat — AR Camera View (shared by Horizon Dip & Water Sightline)
// SPDX-License-Identifier: MIT
//
// Owns the back-camera lifecycle (permission, init, dispose, app
// pause/resume) and stacks a full-bleed overlay builder on top of the
// preview. The overlay is where all the physics HUD lives — the camera is
// display-only; measurement data comes from the sensor fusion engine.
// ============================================================================

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class ArCameraView extends StatefulWidget {
  const ArCameraView({
    super.key,
    required this.overlayBuilder,
    this.placeholderColor = const Color(0xFF071018),
  });

  /// Drawn over the preview (positioned fill). Rebuilt on every setState of
  /// the parent — painters should read live fusion state.
  final WidgetBuilder overlayBuilder;
  final Color placeholderColor;

  @override
  State<ArCameraView> createState() => _ArCameraViewState();
}

class _ArCameraViewState extends State<ArCameraView>
    with WidgetsBindingObserver {
  CameraController? _controller;
  bool _initializing = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeCamera();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The camera must be released while backgrounded on Android.
    if (state == AppLifecycleState.inactive) {
      _disposeCamera();
      if (mounted) {
        setState(() => _initializing = true);
      }
    } else if (state == AppLifecycleState.resumed &&
        _controller == null &&
        mounted) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    try {
      final List<CameraDescription> cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _error = 'No camera available on this device.';
            _initializing = false;
          });
        }
        return;
      }
      final CameraDescription description = cameras
          .firstWhere(
            (CameraDescription c) => c.lensDirection == CameraLensDirection.back,
            orElse: () => cameras.first,
          );
      final CameraController controller = CameraController(
        description,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _error = null;
        _initializing = false;
      });
    } on CameraException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.description ?? 'Camera error (${e.code})';
          _initializing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Camera could not start: $e';
          _initializing = false;
        });
      }
    }
  }

  Future<void> _disposeCamera() async {
    final CameraController? c = _controller;
    _controller = null;
    await c?.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CameraController? controller = _controller;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ColoredBox(color: widget.placeholderColor),
        if (controller != null && controller.value.isInitialized)
          FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: controller.value.previewSize!.height,
              height: controller.value.previewSize!.width,
              // CameraPlugin previews are landscape-native; swap for portrait.
              child: CameraPreview(controller),
            ),
          )
        else
          Center(
            child: _initializing
                ? const CircularProgressIndicator()
                : Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _error ??
                          'Camera unavailable',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
          ),
        Positioned.fill(child: Builder(builder: widget.overlayBuilder)),
      ],
    );
  }
}
