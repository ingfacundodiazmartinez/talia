import 'dart:io';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Servicio para gestionar stickers descargables desde Firebase Storage
///
/// Estructura en Firebase Storage:
/// /stickers/
///   /cuppy/
///     01_smile.webp
///     02_laugh.webp
///   /emojis/
///     heart.png
///     star.png
///
/// Estructura en Firestore (para metadata):
/// /stickers/{stickerId}
///   name: string
///   category: string ('cuppy', 'emojis', etc.)
///   storageUrl: string
///   thumbnailUrl: string (optional)
///   createdAt: timestamp
///   active: boolean
///   order: number
class StickersService {
  static final StickersService _instance = StickersService._internal();
  factory StickersService() => _instance;
  StickersService._internal();

  final FirebaseStorage _storage = FirebaseStorage.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Directory? _cacheDirectory;
  bool _isInitialized = false;

  /// Inicializa el directorio de caché
  Future<void> initialize() async {
    if (_isInitialized) return;

    final appDir = await getApplicationDocumentsDirectory();
    _cacheDirectory = Directory('${appDir.path}/stickers_cache');

    if (!await _cacheDirectory!.exists()) {
      await _cacheDirectory!.create(recursive: true);
    }

    _isInitialized = true;
    debugPrint('✅ StickersService inicializado: ${_cacheDirectory!.path}');
  }

  /// Obtiene la lista de stickers activos desde Firestore
  Future<List<StickerMetadata>> getAvailableStickers({String? category}) async {
    try {
      await initialize();

      Query query = _firestore
          .collection('stickers')
          .where('active', isEqualTo: true)
          .orderBy('order');

      if (category != null) {
        query = query.where('category', isEqualTo: category);
      }

      final snapshot = await query.get();

      return snapshot.docs
          .map((doc) => StickerMetadata.fromFirestore(doc))
          .toList();
    } catch (e) {
      debugPrint('❌ Error obteniendo stickers: $e');
      return [];
    }
  }

  /// Descarga un sticker y lo guarda en caché
  /// Este método es seguro para usar en FutureBuilder - no lanza excepciones
  Future<File?> downloadSticker(StickerMetadata metadata) async {
    try {
      await initialize();

      // Verificar si ya existe en caché
      final cachedFile = await getCachedSticker(metadata.id);
      if (cachedFile != null && await cachedFile.exists()) {
        debugPrint('✅ Sticker encontrado en caché: ${metadata.name}');
        return cachedFile;
      }

      debugPrint('⬇️ Descargando sticker: ${metadata.name} desde ${metadata.storageUrl}');

      final file = File('${_cacheDirectory!.path}/${metadata.id}.${_getFileExtension(metadata.storageUrl)}');

      // Detectar si es una URL HTTP (Firebase Storage pública) o Firebase Storage gs://
      if (metadata.storageUrl.startsWith('http://') || metadata.storageUrl.startsWith('https://')) {
        // Descargar desde URL HTTP pública (Firebase Storage)
        final response = await http.get(Uri.parse(metadata.storageUrl));

        if (response.statusCode == 200) {
          await file.writeAsBytes(response.bodyBytes);
          debugPrint('✅ Sticker descargado desde HTTP: ${metadata.name}');
        } else {
          debugPrint('❌ Error HTTP ${response.statusCode} descargando ${metadata.name}');
          return null;
        }
      } else {
        // Descargar desde Firebase Storage
        final ref = _storage.refFromURL(metadata.storageUrl);
        await ref.writeToFile(file);
        debugPrint('✅ Sticker descargado desde Firebase Storage: ${metadata.name}');
      }

      return file;
    } catch (e) {
      debugPrint('❌ Error descargando sticker ${metadata.name}: $e');
      return null;
    }
  }

  /// Descarga un sticker de forma lazy (solo si no está en caché)
  /// Útil para cargar stickers on-demand con FutureBuilder
  Future<File?> downloadStickerLazy(StickerMetadata metadata) async {
    return await downloadSticker(metadata);
  }

  /// Obtiene un sticker de caché si existe
  Future<File?> getCachedSticker(String stickerId) async {
    await initialize();

    // Buscar archivo con cualquier extensión común
    final extensions = ['webp', 'png', 'jpg', 'jpeg', 'gif'];

    for (final ext in extensions) {
      final file = File('${_cacheDirectory!.path}/$stickerId.$ext');
      if (await file.exists()) {
        return file;
      }
    }

    return null;
  }

