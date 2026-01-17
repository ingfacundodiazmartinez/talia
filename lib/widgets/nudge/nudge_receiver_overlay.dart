import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../models/nudge.dart';
import '../../services/nudge_service.dart';

/// Banner flotante que aparece arriba cuando se recibe un nudge
///
/// Características:
/// - Aparece desde arriba con animación
/// - Animación diferenciada según tipo de nudge:
///   - Latido: pulso (escala sutil)
///   - Zumbido: temblor horizontal
///   - Saludo: ondulación
///   - Psst: fade in misterioso
/// - Tap para responder
/// - Swipe para cerrar
/// - Compatible con modo oscuro
class NudgeReceiverOverlay extends StatefulWidget {
  final NudgeData nudge;
  final VoidCallback onDismiss;

  const NudgeReceiverOverlay({
    super.key,
    required this.nudge,
    required this.onDismiss,
  });

  @override
  State<NudgeReceiverOverlay> createState() => _NudgeReceiverOverlayState();
}

class _NudgeReceiverOverlayState extends State<NudgeReceiverOverlay>
    with TickerProviderStateMixin {
  late Timer _countdownTimer;
  late int _secondsRemaining;

  // Animación de entrada
  late AnimationController _entryController;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  // Animación específica del tipo de nudge
  late AnimationController _effectController;

  bool _isResponding = false;

  @override
  void initState() {
    super.initState();
    _secondsRemaining = widget.nudge.secondsRemaining;

    // Animación de entrada (slide + fade)
    _entryController = AnimationController(
      duration: Duration(milliseconds: 400),
      vsync: this,
    );

    _slideAnimation = Tween<Offset>(
      begin: Offset(0, -1.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _entryController,
      curve: Curves.easeOutBack,
    ));

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _entryController, curve: Curves.easeOut),
    );

    // Animación de efecto según tipo
    _effectController = AnimationController(
      duration: _getEffectDuration(),
      vsync: this,
    );

    _entryController.forward().then((_) {
      // Iniciar animación de efecto después de la entrada
      _startEffectAnimation();
    });

    _startCountdown();
  }

  Duration _getEffectDuration() {
    switch (widget.nudge.type.animation) {
      case NudgeAnimation.pulse:
        return Duration(milliseconds: 600);
      case NudgeAnimation.shake:
        return Duration(milliseconds: 500);
      case NudgeAnimation.wave:
        return Duration(milliseconds: 800);
      case NudgeAnimation.fadeIn:
        return Duration(milliseconds: 400);
    }
  }

  void _startEffectAnimation() {
    switch (widget.nudge.type.animation) {
      case NudgeAnimation.pulse:
        // Pulso repetido 3 veces
        _effectController.repeat(reverse: true);
        Future.delayed(Duration(milliseconds: 1800), () {
          if (mounted) _effectController.stop();
        });
        break;
      case NudgeAnimation.shake:
        // Temblor rápido
        _effectController.repeat();
        Future.delayed(Duration(milliseconds: 600), () {
          if (mounted) {
            _effectController.stop();
            _effectController.value = 0;
          }
        });
        break;
      case NudgeAnimation.wave:
        // Ondulación una vez
        _effectController.forward();
        break;
      case NudgeAnimation.fadeIn:
        // Bounce sutil
        _effectController.forward();
        break;
    }
  }

  void _startCountdown() {
    _countdownTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      setState(() {
        _secondsRemaining--;
      });

      if (_secondsRemaining <= 0) {
        timer.cancel();
        _dismiss();
      }
    });
  }

  void _dismiss() async {
    _effectController.stop();
    await _entryController.reverse();
    if (mounted) {
      widget.onDismiss();
    }
  }

  Future<void> _respond() async {
    if (_isResponding) return;

    setState(() => _isResponding = true);
    HapticFeedback.mediumImpact();

    await NudgeService().sendNudge(
      toUserId: widget.nudge.senderId,
      toUserName: widget.nudge.senderName,
      type: widget.nudge.type,
    );

    _dismiss();
  }

  @override
  void dispose() {
    _countdownTimer.cancel();
    _entryController.dispose();
    _effectController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final type = widget.nudge.type;
    final mediaQuery = MediaQuery.of(context);

    // Colores adaptados al tema
    final primaryColor = colorScheme.primary;
    final surfaceColor = colorScheme.surface;
    final onSurfaceColor = colorScheme.onSurface;
    final onSurfaceVariant = colorScheme.onSurfaceVariant;

    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: () {}, // No cerrar al tocar el fondo
        child: Stack(
          children: [
            // Fondo semi-transparente (tap para cerrar)
            Positioned.fill(
              child: GestureDetector(
                onTap: _dismiss,
                child: FadeTransition(
                  opacity: _fadeAnimation,
                  child: Container(
                    color: isDark
                        ? Colors.black54
                        : Colors.black26,
                  ),
                ),
              ),
            ),

            // Banner flotante
            Positioned(
              top: mediaQuery.padding.top + 16,
              left: 16,
              right: 16,
              child: SlideTransition(
                position: _slideAnimation,
                child: _buildAnimatedBanner(
                  type: type,
                  primaryColor: primaryColor,
                  surfaceColor: surfaceColor,
                  onSurfaceColor: onSurfaceColor,
                  onSurfaceVariant: onSurfaceVariant,
                  isDark: isDark,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAnimatedBanner({
    required NudgeType type,
    required Color primaryColor,
    required Color surfaceColor,
    required Color onSurfaceColor,
    required Color onSurfaceVariant,
    required bool isDark,
  }) {
    Widget banner = _buildBannerContent(
      type: type,
      primaryColor: primaryColor,
      surfaceColor: surfaceColor,
      onSurfaceColor: onSurfaceColor,
      onSurfaceVariant: onSurfaceVariant,
      isDark: isDark,
    );

    // Aplicar animación según tipo
    switch (type.animation) {
      case NudgeAnimation.pulse:
        return AnimatedBuilder(
          animation: _effectController,
          builder: (context, child) {
            final scale = 1.0 + (_effectController.value * 0.03);
            return Transform.scale(
              scale: scale,
              child: child,
            );
          },
          child: banner,
        );

      case NudgeAnimation.shake:
        return AnimatedBuilder(
          animation: _effectController,
          builder: (context, child) {
            final shake = math.sin(_effectController.value * math.pi * 8) * 3;
            return Transform.translate(
              offset: Offset(shake, 0),
              child: child,
            );
          },
          child: banner,
        );

      case NudgeAnimation.wave:
        return AnimatedBuilder(
          animation: _effectController,
          builder: (context, child) {
            final wave = math.sin(_effectController.value * math.pi) * 0.02;
            return Transform.rotate(
              angle: wave,
              child: child,
            );
          },
          child: banner,
        );

      case NudgeAnimation.fadeIn:
        return AnimatedBuilder(
          animation: _effectController,
          builder: (context, child) {
            final bounce = Curves.elasticOut.transform(_effectController.value);
            final scale = 0.95 + (bounce * 0.05);
            return Transform.scale(
              scale: scale,
              child: child,
            );
          },
          child: banner,
        );
    }
  }

  Widget _buildBannerContent({
    required NudgeType type,
    required Color primaryColor,
    required Color surfaceColor,
    required Color onSurfaceColor,
    required Color onSurfaceVariant,
    required bool isDark,
  }) {
    return GestureDetector(
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity != null && details.primaryVelocity! < -100) {
          _dismiss(); // Swipe up para cerrar
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: surfaceColor,
          borderRadius: BorderRadius.circular(16),
          border: isDark
              ? Border.all(
                  color: primaryColor.withOpacity(0.3),
                  width: 1,
                )
              : null,
          boxShadow: [
            BoxShadow(
              color: primaryColor.withOpacity(isDark ? 0.2 : 0.25),
              blurRadius: 16,
              offset: Offset(0, 6),
            ),
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.3 : 0.08),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.all(14),
          child: Row(
            children: [
              // Avatar con borde de color
              _buildAvatar(primaryColor, surfaceColor),
              SizedBox(width: 12),

              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.nudge.senderName,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: onSurfaceColor,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          type.emoji,
                          style: TextStyle(fontSize: 16),
                        ),
                        SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            type.receivedMessage,
                            style: TextStyle(
                              fontSize: 13,
                              color: onSurfaceVariant,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Botón responder
              _buildRespondButton(primaryColor, type),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar(Color primaryColor, Color surfaceColor) {
    final photoUrl = widget.nudge.senderPhotoUrl;
    final name = widget.nudge.senderName;

    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: primaryColor, width: 2),
        boxShadow: [
          BoxShadow(
            color: primaryColor.withOpacity(0.25),
            blurRadius: 6,
            spreadRadius: 0,
          ),
        ],
      ),
      child: ClipOval(
        child: photoUrl != null && photoUrl.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: photoUrl,
                fit: BoxFit.cover,
                placeholder: (_, __) => _buildAvatarPlaceholder(name, primaryColor, surfaceColor),
                errorWidget: (_, __, ___) => _buildAvatarPlaceholder(name, primaryColor, surfaceColor),
              )
            : _buildAvatarPlaceholder(name, primaryColor, surfaceColor),
      ),
    );
  }

  Widget _buildAvatarPlaceholder(String name, Color primaryColor, Color surfaceColor) {
    return Container(
      color: primaryColor.withOpacity(0.15),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0].toUpperCase() : '?',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: primaryColor,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }

  Widget _buildRespondButton(Color primaryColor, NudgeType type) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return GestureDetector(
      onTap: _isResponding ? null : _respond,
      child: AnimatedContainer(
        duration: Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: _isResponding
              ? (isDark ? Colors.grey.shade700 : Colors.grey.shade300)
              : primaryColor,
          borderRadius: BorderRadius.circular(20),
          boxShadow: _isResponding ? [] : [
            BoxShadow(
              color: primaryColor.withOpacity(0.3),
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: _isResponding
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    type.emoji,
                    style: TextStyle(fontSize: 14),
                  ),
                  SizedBox(width: 4),
                  Text(
                    'Responder',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Manager global para mostrar overlays de nudges
class NudgeOverlayManager {
  static final NudgeOverlayManager _instance = NudgeOverlayManager._internal();
  factory NudgeOverlayManager() => _instance;
  NudgeOverlayManager._internal();

  OverlayEntry? _currentOverlay;

  /// Mostrar overlay de nudge recibido
  void showNudgeOverlay(BuildContext context, NudgeData nudge) {
    // Si ya hay un overlay, cerrarlo primero
    dismissCurrentOverlay();

    // Buscar el Overlay más cercano de forma segura
    final overlayState = Overlay.maybeOf(context);
    if (overlayState == null) {
      // Si no hay Overlay en este context, intentar con el Navigator
      final navigatorState = Navigator.maybeOf(context);
      if (navigatorState != null) {
        final navigatorOverlay = navigatorState.overlay;
        if (navigatorOverlay != null) {
          _insertOverlay(navigatorOverlay, nudge);
          return;
        }
      }
      debugPrint('❌ [NudgeOverlay] No se encontró Overlay válido');
      return;
    }

    _insertOverlay(overlayState, nudge);
  }

  void _insertOverlay(OverlayState overlayState, NudgeData nudge) {
    final overlay = OverlayEntry(
      builder: (context) => NudgeReceiverOverlay(
        nudge: nudge,
        onDismiss: () {
          dismissCurrentOverlay();
        },
      ),
    );

    _currentOverlay = overlay;
    overlayState.insert(overlay);
  }

  /// Cerrar overlay actual si existe
  void dismissCurrentOverlay() {
    _currentOverlay?.remove();
    _currentOverlay = null;
  }
}
