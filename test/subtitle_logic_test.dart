import 'package:flutter_test/flutter_test.dart';
import 'package:voxliso/history.dart';
import 'package:voxliso/language_detector.dart';
import 'package:voxliso/aim_beep.dart';
import 'package:voxliso/zone_profiles.dart';
import 'package:voxliso/languages.dart';
import 'dart:ui' show Rect;

import 'package:voxliso/rate_pacer.dart';
import 'package:voxliso/reading_vote.dart';
import 'package:voxliso/sentence_joiner.dart';
import 'package:voxliso/speech_service.dart';
import 'package:voxliso/speech_text.dart';
import 'package:voxliso/spell_fixer.dart';
import 'package:voxliso/static_filter.dart';
import 'package:voxliso/subtitle_locator.dart';
import 'package:voxliso/subtitle_tracker.dart';
import 'package:voxliso/updater.dart';
import 'package:voxliso/text_tools.dart';
import 'package:voxliso/translator.dart';
import 'package:voxliso/version.dart';
import 'package:voxliso/voices.dart';
import 'package:voxliso/zones.dart';

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
      expect(d.update('Đây là một câu tiếng Việt khá dài.', {'vi': 0.98}), 'it');
    });

    test('lit le néerlandais directement', () {
      final d = LanguageDecision('fr');
      expect(d.update('Dit is een Nederlandse zin hier.', {'nl': 0.98}), 'nl');
    });

    test('reconnaît un court sous-titre chinois', () {
      final d = LanguageDecision('fr');
      expect(d.update('你在做什么？', {'zh': 0.95}), 'zh');
    });

    test('lit l\'anglais directement', () {
      final d = LanguageDecision('fr');
      expect(d.update('This is an English sentence here.', {'en': 0.98}), 'en');
    });

    test('lit le portugais directement', () {
      final d = LanguageDecision('fr');
      expect(d.update('Esta é uma frase em português.', {'pt': 0.98}), 'pt');
    });

    test('reconnaît une autre langue à traduire (vietnamien)', () {
      final d = LanguageDecision('fr', accept: (c) => kOtherLanguages.containsKey(c));
      expect(d.update('Đây là một câu tiếng Việt khá dài.', {'vi': 0.98}), 'vi');
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
    test('textes de progression du téléchargement', () {
      expect(Updater.progressText(null), 'Téléchargement…');
      expect(Updater.progressText(0.426), 'Téléchargement : 43 %');
      expect(Updater.pausedText(2), 'En attente du réseau…');
      expect(Updater.pausedText(3), 'En attente du Wi-Fi…');
      expect(Updater.pausedText(99), 'En pause…');
    });
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

    final fr2 = WordList.fromWords(
        ['je', 'te', 'il', 'vous', 'plaît', 'si', 'gentiment', 'merci', 'plaie', 'pli', 'est']);

    test('« SHte plaí » -> « S\'il te plaît » (retour du 26/11/2026)', () {
      expect(SpellFixer.fix('SHte plaí', fr2, lang: 'fr'), "S'il te plaît");
      expect(SpellFixer.fix('Sh vous plaît.', fr2, lang: 'fr'), "S'il vous plaît.");
      expect(SpellFixer.fix('Merci, sil te plaît.', fr2, lang: 'fr'), "Merci, s'il te plaît.");
      expect(SpellFixer.fix("S'il te plaît", fr2, lang: 'fr'), "S'il te plaît");
      // Seulement devant « te / vous plaît », et seulement en français.
      expect(SpellFixer.fix('Sh, il est là.', fr2, lang: 'fr'), 'Sh, il est là.');
      expect(SpellFixer.fix('SHte plaí', fr2, lang: 'de'), 'SHte plaît'); // « SH » laissé
    });

    test('deux mots collés, accent faux : « sigentimènt » -> « si gentiment »', () {
      expect(SpellFixer.fix('Merci sigentimènt !', fr2), 'Merci si gentiment !');
      expect(SpellFixer.fix('Merci gentimènt.', fr2), 'Merci gentiment.');
    });

    test('lettre perdue : « plaí » -> « plaît » (le mot le plus courant)', () {
      expect(SpellFixer.fix('ça te plaí ?', fr2), 'ça te plaît ?');
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
    test('accélère avec le retard : +40 % pour un sous-titre en attente, +60 % au plus', () {
      final p = RatePacer();
      final a = p.next(50);
      expect(a, greaterThan(1.0));
      expect(a, lessThanOrEqualTo(1.25));
      p.next(100);
      expect(p.next(100), 1.4);
      p.next(300);
      expect(p.next(300), 1.6);
      expect(p.next(1000), 1.6);
    });
    test('monte par paliers et redescend doucement', () {
      final p = RatePacer();
      expect(p.next(300), 1.25); // +25 % au plus d'un coup
      expect(p.next(300), 1.5);
      expect(p.next(0), closeTo(1.4, 1e-9));
      expect(p.next(0), closeTo(1.3, 1e-9));
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

  group('Azure Translator', () {
    test('codes de langue', () {
      expect(SubtitleTranslator.azureLang('fr'), 'fr');
      expect(SubtitleTranslator.azureLang('no'), 'nb');
      expect(SubtitleTranslator.azureLang('tl'), 'fil');
      expect(SubtitleTranslator.azureLang('pt'), 'pt');
      expect(SubtitleTranslator.azureLang('pt', target: true), 'pt-pt');
    });
    test('lit la réponse', () {
      const body = '[{"translations":[{"text":"Où est la gare, s\'il vous plaît ?","to":"fr"}]},'
          '{"translations":[{"text":"Merci.","to":"fr"}]}]';
      expect(SubtitleTranslator.parseAzure(body, 2), ["Où est la gare, s'il vous plaît ?", 'Merci.']);
      expect(SubtitleTranslator.parseAzure(body, 3), isNull);
      expect(SubtitleTranslator.parseAzure('{"error":{}}', 1), isNull);
    });
    test('messages d\'erreur', () {
      expect(SubtitleTranslator.azureErrorMessage(401, '{"error":{"code":401000}}'), contains('Clé Azure'));
      expect(SubtitleTranslator.azureErrorMessage(403, '{"error":{"code":403001,"message":"quota"}}'),
          contains('Quota'));
      expect(SubtitleTranslator.azureErrorMessage(429, ''), contains('surchargé'));
      expect(SubtitleTranslator.azureErrorMessage(500, 'oops'), 'Azure a répondu 500.');
    });
  });

  group('Zone miroir', () {
    test('zone en bas : miroir en haut', () {
      final m = mirrorBand(0.62, 0.95)!;
      expect(m.$1, closeTo(0.05, 1e-9));
      expect(m.$2, closeTo(0.38, 1e-9));
    });
    test('zone en haut : miroir en bas', () {
      final m = mirrorBand(0.05, 0.40)!;
      expect(m.$1, closeTo(0.60, 1e-9));
      expect(m.$2, closeTo(0.95, 1e-9));
    });
    test('ne chevauche jamais la zone', () {
      final m = mirrorBand(0.30, 0.95)!;
      expect(m.$1, closeTo(0.05, 1e-9));
      expect(m.$2, closeTo(0.28, 1e-9));
    });
    test('pas de miroir pour une zone qui prend presque toute la hauteur', () {
      expect(mirrorBand(0.05, 0.95), isNull);
    });
  });

  group('Nouvelles langues', () {
    test('codes et écritures', () {
      expect(supportedLanguage('nb-NO')?.code, 'no');
      expect(supportedLanguage('pl')?.label, 'Polski');
      expect(languageFor('ja').script, SubtitleScript.japanese);
      expect(languageFor('ko').script, SubtitleScript.korean);
      expect(languageFor('nl').script, SubtitleScript.latin);
      expect(SubtitleScript.fromName('chinese'), SubtitleScript.chinese);
      expect(SubtitleScript.fromName('???'), SubtitleScript.latin);
      expect(kOtherLanguages.containsKey('nl'), isFalse);
      expect(isReadLanguage('zh'), isTrue);
    });
    test('traduction : codes DeepL et Azure', () {
      expect(SubtitleTranslator.deeplTarget('zh'), 'ZH-HANS');
      expect(SubtitleTranslator.deeplTarget('no'), 'NB');
      expect(SubtitleTranslator.deeplTarget('nl'), 'NL');
      expect(SubtitleTranslator.azureLang('zh'), 'zh-Hans');
    });
    test('comparaison : toutes les écritures', () {
      expect(normalizeForCompare('你好，世界！'), '你好 世界');
      expect(normalizeForCompare('Łódź'), 'lodz');
      expect(normalizeForCompare('Přečtu titulky'), 'prectu titulky');
      expect(similarity(normalizeForCompare('안녕하세요'), normalizeForCompare('안녕하세요!')), 1.0);
    });
    test('temps de parole', () {
      expect(speechWeight('ab'), 2);
      expect(speechWeight('你好'), 6);
      expect(speechWeight('안녕'), 6);
    });
    test('répliques en chinois', () {
      expect(subtitleParts(['－你好', '－再见']), ['你好。', '再见']);
      expect(cleanSubtitle(['我觉得', '你说得对。']), '我觉得你说得对。');
    });
    test('vote caractère par caractère', () {
      expect(ReadingVote.tokens('我觉得 OK 吗'), ['我', '觉', '得', 'OK', '吗']);
      expect(
        ReadingVote.combine(const [
          OcrReading('我觉得你说得对'),
          OcrReading('我觉得你说得封'),
          OcrReading('我觉得你说得对'),
        ]),
        '我觉得你说得对',
      );
      expect(ReadingVote.joinTokens(['Hello', 'world']), 'Hello world');
    });
    test('phrases coupées en chinois', () {
      expect(SentenceJoiner.isIncomplete('我觉得，', 'zh'), isTrue);
      expect(SentenceJoiner.isIncomplete('我觉得你说得对。', 'zh'), isFalse);
      expect(SentenceJoiner.join('我觉得…', '…你说得对。'), '我觉得你说得对。');
    });
  });
  group('Mots raccourcis, phrases coupées', () {
    test('« | » collé à des lettres : I ou l', () {
      expect(cleanSubtitle(['|l est parti.']), 'Il est parti.');
      expect(cleanSubtitle(['|ls arrivent']), 'Ils arrivent');
      expect(cleanSubtitle(['A|ors on y va']), 'Alors on y va');
      expect(cleanSubtitle(["|'homme est là"]), "l'homme est là");
      expect(cleanSubtitle(["|'m here"]), "I'm here");
      expect(cleanSubtitle(['Il faut a||er']), 'Il faut aller');
      expect(cleanSubtitle(['| Bonjour |']), 'Bonjour');
    });

    test('ligne voisine : la 1re ligne d\'un sous-titre qui dépasse de la zone est lue', () {
      const zone = Rect.fromLTRB(0.15, 0.62, 0.85, 0.95);
      final rects = [
        const Rect.fromLTRB(0.30, 0.55, 0.70, 0.61), // 1re ligne, au-dessus de la zone
        const Rect.fromLTRB(0.25, 0.63, 0.75, 0.69), // 2e ligne, dans la zone
        const Rect.fromLTRB(0.40, 0.20, 0.60, 0.26), // texte loin au-dessus
        const Rect.fromLTRB(0.02, 0.70, 0.10, 0.73), // logo à gauche
      ];
      expect(linesInZone(rects, zone), [0, 1]);
    });

    test('ligne voisine : pas une ligne d\'une autre taille ou trop loin', () {
      const line = Rect.fromLTRB(0.25, 0.63, 0.75, 0.69);
      expect(isNeighbourLine(line, const Rect.fromLTRB(0.30, 0.55, 0.70, 0.61)), isTrue);
      expect(isNeighbourLine(line, const Rect.fromLTRB(0.30, 0.45, 0.70, 0.51)), isFalse); // trop loin
      expect(isNeighbourLine(line, const Rect.fromLTRB(0.40, 0.47, 0.60, 0.61)), isFalse); // bien plus haute
      expect(isNeighbourLine(line, const Rect.fromLTRB(0.80, 0.55, 0.95, 0.61)), isFalse); // pas alignée
    });

    test('lecture renforcée : le recadrage contient la ligne qui dépasse de la zone', () {
      const zone = Rect.fromLTRB(0.15, 0.62, 0.85, 0.95);
      const visible = Rect.fromLTRB(0, 0, 1, 1);
      final c = enhancedCrop(zone, [const Rect.fromLTRB(0.08, 0.64, 0.93, 0.70)], visible);
      expect(c.left, lessThan(0.08));
      expect(c.right, greaterThan(0.93));
      final none = enhancedCrop(zone, const [], visible);
      expect(none.left, 0);
      expect(none.right, 1);
      expect(none.top, lessThan(zone.top));
    });

    test('lecture renforcée : une ligne qui touche le bord du recadrage est écartée', () {
      const crop = Rect.fromLTRB(0.13, 0.60, 0.87, 0.97);
      expect(touchesCropEdge(const Rect.fromLTRB(0.13, 0.64, 0.80, 0.70), crop), isTrue);
      expect(touchesCropEdge(const Rect.fromLTRB(0.20, 0.64, 0.868, 0.70), crop), isTrue);
      expect(touchesCropEdge(const Rect.fromLTRB(0.20, 0.64, 0.80, 0.70), crop), isFalse);
      // Bord du recadrage = bord de l'image : la ligne n'est pas coupée par le recadrage.
      expect(touchesCropEdge(const Rect.fromLTRB(0.0, 0.64, 0.8, 0.70), const Rect.fromLTRB(0, 0.6, 1, 0.97)),
          isFalse);
    });

    test('vote : un mot absent de la lecture de référence revient si d\'autres l\'ont lu', () {
      final dict = WordList.fromWords(['je', 'pense', 'que', 'tu', 'as', 'raison', 'mes', 'amis']);
      // Deux lectures renforcées identiques (sans le dernier mot) et une lecture normale complète.
      expect(
        ReadingVote.combine([
          const OcrReading('Je pense que tu as'),
          const OcrReading('Je pense que tu as'),
          const OcrReading('Je pense que tu as raison'),
          const OcrReading('Je pense que tu as raison'),
        ], dict: dict),
        'Je pense que tu as raison',
      );
      expect(
        ReadingVote.combine([
          const OcrReading('pense que tu as raison'),
          const OcrReading('pense que tu as raison'),
          const OcrReading('Je pense que tu as raison'),
        ], dict: dict),
        'Je pense que tu as raison',
      );
      // Un mot parasite vu une seule fois sur trois n'est pas ajouté.
      expect(
        ReadingVote.combine([
          const OcrReading('mes amis'),
          const OcrReading('mes amis'),
          const OcrReading('mes x amis'),
        ], dict: dict),
        'mes amis',
      );
    });

    test('suivi : après un écran vide, un sous-titre est dit en entier', () {
      final t = SubtitleTracker(stableFrames: 1);
      expect(t.push('Tu sais ce que je veux dire'), 'Tu sais ce que je veux dire');
      for (var i = 0; i < 3; i++) {
        t.push('');
      }
      expect(t.push('ce que je veux dire, voilà tout'), 'ce que je veux dire, voilà tout');
    });
  });
  group('Phrases sautées, traductions bizarres', () {
    test('file de la voix : de courts dialogues ne sont plus abandonnés', () {
      // 4 répliques courtes en attente (2 sous-titres) : rien n'est retiré.
      expect(
        SpeechService.toDrop([
          (batch: 1, weight: 8), (batch: 1, weight: 6),
          (batch: 2, weight: 10), (batch: 2, weight: 7), (batch: 3, weight: 12),
        ], SpeechService.maxWaitingChars),
        0,
      );
    });
    test('file de la voix : trop de retard, les plus anciens sous-titres entiers partent', () {
      expect(
        SpeechService.toDrop([
          (batch: 1, weight: 30), (batch: 1, weight: 20),
          (batch: 2, weight: 100), (batch: 3, weight: 120),
        ], 240),
        2, // les deux répliques du sous-titre 1
      );
      // Jamais le dernier sous-titre arrivé, même très long.
      expect(SpeechService.toDrop([(batch: 5, weight: 400)], 240), 0);
      expect(SpeechService.toDrop([(batch: 4, weight: 50), (batch: 5, weight: 400)], 240), 1);
    });

    test('suivi : deux répliques qui se ressemblent sont dites toutes les deux', () {
      final t = SubtitleTracker(stableFrames: 1);
      expect(t.push('Oui, monsieur.'), 'Oui, monsieur.');
      expect(t.push('Non, monsieur.'), 'Non, monsieur.');
    });
    test('suivi : la même réplique, plus tard, est redite', () {
      final t = SubtitleTracker(stableFrames: 1);
      expect(t.push('Non merci.'), 'Non merci.');
      for (var i = 0; i < 12; i++) {
        t.push('Je ne viens pas avec toi ce soir.');
      }
      expect(t.push('Non merci.'), 'Non merci.');
    });
    test('suivi : relu juste après un trou de lecture, pas redit', () {
      final t = SubtitleTracker(stableFrames: 1);
      expect(t.push('Non merci.'), 'Non merci.');
      for (var i = 0; i < 3; i++) {
        t.push('');
      }
      expect(t.push('Non merci.'), isNull);
    });

    test('traduction : pause d\'un moteur en ligne selon l\'erreur', () {
      expect(SubtitleTranslator.pauseAfter(456), const Duration(hours: 6)); // quota DeepL
      expect(SubtitleTranslator.pauseAfter(403), const Duration(hours: 6)); // clé refusée
      expect(SubtitleTranslator.pauseAfter(429), const Duration(seconds: 20));
      expect(SubtitleTranslator.pauseAfter(null), const Duration(minutes: 1)); // réseau
    });

    test('langue : un sous-titre moyen et peu sûr ne fait pas changer seul', () {
      final d = LanguageDecision('en');
      expect(d.update('Bon appétit à tous', {'fr': 0.8}), 'en');
      expect(d.update('Merci beaucoup, madame', {'fr': 0.8}), 'fr');
    });
  });
  test('traduction désactivée par défaut (lecture des sous-titres tels quels)', () {
    expect(kTranslationEnabled, isFalse);
  });

  group('Voix plus naturelle', () {
    test('sous-titre en majuscules remis en minuscules', () {
      expect(speakableText('TU VIENS ? NON, PAS CE SOIR.'), 'Tu viens ? Non, pas ce soir.');
      expect(speakableText("C'EST LE FBI ! OK."), "C'est le FBI ! OK.");
      expect(speakableText("I DON'T KNOW, I'M TIRED.", lang: 'en'), "I don't know, I'm tired.");
      expect(speakableText('ISTANBUL', lang: 'tr'), 'Istanbul');
    });

    test('texte normal et sigle isolé inchangés', () {
      expect(speakableText('Il travaille à la SNCF.'), 'Il travaille à la SNCF.');
      expect(speakableText('OK.'), 'OK.');
      expect(speakableText('NON'), 'Non'); // épelé « N, O, N » avant le 26/11/2026
    });

    test('nom du personnage retiré', () {
      expect(speakableText('JEAN : Tu viens ?'), 'Tu viens ?');
      expect(speakableText('MARIE-CLAIRE: Bonjour.'), 'Bonjour.');
      expect(speakableText('JOHN SMITH: Hello there.'), 'Hello there.');
      expect(speakableText('ATTENTION : la porte.'), 'Attention : la porte.');
      expect(speakableText('OK : on y va.'), 'OK : on y va.');
    });

    test('ponctuation adaptée à la voix', () {
      expect(speakableText('...et puis il est parti.'), 'et puis il est parti.');
      expect(speakableText('Je...je ne sais pas...'), 'Je… je ne sais pas…');
      expect(speakableText('Quoi ?!! Non !!!'), 'Quoi ?! Non !');
      expect(speakableText('Il a dit « demain ».'), 'Il a dit demain.');
      expect(speakableText('UN HOMME EST LÀ.'), 'Un homme est là.');
      expect(speakableText('Oui - enfin, non.'), 'Oui, enfin, non.');
      expect(speakableText('...'), '...');
    });

    test('voix robotiques jamais choisies automatiquement', () {
      final c = VoiceCatalog()
        ..load([
          {'name': 'Eddy', 'locale': 'fr-FR', 'quality': 'default', 'gender': 'male',
            'identifier': 'com.apple.eloquence.fr-FR.Eddy'},
          {'name': 'Albert', 'locale': 'en-US', 'quality': 'default', 'gender': 'male',
            'identifier': 'com.apple.speech.synthesis.voice.Albert'},
          {'name': 'Samantha', 'locale': 'en-US', 'quality': 'default', 'gender': 'female',
            'identifier': 'com.apple.voice.compact.en-US.Samantha'},
          {'name': 'Thomas', 'locale': 'fr-FR', 'quality': 'default', 'gender': 'male',
            'identifier': 'com.apple.voice.compact.fr-FR.Thomas'},
        ]);
      expect(c.best('fr')!.name, 'Thomas');
      expect(c.best('en')!.name, 'Samantha');
      // 2e personnage : pas Eddy ni Albert, la même voix sera prise (plus grave).
      expect(c.secondVoice('fr', c.best('fr')), isNull);
      expect(c.secondVoice('en', c.best('en')), isNull);
      expect(c.labelsFor('fr')['Eddy|fr-FR'], contains('robotique'));
      expect(kSecondVoicePitch, greaterThan(0.8));
    });
  });
  test('barre de langue : « Auto » et la langue du téléphone', () {
    expect(phoneLanguage('fr-FR').code, 'fr');
    expect(phoneLanguage('de-AT').code, 'de');
    expect(phoneLanguage('nb-NO').code, 'no');
    expect(phoneLanguage('zh-Hans-CN').code, 'zh');
    expect(phoneLanguage('pt-BR').code, 'pt');
    // Téléphone dans une langue que VoxLiso ne lit pas : le français.
    expect(phoneLanguage('ar-EG').code, 'fr');
  });
  group('Sous-titres brefs', () {
    final dict = WordList.fromWords(
        ['non', 'merci', 'je', 'ne', 'sais', 'pas', 'quoi', 'faire']);
    SubtitleTracker tracker() => SubtitleTracker()..dictionary = () => dict;

    test('vu une seule fois, fait de vrais mots : dit quand même', () {
      final t = tracker();
      expect(t.push('Non merci.'), isNull);
      expect(t.push('Je ne sais pas quoi faire.'), 'Non merci.');
    });
    test('image floue vue une seule fois : pas dite', () {
      final t = tracker();
      expect(t.push('Nqn mrc1.'), isNull);
      expect(t.push('Je ne sais pas quoi faire.'), isNull);
    });
    test('début d\'un sous-titre qui apparaît : pas dit à part', () {
      final t = tracker();
      expect(t.push('Je ne sais'), isNull);
      expect(t.push('Je ne sais pas quoi faire.'), isNull);
      expect(t.push('Je ne sais pas quoi faire.'), 'Je ne sais pas quoi faire.');
    });
    test('vu une fois puis écran vide : dit à la 2e image vide', () {
      final t = tracker();
      expect(t.push('Non merci.'), isNull);
      expect(t.push(''), isNull);
      expect(t.push(''), 'Non merci.');
    });
    test('sans dictionnaire : comme avant (deux images)', () {
      final t = SubtitleTracker();
      expect(t.push('Non merci.'), isNull);
      expect(t.push('Je ne sais pas quoi faire.'), isNull);
    });
  });

  group('Bips de cadrage', () {
    test('rien dans la zone : pas de bip', () {
      expect(aimBeepHz(0, 1), isNull);
    });
    test('plus aigu quand le texte est lisible', () {
      expect(aimBeepHz(1, readabilityFromConfidence([0.3, 0.35])), 440);
      expect(aimBeepHz(2, readabilityFromConfidence([0.97, 0.99])), 1320);
      final mid = aimBeepHz(1, readabilityFromConfidence([0.7]))!;
      expect(mid, greaterThan(440));
      expect(mid, lessThan(1320));
      expect(readabilityFromConfidence(const []), 0.5);
    });
  });
  group('Profils de zone', () {
    const salon = ZoneProfile(
        name: 'Télé du salon', top: 0.6, bottom: 0.9, left: 0.1, right: 0.9, zoom: 2, exposure: -1);
    const bureau = ZoneProfile(
        name: 'Ordinateur', top: 0.7, bottom: 0.95, left: 0.2, right: 0.8, zoom: 1, exposure: 0);

    test('enregistrés puis relus', () {
      final back = decodeProfiles(encodeProfiles([salon, bureau]));
      expect(back.map((p) => p.name), ['Télé du salon', 'Ordinateur']);
      expect(back.first.zoom, 2);
      expect(back.first.exposure, -1);
    });
    test('même nom : remplacé ; supprimé par son nom', () {
      final changed = ZoneProfile(
          name: 'télé du salon', top: 0.5, bottom: 0.8, left: 0.1, right: 0.9, zoom: 1, exposure: 0);
      final list = upsertProfile([salon, bureau], changed);
      expect(list.length, 2);
      expect(list.first.top, 0.5);
      expect(removeProfile(list, 'ORDINATEUR').map((p) => p.name), ['télé du salon']);
    });
    test('8 profils au plus', () {
      var list = <ZoneProfile>[];
      for (var i = 0; i < 10; i++) {
        list = upsertProfile(list, ZoneProfile(
            name: 'P$i', top: 0.6, bottom: 0.9, left: 0.1, right: 0.9, zoom: 1, exposure: 0));
      }
      expect(list.length, ZoneProfile.max);
      expect(list.first.name, 'P2');
    });
    test('profil en cours reconnu', () {
      expect(salon.matches(top: 0.601, bottom: 0.9, left: 0.1, right: 0.9, zoom: 2, exposure: -1), isTrue);
      expect(salon.matches(top: 0.7, bottom: 0.9, left: 0.1, right: 0.9, zoom: 2, exposure: -1), isFalse);
    });
    test('données abîmées : liste vide', () {
      expect(decodeProfiles('pas du json'), isEmpty);
      expect(decodeProfiles('[{"top": 0.5}]'), isEmpty);
    });
  });
  group('Mots épelés lettre par lettre (retour du 26/11/2026)', () {
    test('mot en majuscules dans une phrase normale', () {
      expect(speakableText('Il a dit NON !'), 'Il a dit Non !');
      expect(speakableText('Je VEUX partir.'), 'Je Veux partir.');
      expect(speakableText('Bienvenue à PARIS.'), 'Bienvenue à Paris.');
    });
    test('réplique courte en majuscules', () {
      expect(speakableText('OUI.'), 'Oui.');
      expect(speakableText('- TU ? - MOI.'), '- Tu ? - Moi.');
    });
    test('majuscule mal lue au milieu d\'un mot', () {
      expect(speakableText('Tu vIens ?'), 'Tu viens ?');
      expect(speakableText('SHte plaît'), 'Shte plaît');
    });
    test('lettres espacées', () {
      expect(speakableText('N O N, merci.'), 'Non, merci.');
    });
    test('sigles, chiffres romains et codes gardés', () {
      expect(speakableText('Le FBI arrive.'), 'Le FBI arrive.');
      expect(speakableText('Louis XIV est là.'), 'Louis XIV est là.');
      expect(speakableText('Appelle le MI6.'), 'Appelle le MI6.');
      expect(speakableText('On regarde la TV.'), 'On regarde la TV.');
    });
  });
}
