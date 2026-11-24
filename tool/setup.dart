// Configure les dossiers android/ et ios/ générés par `flutter create`.
//
// Utilisation (depuis le dossier du projet) :
//   flutter create --platforms=android,ios --org com.voxliso .
//   dart run tool/setup.dart
//
// Le script peut être relancé sans risque : il ne modifie que ce qui manque.
import 'dart:io';

const appName = 'VoxLiso';
const iosTarget = '15.5'; // minimum exigé par ML Kit
const androidMinSdk = 24; // minimum exigé par le plugin camera

void main() {
  var ok = true;
  ok &= _android();
  _bergamotAndroid();
  ok &= _ios();
  ok &= _appleTranslation();
  ok &= _icons();
  _removeDefaultWidgetTest();
  stdout.writeln(ok
      ? '\n✅ Configuration terminée. Lancez : flutter run'
      : '\n⚠️  Certaines étapes ont échoué (voir ci-dessus).');
  if (!ok) exitCode = 1;
}

bool _android() {
  final manifest = File('android/app/src/main/AndroidManifest.xml');
  if (!manifest.existsSync()) {
    stderr.writeln("❌ android/ introuvable : lancez d'abord `flutter create`.");
    return false;
  }
  var xml = manifest.readAsStringSync();

  if (!xml.contains('android.permission.CAMERA')) {
    xml = xml.replaceFirst(
      '<application',
      '<uses-permission android:name="android.permission.CAMERA" />\n    <application',
    );
  }
  if (!xml.contains('android.intent.action.TTS_SERVICE')) {
    const ttsIntent = '<intent>\n'
        '            <action android:name="android.intent.action.TTS_SERVICE" />\n'
        '        </intent>';
    if (xml.contains('<queries>')) {
      xml = xml.replaceFirst('<queries>', '<queries>\n        $ttsIntent');
    } else {
      xml = xml.replaceFirst(
        '</manifest>',
        '    <queries>\n        $ttsIntent\n    </queries>\n</manifest>',
      );
    }
  }
  xml = xml.replaceFirst(RegExp(r'android:label="[^"]*"'), 'android:label="$appName"');
  manifest.writeAsStringSync(xml);
  stdout.writeln('✔ AndroidManifest.xml : caméra, synthèse vocale, nom');

  final gradle = [
    File('android/app/build.gradle.kts'),
    File('android/app/build.gradle'),
  ].where((f) => f.existsSync()).firstOrNull;
  if (gradle == null) {
    stderr.writeln('❌ android/app/build.gradle(.kts) introuvable');
    return false;
  }
  var g = gradle.readAsStringSync();
  final minSdkRe = RegExp(r'minSdk(Version)?\s*=?\s*(flutter\.minSdkVersion|\d+)');
  final m = minSdkRe.firstMatch(g);
  if (m == null) {
    stderr.writeln('⚠️  minSdk introuvable dans ${gradle.path} : mettez-le à $androidMinSdk');
    return false;
  }
  final current = int.tryParse(m.group(2)!) ?? 0;
  if (current < androidMinSdk) {
    g = g.replaceFirst(minSdkRe, 'minSdk = $androidMinSdk');
    gradle.writeAsStringSync(g);
  }
  stdout.writeln('✔ ${gradle.path} : minSdk >= $androidMinSdk');

  // ML Kit référence les modèles chinois/japonais/coréen/devanagari, que
  // l'application n'utilise pas (alphabet latin seulement) : l'optimiseur R8
  // doit les ignorer. Flutter charge automatiquement android/app/proguard-rules.pro.
  // Pas de compactage R8 : il retirait des classes de ML Kit appelées par
  // réflexion (NullPointerException « getClass() » à l'analyse des images).
  if (!g.contains('isMinifyEnabled = false') && !g.contains('minifyEnabled false')) {
    final kts = gradle.path.endsWith('.kts');
    final signRe = RegExp(r'(\n(\s*)signingConfig\s*=?\s*signingConfigs[^\n]*)');
    final sm = signRe.firstMatch(g);
    if (sm != null) {
      final indent = sm.group(2)!;
      final extra = kts
          ? '\n${indent}isMinifyEnabled = false\n${indent}isShrinkResources = false'
          : '\n${indent}minifyEnabled false\n${indent}shrinkResources false';
      g = g.replaceFirst(signRe, '${sm.group(1)}$extra');
      gradle.writeAsStringSync(g);
    }
  }
  final props = File('android/gradle.properties');
  if (props.existsSync() && !props.readAsStringSync().contains('shrink=')) {
    props.writeAsStringSync('${props.readAsStringSync().trimRight()}\nshrink=false\n');
  }
  stdout.writeln('✔ Compactage R8 désactivé');

  final proguard = File('android/app/proguard-rules.pro');
  final existing = proguard.existsSync() ? proguard.readAsStringSync() : '';
  if (!existing.contains('com.google.mlkit.vision.text.chinese')) {
    proguard.writeAsStringSync('$existing\n$_proguardRules');
  }
  stdout.writeln('✔ proguard-rules.pro : modèles ML Kit inutilisés ignorés');
  if (!_releaseSigning(gradle)) return false;
  return _screenCapture(gradle);
}

