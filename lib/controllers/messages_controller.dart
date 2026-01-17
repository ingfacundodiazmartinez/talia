import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/chat_message.dart';
import '../services/chats/chat_services.dart';
import '../utils/release_logger.dart';

/// Controller unificado para mensajes de un chat
///
/// Coordina entre Screen y los servicios atómicos de mensajes.
/// Sigue el patrón: Screen → Controller → Service → Model
///
/// Responsabilidades:
/// - Cargar y paginar mensajes
/// - Enviar mensajes (texto, media)
/// - Editar/eliminar mensajes
/// - Gestionar reacciones
/// - Marcar como leídos
class MessagesController with ChangeNotifier {
  // === DEPENDENCIAS ===
  final String chatId;
  final bool isGroup;
  final FirebaseAuth _auth;
  final ListMessagesService _listService;
  final SendMessageService _sendService;
  final MarkMessagesReadService _markReadService;
  final EditMessageService _editService;
  final DeleteMessageService _deleteService;
  final AddReactionService _addReactionService;
  final RemoveReactionService _removeReactionService;

  // === ESTADO ===
  final List<ChatMessage> _messages = [];
  bool _isLoading = false;
  bool _isSending = false;
  bool _hasMore = true;
  String? _error;
  DocumentSnapshot? _lastDocument;

  // === STREAMS ===
  StreamSubscription? _messagesSubscription;
  final _messagesController = StreamController<List<ChatMessage>>.broadcast();

  // === GETTERS ===
  String? get currentUserId => _auth.currentUser?.uid;
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  Stream<List<ChatMessage>> get messagesStream => _messagesController.stream;
  bool get isLoading => _isLoading;
  bool get isSending => _isSending;
  bool get hasMore => _hasMore;
  String? get error => _error;

