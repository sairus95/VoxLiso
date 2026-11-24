// Traducteur du téléphone (Bergamot) : registre de Mozilla, choix des
// modèles, passage par l'anglais, configuration du moteur.
//
// La dernière partie traduit pour de vrai (modèles de Mozilla téléchargés)
// quand BERGAMOT_LIB donne le chemin de libbergamot pour Linux (CI).
@Timeout(Duration(minutes: 15))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxliso/bergamot.dart';
import 'package:voxliso/bergamot_models.dart';
import 'package:voxliso/phone_translator.dart';
import 'package:voxliso/translator.dart';

Map<String, dynamic> _entry(String from, String to, String status,
        {bool split = false, bool shortlist = true, String arch = 'base-memory'}) =>
    {
      'sourceLanguage': from,
      'targetLanguage': to,
      'architecture': arch,
      'releaseStatus': status,
      'files': {
        'model': {
          'path': 'models/$from-$to/$arch/exported/model.$from$to.intgemm.alphas.bin.gz',
          'uncompressedHash': 'abc',
          'uncompressedSize': 31561787,
        },
        if (split) ...{
          'srcVocab': {'path': 'models/$from-$to/x/srcvocab.$from$to.spm.gz'},
          'trgVocab': {'path': 'models/$from-$to/x/trgvocab.$from$to.spm.gz'},
        } else
          'vocab': {'path': 'models/$from-$to/x/vocab.$from$to.spm.gz'},
        if (shortlist) 'lexicalShortlist': {'path': 'models/$from-$to/x/lex.50.50.$from$to.s2t.bin.gz'},
      },
    };

String _registryJson() => jsonEncode({
      'generated': '2026-11-01',
      'baseUrl': 'https://example.org/bucket/',
      'models': {
        'fr-en': [_entry('fr', 'en', 'Release')],
        'en-fr': [_entry('en', 'fr', 'Release'), _entry('en', 'fr', 'Nightly', arch: 'base')],
        'de-en': [_entry('de', 'en', 'Release')],
        'en-de': [_entry('en', 'de', 'Release')],
        'en-ko': [
          _entry('en', 'ko', 'Release Desktop', arch: 'base'),
          _entry('en', 'ko', 'Release Android', split: true),
        ],
        'en-nb': [_entry('en', 'nb', 'Release')],
        'nb-en': [_entry('nb', 'en', 'Release')],
        'bs-en': [_entry('bs', 'en', 'Nightly')],
        'en-ja': [_entry('en', 'ja', 'Release', shortlist: false)],
      },
    });

