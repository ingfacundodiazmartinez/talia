import 'package:flutter/material.dart';
import '../../../../services/subscription_service.dart';

/// Widget que muestra el estado premium del hijo
/// Puede tener premium compartido por un padre (family sharing)
class PremiumStatusWidget extends StatefulWidget {
  final String userId;
  final bool hasLinkedParent;

  const PremiumStatusWidget({
    super.key,
    required this.userId,
    required this.hasLinkedParent,
  });

  @override
  State<PremiumStatusWidget> createState() => _PremiumStatusWidgetState();
}

class _PremiumStatusWidgetState extends State<PremiumStatusWidget> {
  final SubscriptionService _subscriptionService = SubscriptionService();
  PremiumStatus? _premiumStatus;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPremiumStatus();
  }

  Future<void> _loadPremiumStatus() async {
    try {
      final status = await _subscriptionService.checkPremiumStatus(forceRefresh: true);
      if (mounted) {
        setState(() {
          _premiumStatus = status;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const SizedBox.shrink();
    }

    // Si el sistema premium está desactivado, no mostrar nada
    if (_premiumStatus?.premiumSystemDisabled == true) {
      return const SizedBox.shrink();
    }

    // Si tiene premium (propio o compartido), mostrar badge
    if (_premiumStatus?.isPremium == true) {
      return _buildPremiumActiveCard(context);
    }

    // Si no tiene premium pero tiene padre vinculado, mostrar info
    if (widget.hasLinkedParent) {
      return _buildNoPremiumWithParentCard(context);
    }

    // Si no tiene premium ni padre vinculado, no mostrar nada
    // (el link status widget ya indica que necesitan vincular padre)
    return const SizedBox.shrink();
  }

  Widget _buildPremiumActiveCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isFamilySharing = _premiumStatus?.isFamilySharing == true;
    final ownerName = _premiumStatus?.familyOwnerName ?? 'tu padre/madre';

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.purple.withValues(alpha: 0.15),
            Colors.blue.withValues(alpha: 0.15),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.purple.withValues(alpha: 0.4),
          width: 1.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Colors.purple, Colors.blue],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.star,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Premium+',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Colors.purple, Colors.blue],
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'ACTIVO',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  isFamilySharing
                      ? 'Compartido por $ownerName'
                      : 'Tienes acceso a todas las funciones',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                if (_premiumStatus?.expiresAt != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Expira: ${_formatDate(_premiumStatus!.expiresAt!)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoPremiumWithParentCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.outline.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              Icons.star_border,
              color: colorScheme.onSurfaceVariant,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sin Premium',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Tu padre/madre puede activar Premium+ para compartirlo contigo',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }
}
