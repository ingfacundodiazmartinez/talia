import 'dart:ui';
import 'package:talia/services/remote_logger_service.dart';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Banner personalizado que imita las notificaciones nativas de iOS
/// Se muestra en la parte superior de la pantalla con efecto blur
class CustomNotificationBanner extends StatefulWidget {
  final String title;
  final String body;
  final String? imageUrl;
  final VoidCallback? onTap;
  final Duration displayDuration;

  const CustomNotificationBanner({
    super.key,
    required this.title,
    required this.body,
    this.imageUrl,
    this.onTap,
    this.displayDuration = const Duration(seconds: 4),
  });

  @override
  State<CustomNotificationBanner> createState() => _CustomNotificationBannerState();

  /// Muestra el banner usando un OverlayState directamente (preferido)
  static void showWithOverlay(
    OverlayState overlay,
    BuildContext context, {
    required String title,
    required String body,
    String? imageUrl,
    VoidCallback? onTap,
    Duration displayDuration = const Duration(seconds: 4),
  }) {
    try {
      appLogger.log('✅ Usando OverlayState directamente (método preferido)', level: 'INFO');

      late OverlayEntry overlayEntry;

      overlayEntry = OverlayEntry(
        builder: (context) => Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: CustomNotificationBanner(
            title: title,
            body: body,
            imageUrl: imageUrl,
            onTap: () {
              try {
                overlayEntry.remove();
              } catch (e) {
                appLogger.log('⚠️ Error removiendo overlay: $e', level: 'ERROR');
              }
              onTap?.call();
            },
            displayDuration: displayDuration,
          ),
        ),
      );

      overlay.insert(overlayEntry);
      appLogger.log('✅ Banner insertado en el Overlay exitosamente', level: 'INFO');

      // Auto-remover después del displayDuration
      Future.delayed(displayDuration + const Duration(milliseconds: 300), () {
        try {
          if (overlayEntry.mounted) {
            overlayEntry.remove();
            appLogger.log('✅ Banner removido automáticamente', level: 'INFO');
          }
        } catch (e) {
          appLogger.log('⚠️ Error removiendo overlay automáticamente: $e', level: 'ERROR');
        }
      });
    } catch (e, stackTrace) {
      appLogger.log('❌ Error mostrando banner con OverlayState: $e', level: 'ERROR');
      appLogger.log('Stack trace: $stackTrace', level: 'INFO');
    }
  }

  /// Muestra el banner usando un overlay (método legacy)
  static void show(
    BuildContext context, {
    required String title,
    required String body,
    String? imageUrl,
    VoidCallback? onTap,
    Duration displayDuration = const Duration(seconds: 4),
  }) {
    try {
      // Intentar primero con rootOverlay: true para el overlay raíz
      OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);

      // Si no funciona, intentar con rootOverlay: false
      if (overlay == null) {
        appLogger.log('⚠️ Root overlay no disponible, intentando overlay local...', level: 'WARNING');
        overlay = Overlay.maybeOf(context, rootOverlay: false);
      }

      // Verificar que el overlay existe
      if (overlay == null) {
        appLogger.log('❌ No se pudo obtener el Overlay del contexto (probado root y local)', level: 'ERROR');
        return;
      }

      appLogger.log('✅ Overlay obtenido exitosamente', level: 'INFO');

      late OverlayEntry overlayEntry;

      overlayEntry = OverlayEntry(
        builder: (context) => Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: CustomNotificationBanner(
            title: title,
            body: body,
            imageUrl: imageUrl,
            onTap: () {
              try {
                overlayEntry.remove();
              } catch (e) {
                appLogger.log('⚠️ Error removiendo overlay: $e', level: 'ERROR');
              }
              onTap?.call();
            },
            displayDuration: displayDuration,
          ),
        ),
      );

      overlay.insert(overlayEntry);
      appLogger.log('✅ Banner insertado en el Overlay', level: 'INFO');

      // Auto-remover después del displayDuration
      Future.delayed(displayDuration + const Duration(milliseconds: 300), () {
        try {
          if (overlayEntry.mounted) {
            overlayEntry.remove();
            appLogger.log('✅ Banner removido automáticamente', level: 'INFO');
          }
        } catch (e) {
          appLogger.log('⚠️ Error removiendo overlay automáticamente: $e', level: 'ERROR');
        }
      });
    } catch (e, stackTrace) {
      appLogger.log('❌ Error mostrando banner en overlay: $e', level: 'ERROR');
      appLogger.log('Stack trace: $stackTrace', level: 'INFO');
    }
  }
}

