import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../models/story.dart';
import '../../utils/release_logger.dart';

/// Registro local de una historia que falló al subir, persistido para poder
/// reintentarla aunque el usuario cierre la app.
class FailedStoryRecord {
  final String id; // tempStoryId
  final String userId;
  final String userName;
  final String? userPhotoURL;
  final String mediaType; // 'image' | 'video' | 'music'
  final String? localMediaPath; // archivo copiado a un dir persistente (foto/video)
  final String? caption;
  final bool aiGenerated;
  final String? musicUrl;
  final String? musicPrompt;
  final String? musicLyrics;
  final int? musicStartMs;
  final int? musicClipMs;
  final String? musicTitle;
  final String? musicDisplayMode;
  final List<Map<String, dynamic>> musicLyricsTimings;
  final int createdAtMs;
  final String? error;

  FailedStoryRecord({
    required this.id,
    required this.userId,
    required this.userName,
    this.userPhotoURL,
    required this.mediaType,
    this.localMediaPath,
    this.caption,
    this.aiGenerated = false,
    this.musicUrl,
    this.musicPrompt,
    this.musicLyrics,
    this.musicStartMs,
    this.musicClipMs,
    this.musicTitle,
    this.musicDisplayMode,
    this.musicLyricsTimings = const [],
    required this.createdAtMs,
    this.error,
  });

  bool get isMusicOnly => mediaType == 'music';

  Map<String, dynamic> toJson() => {
        'id': id,
        'userId': userId,
        'userName': userName,
        'userPhotoURL': userPhotoURL,
        'mediaType': mediaType,
        'localMediaPath': localMediaPath,
        'caption': caption,
        'aiGenerated': aiGenerated,
        'musicUrl': musicUrl,
        'musicPrompt': musicPrompt,
        'musicLyrics': musicLyrics,
        'musicStartMs': musicStartMs,
        'musicClipMs': musicClipMs,
        'musicTitle': musicTitle,
        'musicDisplayMode': musicDisplayMode,
        'musicLyricsTimings': musicLyricsTimings,
        'createdAtMs': createdAtMs,
        'error': error,
      };

