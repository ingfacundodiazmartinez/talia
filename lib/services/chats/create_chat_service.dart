import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../utils/release_logger.dart';
import '../../utils/chat_utils.dart';

/// Servicio atómico: Crear chat individual
///
/// Responsabilidad única: Crear un nuevo chat 1-a-1 entre dos usuarios
///
/// Nota: Este servicio NO crea grupos. Para grupos usar CreateGroupService.
class CreateChatService {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  CreateChatService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  /// Crear o obtener chat existente entre dos usuarios
  ///
  /// Si ya existe un chat entre los usuarios, retorna el existente.
  /// Si no existe, crea uno nuevo.
  ///
  /// [otherUserId] - ID del otro usuario
  ///
  /// Retorna (success, chatId, message, isNew)
  Future<({bool success, String? chatId, String message, bool isNew})> call({
    required String otherUserId,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        return (
          success: false,
          chatId: null,
          message: 'Usuario no autenticado',
          isNew: false,
        );
      }

      // No puede chatear consigo mismo
      if (currentUserId == otherUserId) {
        return (
          success: false,
          chatId: null,
          message: 'No puedes crear un chat contigo mismo',
          isNew: false,
        );
      }

      // Lookup determinístico: la CF y todo el sistema usan
      // `{userA}_{userB}` ordenado alfabéticamente como chatId. Un solo
      // get() doc es mucho más rápido que un query a la collection.
      final deterministicId = ChatUtils.getChatId(currentUserId, otherUserId);
      final doc = await _firestore.collection('chats').doc(deterministicId).get();
      if (doc.exists) {
        ReleaseLogger.log(
          'Chat existente encontrado: $deterministicId',
          tag: 'CreateChat',
        );
        return (
          success: true,
          chatId: deterministicId,
          message: 'Chat existente',
          isNew: false,
        );
      }

      // No existe: llamar CF (las rules prohíben write directo a chats/).
      // La CF valida contacto aprobado, bloqueos bidireccionales,
      // restricciones parentales y rate limit (10/h).
      final chatId = await _createNewChat(currentUserId, otherUserId);

      ReleaseLogger.log('Chat creado: $chatId', tag: 'CreateChat');

      return (
        success: true,
        chatId: chatId,
        message: 'Chat creado exitosamente',
        isNew: true,
      );
    } catch (e) {
      ReleaseLogger.error('Error creando chat: $e', tag: 'CreateChat');
      return (
        success: false,
        chatId: null,
        message: 'Error al crear chat: $e',
        isNew: false,
      );
    }
  }

  /// Crear nuevo chat individual.
  ///
  /// Llama a la Cloud Function `createChat` porque los Firestore rules
  /// prohíben escritura directa a `chats/{chatId}` desde clientes (la CF
  /// valida contactos aprobados, bloqueos, restricciones parentales y
  /// rate limit).
  Future<String> _createNewChat(
    String currentUserId,
    String otherUserId,
  ) async {
    final functions = FirebaseFunctions.instanceFor(region: 'us-central1');
    final result = await functions.httpsCallable('createChat').call({
      'otherUserId': otherUserId,
    });
    final data = result.data;
    if (data is Map) {
      final chatId = data['chatId'];
      if (chatId is String && chatId.isNotEmpty) {
        return chatId;
      }
    }
    throw Exception('CF createChat retornó respuesta inválida: $data');
  }

  /// Obtener ID de chat entre dos usuarios (sin crear)
  ///
  /// Útil para verificar si existe o para navigation
  String getChatIdBetweenUsers(String otherUserId) {
    final currentUserId = _auth.currentUser?.uid ?? '';
    return ChatUtils.getChatId(currentUserId, otherUserId);
  }

  /// Verificar si existe chat entre dos usuarios
  Future<bool> existsBetweenUsers(String otherUserId) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) return false;
    final chatId = ChatUtils.getChatId(currentUserId, otherUserId);
    final doc = await _firestore.collection('chats').doc(chatId).get();
    return doc.exists;
  }
}
