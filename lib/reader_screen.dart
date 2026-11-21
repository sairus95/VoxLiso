import 'dart:io' show File, Platform;
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'camera_input.dart';
import 'language_detector.dart';
import 'languages.dart';
import 'roi_overlay.dart';
import 'settings.dart';
import 'settings_sheet.dart';
import 'speech_service.dart';
import 'subtitle_tracker.dart';
import 'text_tools.dart';
import 'translator.dart';
import 'voices.dart';

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
  late final LanguageDetector _langDetector;
  bool _locking = false;

  CameraController? _controller;
  CameraDescription? _camera;
  bool _initializing = false;
  bool _closed = false;
  bool _busy = false;
  bool _reading = false;
  int _photoLoopId = 0;
  DateTime _lastFrame = DateTime.fromMillisecondsSinceEpoch(0);

  List<DetectedBox> _boxes = const [];
  String _diag = 'En attente de la première image…';
  bool _showDiag = true;
  bool _textOutsideOnly = false;

  double _exposure = 0;
  double _minExposure = 0;
  double _maxExposure = 0;
  String _lastSpoken = '';

  /// Texte d'origine quand [_lastSpoken] est une traduction.
  String _lastOriginal = '';
  String? _translateWarning;

  final VoiceCatalog _catalog = VoiceCatalog();
  final SubtitleTranslator _translator = SubtitleTranslator();

  /// Les sous-titres sont traités l'un après l'autre (détection de langue,
  /// traduction) pour être dits dans l'ordre.
  Future<void> _speakChain = Future<void>.value();
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
    _langDetector = LanguageDetector(s.detectedLang);
    _speech.interrupt = s.interrupt;
    _zoom = s.zoom;
    _start();
  }

  Future<void> _start() async {
    await _speech.init();
    _catalog.load(await _speech.rawVoices());
    _translator.refresh();
    await _applyVoice();
    await _initCamera();
  }

  /// Voix utilisée : la langue choisie, ou la dernière langue détectée en mode Auto.
  SubtitleLanguage get _voice => languageFor(s.autoLang ? _langDetector.current : s.lang);

  Future<void> _applyVoice() async {
    final ok = await _speech.configure(
      locale: _voice.ttsLocale,
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
      if (!s.photoMode) await c.startImageStream(_onFrame);
      if (_closed || !mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _controller = c;
        _error = null;
      });
      c.addListener(_syncOrientation);
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncOrientation());
      if (s.photoMode) _startPhotoLoop();
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
    _stopPhotoLoop();
    final c = _controller;
    _controller = null;
    c?.removeListener(_syncOrientation);
    if (mounted && !_closed) setState(() => _boxes = const []);
    if (c != null) {
      try {
        if (c.value.isStreamingImages) await c.stopImageStream();
      } catch (_) {}
      await c.dispose();
    }
  }

  // ---------------------------------------------------------- orientation
  //
  // L'image de la caméra est orientée comme l'interface : portrait, ou
  // paysage du bon côté. Si la rotation automatique du téléphone est
  // désactivée, l'interface reste en portrait et l'image aussi.

  DeviceOrientation get _orientation {
    final c = _controller;
    if (c == null) return DeviceOrientation.portraitUp;
    return c.value.lockedCaptureOrientation ?? c.value.deviceOrientation;
  }

  bool get _landscape => isLandscape(_orientation);

  double get _roiTop => _landscape ? s.roiTopLandscape : s.roiTop;
  double get _roiBottom => _landscape ? s.roiBottomLandscape : s.roiBottom;

  void _setRoi(double top, double bottom) {
    if (_landscape) {
      s.roiTopLandscape = top;
      s.roiBottomLandscape = bottom;
    } else {
      s.roiTop = top;
      s.roiBottom = bottom;
    }
  }

  void _syncOrientation() {
    final c = _controller;
    if (c == null || !c.value.isInitialized || !mounted || _closed || _locking) return;
    final uiLandscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final device = c.value.deviceOrientation;
    final locked = c.value.lockedCaptureOrientation;
    DeviceOrientation want;
    if (!uiLandscape) {
      want = DeviceOrientation.portraitUp;
    } else if (isLandscape(device)) {
      want = device;
    } else if (locked != null && isLandscape(locked)) {
      want = locked;
    } else {
      want = DeviceOrientation.landscapeLeft;
    }
    if (locked == want) return;
    _locking = true;
    c.lockCaptureOrientation(want).catchError((_) {}).whenComplete(() {
      _locking = false;
      if (mounted && !_closed) setState(() {});
    });
  }

  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncOrientation());
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
    final frame = buildInputImage(image, cam, _orientation);
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
    _handleResult(result, frame.uprightSize, info, ms);
  }

  /// Exploite le résultat de l'OCR (flux vidéo ou photo) : cadres, diagnostic, lecture.
  /// Renvoie les lignes trouvées et celles retenues dans la zone.
  ({List<TextLine> all, List<TextLine> inZone}) _handleResult(
    RecognizedText result,
    Size upright,
    String info,
    int ms,
  ) {
    final w = upright.width;
    final h = upright.height;
    final top = _roiTop * h;
    final bottom = _roiBottom * h;

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
      _diag = '${s.photoMode ? 'Mode photo · ' : ''}$info · ${w.toInt()}×${h.toInt()} · ${ms}ms\n'
          'Texte trouvé : ${all.length} ligne(s), ${lines.length} dans la zone'
          '${rawText.isEmpty ? '' : '\n« $rawText »'}';
    });

    if (_reading) {
      final parts = subtitleParts(
        lines.map((l) => l.text).toList(),
        removeSoundTags: s.removeSoundTags,
      );
      final text = parts.join(' ');
      final toSay = _tracker.push(text);
      if (toSay != null && toSay.trim().isNotEmpty) {
        // Répliques séparées seulement si tout le sous-titre est nouveau
        // (pas pour la fin d'un sous-titre « en direct » qui défile).
        final segments =
            s.dialogueVoices && parts.length > 1 && toSay == text ? parts : [toSay];
        _speakChain = _speakChain
            .then((_) => _speakSubtitle(text, segments))
            .catchError((Object _) {});
      }
    }
    return (all: all, inZone: lines);
  }

  // ------------------------------------------------------------ mode photo
  //
  // Au lieu du flux vidéo, on prend de vraies photos (mise au point et
  // exposition calculées par le téléphone, orientation gérée par le fichier).
  // Plus lent, mais indépendant du format des images du flux vidéo.

  void _startPhotoLoop() {
    final id = ++_photoLoopId;
    () async {
      while (!_closed && id == _photoLoopId) {
        final c = _controller;
        if (c == null || !c.value.isInitialized) break;
        final started = DateTime.now();
        if (!_busy) {
          _busy = true;
          try {
            final r = await _ocrPhoto(c);
            if (id == _photoLoopId && !_closed && mounted) {
              _handleResult(r.result, r.upright, r.info, r.ms);
            }
          } catch (e) {
            _setDiag('⚠ Mode photo : $e');
            await Future<void>.delayed(const Duration(seconds: 1));
          } finally {
            _busy = false;
          }
        }
        final wait = s.frameInterval - DateTime.now().difference(started);
        await Future<void>.delayed(
            wait.isNegative ? const Duration(milliseconds: 30) : wait);
      }
    }();
  }

  void _stopPhotoLoop() => _photoLoopId++;

  Future<({RecognizedText result, Size upright, String info, int ms})> _ocrPhoto(
      CameraController c) async {
    final started = DateTime.now();
    final shot = await c.takePicture();
    try {
      final bytes = await File(shot.path).readAsBytes();
      final result = await _recognizer.processImage(InputImage.fromFilePath(shot.path));
      final ms = DateTime.now().difference(started).inMilliseconds;
      final raw = jpegSize(bytes);
      Size upright;
      if (raw != null) {
        // L'image « à l'endroit » est en hauteur en portrait, en largeur en paysage.
        final long = math.max(raw.width, raw.height);
        final short = math.min(raw.width, raw.height);
        upright = _landscape ? Size(long, short) : Size(short, long);
      } else {
        final p = c.value.previewSize ?? const Size(1920, 1080);
        final long = math.max(p.width, p.height);
        final short = math.min(p.width, p.height);
        upright = _landscape ? Size(long, short) : Size(short, long);
      }
      final info = raw == null
          ? 'Photo (taille inconnue)'
          : 'Photo ${raw.width.toInt()}×${raw.height.toInt()}';
      return (result: result, upright: upright, info: info, ms: ms);
    } finally {
      try {
        File(shot.path).deleteSync();
      } catch (_) {}
    }
  }

  Future<void> _waitIdle() async {
    for (var i = 0; i < 60 && _busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Bascule entre flux vidéo et mode photo selon le réglage.
  Future<void> _applyAnalysisMode() async {
    final c = _controller;
    if (c == null) return;
    _stopPhotoLoop();
    await _waitIdle();
    try {
      if (s.photoMode) {
        if (c.value.isStreamingImages) await c.stopImageStream();
        _startPhotoLoop();
      } else if (!c.value.isStreamingImages) {
        await c.startImageStream(_onFrame);
      }
    } catch (e) {
      _setDiag('⚠ Changement de mode : $e');
    }
  }

  /// Bouton « Tester sur une photo » : prend une photo, y cherche du texte
  /// et affiche tout ce qui a été trouvé.
  Future<void> _testPhoto() async {
    final c = _controller;
    if (c == null) return;
    HapticFeedback.selectionClick();
    _stopPhotoLoop();
    await _waitIdle();
    final wasStreaming = c.value.isStreamingImages;
    var title = "La photo a échoué";
    final details = <String>[];
    _busy = true;
    try {
      if (wasStreaming) await c.stopImageStream();
      final r = await _ocrPhoto(c);
      final found = _handleResult(r.result, r.upright, r.info, r.ms);
      title = found.all.isEmpty
          ? 'Aucun texte trouvé sur la photo'
          : '${found.all.length} ligne(s) trouvée(s), ${found.inZone.length} dans la bande jaune';
      for (final l in found.all) {
        details.add('${found.inZone.contains(l) ? '✅' : '🟧'} ${l.text}');
      }
      details.add('\n${r.info} · ${r.ms} ms');
    } catch (e) {
      title = 'La photo a échoué';
      details.add('$e');
    } finally {
      _busy = false;
    }
    if (!_closed && _controller == c) {
      try {
        if (s.photoMode) {
          _startPhotoLoop();
        } else if (wasStreaming) {
          await c.startImageStream(_onFrame);
        }
      } catch (_) {}
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Text(details.isEmpty
              ? 'Rapprochez-vous ou zoomez, évitez les reflets, puis réessayez.'
              : details.join('\n')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  // ------------------------------------------------------ voix et langue

  /// Voix principale d'une langue : celle choisie, sinon la plus naturelle.
  TtsVoice? _primaryVoice(String lang) => s.voiceFor(lang) ?? _catalog.best(lang);

  /// Voix du 2e personnage : celle choisie, sinon une autre voix de la langue,
  /// sinon la même voix en plus grave.
  ({TtsVoice? voice, double pitch}) _secondVoice(String lang) {
    final first = _primaryVoice(lang);
    final second = s.voice2For(lang) ?? _catalog.secondVoice(lang, first);
    if (second == null || second.key == first?.key) return (voice: first, pitch: 0.8);
    return (voice: second, pitch: 1.0);
  }

  /// Identifie la langue (mode Auto), traduit si demandé, puis dit le
  /// sous-titre : une voix par réplique dans les dialogues.
  Future<void> _speakSubtitle(String fullText, List<String> segments) async {
    final before = _langDetector.current;
    final lang = s.autoLang ? await _langDetector.detect(fullText) : s.lang;
    if (_closed || !_reading) return;
    if (s.autoLang && lang != before) {
      s.detectedLang = lang;
      final ok = await _speech.isAvailable(languageFor(lang).ttsLocale);
      if (mounted && !_closed) setState(() => _voiceMissing = !ok);
    }

    var speakLang = lang;
    var out = segments;
    String? warning;
    final target = s.translateTo;
    if (target.isNotEmpty && target != lang) {
      final translated = <String>[];
      for (final seg in segments) {
        final t = await _translator.translate(seg, lang, target);
        if (t == null) break;
        translated.add(t);
      }
      if (translated.length == segments.length) {
        out = translated;
        speakLang = target;
      } else {
        warning = 'Traduction impossible : téléchargez ${languageFor(lang).label} et '
            '${languageFor(target).label} dans les réglages (section Traduction).';
      }
    }
    if (_closed || !_reading) return;

    final locale = languageFor(speakLang).ttsLocale;
    final first = _primaryVoice(speakLang);
    final second = _secondVoice(speakLang);
    _speech.sayAll([
      for (var i = 0; i < out.length; i++)
        Utterance(
          out[i],
          locale: locale,
          voice: i.isOdd ? second.voice : first,
          pitch: i.isOdd ? second.pitch : 1.0,
        ),
    ]);
    if (mounted && !_closed) {
      setState(() {
        _lastSpoken = out.join(' ');
        _lastOriginal = speakLang != lang ? segments.join(' ') : '';
        _translateWarning = warning;
      });
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
    final wasPhoto = s.photoMode;
    // De nouvelles voix ont pu être installées depuis le dernier passage.
    _catalog.load(await _speech.rawVoices());
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SettingsSheet(
        settings: s,
        voice: _voice,
        voiceMissing: _voiceMissing,
        catalog: _catalog,
        translator: _translator,
        primaryVoice: _primaryVoice,
        secondVoice: _secondVoice,
        onVoiceChanged: _applyVoice,
        onPreviewVoice: (lang, voice, pitch) => _speech.say(
          languageFor(lang).sample,
          locale: languageFor(lang).ttsLocale,
          voice: voice,
          pitch: pitch,
        ),
        onResetZone: () => setState(s.resetZones),
      ),
    );
    _speech.interrupt = s.interrupt;
    _tracker.stableFrames = s.stableFrames;
    if (s.photoMode != wasPhoto) await _applyAnalysisMode();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    _releaseCamera();
    _recognizer.close();
    _langDetector.close();
    _translator.close();
    _speech.stop();
    WakelockPlus.disable();
    super.dispose();
  }

  // ------------------------------------------------------------- interface

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final landscapeUi = MediaQuery.orientationOf(context) == Orientation.landscape;
    final banner = _voiceMissing
        ? MaterialBanner(
            content: Text(
              'La voix « ${_voice.label} » n\'est pas installée sur ce téléphone. '
              'Installez-la dans les réglages de synthèse vocale du téléphone.',
            ),
            actions: const [SizedBox.shrink()],
          )
        : null;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: landscapeUi ? 44 : null,
        title: const Text('VoxLiso'),
        actions: [
          IconButton(
            tooltip: 'Tester sur une photo',
            icon: const Icon(Icons.document_scanner_outlined),
            onPressed: _controller == null ? null : _testPhoto,
          ),
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
        child: landscapeUi
            // Paysage : aperçu à gauche, commandes à droite.
            ? Row(children: [
                Expanded(child: Center(child: _buildPreview())),
                SizedBox(
                  width: 330,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (banner != null) banner,
                        ..._buildControls(theme),
                      ],
                    ),
                  ),
                ),
              ])
            // Portrait : aperçu en haut, commandes en bas.
            : Column(children: [
                Expanded(child: Center(child: _buildPreview())),
                if (banner != null) banner,
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _buildControls(theme),
                  ),
                ),
              ]),
      ),
    );
  }

  List<Widget> _buildControls(ThemeData theme) {
    return [
      _buildLastText(theme),
      if (_maxZoom > _minZoom) _buildZoom(),
      if (_maxExposure > _minExposure) _buildExposure(),
      const SizedBox(height: 8),
      SegmentedButton<String>(
        segments: [
          const ButtonSegment(
            value: 'auto',
            label: Text('Auto'),
            tooltip: 'Détection automatique de la langue',
          ),
          for (final l in kLanguages)
            ButtonSegment(value: l.code, label: Text(l.short), tooltip: l.label),
        ],
        selected: {s.lang},
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact),
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
    ];
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
    // Reconstruit l'aperçu à chaque changement d'orientation de la caméra,
    // pour que la bande jaune reste alignée sur l'image.
    return ValueListenableBuilder<CameraValue>(
      valueListenable: c,
      builder: (context, value, _) => _buildPreviewContent(c),
    );
  }

  Widget _buildPreviewContent(CameraController c) {
    return AspectRatio(
      aspectRatio: _landscape ? c.value.aspectRatio : 1 / c.value.aspectRatio,
      child: Stack(fit: StackFit.expand, children: [
        CameraPreview(c),
        RoiOverlay(
          top: _roiTop,
          bottom: _roiBottom,
          boxes: _boxes,
          onChanged: (t, b) => setState(() => _setRoi(t, b)),
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
                  maxLines: _diag.startsWith('⚠') ? 10 : 4,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (s.autoLang || s.translateTo.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                [
                  if (s.autoLang) 'Langue détectée : ${_voice.label}',
                  if (s.translateTo.isNotEmpty)
                    'lu en ${languageFor(s.translateTo).label}',
                ].join(' · '),
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.primary),
              ),
            ),
          Text(
            _lastSpoken.isEmpty ? hint : _lastSpoken,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: _lastSpoken.isEmpty
                ? theme.textTheme.bodyMedium
                : theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          if (_lastOriginal.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Original : $_lastOriginal',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (_translateWarning != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _translateWarning!,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
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
