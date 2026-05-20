import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/character.dart';
import '../services/ad_service.dart';
import '../services/character_service.dart';
import '../services/credit_wallet_service.dart';
import '../services/subscription_service.dart';
import '../theme_service.dart';
import '../utils/release_logger.dart';
import '../widgets/premium_paywall_dialog.dart';

/// Pantalla fullscreen para elegir personaje (face-swap / IA).
///
/// Reemplaza el `CharacterSelectorDialog` modal. Cambios respecto al viejo:
///  - Fullscreen con AppBar normal (push con `fullscreenDialog: true`).
///  - Grid 2 columnas (antes 3) con cards estilo Netflix: foto full-bleed +
///    nombre con overlay degradé inferior.
///  - Badge "✨ IA" para characters que usan edición con prompt (gpt-image-2).
///  - Indicador suave de disponibilidad para niños sin mostrar números.
///  - Bloqueo amigable cuando no hay créditos: modal "Pedile a papá/mamá".
///  - Tip de "asegurate que tu cara sea visible" colapsado a icono `?`.
///
/// Contract de retorno (igual que antes): `Navigator.pop<Character>(context, char)`.
class CharacterSelectorScreen extends StatefulWidget {
  const CharacterSelectorScreen({super.key});

  @override
  State<CharacterSelectorScreen> createState() => _CharacterSelectorScreenState();
}

class _CharacterSelectorScreenState extends State<CharacterSelectorScreen> {
  final CharacterService _characterService = CharacterService();
  final SubscriptionService _subscriptionService = SubscriptionService();
  final CreditWalletService _walletService = CreditWalletService();
  final AdService _adService = AdService();

  List<Character> _characters = [];
  bool _isLoading = true;
  String? _errorMessage;
  String _selectedCategory = 'all';
  SubscriptionTier _userTier = SubscriptionTier.free;

  /// Si el current user es padre/adulto. Default false (asumimos niño) hasta
  /// que se cargue el rol — evita mostrar copy adulto fugazmente al niño.
  bool _isParent = false;

  @override
  void initState() {
    super.initState();
    _loadUserTier();
    _loadUserRole();
    _loadCharacters();
  }

