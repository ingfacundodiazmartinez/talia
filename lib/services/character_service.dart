import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../models/character.dart';
import '../utils/release_logger.dart';
import 'subscription_service.dart';

/// Servicio para gestionar personajes y transformaciones con IA
class CharacterService {
  // Singleton pattern
  static final CharacterService _instance = CharacterService._internal();
  factory CharacterService() => _instance;
  CharacterService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;
  final SubscriptionService _subscriptionService = SubscriptionService();

  // ✅ Cache de personajes para evitar queries repetidas
  List<Character>? _cachedCharacters;
  DateTime? _cacheTimestamp;
  static const _cacheDuration = Duration(minutes: 5);

  // ✅ Flag para pre-carga en progreso
  bool _isPreloading = false;

  /// Pre-cargar personajes al inicio de la app (llamar desde main.dart)
  /// Esto evita el problema de personajes vacíos al abrir face-swap rápidamente
  Future<void> preloadCharacters() async {
    if (_isPreloading) {
      ReleaseLogger.log('⏳ Pre-carga de personajes ya en progreso...', tag: 'CharacterService');
      return;
    }

    _isPreloading = true;
    ReleaseLogger.log('🎭 Pre-cargando personajes...', tag: 'CharacterService');

    try {
      final characters = await _fetchCharactersWithRetry();
      _cachedCharacters = characters;
      _cacheTimestamp = DateTime.now();
      ReleaseLogger.log('✅ ${characters.length} personajes pre-cargados', tag: 'CharacterService');
    } catch (e) {
      ReleaseLogger.error('❌ Error pre-cargando personajes: $e', tag: 'CharacterService');
    } finally {
      _isPreloading = false;
    }
  }

  /// Obtener todos los personajes habilitados ordenados
  /// Con retry automático y caché para evitar fallos transitorios
  Future<List<Character>> getEnabledCharacters() async {
    // ✅ Si hay caché válido, usarlo inmediatamente
    if (_cachedCharacters != null && _cacheTimestamp != null) {
      final cacheAge = DateTime.now().difference(_cacheTimestamp!);
      if (cacheAge < _cacheDuration) {
        ReleaseLogger.log('📦 Usando caché de ${_cachedCharacters!.length} personajes (edad: ${cacheAge.inSeconds}s)', tag: 'CharacterService');
        return _cachedCharacters!;
      }
    }

    // ✅ Fetch con retry
    try {
      final characters = await _fetchCharactersWithRetry();

      // Actualizar caché
      _cachedCharacters = characters;
      _cacheTimestamp = DateTime.now();

      return characters;
    } catch (e) {
      ReleaseLogger.error('❌ Error obteniendo personajes después de reintentos: $e', tag: 'CharacterService');

      // Si hay caché (aunque esté viejo), usarlo como fallback
      if (_cachedCharacters != null && _cachedCharacters!.isNotEmpty) {
        ReleaseLogger.log('⚠️ Usando caché antiguo como fallback (${_cachedCharacters!.length} personajes)', tag: 'CharacterService');
        return _cachedCharacters!;
      }

      return [];
    }
  }

  /// Obtener personajes filtrados según el tier del usuario actual
  /// - Free: solo personajes con accessLevel = 'free'
  /// - Premium: personajes con accessLevel = 'free' o 'premium'
  /// - Premium+: todos los personajes
  /// - Si premium está desactivado: todos los personajes
  Future<List<Character>> getCharactersForCurrentUser() async {
    try {
      // Obtener todos los personajes habilitados
      final allCharacters = await getEnabledCharacters();

      // Obtener el tier del usuario actual
      final status = await _subscriptionService.checkPremiumStatus();

      // Si el sistema premium está desactivado, todos tienen acceso a todos los personajes
      if (status.premiumSystemDisabled) {
        ReleaseLogger.log('🎭 Sistema premium desactivado - todos los personajes disponibles', tag: 'CharacterService');
        return allCharacters;
      }

      final tierName = status.tier.name;

      ReleaseLogger.log('🎭 Filtrando personajes para tier: $tierName', tag: 'CharacterService');

      // Filtrar según el tier
      final filteredCharacters = allCharacters.where((character) {
        return character.isAccessibleForTier(tierName);
      }).toList();

      ReleaseLogger.log('✅ ${filteredCharacters.length}/${allCharacters.length} personajes disponibles para $tierName', tag: 'CharacterService');

      return filteredCharacters;
    } catch (e) {
      ReleaseLogger.error('❌ Error filtrando personajes por tier: $e', tag: 'CharacterService');
      // En caso de error, retornar solo personajes free para seguridad
      final allCharacters = await getEnabledCharacters();
      return allCharacters.where((c) => c.accessLevel == CharacterAccessLevel.free).toList();
    }
  }

