import 'package:cloud_firestore/cloud_firestore.dart';

/// Utilidades centralizadas para conversión de Timestamps
///
/// Uso:
/// ```dart
/// import 'package:talia/utils/timestamp_utils.dart';
///
/// final date = TimestampUtils.toDateTime(data['createdAt']);
/// final iso = TimestampUtils.toIso8601(data['updatedAt']);
/// ```
class TimestampUtils {
  TimestampUtils._();

  /// Convierte cualquier tipo de fecha a DateTime
  ///
  /// Soporta: Timestamp, String (ISO8601), DateTime, int (milliseconds)
  /// Retorna null si no puede convertir
  static DateTime? toDateTime(dynamic value) {
    if (value == null) return null;

    if (value is DateTime) return value;

    if (value is Timestamp) return value.toDate();

    if (value is String) {
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed;
    }

    if (value is int) {
      // Assume milliseconds since epoch
      return DateTime.fromMillisecondsSinceEpoch(value);
    }

    return null;
  }

  /// Convierte a String ISO8601
  ///
  /// Útil para almacenar en Hive u otros almacenes que no soportan Timestamp
  static String? toIso8601(dynamic value) {
    final dt = toDateTime(value);
    return dt?.toIso8601String();
  }

  /// Convierte a Timestamp de Firestore
  static Timestamp? toTimestamp(dynamic value) {
    final dt = toDateTime(value);
    return dt != null ? Timestamp.fromDate(dt) : null;
  }

  /// Parsea birthDate con lógica especial para edad aproximada
  ///
  /// Soporta:
  /// - Timestamp
  /// - String ISO8601
  /// - int (edad aproximada - calcula fecha de nacimiento)
  static DateTime? parseBirthDate(dynamic value) {
    if (value == null) return null;

    if (value is Timestamp) return value.toDate();

    if (value is DateTime) return value;

    if (value is String) return DateTime.tryParse(value);

    if (value is int) {
      // Si es un número pequeño (1-120), asumimos que es edad
      if (value > 0 && value <= 120) {
        final now = DateTime.now();
        return DateTime(now.year - value, now.month, now.day);
      }
      // Si es un número grande, asumimos milliseconds
      if (value > 1000000000) {
        return DateTime.fromMillisecondsSinceEpoch(value);
      }
    }

    return null;
  }
}
