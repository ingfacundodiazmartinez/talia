import 'package:flutter/material.dart';

/// Barra de selección de mensajes
///
/// Mostrada cuando el usuario selecciona múltiples mensajes para reenviar
///
/// Props:
/// - selectedCount: Cantidad de mensajes seleccionados
/// - onForward: Callback para reenviar mensajes
/// - onCancel: Callback para cancelar selección
class ChatSelectionBarWidget extends StatelessWidget implements PreferredSizeWidget {
  final int selectedCount;
  final VoidCallback onForward;
  final VoidCallback onCancel;

  const ChatSelectionBarWidget({
    super.key,
    required this.selectedCount,
    required this.onForward,
    required this.onCancel,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: onCancel,
        tooltip: 'Cancelar selección',
      ),
      title: Text(
        selectedCount == 1
            ? '1 mensaje seleccionado'
            : '$selectedCount mensajes seleccionados',
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.forward),
          onPressed: selectedCount > 0 ? onForward : null,
          tooltip: 'Reenviar mensajes',
        ),
      ],
    );
  }
}
