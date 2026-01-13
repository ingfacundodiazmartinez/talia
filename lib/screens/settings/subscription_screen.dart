import 'dart:io';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/subscription_service.dart';
import '../../services/in_app_purchase_service.dart';
import '../../services/app_config_service.dart';

/// Pantalla de gestión de suscripción Premium
class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  final SubscriptionService _subscriptionService = SubscriptionService();
  final InAppPurchaseService _iapService = InAppPurchaseService();

  PremiumStatus? _currentStatus;
  Map<SubscriptionTier, String>? _prices;
  bool _isLoading = true;
  bool _isPurchasing = false;
  String? _errorMessage;
  SubscriptionTier _selectedTier = SubscriptionTier.premium;

  // Colores alineados con el tema de la app (ThemeService)
  static const Color _primaryPurple = Color(0xFF9D7FE8);  // primaryColor
  static const Color _secondaryPurple = Color(0xFF7B5FC7); // primaryDarkColor
  static const Color _accentGold = Color(0xFFFFD700);

  @override
  void initState() {
    super.initState();
    _checkPremiumEnabled();
    _loadData();
    _setupPurchaseListener();
  }

  /// Verifica si el sistema premium está habilitado
  /// Si está desactivado, cierra la pantalla
  void _checkPremiumEnabled() {
    if (!AppConfigService().premiumEnabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.of(context).pop();
        }
      });
    }
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      await _iapService.initialize();
      final status = await _subscriptionService.checkPremiumStatus(forceRefresh: true);
      final prices = await _iapService.getPrices();

      if (mounted) {
        setState(() {
          _currentStatus = status;
          _prices = prices;
          _isLoading = false;
          // Si ya es premium+, seleccionar ese tier
          if (status.tier == SubscriptionTier.premiumPlus) {
            _selectedTier = SubscriptionTier.premiumPlus;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Error cargando información: $e';
          _isLoading = false;
        });
      }
    }
  }

  void _setupPurchaseListener() {
    _iapService.onPurchaseResult = (result) {
      if (mounted) {
        // No quitar loading si es pending
        if (!result.pending) {
          setState(() => _isPurchasing = false);
        }

        // Determinar color e icono según el tipo de resultado
        Color backgroundColor;
        IconData icon;

        if (result.pending) {
          // Estado de procesamiento - color neutro/info
          backgroundColor = _primaryPurple;
          icon = Icons.hourglass_top;
        } else if (result.success) {
          // Verificar si es un mensaje de "no encontrado" (info, no éxito real)
          final isInfoMessage = result.message.contains('No se encontraron');
          if (isInfoMessage) {
            backgroundColor = Colors.blueGrey;
            icon = Icons.info_outline;
          } else {
            // Éxito real
            backgroundColor = Colors.green;
            icon = Icons.check_circle;
            _loadData(); // Recargar estado solo en éxito real
          }
        } else if (result.canceled) {
          // Cancelado por el usuario - color neutro
          backgroundColor = Colors.grey[600]!;
          icon = Icons.cancel_outlined;
        } else {
          // Error real
          backgroundColor = Colors.red;
          icon = Icons.error_outline;
        }

        // Limpiar snackbars anteriores
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(icon, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    result.message,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
            backgroundColor: backgroundColor,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            duration: result.pending
                ? const Duration(seconds: 10) // Pending se cierra cuando llega otro resultado
                : const Duration(seconds: 3),
          ),
        );
      }
    };
  }

  Future<void> _purchaseSubscription(SubscriptionTier tier) async {
    setState(() => _isPurchasing = true);
    await _iapService.purchaseSubscription(tier);
  }

  Future<void> _restorePurchases() async {
    setState(() => _isPurchasing = true);
    await _iapService.restorePurchases();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _isLoading
          ? _buildLoadingState()
          : CustomScrollView(
              slivers: [
                _buildSliverAppBar(),
                SliverToBoxAdapter(child: _buildContent()),
              ],
            ),
    );
  }

  Widget _buildLoadingState() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_primaryPurple, _secondaryPurple],
        ),
      ),
      child: const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );
  }

  Widget _buildSliverAppBar() {
    final isPremium = _currentStatus?.isPremium ?? false;
    final tier = _currentStatus?.tier ?? SubscriptionTier.free;
    // Calcular altura basada en si tiene fecha de expiración
    final hasExpiry = _currentStatus?.expiresAt != null;
    final expandedHeight = isPremium && hasExpiry ? 260.0 : 230.0;

    return SliverAppBar(
      expandedHeight: expandedHeight,
      pinned: true,
      backgroundColor: _primaryPurple,
      foregroundColor: Colors.white,
      flexibleSpace: FlexibleSpaceBar(
        background: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_primaryPurple, _secondaryPurple],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 50),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Icono
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isPremium ? Icons.workspace_premium : Icons.star_outline,
                      size: 40,
                      color: isPremium ? _accentGold : Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    isPremium ? 'Eres ${tier.displayName}' : 'Talia Premium',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isPremium
                        ? 'Gracias por ser parte de Talia'
                        : 'Desbloquea todas las funciones',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                  if (hasExpiry) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'Válido hasta ${_formatDate(_currentStatus!.expiresAt!)}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    final colorScheme = Theme.of(context).colorScheme;
    final isPremium = _currentStatus?.isPremium ?? false;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Selector de planes (siempre visible)
          _buildPlanSelector(colorScheme),
          const SizedBox(height: 24),

          // Beneficios del plan seleccionado
          _buildBenefitsSection(colorScheme),
          const SizedBox(height: 24),

          // Botón de suscripción
          _buildSubscribeButton(colorScheme),
          const SizedBox(height: 16),

          // Restaurar compras (solo si no tiene suscripción)
          if (!isPremium) _buildRestoreButton(colorScheme),

          // Cancelar suscripción (solo si tiene suscripción)
          if (isPremium) ...[
            _buildCancelSubscriptionButton(colorScheme),
            const SizedBox(height: 8),
          ],

          if (_errorMessage != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(color: colorScheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 24),

          // Términos y condiciones
          _buildTermsSection(colorScheme),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildPlanSelector(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Elige tu plan',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: _buildPlanCard(
                tier: SubscriptionTier.premium,
                colorScheme: colorScheme,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildPlanCard(
                tier: SubscriptionTier.premiumPlus,
                colorScheme: colorScheme,
                isBestValue: true,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPlanCard({
    required SubscriptionTier tier,
    required ColorScheme colorScheme,
    bool isBestValue = false,
  }) {
    final isSelected = _selectedTier == tier;
    final isCurrentPlan = _currentStatus?.tier == tier;
    final price = _prices?[tier] ?? '\$${tier.monthlyPrice.toStringAsFixed(2)}';

    return GestureDetector(
      // ✅ FIX: Permitir seleccionar cualquier plan (incluso el actual) para ver beneficios
      // El botón de suscripción ya maneja el caso de plan actual mostrando "Plan Actual"
      onTap: () => setState(() => _selectedTier = tier),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: isSelected
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [_primaryPurple, _secondaryPurple],
                )
              : null,
          color: isSelected ? null : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? _primaryPurple : colorScheme.outline.withValues(alpha: 0.3),
            width: isSelected ? 2 : 1,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: _primaryPurple.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Column(
          children: [
            // Badge de mejor valor
            if (isBestValue)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isSelected ? Colors.white : _accentGold,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'MEJOR VALOR',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isSelected ? _primaryPurple : Colors.black87,
                  ),
                ),
              ),
            // Nombre del plan
            Text(
              tier.displayName,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: isSelected ? Colors.white : colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            // Precio
            Text(
              price,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: isSelected ? Colors.white : _primaryPurple,
              ),
            ),
            Text(
              '/mes',
              style: TextStyle(
                fontSize: 14,
                color: isSelected
                    ? Colors.white.withValues(alpha: 0.8)
                    : colorScheme.onSurfaceVariant,
              ),
            ),
            if (isCurrentPlan) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.green,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'ACTUAL',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBenefitsSection(ColorScheme colorScheme) {
    final benefits = _selectedTier.benefits;
    final icons = _getBenefitIcons(_selectedTier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle, color: _primaryPurple, size: 24),
            const SizedBox(width: 8),
            Text(
              'Incluye:',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              ...List.generate(benefits.length, (index) {
                return Padding(
                  padding: EdgeInsets.only(
                    bottom: index < benefits.length - 1 ? 12 : 0,
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: _primaryPurple.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Text(
                            icons[index],
                            style: const TextStyle(fontSize: 18),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          benefits[index],
                          style: TextStyle(
                            fontSize: 15,
                            color: colorScheme.onSurface,
                          ),
                        ),
                    ),
                  ],
                ),
              );
            }),
              // Nota sobre moderación
              if (_selectedTier != SubscriptionTier.free) ...[
                const SizedBox(height: 12),
                Text(
                  '* La moderación de multimedia analiza contenido para detectar material inapropiado. '
                  'Puede haber fallos ocasionales debido a límites de la API o errores de red.',
                  style: TextStyle(
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  List<String> _getBenefitIcons(SubscriptionTier tier) {
    switch (tier) {
      case SubscriptionTier.free:
        return ['🎭', '👤', '📺'];
      case SubscriptionTier.premium:
        return ['🎭', '⭐', '🚫', '📊', '🎤'];
      case SubscriptionTier.premiumPlus:
        return ['🎭', '👑', '🚫', '📊', '🛡️', '👨‍👩‍👧‍👦', '💬'];
    }
  }

  Widget _buildSubscribeButton(ColorScheme colorScheme) {
    final isCurrentPlan = _currentStatus?.tier == _selectedTier;
    final currentTier = _currentStatus?.tier ?? SubscriptionTier.free;

    // Si es plan actual
    if (isCurrentPlan) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.green),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle, color: Colors.green),
            SizedBox(width: 8),
            Text(
              'Plan Actual',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.green,
              ),
            ),
          ],
        ),
      );
    }

    // Determinar si es upgrade o downgrade
    final isUpgrade = _selectedTier == SubscriptionTier.premiumPlus &&
                      currentTier == SubscriptionTier.premium;
    final isDowngrade = _selectedTier == SubscriptionTier.premium &&
                        currentTier == SubscriptionTier.premiumPlus;

    // Determinar texto e icono del botón
    String buttonText;
    IconData buttonIcon;
    List<Color> gradientColors;

    if (isUpgrade) {
      buttonText = 'Mejorar a Premium+';
      buttonIcon = Icons.rocket_launch;
      gradientColors = [_primaryPurple, _secondaryPurple];
    } else if (isDowngrade) {
      buttonText = 'Cambiar a Premium';
      buttonIcon = Icons.swap_vert;
      gradientColors = [Colors.orange, Colors.deepOrange];
    } else {
      buttonText = 'Suscribirse a ${_selectedTier.displayName}';
      buttonIcon = Icons.rocket_launch;
      gradientColors = [_primaryPurple, _secondaryPurple];
    }

    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: LinearGradient(colors: gradientColors),
            boxShadow: [
              BoxShadow(
                color: gradientColors[0].withValues(alpha: 0.4),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ElevatedButton(
            onPressed: _isPurchasing
                ? null
                : () => isDowngrade
                    ? _showDowngradeConfirmation()
                    : _purchaseSubscription(_selectedTier),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.transparent,
              shadowColor: Colors.transparent,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: _isPurchasing
                ? const SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(buttonIcon, color: Colors.white),
                      const SizedBox(width: 8),
                      Text(
                        buttonText,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        // Nota para downgrade
        if (isDowngrade) ...[
          const SizedBox(height: 8),
          Text(
            'El cambio se aplicará en tu próximo ciclo de facturación',
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }

  void _showDowngradeConfirmation() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.swap_vert, color: Colors.orange),
            SizedBox(width: 8),
            Text('Cambiar de plan'),
          ],
        ),
        content: const Text(
          '¿Estás seguro de que deseas cambiar a Premium?\n\n'
          'Perderás acceso a las funciones exclusivas de Premium+ como el plan familiar y soporte prioritario.\n\n'
          'El cambio se aplicará en tu próximo ciclo de facturación.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _purchaseSubscription(_selectedTier);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
            ),
            child: const Text('Confirmar cambio'),
          ),
        ],
      ),
    );
  }

  Widget _buildRestoreButton(ColorScheme colorScheme) {
    return TextButton.icon(
      onPressed: _isPurchasing ? null : _restorePurchases,
      icon: Icon(Icons.restore, color: colorScheme.primary),
      label: Text(
        'Restaurar compras anteriores',
        style: TextStyle(
          color: colorScheme.primary,
          fontSize: 14,
        ),
      ),
    );
  }

  Widget _buildCancelSubscriptionButton(ColorScheme colorScheme) {
    return TextButton.icon(
      onPressed: _showCancelSubscriptionDialog,
      icon: Icon(Icons.cancel_outlined, color: colorScheme.error),
      label: Text(
        'Cancelar suscripción',
        style: TextStyle(
          color: colorScheme.error,
          fontSize: 14,
        ),
      ),
    );
  }

  void _showCancelSubscriptionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            SizedBox(width: 8),
            Expanded(child: Text('Cancelar suscripción')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '¿Estás seguro de que deseas cancelar tu suscripción?\n',
            ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '• Mantendrás acceso hasta el final del período actual',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    '• Perderás todos los beneficios premium',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '• Puedes volver a suscribirte cuando quieras',
                    style: TextStyle(fontSize: 13, color: Colors.green[700]),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              Platform.isAndroid
                  ? 'Serás redirigido a Google Play para gestionar tu suscripción.'
                  : 'Serás redirigido a la App Store para gestionar tu suscripción.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Volver'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _openSubscriptionManagement();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Ir a cancelar'),
          ),
        ],
      ),
    );
  }

  Future<void> _openSubscriptionManagement() async {
    final Uri url;

    if (Platform.isAndroid) {
      // URL de Google Play para gestión de suscripciones
      url = Uri.parse('https://play.google.com/store/account/subscriptions');
    } else {
      // URL de App Store para gestión de suscripciones
      url = Uri.parse('https://apps.apple.com/account/subscriptions');
    }

    try {
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                Platform.isAndroid
                    ? 'Abre Google Play > Menú > Suscripciones'
                    : 'Abre Ajustes > Tu nombre > Suscripciones',
              ),
              backgroundColor: Colors.orange,
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('No se pudo abrir la tienda'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Widget _buildTermsSection(ColorScheme colorScheme) {
    // Obtener precio del plan seleccionado para mostrar en términos
    final selectedPrice = _prices?[_selectedTier] ?? '\$${_selectedTier.monthlyPrice.toStringAsFixed(2)}';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Título de la sección
          Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 20,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                'Información de la suscripción',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // ✅ Requisitos de Apple: Información clara de la suscripción
          _buildSubscriptionInfoRow(
            colorScheme,
            'Suscripción:',
            '${_selectedTier.displayName} (auto-renovable)',
          ),
          const SizedBox(height: 4),
          _buildSubscriptionInfoRow(
            colorScheme,
            'Duración:',
            '1 mes',
          ),
          const SizedBox(height: 4),
          _buildSubscriptionInfoRow(
            colorScheme,
            'Precio:',
            '$selectedPrice/mes',
          ),

          const SizedBox(height: 12),

          // Texto de renovación automática
          Text(
            'El pago se cargará a tu cuenta de ${Platform.isIOS ? "iTunes" : "Google Play"} al confirmar la compra. '
            'La suscripción se renueva automáticamente cada mes a menos que se cancele al menos 24 horas antes del final del período actual. '
            'Puedes gestionar y cancelar tu suscripción desde la configuración de tu cuenta de ${Platform.isIOS ? "App Store" : "Google Play"}.',
            textAlign: TextAlign.left,
            style: TextStyle(
              fontSize: 11,
              color: colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),

          const SizedBox(height: 16),

          // ✅ Links requeridos por Apple - más prominentes
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GestureDetector(
                onTap: () => _openUrl('https://taliachat.com/terms'),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    border: Border.all(color: colorScheme.primary.withValues(alpha: 0.5)),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    'Términos de Uso (EULA)',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () => _openUrl('https://taliachat.com/privacy'),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    border: Border.all(color: colorScheme.primary.withValues(alpha: 0.5)),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    'Política de Privacidad',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSubscriptionInfoRow(ColorScheme colorScheme, String label, String value) {
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
        ),
      ],
    );
  }

  Future<void> _openUrl(String urlString) async {
    final url = Uri.parse(urlString);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  String _formatDate(DateTime date) {
    final months = [
      'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
      'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic'
    ];
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }
}
