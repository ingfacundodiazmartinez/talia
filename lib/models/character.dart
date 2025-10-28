import 'package:cloud_firestore/cloud_firestore.dart';

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
  });

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
    };
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
    );
  }
}