  Future<void> _loadUserRole() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      if (!doc.exists) return;
      final role = doc.data()?['role'] as String?;
      if (mounted) {
        setState(() {
          _isParent = role == 'parent' || role == 'adult';
        });
      }
    } catch (e) {
      ReleaseLogger.log('No se pudo cargar rol: $e');
    }
  }

  Future<void> _loadUserTier() async {
    final status =
        await _subscriptionService.checkPremiumStatus(forceRefresh: true);
    if (mounted) {
      setState(() => _userTier = status.tier);
    }
  }

  Future<void> _loadCharacters() async {
    try {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
      final characters = await _characterService
          .getEnabledCharacters()
          .timeout(const Duration(seconds: 10));
      if (mounted) {
        setState(() {
          _characters = characters;
          _isLoading = false;
        });
      }
    } catch (e) {
      ReleaseLogger.log('❌ Error cargando personajes: $e');
      if (mounted) {
        setState(() {
          _errorMessage = e.toString().contains('tardando') ||
                  e.toString().contains('TimeoutException')
              ? 'La carga está tardando demasiado. Verificá tu conexión.'
              : 'Error al cargar personajes';
          _isLoading = false;
        });
      }
    }
  }

  List<Character> get _filteredCharacters {
    if (_selectedCategory == 'all') return _characters;
    return _characters.where((c) => c.category == _selectedCategory).toList();
  }

  List<String> get _categories {
    final cats = _characters.map((c) => c.category).toSet().toList()..sort();
    return ['all', ...cats];
  }

  void _showTipBottomSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lightbulb_outline,
                    color: Colors.orange[700], size: 24),
                const SizedBox(width: 8),
                const Text(
                  'Consejos para mejores resultados',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Asegurate de que tu cara sea claramente visible con buena '
              'iluminación. Evitá sombras o imágenes muy oscuras.',
              style: TextStyle(fontSize: 14, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  /// Llamado al tocar un character. Verifica acceso premium + créditos antes
  /// de retornar el character al caller.
  Future<void> _onCharacterTap(Character character, int? availableCredits) async {
    final hasPremiumAccess = character.isAccessibleForTier(_userTier.name);
    if (!hasPremiumAccess) {
      _showPremiumPaywall(character);
      return;
    }

    final cost = character.creditCost;
    final balance = availableCredits ?? 0;
    if (balance < cost) {
      _showInsufficientCreditsModal(character, cost: cost, balance: balance);
      return;
    }

    // Todo OK: retornar al caller
    if (mounted) Navigator.of(context).pop(character);
  }

  /// Padre dispara un rewarded ad para ganar 1 crédito.
  /// Se llama desde el banner de disponibilidad y desde el modal de bloqueo.
  Future<void> _onWatchAdPressed() async {
    // Asegurar que hay un ad pre-cargado
    if (!_adService.isRewardedAdLoaded) {
      await _adService.loadRewardedAd();
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (!_adService.isRewardedAdLoaded) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No hay videos disponibles. Intentá en un rato.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    final earned = await _adService.showRewardedAd();
    if (!mounted) return;
    if (earned) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('¡Ganaste 1 crédito!'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _showPremiumPaywall(Character character) {
    final requiredTier =
        character.accessLevel == CharacterAccessLevel.premiumPlus
            ? SubscriptionTier.premiumPlus
            : SubscriptionTier.premium;
    PremiumPaywallDialog.show(
      context,
      feature: PremiumFeature(
        id: 'character_${character.id}',
        name: 'Personaje ${character.name}',
        description:
            'Este personaje está disponible para usuarios ${requiredTier.displayName}. '
            'Actualizá tu plan para desbloquear todos los personajes exclusivos.',
        iconName: '🎭',
        requiredTier: requiredTier,
      ),
    );
  }

  /// Modal cuando no hay créditos suficientes. Diferencia copy y CTA según rol:
  /// - Hijo: pide ayuda al padre, CTA neutral "Entendido".
  /// - Padre: ofrece acción directa "Ver video ahora".
  void _showInsufficientCreditsModal(Character character,
      {required int cost, required int balance}) {
    final colorScheme = Theme.of(context).colorScheme;
    final title = _isParent ? '¡Casi listo!' : '¡Estás a un paso!';
    final body = _isParent
        ? 'Mirá un video corto para desbloquear ${character.name}.'
        : 'Pedile a papá o mamá que vea unos videos cortos '
            'para que puedas transformarte en ${character.name}.';

    showDialog(
      context: context,
      builder: (dialogCtx) => Dialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _isParent
                      ? Icons.play_circle_outline
                      : Icons.celebration_outlined,
                  color: Colors.orange[700],
                  size: 40,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                body,
                style: const TextStyle(fontSize: 14, height: 1.4),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.of(dialogCtx).pop();
                    if (_isParent) _onWatchAdPressed();
                  },
                  icon: Icon(
                      _isParent ? Icons.play_arrow : Icons.check, size: 20),
                  label: Text(
                    _isParent ? 'Ver video ahora' : 'Entendido',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Elige tu personaje'),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline),
            tooltip: 'Consejos',
            onPressed: _showTipBottomSheet,
          ),
        ],
      ),
      body: StreamBuilder<int?>(
        stream: _walletService.watchMaxAvailableCredits(),
        builder: (context, walletSnap) {
          final availableCredits = walletSnap.data;
          return Column(
            children: [
              _AvailabilityIndicator(
                credits: availableCredits,
                isParent: _isParent,
                onTapEarn: _isParent ? _onWatchAdPressed : null,
              ),
              if (_characters.isNotEmpty && _categories.length > 2)
                _CategoryChips(
                  categories: _categories,
                  selected: _selectedCategory,
                  onSelected: (c) => setState(() => _selectedCategory = c),
                ),
              Expanded(
                child: _buildBody(availableCredits),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBody(int? availableCredits) {
    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(
          color: ThemeService.primaryColor,
        ),
      );
    }
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 48,
                  color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              Text(_errorMessage!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadCharacters,
                child: const Text('Reintentar'),
              ),
            ],
          ),
        ),
      );
    }

    final filtered = _filteredCharacters;
    if (filtered.isEmpty) {
      return const Center(child: Text('No hay personajes disponibles'));
    }

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.82,
      ),
      itemCount: filtered.length,
      itemBuilder: (context, idx) {
        final character = filtered[idx];
        return _CharacterCard(
          character: character,
          userTier: _userTier,
          availableCredits: availableCredits,
          onTap: () => _onCharacterTap(character, availableCredits),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// COMPONENTES PRIVADOS
// ═══════════════════════════════════════════════════════════════

/// Indicador cualitativo de cuántas transformaciones hay disponibles.
/// El copy se adapta al rol:
///  - Hijo: lenguaje pide-ayuda-a-papá, sin números, no clickeable.
///  - Padre: lenguaje adulto, si saldo bajo es clickeable y dispara ad.
class _AvailabilityIndicator extends StatelessWidget {
  final int? credits;
  final bool isParent;
  final VoidCallback? onTapEarn;

  const _AvailabilityIndicator({
    required this.credits,
    required this.isParent,
    required this.onTapEarn,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final c = credits;

    if (c == null) {
      // Estado desconocido: probable cargando o usuario sin wallet linkado
      return const SizedBox.shrink();
    }

    String label;
    Color bgColor;
    Color fgColor;
    IconData icon;
    bool isActionable = false;

    if (c >= 20) {
      label = isParent
          ? 'Tenés muchos créditos disponibles'
          : 'Podés transformarte muchas veces';
      bgColor = colorScheme.primary.withValues(alpha: 0.10);
      fgColor = colorScheme.primary;
      icon = Icons.auto_awesome;
    } else if (c >= 4) {
      label = 'Te quedan algunas transformaciones';
      bgColor = Colors.orange.withValues(alpha: 0.12);
      fgColor = Colors.orange[800]!;
      icon = Icons.tips_and_updates_outlined;
    } else {
      if (isParent) {
        label = 'Mirá un video para ganar 1 crédito';
        isActionable = onTapEarn != null;
        icon = Icons.play_circle_outline;
      } else {
        label = 'Pedile a papá/mamá que vea videos';
        icon = Icons.notifications_active_outlined;
      }
      bgColor = Colors.red.withValues(alpha: 0.10);
      fgColor = Colors.red[700]!;
    }

    final content = Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: fgColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: fgColor,
              ),
            ),
          ),
          if (isActionable)
            Icon(Icons.chevron_right, size: 20, color: fgColor),
        ],
      ),
    );

    if (!isActionable) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTapEarn,
        borderRadius: BorderRadius.circular(12),
        child: content,
      ),
    );
  }
}