  /// Descarga múltiples stickers en batch
  Future<Map<String, File>> downloadMultipleStickers(List<StickerMetadata> stickers) async {
    final Map<String, File> downloadedStickers = {};

    for (final sticker in stickers) {
      final file = await downloadSticker(sticker);
      if (file != null) {
        downloadedStickers[sticker.id] = file;
      }
    }

    return downloadedStickers;
  }

  /// Pre-carga todos los stickers activos
  Future<void> preloadStickers() async {
    debugPrint('🔄 Pre-cargando stickers...');

    final stickers = await getAvailableStickers();
    await downloadMultipleStickers(stickers);

    debugPrint('✅ Pre-carga de stickers completada: ${stickers.length} stickers');
  }

  /// Limpia el caché de stickers
  Future<void> clearCache() async {
    await initialize();

    if (await _cacheDirectory!.exists()) {
      await _cacheDirectory!.delete(recursive: true);
      await _cacheDirectory!.create(recursive: true);
      debugPrint('✅ Caché de stickers limpiado');
    }
  }

  /// Obtiene el tamaño del caché en bytes
  Future<int> getCacheSize() async {
    await initialize();

    int totalSize = 0;

    if (await _cacheDirectory!.exists()) {
      final files = _cacheDirectory!.listSync(recursive: true);
      for (final file in files) {
        if (file is File) {
          totalSize += await file.length();
        }
      }
    }

    return totalSize;
  }

  /// Sube un sticker a Firebase Storage (para uso en backoffice)
  Future<String?> uploadSticker({
    required File file,
    required String category,
    required String name,
  }) async {
    try {
      final fileName = '${DateTime.now().millisecondsSinceEpoch}_${name}';
      final ref = _storage.ref().child('stickers/$category/$fileName');

      debugPrint('⬆️ Subiendo sticker: $fileName');

      await ref.putFile(file);
      final downloadUrl = await ref.getDownloadURL();

      debugPrint('✅ Sticker subido: $downloadUrl');
      return downloadUrl;
    } catch (e) {
      debugPrint('❌ Error subiendo sticker: $e');
      return null;
    }
  }

  /// Crea metadata de sticker en Firestore (para uso en backoffice)
  Future<String?> createStickerMetadata({
    required String name,
    required String category,
    required String storageUrl,
    String? thumbnailUrl,
    int order = 0,
    bool active = true,
  }) async {
    try {
      final docRef = await _firestore.collection('stickers').add({
        'name': name,
        'category': category,
        'storageUrl': storageUrl,
        'thumbnailUrl': thumbnailUrl,
        'createdAt': FieldValue.serverTimestamp(),
        'active': active,
        'order': order,
      });

      debugPrint('✅ Metadata de sticker creada: ${docRef.id}');
      return docRef.id;
    } catch (e) {
      debugPrint('❌ Error creando metadata de sticker: $e');
      return null;
    }
  }

  /// Actualiza el estado activo de un sticker
  Future<bool> updateStickerActiveStatus(String stickerId, bool active) async {
    try {
      await _firestore.collection('stickers').doc(stickerId).update({
        'active': active,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      debugPrint('✅ Estado de sticker actualizado: $stickerId -> $active');
      return true;
    } catch (e) {
      debugPrint('❌ Error actualizando estado de sticker: $e');
      return false;
    }
  }

  /// Elimina un sticker (soft delete)
  Future<bool> deleteSticker(String stickerId) async {
    return await updateStickerActiveStatus(stickerId, false);
  }

  /// Obtiene la extensión del archivo desde la URL
  String _getFileExtension(String url) {
    final uri = Uri.parse(url);
    final path = uri.path;
    final lastDot = path.lastIndexOf('.');

    if (lastDot != -1 && lastDot < path.length - 1) {
      return path.substring(lastDot + 1).split('?').first;
    }

    return 'webp'; // Default
  }
}

/// Metadata de un sticker
class StickerMetadata {
  final String id;
  final String name;
  final String category;
  final String storageUrl;
  final String? thumbnailUrl;
  final DateTime? createdAt;
  final bool active;
  final int order;

  StickerMetadata({
    required this.id,
    required this.name,
    required this.category,
    required this.storageUrl,
    this.thumbnailUrl,
    this.createdAt,
    required this.active,
    required this.order,
  });

  factory StickerMetadata.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    return StickerMetadata(
      id: doc.id,
      name: data['name'] ?? '',
      category: data['category'] ?? 'default',
      storageUrl: data['storageUrl'] ?? '',
      thumbnailUrl: data['thumbnailUrl'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      active: data['active'] ?? true,
      order: data['order'] ?? 0,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'category': category,
      'storageUrl': storageUrl,
      'thumbnailUrl': thumbnailUrl,
      'createdAt': createdAt,
      'active': active,
      'order': order,
    };
  }
}
