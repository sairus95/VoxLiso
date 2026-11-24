// Traducteur du téléphone (Android) : Bergamot, le traducteur de Firefox,
// appelé par dart:ffi à travers l'interface C de native/bergamot/capi.
//
// La traduction bloque le fil qui l'appelle (de quelques dizaines à quelques
// centaines de millisecondes par phrase) : elle tourne dans un isolate à part,
// qui garde le moteur et les derniers modèles chargés.

import 'dart:async';
import 'dart:collection';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

typedef _VersionC = Pointer<Utf8> Function();
typedef _ServiceCreateC = Int32 Function(Size, Pointer<Pointer<Void>>, Pointer<Pointer<Utf8>>);
typedef _ServiceCreateD = int Function(int, Pointer<Pointer<Void>>, Pointer<Pointer<Utf8>>);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _FreeD = void Function(Pointer<Void>);
typedef _ModelLoadC = Int32 Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Void>>, Pointer<Pointer<Utf8>>);
typedef _ModelLoadD = int Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Pointer<Void>>, Pointer<Pointer<Utf8>>);
typedef _TranslateC = Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
    Pointer<Pointer<Utf8>>, Size, Uint32, Pointer<Pointer<Pointer<Utf8>>>, Pointer<Pointer<Utf8>>);
typedef _TranslateD = int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>,
    Pointer<Pointer<Utf8>>, int, int, Pointer<Pointer<Pointer<Utf8>>>, Pointer<Pointer<Utf8>>);
typedef _FreeStringsC = Void Function(Pointer<Pointer<Utf8>>, Size);
typedef _FreeStringsD = void Function(Pointer<Pointer<Utf8>>, int);
typedef _FreeStringC = Void Function(Pointer<Utf8>);
typedef _FreeStringD = void Function(Pointer<Utf8>);

/// Erreur du moteur (modèle illisible, traduction impossible…).
class BergamotException implements Exception {
  BergamotException(this.message);
  final String message;
  @override
  String toString() => 'Bergamot : $message';
}

/// Accès direct (synchrone) à libbergamot. À n'utiliser que dans un isolate
/// de travail : voir [BergamotWorker].
class BergamotLibrary {
  BergamotLibrary(DynamicLibrary lib)
      : _version = lib.lookupFunction<_VersionC, _VersionC>('bt_version'),
        _serviceCreate =
            lib.lookupFunction<_ServiceCreateC, _ServiceCreateD>('bt_service_create'),
        _serviceFree = lib.lookupFunction<_FreeC, _FreeD>('bt_service_free'),
        _modelLoad = lib.lookupFunction<_ModelLoadC, _ModelLoadD>('bt_model_load'),
        _modelFree = lib.lookupFunction<_FreeC, _FreeD>('bt_model_free'),
        _translate = lib.lookupFunction<_TranslateC, _TranslateD>('bt_translate'),
        _freeStrings = lib.lookupFunction<_FreeStringsC, _FreeStringsD>('bt_free_strings'),
        _freeString = lib.lookupFunction<_FreeStringC, _FreeStringD>('bt_free_string');

  final _VersionC _version;
  final _ServiceCreateD _serviceCreate;
  final _FreeD _serviceFree;
  final _ModelLoadD _modelLoad;
  final _FreeD _modelFree;
  final _TranslateD _translate;
  final _FreeStringsD _freeStrings;
  final _FreeStringD _freeString;

  /// Nom de la bibliothèque sur Android (dossier jniLibs de l'APK).
  static const androidName = 'libbergamot.so';

  /// Ouvre la bibliothèque : [path] (tests sur ordinateur) ou celle de l'APK.
  static BergamotLibrary open([String? path]) =>
      BergamotLibrary(DynamicLibrary.open(path ?? androidName));

  String version() => _version().toDartString();

  Never _fail(Pointer<Pointer<Utf8>> error, String what) {
    final p = error.value;
    var message = what;
    if (p != nullptr) {
      message = '$what : ${p.toDartString()}';
      _freeString(p);
    }
    throw BergamotException(message);
  }

  Pointer<Void> createService({int cacheSize = 256}) {
    return using((arena) {
      final out = arena<Pointer<Void>>();
      final error = arena<Pointer<Utf8>>()..value = nullptr;
      if (_serviceCreate(cacheSize, out, error) != 0) _fail(error, 'moteur non créé');
      return out.value;
    });
  }

  void freeService(Pointer<Void> service) => _serviceFree(service);

  /// Charge un modèle : [configYaml] avec des chemins relatifs à [dir].
  Pointer<Void> loadModel(String configYaml, String dir) {
    return using((arena) {
      final out = arena<Pointer<Void>>();
      final error = arena<Pointer<Utf8>>()..value = nullptr;
      final status = _modelLoad(
          configYaml.toNativeUtf8(allocator: arena), dir.toNativeUtf8(allocator: arena), out, error);
      if (status != 0) _fail(error, 'modèle illisible ($dir)');
      return out.value;
    });
  }

  void freeModel(Pointer<Void> model) => _modelFree(model);

