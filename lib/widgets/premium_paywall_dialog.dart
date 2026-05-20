import 'package:talia/theme_service.dart';
import 'package:flutter/material.dart';
import '../services/subscription_service.dart';
import '../services/app_config_service.dart';
import '../screens/settings/subscription_screen.dart';

/// Dialog de paywall para mostrar cuando el usuario intenta usar una feature premium
/// Soft paywall: muestra las funcionalidades premium y permite navegar a la pantalla de suscripción
class PremiumPaywallDialog extends StatelessWidget {
  final PremiumFeature feature;

  const PremiumPaywallDialog({
    super.key,
    required this.feature,
  });

  /// Mostrar el paywall dialog
  ///
  /// Si el feature flag `premium_enabled` está desactivado, no muestra nada
  static Future<void> show(
    BuildContext context, {
    required PremiumFeature feature,
  }) {
    // Feature flag: si premium está desactivado, no mostrar paywall
    if (!AppConfigService().premiumEnabled) {
      return Future.value();
    }

    return showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (context) => PremiumPaywallDialog(feature: feature),
    );
  }

  // Colores según el tier requerido
  List<Color> get _gradientColors {
    if (feature.requiredTier == SubscriptionTier.premiumPlus) {
      return [const Color(0xFFD4AF37), const Color(0xFFFFD700)];
    }
    return [const Color(0xFF7B5FC7), ThemeService.primaryColor];
  }

  Color get _primaryColor {
    return feature.requiredTier == SubscriptionTier.premiumPlus
        ? const Color(0xFFD4AF37)
        : ThemeService.primaryColor;
  }

  IconData get _tierIcon {
    return feature.requiredTier == SubscriptionTier.premiumPlus
        ? Icons.workspace_premium
        : Icons.star_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1E1E2E) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtextColor = isDark ? Colors.grey[400] : Colors.grey[600];

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 340),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: _primaryColor.withValues(alpha: 0.3),
              blurRadius: 30,
              spreadRadius: 0,
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header con gradiente
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 32),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: _gradientColors,
                ),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  // Icono con efecto glow
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.white.withValues(alpha: 0.3),
                          blurRadius: 20,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: Icon(
                      _tierIcon,
                      color: Colors.white,
                      size: 44,
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Título del tier
                  Text(
                    feature.requiredTier == SubscriptionTier.premiumPlus
                        ? 'Contenido Premium+'
                        : 'Contenido Premium',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),

            // Contenido
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  // Feature bloqueada
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _primaryColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: _primaryColor.withValues(alpha: 0.3),
                        width: 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        // Icono de la feature
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: _primaryColor.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Text(
                              feature.iconName,
                              style: const TextStyle(fontSize: 24),
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        // Nombre y descripción
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                feature.name,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: textColor,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                feature.description,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: subtextColor,
                                  height: 1.3,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Beneficios rápidos
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildBenefit(Icons.bolt, 'Acceso\ninmediato', subtextColor),
                      _buildBenefit(Icons.all_inclusive, 'Sin\nlímites', subtextColor),
                      _buildBenefit(Icons.verified, 'Exclusivo', subtextColor),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Botón principal
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => const SubscriptionScreen(),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primaryColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 4,
                        shadowColor: _primaryColor.withValues(alpha: 0.4),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            feature.requiredTier == SubscriptionTier.premiumPlus
                                ? Icons.workspace_premium
                                : Icons.star_rounded,
                            size: 22,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Obtener ${feature.requiredTier.displayName}',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Botón secundario
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'Ahora no',
                      style: TextStyle(
                        color: subtextColor,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBenefit(IconData icon, String label, Color? textColor) {
    return Column(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: _primaryColor.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: _primaryColor, size: 22),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            color: textColor,
            fontWeight: FontWeight.w500,
            height: 1.2,
          ),
        ),
      ],
    );
  }
}

/// Widget para mostrar un badge "Premium" en features bloqueadas
class PremiumBadge extends StatelessWidget {
  final SubscriptionTier requiredTier;
  final bool mini;

  const PremiumBadge({
    super.key,
    required this.requiredTier,
    this.mini = false,
  });

  // Colores diferenciados por tier
  List<Color> get _gradientColors {
    if (requiredTier == SubscriptionTier.premiumPlus) {
      // Premium+: Dorado/Oro
      return [const Color(0xFFD4AF37), const Color(0xFFFFD700)];
    }
    // Premium: Púrpura (colores del tema)
    return [const Color(0xFF7B5FC7), ThemeService.primaryColor];
  }

  IconData get _icon {
    return requiredTier == SubscriptionTier.premiumPlus
        ? Icons.workspace_premium  // Corona/diamante para Premium+
        : Icons.star;              // Estrella para Premium
  }

  Color get _iconColor {
    return requiredTier == SubscriptionTier.premiumPlus
        ? Colors.white
        : Colors.amber;
  }

  String get _label {
    return requiredTier == SubscriptionTier.premiumPlus ? 'PRO+' : 'PRO';
  }

  @override
  Widget build(BuildContext context) {
    // Feature flag: si premium está desactivado, no mostrar badge
    if (!AppConfigService().premiumEnabled) {
      return const SizedBox.shrink();
    }

    if (mini) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: _gradientColors),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, color: _iconColor, size: 10),
            const SizedBox(width: 2),
            Text(
              _label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 8,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: _gradientColors),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, color: _iconColor, size: 16),
          const SizedBox(width: 6),
          Text(
            requiredTier.displayName.toUpperCase(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}
