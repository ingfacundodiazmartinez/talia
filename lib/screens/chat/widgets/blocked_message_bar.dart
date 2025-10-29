import 'package:flutter/material.dart';

/// Barra que muestra cuando hay un bloqueo activo
///
/// Responsabilidades:
/// - Mostrar mensaje cuando el usuario ha bloqueado al contacto
/// - Mostrar mensaje cuando el contacto ha bloqueado al usuario
/// - Estilo visual consistente con indicador de error/advertencia
class BlockedMessageBar extends StatelessWidget {
  final bool isBlocked;
  final bool isBlockedBy;

  const BlockedMessageBar({
    super.key,
    required this.isBlocked,
    required this.isBlockedBy,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.red.withValues(alpha: 0.1),
      child: Row(
        children: [
          const Icon(Icons.block, color: Colors.red, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              isBlocked
                  ? 'Has bloqueado a este contacto. No puedes enviar ni recibir mensajes.'
                  : 'Este contacto te ha bloqueado.',
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
