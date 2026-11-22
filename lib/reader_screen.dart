import 'dart:async';
import 'dart:io' show File, Platform;
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'camera_input.dart';
import 'enhance.dart';
import 'history.dart';
import 'logo.dart';
import 'plus_screen.dart';
import 'premium.dart';
import 'language_detector.dart';
import 'languages.dart';
import 'roi_overlay.dart';
import 'reading_vote.dart';
import 'screen_capture.dart';
import 'sentence_joiner.dart';
import 'settings.dart';
import 'settings_sheet.dart';
import 'speech_service.dart';
import 'spell_fixer.dart';
import 'static_filter.dart';
import 'subtitle_locator.dart';
import 'subtitle_tracker.dart';
import 'system_bridge.dart';
import 'text_tools.dart';
import 'translator.dart';
import 'updater.dart';
import 'tutorial.dart';
import 'version.dart';
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

  /// Orientation de l'interface (mise à jour à chaque affichage).
  bool _uiLandscape = false;

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
  late bool _showDiag = !widget.settings.largeMode;
  bool _textOutsideOnly = false;

  double _exposure = 0;
  double _minExposure = 0;
  double _maxExposure = 0;
  String _lastSpoken = '';

  /// Texte d'origine quand [_lastSpoken] est une traduction.
  String _lastOriginal = '';
  String? _translateWarning;

  /// Moteur de la dernière traduction : « DeepL » ou « hors ligne ».
  String _translationEngine = '';

  final VoiceCatalog _catalog = VoiceCatalog();
  final SubtitleTranslator _translator = SubtitleTranslator();

  /// Les sous-titres sont traités l'un après l'autre (détection de langue,
  /// traduction) pour être dits dans l'ordre.
  Future<void> _speakChain = Future<void>.value();

  final SubtitleHistory _history = SubtitleHistory();

  /// Texte fixe (logo, heure, menu) : ignoré après 20 s sans changement.
  final StaticTextFilter _staticFilter = StaticTextFilter();

  /// Écran noir pendant la lecture.
  bool _dimmed = false;
  Timer? _dimTimer;
  static const Duration _dimDelay = Duration(seconds: 8);

  /// Nouvelle version disponible sur GitHub.
  UpdateInfo? _update;

  /// Correction des mots mal lus (dictionnaires par langue).
  final SpellFixer _spell = SpellFixer();

  /// Phrase coupée en attente de sa suite (traduction) : texte, langue et
  /// position de la réplique (pour garder la voix du bon personnage).
  ({String text, String lang, int index})? _held;
  Timer? _heldTimer;
  static const Duration _holdDelay = Duration(milliseconds: 3500);

  /// Repérage automatique des sous-titres en cours (null = inactif).
  SubtitleLocator? _locator;
  Timer? _locTimer;
  int _locSeconds = 0;
  bool _locScreenLandscape = false;

  // Lecture de l'écran du téléphone (Android).
  final ScreenCapture _screen = ScreenCapture();
  List<DetectedBox> _screenBoxes = const [];
  bool _screenBoxesLandscape = false;

  /// Bande d'écran affichée et réglée : portrait ou paysage.
  bool _screenEditLandscape = false;
  String? _error;
  bool _voiceMissing = false;

  double _zoom = 1;
  double _minZoom = 1;
  double _maxZoom = 1;

  AppSettings get s => widget.settings;

  /// Langue de traduction choisie, si VoxLiso Plus permet de traduire.
  String get _translateTo =>
      Premium.instance.has(PlusFeature.translation) ? s.translateTo : '';

  void _onPremium() {
    if (!mounted || _closed) return;
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _tracker = SubtitleTracker(stableFrames: s.stableFrames)
      // Dictionnaire de la langue lue : départage les lectures (« raisori » / « raison »).
      ..dictionary = () {
        final lang = s.autoLang ? _langDetector.current : s.lang;
        final list = _spell.loaded(lang);
        if (list == null) _spell.load(lang);
        return list;
      };
    // Mode Auto : les autres langues en alphabet latin (néerlandais, polonais…)
    // sont aussi reconnues, pour être traduites.
    _langDetector = LanguageDetector(
      s.detectedLang,
      accept: (code) =>
          kOtherLanguages.containsKey(code) && SubtitleTranslator.canTranslate(code),
    );
    _translator
      ..deeplKey = s.effectiveDeeplKey
      ..azureKey = s.effectiveAzureKey
      ..azureRegion = s.effectiveAzureRegion;
    _history.decode(s.historyJson);
    Premium.instance.addListener(_onPremium);
    // Lecture de l'écran réservée à VoxLiso Plus.
    if (s.screenSource && !Premium.instance.has(PlusFeature.screen)) s.source = 'camera';
    if (ScreenCapture.isAvailable) {
      _screen.listen();
      _screen.frames.listen(_onScreenFrame);
      _screen.stopped.listen((_) => _stopReading());
      _screen.isRunning().then((running) {
        // Capture restée active (application rouverte) : on reprend la lecture.
        if (running && s.screenSource && mounted) setState(() => _reading = true);
      });
    } else if (s.screenSource) {
      s.source = 'camera';
    }
    _speech.interrupt = s.interrupt;
    _speech.autoRate = s.autoRate;
    _speech.boost.addListener(_onBoost);
    _zoom = s.zoom;
    _start();
  }

  Future<void> _start() async {
    await _speech.init();
    if (s.ttsEngine.isNotEmpty) await _speech.setEngine(s.ttsEngine);
    _catalog.load(await _speech.rawVoices());
    _translator.refresh();
    _autoCheckUpdate();
    await _applyVoice();
    await _initCamera();
  }

  /// Vitesse automatique : la voix accélère, on l'affiche (« voix ×1,2 »).
  void _onBoost() {
    if (mounted && !_closed) setState(() {});
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
    if (_initializing || _controller != null || _closed || s.screenSource) return;
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

  /// Orientation utilisée pour l'analyse et l'aperçu. Elle suit l'interface :
  /// portrait = portrait (comme en 1.0.14, quoi que dise le module caméra) ;
  /// paysage = le côté indiqué par le capteur.
  DeviceOrientation get _orientation {
    if (!_uiLandscape) return DeviceOrientation.portraitUp;
    final c = _controller;
    if (c != null) {
      final d = c.value.deviceOrientation;
      if (isLandscape(d)) return d;
      final l = c.value.lockedCaptureOrientation;
      if (l != null && isLandscape(l)) return l;
    }
    return DeviceOrientation.landscapeLeft;
  }

  bool get _landscape => isLandscape(_orientation);

  /// Partie de l'image caméra visible dans l'aperçu 16:9 (fractions 0..1,
  /// image « à l'endroit »). Identité si la caméra filme déjà en 16:9.
  ({double ox, double oy, double vw, double vh}) get _crop {
    const full = (ox: 0.0, oy: 0.0, vw: 1.0, vh: 1.0);
    final c = _controller;
    if (c == null || !c.value.isInitialized) return full;
    final ar = c.value.aspectRatio; // largeur / hauteur, capteur en paysage
    final image = _landscape ? ar : 1 / ar;
    final display = _wide ? 16 / 9 : 9 / 16;
    if ((image - display).abs() < 0.01) return full;
    if (image > display) {
      final vw = display / image;
      return (ox: (1 - vw) / 2, oy: 0.0, vw: vw, vh: 1.0);
    }
    final vh = image / display;
    return (ox: 0.0, oy: (1 - vh) / 2, vw: 1.0, vh: vh);
  }

  /// Vue 16:9 : en paysage, et en portrait si le réglage est activé (par défaut).
  bool get _wide => _landscape || s.frame169;

  // La bande est réglée sur la vue affichée : une seule bande pour toutes les
  // vues 16:9 (portrait comme paysage), une autre pour la vue 9:16.
  double get _roiTop => _wide ? s.roiTopLandscape : s.roiTop;
  double get _roiBottom => _wide ? s.roiBottomLandscape : s.roiBottom;

  void _setRoi(double top, double bottom) {
    if (_wide) {
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
    _uiLandscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final locked = c.value.lockedCaptureOrientation;
    final want = _orientation;
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
    if (state != AppLifecycleState.resumed) _undim();
    // Mode écran : la lecture continue pendant que l'on regarde la vidéo.
    if (s.screenSource) return;
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
    // Image renforcée, pendant la lecture : chaque image est relue une 2e fois sur
    // la zone agrandie et contrastée, et les deux lectures sont comparées mot à mot.
    final enhance = s.enhance && _reading;
    final found = _handleResult(result, frame.uprightSize, info, ms, feedTracker: !enhance);
    if (!enhance) return;
    final second = await _enhancedPass(image, cam, showBoxes: found.inZone.isEmpty);
    if (_closed || !mounted) return;
    if (found.inZone.isNotEmpty) {
      _onLines(
        found.inZone.map((l) => l.text).toList(),
        confidence: _confidenceOf(found.inZone),
        alternative: second == null || second.isEmpty
            ? null
            : OcrReading(_keyed(second.map((l) => l.text).toList()),
                confidence: _confidenceOf(second)),
      );
    } else {
      // Rien dans la zone sur l'image normale : la lecture renforcée seule.
      final lines = second ?? const <TextLine>[];
      _onLines(lines.map((l) => l.text).toList(), confidence: _confidenceOf(lines));
    }
  }

  /// Confiance de ML Kit pour chaque mot (Android ; rien sur iPhone).
  static Map<String, double> _confidenceOf(Iterable<TextLine> lines) {
    final out = <String, double>{};
    for (final line in lines) {
      for (final e in line.elements) {
        final c = e.confidence;
        if (c == null) continue;
        final key = normalizeForCompare(e.text);
        if (key.isEmpty) continue;
        final prev = out[key];
        if (prev == null || c > prev) out[key] = c;
      }
    }
    return out;
  }

  /// 2e lecture de la zone seule, recadrée, contrastée et agrandie : pour les
  /// sous-titres pâles, à contour, lointains ou avec des reflets.
  /// Renvoie les lignes lues dans la zone (null si l'image n'a pas pu être lue).
  /// [showBoxes] : afficher ses cadres (quand l'image normale n'a rien trouvé).
  Future<List<TextLine>?> _enhancedPass(CameraImage image, CameraDescription cam,
      {required bool showBoxes}) async {
    final crop = _crop;
    final zone = Rect.fromLTRB(
      crop.ox + s.roiLeft * crop.vw,
      crop.oy + _roiTop * crop.vh,
      crop.ox + s.roiRight * crop.vw,
      crop.oy + _roiBottom * crop.vh,
    );
    final e = buildEnhancedInput(image, cam, _orientation, zone);
    if (e == null) return null;
    final RecognizedText result;
    final started = DateTime.now();
    try {
      result = await _recognizer.processImage(e.image);
    } catch (_) {
      return null;
    }
    if (_closed || !mounted) return null;
    final ms = DateTime.now().difference(started).inMilliseconds;
    final found = <(TextLine, Rect)>[];
    for (final block in result.blocks) {
      for (final line in block.lines) {
        final full = e.toFull(line.boundingBox);
        if (zone.contains(full.center)) found.add((line, full));
      }
    }
    found.sort((a, b) {
      final dy = a.$2.center.dy - b.$2.center.dy;
      if (dy.abs() < math.min(a.$2.height, b.$2.height) * 0.5) {
        return a.$2.left.compareTo(b.$2.left);
      }
      return dy < 0 ? -1 : 1;
    });
    final fixedIdx = s.ignoreStatic
        ? _staticFilter.update([for (final f in found) f.$1.text])
        : const <int>{};
    final kept = [
      for (var i = 0; i < found.length; i++)
        if (!fixedIdx.contains(i)) found[i],
    ];
    Rect toDisplay(Rect r) => Rect.fromLTRB(
          (r.left - crop.ox) / crop.vw,
          (r.top - crop.oy) / crop.vh,
          (r.right - crop.ox) / crop.vw,
          (r.bottom - crop.oy) / crop.vh,
        );
    setState(() {
      if (showBoxes) {
        _boxes = [
          ..._boxes,
          for (var i = 0; i < found.length; i++)
            DetectedBox(toDisplay(found[i].$2), !fixedIdx.contains(i),
                fixed: fixedIdx.contains(i)),
        ];
      }
      _diag = '$_diag\nImage renforcée : ${kept.length} ligne(s) lue(s) · ${ms}ms';
    });
    return [for (final k in kept) k.$1];
  }

  /// Exploite le résultat de l'OCR (flux vidéo ou photo) : cadres, diagnostic, lecture.
  /// Renvoie les lignes trouvées et celles retenues dans la zone.
  ({List<TextLine> all, List<TextLine> inZone}) _handleResult(
    RecognizedText result,
    Size upright,
    String info,
    int ms, {
    bool feedTracker = true,
  }) {
    final w = upright.width;
    final h = upright.height;
    final crop = _crop;
    // Bande jaune (fractions de l'aperçu 16:9) -> pixels de l'image analysée.
    final top = (crop.oy + _roiTop * crop.vh) * h;
    final bottom = (crop.oy + _roiBottom * crop.vh) * h;
    // Zone centrée : le texte des côtés (logos, heure, décor) est ignoré.
    final left = (crop.ox + s.roiLeft * crop.vw) * w;
    final right = (crop.ox + s.roiRight * crop.vw) * w;
    // Partie de l'image visible dans l'aperçu.
    final visible = Rect.fromLTRB(
        crop.ox * w, crop.oy * h, (crop.ox + crop.vw) * w, (crop.oy + crop.vh) * h);

    final all = <TextLine>[];
    final lines = <TextLine>[];
    for (final block in result.blocks) {
      for (final line in block.lines) {
        final r = line.boundingBox;
        // Hors de l'aperçu : ni affichée ni lue.
        if (!visible.contains(r.center)) continue;
        all.add(line);
        // Lue si son centre est entre les bords gauche et droit de la zone et
        // si au moins la moitié de sa hauteur est entre les bords haut et bas.
        if (r.center.dx < left || r.center.dx > right) continue;
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

    // Pixels de l'image -> fractions de l'aperçu 16:9 (pour les cadres).
    Rect frac(Rect r) => Rect.fromLTRB(
          (r.left / w - crop.ox) / crop.vw,
          (r.top / h - crop.oy) / crop.vh,
          (r.right / w - crop.ox) / crop.vw,
          (r.bottom / h - crop.oy) / crop.vh,
        );
    // Texte fixe (logo, heure, menu) : ignoré.
    final fixedIdx =
        s.ignoreStatic ? _staticFilter.update([for (final l in lines) l.text]) : const <int>{};
    final fixed = {for (final i in fixedIdx) lines[i]};
    if (fixed.isNotEmpty) lines.removeWhere(fixed.contains);
    final boxes = [
      for (final l in all)
        DetectedBox(frac(l.boundingBox), lines.contains(l), fixed: fixed.contains(l)),
    ];
    final rawText = lines.map((l) => l.text).join(' / ');
    setState(() {
      _boxes = boxes;
      _textOutsideOnly = lines.isEmpty && all.isNotEmpty;
      _diag = 'v$kAppVersion · ${_landscape ? 'paysage' : 'portrait'} · '
          '${s.photoMode ? 'Mode photo · ' : ''}$info · ${w.toInt()}×${h.toInt()} · ${ms}ms\n'
          'Texte trouvé : ${all.length} ligne(s), ${lines.length} dans la zone'
          '${fixed.isEmpty ? '' : ', ${fixed.length} fixe(s) ignorée(s)'}'
          '${rawText.isEmpty ? '' : '\n« $rawText »'}';
    });

    // Repérage automatique : toutes les lignes visibles, avec leur position.
    _locator?.add([for (final l in all) SeenLine(l.text, frac(l.boundingBox))]);

    if (_reading && feedTracker) {
      _onLines(lines.map((l) => l.text).toList(), confidence: _confidenceOf(lines));
    }
    return (all: all, inZone: lines);
  }

  /// Lignes lues -> texte suivi d'une image à l'autre : répliques séparées par
  /// [kPartSep], précédé de [kPartSep] si le sous-titre commence par un tiret.
  String _keyed(List<String> lineTexts) {
    final parts = subtitleParts(lineTexts, removeSoundTags: s.removeSoundTags);
    final firstLine =
        lineTexts.map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return joinParts(parts, dialogueStart: RegExp(r'^[-–—]').hasMatch(firstLine));
  }

  /// Lignes retenues dans la bande (caméra ou écran) -> sous-titre à dire.
  /// [confidence] : confiance de ML Kit par mot ; [alternative] : 2e lecture
  /// de la même image (image renforcée), comparée mot à mot à la première.
  void _onLines(List<String> lineTexts,
      {Map<String, double> confidence = const {}, OcrReading? alternative}) {
    final toSay = _tracker.push(
      _keyed(lineTexts),
      confidence: confidence,
      alternatives: [if (alternative != null) alternative],
    );
    if (toSay == null) return;
    final parts = splitParts(toSay);
    if (parts.isEmpty) return;
    final text = parts.join(' ');
    // Répliques séparées seulement si tout le sous-titre est nouveau
    // (pas pour la fin d'un sous-titre « en direct » qui défile).
    final full = _tracker.lastWasFull;
    final segments = s.dialogueVoices && parts.length > 1 && full ? parts : [text];
    // Un sous-titre qui commence par un tiret ouvre une nouvelle réplique :
    // ce n'est jamais la suite de la phrase précédente.
    final dialogueStart = full && startsWithDialogue(toSay);
    // Langue reconnue sur le sous-titre entier, même si seule sa fin est dite.
    final whole = full ? text : splitParts(_tracker.lastFull).join(' ');
    _speakChain = _speakChain
        .then((_) => _speakSubtitle(whole.isEmpty ? text : whole, segments,
            dialogueStart: dialogueStart))
        .catchError((Object _) {});
  }

  // ------------------------------------------------- écran du téléphone

  (double, double) _screenBand(bool landscape) => landscape
      ? (s.screenTopLandscape, s.screenBottomLandscape)
      : (s.screenTop, s.screenBottom);

  void _onScreenFrame(ScreenFrame f) {
    if (!s.screenSource || _closed) return;
    if (_locator != null) {
      _locScreenLandscape = f.landscape;
      _locator!.add([for (final l in f.lines) SeenLine(l.text, l.rect)]);
    }
    final (top, bottom) = _screenBand(f.landscape);
    final inZone = <ScreenLine>[];
    for (final l in f.lines) {
      final r = l.rect;
      final overlap = math.min(r.bottom, bottom) - math.max(r.top, top);
      if (r.height > 0 && overlap >= r.height * 0.5) inZone.add(l);
    }
    inZone.sort((a, b) {
      final dy = a.rect.center.dy - b.rect.center.dy;
      if (dy.abs() < math.min(a.rect.height, b.rect.height) * 0.5) {
        return a.rect.left.compareTo(b.rect.left);
      }
      return dy < 0 ? -1 : 1;
    });
    final fixedIdx =
        s.ignoreStatic ? _staticFilter.update([for (final l in inZone) l.text]) : const <int>{};
    final fixed = {for (final i in fixedIdx) inZone[i]};
    if (fixed.isNotEmpty) inZone.removeWhere(fixed.contains);
    final raw = inZone.map((l) => l.text).join(' / ');
    if (mounted) {
      setState(() {
        _screenBoxes = [
          for (final l in f.lines)
            DetectedBox(l.rect, inZone.contains(l), fixed: fixed.contains(l)),
        ];
        _screenBoxesLandscape = f.landscape;
        _diag = 'Écran du téléphone (${f.landscape ? 'paysage' : 'portrait'})\n'
            'Texte trouvé : ${f.lines.length} ligne(s), ${inZone.length} dans la zone'
            '${fixed.isEmpty ? '' : ', ${fixed.length} fixe(s) ignorée(s)'}'
            '${raw.isEmpty ? '' : '\n« $raw »'}';
      });
    }
    if (_reading) _onLines(inZone.map((l) => l.text).toList());
  }

  Future<void> _setSource(String source) async {
    if (source == s.source) return;
    if (source == 'screen' && !Premium.instance.has(PlusFeature.screen)) {
      await openPlusScreen(context, reason: PlusFeature.screen);
      if (!mounted || !Premium.instance.has(PlusFeature.screen)) return;
    }
    if (_reading) await _stopReadingAsync();
    s.source = source;
    _tracker.reset();
    _staticFilter.reset();
    if (source == 'screen') {
      await _releaseCamera();
    } else {
      await _initCamera();
    }
    if (mounted) setState(() {});
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
    final chosenPitch = s.pitch2For(lang);
    if (second == null || second.key == first?.key) {
      // Même voix que le 1er personnage : plus grave pour les distinguer.
      return (voice: first, pitch: chosenPitch ?? s.pitchFor(lang) * 0.8);
    }
    return (voice: second, pitch: chosenPitch ?? 1.0);
  }

  /// Identifie la langue (mode Auto), traduit si demandé, puis dit le
  /// sous-titre : une voix par réplique dans les dialogues.
  Future<void> _speakSubtitle(String fullText, List<String> segments,
      {bool dialogueStart = false}) async {
    final before = _langDetector.current;
    final lang = s.autoLang ? await _langDetector.detect(fullText) : s.lang;
    if (_closed || !_reading) return;
    // Mots mal lus corrigés avec le dictionnaire de la langue (« corne » -> « come »).
    if (s.spellFix && SpellFixer.languages.contains(lang)) {
      final list = await _spell.load(lang);
      if (list != null) segments = [for (final t in segments) SpellFixer.fix(t, list)];
    }
    if (s.autoLang && lang != before) {
      s.detectedLang = lang;
      if (isReadLanguage(lang)) {
        final ok = await _speech.isAvailable(languageFor(lang).ttsLocale);
        if (mounted && !_closed) setState(() => _voiceMissing = !ok);
      } else if (mounted && !_closed) {
        setState(() {}); // affiche la langue détectée
      }
    }

    final target = _targetFor(lang);
    if (target.isEmpty || target == lang) {
      // Pas de traduction : une éventuelle phrase en attente part d'abord.
      await _flushHeld();
      await _translateAndSay(lang, segments);
      return;
    }

    // Traduction : une phrase coupée entre deux sous-titres est traduite en entier.
    final segs = List<String>.of(segments);
    var firstIndex = 0;
    final held = _held;
    if (held != null) {
      _heldTimer?.cancel();
      _held = null;
      if (held.lang == lang && !dialogueStart && segs.isNotEmpty) {
        segs[0] = SentenceJoiner.join(held.text, segs[0]);
        firstIndex = held.index;
      } else {
        await _translateAndSay(held.lang, [held.text], firstIndex: held.index);
      }
    }
    // (longueur plafonnée : une phrase qui ne finit jamais n'est pas retenue sans fin)
    if (segs.isNotEmpty && segs.last.length < 220 && SentenceJoiner.isIncomplete(segs.last, lang)) {
      final index = firstIndex + segs.length - 1;
      _held = (text: segs.removeLast(), lang: lang, index: index);
      _heldTimer = Timer(_holdDelay, () {
        // Pas de suite à temps : le morceau est traduit seul.
        _speakChain = _speakChain.then((_) => _flushHeld()).catchError((Object _) {});
      });
    }
    if (segs.isEmpty) return;
    await _translateAndSay(lang, segs, firstIndex: firstIndex);
  }

  /// Langue dans laquelle lire un sous-titre de langue [lang] ('' = pas de traduction) :
  /// celle choisie dans « Traduction » ; sinon, une langue autre que
  /// fr/de/es/it/en/pt (néerlandais, polonais…) est traduite automatiquement.
  /// Sans VoxLiso Plus, pas de traduction : lecture dans la langue d'origine.
  String _targetFor(String lang) {
    if (!Premium.instance.has(PlusFeature.translation)) return '';
    var target = s.translateTo;
    if (target.isEmpty && !isReadLanguage(lang)) target = s.autoTranslateTo;
    return target;
  }

  /// Traduit et dit la phrase en attente (délai écoulé, ou avant une autre lecture).
  Future<void> _flushHeld() async {
    final h = _held;
    if (h == null) return;
    _heldTimer?.cancel();
    _held = null;
    if (_closed || !_reading) return;
    await _translateAndSay(h.lang, [h.text], firstIndex: h.index);
  }

  /// Traduit si besoin puis dit les répliques [segments] (langue [lang]).
  /// [firstIndex] : position de la 1re réplique, pour la voix du personnage.
  Future<void> _translateAndSay(String lang, List<String> segments, {int firstIndex = 0}) async {
    if (_closed || !_reading || segments.isEmpty) return;
    var speakLang = lang;
    var out = segments;
    String? warning;
    final target = _targetFor(lang);
    if (target.isNotEmpty && target != lang) {
      final result = await _translator.translateAll(segments, lang, target);
      if (result != null) {
        out = result.texts;
        speakLang = target;
        _translationEngine = result.engine;
        // Azure ou DeepL réglé mais indisponible : on le signale, la lecture continue.
        if (result.engine == 'hors ligne' &&
            (s.effectiveAzureKey.isNotEmpty || s.effectiveDeeplKey.isNotEmpty)) {
          warning = _translator.azureError ?? _translator.deeplError;
        }
      } else if (_translator.autoDownloading.isNotEmpty) {
        warning = 'Téléchargement de ${_translator.autoDownloading.map(languageName).join(' et ')} '
            'pour la traduction (en Wi-Fi). En attendant : lecture dans la langue d\'origine.';
      } else {
        warning = _translator.azureError ??
            _translator.deeplError ??
            'Traduction impossible : téléchargez ${languageName(lang)} et '
                '${languageName(target)} dans les réglages (section Traduction).';
      }
    }
    if (_closed || !_reading) return;

    // Langue lue par une voix (fr/de/es/it/en/pt) : sa voix ; autre langue non
    // traduite : la voix du téléphone pour cette langue, si elle existe.
    final locale = isReadLanguage(speakLang) ? languageFor(speakLang).ttsLocale : speakLang;
    final first = _primaryVoice(speakLang);
    final second = _secondVoice(speakLang);
    _speech.sayAll([
      for (var i = 0; i < out.length; i++)
        Utterance(
          out[i],
          locale: locale,
          voice: (firstIndex + i).isOdd ? second.voice : first,
          pitch: (firstIndex + i).isOdd ? second.pitch : s.pitchFor(speakLang),
        ),
    ]);
    if (s.largeMode) HapticFeedback.lightImpact();
    _history.add(HistoryEntry(
      time: DateTime.now(),
      text: out.join(' '),
      lang: speakLang,
      original: speakLang != lang ? segments.join(' ') : '',
      originalLang: speakLang != lang ? lang : '',
    ));
    s.historyJson = _history.encode();
    if (mounted && !_closed) {
      setState(() {
        _lastSpoken = out.join(' ');
        _lastOriginal = speakLang != lang ? segments.join(' ') : '';
        _translateWarning = warning;
      });
    }
  }

  // ------------------------------------------------ repérage automatique

  /// Observe l'écran quelques secondes et place la zone sur le texte qui change.
  Future<void> _startLocate() async {
    if (_locator != null) return;
    if (s.screenSource && !_reading) {
      await _toggleReading();
      if (!_reading) return;
    }
    _undim();
    setState(() {
      _locator = SubtitleLocator();
      _locSeconds = 0;
    });
    _announce('Repérage des sous-titres');
    _locTimer?.cancel();
    _locTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      final loc = _locator;
      if (!mounted || _closed || loc == null) {
        t.cancel();
        return;
      }
      _locSeconds++;
      final enough = _locSeconds >= 5 && loc.frames >= 10 && loc.distinctChanging >= 3;
      final limit = s.screenSource ? 30 : 12;
      if (enough || _locSeconds >= limit) {
        t.cancel();
        _finishLocate();
      } else {
        setState(() {});
      }
    });
  }

  void _cancelLocate() {
    _locTimer?.cancel();
    setState(() => _locator = null);
  }

  void _finishLocate() {
    final loc = _locator;
    if (loc == null) return;
    final z = loc.result();
    setState(() => _locator = null);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (z == null) {
      messenger?.showSnackBar(const SnackBar(
        duration: Duration(seconds: 8),
        content: Text('Aucun sous-titre repéré. Lancez un passage où les sous-titres '
            'défilent, gardez le téléphone immobile et réessayez.'),
      ));
      _announce('Aucun sous-titre repéré');
      return;
    }
    setState(() {
      if (s.screenSource) {
        _screenEditLandscape = _locScreenLandscape;
        if (_locScreenLandscape) {
          s.screenTopLandscape = z.top;
          s.screenBottomLandscape = z.bottom;
        } else {
          s.screenTop = z.top;
          s.screenBottom = z.bottom;
        }
      } else {
        _setRoi(z.top, z.bottom);
        s.roiLeft = z.left;
        s.roiRight = z.right;
      }
    });
    messenger?.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text('Zone placée sur les sous-titres (${z.subtitles} sous-titre(s) observé(s)). '
          'Ajustez-la avec les poignées si besoin.'),
    ));
    _announce('Zone placée sur les sous-titres');
  }

  Widget _buildLocateButton() {
    final running = _locator != null;
    final limit = s.screenSource ? 30 : 12;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      OutlinedButton.icon(
        onPressed: running ? _cancelLocate : _startLocate,
        icon: Icon(running ? Icons.close : Icons.center_focus_strong),
        label: Text(running
            ? 'Repérage… $_locSeconds s (toucher pour annuler)'
            : 'Repérer les sous-titres'),
      ),
      if (running) ...[
        const SizedBox(height: 4),
        LinearProgressIndicator(value: (_locSeconds / limit).clamp(0.0, 1.0).toDouble()),
        const SizedBox(height: 2),
        Text(
          s.screenSource
              ? 'Ouvrez votre vidéo avec les sous-titres : la zone sera placée toute seule.'
              : 'Gardez le téléphone immobile, avec des sous-titres à l\'écran.',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    ]);
  }

  // ------------------------------------------------------- écran noir

  /// Écran noir activé dans les réglages (fonction VoxLiso Plus).
  bool get _blackScreenOn => s.blackScreen && Premium.instance.has(PlusFeature.blackScreen);

  /// Programme l'écran noir après quelques secondes sans toucher l'écran.
  void _scheduleDim() {
    _dimTimer?.cancel();
    if (!_reading || !_blackScreenOn || s.screenSource) return;
    _dimTimer = Timer(_dimDelay, () {
      if (!mounted || _closed || !_reading || !_blackScreenOn) return;
      setState(() => _dimmed = true);
      SystemBridge.setBrightness(0.01);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    });
  }

  /// Rallume l'écran (toucher), puis le réassombrit plus tard.
  void _wake() {
    if (_dimmed) {
      setState(() => _dimmed = false);
      SystemBridge.setBrightness(-1);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _scheduleDim();
  }

  /// Fin de l'écran noir (lecture arrêtée, application en arrière-plan).
  void _undim() {
    _dimTimer?.cancel();
    if (!_dimmed) return;
    _dimmed = false;
    SystemBridge.setBrightness(-1);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (mounted && !_closed) setState(() {});
  }

  Widget _buildDimmed() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Semantics(
        button: true,
        label: 'Lecture des sous-titres en cours. Touchez pour rallumer l\'écran.',
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _wake,
          child: const SizedBox.expand(
            child: Center(
              child: Text(
                'VoxLiso lit les sous-titres\nTouchez l\'écran pour l\'afficher',
                textAlign: TextAlign.center,
                style: TextStyle(color: Color(0xFF2B2B2B), fontSize: 14),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------- mises à jour

  /// Au démarrage : au plus une vérification toutes les 6 heures.
  Future<void> _autoCheckUpdate() async {
    if (!Updater.supported) return;
    await Updater.cleanUp(s); // APK de la mise à jour déjà installée : effacé
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - s.lastUpdateCheck < const Duration(hours: 6).inMilliseconds) return;
    try {
      final info = await Updater.check();
      s.lastUpdateCheck = now;
      if (info != null && info.version != s.skippedVersion && mounted) {
        setState(() => _update = info);
      }
    } catch (_) {}
  }

  /// Bouton « Rechercher une mise à jour » des réglages.
  Future<String> _manualCheckUpdate() async {
    if (!Updater.supported) return 'Mises à jour automatiques indisponibles sur cet appareil.';
    try {
      final info = await Updater.check();
      s.lastUpdateCheck = DateTime.now().millisecondsSinceEpoch;
      if (info == null) return 'VoxLiso est à jour (version $kAppVersion).';
      s.skippedVersion = '';
      if (mounted) setState(() => _update = info);
      return 'Version ${info.version} disponible : touchez « Mettre à jour » en haut de l\'écran.';
    } catch (_) {
      return 'Impossible de joindre GitHub : vérifiez la connexion internet.';
    }
  }

  /// Téléchargement de mise à jour en cours (une seule fois à la fois).
  bool _updating = false;

  Future<void> _runUpdate(UpdateInfo info) async {
    if (_updating) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Téléchargement déjà en cours : voir la notification d\'Android.')));
      return;
    }
    _updating = true;
    try {
      await _downloadAndInstall(info);
    } finally {
      _updating = false;
    }
  }

  Future<void> _downloadAndInstall(UpdateInfo info) async {
    final progress = ValueNotifier<(double?, String)>((null, 'Téléchargement…'));
    var dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('Mise à jour vers ${info.version}'),
        content: ValueListenableBuilder<(double?, String)>(
          valueListenable: progress,
          builder: (context, v, child) => Column(mainAxisSize: MainAxisSize.min, children: [
            LinearProgressIndicator(value: v.$1),
            const SizedBox(height: 12),
            Text(v.$2),
            const SizedBox(height: 8),
            Text(
              'Le téléchargement continue écran éteint ou si vous quittez VoxLiso '
              '(progression dans les notifications).',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () {
              dialogOpen = false;
              Navigator.of(ctx).pop();
            },
            child: const Text('Masquer'),
          ),
        ],
      ),
    ).then((_) => dialogOpen = false);
    String? path;
    try {
      path = await Updater.download(info, s, (p, text) => progress.value = (p, text));
    } catch (_) {}
    if (!mounted) return;
    if (dialogOpen) {
      dialogOpen = false;
      Navigator.of(context, rootNavigator: true).pop();
    }
    final messenger = ScaffoldMessenger.of(context);
    final browser = SnackBarAction(
      label: 'Navigateur',
      onPressed: () => SystemBridge.openUrl(info.url),
    );
    if (path == null) {
      messenger.showSnackBar(SnackBar(
        content: const Text('Téléchargement impossible : vérifiez la connexion internet.'),
        action: browser,
      ));
      return;
    }
    // Android demande de confirmer l'installation : seulement avec VoxLiso à l'écran
    // (si le téléchargement s'est fini écran éteint, on attend le retour dans l'application).
    await _untilVisible();
    if (!mounted) return;
    final ok = await Updater.install(path);
    if (!mounted) return;
    setState(() => _update = null);
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 8),
      content: Text(ok
          ? 'Android va demander de confirmer la mise à jour. La première fois, '
              'autorisez VoxLiso à installer des applications, puis revenez.'
          : 'Installation impossible depuis VoxLiso : ouvrez le fichier dans le navigateur.'),
      action: ok ? null : browser,
    ));
  }

  /// Attend que VoxLiso soit au premier plan, écran allumé.
  Future<void> _untilVisible() async {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) return;
    final done = Completer<void>();
    final listener = AppLifecycleListener(onResume: () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    listener.dispose();
  }

  Widget _buildUpdateBanner(UpdateInfo info) => MaterialBanner(
        leading: const Icon(Icons.system_update),
        content: Text('VoxLiso ${info.version} est disponible.'),
        actions: [
          TextButton(
            onPressed: () => setState(() {
              s.skippedVersion = info.version;
              _update = null;
            }),
            child: const Text('Plus tard'),
          ),
          FilledButton(
            onPressed: () => _runUpdate(info),
            child: const Text('Mettre à jour'),
          ),
        ],
      );

  /// Redit une phrase (historique ou bouton « Répéter »).
  void _replay(HistoryEntry e) {
    _speech.say(
      e.text,
      locale: isReadLanguage(e.lang) ? languageFor(e.lang).ttsLocale : e.lang,
      voice: _primaryVoice(e.lang),
      pitch: s.pitchFor(e.lang),
    );
  }

  Future<void> _openHistory() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => HistoryScreen(
        history: _history,
        large: s.largeMode,
        onReplay: _replay,
        onChanged: () => s.historyJson = _history.encode(),
      ),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _openTutorial() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (ctx) => TutorialScreen(settings: s, onDone: () => Navigator.of(ctx).pop()),
    ));
    if (mounted) setState(() {});
  }

  /// Annonce vocale en mode grands boutons (en français, langue de l'interface).
  void _announce(String message) {
    if (!s.largeMode) return;
    _speech.say(message, locale: 'fr-FR', voice: _primaryVoice('fr'));
  }

  // ----------------------------------------------- zone sans glisser

  (double, double) get _zone => s.screenSource
      ? _screenBand(_screenEditLandscape)
      : (_roiTop, _roiBottom);

  void _setZone(double top, double bottom) {
    if (!s.screenSource) {
      _setRoi(top, bottom);
    } else if (_screenEditLandscape) {
      s.screenTopLandscape = top;
      s.screenBottomLandscape = bottom;
    } else {
      s.screenTop = top;
      s.screenBottom = bottom;
    }
  }

  /// Boutons « Monter / Descendre / Agrandir / Réduire » (TalkBack, malvoyants).
  /// Plus étroite / plus large (caméra) : rapproche ou écarte les bords gauche et droit.
  void _widenZone(double delta) {
    var l = s.roiLeft - delta / 2;
    var r = s.roiRight + delta / 2;
    if (r - l < 0.2) {
      final mid = (l + r) / 2;
      l = mid - 0.1;
      r = mid + 0.1;
    }
    l = l.clamp(0.0, 0.8).toDouble();
    r = r.clamp(l + 0.2, 1.0).toDouble();
    HapticFeedback.selectionClick();
    setState(() {
      s.roiLeft = l;
      s.roiRight = r;
    });
    _announce('Zone de ${(l * 100).round()} à ${(r * 100).round()} pour cent en largeur');
  }

  void _nudgeZone({double move = 0, double grow = 0}) {
    var (top, bottom) = _zone;
    top += move - grow / 2;
    bottom += move + grow / 2;
    if (bottom - top < 0.08) {
      final mid = (top + bottom) / 2;
      top = mid - 0.04;
      bottom = mid + 0.04;
    }
    if (top < 0) {
      bottom -= top;
      top = 0;
    }
    if (bottom > 1) {
      top -= bottom - 1;
      bottom = 1;
    }
    top = top.clamp(0.0, 0.92).toDouble();
    bottom = bottom.clamp(top + 0.08, 1.0).toDouble();
    HapticFeedback.selectionClick();
    setState(() => _setZone(top, bottom));
    _announce('Zone de ${(top * 100).round()} à ${(bottom * 100).round()} pour cent');
  }

  void _setDiag(String text) {
    if (mounted && !_closed) setState(() => _diag = text);
  }

  // ---------------------------------------------------------- commandes

  Future<void> _toggleReading() async {
    HapticFeedback.mediumImpact();
    if (_reading) {
      await _stopReadingAsync();
      _announce('Lecture arrêtée');
      return;
    }
    _tracker
      ..stableFrames = s.stableFrames
      ..reset();
    if (s.screenSource) {
      final ok = await _screen.start();
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("Capture de l'écran refusée : la lecture ne peut pas démarrer."),
        ));
        return;
      }
      setState(() => _reading = true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        duration: Duration(seconds: 6),
        content: Text('Ouvrez maintenant votre vidéo (YouTube, navigateur…) avec les '
            'sous-titres activés. Pour arrêter : notification VoxLiso > Arrêter.'),
      ));
      _announce('Lecture démarrée. Ouvrez maintenant votre vidéo.');
    } else {
      WakelockPlus.enable();
      setState(() => _reading = true);
      _announce('Lecture démarrée');
      _scheduleDim();
    }
  }

  void _stopReading() {
    _stopReadingAsync();
  }

  Future<void> _stopReadingAsync() async {
    if (!_reading) return;
    _undim();
    _heldTimer?.cancel();
    _held = null;
    if (mounted && !_closed) setState(() => _reading = false);
    _speech.stop();
    WakelockPlus.disable();
    if (s.screenSource) await _screen.stop();
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
        onEngineChanged: (engine) async {
          s.ttsEngine = engine;
          await _speech.setEngine(engine);
          await _applyVoice();
          _catalog.load(await _speech.rawVoices());
        },
        onInstallVoices: () => SystemBridge.installVoices(s.ttsEngine),
        onPreviewVoice: (lang, voice, pitch) => _speech.say(
          languageFor(lang).sample,
          locale: languageFor(lang).ttsLocale,
          voice: voice,
          pitch: pitch,
        ),
        onResetZone: () => setState(s.resetZones),
        onCheckUpdate: _manualCheckUpdate,
        onTutorial: () {
          Navigator.of(context).pop();
          _openTutorial();
        },
      ),
    );
    _speech.interrupt = s.interrupt;
    _speech.autoRate = s.autoRate;
    _scheduleDim(); // écran noir activé ou désactivé dans les réglages
    _tracker.stableFrames = s.stableFrames;
    _translator
      ..deeplKey = s.effectiveDeeplKey
      ..azureKey = s.effectiveAzureKey
      ..azureRegion = s.effectiveAzureRegion;
    if (s.photoMode != wasPhoto) await _applyAnalysisMode();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    Premium.instance.removeListener(_onPremium);
    _releaseCamera();
    _recognizer.close();
    _langDetector.close();
    _translator.close();
    _screen.dispose();
    _dimTimer?.cancel();
    _locTimer?.cancel();
    _heldTimer?.cancel();
    _speech.boost.removeListener(_onBoost);
    if (_dimmed) {
      SystemBridge.setBrightness(-1);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _speech.stop();
    WakelockPlus.disable();
    super.dispose();
  }

  // ------------------------------------------------------------- interface

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final landscapeUi = MediaQuery.orientationOf(context) == Orientation.landscape;
    _uiLandscape = landscapeUi;
    if (_dimmed) return _buildDimmed();
    final banner = _voiceMissing
        ? MaterialBanner(
            content: Text(
              'La voix « ${_voice.label} » n\'est pas installée sur ce téléphone. '
              'Installez-la dans les réglages de synthèse vocale du téléphone.',
            ),
            actions: const [SizedBox.shrink()],
          )
        : null;

    // Tout toucher repousse l'écran noir.
    return Listener(
      onPointerDown: (_) => _scheduleDim(),
      child: Scaffold(
      appBar: AppBar(
        toolbarHeight: landscapeUi ? 44 : null,
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          LogoMark(size: landscapeUi ? 26 : 30),
          const SizedBox(width: 10),
          Wordmark(fontSize: landscapeUi ? 19 : 22),
        ]),
        actions: [
          IconButton(
            tooltip: 'Historique des sous-titres',
            icon: const Icon(Icons.history),
            onPressed: _openHistory,
          ),
          if (!s.screenSource)
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
        child: Column(children: [
          if (_update != null) _buildUpdateBanner(_update!),
          Expanded(
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
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _buildControls(theme),
                    ),
                  ),
                ),
              ]),
          ),
        ]),
      ),
      ),
    );
  }

  List<Widget> _buildControls(ThemeData theme) {
    final large = s.largeMode;
    final a11y = large || MediaQuery.accessibleNavigationOf(context);
    final controls = <Widget>[
      _buildLastText(theme),
      if (large && _history.last != null) ...[
        const SizedBox(height: 8),
        SizedBox(
          height: 64,
          child: FilledButton.tonalIcon(
            onPressed: () => _replay(_history.last!),
            icon: const Icon(Icons.replay, size: 30),
            label: const Text('Répéter la dernière phrase', style: TextStyle(fontSize: 20)),
          ),
        ),
      ],
      if (ScreenCapture.isAvailable) ...[
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'camera',
              icon: Icon(Icons.videocam_outlined),
              label: Text('Caméra'),
              tooltip: 'Sous-titres de la télé ou de l\'ordinateur',
            ),
            ButtonSegment(
              value: 'screen',
              icon: Icon(Icons.smartphone),
              label: Text('Écran du téléphone'),
              tooltip: 'Vidéos regardées sur ce téléphone (YouTube, navigateur…)',
            ),
          ],
          selected: {s.source},
          showSelectedIcon: false,
          onSelectionChanged: (v) => _setSource(v.first),
        ),
      ],
      const SizedBox(height: 8),
      _buildLocateButton(),
      if (!s.screenSource && _maxZoom > _minZoom) _buildZoom(),
      if (!s.screenSource && _maxExposure > _minExposure) _buildExposure(),
      if (a11y) ...[
        const SizedBox(height: 8),
        _buildZoneButtons(large),
      ],
      const SizedBox(height: 8),
      FittedBox(
        fit: BoxFit.scaleDown,
        child: SegmentedButton<String>(
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
        style: ButtonStyle(
          visualDensity: large ? VisualDensity.standard : VisualDensity.compact,
          minimumSize: large ? const WidgetStatePropertyAll(Size(0, 56)) : null,
        ),
        onSelectionChanged: (v) => _setLanguage(v.first),
      ),
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: large ? 104 : 64,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: _reading ? Colors.red.shade700 : null,
            textStyle: TextStyle(fontSize: large ? 28 : 20, fontWeight: FontWeight.bold),
          ),
          onPressed: s.screenSource || _controller != null ? _toggleReading : null,
          icon: Icon(_reading ? Icons.stop : Icons.record_voice_over, size: large ? 40 : 28),
          label: Text(_reading ? 'Arrêter la lecture' : 'Lire les sous-titres'),
        ),
      ),
    ];
    if (!large) return controls;
    // Mode grands boutons : textes agrandis dans le panneau de commandes.
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return [
      MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(math.max(scale, 1.3))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: controls),
      ),
    ];
  }

  Widget _buildZoneButtons(bool large) {
    final (top, bottom) = _zone;
    Widget b(String label, IconData icon, VoidCallback onTap) => Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: SizedBox(
              height: large ? 64 : 48,
              child: OutlinedButton(
                onPressed: onTap,
                style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
                child: Semantics(
                  label: label,
                  excludeSemantics: true,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon),
                    Text(label, style: const TextStyle(fontSize: 12), maxLines: 1),
                  ]),
                ),
              ),
            ),
          ),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        'Zone des sous-titres : de ${(top * 100).round()} à ${(bottom * 100).round()} %'
        '${s.screenSource ? (_screenEditLandscape ? ' (paysage)' : ' (portrait)') : ''}',
      ),
      const SizedBox(height: 4),
      Row(children: [
        b('Monter', Icons.arrow_upward, () => _nudgeZone(move: -0.04)),
        b('Descendre', Icons.arrow_downward, () => _nudgeZone(move: 0.04)),
        b('Agrandir', Icons.unfold_more, () => _nudgeZone(grow: 0.06)),
        b('Réduire', Icons.unfold_less, () => _nudgeZone(grow: -0.06)),
      ]),
      if (!s.screenSource) ...[
        const SizedBox(height: 6),
        Row(children: [
          b('Plus étroite', Icons.width_normal, () => _widenZone(-0.1)),
          b('Plus large', Icons.width_wide, () => _widenZone(0.1)),
        ]),
      ],
    ]);
  }

  Widget _buildPreview() {
    if (s.screenSource) return _buildScreenPanel();
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
    final o = _orientation;
    final land = isLandscape(o);
    final ar = c.value.aspectRatio;
    // Sur Android, l'image du module caméra doit être tournée selon l'orientation
    // (comme le fait CameraPreview) ; sur iPhone elle l'est déjà.
    final turns = Platform.isAndroid
        ? const {
              DeviceOrientation.portraitUp: 0,
              DeviceOrientation.landscapeRight: 1,
              DeviceOrientation.portraitDown: 2,
              DeviceOrientation.landscapeLeft: 3,
            }[o] ??
            0
        : 0;
    final imageAspect = land ? ar : 1 / ar;
    return AspectRatio(
      aspectRatio: _wide ? 16 / 9 : 9 / 16,
      child: Stack(fit: StackFit.expand, children: [
        ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: 1000 * imageAspect,
              height: 1000,
              child: RotatedBox(quarterTurns: turns, child: c.buildPreview()),
            ),
          ),
        ),
        RoiOverlay(
          top: _roiTop,
          bottom: _roiBottom,
          left: s.roiLeft,
          right: s.roiRight,
          boxes: _boxes,
          onChanged: (t, b) => setState(() => _setRoi(t, b)),
          onHorizontalChanged: (l, r) => setState(() {
            s.roiLeft = l;
            s.roiRight = r;
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

  /// Mode « Écran du téléphone » : schéma du téléphone avec la bande à régler.
  Widget _buildScreenPanel() {
    final theme = Theme.of(context);
    final land = _screenEditLandscape;
    final (top, bottom) = _screenBand(land);
    final boxes = _screenBoxesLandscape == land ? _screenBoxes : const <DetectedBox>[];
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, icon: Icon(Icons.stay_current_portrait), label: Text('Portrait')),
            ButtonSegment(value: true, icon: Icon(Icons.stay_current_landscape), label: Text('Plein écran')),
          ],
          selected: {land},
          showSelectedIcon: false,
          onSelectionChanged: (v) => setState(() => _screenEditLandscape = v.first),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Center(
            child: AspectRatio(
              aspectRatio: land ? 19.5 / 9 : 9 / 19.5,
              child: Container(
                decoration: BoxDecoration(
                  color: kBrandNavy,
                  border: Border.all(color: theme.colorScheme.outline, width: 3),
                  borderRadius: BorderRadius.circular(18),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(fit: StackFit.expand, children: [
                  // Emplacement typique de la vidéo.
                  if (!land)
                    const Align(
                      alignment: Alignment(0, -0.62),
                      child: FractionallySizedBox(
                        heightFactor: 0.28,
                        widthFactor: 1,
                        child: ColoredBox(color: Color(0xFF2A3A6B)),
                      ),
                    )
                  else
                    const ColoredBox(color: Color(0xFF2A3A6B)),
                  RoiOverlay(
                    top: top,
                    bottom: bottom,
                    boxes: boxes,
                    onChanged: (t, b) => setState(() {
                      if (land) {
                        s.screenTopLandscape = t;
                        s.screenBottomLandscape = b;
                      } else {
                        s.screenTop = t;
                        s.screenBottom = b;
                      }
                    }),
                    onChangeEnd: () {},
                  ),
                  if (_showDiag)
                    Positioned(
                      left: 4,
                      right: 4,
                      bottom: 4,
                      child: IgnorePointer(
                        child: Text(
                          _diag,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 10),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _reading
              ? 'Lecture en cours : ouvrez votre vidéo avec les sous-titres activés.'
              : 'Placez la bande là où les sous-titres apparaissent sur votre écran '
                  '(portrait et plein écran se règlent séparément), puis appuyez sur « Lire ».',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
        Text(
          'Fonctionne avec YouTube, le navigateur, vos vidéos… '
          'Pas avec Netflix, Disney+ ni Prime Video (écran protégé).',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
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
        : s.screenSource
        ? 'Appuyez sur « Lire », autorisez la capture, puis ouvrez votre vidéo.'
        : 'Visez l\'écran, placez la bande jaune sur les sous-titres, puis appuyez sur « Lire ».';
    final boost = _speech.boost.value;
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
          if (s.autoLang || _translateTo.isNotEmpty || boost > 1.0)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                [
                  if (s.autoLang) 'Langue détectée : ${languageName(_langDetector.current)}',
                  if (_translateTo.isNotEmpty)
                    'lu en ${languageFor(_translateTo).label}'
                        '${_lastOriginal.isNotEmpty && _translationEngine.isNotEmpty ? ' ($_translationEngine)' : ''}',
                  if (boost > 1.0) 'voix accélérée ×${boost.toStringAsFixed(2).replaceAll('.', ',')}',
                ].join(' · '),
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.primary),
              ),
            ),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(
                _lastSpoken.isEmpty ? hint : _lastSpoken,
                maxLines: s.largeMode ? 4 : 3,
                overflow: TextOverflow.ellipsis,
                style: _lastSpoken.isEmpty
                    ? theme.textTheme.bodyMedium
                    : (s.largeMode ? theme.textTheme.headlineSmall : theme.textTheme.titleMedium)
                        ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            if (!s.largeMode && _history.last != null)
              IconButton(
                tooltip: 'Répéter la dernière phrase',
                icon: const Icon(Icons.replay),
                onPressed: () => _replay(_history.last!),
              ),
          ]),
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
