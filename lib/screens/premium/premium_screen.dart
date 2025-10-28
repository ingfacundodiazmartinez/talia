import 'package:flutter/material.dart';
import '../../services/subscription_service.dart';
import 'package:url_launcher/url_launcher.dart';

/// Pantalla principal de Premium
/// Muestra los planes disponibles, beneficios y permite suscribirse
class PremiumScreen extends StatefulWidget {
  const PremiumScreen({Key? key}) : super(key: key);

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen> {
  final _subscriptionService = SubscriptionService();

  PremiumStatus? _currentStatus;
  bool _isLoading = true;
  SubscriptionTier _selectedTier = SubscriptionTier.premium;

  @override
  void initState() {
    super.initState();
    _loadPremiumStatus();
  }

  Future<void> _loadPremiumStatus() async {
    setState(() => _isLoading = true);
    try {
      final status = await _subscriptionService.checkPremiumStatus(forceRefresh: true);
      setState(() {
        _currentStatus = status;
        _isLoading = false;
      });
    } catch (e) {
      print('Error cargando status: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _handleSubscribe() async {
    try {
      // Pedir email al usuario primero
      final emailController = TextEditingController();
      final email = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Email de MercadoPago'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Ingresa el email de tu cuenta de MercadoPago para continuar con la suscripción.',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  hintText: 'tu@email.com',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () {
                final email = emailController.text.trim();
                if (email.isEmpty || !email.contains('@')) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Por favor ingresa un email válido'),
                      backgroundColor: Colors.red,
                    ),
                  );
                  return;
                }
                Navigator.pop(context, email);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6A1B9A),
              ),
              child: const Text('Continuar', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );

      // Si el usuario canceló, salir
      if (email == null || email.isEmpty) return;

      // Mostrar loading
      if (mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const Center(
            child: CircularProgressIndicator(),
          ),
        );
      }

      // Crear sesión de checkout con el email proporcionado
      final session = await _subscriptionService.createCheckoutSession(
        tier: _selectedTier,
        provider: 'mercadopago',
        email: email,
      );

      // Cerrar loading
      if (mounted) Navigator.of(context).pop();

      // Abrir URL de checkout en navegador
      final uri = Uri.parse(session.checkoutUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);

