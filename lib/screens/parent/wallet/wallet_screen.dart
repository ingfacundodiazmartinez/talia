import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../controllers/wallet_controller.dart';
import '../../../services/credit_wallet_service.dart';

/// Pantalla del wallet de créditos del padre.
///
/// Muestra:
/// - Balance actual grande
/// - Lifetime stats (ganados, gastados)
/// - CTA principal: "Ver un video para ganar 1 crédito"
/// - Tope diario de ads (X/50)
/// - Historial de últimas transacciones
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  late final WalletController _controller;
  bool _watchingAd = false;

  // Último balance conocido (del stream) y override optimista para que el
  // contador suba al instante al terminar el video, sin esperar el round-trip
  // de la CF + propagación del snapshot de Firestore.
  int _lastKnownBalance = 0;
  int? _optimisticBalance;
  Timer? _optimisticTimer;

  @override
  void initState() {
    super.initState();
    _controller = WalletController();
    // Si el wallet doc todavía no existe (padre que nunca abrió el shell), lo
    // creamos llamando getWalletStatus. El listener se actualiza solo después.
    _controller.ensureWalletExists();
  }

  @override
  void dispose() {
    _optimisticTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onWatchAdPressed() async {
    setState(() => _watchingAd = true);

    final result = await _controller.watchAdForCredit();

    if (!mounted) return;
    setState(() => _watchingAd = false);

    final messenger = ScaffoldMessenger.of(context);
    switch (result) {
      case AdResult.earned:
        // ✅ Optimista: mostrar +1 al instante. El stream lo confirma en 1-3s; si
        // por throttle no se acreditó, el timer revierte al valor real.
        setState(() => _optimisticBalance = _lastKnownBalance + 1);
        _optimisticTimer?.cancel();
        _optimisticTimer = Timer(const Duration(seconds: 6), () {
          if (mounted) setState(() => _optimisticBalance = null);
        });
        messenger.showSnackBar(
          const SnackBar(
            content: Text('¡Ganaste 1 crédito!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
        break;
      case AdResult.dismissed:
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Necesitás ver el video completo para ganar el crédito'),
            duration: Duration(seconds: 3),
          ),
        );
        break;
      case AdResult.notReady:
        messenger.showSnackBar(
          const SnackBar(
            content: Text('No hay videos disponibles ahora. Intentá en un rato.'),
            duration: Duration(seconds: 3),
          ),
        );
        break;
      case AdResult.error:
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Hubo un error mostrando el video'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mi billetera'),
      ),
      body: StreamBuilder<CreditWalletStatus?>(
        stream: _controller.watchStatus(),
        builder: (context, snapshot) {
          final status = snapshot.data;

          if (status == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Cargando tu billetera...'),
                  ],
                ),
              ),
            );
          }

          // Cachear el balance real del stream para el cálculo optimista.
          _lastKnownBalance = status.balance;
          // Si el stream ya alcanzó (o superó) el optimista, descartarlo.
          if (_optimisticBalance != null && status.balance >= _optimisticBalance!) {
            _optimisticTimer?.cancel();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _optimisticBalance = null);
            });
          }
          // Balance a mostrar: el mayor entre el real y el optimista.
          final displayBalance = _optimisticBalance != null
              ? math.max(status.balance, _optimisticBalance!)
              : status.balance;

          return RefreshIndicator(
            onRefresh: _controller.ensureWalletExists,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _BalanceCard(status: status, displayBalance: displayBalance),
                const SizedBox(height: 16),
                _LifetimeStatsRow(status: status),
                const SizedBox(height: 24),
                _EarnAdButton(
                  status: status,
                  isLoading: _watchingAd,
                  onPressed: _onWatchAdPressed,
                ),
                const SizedBox(height: 24),
                const _SectionTitle('Historial'),
                const SizedBox(height: 8),
                _TransactionsList(controller: _controller),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  final CreditWalletStatus status;
  final int displayBalance;

  const _BalanceCard({required this.status, required this.displayBalance});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primary,
            colorScheme.primary.withValues(alpha: 0.7),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Text(
            'Saldo',
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onPrimary.withValues(alpha: 0.85),
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.auto_awesome,
                color: colorScheme.onPrimary,
                size: 36,
              ),
              const SizedBox(width: 8),
              Text(
                '$displayBalance',
                style: TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            displayBalance == 1 ? 'crédito disponible' : 'créditos disponibles',
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onPrimary.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }
}

class _LifetimeStatsRow extends StatelessWidget {
  final CreditWalletStatus status;

  const _LifetimeStatsRow({required this.status});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _StatCard(
            label: 'Ganados',
            value: status.lifetimeEarned,
            icon: Icons.trending_up,
            color: Colors.green,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _StatCard(
            label: 'Gastados',
            value: status.lifetimeSpent,
            icon: Icons.trending_down,
            color: Colors.orange,
          ),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final int value;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '$value',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _EarnAdButton extends StatelessWidget {
  final CreditWalletStatus status;
  final bool isLoading;
  final VoidCallback onPressed;

  const _EarnAdButton({
    required this.status,
    required this.isLoading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final capReached = status.todayAdsCapRemaining <= 0;

    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton.icon(
            onPressed: (isLoading || capReached) ? null : onPressed,
            icon: isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_circle_outline),
            label: Text(
              isLoading
                  ? 'Cargando video...'
                  : capReached
                      ? 'Tope diario alcanzado'
                      : 'Ver un video para ganar 1 crédito',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Hoy ganaste ${status.todayAdsWatched} de 50 créditos por video',
          style: TextStyle(
            fontSize: 12,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}

class _TransactionsList extends StatelessWidget {
  final WalletController controller;

  const _TransactionsList({required this.controller});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<WalletTransaction>>(
      stream: controller.watchTransactions(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final txs = snapshot.data!;
        if (txs.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                'Sin movimientos todavía',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }

        return Column(
          children: txs.map((tx) => _TransactionTile(tx: tx)).toList(),
        );
      },
    );
  }
}

class _TransactionTile extends StatelessWidget {
  final WalletTransaction tx;

  const _TransactionTile({required this.tx});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = tx.isPositive ? Colors.green : Colors.orange;
    final sign = tx.isPositive ? '+' : '-';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            tx.isPositive ? Icons.add_circle_outline : Icons.remove_circle_outline,
            color: color,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _buildTitle(tx),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: colorScheme.onSurface,
                  ),
                ),
                if (tx.createdAt != null)
                  Text(
                    _formatDate(tx.createdAt!),
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          Text(
            '$sign${tx.amount}',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    final diff = now.difference(local);
    if (diff.inMinutes < 1) return 'hace un instante';
    if (diff.inMinutes < 60) return 'hace ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'hace ${diff.inHours} h';
    if (diff.inDays < 7) return 'hace ${diff.inDays} d';
    return '${local.day}/${local.month}/${local.year}';
  }

  // Construye el título: si el initiator es un hijo (no es el padre dueño del
  // wallet), prepende su nombre. Ej: "Tade · Face-swap". Para earns/grants
  // del propio padre, solo el label de la razón.
  String _buildTitle(WalletTransaction tx) {
    final name = tx.initiatedByName;
    final role = tx.initiatedByRole;
    final isChild = role == 'child' && name != null && name.isNotEmpty;
    if (isChild && tx.type == 'spend') {
      return '$name · ${tx.reasonLabel}';
    }
    return tx.reasonLabel;
  }
}
