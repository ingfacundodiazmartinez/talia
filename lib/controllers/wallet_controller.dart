import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/credit_wallet_service.dart';
import '../services/ad_service.dart';
import '../utils/release_logger.dart';

const int _adsDailyCap = 50;

/// Genera "YYYY-MM-DD" en UTC, igual que el backend, para calcular si el daily
/// bonus está disponible y si el contador de ads debe resetearse.
String _todayUtc() {
  final now = DateTime.now().toUtc();
  final yyyy = now.year.toString().padLeft(4, '0');
  final mm = now.month.toString().padLeft(2, '0');
  final dd = now.day.toString().padLeft(2, '0');
  return '$yyyy-$mm-$dd';
}

/// Entrada del historial de transacciones para mostrar en UI.
class WalletTransaction {
  final String id;
  final String type; // earn | spend | grant | refund
  final int amount;
  final String reason;
  final int balanceAfter;
  final DateTime? createdAt;

  WalletTransaction({
    required this.id,
    required this.type,
    required this.amount,
    required this.reason,
    required this.balanceAfter,
    required this.createdAt,
  });

  factory WalletTransaction.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return WalletTransaction(
      id: doc.id,
      type: d['type'] as String? ?? 'earn',
      amount: (d['amount'] as num?)?.toInt() ?? 0,
      reason: d['reason'] as String? ?? 'unknown',
      balanceAfter: (d['balanceAfter'] as num?)?.toInt() ?? 0,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  /// Etiqueta legible en español de la razón.
  String get reasonLabel {
    switch (reason) {
      case 'welcome_bonus':
        return 'Bono de bienvenida';
      case 'daily_bonus':
        return 'Bono diario';
      case 'rewarded_ad':
        return 'Video visto';
      case 'premium_monthly':
        return 'Bono mensual Premium';
      case 'manual_grant':
        return 'Regalo de Talia';
      case 'face_swap':
        return 'Face-swap';
      case 'image_edit':
        return 'Transformación con IA';
      case 'image_edit_hd':
        return 'Transformación HD';
      case 'report':
        return 'Reporte de actividad';
      default:
        if (reason.startsWith('refund_')) {
          return 'Reintegro';
        }
        return reason;
    }
  }

  /// Signo a mostrar: positivo en earn/grant/refund, negativo en spend.
  bool get isPositive => type == 'earn' || type == 'grant' || type == 'refund';
}

/// Controller que coordina el wallet screen con servicios.
class WalletController {
  final CreditWalletService _walletService = CreditWalletService();
  final AdService _adService = AdService();

  /// Stream realtime del status del wallet, leyendo directamente del doc
  /// Firestore. Esto garantiza que el balance se actualiza apenas el backend
  /// procesa una transacción (welcome, daily, ad, spend, refund).
  Stream<CreditWalletStatus?> watchStatus() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Stream.value(null);

    return FirebaseFirestore.instance
        .collection('credit_wallets')
        .doc(uid)
        .snapshots()
        .map(_statusFromDoc);
  }

  CreditWalletStatus? _statusFromDoc(DocumentSnapshot doc) {
    if (!doc.exists) return null;
    final d = doc.data() as Map<String, dynamic>;
    final today = _todayUtc();
    final counterDate = d['todayCounterDate'] as String?;
    final todayAds = (counterDate == today)
        ? ((d['todayAdsWatched'] as num?)?.toInt() ?? 0)
        : 0;

    return CreditWalletStatus(
      balance: (d['balance'] as num?)?.toInt() ?? 0,
      lifetimeEarned: (d['lifetimeEarned'] as num?)?.toInt() ?? 0,
      lifetimeSpent: (d['lifetimeSpent'] as num?)?.toInt() ?? 0,
      todayAdsWatched: todayAds,
      todayAdsCapRemaining: (_adsDailyCap - todayAds).clamp(0, _adsDailyCap),
      welcomeBonusGranted: d['welcomeBonusGranted'] as bool? ?? false,
      lastDailyBonusDate: d['lastDailyBonusDate'] as String?,
      canClaimDailyBonus: d['lastDailyBonusDate'] != today,
    );
  }

  /// Stream del historial (directo de Firestore para realtime).
  Stream<List<WalletTransaction>> watchTransactions({int limit = 20}) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Stream.value([]);
    return FirebaseFirestore.instance
        .collection('credit_transactions')
        .where('walletId', isEqualTo: uid)
        .limit(limit)
        .snapshots()
        .map((snap) {
      final txs = snap.docs.map(WalletTransaction.fromDoc).toList()
        ..sort((a, b) {
          final aT = a.createdAt?.millisecondsSinceEpoch ?? 0;
          final bT = b.createdAt?.millisecondsSinceEpoch ?? 0;
          return bT.compareTo(aT);
        });
      return txs;
    });
  }

  /// Force-create del wallet doc llamando getWalletStatus, útil la primera vez
  /// que el padre abre la pantalla y todavía no hay doc en Firestore.
  Future<void> ensureWalletExists() async {
    await _walletService.getStatus();
  }

  /// Reclamar daily bonus. Retorna true si se acreditó algo nuevo.
  Future<bool> claimDailyBonus() async {
    return _walletService.claimDailyBonus();
  }

  /// Ver un rewarded ad. El crédito se acredita automáticamente vía AdService
  /// → CreditWalletService → backend → Firestore doc → realtime listener actualiza UI.
  Future<AdResult> watchAdForCredit() async {
    try {
      if (!_adService.isRewardedAdLoaded) {
        await _adService.loadRewardedAd();
        await Future.delayed(const Duration(milliseconds: 500));
      }

      if (!_adService.isRewardedAdLoaded) {
        return AdResult.notReady;
      }

      final earned = await _adService.showRewardedAd();
      return earned ? AdResult.earned : AdResult.dismissed;
    } catch (e) {
      ReleaseLogger.error('Error mostrando ad: $e', tag: 'WalletController');
      return AdResult.error;
    }
  }

  void dispose() {
    // No hay nada que cerrar: los streams son directos de Firestore.
  }
}

enum AdResult { earned, dismissed, notReady, error }