  /// Verificar si el usuario actual puede usar un personaje específico
  Future<bool> canUserAccessCharacter(String characterId) async {
    try {
      final status = await _subscriptionService.checkPremiumStatus();

      // Si el sistema premium está desactivado, todos pueden acceder a todos los personajes
      if (status.premiumSystemDisabled) return true;

      final tierName = status.tier.name;

      final allCharacters = await getEnabledCharacters();
      final character = allCharacters.where((c) => c.id == characterId).firstOrNull;

      if (character == null) return false;

      return character.isAccessibleForTier(tierName);
    } catch (e) {
      return false;
    }
  }

  /// Fetch de personajes con retry automático para errores transitorios
  Future<List<Character>> _fetchCharactersWithRetry({int maxRetries = 3}) async {
    int attempt = 0;
    Object? lastError;

    while (attempt < maxRetries) {
      try {
        attempt++;
        ReleaseLogger.log('🔄 Intentando cargar personajes (intento $attempt/$maxRetries)...', tag: 'CharacterService');

        final snapshot = await _firestore
            .collection('characters')
            .where('enabled', isEqualTo: true)
            .orderBy('order')
            .get();

        final characters = snapshot.docs.map((doc) => Character.fromFirestore(doc)).toList();
        ReleaseLogger.log('✅ ${characters.length} personajes cargados exitosamente', tag: 'CharacterService');
        return characters;

      } catch (e) {
        lastError = e;
        ReleaseLogger.error('⚠️ Error en intento $attempt: $e', tag: 'CharacterService');

        // No reintentar si es error de permisos
        if (e.toString().contains('permission-denied') ||
            e.toString().contains('PERMISSION_DENIED')) {
          ReleaseLogger.error('🚫 Error de permisos - no se reintentará', tag: 'CharacterService');
          break;
        }

        // Esperar antes de reintentar (backoff exponencial)
        if (attempt < maxRetries) {
          final delay = Duration(milliseconds: 500 * attempt);
          ReleaseLogger.log('⏳ Esperando ${delay.inMilliseconds}ms antes de reintentar...', tag: 'CharacterService');
          await Future.delayed(delay);
        }
      }
    }

    throw lastError ?? Exception('Error desconocido cargando personajes');
  }

  /// Invalidar caché (útil para forzar recarga)
  void invalidateCache() {
    _cachedCharacters = null;
    _cacheTimestamp = null;
    ReleaseLogger.log('🗑️ Caché de personajes invalidado', tag: 'CharacterService');
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

      // 2. Escuchar cambios en Firestore en tiempo real
      // ✅ RENAMED: transformationStatus → transformation_status (snake_case)
      final statusDoc = _firestore
          .collection('transformation_status')
          .doc(statusDocId);

      // Crear un Completer para esperar el resultado
      final completer = Completer<String>();
      late StreamSubscription subscription;

      subscription = statusDoc.snapshots().listen(
        (snapshot) {
          if (!snapshot.exists) {
            return;
          }

          final data = snapshot.data();
          if (data == null) return;

          final status = data['status'] as String?;
          final progress = (data['progress'] as num?)?.toDouble() ?? 0.0;
          final message = data['message'] as String?;


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
              subscription.cancel();
              if (!completer.isCompleted) {
                completer.complete(outputUrl);
              }
            }
          } else if (status == 'failed') {
            final error = data['error'] as String? ?? 'Error desconocido';
            subscription.cancel();
            if (!completer.isCompleted) {
              completer.completeError(Exception('Transformación falló: $error'));
            }
          } else if (status == 'timeout') {
            final error = data['error'] as String? ?? 'Timeout';
            subscription.cancel();
            if (!completer.isCompleted) {
              completer.completeError(Exception('Timeout: $error'));
            }
          } else if (status == 'error') {
            final error = data['error'] as String? ?? 'Error durante procesamiento';
            subscription.cancel();
            if (!completer.isCompleted) {
              completer.completeError(Exception(error));
            }
          } else if (status == 'canceled') {
            subscription.cancel();
            if (!completer.isCompleted) {
              completer.completeError(Exception('Transformación cancelada'));
            }
          }
        },
        onError: (error) {
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

      return transformedUrl;
    } catch (e) {
      rethrow;
    }
  }

  /// Agregar un personaje (solo para admin)
  Future<String> addCharacter(Character character) async {
    try {
      final docRef = await _firestore
          .collection('characters')
          .add(character.toMap());

      return docRef.id;
    } catch (e) {
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

    } catch (e) {
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

    } catch (e) {
      rethrow;
    }
  }
}