class _CategoryChips extends StatelessWidget {
  final List<String> categories;
  final String selected;
  final ValueChanged<String> onSelected;

  const _CategoryChips({
    required this.categories,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: categories.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, idx) {
          final cat = categories[idx];
          final isSelected = cat == selected;
          final label = cat == 'all'
              ? 'Todos'
              : cat[0].toUpperCase() + cat.substring(1);
          return ChoiceChip(
            label: Text(label),
            selected: isSelected,
            onSelected: (_) => onSelected(cat),
            selectedColor: colorScheme.primary,
            labelStyle: TextStyle(
              color: isSelected
                  ? colorScheme.onPrimary
                  : colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(
                color: isSelected
                    ? Colors.transparent
                    : colorScheme.outline.withValues(alpha: 0.4),
              ),
            ),
            showCheckmark: false,
          );
        },
      ),
    );
  }
}

/// Card individual de un character: foto full-bleed con overlay degradé inferior
/// + badges flotantes.
class _CharacterCard extends StatelessWidget {
  final Character character;
  final SubscriptionTier userTier;
  final int? availableCredits;
  final VoidCallback onTap;

  const _CharacterCard({
    required this.character,
    required this.userTier,
    required this.availableCredits,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasPremiumAccess = character.isAccessibleForTier(userTier.name);
    final isPremiumChar = character.accessLevel != CharacterAccessLevel.free;
    final cost = character.creditCost;
    final hasCredits = (availableCredits ?? 0) >= cost;
    final locked = !hasPremiumAccess; // Premium lock prima sobre créditos
    final dimmed = !hasCredits && hasPremiumAccess; // Sin créditos = atenuado

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Imagen full-bleed
              _buildImage(),

              // 2. Gradient inferior para legibilidad del nombre
              const _BottomGradient(),

              // 3. Atenuación si no tiene créditos (pero sí premium)
              if (dimmed)
                Container(
                  color: Colors.black.withValues(alpha: 0.35),
                ),

              // 4. Overlay completo + lock si es Premium sin acceso
              if (locked)
                Container(
                  color: Colors.black.withValues(alpha: 0.45),
                  alignment: Alignment.center,
                  child: const Icon(Icons.lock, color: Colors.white, size: 32),
                ),

              // 5. Nombre abajo-izquierda (deja espacio al chip de costo)
              Positioned(
                left: 10,
                right: 58, // espacio para el cost chip
                bottom: 10,
                child: Text(
                  character.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    shadows: [
                      Shadow(
                        color: Colors.black54,
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),

              // 6. Cost chip (bottom-right): cuántos créditos cuesta
              Positioned(
                bottom: 10,
                right: 10,
                child: _CostChip(cost: cost),
              ),

              // 7. Badge IA (top-left) si usa modelo generativo
              if (character.usesGenerativeAi)
                const Positioned(top: 8, left: 8, child: _AiBadge()),

              // 8. Badge Premium (top-right)
              if (isPremiumChar)
                Positioned(top: 8, right: 8, child: _PremiumDot()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImage() {
    if (character.thumbnailUrl.isEmpty ||
        character.thumbnailUrl.contains('example.com')) {
      return Container(
        color: Colors.grey[300],
        child: const Center(
          child: Icon(Icons.person, size: 56, color: Colors.white70),
        ),
      );
    }
    return CachedNetworkImage(
      imageUrl: character.thumbnailUrl,
      fit: BoxFit.cover,
      placeholder: (context, url) => Container(
        color: Colors.grey[300],
        child: Center(
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: ThemeService.primaryColor,
          ),
        ),
      ),
      errorWidget: (context, url, error) => Container(
        color: Colors.grey[300],
        child: const Center(
          child: Icon(Icons.broken_image, size: 36, color: Colors.white70),
        ),
      ),
    );
  }
}

class _BottomGradient extends StatelessWidget {
  const _BottomGradient();

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      height: 80,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black.withValues(alpha: 0.65),
            ],
          ),
        ),
      ),
    );
  }
}

class _AiBadge extends StatelessWidget {
  const _AiBadge();

  static const _gradientStart = Color(0xFFFF6B9D);
  static const _gradientEnd = Color(0xFFA855F7);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_gradientStart, _gradientEnd],
        ),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: _gradientEnd.withValues(alpha: 0.4),
            blurRadius: 6,
          ),
        ],
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, color: Colors.white, size: 12),
          SizedBox(width: 3),
          Text(
            'IA',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _PremiumDot extends StatelessWidget {
  const _PremiumDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: const BoxDecoration(
        color: Color(0xFFFFD700),
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.star, color: Colors.white, size: 12),
    );
  }
}

/// Chip compacto que muestra cuántos créditos cuesta una transformación.
/// Visualmente sutil — blanco semi-transparente sobre el degradé inferior.
class _CostChip extends StatelessWidget {
  final int cost;

  const _CostChip({required this.cost});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.auto_awesome,
            size: 13,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 3),
          Text(
            '$cost',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}
