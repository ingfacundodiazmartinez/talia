import 'package:flutter/material.dart';

/// Resultado de la selección de compartir ubicación.
class LocationShareChoice {
  /// null = ubicación actual (estática). Si no es null, compartir en vivo por
  /// esta duración.
  final Duration? liveDuration;
  const LocationShareChoice({this.liveDuration});

  bool get isLive => liveDuration != null;
}

/// Bottom sheet estilo WhatsApp para elegir cómo compartir la ubicación:
/// un punto actual, o en tiempo real por 15 min / 1 h / 8 h.
class LocationShareSheet {
  static Future<LocationShareChoice?> show(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return showModalBottomSheet<LocationShareChoice>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: Icon(Icons.near_me, color: colorScheme.primary),
              title: const Text('Enviar ubicación actual'),
              subtitle: const Text('Comparte dónde estás ahora'),
              onTap: () =>
                  Navigator.pop(ctx, const LocationShareChoice()),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Icon(Icons.location_on, size: 18, color: colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Compartir en tiempo real',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            _liveOption(ctx, '15 minutos', const Duration(minutes: 15)),
            _liveOption(ctx, '1 hora', const Duration(hours: 1)),
            _liveOption(ctx, '8 horas', const Duration(hours: 8)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  static Widget _liveOption(BuildContext ctx, String label, Duration d) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      leading: const Icon(Icons.timelapse, size: 20),
      title: Text(label),
      onTap: () => Navigator.pop(ctx, LocationShareChoice(liveDuration: d)),
    );
  }
}
