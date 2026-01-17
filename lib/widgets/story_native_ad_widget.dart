import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Widget para mostrar Native Ads como una historia más en el viewer
/// Se ve exactamente como una historia normal con timer arriba
class StoryNativeAdWidget extends StatefulWidget {
  final NativeAd nativeAd;
  final VoidCallback? onAdCompleted;

  const StoryNativeAdWidget({
    super.key,
    required this.nativeAd,
    this.onAdCompleted,
  });

  @override
  State<StoryNativeAdWidget> createState() => _StoryNativeAdWidgetState();
}

class _StoryNativeAdWidgetState extends State<StoryNativeAdWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _progressController;

  // Tiempo mínimo antes de poder saltar (1 segundo)
  bool _canSkip = false;

  @override
  void initState() {
    super.initState();

    // Timer de 5 segundos como una historia normal
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );

    _progressController.forward();

    _progressController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        widget.onAdCompleted?.call();
      }
    });

    // Habilitar skip después de 1 segundo
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _canSkip = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _progressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    return Material(
      color: Colors.white,
      child: GestureDetector(
        // Detectar swipe horizontal en toda la pantalla
        onHorizontalDragEnd: (details) {
          if (_canSkip && details.primaryVelocity != null) {
            // Swipe izquierda (negativo) o derecha (positivo) - ambos saltan el ad
            if (details.primaryVelocity!.abs() > 200) {
              widget.onAdCompleted?.call();
            }
          }
        },
        onLongPress: () => _progressController.stop(),
        onLongPressUp: () => _progressController.forward(),
        child: Stack(
          children: [
            // Fondo que recibe taps en zona derecha
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) {
                  // Si tap en el 30% derecho de la pantalla, saltar
                  if (_canSkip && details.localPosition.dx > screenWidth * 0.7) {
                    widget.onAdCompleted?.call();
                  }
                },
                child: Container(color: Colors.white),
              ),
            ),

            // Native Ad content - centrado vertical y horizontalmente
            Positioned(
              left: screenWidth * 0.15,
              right: screenWidth * 0.15,
              top: screenHeight * 0.20,
              bottom: screenHeight * 0.20,
              child: Center(
                child: AdWidget(ad: widget.nativeAd),
              ),
            ),

            // Header con timer (igual que historias)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.5),
                    Colors.transparent,
                  ],
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Column(
                    children: [
                      // Progress bar (timer)
                      AnimatedBuilder(
                        animation: _progressController,
                        builder: (context, child) {
                          return LinearProgressIndicator(
                            value: _progressController.value,
                            backgroundColor: Colors.white.withOpacity(0.3),
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Colors.white,
                            ),
                            minHeight: 2,
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      // Header info
                      Row(
                        children: [
                          // Ícono de "Patrocinado"
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                              border: Border.all(
                                color: const Color(0xFF6A1B9A),
                                width: 2,
                              ),
                            ),
                            child: const Icon(
                              Icons.campaign,
                              color: Color(0xFF6A1B9A),
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 10),
                          // Texto "Patrocinado"
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: const [
                                Text(
                                  'Patrocinado',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  'Anuncio',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Sin botón - el usuario toca la derecha para saltar (después de 1s)
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          ],
        ),
      ),
    );
  }
}