/// Signature des versions destinées au Play Store : si android/key.properties
/// existe (créé par GitHub Actions à partir des secrets ANDROID_RELEASE_*),
/// la clé d'envoi Google Play est utilisée ; sinon, la clé « debug » habituelle.
bool _releaseSigning(File gradle) {
  var g = gradle.readAsStringSync();
  if (g.contains('key.properties')) {
    stdout.writeln('✔ Signature Play Store déjà configurée');
    return true;
  }
  if (!gradle.path.endsWith('.kts')) {
    stderr.writeln('⚠️  ${gradle.path} : signature Play Store à configurer à la main');
    return false;
  }
  const debugLine = 'signingConfig = signingConfigs.getByName("debug")';
  if (!g.contains(debugLine) || !g.contains('\nandroid {')) {
    stderr.writeln('❌ ${gradle.path} : configuration de signature introuvable');
    return false;
  }
  g = 'import java.io.FileInputStream\nimport java.util.Properties\n\n$g';
  g = g.replaceFirst('\nandroid {', '''

// Clé d'envoi Google Play (voir tool/setup.dart).
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) load(FileInputStream(keystorePropertiesFile))
}

android {
    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }''');
  g = g.replaceFirst(
    debugLine,
    'signingConfig = signingConfigs.getByName('
        'if (keystorePropertiesFile.exists()) "release" else "debug")',
  );
  gradle.writeAsStringSync(g);
  stdout.writeln('✔ Signature Play Store : clé de android/key.properties si présente');
  return true;
}

