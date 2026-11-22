import 'package:flutter_test/flutter_test.dart';
import 'package:voxliso/history.dart';
import 'package:voxliso/language_detector.dart';
import 'package:voxliso/languages.dart';
import 'package:voxliso/static_filter.dart';
import 'package:voxliso/subtitle_tracker.dart';
import 'package:voxliso/updater.dart';
import 'package:voxliso/text_tools.dart';
import 'package:voxliso/voices.dart';

void main() {
  group('cleanSubtitle', () {
    test('retire les descriptions sonores et les symboles', () {
      expect(cleanSubtitle(['♪ [Musique] ♪', 'Bonjour à tous']), 'Bonjour à tous');
      expect(cleanSubtitle(['(rires) Très drôle !']), 'Très drôle !');
    });

    test('sépare les répliques de dialogue', () {
      expect(cleanSubtitle(['- Tu viens ?', '- Non']), 'Tu viens ? Non.');
      expect(subtitleParts(['- Tu viens ?', '- Non']), ['Tu viens ?', 'Non.']);
    });

    test('répliques sur une seule ligne', () {
      expect(subtitleParts(['- ¿Vienes? - No, gracias.']), ['¿Vienes?', 'No, gracias.']);
    });

    test('une phrase sur deux lignes reste une seule réplique', () {
      expect(subtitleParts(['Ich habe keine Zeit,', 'weil ich arbeiten muss.']),
          ['Ich habe keine Zeit, weil ich arbeiten muss.']);
    });

    test('un tiret dans une phrase ne coupe pas la réplique', () {
      expect(subtitleParts(['Il est peut-être là - ou pas.']), ['Il est peut-être là - ou pas.']);
    });

    test('joint les lignes d\'une même phrase', () {
      expect(cleanSubtitle(['Ich habe keine Zeit,', 'weil ich arbeiten muss.']),
          'Ich habe keine Zeit, weil ich arbeiten muss.');
    });

    test('prépare le texte pour la traduction', () {
      expect(prepareForTranslation('...et puis il est parti'), 'et puis il est parti');
      expect(prepareForTranslation('Je pense que…'), 'Je pense que');
      expect(prepareForTranslation('Pourquoi ?'), 'Pourquoi ?');
      expect(prepareForTranslation('...'), '...');
    });

    test('écarte le bruit de l\'OCR', () {
      expect(cleanSubtitle(['= : ~ 1 2', '¿Dónde está?']), '¿Dónde está?');
    });
  });

  group('SubtitleTracker', () {
    test('lit une seule fois un sous-titre qui reste affiché', () {
      final t = SubtitleTracker(stableFrames: 2);
      final said = <String>[];
      for (final r in ['Ciao, come stai?', 'Ciao, come stai?', 'Ciao, come stai ?', 'Ciao, corne stai?']) {
        final s = t.push(r);
        if (s != null) said.add(s);
      }
      expect(said, ['Ciao, come stai?']);
    });

    test('attend une lecture stable', () {
      final t = SubtitleTracker(stableFrames: 2);
      expect(t.push('Bonjour'), isNull);
      expect(t.push('Bonjour'), 'Bonjour');
    });

    test('lit le sous-titre suivant', () {
      final t = SubtitleTracker(stableFrames: 2);
      final said = <String>[];
      for (final r in ['Où vas-tu ?', 'Où vas-tu ?', '', 'Je rentre chez moi.', 'Je rentre chez moi.']) {
        final s = t.push(r);
        if (s != null) said.add(s);
      }
      expect(said, ['Où vas-tu ?', 'Je rentre chez moi.']);
    });

    test('sous-titres en direct : ne lit que la partie nouvelle', () {
      final t = SubtitleTracker(stableFrames: 1);
      expect(t.push('Le gouvernement a annoncé'), 'Le gouvernement a annoncé');
      expect(t.push('Le gouvernement a annoncé ce matin une réforme'), 'ce matin une réforme');
      expect(t.push('ce matin une réforme des retraites'), 'des retraites');
    });
  });

  group('LanguageDecision', () {
    test('change tout de suite sur un texte long et sûr', () {
      final d = LanguageDecision('fr');
      expect(d.update('Ich habe heute keine Zeit für dich.', {'de': 0.95}), 'de');
    });

    test('ignore les sous-titres trop courts', () {
      final d = LanguageDecision('fr');
      expect(d.update('Ja.', {'de': 0.99}), 'fr');
    });

    test('ignore les langues non prises en charge', () {
      final d = LanguageDecision('it');
      expect(d.update('Dit is een Nederlandse zin hier.', {'nl': 0.98}), 'it');
    });

    test('lit l\'anglais directement', () {
      final d = LanguageDecision('fr');
      expect(d.update('This is an English sentence here.', {'en': 0.98}), 'en');
    });

    test('lit le portugais directement', () {
      final d = LanguageDecision('fr');
      expect(d.update('Esta é uma frase em português.', {'pt': 0.98}), 'pt');
    });

    test('reconnaît une autre langue à traduire (néerlandais)', () {
      final d = LanguageDecision('fr', accept: (c) => kOtherLanguages.containsKey(c));
      expect(d.update('Dit is een Nederlandse zin hier.', {'nl': 0.98}), 'nl');
      expect(d.update('Où est la gare, s\'il vous plaît ?', {'fr': 0.97}), 'fr');
    });

    test('ignore « und » (langue indéterminée)', () {
      final d = LanguageDecision('de', accept: (c) => true);
      expect(d.update('xxxx yyyy zzzz wwww', {'und': 1.0}), 'de');
    });

    test('identification moyenne : il faut deux sous-titres de suite', () {
      final d = LanguageDecision('fr');
      expect(d.update('Vamos a la playa', {'es': 0.55}), 'fr');
      expect(d.update('Dónde está mi casa', {'es': 0.6}), 'es');
    });

    test('accepte les codes régionaux', () {
      final d = LanguageDecision('fr');
      expect(d.update('Questa è una frase italiana lunga.', {'it-IT': 0.9}), 'it');
    });
  });

  group('VoiceCatalog', () {
    VoiceCatalog catalog() => VoiceCatalog()
      ..load([
        {'name': 'fr-ca-x-cab-local', 'locale': 'fr-CA', 'quality': 'very high', 'network_required': '0', 'features': ''},
        {'name': 'fr-fr-x-frc-local', 'locale': 'fr-FR', 'quality': 'high', 'network_required': '0', 'features': ''},
        {'name': 'fr-fr-x-frd-local', 'locale': 'fr-FR', 'quality': 'very high', 'network_required': '0', 'features': ''},
        {'name': 'fr-fr-x-fre-network', 'locale': 'fr-FR', 'quality': 'very high', 'network_required': '1', 'features': ''},
        {'name': 'de-de-x-deb-local', 'locale': 'de-DE', 'quality': 'normal', 'network_required': '0', 'features': 'notInstalled'},
        {'name': 'Amélie', 'locale': 'fr-FR', 'quality': 'enhanced', 'gender': 'female', 'identifier': 'a'},
        {'name': 'Thomas', 'locale': 'fr-FR', 'quality': 'default', 'gender': 'male', 'identifier': 't'},
      ]);

    test('meilleure voix : hors ligne, accent de France, puis qualité', () {
      expect(catalog().best('fr')!.name, 'fr-fr-x-frd-local');
    });

    test('voix non installée ou en ligne écartée du choix automatique', () {
      expect(catalog().best('de'), isNull);
    });

    test('2e personnage : genre opposé quand il est connu', () {
      final c = catalog();
      final amelie = c.voicesFor('fr').firstWhere((v) => v.name == 'Amélie');
      expect(c.secondVoice('fr', amelie)!.name, 'Thomas');
    });

    test('2e personnage : une autre voix de la même région sinon', () {
      final c = catalog();
      final second = c.secondVoice('fr', c.best('fr'));
      expect(second!.key, isNot(c.best('fr')!.key));
      expect(second.locale, 'fr-FR');
    });

    test('libellés lisibles', () {
      final labels = catalog().labelsFor('fr');
      expect(labels['fr-fr-x-frd-local|fr-FR'], startsWith('Voix 1'));
      expect(labels['Amélie|fr-FR'], contains('Femme'));
      expect(labels['fr-fr-x-fre-network|fr-FR'], contains('internet'));
    });
  });

  group('SubtitleHistory', () {
    test('sauvegarde et relit les entrées, traduction comprise', () {
      final h = SubtitleHistory()
        ..add(HistoryEntry(time: DateTime(2026, 11, 21, 20, 30), text: 'Bonjour', lang: 'fr'))
        ..add(HistoryEntry(
            time: DateTime(2026, 11, 21, 20, 31),
            text: 'Où est la gare ?',
            lang: 'fr',
            original: 'Wo ist der Bahnhof?',
            originalLang: 'de'));
      final copy = SubtitleHistory()..decode(h.encode());
      expect(copy.entries.length, 2);
      expect(copy.last!.original, 'Wo ist der Bahnhof?');
      expect(copy.last!.originalLang, 'de');
      expect(copy.entries.first.time, DateTime(2026, 11, 21, 20, 30));
    });

    test('garde un nombre limité de phrases', () {
      final h = SubtitleHistory();
      for (var i = 0; i < SubtitleHistory.maxEntries + 20; i++) {
        h.add(HistoryEntry(time: DateTime(2026), text: 'Phrase $i', lang: 'fr'));
      }
      expect(h.entries.length, SubtitleHistory.maxEntries);
      expect(h.last!.text, 'Phrase ${SubtitleHistory.maxEntries + 19}');
      final saved = SubtitleHistory()..decode(h.encode());
      expect(saved.entries.length, SubtitleHistory.savedEntries);
    });

    test('données abîmées : historique vide, sans plantage', () {
      final h = SubtitleHistory()..decode('pas du json');
      expect(h.entries, isEmpty);
    });
  });

  group('StaticTextFilter', () {
    test('ignore un texte resté identique plus de 20 s', () {
      var now = DateTime(2026, 11, 22, 20, 0, 0);
      final f = StaticTextFilter(clock: () => now);
      for (var i = 0; i < 25; i++) {
        final fixed = f.update(['FRANCE 2', 'Bonjour à tous']);
        if (i < 20) expect(fixed, isEmpty, reason: 'seconde $i');
        now = now.add(const Duration(seconds: 1));
      }
      // Les sous-titres changent : seule la ligne fixe est ignorée.
      expect(f.update(['FRANCE 2', 'Une nouvelle phrase']), {0});
    });

    test('un sous-titre affiché quelques secondes n\'est jamais fixe', () {
      var now = DateTime(2026, 11, 22, 20, 0, 0);
      final f = StaticTextFilter(clock: () => now);
      for (var i = 0; i < 8; i++) {
        expect(f.update(['Je reviens dans cinq minutes.']), isEmpty);
        now = now.add(const Duration(seconds: 1));
      }
    });

    test('tolère une lecture ratée, pas une longue absence', () {
      var now = DateTime(2026, 11, 22, 20, 0, 0);
      final f = StaticTextFilter(clock: () => now);
      for (var i = 0; i < 15; i++) {
        f.update(['LIVE']);
        now = now.add(const Duration(seconds: 1));
      }
      now = now.add(const Duration(seconds: 2)); // image floue : 2 s sans le texte
      for (var i = 0; i < 5; i++) {
        f.update(['LIVE']);
        now = now.add(const Duration(seconds: 1));
      }
      expect(f.update(['LIVE']), {0});
      now = now.add(const Duration(seconds: 10)); // disparu longtemps : on oublie
      expect(f.update(['LIVE']), isEmpty);
    });

    test('petites erreurs de lecture : même texte fixe', () {
      var now = DateTime(2026, 11, 22, 20, 0, 0);
      final f = StaticTextFilter(clock: () => now);
      for (var i = 0; i < 22; i++) {
        f.update([i.isEven ? 'Le Journal de 20h' : 'Le Journa1 de 20h']);
        now = now.add(const Duration(seconds: 1));
      }
      expect(f.update(['Le Journal de 20h']), {0});
    });
  });

  group('Updater', () {
    test('compare les numéros de version', () {
      expect(Updater.isNewer('v1.0.27', '1.0.26'), isTrue);
      expect(Updater.isNewer('v1.0.26', '1.0.26'), isFalse);
      expect(Updater.isNewer('v1.0.9', '1.0.10'), isFalse);
      expect(Updater.isNewer('v1.1.0', '1.0.99'), isTrue);
      expect(Updater.isNewer('v1.0.27', 'dev'), isFalse);
      expect(Updater.parseVersion('v2.3.4'), [2, 3, 4]);
    });
  });
}