  factory FailedStoryRecord.fromJson(Map<String, dynamic> j) => FailedStoryRecord(
        id: j['id'] as String,
        userId: j['userId'] as String,
        userName: (j['userName'] ?? 'Usuario') as String,
        userPhotoURL: j['userPhotoURL'] as String?,
        mediaType: (j['mediaType'] ?? 'image') as String,
        localMediaPath: j['localMediaPath'] as String?,
        caption: j['caption'] as String?,
        aiGenerated: j['aiGenerated'] == true,
        musicUrl: j['musicUrl'] as String?,
        musicPrompt: j['musicPrompt'] as String?,
        musicLyrics: j['musicLyrics'] as String?,
        musicStartMs: (j['musicStartMs'] as num?)?.toInt(),
        musicClipMs: (j['musicClipMs'] as num?)?.toInt(),
        musicTitle: j['musicTitle'] as String?,
        musicDisplayMode: j['musicDisplayMode'] as String?,
        musicLyricsTimings: (j['musicLyricsTimings'] as List?)
                ?.whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList() ??
            const [],
        createdAtMs: (j['createdAtMs'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
        error: j['error'] as String?,
      );

  /// Construye un [Story] (status failed) para mostrarlo en el cache/UI.
  Story toStory() {
    final created = DateTime.fromMillisecondsSinceEpoch(createdAtMs);
    return Story(
      id: id,
      userId: userId,
      userName: userName,
      userPhotoURL: userPhotoURL,
      mediaUrl: '',
      mediaType: mediaType,
      caption: caption,
      createdAt: created,
      expiresAt: created.add(const Duration(hours: 24)),
      viewedBy: const [],
      replies: const [],
      status: StoryStatus.failed,
      localMediaPath: localMediaPath,
      uploadError: error,
      aiGenerated: aiGenerated,
      musicUrl: musicUrl,
      musicPrompt: musicPrompt,
      musicLyrics: musicLyrics,
      musicStartMs: musicStartMs,
      musicClipMs: musicClipMs,
      musicTitle: musicTitle,
      musicDisplayMode: musicDisplayMode,
      musicLyricsTimings:
          musicLyricsTimings.map((m) => LyricLine.fromMap(m)).toList(),
    );
  }
}

/// Almacén persistente de historias que fallaron al subir.
///
/// Guarda los metadatos en SharedPreferences y, para fotos/videos, copia el
/// archivo a un directorio propio de la app (los temporales de la cámara se
/// borran). Así la historia fallida sobrevive al cierre de la app y puede
/// reintentarse.
class FailedStoryStore {
  static final FailedStoryStore _instance = FailedStoryStore._internal();
  factory FailedStoryStore() => _instance;
  FailedStoryStore._internal();

  static const String _prefsKey = 'failed_stories_v1';
  static const String _subDir = 'failed_stories';
  final _uuid = const Uuid();

  Future<Directory> _mediaDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$_subDir');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Copia el media a un directorio persistente y devuelve el nuevo path.
  /// Si el archivo no existe (ya se borró), devuelve null.
  Future<String?> _persistMedia(String sourcePath) async {
    try {
      final src = File(sourcePath);
      if (!await src.exists()) return null;
      final dir = await _mediaDir();
      final dotIdx = sourcePath.lastIndexOf('.');
      final ext = (dotIdx != -1 && dotIdx > sourcePath.lastIndexOf('/'))
          ? sourcePath.substring(dotIdx)
          : '';
      final dest = '${dir.path}/${_uuid.v4()}$ext';
      await src.copy(dest);
      return dest;
    } catch (e) {
      ReleaseLogger.warning('No se pudo persistir media fallida: $e',
          tag: 'FailedStoryStore');
      return null;
    }
  }

  Future<List<FailedStoryRecord>> getAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefsKey) ?? const [];
      return raw
          .map((s) {
            try {
              return FailedStoryRecord.fromJson(
                  jsonDecode(s) as Map<String, dynamic>);
            } catch (_) {
              return null;
            }
          })
          .whereType<FailedStoryRecord>()
          .toList();
    } catch (e) {
      ReleaseLogger.warning('Error leyendo failed stories: $e',
          tag: 'FailedStoryStore');
      return [];
    }
  }

  Future<List<FailedStoryRecord>> getForUser(String userId) async {
    final all = await getAll();
    return all.where((r) => r.userId == userId).toList();
  }

  Future<void> _writeAll(List<FailedStoryRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _prefsKey,
      records.map((r) => jsonEncode(r.toJson())).toList(),
    );
  }

  /// Guarda (o reemplaza) un registro fallido. Para foto/video copia el media
  /// a un directorio persistente; [sourceMediaPath] es el path original.
  Future<FailedStoryRecord> save({
    required String id,
    required String userId,
    required String userName,
    String? userPhotoURL,
    required String mediaType,
    String? sourceMediaPath,
    String? caption,
    bool aiGenerated = false,
    String? musicUrl,
    String? musicPrompt,
    String? musicLyrics,
    int? musicStartMs,
    int? musicClipMs,
    String? musicTitle,
    String? musicDisplayMode,
    List<Map<String, dynamic>> musicLyricsTimings = const [],
    required int createdAtMs,
    String? error,
  }) async {
    String? persistedPath;
    if (mediaType != 'music' && sourceMediaPath != null) {
      persistedPath = await _persistMedia(sourceMediaPath);
    }

    final record = FailedStoryRecord(
      id: id,
      userId: userId,
      userName: userName,
      userPhotoURL: userPhotoURL,
      mediaType: mediaType,
      localMediaPath: persistedPath,
      caption: caption,
      aiGenerated: aiGenerated,
      musicUrl: musicUrl,
      musicPrompt: musicPrompt,
      musicLyrics: musicLyrics,
      musicStartMs: musicStartMs,
      musicClipMs: musicClipMs,
      musicTitle: musicTitle,
      musicDisplayMode: musicDisplayMode,
      musicLyricsTimings: musicLyricsTimings,
      createdAtMs: createdAtMs,
      error: error,
    );

    final all = await getAll();
    all.removeWhere((r) => r.id == id);
    all.add(record);
    await _writeAll(all);
    ReleaseLogger.log('Historia fallida guardada localmente: $id',
        tag: 'FailedStoryStore');
    return record;
  }

  /// Elimina un registro fallido y su media copiada.
  Future<void> remove(String id) async {
    final all = await getAll();
    final matches = all.where((r) => r.id == id).toList();
    final record = matches.isNotEmpty ? matches.first : null;
    if (record?.localMediaPath != null) {
      try {
        final f = File(record!.localMediaPath!);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    all.removeWhere((r) => r.id == id);
    await _writeAll(all);
  }
}
