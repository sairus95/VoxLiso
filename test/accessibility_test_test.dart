import 'package:flutter_test/flutter_test.dart';
import 'package:voxliso/accessibility_test.dart';

void main() {
  group('Test accessibilité', () {
    test('entrée lue depuis le service natif, position et ligne du journal', () {
      final e = A11yEntry.fromMap({
        'time': DateTime(2026, 11, 25, 23, 10, 5).millisecondsSinceEpoch,
        'pkg': 'com.netflix.mediaclient',
        'text': 'Où étais-tu ?\nJe t\'ai cherché.',
        't': 0.80,
        'b': 0.90,
        'id': 'player_subtitles',
        'cls': 'TextView',
        'source': 'texte',
      });
      expect(e.appName, 'Netflix');
      expect(e.position, 'bas 85 %');
      expect(e.logLine,
          '23:10:05  Netflix  [bas 85 %, id=player_subtitles, TextView]  Où étais-tu ? / Je t\'ai cherché.');
    });

    test('annonce sans position', () {
      final e = A11yEntry.fromMap({'time': 0, 'pkg': 'x.y', 'text': 'Bonjour', 'source': 'annonce'});
      expect(e.position, '');
      expect(e.appName, 'x.y');
      expect(e.logLine.endsWith('x.y  [annonce]  Bonjour'), isTrue);
    });

    test('un même texte n\'est pas redit avant 30 s', () {
      final f = SpokenFilter();
      final t0 = DateTime(2026);
      A11yEntry e(String text) => A11yEntry(time: t0, pkg: 'p', text: text);
      expect(f.accept(e('Lecture'), now: t0), isTrue);
      expect(f.accept(e('lecture '), now: t0.add(const Duration(seconds: 10))), isFalse);
      expect(f.accept(e('Bonjour'), now: t0.add(const Duration(seconds: 10))), isTrue);
      expect(f.accept(e('Lecture'), now: t0.add(const Duration(seconds: 31))), isTrue);
      expect(f.accept(e('a'), now: t0), isFalse);
    });
  });
}
