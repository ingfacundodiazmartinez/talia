import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/release_logger.dart';

/// Diálogo que explica y solicita permisos de ubicación en segundo plano
///
/// Se muestra siempre ANTES de solicitar permisos de ubicación en background:
/// - Android: Requerido por políticas de Play Store
/// - iOS: Buena práctica para mejor experiencia de usuario
class LocationPermissionDialog extends StatelessWidget {
  const LocationPermissionDialog({super.key});

  /// Muestra el diálogo
  static Future<void> show(BuildContext context) async {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const LocationPermissionDialog(),
    );
  }

  /// Solicita permisos de ubicación (primero normal, luego en segundo plano)
  Future<void> _requestLocationPermissions(BuildContext context) async {
    try {
      // 1. Solicitar permiso de ubicación normal primero
      final locationStatus = await Permission.location.request();

      if (locationStatus.isGranted) {
        // 2. Si se otorgó ubicación normal, solicitar ubicación en segundo plano
        final backgroundStatus = await Permission.locationAlways.request();

        if (backgroundStatus.isGranted) {
          ReleaseLogger.log('Permisos de ubicación en segundo plano otorgados', tag: 'LocationPermission');
        } else if (backgroundStatus.isDenied) {
          ReleaseLogger.log('Permiso de ubicación en segundo plano denegado', tag: 'LocationPermission');
        } else if (backgroundStatus.isPermanentlyDenied) {
          // Mostrar diálogo para ir a configuración
          _showOpenSettingsDialog(context);
          return;
        }
      } else if (locationStatus.isDenied) {
        ReleaseLogger.log('Permiso de ubicación denegado', tag: 'LocationPermission');
      } else if (locationStatus.isPermanentlyDenied) {
        // Mostrar diálogo para ir a configuración
        _showOpenSettingsDialog(context);
        return;
      }

      // Cerrar el diálogo después de solicitar permisos
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      ReleaseLogger.error('Error solicitando permisos de ubicación: $e', tag: 'LocationPermission');
      if (context.mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  /// Muestra diálogo para abrir configuración del sistema
  void _showOpenSettingsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permisos necesarios'),
        content: const Text(
          'Para tu seguridad, Talia necesita acceso a tu ubicación en segundo plano. '
          'Por favor, ve a Configuración y habilita los permisos de ubicación.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Ahora no'),
          ),
          TextButton(
            onPressed: () {
              openAppSettings();
              Navigator.of(context).pop();
            },
            child: const Text('Abrir Configuración'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
      ),
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: isDarkMode ? colorScheme.surface : Colors.white,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Ícono
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFF9D7FE8).withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.location_on,
                size: 48,
                color: Color(0xFF9D7FE8),
              ),
            ),

            const SizedBox(height: 20),

            // Título
            Text(
              'Ubicación de Seguridad',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: isDarkMode ? colorScheme.onSurface : const Color(0xFF1A1A1A),
              ),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 16),

            // Descripción
            Text(
              'Para tu seguridad, Talia necesita acceder a tu ubicación incluso cuando la app está cerrada.',
              style: TextStyle(
                fontSize: 15,
                color: isDarkMode
                    ? colorScheme.onSurfaceVariant
                    : const Color(0xFF666666),
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 24),

            // Razones
            Text(
              '¿Por qué es necesario?',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: isDarkMode ? colorScheme.onSurface : const Color(0xFF1A1A1A),
              ),
            ),

            const SizedBox(height: 16),

            // Lista de razones
            _buildReason(
              icon: Icons.check_circle,
              text: 'Tus padres podrán encontrarte en caso de emergencia',
              isDarkMode: isDarkMode,
              context: context,
            ),
            const SizedBox(height: 12),
            _buildReason(
              icon: Icons.check_circle,
              text: 'El botón SOS enviará tu ubicación exacta',
              isDarkMode: isDarkMode,
              context: context,
            ),
            const SizedBox(height: 12),
            _buildReason(
              icon: Icons.check_circle,
              text: 'Te mantiene protegido las 24 horas',
              isDarkMode: isDarkMode,
              context: context,
            ),

            const SizedBox(height: 24),

            // Nota de privacidad
            Text(
              'Tu privacidad está protegida. Solo tus padres pueden ver tu ubicación.',
              style: TextStyle(
                fontSize: 13,
                fontStyle: FontStyle.italic,
                color: isDarkMode
                    ? colorScheme.onSurfaceVariant.withValues(alpha: 0.7)
                    : const Color(0xFF999999),
                height: 1.3,
              ),
              textAlign: TextAlign.center,
            ),

            const SizedBox(height: 28),

            // Botones
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF9D7FE8),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text(
                      'Ahora no',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => _requestLocationPermissions(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF9D7FE8),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'Activar',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReason({
    required IconData icon,
    required String text,
    required bool isDarkMode,
    BuildContext? context,
  }) {
    final colorScheme = context != null ? Theme.of(context).colorScheme : null;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          icon,
          size: 20,
          color: const Color(0xFF9D7FE8),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 14,
              color: isDarkMode
                  ? (colorScheme?.onSurfaceVariant ?? Colors.white70)
                  : const Color(0xFF555555),
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