  /// Traduit [texts] avec [model], puis [pivot] s'il est donné (it→en→de).
  List<String> translate(Pointer<Void> service, Pointer<Void> model, Pointer<Void>? pivot,
      List<String> texts) {
    if (texts.isEmpty) return const [];
    return using((arena) {
      final input = arena<Pointer<Utf8>>(texts.length);
      for (var i = 0; i < texts.length; i++) {
        input[i] = texts[i].toNativeUtf8(allocator: arena);
      }
      final out = arena<Pointer<Pointer<Utf8>>>();
      final error = arena<Pointer<Utf8>>()..value = nullptr;
      final status =
          _translate(service, model, pivot ?? nullptr, input, texts.length, 0, out, error);
      if (status != 0) _fail(error, 'traduction impossible');
      final result = [for (var i = 0; i < texts.length; i++) out.value[i].toDartString()];
      _freeStrings(out.value, texts.length);
      return result;
    });
  }
}

/// Isolate de travail qui garde le moteur Bergamot et les derniers modèles
/// (au plus [maxModels], un aller par l'anglais + un retour).
class BergamotWorker {
  BergamotWorker._(this._isolate, this._send, this._replies, this._pending);

  final Isolate _isolate;
  final SendPort _send;
  final ReceivePort _replies;

  /// Réponses attendues, par numéro de demande (rempli par l'écouteur de [start]).
  final Map<int, Completer<Object?>> _pending;
  int _nextId = 0;

  static const maxModels = 3;

  /// Démarre l'isolate. Renvoie null si la bibliothèque n'existe pas sur ce
  /// téléphone (Android 32 bits, par exemple).
  static Future<BergamotWorker?> start([String? libraryPath]) async {
    final replies = ReceivePort();
    final first = Completer<Object?>();
    final pending = <int, Completer<Object?>>{};
    replies.listen((message) {
      if (!first.isCompleted) {
        first.complete(message);
        return;
      }
      final m = message as List;
      final c = pending.remove(m[0] as int);
      if (c == null) return;
      if (m[1] == true) {
        c.complete(m[2]);
      } else {
        c.completeError(BergamotException(m[2].toString()));
      }
    });
    final isolate = await Isolate.spawn(_main, [replies.sendPort, libraryPath]);
    final hello = await first.future;
    if (hello is! SendPort) {
      replies.close();
      isolate.kill();
      return null;
    }
    return BergamotWorker._(isolate, hello, replies, pending);
  }

  Future<Object?> _call(String op, List<Object?> args) {
    final id = _nextId++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send.send([id, op, ...args]);
    return c.future;
  }

  /// Version de la bibliothèque et du moteur.
  Future<String> version() async => (await _call('version', const [])).toString();

  /// Traduit [texts] avec le modèle du dossier [modelDir] (qui contient
  /// config.yml), puis celui de [pivotDir] s'il est donné.
  Future<List<String>> translate(List<String> texts, String modelDir, [String? pivotDir]) async {
    final r = await _call('translate', [texts, modelDir, pivotDir]);
    return (r as List).cast<String>();
  }

  /// Oublie un modèle chargé (avant de supprimer ses fichiers).
  Future<void> unload(String modelDir) => _call('unload', [modelDir]);

  void close() {
    _send.send([-1, 'exit']);
    _replies.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(BergamotException('arrêté'));
    }
    _pending.clear();
  }

  static void _main(List<Object?> args) {
    final reply = args[0] as SendPort;
    BergamotLibrary? opened;
    try {
      opened = BergamotLibrary.open(args[1] as String?);
    } catch (e) {
      reply.send('absent : $e');
      return;
    }
    final lib = opened!;
    final inbox = ReceivePort();
    reply.send(inbox.sendPort);

    Pointer<Void>? service;
    final models = LinkedHashMap<String, Pointer<Void>>();

    Pointer<Void> model(String dir) {
      final known = models.remove(dir);
      if (known != null) {
        models[dir] = known; // le plus récent en dernier
        return known;
      }
      while (models.length >= maxModels) {
        final oldest = models.keys.first;
        lib.freeModel(models.remove(oldest)!);
      }
      final yaml = File('$dir/config.yml').readAsStringSync();
      final m = lib.loadModel(yaml, dir);
      models[dir] = m;
      return m;
    }

    inbox.listen((message) {
      final m = message as List;
      final id = m[0] as int;
      final op = m[1] as String;
      if (op == 'exit') {
        for (final p in models.values) {
          lib.freeModel(p);
        }
        models.clear();
        if (service != null) lib.freeService(service!);
        inbox.close();
        return;
      }
      try {
        Object? result;
        switch (op) {
          case 'version':
            result = lib.version();
          case 'translate':
            final texts = (m[2] as List).cast<String>();
            final main = model(m[3] as String);
            final pivot = m[4] == null ? null : model(m[4] as String);
            service ??= lib.createService();
            result = lib.translate(service!, main, pivot, texts);
          case 'unload':
            final p = models.remove(m[2] as String);
            if (p != null) lib.freeModel(p);
        }
        reply.send([id, true, result]);
      } catch (e) {
        reply.send([id, false, e is BergamotException ? e.message : e.toString()]);
      }
    });
  }
}
