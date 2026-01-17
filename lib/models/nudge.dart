/// Tipos de nudge disponibles
enum NudgeType {
  latido,  // 💓 Latido (envía afecto, inicia conversación)
  zumbido, // 📳 Zumbido (retomar conversación)
  saludo,  // 👋 Saludo (inicia conversación casual)
  psst,    // 🤫 Psst (tiene algo nuevo, fomenta ver historias)
}

/// Tipo de animación para el banner
enum NudgeAnimation {
  pulse,  // Para latido - escala sutil como corazón
  shake,  // Para zumbido - temblor horizontal
  wave,   // Para saludo - ondulación suave
  fadeIn, // Para psst - aparición misteriosa con bounce
}

/// Extensión con propiedades y métodos útiles para NudgeType
extension NudgeTypeExtension on NudgeType {
  /// Emoji representativo del tipo
  String get emoji {
    switch (this) {
      case NudgeType.latido:
        return '💓';
      case NudgeType.zumbido:
        return '📳';
      case NudgeType.saludo:
        return '👋';
      case NudgeType.psst:
        return '🤫';
    }
  }

  /// Nombre para mostrar en el selector
  String get displayName {
    switch (this) {
      case NudgeType.latido:
        return 'Latido';
      case NudgeType.zumbido:
        return 'Zumbido';
      case NudgeType.saludo:
        return 'Saludo';
      case NudgeType.psst:
        return 'Psst';
    }
  }

  /// Mensaje que ve el receptor
  String get receivedMessage {
    switch (this) {
      case NudgeType.latido:
        return 'Te envió un latido';
      case NudgeType.zumbido:
        return 'Te envió un zumbido';
      case NudgeType.saludo:
        return 'Te envió un saludo';
      case NudgeType.psst:
        return 'Tiene algo nuevo';
    }
  }

  /// Tipo de animación para el banner
  NudgeAnimation get animation {
    switch (this) {
      case NudgeType.latido:
        return NudgeAnimation.pulse;
      case NudgeType.zumbido:
        return NudgeAnimation.shake;
      case NudgeType.saludo:
        return NudgeAnimation.wave;
      case NudgeType.psst:
        return NudgeAnimation.fadeIn;
    }
  }

  /// Patrón de vibración en milisegundos [pausa, vibra, pausa, vibra, ...]
  List<int> get vibrationPattern {
    switch (this) {
      case NudgeType.latido:
        // tum-tum como corazón
        return [0, 100, 100, 100];
      case NudgeType.zumbido:
        // Vibración rápida e insistente
        return [0, 50, 50, 50, 50, 50, 50, 50];
      case NudgeType.saludo:
        // Vibración amigable
        return [0, 80, 80, 80];
      case NudgeType.psst:
        // Vibración suave, discreta
        return [0, 60, 150, 60];
    }
  }

  /// Intensidades de vibración (0-255) para Android
  List<int> get vibrationIntensities {
    switch (this) {
      case NudgeType.latido:
        return [0, 200, 0, 200];
      case NudgeType.zumbido:
        return [0, 255, 0, 255, 0, 255, 0, 255];
      case NudgeType.saludo:
        return [0, 180, 0, 180];
      case NudgeType.psst:
        return [0, 120, 0, 120];
    }
  }

  /// Volumen del sonido (0.0 - 1.0)
  double get soundVolume {
    switch (this) {
      case NudgeType.latido:
        return 0.5;
      case NudgeType.zumbido:
        return 0.7;
      case NudgeType.saludo:
        return 0.5;
      case NudgeType.psst:
        return 0.3;
    }
  }

  /// Crear desde string (para FCM payload)
  static NudgeType fromString(String value) {
    switch (value) {
      case 'latido':
        return NudgeType.latido;
      case 'zumbido':
        return NudgeType.zumbido;
      case 'saludo':
        return NudgeType.saludo;
      case 'psst':
        return NudgeType.psst;
      default:
        return NudgeType.latido;
    }
  }
}

/// Datos de un nudge recibido (desde FCM payload)
class NudgeData {
  final String senderId;
  final String senderName;
  final String? senderPhotoUrl;
  final NudgeType type;
  final DateTime sentAt;
  final DateTime expiresAt;

  /// Tiempo en segundos para mostrar el banner
  static const int displayDurationSeconds = 5;

  NudgeData({
    required this.senderId,
    required this.senderName,
    this.senderPhotoUrl,
    required this.type,
    required this.sentAt,
    DateTime? expiresAt,
  }) : expiresAt = expiresAt ?? sentAt.add(Duration(seconds: displayDurationSeconds));

  /// Verificar si el nudge expiró
  bool get isExpired => DateTime.now().isAfter(expiresAt);

  /// Segundos restantes para mostrar
  int get secondsRemaining {
    final remaining = expiresAt.difference(DateTime.now()).inSeconds;
    return remaining > 0 ? remaining : 0;
  }

  /// Factory desde FCM data payload
  factory NudgeData.fromFcmPayload(Map<String, dynamic> data) {
    final sentAtMillis = int.tryParse(data['sentAt']?.toString() ?? '') ??
                         DateTime.now().millisecondsSinceEpoch;
    final sentAt = DateTime.fromMillisecondsSinceEpoch(sentAtMillis);

    return NudgeData(
      senderId: data['senderId'] ?? '',
      senderName: data['senderName'] ?? 'Alguien',
      senderPhotoUrl: data['senderPhotoUrl'],
      type: NudgeTypeExtension.fromString(data['nudgeType'] ?? 'latido'),
      sentAt: sentAt,
    );
  }

  /// Mensaje para mostrar al receptor
  String get message => '${type.emoji} $senderName ${type.receivedMessage.toLowerCase()}';

  /// Tipo de animación para el banner
  NudgeAnimation get animation => type.animation;

  @override
  String toString() {
    return 'NudgeData(from: $senderName, type: ${type.name}, expired: $isExpired)';
  }
}
