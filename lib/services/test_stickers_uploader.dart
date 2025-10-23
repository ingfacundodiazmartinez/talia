import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Servicio temporal para subir stickers de prueba
/// SOLO PARA DESARROLLO - Eliminar en producción
class TestStickersUploader {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static final List<Map<String, dynamic>> testStickers = [
    // Categoría: Emociones
    {
      'name': 'cara_feliz',
      'emoji': '😊',
      'category': 'emociones',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f60a.png',
      'active': true,
      'order': 0,
    },
    {
      'name': 'risa',
      'emoji': '😂',
      'category': 'emociones',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f602.png',
      'active': true,
      'order': 1,
    },
    {
      'name': 'amor',
      'emoji': '🥰',
      'category': 'emociones',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f970.png',
      'active': true,
      'order': 2,
    },
    {
      'name': 'cool',
      'emoji': '😎',
      'category': 'emociones',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f60e.png',
      'active': true,
      'order': 3,
    },
    {
      'name': 'pensando',
      'emoji': '🤔',
      'category': 'emociones',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f914.png',
      'active': true,
      'order': 4,
    },
    {
      'name': 'ojos_corazon',
      'emoji': '😍',
      'category': 'emociones',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f60d.png',
      'active': true,
      'order': 5,
    },

    // Categoría: Gestos
    {
      'name': 'pulgar_arriba',
      'emoji': '👍',
      'category': 'gestos',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f44d.png',
      'active': true,
      'order': 10,
    },
    {
      'name': 'aplausos',
      'emoji': '👏',
      'category': 'gestos',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f44f.png',
      'active': true,
      'order': 11,
    },
    {
      'name': 'rezando',
      'emoji': '🙏',
      'category': 'gestos',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f64f.png',
      'active': true,
      'order': 12,
    },

    // Categoría: Corazones
    {
      'name': 'corazon_rojo',
      'emoji': '❤️',
      'category': 'corazones',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/2764-fe0f.png',
      'active': true,
      'order': 20,
    },
    {
      'name': 'corazon_azul',
      'emoji': '💙',
      'category': 'corazones',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f499.png',
      'active': true,
      'order': 21,
    },
    {
      'name': 'corazon_verde',
      'emoji': '💚',
      'category': 'corazones',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f49a.png',
      'active': true,
      'order': 22,
    },

    // Categoría: Animales
    {
      'name': 'perro',
      'emoji': '🐶',
      'category': 'animales',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f436.png',
      'active': true,
      'order': 30,
    },
    {
      'name': 'gato',
      'emoji': '🐱',
      'category': 'animales',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f431.png',
      'active': true,
      'order': 31,
    },
    {
      'name': 'conejo',
      'emoji': '🐰',
      'category': 'animales',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f430.png',
      'active': true,
      'order': 32,
    },
    {
      'name': 'panda',
      'emoji': '🐼',
      'category': 'animales',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f43c.png',
      'active': true,
      'order': 33,
    },

    // Categoría: Comida
    {
      'name': 'pizza',
      'emoji': '🍕',
      'category': 'comida',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f355.png',
      'active': true,
      'order': 40,
    },
    {
      'name': 'hamburguesa',
      'emoji': '🍔',
      'category': 'comida',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f354.png',
      'active': true,
      'order': 41,
    },
    {
      'name': 'helado',
      'emoji': '🍦',
      'category': 'comida',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f366.png',
      'active': true,
      'order': 42,
    },
    {
      'name': 'dona',
      'emoji': '🍩',
      'category': 'comida',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f369.png',
      'active': true,
      'order': 43,
    },

    // Categoría: Objetos
    {
      'name': 'futbol',
      'emoji': '⚽',
      'category': 'objetos',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/26bd.png',
      'active': true,
      'order': 50,
    },
    {
      'name': 'videojuego',
      'emoji': '🎮',
      'category': 'objetos',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f3ae.png',
      'active': true,
      'order': 51,
    },
    {
      'name': 'musica',
      'emoji': '🎵',
      'category': 'objetos',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f3b5.png',
      'active': true,
      'order': 52,
    },
    {
      'name': 'camara',
      'emoji': '📷',
      'category': 'objetos',
      'storageUrl': 'https://em-content.zobj.net/thumbs/120/twitter/351/1f4f7.png',
      'active': true,
      'order': 53,
    },
  ];

  /// Sube los stickers de prueba a Firestore
  static Future<void> uploadTestStickers() async {
    try {
      debugPrint('🎨 Subiendo ${testStickers.length} stickers de prueba...');

      int successCount = 0;
      int errorCount = 0;

      for (final sticker in testStickers) {
        try {
          await _firestore.collection('stickers').add({
            ...sticker,
            'createdAt': FieldValue.serverTimestamp(),
          });
          debugPrint('  ✅ ${sticker['emoji']} ${sticker['name']}');
          successCount++;
        } catch (e) {
          debugPrint('  ❌ Error con ${sticker['name']}: $e');
          errorCount++;
        }
      }

      debugPrint('\n✅ Subida completada!');
      debugPrint('   Exitosos: $successCount');
      debugPrint('   Errores: $errorCount');
    } catch (e) {
      debugPrint('❌ Error general: $e');
      rethrow;
    }
  }

  /// Limpia todos los stickers de prueba
  static Future<void> clearAllStickers() async {
    try {
      debugPrint('🗑️ Eliminando todos los stickers...');

      final snapshot = await _firestore.collection('stickers').get();

      for (final doc in snapshot.docs) {
        await doc.reference.delete();
      }

      debugPrint('✅ ${snapshot.docs.length} stickers eliminados');
    } catch (e) {
      debugPrint('❌ Error: $e');
      rethrow;
    }
  }
}
