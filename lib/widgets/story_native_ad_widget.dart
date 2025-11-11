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
  }

  @override
  void dispose() {
    _progressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _progressController.stop(),
      onTapUp: (_) => _progressController.forward(),
      onTapCancel: () => _progressController.forward(),
      child: Container(
        color: Colors.white,
        child: Stack(
          children: [
            // Native Ad content - ocupa toda la pantalla
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.9,
                  maxHeight: MediaQuery.of(context).size.height * 0.7,
                ),
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
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
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
                            // Botón cerrar
                            IconButton(
                              icon: const Icon(
                                Icons.close,
                                color: Colors.white,
                                size: 24,
                              ),
                              onPressed: widget.onAdCompleted,
                            ),
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
