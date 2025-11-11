import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:talia/firebase_options.dart';

/// Script para subir stickers de prueba a Firebase Storage
/// Uso: dart run scripts/upload_test_stickers.dart
///
/// Este script descarga emojis de Twemoji (MIT License) y los sube como stickers de prueba

void main() async {
  print('🎨 Iniciando subida de stickers de prueba...\n');

  // Inicializar Firebase
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  print('✅ Firebase inicializado\n');

  final storage = FirebaseStorage.instance;
  final firestore = FirebaseFirestore.instance;

  // Obtener directorio temporal
  final tempDir = await getTemporaryDirectory();
  final stickersDir = Directory('${tempDir.path}/test_stickers');
  if (!await stickersDir.exists()) {
    await stickersDir.create(recursive: true);
  }

  // Lista de emojis de Twemoji (versión 72x72 PNG desde CDN público)
  // URL base: https://em-content.zobj.net/thumbs/120/twitter/
  final testStickers = [
    // Categoría: Caras y Emociones
    {'emoji': '😊', 'name': 'cara_feliz', 'code': '1f60a', 'category': 'emociones'},
    {'emoji': '😂', 'name': 'risa', 'code': '1f602', 'category': 'emociones'},
    {'emoji': '🥰', 'name': 'amor', 'code': '1f970', 'category': 'emociones'},
    {'emoji': '😎', 'name': 'cool', 'code': '1f60e', 'category': 'emociones'},
    {'emoji': '🤔', 'name': 'pensando', 'code': '1f914', 'category': 'emociones'},
    {'emoji': '😴', 'name': 'dormido', 'code': '1f634', 'category': 'emociones'},
    {'emoji': '🤩', 'name': 'estrella', 'code': '1f929', 'category': 'emociones'},
    {'emoji': '😍', 'name': 'ojos_corazon', 'code': '1f60d', 'category': 'emociones'},

    // Categoría: Gestos
    {'emoji': '👍', 'name': 'pulgar_arriba', 'code': '1f44d', 'category': 'gestos'},
    {'emoji': '👎', 'name': 'pulgar_abajo', 'code': '1f44e', 'category': 'gestos'},
    {'emoji': '🙏', 'name': 'rezando', 'code': '1f64f', 'category': 'gestos'},
    {'emoji': '👏', 'name': 'aplausos', 'code': '1f44f', 'category': 'gestos'},
    {'emoji': '✌️', 'name': 'paz', 'code': '270c-fe0f', 'category': 'gestos'},
    {'emoji': '🤝', 'name': 'apretón', 'code': '1f91d', 'category': 'gestos'},

    // Categoría: Corazones
    {'emoji': '❤️', 'name': 'corazon_rojo', 'code': '2764-fe0f', 'category': 'corazones'},
    {'emoji': '💙', 'name': 'corazon_azul', 'code': '1f499', 'category': 'corazones'},
    {'emoji': '💚', 'name': 'corazon_verde', 'code': '1f49a', 'category': 'corazones'},
    {'emoji': '💛', 'name': 'corazon_amarillo', 'code': '1f49b', 'category': 'corazones'},
    {'emoji': '💜', 'name': 'corazon_morado', 'code': '1f49c', 'category': 'corazones'},
    {'emoji': '💕', 'name': 'dos_corazones', 'code': '1f495', 'category': 'corazones'},

    // Categoría: Animales
    {'emoji': '🐶', 'name': 'perro', 'code': '1f436', 'category': 'animales'},
    {'emoji': '🐱', 'name': 'gato', 'code': '1f431', 'category': 'animales'},
    {'emoji': '🐭', 'name': 'raton', 'code': '1f42d', 'category': 'animales'},
    {'emoji': '🐹', 'name': 'hamster', 'code': '1f439', 'category': 'animales'},
    {'emoji': '🐰', 'name': 'conejo', 'code': '1f430', 'category': 'animales'},
    {'emoji': '🦊', 'name': 'zorro', 'code': '1f98a', 'category': 'animales'},
    {'emoji': '🐻', 'name': 'oso', 'code': '1f43b', 'category': 'animales'},
    {'emoji': '🐼', 'name': 'panda', 'code': '1f43c', 'category': 'animales'},

    // Categoría: Comida
    {'emoji': '🍕', 'name': 'pizza', 'code': '1f355', 'category': 'comida'},
    {'emoji': '🍔', 'name': 'hamburguesa', 'code': '1f354', 'category': 'comida'},
    {'emoji': '🍟', 'name': 'papas', 'code': '1f35f', 'category': 'comida'},
    {'emoji': '🌮', 'name': 'taco', 'code': '1f32e', 'category': 'comida'},
    {'emoji': '🍩', 'name': 'dona', 'code': '1f369', 'category': 'comida'},
    {'emoji': '🍦', 'name': 'helado', 'code': '1f366', 'category': 'comida'},
    {'emoji': '🍰', 'name': 'pastel', 'code': '1f370', 'category': 'comida'},
    {'emoji': '🎂', 'name': 'torta', 'code': '1f382', 'category': 'comida'},

    // Categoría: Objetos
    {'emoji': '⚽', 'name': 'futbol', 'code': '26bd', 'category': 'objetos'},
    {'emoji': '🎮', 'name': 'videojuego', 'code': '1f3ae', 'category': 'objetos'},
    {'emoji': '🎵', 'name': 'musica', 'code': '1f3b5', 'category': 'objetos'},
    {'emoji': '📱', 'name': 'celular', 'code': '1f4f1', 'category': 'objetos'},
    {'emoji': '💻', 'name': 'laptop', 'code': '1f4bb', 'category': 'objetos'},
    {'emoji': '📷', 'name': 'camara', 'code': '1f4f7', 'category': 'objetos'},
    {'emoji': '🎨', 'name': 'arte', 'code': '1f3a8', 'category': 'objetos'},
    {'emoji': '⭐', 'name': 'estrella', 'code': '2b50', 'category': 'objetos'},
  ];

  print('📥 Descargando ${testStickers.length} stickers de prueba...\n');

  int successCount = 0;
  int errorCount = 0;

  for (var i = 0; i < testStickers.length; i++) {
    final sticker = testStickers[i];
    final emoji = sticker['emoji'] as String;
    final name = sticker['name'] as String;
    final code = sticker['code'] as String;
    final category = sticker['category'] as String;

    try {
      print('[$i/${testStickers.length}] ${sticker['emoji']} Procesando: $name...');

      // URL de Twemoji (CDN público de Twitter)
      final url = 'https://em-content.zobj.net/thumbs/120/twitter/351/$code.png';

      // Descargar imagen
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        // Guardar temporalmente
        final tempFile = File('${stickersDir.path}/$name.png');
        await tempFile.writeAsBytes(response.bodyBytes);

        // Subir a Firebase Storage
        final storageRef = storage.ref().child('stickers/$category/$name.png');
        await storageRef.putFile(tempFile);
        final downloadUrl = await storageRef.getDownloadURL();

        // Crear metadata en Firestore
        await firestore.collection('stickers').add({
          'name': name,
          'category': category,
          'storageUrl': downloadUrl,
          'emoji': emoji,
          'code': code,
          'createdAt': FieldValue.serverTimestamp(),
          'active': true,
          'order': i,
        });

        print('  ✅ Subido y registrado: $name');
        successCount++;

        // Limpiar archivo temporal
        await tempFile.delete();
      } else {
        print('  ❌ Error descargando: HTTP ${response.statusCode}');
        errorCount++;
      }
    } catch (e) {
      print('  ❌ Error: $e');
      errorCount++;
    }

    // Pequeña pausa para no saturar
    await Future.delayed(Duration(milliseconds: 500));
  }

  print('\n${'=' * 50}');
  print('✅ Proceso completado!');
  print('   Exitosos: $successCount');
  print('   Errores: $errorCount');
  print('=' * 50);
  print('\n🎨 Los stickers ya están disponibles en Firebase Storage');
  print('📱 Abre la app y prueba el editor de stories!\n');

  exit(0);
}
