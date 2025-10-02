import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import '../lib/firebase_options.dart';

/// Script para limpiar completamente la base de datos de Firestore
/// Uso: dart scripts/clear_firestore.dart
void main() async {
  print('🔥 Iniciando Firebase...');

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  final firestore = FirebaseFirestore.instance;

  print('');
  print('⚠️  ═══════════════════════════════════════════════════════════');
  print('⚠️  ADVERTENCIA: Esto eliminará TODOS los datos de Firestore');
  print('⚠️  ═══════════════════════════════════════════════════════════');
  print('');

  // Lista de todas las colecciones
  final collections = [
    'users',
    'parent_children',
    'parent_child_links',
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

  int totalDeleted = 0;

  for (final collectionName in collections) {
    try {
      print('🔄 Procesando: $collectionName...');

      // Obtener todos los documentos de la colección
      final snapshot = await firestore.collection(collectionName).get();
      final docCount = snapshot.docs.length;

      if (docCount == 0) {
        print('   ℹ️  Colección vacía, saltando...');
        continue;
      }

      print('   📋 Encontrados $docCount documentos');

      // Eliminar cada documento (con subcollections si existen)
      for (final doc in snapshot.docs) {
        // Eliminar subcollection de mensajes si es un chat o grupo
        if (collectionName == 'chats' || collectionName == 'groups') {
          final messagesSnapshot = await doc.reference.collection('messages').get();
          for (final message in messagesSnapshot.docs) {
            await message.reference.delete();
          }
        }

        await doc.reference.delete();
      }

      totalDeleted += docCount;
      print('   ✅ $collectionName eliminada ($docCount documentos)');
    } catch (e) {
      print('   ❌ Error eliminando $collectionName: $e');
    }
  }

  print('');
  print('═══════════════════════════════════════════════════════════');
  print('✅ ¡Limpieza completada!');
  print('📊 Total de documentos eliminados: $totalDeleted');
  print('🎯 Base de datos lista para nuevas pruebas');
  print('═══════════════════════════════════════════════════════════');
}