/// Lecture de l'écran du téléphone (vidéos YouTube, navigateur…) :
/// code Kotlin natif, permissions, service de capture et ML Kit natif.
bool _screenCapture(File gradle) {
  final kotlinRoot = Directory('android/app/src/main/kotlin');
  final activity = kotlinRoot.existsSync()
      ? kotlinRoot
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('MainActivity.kt'))
          .firstOrNull
      : null;
  if (activity == null) {
    stderr.writeln('❌ MainActivity.kt introuvable : lecture de l\'écran non installée');
    return false;
  }
  final pkg = RegExp(r'^package\s+([\w.]+)', multiLine: true)
          .firstMatch(activity.readAsStringSync())
          ?.group(1) ??
      'com.voxliso.voxliso';
  for (final src in Directory('native/android').listSync().whereType<File>()) {
    if (!src.path.endsWith('.kt')) continue;
    final name = src.uri.pathSegments.last;
    final code = src
        .readAsStringSync()
        .replaceFirst(RegExp(r'^package\s+[\w.]+', multiLine: true), 'package $pkg');
    File('${activity.parent.path}/$name').writeAsStringSync(code);
  }

  final manifest = File('android/app/src/main/AndroidManifest.xml');
  var xml = manifest.readAsStringSync();
  for (final perm in [
    'android.permission.INTERNET',
    'android.permission.REQUEST_INSTALL_PACKAGES',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION',
    'android.permission.POST_NOTIFICATIONS',
  ]) {
    if (!xml.contains('"$perm"')) {
      xml = xml.replaceFirst(
          '<application', '<uses-permission android:name="$perm" />\n    <application');
    }
  }
  if (!xml.contains('.ScreenCaptureService')) {
    xml = xml.replaceFirst(
      '</application>',
      '    <service\n'
          '            android:name=".ScreenCaptureService"\n'
          '            android:exported="false"\n'
          '            android:foregroundServiceType="mediaProjection" />\n'
          '    </application>',
    );
  }
  manifest.writeAsStringSync(xml);

  // Moteurs de reconnaissance : latin, plus chinois, japonais et coréen
  // (le module Flutter ne les déclare qu'en « compileOnly »).
  var g = gradle.readAsStringSync();
  const mlkit = [
    'com.google.mlkit:text-recognition:16.0.1',
    'com.google.mlkit:text-recognition-chinese:16.0.1',
    'com.google.mlkit:text-recognition-japanese:16.0.1',
    'com.google.mlkit:text-recognition-korean:16.0.1',
  ];
  final missing = [for (final m in mlkit) if (!g.contains(m)) m];
  if (missing.isNotEmpty) {
    final kts = gradle.path.endsWith('.kts');
    final lines = [for (final m in missing) kts ? '    implementation("$m")' : "    implementation '$m'"];
    g = '$g\ndependencies {\n${lines.join('\n')}\n}\n';
    gradle.writeAsStringSync(g);
  }
  stdout.writeln('✔ Lecture de l\'écran du téléphone : service natif ($pkg)');
  return true;
}

/// Traducteur du téléphone sur Android : libbergamot.so (compilée par la
/// tâche « bergamot » de la CI) dans l'APK, pour les téléphones 64 bits.
/// Absente : VoxLiso garde la traduction ML Kit.
void _bergamotAndroid() {
  final lib = File('native/bergamot/lib/libbergamot-android-arm64.so');
  if (!lib.existsSync()) {
    stdout.writeln('⚠️  libbergamot absente : traducteur du téléphone non inclus (ML Kit seulement)');
    return;
  }
  final dest = Directory('android/app/src/main/jniLibs/arm64-v8a')..createSync(recursive: true);
  lib.copySync('${dest.path}/libbergamot.so');
  stdout.writeln('✔ Traducteur du téléphone : libbergamot.so (arm64-v8a, ${lib.lengthSync() ~/ 1024} ko)');
}

/// Traducteur du téléphone sur iPhone (iOS 18+) : code Swift de
/// native/ios/VoxTranslation.swift ajouté à AppDelegate.swift et enregistré à
/// côté des modules Flutter ; cadre Translation lié en « weak » (absent avant
/// iOS 17.4, l'application doit quand même démarrer).
bool _appleTranslation() {
  final delegate = File('ios/Runner/AppDelegate.swift');
  final src = File('native/ios/VoxTranslation.swift');
  if (!delegate.existsSync() || !src.existsSync()) {
    stderr.writeln('❌ AppDelegate.swift introuvable : traduction Apple non installée');
    return false;
  }
  var code = delegate.readAsStringSync();
  if (!code.contains('class VoxTranslationPlugin')) {
    final reg = RegExp(r'GeneratedPluginRegistrant\.register\(with:\s*([^)]+)\)');
    final m = reg.firstMatch(code);
    if (m == null) {
      stderr.writeln('❌ AppDelegate.swift : GeneratedPluginRegistrant introuvable');
      return false;
    }
    final registry = m.group(1)!.trim();
    final line = code.substring(code.lastIndexOf('\n', m.start) + 1, m.start);
    final indent = RegExp(r'^\s*').firstMatch(line)!.group(0)!;
    code = code.replaceRange(m.end, m.end,
        '\n${indent}if let r = $registry.registrar(forPlugin: "VoxTranslationPlugin") {'
        '\n$indent  VoxTranslationPlugin.register(with: r)'
        '\n$indent}');
    // Les « import » en tête du fichier, le reste à la fin.
    const imports = '#if canImport(Translation)\nimport Translation\nimport SwiftUI\n#endif\n';
    final swift = src.readAsStringSync();
    if (!swift.contains(imports)) {
      stderr.writeln('❌ VoxTranslation.swift : bloc « import » attendu introuvable');
      return false;
    }
    code = '$imports$code\n\n${swift.replaceFirst(imports, '')}';
    delegate.writeAsStringSync(code);
  }
  final pbx = File('ios/Runner.xcodeproj/project.pbxproj');
  if (pbx.existsSync()) {
    var s = pbx.readAsStringSync();
    if (!s.contains('-weak_framework')) {
      // Seulement la cible Runner (pas RunnerTests, dont l'identifiant finit par .RunnerTests).
      s = s.replaceAllMapped(
        RegExp(r'^(\s*)PRODUCT_BUNDLE_IDENTIFIER = ([\w.]+);\n', multiLine: true),
        (m) => m[2]!.endsWith('RunnerTests')
            ? m[0]!
            : '${m[0]}${m[1]}OTHER_LDFLAGS = (\n${m[1]}\t"\$(inherited)",\n'
                '${m[1]}\t"-weak_framework",\n${m[1]}\tTranslation,\n${m[1]});\n',
      );
      pbx.writeAsStringSync(s);
    }
  }
  stdout.writeln('✔ Traduction Apple (iOS 18+) : VoxTranslationPlugin enregistré');
  return true;
}