class _CustomNotificationBannerState extends State<CustomNotificationBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  double _dragDistance = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));

    // Iniciar animación de entrada
    _controller.forward();

    // Auto-cerrar
    Future.delayed(widget.displayDuration, () {
      if (mounted) {
        _dismiss();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismiss() {
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    // Detectar si es dark mode
    final isDarkMode = MediaQuery.of(context).platformBrightness == Brightness.dark;

    return Material(
      type: MaterialType.transparency,
      child: SlideTransition(
        position: _slideAnimation,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: GestureDetector(
          onTap: widget.onTap,
          onVerticalDragUpdate: (details) {
            setState(() {
              _dragDistance += details.delta.dy;
              // Solo permitir arrastrar hacia arriba
              if (_dragDistance > 0) _dragDistance = 0;
            });
          },
          onVerticalDragEnd: (details) {
            if (_dragDistance < -50) {
              // Si arrastra más de 50px hacia arriba, cerrar
              _dismiss();
            }
            setState(() {
              _dragDistance = 0;
            });
          },
          child: Transform.translate(
            offset: Offset(0, _dragDistance),
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 15,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(13),
                  child: Container(
                    decoration: BoxDecoration(
                      color: isDarkMode
                        ? const Color(0xFF2C2C2E).withOpacity(0.98)
                        : const Color(0xFFFFFFFF).withOpacity(0.98),
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(
                        color: isDarkMode
                          ? const Color(0x1AFFFFFF)
                          : const Color(0x0D000000),
                        width: 0.5,
                      ),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: Row(
                        children: [
                          // Avatar
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isDarkMode ? Colors.grey[700] : Colors.grey[300],
                            ),
                            child: widget.imageUrl != null &&
                                    widget.imageUrl!.isNotEmpty
                                ? ClipOval(
                                    child: CachedNetworkImage(
                                      imageUrl: widget.imageUrl!,
                                      fit: BoxFit.cover,
                                      placeholder: (context, url) => Container(
                                        color: isDarkMode ? Colors.grey[700] : Colors.grey[300],
                                      ),
                                      errorWidget: (context, url, error) =>
                                          _buildDefaultAvatar(isDarkMode),
                                    ),
                                  )
                                : _buildDefaultAvatar(isDarkMode),
                          ),
                          const SizedBox(width: 12),
                          // Texto con DefaultTextStyle para evitar el error de Material
                          Expanded(
                            child: DefaultTextStyle(
                              style: TextStyle(
                                color: isDarkMode ? Colors.white : Colors.black,
                                decoration: TextDecoration.none, // ✅ SIN decoración
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    widget.title,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: isDarkMode ? Colors.white : const Color(0xFF000000),
                                      decoration: TextDecoration.none, // ✅ IMPORTANTE
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    widget.body,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w400,
                                      color: isDarkMode
                                        ? Colors.white.withOpacity(0.7)
                                        : const Color(0xFF000000).withOpacity(0.6),
                                      decoration: TextDecoration.none, // ✅ IMPORTANTE
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    );
  }

  Widget _buildDefaultAvatar(bool isDarkMode) {
    // Usar el logo de la app para notificaciones sin imagen
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isDarkMode ? const Color(0xFF9D7FE8) : const Color(0xFF9D7FE8),
      ),
      child: ClipOval(
        child: Image.asset(
          'assets/images/icon.png',
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            // Fallback a letra si el logo no se puede cargar
            return Center(
              child: Text(
                widget.title.isNotEmpty ? widget.title[0].toUpperCase() : 'T',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
