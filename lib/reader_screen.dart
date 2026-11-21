import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'camera_input.dart';
import 'languages.dart';
import 'roi_overlay.dart';
import 'settings.dart';
import 'settings_sheet.dart';
import 'speech_service.dart';
import 'subtitle_tracker.dart';
import 'text_tools.dart';

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.settings});
  final AppSettings settings;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  final TextRecognizer _recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  final SpeechService _speech = SpeechService();
  late final SubtitleTracker _tracker;

  CameraController? _controller;
  CameraDescription? _camera;
  bool _initializing = false;
  bool _closed = false;
  bool _busy = false;
  bool _reading = false;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);

  List<Rect> _boxes = const [];
  String _lastSpoken = '';
  String? _error;
  bool _voiceMissing = false;

  double _zoom = 1;
  double _minZoom = 1;
  double _maxZoom = 1;

  AppSettings get s => widget.settings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tracker = SubtitleTracker(stableFrames: s.stableFrames);
    _speech.interrupt = s.interrupt;
    _zoom = s.zoom;
    _start();
  }

  Future<void> _start() async {
    await _speech.init();
    await _applyVoice();
    await _initCamera();
  }

  Future<void> _applyVoice() async {
    final ok = await _speech.configure(
      locale: languageFor(s.lang).ttsLocale,
      rate: s.rate,
    );
    if (mounted) setState(() => _voiceMissing = !ok);
  }

  // ---------------------------------------------------------------- caméra

  Future<void> _initCamera() async {
    if (_initializing || _controller != null || _closed) return;
    _initializing = true;
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        _setError('Aucune caméra trouvée sur cet appareil.');
        return;
      }
      _camera = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      final c = CameraController(
        _camera!,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup:
            Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );
      await c.initialize();
      if (_closed || !mounted) {
        await c.dispose();
        return;
      }
      try {
        await c.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } catch (_) {}
      try {
        await c.setFocusMode(FocusMode.auto);
      } catch (_) {}
      try {
        _minZoom = await c.getMinZoomLevel();
        _maxZoom = math.min(await c.getMaxZoomLevel(), 8.0);
        final double zoomMax = math.max(_minZoom, _maxZoom);
        _zoom = _zoom.clamp(_minZoom, zoomMax).toDouble();
        await c.setZoomLevel(_zoom);
      } catch (_) {
        _minZoom = 1.0;
        _maxZoom = 1.0;
        _zoom = 1.0;
      }
      await c.startImageStream(_onFrame);
      if (_closed || !mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _error = null;
      });
    } on CameraException catch (e) {
      _setError(e.code.contains('Access') || e.code.contains('ermission')
          ? "L'accès à la caméra a été refusé.\n"
              "Autorisez-le dans Réglages > Applications > Voix Sous-Titres > Autorisations, puis réessayez."
          : 'Erreur caméra : ${e.description ?? e.code}');
    } catch (e) {
      _setError('Erreur au démarrage de la caméra : $e');
    } finally {
      _initializing = false;
    }
  }

  void _setError(String message) {
    if (mounted) setState(() => _error = message);
  }

  Future<void> _releaseCamera() async {
    final c = _controller;
    _controller = null;
    if (mounted && !_closed) setState(() => _boxes = const []);
    if (c != null) {
      try {
        if (c.value.isStreamingImages) await c.stopImageStream();
      } catch (_) {}
      await c.dispose();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (_controller != null) {
        _stopReading();
        _releaseCamera();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_controller == null && _error == null) _initCamera();
    }
  }

  // ------------------------------------------------------- analyse d'image

  void _onFrame(CameraImage image) {
    if (_busy || _closed) return;
    final now = DateTime.now();
    if (now.difference(_lastFrame) < s.frameInterval) return;
    _lastFrame = now;
    _busy = true;
    _processFrame(image).whenComplete(() => _busy = false);
  }

  Future<void> _processFrame(CameraImage image) async {
    final cam = _camera;
    if (cam == null) return;
    final frame = buildInputImage(image, cam);
    if (frame == null) return;

    final RecognizedText result;
    try {
      result = await _recognizer.processImage(frame.image);
    } catch (_) {
      return;
    }
    if (_closed || !mounted) return;

    final w = frame.uprightSize.width;
    final h = frame.uprightSize.height;
    final top = s.roiTop;
    final bottom = s.roiBottom;

    final lines = <TextLine>[];
    for (final block in result.blocks) {
      for (final line in block.lines) {
        final cy = line.boundingBox.center.dy / h;
        if (cy >= top && cy <= bottom) lines.add(line);
      }
    }
    // De haut en bas, puis de gauche à droite sur une même ligne.
    lines.sort((a, b) {
      final ra = a.boundingBox, rb = b.boundingBox;
      final dy = ra.center.dy - rb.center.dy;
      if (dy.abs() < math.min(ra.height, rb.height) * 0.5) {
        return ra.left.compareTo(rb.left);
      }
      return dy < 0 ? -1 : 1;
    });

    final boxes = [
      for (final l in lines)
        Rect.fromLTRB(
          l.boundingBox.left / w,
          l.boundingBox.top / h,
          l.boundingBox.right / w,
          l.boundingBox.bottom / h,
        ),
    ];
    setState(() => _boxes = boxes);

    if (!_reading) return;
    final text = cleanSubtitle(
      lines.map((l) => l.text).toList(),
      removeSoundTags: s.removeSoundTags,
    );
    final toSay = _tracker.push(text);
    if (toSay != null && toSay.trim().isNotEmpty) {
      _speech.say(toSay);
      setState(() => _lastSpoken = toSay);
    }
  }

  // ---------------------------------------------------------- commandes

  void _toggleReading() {
    HapticFeedback.mediumImpact();
    if (_reading) {
      _stopReading();
    } else {
      _tracker
        ..stableFrames = s.stableFrames
        ..reset();
      WakelockPlus.enable();
      setState(() => _reading = true);
    }
  }

  void _stopReading() {
    if (!_reading) return;
    _speech.stop();
    WakelockPlus.disable();
    if (mounted && !_closed) setState(() => _reading = false);
  }

  Future<void> _setLanguage(String code) async {
    s.lang = code;
    _tracker.reset();
    setState(() {});
    await _applyVoice();
  }

  Future<void> _setZoom(double z) async {
    setState(() => _zoom = z);
    try {
      await _controller?.setZoomLevel(z);
    } catch (_) {}
  }

  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SettingsSheet(
        settings: s,
        voiceMissing: _voiceMissing,
        onVoiceChanged: _applyVoice,
        onTestVoice: () => _speech.say(languageFor(s.lang).sample),
        onResetZone: () => setState(() {
          s.roiTop = AppSettings.defaultRoiTop;
          s.roiBottom = AppSettings.defaultRoiBottom;
        }),
      ),
    );
    _speech.interrupt = s.interrupt;
    _tracker.stableFrames = s.stableFrames;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    _releaseCamera();
    _recognizer.close();
    _speech.stop();
    WakelockPlus.disable();
    super.dispose();
  }

  // ------------------------------------------------------------- interface

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Voix Sous-Titres'),
        actions: [
          IconButton(
            tooltip: 'Réglages',
            icon: const Icon(Icons.tune),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(child: Center(child: _buildPreview())),
          if (_voiceMissing)
            MaterialBanner(
              content: Text(
                'La voix « ${languageFor(s.lang).label} » n\'est pas installée sur ce téléphone. '
                'Installez-la dans les réglages de synthèse vocale du téléphone.',
              ),
              actions: const [SizedBox.shrink()],
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildLastText(theme),
                if (_maxZoom > _minZoom) _buildZoom(),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: [
                    for (final l in kLanguages)
                      ButtonSegment(
                        value: l.code,
                        label: Text(l.short),
                        tooltip: l.label,
                      ),
                  ],
                  selected: {s.lang},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) => _setLanguage(v.first),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 64,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _reading ? Colors.red.shade700 : null,
                      textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    onPressed: _controller == null ? null : _toggleReading,
                    icon: Icon(_reading ? Icons.stop : Icons.record_voice_over, size: 28),
                    label: Text(_reading ? 'Arrêter la lecture' : 'Lire les sous-titres'),
                  ),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildPreview() {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.videocam_off, size: 56),
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () {
              setState(() => _error = null);
              _initCamera();
            },
            child: const Text('Réessayer'),
          ),
        ]),
      );
    }
    final c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const CircularProgressIndicator();
    }
    return AspectRatio(
      aspectRatio: 1 / c.value.aspectRatio,
      child: Stack(fit: StackFit.expand, children: [
        CameraPreview(c),
        RoiOverlay(
          top: s.roiTop,
          bottom: s.roiBottom,
          boxes: _boxes,
          onChanged: (t, b) => setState(() {
            s.roiTop = t;
            s.roiBottom = b;
          }),
          onChangeEnd: () {},
        ),
      ]),
    );
  }

  Widget _buildLastText(ThemeData theme) {
    final hint = _reading
        ? 'En attente d\'un sous-titre…'
        : 'Visez l\'écran, placez la bande jaune sur les sous-titres, puis appuyez sur « Lire ».';
    return Container(
      constraints: const BoxConstraints(minHeight: 72),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _lastSpoken.isEmpty ? hint : _lastSpoken,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: _lastSpoken.isEmpty
            ? theme.textTheme.bodyMedium
            : theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildZoom() {
    return Row(children: [
      const Icon(Icons.zoom_out),
      Expanded(
        child: Slider(
          value: _zoom.clamp(_minZoom, _maxZoom).toDouble(),
          min: _minZoom,
          max: _maxZoom,
          label: 'x${_zoom.toStringAsFixed(1)}',
          divisions: ((_maxZoom - _minZoom) * 4).round().clamp(1, 100),
          onChanged: _setZoom,
          onChangeEnd: (z) => s.zoom = z,
        ),
      ),
      const Icon(Icons.zoom_in),
    ]);
  }
}
