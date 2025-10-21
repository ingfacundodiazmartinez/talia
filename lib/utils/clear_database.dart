import 'package:cloud_firestore/cloud_firestore.dart';

/// Script para limpiar completamente la base de datos de Firestore
/// ADVERTENCIA: Esto eliminará TODOS los datos de forma permanente
Future<void> clearDatabase() async {
  final firestore = FirebaseFirestore.instance;

  print('🗑️  Iniciando limpieza de la base de datos...');
  print('⚠️  ADVERTENCIA: Esto eliminará TODOS los datos');

  // Lista de todas las colecciones
  final collections = [
    'users',
    'parent_children',
    'parent_children',
    'chats',
    'messages',
    'contacts',
    'notifications',
    'activities',
    'alerts',
    'story_approval_requests',
    'stories',
    'groups',
    'parent_approval_requests',
    'link_codes',
    'locations',
    'video_calls',
    'chat_permissions',
  ];

  for (final collectionName in collections) {
    try {
      print('🔄 Eliminando colección: $collectionName...');

      // Obtener todos los documentos de la colección
      final snapshot = await firestore.collection(collectionName).get();

      print('   Encontrados ${snapshot.docs.length} documentos');

      // Eliminar cada documento
      for (final doc in snapshot.docs) {
        await doc.reference.delete();
      }

      print('✅ Colección $collectionName eliminada (${snapshot.docs.length} docs)');
    } catch (e) {
      print('❌ Error eliminando $collectionName: $e');
    }
  }

  print('');
  print('✅ ¡Limpieza completada!');
  print('📊 Base de datos ahora está vacía y lista para nuevas pruebas');
}
