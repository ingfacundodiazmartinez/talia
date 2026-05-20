import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../utils/release_logger.dart';

/// Estado del wallet de créditos del padre, retornado por getWalletStatus.
class CreditWalletStatus {
  final int balance;
  final int lifetimeEarned;
  final int lifetimeSpent;
  final int todayAdsWatched;
  final int todayAdsCapRemaining;
  final bool welcomeBonusGranted;
  final String? lastDailyBonusDate;
  final bool canClaimDailyBonus;

  CreditWalletStatus({
    required this.balance,
    required this.lifetimeEarned,
    required this.lifetimeSpent,
    required this.todayAdsWatched,
    required this.todayAdsCapRemaining,
    required this.welcomeBonusGranted,
    required this.lastDailyBonusDate,
    required this.canClaimDailyBonus,
  });

  factory CreditWalletStatus.fromMap(Map<String, dynamic> data) {
    return CreditWalletStatus(
      balance: (data['balance'] as num?)?.toInt() ?? 0,
      lifetimeEarned: (data['lifetimeEarned'] as num?)?.toInt() ?? 0,
      lifetimeSpent: (data['lifetimeSpent'] as num?)?.toInt() ?? 0,
      todayAdsWatched: (data['todayAdsWatched'] as num?)?.toInt() ?? 0,
      todayAdsCapRemaining: (data['todayAdsCapRemaining'] as num?)?.toInt() ?? 0,
      welcomeBonusGranted: data['welcomeBonusGranted'] as bool? ?? false,
      lastDailyBonusDate: data['lastDailyBonusDate'] as String?,
      canClaimDailyBonus: data['canClaimDailyBonus'] as bool? ?? false,
    );
  }
}

/// Servicio cliente para el wallet familiar de créditos (Fase 1: modo sombra).
///
/// Documentación: WALLET_SPEC.md
///
/// Fase 1: las cloud functions se llaman pero la app NO consume créditos todavía
/// para gatear features. Solo se acumulan en background hasta que se active
/// el feature flag wallet_enabled.
class CreditWalletService {
  static final CreditWalletService _instance = CreditWalletService._internal();
  factory CreditWalletService() => _instance;
  CreditWalletService._internal();

  final FirebaseFunctions _functions = FirebaseFunctions.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Stream del balance disponible para el current user.
  ///
  /// - Si el user es padre (role: parent/adult) → escucha su propio wallet.
  /// - Si el user es hijo → lee linkedParentsData del user doc y escucha
  ///   el wallet del primer padre linkado. (MVP: 1 padre. Multi-parent en v2.)
  ///
  /// Devuelve null si el user no está autenticado o no tiene padre/wallet.
  /// Devuelve 0 si el wallet existe pero está vacío.
  ///
  /// Uso típico (vista del niño en el character selector):
  ///   `StreamBuilder<int?>(stream: walletService.watchMaxAvailableCredits(), ...)`
  Stream<int?> watchMaxAvailableCredits() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Stream.value(null);

