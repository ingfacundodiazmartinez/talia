/// Tipo de contenido compartido desde apps externas
enum SharedContentType {
  image,
  video,
  text,
  url,
  document;

  static SharedContentType fromString(String value) {
    switch (value.toLowerCase()) {
      case 'image':
        return SharedContentType.image;
      case 'video':
        return SharedContentType.video;
      case 'url':
        return SharedContentType.url;
      case 'document':
      case 'file':
        return SharedContentType.document;
      default:
        return SharedContentType.text;
    }
  }

  String get displayName {
    switch (this) {
      case SharedContentType.image:
        return 'Imagen';
      case SharedContentType.video:
        return 'Video';
      case SharedContentType.text:
        return 'Texto';
      case SharedContentType.url:
        return 'Enlace';
      case SharedContentType.document:
        return 'Documento';
    }
  }
}

/// Destino para el contenido compartido
enum ShareDestination {
  chat,
  story;

  String get displayName {
    switch (this) {
      case ShareDestination.chat:
        return 'Chat';
      case ShareDestination.story:
        return 'Historia';
    }
  }
}

/// Modelo que representa contenido compartido desde apps externas
///
/// Este modelo es local (no corresponde a una colección de Firestore)
/// ya que representa datos temporales recibidos de otras apps.
class SharedContent {
  final String id;
  final SharedContentType type;
  final String? text;
  final String? mediaPath;
  final String? url;
  final String? mimeType;
  final int? fileSize;
  final DateTime timestamp;

  SharedContent({
    required this.id,
    required this.type,
    this.text,
    this.mediaPath,
    this.url,
    this.mimeType,
    this.fileSize,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Factory constructor desde Map (para datos de share_handler o iOS App Group)
  factory SharedContent.fromMap(Map<String, dynamic> map) {
    return SharedContent(
      id: map['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      type: SharedContentType.fromString(map['type'] ?? 'text'),
      text: map['text'],
      mediaPath: map['path'] ?? map['mediaPath'],
      url: map['url'],
      mimeType: map['mimeType'],
      fileSize: map['fileSize'],
    );
  }

  /// Convertir a Map
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type.name,
      if (text != null) 'text': text,
      if (mediaPath != null) 'mediaPath': mediaPath,
      if (url != null) 'url': url,
      if (mimeType != null) 'mimeType': mimeType,
      if (fileSize != null) 'fileSize': fileSize,
      'timestamp': timestamp.millisecondsSinceEpoch,
    };
  }

  // ═══════════════════════════════════════════════════════════════
  // COMPUTED GETTERS
  // ═══════════════════════════════════════════════════════════════

  /// Indica si es contenido multimedia (imagen o video)
  bool get isMedia =>
      type == SharedContentType.image || type == SharedContentType.video;

  /// Indica si es solo texto
  bool get isText => type == SharedContentType.text;

  /// Indica si es una URL
  bool get isUrl => type == SharedContentType.url;

  /// Indica si es un documento/archivo
  bool get isDocument => type == SharedContentType.document;

  /// Indica si puede usarse para crear una historia
  /// (solo imágenes y videos individuales)
  bool get canBeStory => isMedia && mediaPath != null;

  /// Obtiene una descripción corta del contenido para preview
  String get shortDescription {
    if (text != null && text!.isNotEmpty) {
      return text!.length > 50 ? '${text!.substring(0, 50)}...' : text!;
    }
    if (url != null) {
      return url!.length > 40 ? '${url!.substring(0, 40)}...' : url!;
    }
    return type.displayName;
  }

  /// Obtiene la extensión del archivo si es media
  String? get fileExtension {
    if (mediaPath == null) return null;
    final parts = mediaPath!.split('.');
    return parts.length > 1 ? parts.last.toLowerCase() : null;
  }

  /// Copia con modificaciones
  SharedContent copyWith({
    String? id,
    SharedContentType? type,
    String? text,
    String? mediaPath,
    String? url,
    String? mimeType,
    int? fileSize,
    DateTime? timestamp,
  }) {
    return SharedContent(
      id: id ?? this.id,
      type: type ?? this.type,
      text: text ?? this.text,
      mediaPath: mediaPath ?? this.mediaPath,
      url: url ?? this.url,
      mimeType: mimeType ?? this.mimeType,
      fileSize: fileSize ?? this.fileSize,
      timestamp: timestamp ?? this.timestamp,
    );
  }

  @override
  String toString() {
    return 'SharedContent(id: $id, type: $type, hasMedia: $isMedia)';
  }
}
