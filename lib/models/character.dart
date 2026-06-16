import 'package:cloud_firestore/cloud_firestore.dart';

/// Nivel de acceso requerido para usar el personaje
enum CharacterAccessLevel {
  free,      // Disponible para todos
  premium,   // Solo Premium y Premium+
  premiumPlus;  // Solo Premium+

  static CharacterAccessLevel fromString(String? value) {
    switch (value?.toLowerCase()) {
      case 'premium':
        return CharacterAccessLevel.premium;
      case 'premium_plus':
        return CharacterAccessLevel.premiumPlus;
      default:
        return CharacterAccessLevel.free;
    }
  }

  String get name {
    switch (this) {
      case CharacterAccessLevel.free:
        return 'free';
      case CharacterAccessLevel.premium:
        return 'premium';
      case CharacterAccessLevel.premiumPlus:
        return 'premium_plus';
    }
  }
}

/// Modelo de personaje para transformación con IA
class Character {
  final String id;
  final String name;
  final String category;
  final String thumbnailUrl;
  final String referenceImageUrl;
  final bool enabled;
  final int order;
  final Map<String, dynamic>? modelConfig;
  final DateTime createdAt;
  /// Nivel de acceso requerido para usar este personaje
  final CharacterAccessLevel accessLevel;
  /// Modelo de IA usado: 'face_swap' | 'p_image_edit' | 'nano_banana' | 'auto'.
  /// Determina el costo en créditos del wallet familiar.
  final String aiModel;

  Character({
    required this.id,
    required this.name,
    required this.category,
    required this.thumbnailUrl,
    required this.referenceImageUrl,
    this.enabled = true,
    this.order = 0,
    this.modelConfig,
    required this.createdAt,
    this.accessLevel = CharacterAccessLevel.free,
    this.aiModel = 'auto',
  });

  /// Costo en créditos del wallet familiar para usar este personaje.
  /// Debe estar sincronizado con FEATURE_PRICES en functions/wallet.js.
  int get creditCost {
    switch (aiModel) {
      case 'face_swap':
        return 1;
      case 'p_image_edit':
      case 'nano_banana': // key Firestore; el backend invoca gpt-image-2 low
        return 2;
      case 'auto':
      default:
        // Fallback conservador: si no se sabe, asumir el caro (edit con prompt).
        return 2;
    }
  }

  /// Indica si el personaje usa IA generativa (edit con prompt), no solo face-swap.
  /// Usado para mostrar el badge "✨ IA" en la card.
  bool get usesGenerativeAi {
    return aiModel == 'p_image_edit' || aiModel == 'nano_banana';
  }

  /// Crear Character desde documento de Firestore
  factory Character.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return Character(
      id: doc.id,
      name: data['name'] ?? '',
      category: data['category'] ?? '',
      thumbnailUrl: data['thumbnailUrl'] ?? '',
      referenceImageUrl: data['referenceImageUrl'] ?? '',
      enabled: data['enabled'] ?? true,
      order: data['order'] ?? 0,
      modelConfig: data['modelConfig'] as Map<String, dynamic>?,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      accessLevel: CharacterAccessLevel.fromString(data['accessLevel'] as String?),
      aiModel: data['aiModel'] as String? ?? 'auto',
    );
  }

  /// Convertir Character a Map para Firestore
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'category': category,
      'thumbnailUrl': thumbnailUrl,
      'referenceImageUrl': referenceImageUrl,
      'enabled': enabled,
      'order': order,
      'modelConfig': modelConfig,
      'createdAt': Timestamp.fromDate(createdAt),
      'accessLevel': accessLevel.name,
      'aiModel': aiModel,
    };
  }

  /// Verificar si el personaje es accesible para un tier dado
  bool isAccessibleForTier(String tierName) {
    switch (accessLevel) {
      case CharacterAccessLevel.free:
        return true; // Todos pueden usar personajes free
      case CharacterAccessLevel.premium:
        return tierName == 'premium' || tierName == 'premium_plus';
      case CharacterAccessLevel.premiumPlus:
        return tierName == 'premium_plus';
    }
  }

  /// Copiar con modificaciones
  Character copyWith({
    String? id,
    String? name,
    String? category,
    String? thumbnailUrl,
    String? referenceImageUrl,
    bool? enabled,
    int? order,
    Map<String, dynamic>? modelConfig,
    DateTime? createdAt,
    CharacterAccessLevel? accessLevel,
    String? aiModel,
  }) {
    return Character(
      id: id ?? this.id,
      name: name ?? this.name,
      category: category ?? this.category,
      thumbnailUrl: thumbnailUrl ?? this.thumbnailUrl,
      referenceImageUrl: referenceImageUrl ?? this.referenceImageUrl,
      enabled: enabled ?? this.enabled,
      order: order ?? this.order,
      modelConfig: modelConfig ?? this.modelConfig,
      createdAt: createdAt ?? this.createdAt,
      accessLevel: accessLevel ?? this.accessLevel,
      aiModel: aiModel ?? this.aiModel,
    );
  }
}
