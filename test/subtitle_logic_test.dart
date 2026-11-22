import 'package:flutter_test/flutter_test.dart';
import 'package:voxliso/history.dart';
import 'package:voxliso/language_detector.dart';
import 'package:voxliso/languages.dart';
import 'dart:ui' show Rect;

import 'package:voxliso/rate_pacer.dart';
import 'package:voxliso/reading_vote.dart';
import 'package:voxliso/sentence_joiner.dart';
import 'package:voxliso/spell_fixer.dart';
import 'package:voxliso/static_filter.dart';
import 'package:voxliso/subtitle_locator.dart';
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
      expect(cleanSubtitle(['- Tu viens ?', '- Non']), 'Tu viens ? Non');
      expect(subtitleParts(['- Tu viens ?', '- Non']), ['Tu viens ?', 'Non']);
      expect(subtitleParts(['- Oui', '- Non']), ['Oui.', 'Non']);
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

  group('SpellFixer', () {
    final en = WordList.fromWords(['you', 'the', 'come', 'here', 'home', 'modern', 'corn', 'will']);
    final fr = WordList.fromWords(['je', 'la', 'école', 'maison', 'journal', 'demain', 'de', 'à']);

    test('confusions typiques de la lecture', () {
      expect(SpellFixer.fix('Please corne here.', en), 'Please come here.');
      expect(SpellFixer.fix('a rnodern home', en), 'a modern home');
      expect(SpellFixer.fix('Le Journa1 de demain', fr), 'Le Journal de demain');
      expect(SpellFixer.fix('la rnaison', fr), 'la maison');
    });

    test('accents oubliés', () {
      expect(SpellFixer.fix('Je vais à l\'ecole demain.', fr), 'Je vais à l\'école demain.');
    });

    test('ne touche ni aux mots connus, ni aux noms propres, ni aux nombres', () {
      expect(SpellFixer.fix('You will come home.', en), 'You will come home.');
      expect(SpellFixer.fix('Ask Jarvis to come.', en), 'Ask Jarvis to come.');
      expect(SpellFixer.fix('Rendez-vous à 20h30.', fr), 'Rendez-vous à 20h30.');
    });

    test('garde les majuscules', () {
      expect(SpellFixer.fix('CORNE HERE', en), 'COME HERE');
      expect(SpellFixer.fix('Corne here.', en), 'Come here.');
    });
  });

  group('SubtitleLocator', () {
    test('place la zone sur le texte qui change, pas sur le logo', () {
      final loc = SubtitleLocator();
      const subs = ['Je pense que tu as raison.', 'Allons-y tout de suite.', 'Où est-il passé ?'];
      for (var i = 0; i < 15; i++) {
        loc.add([
          SeenLine('TF1', const Rect.fromLTRB(0.85, 0.05, 0.95, 0.12)),
          SeenLine(subs[i ~/ 5], const Rect.fromLTRB(0.3, 0.80, 0.7, 0.86)),
        ]);
      }
      final z = loc.result()!;
      expect(z.subtitles, 3);
      expect(z.top, lessThan(0.80));
      expect(z.bottom, greaterThan(0.86));
      expect(z.top, greaterThan(0.6));
      expect(z.left, lessThanOrEqualTo(0.3));
      expect(z.right, greaterThanOrEqualTo(0.7));
    });

    test('rien qui change : pas de zone', () {
      final loc = SubtitleLocator();
      for (var i = 0; i < 10; i++) {
        loc.add([SeenLine('Menu principal', const Rect.fromLTRB(0.3, 0.1, 0.7, 0.15))]);
      }
      expect(loc.result(), isNull);
    });
  });

  group('SentenceJoiner', () {
    test('repère une phrase coupée', () {
      expect(SentenceJoiner.isIncomplete('Je pense que…', 'fr'), isTrue);
      expect(SentenceJoiner.isIncomplete('Je pense que...', 'fr'), isTrue);
      expect(SentenceJoiner.isIncomplete('Je pense que', 'fr'), isTrue);
      expect(SentenceJoiner.isIncomplete('Si tu viens,', 'fr'), isTrue);
      expect(SentenceJoiner.isIncomplete("Il faut qu'", 'fr'), isTrue);
      expect(SentenceJoiner.isIncomplete('I want to', 'en'), isTrue);
      expect(SentenceJoiner.isIncomplete('Ich glaube, dass', 'de'), isTrue);
      expect(SentenceJoiner.isIncomplete('Creo que', 'es'), isTrue);
      expect(SentenceJoiner.isIncomplete('Penso che', 'it'), isTrue);
      expect(SentenceJoiner.isIncomplete('Acho que', 'pt'), isTrue);
    });
    test('laisse les phrases complètes', () {
      expect(SentenceJoiner.isIncomplete('Il fait beau', 'fr'), isFalse);
      expect(SentenceJoiner.isIncomplete('Il fait beau.', 'fr'), isFalse);
      expect(SentenceJoiner.isIncomplete('Tu viens ?', 'fr'), isFalse);
      expect(SentenceJoiner.isIncomplete('Fais-le', 'fr'), isFalse);
      expect(SentenceJoiner.isIncomplete("Va-t'en", 'fr'), isFalse);
      expect(SentenceJoiner.isIncomplete('Je n’en peux plus', 'fr'), isFalse);
      expect(SentenceJoiner.isIncomplete('I think so', 'en'), isFalse);
      expect(SentenceJoiner.isIncomplete('Come on', 'en'), isFalse);
      expect(SentenceJoiner.isIncomplete('Ich rufe dich an', 'de'), isFalse);
      expect(SentenceJoiner.isIncomplete('Acho que não', 'pt'), isFalse);
      expect(SentenceJoiner.isIncomplete('', 'fr'), isFalse);
    });
    test('réunit les deux morceaux', () {
      expect(SentenceJoiner.join('Je pense que…', '…tu as raison.'), 'Je pense que tu as raison.');
      expect(SentenceJoiner.join('Je pense que ...', '... tu as raison.'), 'Je pense que tu as raison.');
      expect(SentenceJoiner.join('Si tu viens,', 'on part.'), 'Si tu viens, on part.');
    });
  });

  group('RatePacer', () {
    test('vitesse normale sans retard', () {
      final p = RatePacer();
      expect(p.next(0), 1.0);
      expect(p.next(10), 1.0);
    });
    test('accélère avec le retard, sans dépasser +40 %', () {
      final p = RatePacer();
      final a = p.next(50);
      expect(a, greaterThan(1.0));
      expect(a, lessThanOrEqualTo(1.25));
      p.next(300);
      expect(p.next(300), 1.4);
      expect(p.next(1000), 1.4);
    });
    test('monte par paliers et redescend doucement', () {
      final p = RatePacer();
      expect(p.next(300), 1.25); // +25 % au plus d'un coup
      expect(p.next(300), 1.4);
      expect(p.next(0), closeTo(1.3, 1e-9));
      expect(p.next(0), closeTo(1.2, 1e-9));
      p.reset();
      expect(p.factor, 1.0);
    });
  });

  group('ReadingVote', () {
    final dict = WordList.fromWords([
      'je', 'pense', 'que', 'tu', 'as', 'raison', 'il', 'fait', 'beau', 'la', 'maison',
      'à', 'rentre', 'école', 'vu', 'ai', 'le', 'chat', 'est', 'sur', 'table', 'viens', 'non',
    ]);
    test('garde le vrai mot quand deux lectures diffèrent', () {
      expect(
        ReadingVote.combine([
          const OcrReading('Je pense que tu as raisori.'),
          const OcrReading('Je pense gue tu as raison.'),
        ], dict: dict),
        'Je pense que tu as raison.',
      );
    });
    test('la majorité l\'emporte', () {
      expect(
        ReadingVote.combine([
          const OcrReading('Le chat est sur la table'),
          const OcrReading('Le chat est sur la tabie'),
          const OcrReading('Le chat est sur la table'),
        ], dict: dict),
        'Le chat est sur la table',
      );
    });
    test('retire un mot vu dans une seule lecture sur trois', () {
      expect(
        ReadingVote.combine([
          const OcrReading('Il fait beau'),
          const OcrReading('Il fait beau x'),
          const OcrReading('Il fait beau'),
        ], dict: dict),
        'Il fait beau',
      );
    });
    test('accents : la forme du dictionnaire', () {
      expect(
        ReadingVote.combine([
          const OcrReading("Je l'ai vu à l'ecole"),
          const OcrReading("Je l'ai vu à l'école"),
        ], dict: dict),
        "Je l'ai vu à l'école",
      );
    });
    test('sans dictionnaire : la confiance de ML Kit départage', () {
      expect(
        ReadingVote.combine([
          const OcrReading('Hello Jonh', confidence: {'jonh': 0.4}),
          const OcrReading('Hello John', confidence: {'john': 0.95}),
        ]),
        'Hello John',
      );
    });
    test('garde les répliques et le tiret de début', () {
      final t = ReadingVote.combine([
        OcrReading(joinParts(['Tu viens ?', 'Non'], dialogueStart: true)),
        OcrReading(joinParts(['Tu vlens ?', 'Non'], dialogueStart: true)),
      ], dict: dict);
      expect(splitParts(t), ['Tu viens ?', 'Non']);
      expect(startsWithDialogue(t), isTrue);
    });
    test('une seule lecture : inchangée', () {
      expect(ReadingVote.combine([const OcrReading('Bonjour')], dict: dict), 'Bonjour');
      expect(ReadingVote.combine(const []), '');
    });

    test('suivi : lectures en désaccord, une image de plus puis le vote', () {
      final t = SubtitleTracker(stableFrames: 2)..dictionary = () => dict;
      expect(t.push('Je pense que tu as raisori.'), isNull);
      expect(t.push('Je pense gue tu as raison.'), isNull);
      expect(t.push('Je pense que tu as raison.'), 'Je pense que tu as raison.');
    });
    test('suivi : dit le sous-titre même s\'il disparaît pendant qu\'on départage', () {
      final t = SubtitleTracker(stableFrames: 2)..dictionary = () => dict;
      expect(t.push('Il fait beau'), isNull);
      expect(t.push('Il fait bcau'), isNull);
      expect(t.push(''), 'Il fait beau');
    });
    test('suivi : 2e lecture de la même image', () {
      final t = SubtitleTracker(stableFrames: 1)..dictionary = () => dict;
      expect(
        t.push('Je rentre à la rnaison.',
            alternatives: [const OcrReading('Je rentre à la maison.')]),
        isNull,
      );
      expect(t.push(''), 'Je rentre à la maison.');
      expect(t.lastWasFull, isTrue);
    });
    test('suivi : un nouveau sous-titre fait dire celui qui attendait', () {
      final t = SubtitleTracker(stableFrames: 2)..dictionary = () => dict;
      t.push('Il fait beau');
      expect(t.push('Il fait bcau'), isNull);
      expect(t.push('Le chat est sur la table'), 'Il fait beau');
      expect(t.push('Le chat est sur la table'), 'Le chat est sur la table');
    });
  });
}
