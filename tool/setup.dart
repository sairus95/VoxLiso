// Configure les dossiers android/ et ios/ générés par `flutter create`.
//
// Utilisation (depuis le dossier du projet) :
//   flutter create --platforms=android,ios --org com.voixsoustitres .
//   dart run tool/setup.dart
//
// Le script peut être relancé sans risque : il ne modifie que ce qui manque.
import 'dart:io';

const appName = 'Voix Sous-Titres';
const iosTarget = '15.5'; // minimum exigé par ML Kit
const androidMinSdk = 24; // minimum exigé par le plugin camera

void main() {
  var ok = true;
  ok &= _android();
  ok &= _ios();
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

void _removeDefaultWidgetTest() {
  // Le test d'exemple de `flutter create` cherche une classe MyApp qui n'existe pas ici.
  final t = File('test/widget_test.dart');
  if (t.existsSync() && t.readAsStringSync().contains('MyApp')) t.deleteSync();
}

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
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
$_podTargetSettings
  end
end
''';

const _podTargetSettings = '''
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '$iosTarget'
      if target.respond_to?(:product_type) && target.product_type == 'com.apple.product-type.bundle'
        config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
      end
    end''';
