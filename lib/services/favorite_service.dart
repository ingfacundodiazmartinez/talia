import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';

/// Servicio para gestionar mensajes favoritos.
///
/// Los favoritos son una preferencia personal del usuario, no compartida con
/// el otro participante del chat ni con padres. Por eso se guardan en Hive
/// local y NO en Firestore: cero red, cero permisos, cero costo.
///
/// Tradeoff: no se sincronizan entre dispositivos. Si se necesita sync
/// multi-device en el futuro, se puede agregar un mirror a Firestore con
/// `users/{uid}/favorites` sin cambiar esta API.
class FavoriteService {
  static const String _boxName = 'favorites_v1';

  // Singleton — un solo box para toda la app.
  static final FavoriteService _instance = FavoriteService._internal();
  factory FavoriteService() => _instance;
  FavoriteService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  Box? _box;
  bool _initialized = false;

  // Streams broadcasted on toggle. Key = "${uid}__${chatId}".
  final Map<String, StreamController<Set<String>>> _streams = {};

  Future<void> _ensureInit() async {
    if (_initialized) return;
    try {
      // Hive.initFlutter() ya se llama desde MessageCacheService al boot.
      // Pero ser defensivos: si openBox falla por "no init", lo intentamos.
      _box = await Hive.openBox(_boxName);
    } on HiveError {
      await Hive.initFlutter();
      _box = await Hive.openBox(_boxName);
    }
    _initialized = true;
  }

  String _key(String uid, String chatId, String messageId) =>
      '${uid}__${chatId}__$messageId';

  String _streamKey(String uid, String chatId) => '${uid}__$chatId';

  String? _currentUid() => _auth.currentUser?.uid;

  /// Marca o desmarca un mensaje como favorito.
  ///
  /// [messageSnapshot] guarda los datos necesarios para mostrar el mensaje en
  /// el tab Favoritos del perfil sin tener que ir a Firestore. Idealmente
  /// incluye: text, type, senderId, timestamp (int ms), imageUrl, videoUrl,
  /// audioUrl. Si no se pasa, el tab Favoritos sólo verá el messageId.
  Future<void> toggleFavorite({
    required String chatId,
    required String messageId,
    required bool isGroupChat,
    Map<String, dynamic>? messageSnapshot,
  }) async {
    await _ensureInit();
    final uid = _currentUid();
    if (uid == null) {
      throw Exception('Usuario no autenticado');
    }

    final key = _key(uid, chatId, messageId);
    if (_box!.containsKey(key)) {
      await _box!.delete(key);
    } else {
      await _box!.put(key, {
        'chatId': chatId,
        'messageId': messageId,
        'isGroupChat': isGroupChat,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        if (messageSnapshot != null) ...messageSnapshot,
      });
    }
    await _emitForChat(uid, chatId);
  }

  /// Verifica si un mensaje está marcado como favorito.
  Future<bool> isFavorite({
    required String chatId,
    required String messageId,
    required bool isGroupChat,
  }) async {
    await _ensureInit();
    final uid = _currentUid();
    if (uid == null) return false;
    return _box!.containsKey(_key(uid, chatId, messageId));
  }

  /// Set de messageIds favoritos para un chat (lectura única).
  Future<Set<String>> getFavoriteMessageIds({
    required String chatId,
    required bool isGroupChat,
  }) async {
    await _ensureInit();
    final uid = _currentUid();
    if (uid == null) return <String>{};
    final prefix = '${uid}__${chatId}__';
    final ids = <String>{};
    for (final raw in _box!.keys) {
      final k = raw.toString();
      if (k.startsWith(prefix)) {
        ids.add(k.substring(prefix.length));
      }
    }
    return ids;
  }

  /// Stream de messageIds favoritos. Emite el set actual y luego cualquier
  /// cambio (toggle del mismo chat).
  Stream<Set<String>> getFavoriteMessageIdsStream({
    required String chatId,
    required bool isGroupChat,
  }) async* {
    await _ensureInit();
    final uid = _currentUid();
    if (uid == null) {
      yield <String>{};
      return;
    }
    final ctrlKey = _streamKey(uid, chatId);
    final ctrl =
        _streams.putIfAbsent(ctrlKey, () => StreamController.broadcast());

    // Emit el estado actual.
    yield await getFavoriteMessageIds(chatId: chatId, isGroupChat: isGroupChat);
    // Luego, todos los cambios futuros.
    yield* ctrl.stream;
  }

  /// Mensajes favoritos completos para mostrar en el tab Favoritos del perfil.
  /// Devuelve la lista con `id`, `text`, `formattedTime`, etc., armada desde
  /// el snapshot guardado en Hive al momento de marcar como favorito.
  Future<List<Map<String, dynamic>>> getFavoriteMessagesForProfile({
    required String chatId,
    bool isGroupChat = false,
  }) async {
    await _ensureInit();
    final uid = _currentUid();
    if (uid == null) return [];
    final prefix = '${uid}__${chatId}__';
    final result = <Map<String, dynamic>>[];
    for (final raw in _box!.keys) {
      final k = raw.toString();
      if (!k.startsWith(prefix)) continue;
      final value = _box!.get(k);
      if (value is! Map) continue;
      final data = <String, dynamic>{};
      value.forEach((mk, mv) {
        data[mk.toString()] = mv;
      });
      data['id'] = data['messageId'] ?? k.substring(prefix.length);
      final ts = data['timestamp'] ?? data['savedAt'];
      if (ts is int) {
        data['formattedTime'] = DateFormat('dd/MM/yyyy HH:mm')
            .format(DateTime.fromMillisecondsSinceEpoch(ts));
      }
      // 🔒 Derivar mediaType/mediaUrl que el render del perfil espera.
      // El snapshot guarda imageUrl/videoUrl/audioUrl por separado, pero el
      // widget de favoritos lee solo mediaType+mediaUrl. Sin esto, los
      // mensajes de imagen/video/audio aparecen vacíos en el tab Favoritos.
      final imgUrl = data['imageUrl'] as String?;
      final vidUrl = data['videoUrl'] as String?;
      final audUrl = data['audioUrl'] as String?;
      if (imgUrl != null && imgUrl.isNotEmpty) {
        data['mediaType'] = 'image';
        data['mediaUrl'] = imgUrl;
      } else if (vidUrl != null && vidUrl.isNotEmpty) {
        data['mediaType'] = 'video';
        data['mediaUrl'] = vidUrl;
      } else if (audUrl != null && audUrl.isNotEmpty) {
        data['mediaType'] = 'audio';
        data['mediaUrl'] = audUrl;
      }
      result.add(data);
    }
    result.sort((a, b) {
      final aMs = (a['savedAt'] as int?) ?? 0;
      final bMs = (b['savedAt'] as int?) ?? 0;
      return bMs.compareTo(aMs);
    });
    return result;
  }

  Future<void> _emitForChat(String uid, String chatId) async {
    final ctrl = _streams[_streamKey(uid, chatId)];
    if (ctrl == null || ctrl.isClosed) return;
    final ids =
        await getFavoriteMessageIds(chatId: chatId, isGroupChat: false);
    ctrl.add(ids);
  }
}
