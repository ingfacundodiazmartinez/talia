import 'package:flutter/material.dart';
import '../../../services/reaction_service.dart';
import '../../../widgets/reaction_picker.dart';

/// Mixin que proporciona la lógica del reaction picker para screens de chat.
///
/// Este mixin centraliza la lógica de mostrar el picker de reacciones
/// que era idéntica entre chat_detail_screen.dart y group_chat_screen.dart.
///
/// Uso:
/// ```dart
/// class _MyChatScreenState extends State<MyChatScreen>
///     with ReactionPickerMixin {
///   // ...
/// }
/// ```
mixin ReactionPickerMixin<T extends StatefulWidget> on State<T> {
  /// Overlay entry para el picker de reacciones
  OverlayEntry? _reactionOverlay;

  /// Servicio de reacciones (puede ser overrideado)
  ReactionService get reactionService => ReactionService();

  /// Muestra el picker de reacciones encima del mensaje
  ///
  /// [messageContext] - BuildContext del widget del mensaje
  /// [messageId] - ID del mensaje para agregar la reacción
  /// [chatId] - ID del chat o grupo
  /// [isGroup] - Si es un chat grupal (default: false)
  void showReactionPicker(
    BuildContext messageContext,
    String messageId, {
    required String chatId,
    bool isGroup = false,
  }) async {
    FocusScope.of(context).unfocus();
    await Future.delayed(const Duration(milliseconds: 100));

    final RenderBox? renderBox = messageContext.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final position = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    final screenWidth = MediaQuery.of(context).size.width;

    const pickerWidth = 280.0;
    double leftPosition = position.dx;

    // Ajustar posición si se sale de la pantalla
    if (leftPosition + pickerWidth > screenWidth) {
      leftPosition = position.dx + size.width - pickerWidth;
      if (leftPosition < 0) {
        leftPosition = (screenWidth - pickerWidth) / 2;
      }
    }

    // Remover overlay anterior si existe
    _reactionOverlay?.remove();

    _reactionOverlay = OverlayEntry(
      builder: (ctx) => GestureDetector(
        onTap: () {
          _reactionOverlay?.remove();
          _reactionOverlay = null;
        },
        child: Container(
          color: Colors.transparent,
          child: Stack(
            children: [
              Positioned(
                top: position.dy - 60,
                left: leftPosition,
                child: Material(
                  color: Colors.transparent,
                  child: ReactionPicker(
                    onReactionSelected: (reaction) {
                      _reactionOverlay?.remove();
                      _reactionOverlay = null;
                      reactionService.toggleReaction(
                        chatId: chatId,
                        messageId: messageId,
                        reaction: reaction,
                        isGroup: isGroup,
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_reactionOverlay!);

    // Auto-dismiss después de 5 segundos
    Future.delayed(const Duration(seconds: 5), () {
      _reactionOverlay?.remove();
      _reactionOverlay = null;
    });
  }

  /// Cierra el picker de reacciones si está abierto
  void closeReactionPicker() {
    _reactionOverlay?.remove();
    _reactionOverlay = null;
  }

  /// Llamar en dispose() del State para limpiar recursos
  void disposeReactionPicker() {
    _reactionOverlay?.remove();
    _reactionOverlay = null;
  }
}
