import 'package:flutter/material.dart';

/// Widget que muestra separadores de fecha entre mensajes
///
/// Responsabilidades:
/// - Determinar si se debe mostrar un separador entre mensajes
/// - Formatear la fecha apropiadamente (Hoy, Ayer, fecha completa)
/// - Renderizar el separador con estilo consistente
class DateSeparatorWidget extends StatelessWidget {
  final DateTime date;

  const DateSeparatorWidget({
    super.key,
    required this.date,
  });

  /// Determina si se debe mostrar un separador de fecha antes de este mensaje
  static bool shouldShowSeparator({
    required int index,
    required int totalMessages,
    required DateTime currentMessageDate,
    required DateTime nextMessageDate,
  }) {
    // Si es el último mensaje de la lista (el más antiguo), siempre mostrar fecha
    if (index == totalMessages - 1) {
      return true;
    }

    final currentDate = DateTime(
      currentMessageDate.year,
      currentMessageDate.month,
      currentMessageDate.day,
    );

    final nextDate = DateTime(
      nextMessageDate.year,
      nextMessageDate.month,
      nextMessageDate.day,
    );

    // Mostrar separador si las fechas son diferentes
    return currentDate != nextDate;
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final messageDate = DateTime(date.year, date.month, date.day);

    String dateText;
    if (messageDate == today) {
      dateText = 'Hoy';
    } else if (messageDate == yesterday) {
      dateText = 'Ayer';
    } else {
      // Formato: "25 Dic, 2023"
      const months = [
        '',
        'Ene',
        'Feb',
        'Mar',
        'Abr',
        'May',
        'Jun',
        'Jul',
        'Ago',
        'Sep',
        'Oct',
        'Nov',
        'Dic',
      ];
      dateText = '${date.day} ${months[date.month]}, ${date.year}';
    }

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          dateText,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}
