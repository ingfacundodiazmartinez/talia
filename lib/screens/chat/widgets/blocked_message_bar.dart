import 'package:flutter/material.dart';

/// Barra que se muestra al usuario que bloqueó al contacto.
///
/// Esta barra SOLO se muestra al bloqueador. El bloqueado nunca debe enterarse
/// de que fue bloqueado, así que esta barra no se renderiza desde su lado.
class BlockedMessageBar extends StatelessWidget {
  const BlockedMessageBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.red.withValues(alpha: 0.1),
      child: const Row(
        children: [
          Icon(Icons.block, color: Colors.red, size: 20),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Has bloqueado a este contacto. No puedes enviar ni recibir mensajes.',
              style: TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
