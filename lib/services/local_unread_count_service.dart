import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Servicio para gestionar contadores de mensajes no leídos localmente
///
/// Usa SharedPreferences para persistencia local en vez de Firestore.
/// Esto es más eficiente porque:
/// - Es un dato específico del usuario/dispositivo
/// - No necesita sincronización con el servidor
/// - Reduce lecturas/escrituras a Firestore
class LocalUnreadCountService extends ChangeNotifier {
  static const String _prefsKey = 'local_unread_counts';
  static const String _currentChatKey = 'current_chat_id';

  static LocalUnreadCountService? _instance;

  SharedPreferences? _prefs;
  Map<String, int> _unreadCounts = {};
  String? _currentChatId;
  bool _initialized = false;

  /// Singleton factory
  factory LocalUnreadCountService() {
    _instance ??= LocalUnreadCountService._internal();
    return _instance!;
  }

  LocalUnreadCountService._internal();

  /// Inicializar servicio (llamar al inicio de la app)
  Future<void> initialize() async {
    if (_initialized) return;

    _prefs = await SharedPreferences.getInstance();
    await _loadFromPrefs();
    _initialized = true;
  }

  /// Cargar datos desde SharedPreferences
  Future<void> _loadFromPrefs() async {
    try {
      final jsonString = _prefs?.getString(_prefsKey);
      if (jsonString != null) {
        final Map<String, dynamic> decoded = json.decode(jsonString);
        _unreadCounts = decoded.map((key, value) => MapEntry(key, value as int));
      }
      _currentChatId = _prefs?.getString(_currentChatKey);
    } catch (e) {
      _unreadCounts = {};
    }
  }

  /// Guardar datos en SharedPreferences
  Future<void> _saveToPrefs() async {
    try {
      final jsonString = json.encode(_unreadCounts);
      await _prefs?.setString(_prefsKey, jsonString);
    } catch (e) {
      // Silently handle error
    }
  }

  /// Obtener contador de un chat específico
  int getUnreadCount(String chatId) {
    return _unreadCounts[chatId] ?? 0;
  }

  /// Obtener total de mensajes no leídos
  int getTotalUnreadCount() {
    return _unreadCounts.values.fold(0, (sum, count) => sum + count);
  }

  /// Obtener mapa completo de contadores (para UI reactiva)
  Map<String, int> get allUnreadCounts => Map.unmodifiable(_unreadCounts);

  /// Verificar si el usuario está actualmente en un chat específico
  bool isUserInChat(String chatId) {
    return _currentChatId == chatId;
  }

  /// Obtener el chatId actual (donde está el usuario)
  String? get currentChatId => _currentChatId;

  /// Marcar que el usuario entró a un chat (resetear contador y guardar estado)
  Future<void> enterChat(String chatId) async {
    _currentChatId = chatId;
    await _prefs?.setString(_currentChatKey, chatId);

    // Resetear contador de este chat
    if (_unreadCounts.containsKey(chatId) && _unreadCounts[chatId]! > 0) {
      _unreadCounts[chatId] = 0;
      await _saveToPrefs();
      notifyListeners();
    }
  }

  /// Marcar que el usuario salió del chat
  Future<void> exitChat() async {
    _currentChatId = null;
    await _prefs?.remove(_currentChatKey);
  }

  /// Incrementar contador de un chat (solo si el usuario NO está en ese chat)
  /// Retorna true si se incrementó, false si no (porque el usuario está en el chat)
  Future<bool> incrementUnreadCount(String chatId, {int amount = 1}) async {
    // No incrementar si el usuario está viendo este chat
    if (_currentChatId == chatId) {
      return false;
    }

    _unreadCounts[chatId] = (_unreadCounts[chatId] ?? 0) + amount;
    await _saveToPrefs();
    notifyListeners();
    return true;
  }

  /// Resetear contador de un chat específico
  Future<void> resetUnreadCount(String chatId) async {
    if (_unreadCounts.containsKey(chatId)) {
      _unreadCounts[chatId] = 0;
      await _saveToPrefs();
      notifyListeners();
    }
  }

  /// Resetear todos los contadores
  Future<void> resetAllUnreadCounts() async {
    _unreadCounts.clear();
    await _saveToPrefs();
    notifyListeners();
  }

  /// Eliminar contador de un chat (cuando se elimina el chat)
  Future<void> removeChat(String chatId) async {
    _unreadCounts.remove(chatId);
    await _saveToPrefs();
    notifyListeners();
  }

  /// Stream de cambios para UI reactiva
  /// Retorna un Stream que emite cada vez que hay cambios en los contadores
  Stream<Map<String, int>> watchUnreadCounts() {
    // Crear un StreamController que emite cuando notifyListeners() es llamado
    final controller = StreamController<Map<String, int>>.broadcast();

    // Emitir valor inicial
    controller.add(Map.unmodifiable(_unreadCounts));

    // Escuchar cambios
    void listener() {
      if (!controller.isClosed) {
        controller.add(Map.unmodifiable(_unreadCounts));
      }
    }

    addListener(listener);

    // Cleanup cuando el stream se cierra
    controller.onCancel = () {
      removeListener(listener);
    };

    return controller.stream;
  }

  /// Stream del contador de un chat específico
  Stream<int> watchChatUnreadCount(String chatId) {
    return watchUnreadCounts().map((counts) => counts[chatId] ?? 0);
  }

  /// Stream del total de no leídos
  Stream<int> watchTotalUnreadCount() {
    return watchUnreadCounts().map((counts) =>
      counts.values.fold(0, (sum, count) => sum + count)
    );
  }
}