  MessagesController({
    required this.chatId,
    this.isGroup = false,
    FirebaseAuth? auth,
    ListMessagesService? listService,
    SendMessageService? sendService,
    MarkMessagesReadService? markReadService,
    EditMessageService? editService,
    DeleteMessageService? deleteService,
    AddReactionService? addReactionService,
    RemoveReactionService? removeReactionService,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _listService = listService ?? ListMessagesService(),
        _sendService = sendService ?? SendMessageService(),
        _markReadService = markReadService ?? MarkMessagesReadService(),
        _editService = editService ?? EditMessageService(),
        _deleteService = deleteService ?? DeleteMessageService(),
        _addReactionService = addReactionService ?? AddReactionService(),
        _removeReactionService = removeReactionService ?? RemoveReactionService();

  // === INICIALIZACIÓN ===

  /// Inicializar controller y comenzar a escuchar mensajes
  Future<void> initialize() async {
    _isLoading = true;
    notifyListeners();

    try {
      await _startListeningMessages();
      _error = null;
    } catch (e) {
      _error = 'Error inicializando mensajes: $e';
      ReleaseLogger.error(_error!, tag: 'MessagesController');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _startListeningMessages() async {
    _messagesSubscription?.cancel();

    // ListMessagesService.call() retorna Stream<List<ChatMessage>>
    _messagesSubscription = _listService
        .call(chatId: chatId, isGroup: isGroup)
        .listen(
          (messagesList) {
            _messages.clear();
            _messages.addAll(messagesList);
            _messagesController.add(_messages);
            _markAsReadIfNeeded();
          },
          onError: (e) {
            ReleaseLogger.error('Error en stream de mensajes: $e', tag: 'MessagesController');
            _error = 'Error cargando mensajes';
            notifyListeners();
          },
        );
  }

  /// Cargar más mensajes (paginación)
  Future<void> loadMore() async {
    if (_isLoading || !_hasMore) return;

    _isLoading = true;
    notifyListeners();

    try {
      final result = await _listService.getPage(
        chatId: chatId,
        isGroup: isGroup,
        startAfter: _lastDocument,
        limit: 30,
      );

      if (result.messages.isEmpty) {
        _hasMore = false;
      } else {
        _messages.addAll(result.messages);
        _lastDocument = result.lastDoc;
        _messagesController.add(_messages);
      }
    } catch (e) {
      ReleaseLogger.error('Error cargando más mensajes: $e', tag: 'MessagesController');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // === ENVIAR MENSAJES ===

  /// Enviar mensaje de texto
  Future<bool> sendTextMessage(String text, {Map<String, dynamic>? replyTo}) async {
    if (text.trim().isEmpty) return false;

    _isSending = true;
    notifyListeners();

    try {
      final result = await _sendService.call(
        chatId: chatId,
        text: text,
        isGroup: isGroup,
        replyTo: replyTo,
      );

      _error = result.success ? null : result.message;
      return result.success;
    } catch (e) {
      _error = 'Error enviando mensaje: $e';
      ReleaseLogger.error(_error!, tag: 'MessagesController');
      return false;
    } finally {
      _isSending = false;
      notifyListeners();
    }
  }

  // === EDITAR/ELIMINAR ===

  /// Editar mensaje
  Future<bool> editMessage({
    required String messageId,
    required String newText,
  }) async {
    try {
      final result = await _editService.call(
        chatId: chatId,
        messageId: messageId,
        newText: newText,
        isGroup: isGroup,
      );

      _error = result.success ? null : result.message;
      return result.success;
    } catch (e) {
      _error = 'Error editando mensaje: $e';
      ReleaseLogger.error(_error!, tag: 'MessagesController');
      return false;
    }
  }

  /// Verificar si puede editar un mensaje
  Future<bool> canEditMessage(String messageId) async {
    final result = await _editService.canEdit(
      chatId: chatId,
      messageId: messageId,
      isGroup: isGroup,
    );
    return result.canEdit;
  }

  /// Eliminar mensaje para mí
  Future<bool> deleteMessageForMe(String messageId) async {
    try {
      final result = await _deleteService.deleteForMe(
        chatId: chatId,
        messageId: messageId,
        isGroup: isGroup,
      );

      _error = result.success ? null : result.message;
      return result.success;
    } catch (e) {
      _error = 'Error eliminando mensaje: $e';
      ReleaseLogger.error(_error!, tag: 'MessagesController');
      return false;
    }
  }

  /// Eliminar mensaje para todos
  Future<bool> deleteMessageForEveryone(String messageId) async {
    try {
      final result = await _deleteService.deleteForEveryone(
        chatId: chatId,
        messageId: messageId,
        isGroup: isGroup,
      );

      _error = result.success ? null : result.message;
      return result.success;
    } catch (e) {
      _error = 'Error eliminando mensaje: $e';
      ReleaseLogger.error(_error!, tag: 'MessagesController');
      return false;
    }
  }

  /// Verificar si puede eliminar para todos
  Future<bool> canDeleteForEveryone(String messageId) async {
    final result = await _deleteService.canDeleteForEveryone(
      chatId: chatId,
      messageId: messageId,
      isGroup: isGroup,
    );
    return result.canDelete;
  }

  // === REACCIONES ===

  /// Toggle de reacción
  Future<bool> toggleReaction({
    required String messageId,
    required String emoji,
  }) async {
    try {
      final result = await _addReactionService.toggle(
        chatId: chatId,
        messageId: messageId,
        emoji: emoji,
        isGroup: isGroup,
      );

      return result.success;
    } catch (e) {
      ReleaseLogger.error('Error toggle reacción: $e', tag: 'MessagesController');
      return false;
    }
  }

  /// Agregar reacción
  Future<bool> addReaction({
    required String messageId,
    required String emoji,
  }) async {
    try {
      final result = await _addReactionService.call(
        chatId: chatId,
        messageId: messageId,
        emoji: emoji,
        isGroup: isGroup,
      );

      return result.success;
    } catch (e) {
      ReleaseLogger.error('Error agregando reacción: $e', tag: 'MessagesController');
      return false;
    }
  }

  /// Quitar reacción
  Future<bool> removeReaction({
    required String messageId,
    required String emoji,
  }) async {
    try {
      final result = await _removeReactionService.call(
        chatId: chatId,
        messageId: messageId,
        emoji: emoji,
        isGroup: isGroup,
      );

      return result.success;
    } catch (e) {
      ReleaseLogger.error('Error removiendo reacción: $e', tag: 'MessagesController');
      return false;
    }
  }

  // === MARCAR COMO LEÍDO ===

  Future<void> _markAsReadIfNeeded() async {
    final userId = currentUserId;
    if (userId == null) return;

    // Buscar mensajes no leídos de otros usuarios
    final unread = _messages.where((m) =>
        m.senderId != userId && !m.isRead).toList();

    if (unread.isEmpty) return;

    await _markReadService.call(
      chatId: chatId,
      isGroup: isGroup,
    );
  }

  /// Marcar todos los mensajes como leídos
  Future<void> markAllAsRead() async {
    await _markReadService.call(
      chatId: chatId,
      isGroup: isGroup,
    );
  }

  // === HELPERS ===

  /// Obtener mensaje por ID
  ChatMessage? getMessageById(String messageId) {
    try {
      return _messages.firstWhere((m) => m.id == messageId);
    } catch (_) {
      return null;
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  // === CLEANUP ===

  @override
  void dispose() {
    _messagesSubscription?.cancel();
    _messagesController.close();
    super.dispose();
  }
}
