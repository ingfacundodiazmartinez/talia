import 'package:flutter/material.dart';
import '../services/subscription_service.dart';
import '../services/in_app_purchase_service.dart';

/// Dialog amigable que se muestra cuando el padre quiere agregar más hijos
/// de los incluidos en su plan Premium+
class ExtraChildPaywallDialog extends StatefulWidget {
  final ChildLimitResult limitResult;

  const ExtraChildPaywallDialog({
    super.key,
    required this.limitResult,
  });

  /// Muestra el dialog y retorna true si se completó la compra exitosamente
  static Future<bool> show(BuildContext context, ChildLimitResult limitResult) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => ExtraChildPaywallDialog(limitResult: limitResult),
    );
    return result ?? false;
  }

  @override
  State<ExtraChildPaywallDialog> createState() => _ExtraChildPaywallDialogState();
}

class _ExtraChildPaywallDialogState extends State<ExtraChildPaywallDialog> {
  final InAppPurchaseService _iapService = InAppPurchaseService();
  bool _isPurchasing = false;
  String? _errorMessage;
  String _extraChildPrice = '\$2.99';

  @override
  void initState() {
    super.initState();
    _loadPrice();
    _setupPurchaseCallback();
  }

  Future<void> _loadPrice() async {
    try {
      final products = await _iapService.getProducts();
      for (final product in products) {
        if (product.id.contains('extra_child')) {
          // Extraer solo el precio sin "/mes"
          setState(() {
            _extraChildPrice = product.price;
          });
          break;
        }
      }
    } catch (e) {
      // Usar precio por defecto
    }
  }

  void _setupPurchaseCallback() {
    _iapService.onPurchaseResult = (result) {
      if (!mounted) return;

      setState(() {
        _isPurchasing = false;
      });

      if (result.success) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 12),
                Text('Ahora puedes vincular un hijo mas'),
              ],
            ),
            backgroundColor: Colors.green,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      } else if (!result.canceled) {
        setState(() {
          _errorMessage = result.message;
        });
      }
    };
  }

  Future<void> _purchaseExtraChild() async {
    setState(() {
      _isPurchasing = true;
      _errorMessage = null;
    });

    try {
      await _iapService.purchaseExtraChild();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isPurchasing = false;
          _errorMessage = 'Error iniciando compra: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
      ),
      elevation: 8,
      child: Container(
        padding: const EdgeInsets.all(24),
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header con ilustracion amigable
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    colorScheme.primary.withValues(alpha: 0.2),
                    colorScheme.secondary.withValues(alpha: 0.2),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(
                    Icons.family_restroom,
                    size: 50,
                    color: colorScheme.primary,
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isDarkMode ? colorScheme.surface : Colors.white,
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        Icons.add,
                        size: 16,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Titulo amigable
            Text(
              'Familia numerosa?',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 8),

            // Subtitulo empatico
            Text(
              'Tu plan incluye ${widget.limitResult.maxChildren} hijos.\nAgrega mas para proteger a toda tu familia.',
              style: TextStyle(
                fontSize: 15,
                color: colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 24),

            // Tarjeta de oferta
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: isDarkMode
                      ? [
                          colorScheme.primaryContainer,
                          colorScheme.secondaryContainer,
                        ]
                      : [
                          colorScheme.primary.withValues(alpha: 0.08),
                          colorScheme.secondary.withValues(alpha: 0.08),
                        ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: colorScheme.primary.withValues(alpha: 0.2),
                  width: 1.5,
                ),
              ),
              child: Column(
                children: [
                  // Precio destacado
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _extraChildPrice,
                        style: TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.primary,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          '/mes',
                          style: TextStyle(
                            fontSize: 16,
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 4),

                  Text(
                    'por cada hijo adicional',
                    style: TextStyle(
                      fontSize: 14,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Beneficios
                  _buildBenefit(
                    icon: Icons.shield_outlined,
                    text: 'Misma proteccion completa',
                    colorScheme: colorScheme,
                  ),
                  const SizedBox(height: 8),
                  _buildBenefit(
                    icon: Icons.sync,
                    text: 'Se cobra junto a tu suscripcion',
                    colorScheme: colorScheme,
                  ),
                  const SizedBox(height: 8),
                  _buildBenefit(
                    icon: Icons.cancel_outlined,
                    text: 'Cancela cuando quieras',
                    colorScheme: colorScheme,
                  ),
                ],
              ),
            ),

            // Estado actual
            if (widget.limitResult.extraChildrenPurchased > 0) ...[
              const SizedBox(height: 12),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'Ya tienes ${widget.limitResult.extraChildrenPurchased} hijo${widget.limitResult.extraChildrenPurchased > 1 ? 's' : ''} adicional${widget.limitResult.extraChildrenPurchased > 1 ? 'es' : ''}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.green.shade700,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],

            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: Colors.red, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(
                          color: isDarkMode ? Colors.red.shade200 : Colors.red.shade800,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),

            // Boton principal
            SizedBox(
              width: double.infinity,
              height: 54,
              child: ElevatedButton(
                onPressed: _isPurchasing ? null : _purchaseExtraChild,
                style: ElevatedButton.styleFrom(
                  backgroundColor: colorScheme.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: _isPurchasing
                    ? SizedBox(
                        height: 24,
                        width: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_circle_outline, size: 22),
                          SizedBox(width: 8),
                          Text(
                            'Agregar 1 Hijo Mas',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
              ),
            ),

            const SizedBox(height: 12),

            // Boton secundario
            TextButton(
              onPressed: _isPurchasing ? null : () => Navigator.of(context).pop(false),
              style: TextButton.styleFrom(
                foregroundColor: colorScheme.onSurfaceVariant,
              ),
              child: Text(
                'Ahora no',
                style: TextStyle(fontSize: 15),
              ),
            ),

            // Trust badge
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 14,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
                SizedBox(width: 4),
                Text(
                  'Pago seguro via App Store',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBenefit({
    required IconData icon,
    required String text,
    required ColorScheme colorScheme,
  }) {
    return Row(
      children: [
        Container(
          padding: EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.check,
            size: 14,
            color: Colors.green,
          ),
        ),
        SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurface,
            ),
          ),
        ),
      ],
    );
  }
}