        // Mostrar mensaje de espera con información de trial
        if (mounted) {
          final trialMessage = session.hasTrial && session.trialDays != null
              ? 'Incluye ${session.trialDays} días de prueba gratis. '
              : '';

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${trialMessage}Inicia sesión en MercadoPago con $email y completa la autorización. La app se actualizará automáticamente.',
              ),
              duration: Duration(seconds: 8),
              backgroundColor: const Color(0xFF6A1B9A),
            ),
          );
        }
      } else {
        throw 'No se pudo abrir el navegador';
      }
    } catch (e) {
      // Cerrar loading si está abierto
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }

      // Mostrar error
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al crear sesión de pago: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Talia Premium'),
        backgroundColor: const Color(0xFF6A1B9A), // Mantener morado como brand color
        foregroundColor: Colors.white,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Column(
                children: [
                  // Header con estado actual
                  if (_currentStatus != null && _currentStatus!.isPremium)
                    _buildCurrentPremiumHeader(),

                  // Hero section
                  _buildHeroSection(),

                  // Selector de planes
                  _buildTierSelector(),

                  // Lista de features del plan seleccionado
                  _buildFeaturesList(),

                  // Botón de suscripción
                  _buildSubscribeButton(),

                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }

  Widget _buildCurrentPremiumHeader() {
    final status = _currentStatus!;
    final daysLeft = status.expiresAt != null
        ? status.expiresAt!.difference(DateTime.now()).inDays
        : null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF6A1B9A),
            const Color(0xFF8E24AA),
          ],
        ),
      ),
      child: Column(
        children: [
          const Icon(Icons.star, color: Colors.amber, size: 40),
          const SizedBox(height: 10),
          Text(
            'Tienes ${status.displayName}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (daysLeft != null) ...[
            const SizedBox(height: 5),
            Text(
              'Vence en $daysLeft días',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHeroSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(30),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF6A1B9A),
            Color(0xFF8E24AA),
          ],
        ),
      ),
      child: Column(
        children: [
          const Icon(Icons.auto_awesome, color: Colors.amber, size: 60),
          const SizedBox(height: 20),
          const Text(
            'Desbloquea el Poder de la IA',
            style: TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 10),
          const Text(
            'Transforma tus fotos y videos con efectos premium de inteligencia artificial',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 16,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 15),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(25),
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: const Text(
              'Prueba GRATIS por 7 días',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTierSelector() {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
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
          const SizedBox(height: 15),
          Row(
            children: [
              Expanded(
                child: _buildTierCard(
                  tier: SubscriptionTier.premium,
                  popular: true,
                ),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: _buildTierCard(
                  tier: SubscriptionTier.premiumPlus,
                  popular: false,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTierCard({
    required SubscriptionTier tier,
    required bool popular,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final isSelected = _selectedTier == tier;
    final premiumColor = const Color(0xFF6A1B9A);

    return GestureDetector(
      onTap: () => setState(() => _selectedTier = tier),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: isSelected ? premiumColor : colorScheme.surfaceContainerHighest,
          border: Border.all(
            color: isSelected ? premiumColor : colorScheme.outline,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: premiumColor.withOpacity(0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ]
              : [],
        ),
        child: Column(
          children: [
            if (popular)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.amber,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'POPULAR',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            const SizedBox(height: 10),
            Text(
              tier.displayName,
              style: TextStyle(
                color: isSelected ? Colors.white : colorScheme.onSurface,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '\$${tier.monthlyPrice.toStringAsFixed(2)}',
              style: TextStyle(
                color: isSelected ? Colors.white : colorScheme.onSurface,
                fontSize: 32,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              '/mes',
              style: TextStyle(
                color: isSelected ? Colors.white70 : colorScheme.onSurfaceVariant,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isSelected ? Colors.white.withOpacity(0.2) : Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected ? Colors.white : Colors.green,
                  width: 1,
                ),
              ),
              child: Text(
                '7 días GRATIS',
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.green,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeaturesList() {
    final features = PremiumFeature.forTier(_selectedTier);
    final allFeatures = PremiumFeature.all;
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Incluye:',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 15),
          ...allFeatures.map((feature) {
            final isIncluded = features.contains(feature);
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    isIncluded ? Icons.check_circle : Icons.cancel,
                    color: isIncluded ? Colors.green : colorScheme.outline,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${feature.iconName} ${feature.name}',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: isIncluded ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          feature.description,
                          style: TextStyle(
                            fontSize: 14,
                            color: isIncluded ? colorScheme.onSurfaceVariant : colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
          const SizedBox(height: 10),
          if (_selectedTier == SubscriptionTier.premium ||
              _selectedTier == SubscriptionTier.premiumPlus) ...[
            _buildFeatureItem(
              icon: Icons.block,
              title: 'Sin anuncios',
              description: 'Disfruta de una experiencia sin publicidad',
            ),
            _buildFeatureItem(
              icon: Icons.cloud_upload,
              title: 'Almacenamiento ampliado',
              description: 'Guarda más historias y contenido',
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFeatureItem({
    required IconData icon,
    required String title,
    required String description,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Colors.green, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 14,
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

  Widget _buildSubscribeButton() {
    // Si ya tiene este tier o superior, no mostrar botón
    if (_currentStatus != null && _currentStatus!.isPremium) {
      if (_currentStatus!.tier == _selectedTier) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.green[50],
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.green),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle, color: Colors.green),
                SizedBox(width: 10),
                Text(
                  'Plan Actual',
                  style: TextStyle(
                    color: Colors.green,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        );
      }

      // Si tiene Premium y está seleccionando Premium+, permitir upgrade
      if (_currentStatus!.tier == SubscriptionTier.premium &&
          _selectedTier == SubscriptionTier.premiumPlus) {
        return _buildActionButton(
          text: 'Mejorar a Premium+',
          onPressed: _handleSubscribe,
        );
      }

      // Si tiene Premium+ y está mirando Premium, no permitir downgrade
      if (_currentStatus!.tier == SubscriptionTier.premiumPlus &&
          _selectedTier == SubscriptionTier.premium) {
        final colorScheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'Ya tienes un plan superior',
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
          ),
        );
      }
    }

    return _buildActionButton(
      text: 'Suscribirse a ${_selectedTier.displayName}',
      onPressed: _handleSubscribe,
    );
  }

  Widget _buildActionButton({
    required String text,
    required VoidCallback onPressed,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF6A1B9A),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

}
