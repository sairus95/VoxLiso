import 'package:flutter_test/flutter_test.dart';
import 'package:voxliso/premium.dart';

void main() {
  test('hors boutique (APK GitHub, tests) : VoxLiso Plus est débloqué', () async {
    expect(kStoreBuild, isFalse);
    await Premium.instance.init();
    expect(Premium.instance.unlocked, isTrue);
    for (final f in PlusFeature.values) {
      expect(Premium.instance.has(f), isTrue);
    }
  });
}
