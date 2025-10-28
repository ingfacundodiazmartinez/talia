import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../models/character.dart';

/// Servicio para gestionar personajes y transformaciones con IA
class CharacterService {
  // Singleton pattern
  static final CharacterService _instance = CharacterService._internal();
  factory CharacterService() => _instance;
  CharacterService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Obtener todos los personajes habilitados ordenados
  Future<List<Character>> getEnabledCharacters() async {
    try {
      final snapshot = await _firestore
          .collection('characters')
          .where('enabled', isEqualTo: true)
          .orderBy('order')
          .get();

      return snapshot.docs.map((doc) => Character.fromFirestore(doc)).toList();
    } catch (e) {
      print('❌ Error obteniendo personajes: $e');
      return [];
    }
  }

  /// Obtener personajes por categoría
  Future<List<Character>> getCharactersByCategory(String category) async {
    try {
      final snapshot = await _firestore
          .collection('characters')
          .where('category', isEqualTo: category)
          .where('enabled', isEqualTo: true)
          .orderBy('order')
          .get();

      return snapshot.docs.map((doc) => Character.fromFirestore(doc)).toList();
    } catch (e) {
      print('❌ Error obteniendo personajes por categoría: $e');
      return [];
    }
  }

  /// Stream de personajes habilitados (para UI reactiva)
  Stream<List<Character>> watchEnabledCharacters() {
    return _firestore
        .collection('characters')
        .where('enabled', isEqualTo: true)
        .orderBy('order')
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) => Character.fromFirestore(doc)).toList();
    });
  }

  /// Transformar imagen usando un personaje específico
  ///
  /// Params:
  /// - imageUrl: URL de la imagen del usuario (subida a Storage)
  /// - characterId: ID del personaje a usar
  ///
  /// Returns:
  /// - URL de la imagen transformada
  Future<String> transformImage({
    required String imageUrl,
    required String characterId,
  }) async {
    try {
      print('🎭 Iniciando transformación con personaje $characterId');
      print('📸 Imagen original: $imageUrl');

      // Configurar timeout de 2 minutos (120 segundos)
      final callable = _functions.httpsCallable(
        'transformCharacter',
        options: HttpsCallableOptions(
          timeout: Duration(seconds: 120),
        ),
      );

      final result = await callable.call({
        'imageUrl': imageUrl,
        'characterId': characterId,
      });

      final transformedUrl = result.data['transformedImageUrl'] as String;
      print('✅ Transformación completada: $transformedUrl');

      return transformedUrl;
    } catch (e) {
      print('❌ Error transformando imagen: $e');
      rethrow;
    }
  }

  /// Agregar un personaje (solo para admin)
  Future<String> addCharacter(Character character) async {
    try {
      final docRef = await _firestore
          .collection('characters')
          .add(character.toMap());

      print('✅ Personaje agregado: ${docRef.id}');
      return docRef.id;
    } catch (e) {
      print('❌ Error agregando personaje: $e');
      rethrow;
    }
  }

  /// Actualizar un personaje (solo para admin)
  Future<void> updateCharacter(String characterId, Map<String, dynamic> updates) async {
    try {
      await _firestore
          .collection('characters')
          .doc(characterId)
          .update(updates);

      print('✅ Personaje actualizado: $characterId');
    } catch (e) {
      print('❌ Error actualizando personaje: $e');
      rethrow;
    }
  }

  /// Eliminar un personaje (solo para admin)
  Future<void> deleteCharacter(String characterId) async {
    try {
      await _firestore
          .collection('characters')
          .doc(characterId)
          .delete();

      print('✅ Personaje eliminado: $characterId');
    } catch (e) {
      print('❌ Error eliminando personaje: $e');
      rethrow;
    }
  }
}
