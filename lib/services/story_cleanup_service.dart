import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';

class StoryCleanupService {
  static final StoryCleanupService _instance = StoryCleanupService._internal();
  factory StoryCleanupService() => _instance;
  StoryCleanupService._internal();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  Timer? _cleanupTimer;

  // Iniciar limpieza automática cada hora
  void startAutoCleanup() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(Duration(hours: 1), (timer) {
      _cleanupExpiredStories();
    });

    // Ejecutar limpieza inicial
    _cleanupExpiredStories();
  }

  // Detener limpieza automática
  void stopAutoCleanup() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
  }

  // Limpiar historias expiradas
  Future<void> _cleanupExpiredStories() async {
    try {
      print('🧹 Iniciando limpieza de historias expiradas...');

      final now = DateTime.now();
      final expiredStoriesQuery = await _firestore
          .collection('stories')
          .where('expiresAt', isLessThan: Timestamp.fromDate(now))
          .get();

      if (expiredStoriesQuery.docs.isEmpty) {
        print('✅ No hay historias expiradas para limpiar');
        return;
      }

      print('🗑️ Encontradas ${expiredStoriesQuery.docs.length} historias expiradas');

      int deletedFiles = 0;
      int deletedDocs = 0;

      for (final storyDoc in expiredStoriesQuery.docs) {
        try {
          final storyData = storyDoc.data();

          // Eliminar archivo de Storage
          if (storyData['mediaUrl'] != null) {
            try {
              final mediaUrl = storyData['mediaUrl'] as String;
              final storageRef = _storage.refFromURL(mediaUrl);
              await storageRef.delete();
              deletedFiles++;
            } catch (e) {
              print('⚠️ Error eliminando archivo de Storage para historia ${storyDoc.id}: $e');
            }
          }

          // Eliminar documento de Firestore
          await storyDoc.reference.delete();
          deletedDocs++;

        } catch (e) {
          print('❌ Error eliminando historia ${storyDoc.id}: $e');
        }
      }

      print('✅ Limpieza completada: $deletedDocs documentos y $deletedFiles archivos eliminados');

    } catch (e) {
      print('❌ Error en limpieza automática de historias: $e');
    }
  }

  // Limpiar historias de un usuario específico (cuando se elimina cuenta)
  Future<void> cleanupUserStories(String userId) async {
    try {
      print('🧹 Limpiando historias del usuario: $userId');

      final userStoriesQuery = await _firestore
          .collection('stories')
          .where('userId', isEqualTo: userId)
          .get();

      for (final storyDoc in userStoriesQuery.docs) {
        try {
          final storyData = storyDoc.data();

          // Eliminar archivo de Storage
          if (storyData['mediaUrl'] != null) {
            try {
              final mediaUrl = storyData['mediaUrl'] as String;
              final storageRef = _storage.refFromURL(mediaUrl);
              await storageRef.delete();
            } catch (e) {
              print('Error eliminando archivo de Storage: $e');
            }
          }

          // Eliminar documento
          await storyDoc.reference.delete();

        } catch (e) {
          print('Error eliminando historia ${storyDoc.id}: $e');
        }
      }

      print('✅ Historias del usuario $userId eliminadas');

    } catch (e) {
      print('❌ Error limpiando historias del usuario $userId: $e');
    }
  }

  // Obtener estadísticas de historias
  Future<Map<String, int>> getStoriesStats() async {
    try {
      final now = DateTime.now();

      // Historias activas
      final activeStoriesQuery = await _firestore
          .collection('stories')
          .where('expiresAt', isGreaterThan: Timestamp.fromDate(now))
          .get();

      // Historias expiradas
      final expiredStoriesQuery = await _firestore
          .collection('stories')
          .where('expiresAt', isLessThan: Timestamp.fromDate(now))
          .get();

      // Historias de las últimas 24 horas
      final last24Hours = now.subtract(Duration(hours: 24));
      final recentStoriesQuery = await _firestore
          .collection('stories')
          .where('createdAt', isGreaterThan: Timestamp.fromDate(last24Hours))
          .get();

      return {
        'active': activeStoriesQuery.docs.length,
        'expired': expiredStoriesQuery.docs.length,
        'recent24h': recentStoriesQuery.docs.length,
      };

    } catch (e) {
      print('Error obteniendo estadísticas de historias: $e');
      return {
        'active': 0,
        'expired': 0,
        'recent24h': 0,
      };
    }
  }

  // Cleanup manual
  Future<void> manualCleanup() async {
    await _cleanupExpiredStories();
  }
}