bool _ios() {
  final plist = File('ios/Runner/Info.plist');
  if (!plist.existsSync()) {
    stderr.writeln("❌ ios/ introuvable : lancez d'abord `flutter create`.");
    return false;
  }
  var p = plist.readAsStringSync();
  final additions = StringBuffer();
  void addKey(String key, String value) {
    if (!p.contains('<key>$key</key>')) {
      additions.write('\t<key>$key</key>\n\t<string>$value</string>\n');
    }
  }

  addKey('NSCameraUsageDescription',
      "La caméra sert à lire les sous-titres affichés sur l'écran que vous visez.");
  addKey('NSMicrophoneUsageDescription',
      "Le micro n'est pas utilisé ; cette mention est exigée par le module caméra.");
  if (additions.isNotEmpty) {
    final i = p.lastIndexOf('</dict>');
    p = p.substring(0, i) + additions.toString() + p.substring(i);
  }
  p = p.replaceFirstMapped(
    RegExp(r'(<key>CFBundleDisplayName</key>\s*<string>)[^<]*(</string>)'),
    (m) => '${m[1]}$appName${m[2]}',
  );
  plist.writeAsStringSync(p);
  stdout.writeln('✔ Info.plist : autorisation caméra, nom');

  final pbx = File('ios/Runner.xcodeproj/project.pbxproj');
  if (pbx.existsSync()) {
    final s = pbx.readAsStringSync().replaceAll(
          RegExp(r'IPHONEOS_DEPLOYMENT_TARGET = [\d.]+;'),
          'IPHONEOS_DEPLOYMENT_TARGET = $iosTarget;',
        );
    pbx.writeAsStringSync(s);
    stdout.writeln('✔ Xcode : iOS minimum $iosTarget');
  }

  final podfile = File('ios/Podfile');
  if (podfile.existsSync()) {
    var pod = podfile.readAsStringSync();
    pod = pod.replaceFirst(
      RegExp(r"^#?\s*platform :ios, '[\d.]+'", multiLine: true),
      "platform :ios, '$iosTarget'",
    );
    // Reconnaissance du chinois, du japonais et du coréen (même version de ML Kit
    // que google_mlkit_text_recognition 0.17).
    const flutterPods = 'flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))';
    if (!pod.contains('TextRecognitionChinese') && pod.contains(flutterPods)) {
      pod = pod.replaceFirst(flutterPods, '$flutterPods\n$_cjkPods');
    }
    // Les « bundles » de ressources des pods (ML Kit…) n'ont pas à être signés.
    const marker = 'flutter_additional_ios_build_settings(target)';
    if (!pod.contains('CODE_SIGNING_ALLOWED') && pod.contains(marker)) {
      pod = pod.replaceFirst(marker, '$marker\n$_podTargetSettings');
    }
    podfile.writeAsStringSync(pod);
  } else {
    podfile.writeAsStringSync(_podfile);
  }
  stdout.writeln('✔ Podfile : iOS minimum $iosTarget');
  return true;
}

