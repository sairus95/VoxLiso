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

  List<DetectedBox> _boxes = const [];
  String _diag = 'En attente de la première image…';
  bool _showDiag = true;
  bool _textOutsideOnly = false;

  double _exposure = 0;
  double _minExposure = 0;
  double _maxExposure = 0;
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
        ResolutionPreset.veryHigh, // 1080p : petits sous-titres plus lisibles
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
      try {
        _minExposure = await c.getMinExposureOffset();
        _maxExposure = await c.getMaxExposureOffset();
        _exposure = 0;
      } catch (_) {
        _minExposure = 0;
        _maxExposure = 0;
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
              "Autorisez-le dans Réglages > Applications > VoxLiso > Autorisations, puis réessayez."
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
    final info = describeCameraImage(image);
    final frame = buildInputImage(image, cam);
    if (frame == null) {
      _setDiag('⚠ Format d\'image non pris en charge : $info');
      return;
    }

    final RecognizedText result;
    final started = DateTime.now();
    try {
      result = await _recognizer.processImage(frame.image);
    } catch (e) {
      _setDiag('⚠ Erreur de reconnaissance : $e\n$info');
      return;
    }
    if (_closed || !mounted) return;
    final ms = DateTime.now().difference(started).inMilliseconds;

    final w = frame.uprightSize.width;
    final h = frame.uprightSize.height;
    final top = s.roiTop * h;
    final bottom = s.roiBottom * h;

    final all = <TextLine>[];
    final lines = <TextLine>[];
    for (final block in result.blocks) {
      for (final line in block.lines) {
        all.add(line);
        // Gardée si au moins la moitié de sa hauteur est dans la bande jaune.
        final r = line.boundingBox;
        final overlap = math.min(r.bottom, bottom) - math.max(r.top, top);
        if (r.height > 0 && overlap >= r.height * 0.5) lines.add(line);
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

    Rect frac(Rect r) => Rect.fromLTRB(r.left / w, r.top / h, r.right / w, r.bottom / h);
    final boxes = [
      for (final l in all) DetectedBox(frac(l.boundingBox), lines.contains(l)),
    ];
    final rawText = lines.map((l) => l.text).join(' / ');
    setState(() {
      _boxes = boxes;
      _textOutsideOnly = lines.isEmpty && all.isNotEmpty;
      _diag = '$info · ${frame.uprightSize.width.toInt()}×${frame.uprightSize.height.toInt()} · ${ms}ms\n'
          'Texte trouvé : ${all.length} ligne(s), ${lines.length} dans la zone'
          '${rawText.isEmpty ? '' : '\n« $rawText »'}';
    });

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

  void _setDiag(String text) {
    if (mounted && !_closed) setState(() => _diag = text);
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

  Future<void> _setExposure(double v) async {
    setState(() => _exposure = v);
    try {
      await _controller?.setExposureOffset(v);
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
        title: const Text('VoxLiso'),
        actions: [
          IconButton(
            tooltip: _showDiag ? 'Masquer le diagnostic' : 'Afficher le diagnostic',
            icon: Icon(_showDiag ? Icons.bug_report : Icons.bug_report_outlined),
            onPressed: () => setState(() => _showDiag = !_showDiag),
          ),
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
                if (_maxExposure > _minExposure) _buildExposure(),
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
        if (_showDiag)
          Positioned(
            left: 4,
            right: 4,
            top: 4,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _diag,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 11, height: 1.3),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _buildLastText(ThemeData theme) {
    final hint = _textOutsideOnly
        ? 'Du texte est vu en dehors de la bande jaune (cadres orange) : '
            'faites glisser la bande dessus.'
        : _reading
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

  Widget _buildExposure() {
    return Row(children: [
      const Icon(Icons.brightness_low),
      Expanded(
        child: Semantics(
          label: 'Luminosité de la caméra',
          child: Slider(
            value: _exposure.clamp(_minExposure, _maxExposure).toDouble(),
            min: _minExposure,
            max: _maxExposure,
            label: _exposure.toStringAsFixed(1),
            onChanged: _setExposure,
          ),
        ),
      ),
      const Icon(Icons.brightness_high),
    ]);
  }
}
