import 'dart:async';
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

  /// Transformar imagen usando un personaje específico (versión con progreso real-time)
  ///
  /// Params:
  /// - imageUrl: URL de la imagen del usuario (subida a Storage)
  /// - characterId: ID del personaje a usar
  /// - onProgress: Callback para recibir actualizaciones de progreso (0.0 - 1.0)
  /// - onStatusUpdate: Callback opcional para recibir mensajes de estado
  ///
  /// Returns:
  /// - URL de la imagen transformada
  Future<String> transformImageWithProgress({
    required String imageUrl,
    required String characterId,
    Function(double progress)? onProgress,
    Function(String status)? onStatusUpdate,
  }) async {
    try {
      print('🎭 Iniciando transformación con progreso real-time - personaje $characterId');
      print('📸 Imagen original: $imageUrl');

      // 1. Crear predicción (retorna inmediatamente con statusDocId)
      onProgress?.call(0.05);
      onStatusUpdate?.call('Iniciando transformación...');

      final createCallable = _functions.httpsCallable(
        'createCharacterTransformation',
        options: HttpsCallableOptions(timeout: Duration(seconds: 60)),
      );

      final createResult = await createCallable.call({
        'imageUrl': imageUrl,
        'characterId': characterId,
      });

      final statusDocId = createResult.data['statusDocId'] as String;
      final characterName = createResult.data['characterName'] as String?;
      print('✅ Predicción creada - escuchando documento: $statusDocId');

      // 2. Escuchar cambios en Firestore en tiempo real
      final statusDoc = _firestore
          .collection('transformationStatus')
          .doc(statusDocId);

      // Crear un Completer para esperar el resultado
      final completer = Completer<String>();
      late StreamSubscription subscription;

      subscription = statusDoc.snapshots().listen(
        (snapshot) {
          if (!snapshot.exists) {
            print('⚠️ Documento de estado no existe');
            return;
          }

          final data = snapshot.data();
          if (data == null) return;

          final status = data['status'] as String?;
          final progress = (data['progress'] as num?)?.toDouble() ?? 0.0;
          final message = data['message'] as String?;

          print('📊 Estado actualizado: $status ($progress)');

          // Notificar progreso
          if (onProgress != null) {
            onProgress(progress);
          }

          // Notificar mensaje
          if (onStatusUpdate != null && message != null) {
            onStatusUpdate(message);
          }

          // Verificar si terminó
          if (status == 'succeeded') {
            final outputUrl = data['outputUrl'] as String?;
            if (outputUrl != null) {
              print('✅ Transformación completada: $outputUrl');
              subscription.cancel();
              if (!completer.isCompleted) {
                completer.complete(outputUrl);
              }
            }
          } else if (status == 'failed') {
            final error = data['error'] as String? ?? 'Error desconocido';
            print('❌ Transformación falló: $error');
            subscription.cancel();
            if (!completer.isCompleted) {
              completer.completeError(Exception('Transformación falló: $error'));
            }
          } else if (status == 'timeout') {
            final error = data['error'] as String? ?? 'Timeout';
            print('⏰ Transformación timeout: $error');
            subscription.cancel();
            if (!completer.isCompleted) {
              completer.completeError(Exception('Timeout: $error'));
            }
          } else if (status == 'error') {
            final error = data['error'] as String? ?? 'Error durante procesamiento';
            print('❌ Error en transformación: $error');
            subscription.cancel();
            if (!completer.isCompleted) {
              completer.completeError(Exception(error));
            }
          } else if (status == 'canceled') {
            print('⚠️ Transformación cancelada');
            subscription.cancel();
            if (!completer.isCompleted) {
              completer.completeError(Exception('Transformación cancelada'));
            }
          }
        },
        onError: (error) {
          print('❌ Error en listener de Firestore: $error');
          subscription.cancel();
          if (!completer.isCompleted) {
            completer.completeError(error);
          }
        },
      );

      // Timeout de seguridad (3 minutos)
      return await completer.future.timeout(
        Duration(minutes: 3),
        onTimeout: () {
          subscription.cancel();
          throw Exception('Timeout esperando transformación después de 3 minutos');
        },
      );
    } catch (e) {
      print('❌ Error transformando imagen: $e');
      rethrow;
    }
  }

  /// Transformar imagen usando un personaje específico (versión simple, sin progreso)
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
