import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Version destinée aux boutiques (Play Store, App Store) : compilée avec
/// `--dart-define=STORE_BUILD=true`. Les autres versions (APK publié sur
/// GitHub, compilation sur l'ordinateur) ont toutes les fonctions débloquées.
const bool kStoreBuild = bool.fromEnvironment('STORE_BUILD');

/// Fonctions réservées à VoxLiso Plus.
enum PlusFeature {
  translation('Traduction des sous-titres',
      'Lire les sous-titres traduits dans une autre langue, sur le téléphone ou avec DeepL.'),
  screen('Lecture de l\'écran du téléphone',
      'Lire les sous-titres des vidéos regardées sur ce téléphone (YouTube, navigateur…).'),
  blackScreen('Écran noir pendant la lecture',
      'Après 8 secondes sans toucher le téléphone, l\'écran passe au noir : il ne gêne pas '
          'dans le noir et la batterie dure plus longtemps. Un toucher le rallume.');

  const PlusFeature(this.title, this.description);
  final String title;
  final String description;
}

/// Achat unique « VoxLiso Plus » (produit non consommable, sans abonnement).
///
/// Identifiant du produit à créer, à l'identique, dans la Play Console
/// (Monétiser > Produits intégrés) et dans App Store Connect (Achats intégrés,
/// type « Non consommable ») : [productId].
class Premium extends ChangeNotifier {
  Premium._();
  static final Premium instance = Premium._();

  static const String productId = 'voxliso_plus';
  static const String _prefKey = 'plusUnlocked';

  SharedPreferences? _prefs;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  bool _started = false;

  bool _unlocked = !kStoreBuild;

  /// Toutes les fonctions sont débloquées.
  bool get unlocked => _unlocked;
  bool has(PlusFeature f) => _unlocked;

  /// La boutique répond (Play Store / App Store connecté).
  bool storeAvailable = false;

  /// Le produit et son prix, dans la monnaie de l'utilisateur.
  ProductDetails? product;

  /// Un achat ou une restauration est en cours.
  bool busy = false;

  /// Le paiement attend une validation (paiement en espèces, contrôle parental…).
  bool pending = false;

  /// Dernier message à afficher (erreur, rien à restaurer…).
  String? message;

  /// Lit l'achat mémorisé, puis interroge la boutique sans bloquer le démarrage.
  Future<void> init() async {
    if (_started) return;
    _started = true;
    if (!kStoreBuild) return;
    _prefs = await SharedPreferences.getInstance();
    _unlocked = _prefs!.getBool(_prefKey) ?? false;
    unawaited(_connect());
  }

  Future<void> _connect() async {
    final iap = InAppPurchase.instance;
    _sub = iap.purchaseStream.listen(
      _onPurchases,
      onError: (Object e) => _set(message: 'Boutique : $e', busy: false),
    );
    try {
      storeAvailable = await iap.isAvailable();
      if (!storeAvailable) {
        _set(message: 'La boutique n\'est pas disponible sur ce téléphone.');
        return;
      }
      final r = await iap.queryProductDetails({productId});
      product = r.productDetails.where((p) => p.id == productId).firstOrNull;
      if (product == null) {
        _set(message: r.error?.message ?? 'VoxLiso Plus n\'est pas encore proposé dans la boutique.');
      } else {
        _set();
      }
      // Android : retrouve l'achat sans rien demander (réinstallation, autre
      // téléphone). Sur iPhone, la restauration peut demander le mot de passe
      // Apple : elle ne se fait que par le bouton « Restaurer mes achats ».
      if (defaultTargetPlatform == TargetPlatform.android) await iap.restorePurchases();
    } catch (e) {
      _set(message: 'Boutique indisponible : $e');
    }
  }

  /// Ouvre la fenêtre de paiement de la boutique.
  Future<void> buy() async {
    final p = product;
    if (p == null) {
      _set(message: 'VoxLiso Plus n\'est pas disponible pour l\'instant. Réessayez plus tard.');
      return;
    }
    _set(busy: true, message: null);
    try {
      final started =
          await InAppPurchase.instance.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: p));
      if (!started) _set(busy: false);
    } catch (e) {
      _set(busy: false, message: 'Achat impossible : $e');
    }
  }

  /// Retrouve un achat déjà payé (nouveau téléphone, réinstallation).
  Future<void> restore() async {
    if (!kStoreBuild) return;
    _set(busy: true, message: null);
    try {
      await InAppPurchase.instance.restorePurchases();
      // Rien n'arrive si aucun achat n'est trouvé : on le dit après un délai.
      await Future<void>.delayed(const Duration(seconds: 4));
      if (busy) {
        _set(
          busy: false,
          message: _unlocked ? null : 'Aucun achat VoxLiso Plus trouvé pour ce compte.',
        );
      }
    } catch (e) {
      _set(busy: false, message: 'Restauration impossible : $e');
    }
  }

  Future<void> _onPurchases(List<PurchaseDetails> purchases) async {
    for (final p in purchases) {
      if (p.productID != productId) continue;
      switch (p.status) {
        case PurchaseStatus.pending:
          pending = true;
          _set(busy: false, message: 'Paiement en attente de validation.');
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _unlock();
        case PurchaseStatus.error:
          pending = false;
          _set(busy: false, message: 'Achat non abouti : ${p.error?.message ?? 'erreur inconnue'}');
        case PurchaseStatus.canceled:
          pending = false;
          _set(busy: false, message: null);
      }
      // Obligatoire : sans confirmation, Google rembourse l'achat au bout de
      // 3 jours, et l'App Store le renvoie à chaque lancement.
      if (p.pendingCompletePurchase) {
        try {
          await InAppPurchase.instance.completePurchase(p);
        } catch (_) {}
      }
    }
  }

  Future<void> _unlock() async {
    pending = false;
    _unlocked = true;
    await _prefs?.setBool(_prefKey, true);
    _set(busy: false, message: null);
  }

  void _set({bool? busy, String? message}) {
    if (busy != null) this.busy = busy;
    this.message = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