void main() {
  group('Registre de Mozilla', () {
    final r = BergamotRegistry.parse(_registryJson());

    test('adresse de base sans / final, modèles publiés seulement', () {
      expect(r.baseUrl, 'https://example.org/bucket');
      expect(r.models.containsKey('bs-en'), isFalse); // Nightly
      expect(r.models.containsKey('fr-en'), isTrue);
    });

    test('version Android préférée, vocabulaires séparés', () {
      final ko = r.models['en-ko']!;
      expect(ko.vocabs.length, 2);
      expect(ko.model.path, contains('base-memory'));
      final yaml = ko.configYaml();
      expect(yaml, contains('  - srcvocab.enko.spm\n  - trgvocab.enko.spm'));
    });

    test('nom des fichiers décompressés, configuration du moteur', () {
      final m = r.models['fr-en']!;
      expect(m.model.name, 'model.fren.intgemm.alphas.bin');
      expect(m.files.length, 3);
      final yaml = m.configYaml();
      expect(yaml, contains('models:\n  - model.fren.intgemm.alphas.bin'));
      expect(yaml, contains('vocabs:\n  - vocab.fren.spm\n  - vocab.fren.spm'));
      expect(yaml, contains('shortlist:\n  - lex.50.50.fren.s2t.bin\n  - false'));
      expect(yaml, contains('gemm-precision: int8shiftAlphaAll'));
      expect(yaml, contains('beam-size: 1'));
    });

    test('sans liste de mots courte', () {
      final yaml = r.models['en-ja']!.configYaml();
      expect(yaml, isNot(contains('shortlist')));
    });

    test('passage par l\'anglais', () {
      expect([for (final m in r.plan('de', 'fr')) m.pair], ['de-en', 'en-fr']);
      expect([for (final m in r.plan('fr', 'en')) m.pair], ['fr-en']);
      expect([for (final m in r.plan('en', 'de')) m.pair], ['en-de']);
      expect(r.plan('ja', 'fr'), isEmpty); // pas de ja-en dans ce registre
      expect(r.plan('fr', 'fr'), isEmpty);
    });

    test('norvégien : bokmål', () {
      expect([for (final m in r.plan('no', 'fr')) m.pair], ['nb-en', 'en-fr']);
      expect([for (final m in r.both('no')) m.pair], ['nb-en', 'en-nb']);
    });
  });

  group('Modèles installés', () {
    late Directory root;
    late BergamotStore store;
    setUp(() {
      root = Directory.systemTemp.createTempSync('voxliso_models_');
      store = BergamotStore(root);
    });
    tearDown(() => root.deleteSync(recursive: true));

    void fake(String pair) {
      final d = store.dir(pair)..createSync(recursive: true);
      File('${d.path}/config.yml').writeAsStringSync('models: []\n');
    }

    test('route directe ou par l\'anglais, seulement si tout est là', () {
      expect(store.route('de', 'fr'), isNull);
      fake('de-en');
      expect(store.route('de', 'fr'), isNull);
      fake('en-fr');
      expect(store.route('de', 'fr'), ['${root.path}/de-en', '${root.path}/en-fr']);
      expect(store.route('en', 'fr'), ['${root.path}/en-fr']);
      expect(store.pairs(), ['de-en', 'en-fr']);
    });

    test('un dossier sans config.yml (téléchargement interrompu) est ignoré', () {
      store.dir('fr-en').createSync(recursive: true);
      expect(store.hasPair('fr-en'), isFalse);
      expect(store.pairs(), isEmpty);
    });

    test('norvégien installé en « nb »', () {
      fake('nb-en');
      fake('en-fr');
      expect(store.route('no', 'fr'), isNotNull);
    });
  });

  // ------------------------------------------------- vraie traduction (CI)

  final lib = Platform.environment['BERGAMOT_LIB'];
  group('Bergamot pour de vrai', () {
    late Directory root;
    late BergamotTranslator phone;

    setUpAll(() async {
      root = Directory.systemTemp.createTempSync('voxliso_bergamot_');
      phone = BergamotTranslator(libraryPath: lib, root: root, wifiCheck: () async => true);
      expect(await phone.isAvailable(), isTrue, reason: 'libbergamot introuvable : $lib');
      final r = await phone.registry();
      expect(r, isNotNull, reason: 'registre de Mozilla injoignable');
      final store = BergamotStore(root);
      for (final m in [...r!.plan('fr', 'en'), ...r.plan('en', 'de')]) {
        final sw = Stopwatch()..start();
        await store.install(m, r.baseUrl);
        // ignore: avoid_print
        print('${m.pair} : ${store.sizeOf(m.pair) ~/ 1000000} Mo en ${sw.elapsed.inSeconds} s');
      }
    });

    tearDownAll(() async {
      await phone.close();
      root.deleteSync(recursive: true);
    });

    test('version du moteur', () async {
      final w = await BergamotWorker.start(lib);
      expect(w, isNotNull);
      final v = await w!.version();
      // ignore: avoid_print
      print('libbergamot $v');
      expect(v, isNotEmpty);
      w.close();
    });

    test('français → anglais', () async {
      final sw = Stopwatch()..start();
      final out = await phone.translate(
          ['Où est la gare, s\'il vous plaît ?', 'Je ne sais pas.'], 'fr', 'en');
      // ignore: avoid_print
      print('fr→en en ${sw.elapsedMilliseconds} ms : $out');
      expect(out, isNotNull);
      expect(out![0].toLowerCase(), contains('station'));
      expect(out[1].toLowerCase(), contains('know'));
    });

    test('français → allemand, par l\'anglais', () async {
      final out = await phone.translate(['Où est la gare, s\'il vous plaît ?'], 'fr', 'de');
      // ignore: avoid_print
      print('fr→de : $out');
      expect(out, isNotNull);
      expect(out!.first, contains('Bahnhof'));
    });

    test('langue absente : null (pas d\'erreur)', () async {
      expect(await phone.canTranslateNow('it', 'en'), isFalse);
      expect(await phone.translate(['Ciao'], 'it', 'en'), isNull);
    });

    test('dans la chaîne de traduction des sous-titres', () async {
      final t = SubtitleTranslator(phone: phone)..phoneReady = true;
      final r = await t.translateAll(['- Tu viens ?', '- Oui, j\'arrive.'], 'fr', 'en');
      // ignore: avoid_print
      print('translateAll : ${r?.texts} (${r?.engine})');
      expect(r, isNotNull);
      expect(r!.engine, 'téléphone');
      expect(r.texts.length, 2);
    });

    test('langue vue comme installée dans les deux sens', () async {
      expect(await phone.isInstalled('fr'), isFalse); // en-fr absent
      expect(await phone.isInstalled('en'), isTrue);
    });
  }, skip: lib == null ? 'BERGAMOT_LIB absent (bibliothèque Linux compilée par la CI)' : false);
}