/// Remplace l'icône Flutter par défaut par celle de VoxLiso
/// (fichiers générés par tool/icone/make_icons.py dans assets/launcher).
bool _icons() {
  var count = 0;
  void copyTree(String from, String to) {
    final src = Directory(from);
    if (!src.existsSync()) return;
    for (final e in src.listSync(recursive: true).whereType<File>()) {
      final rel = e.path.substring(src.path.length + 1);
      final dest = File('$to/$rel');
      dest.parent.createSync(recursive: true);
      e.copySync(dest.path);
      count++;
    }
  }

  if (!Directory('assets/launcher').existsSync()) {
    stderr.writeln('⚠️  assets/launcher introuvable : icône par défaut conservée');
    return true;
  }
  copyTree('assets/launcher/android/res', 'android/app/src/main/res');
  copyTree('assets/launcher/ios/AppIcon.appiconset',
      'ios/Runner/Assets.xcassets/AppIcon.appiconset');
  stdout.writeln('✔ Icône VoxLiso : $count fichiers copiés');
  return true;
}

void _removeDefaultWidgetTest() {
  // Le test d'exemple de `flutter create` cherche une classe MyApp qui n'existe pas ici.
  final t = File('test/widget_test.dart');
  if (t.existsSync() && t.readAsStringSync().contains('MyApp')) t.deleteSync();
}

const _cjkPods = "  pod 'GoogleMLKit/TextRecognitionChinese', '~> 9.0.0'\n"
    "  pod 'GoogleMLKit/TextRecognitionJapanese', '~> 9.0.0'\n"
    "  pod 'GoogleMLKit/TextRecognitionKorean', '~> 9.0.0'";

const _podfile = '''
platform :ios, '$iosTarget'

# CocoaPods analytics sends network stats synchronously affecting flutter build latency.
ENV['COCOAPODS_DISABLE_STATS'] = 'true'

project 'Runner', {
  'Debug' => :debug,
  'Profile' => :release,
  'Release' => :release,
}

def flutter_root
  generated_xcode_build_settings_path = File.expand_path(File.join('..', 'Flutter', 'Generated.xcconfig'), __FILE__)
  unless File.exist?(generated_xcode_build_settings_path)
    raise "#{generated_xcode_build_settings_path} must exist. If you're running pod install manually, make sure flutter pub get is executed first"
  end

  File.foreach(generated_xcode_build_settings_path) do |line|
    matches = line.match(/FLUTTER_ROOT\\=(.*)/)
    return matches[1].strip if matches
  end
  raise "FLUTTER_ROOT not found in #{generated_xcode_build_settings_path}. Try deleting Generated.xcconfig, then run flutter pub get"
end

require File.expand_path(File.join('packages', 'flutter_tools', 'bin', 'podhelper'), flutter_root)

flutter_ios_podfile_setup

target 'Runner' do
  use_frameworks!

  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
  pod 'GoogleMLKit/TextRecognitionChinese', '~> 9.0.0'
  pod 'GoogleMLKit/TextRecognitionJapanese', '~> 9.0.0'
  pod 'GoogleMLKit/TextRecognitionKorean', '~> 9.0.0'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
$_podTargetSettings
  end
end
''';

const _proguardRules = '''
# ML Kit : seuls les sous-titres en alphabet latin sont lus.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
# Au cas où le compactage serait réactivé : ne rien retirer de ML Kit.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_** { *; }
-keep class com.google_mlkit_commons.** { *; }
-keep class com.google_mlkit_text_recognition.** { *; }
''';

const _podTargetSettings = '''
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '$iosTarget'
      if target.respond_to?(:product_type) && target.product_type == 'com.apple.product-type.bundle'
        config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
      end
    end''';