    return _firestore
        .collection('users')
        .doc(uid)
        .snapshots()
        .asyncExpand((userSnap) {
      if (!userSnap.exists) return Stream<int?>.value(null);
      final data = userSnap.data()!;
      final role = data['role'] as String?;

      // Si es padre, escucha su propio wallet
      if (role == 'parent' || role == 'adult') {
        return _watchWalletBalance(uid);
      }

      // Si es hijo, busca el primer padre linkado y escucha su wallet
      final linkedParentsData = data['linkedParentsData'] as Map<String, dynamic>?;
      if (linkedParentsData == null || linkedParentsData.isEmpty) {
        return Stream<int?>.value(null);
      }
      final firstParentId = linkedParentsData.keys.first;
      return _watchWalletBalance(firstParentId);
    });
  }

  Stream<int?> _watchWalletBalance(String walletId) {
    return _firestore
        .collection('credit_wallets')
        .doc(walletId)
        .snapshots()
        .map((s) {
      if (!s.exists) return 0;
      return (s.data()!['balance'] as num?)?.toInt() ?? 0;
    });
  }

  /// Lee el estado completo del wallet del usuario autenticado.
  /// Devuelve null si el usuario no es padre (permission-denied o not-found).
  Future<CreditWalletStatus?> getStatus() async {
    try {
      final result = await _functions.httpsCallable('getWalletStatus').call();
      return CreditWalletStatus.fromMap(
        Map<String, dynamic>.from(result.data as Map),
      );
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'permission-denied' || e.code == 'not-found') {
        // No es padre o usuario no existe — esperable en algunos flujos
        return null;
      }
      ReleaseLogger.warning(
        'getWalletStatus falló: ${e.code} ${e.message}',
        tag: 'CreditWalletService',
      );
      return null;
    } catch (e) {
      ReleaseLogger.error('getWalletStatus error: $e', tag: 'CreditWalletService');
      return null;
    }
  }

  /// Reclama el welcome bonus (20 créditos, one-time).
  /// Devuelve true si se acreditó, false si ya estaba reclamado o falló.
  Future<bool> claimWelcomeBonus() async {
    try {
      await _functions.httpsCallable('claimWelcomeBonus').call();
      ReleaseLogger.log('🎁 Welcome bonus reclamado', tag: 'CreditWalletService');
      return true;
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'already-exists') {
        // Ya estaba reclamado — no es error, es estado esperado en re-runs
        return false;
      }
      ReleaseLogger.warning(
        'claimWelcomeBonus falló: ${e.code} ${e.message}',
        tag: 'CreditWalletService',
      );
      return false;
    } catch (e) {
      ReleaseLogger.error('claimWelcomeBonus error: $e', tag: 'CreditWalletService');
      return false;
    }
  }

  /// Reclama el daily bonus (5 créditos, idempotente por día UTC).
  /// Devuelve true si se acreditó, false si ya estaba reclamado hoy.
  Future<bool> claimDailyBonus() async {
    try {
      await _functions.httpsCallable('claimDailyBonus').call();
      ReleaseLogger.log('☀️ Daily bonus reclamado', tag: 'CreditWalletService');
      return true;
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'already-exists') {
        // Ya se reclamó hoy
        return false;
      }
      ReleaseLogger.warning(
        'claimDailyBonus falló: ${e.code} ${e.message}',
        tag: 'CreditWalletService',
      );
      return false;
    } catch (e) {
      ReleaseLogger.error('claimDailyBonus error: $e', tag: 'CreditWalletService');
      return false;
    }
  }

  /// Acredita 1 crédito por haber visto un rewarded ad.
  /// [adId] debe ser único por impresión para evitar double-crediting.
  /// Devuelve true si se acreditó, false si era duplicado o se alcanzó el tope diario.
  Future<bool> earnCreditsFromAd({
    required String adId,
    String adNetwork = 'admob',
    String? ssvSignature,
  }) async {
    try {
      await _functions.httpsCallable('earnCreditsFromAd').call({
        'adId': adId,
        'adNetwork': adNetwork,
        if (ssvSignature != null) 'ssvSignature': ssvSignature,
      });
      return true;
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'already-exists') {
        // adId ya acreditado, no es error
        return false;
      }
      if (e.code == 'resource-exhausted') {
        // Tope diario alcanzado — no es error técnico
        ReleaseLogger.log(
          '⚠️ Tope diario de ads alcanzado',
          tag: 'CreditWalletService',
        );
        return false;
      }
      if (e.code == 'permission-denied') {
        // Usuario no es padre, ignorar silenciosamente
        return false;
      }
      ReleaseLogger.warning(
        'earnCreditsFromAd falló: ${e.code} ${e.message}',
        tag: 'CreditWalletService',
      );
      return false;
    } catch (e) {
      ReleaseLogger.error('earnCreditsFromAd error: $e', tag: 'CreditWalletService');
      return false;
    }
  }
}
