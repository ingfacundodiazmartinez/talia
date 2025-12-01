import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../utils/release_logger.dart';
import '../screens/chat_detail_screen.dart';

/// Servicio para crear chats de forma segura usando Cloud Functions
///
/// IMPORTANTE: Los chats DEBEN crearse mediante Cloud Function para validar:
/// - Contactos aprobados
/// - Bloqueos bidireccionales
/// - Restricciones parentales
/// - Rate limiting
///
/// OPTIMIZACIÓN: Verifica si el chat existe localmente antes de llamar a CF
class CreateChatService {
  final FirebaseFunctions _functions;
  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;

  CreateChatService({
    FirebaseFunctions? functions,
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
  })  : _functions = functions ?? FirebaseFunctions.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  /// Genera el chatId a partir de dos userIds (ordenados alfabéticamente)
  String _generateChatId(String userId1, String userId2) {
    final sortedIds = [userId1, userId2]..sort();
    return '${sortedIds[0]}_${sortedIds[1]}';
  }

  /// Crear o obtener chat con un contacto
  ///
  /// OPTIMIZADO: Primero verifica si el chat existe localmente.
  /// Solo llama a Cloud Function si el chat no existe.
  ///
  /// Returns: chatId si se creó o ya existía
  /// Throws: Exception si no se puede crear (no son contactos, bloqueados, etc.)
  Future<String> createOrGetChat({
    required String otherUserId,
  }) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        throw Exception('Usuario no autenticado');
      }

      // ✅ OPTIMIZACIÓN: Verificar si el chat ya existe localmente (con timeout)
      final chatId = _generateChatId(currentUserId, otherUserId);

      try {
        final chatDoc = await _firestore
            .collection('chats')
            .doc(chatId)
            .get()
            .timeout(const Duration(seconds: 5));

        if (chatDoc.exists) {
          ReleaseLogger.log('✅ Chat ya existe (local): $chatId');
          return chatId;
        }
      } catch (e) {
        // Si hay timeout o error, intentar con CF
        ReleaseLogger.log('⚠️ Error verificando chat local, intentando CF: $e');
      }

      // Llamar a Cloud Function si el chat NO existe o hubo error
      ReleaseLogger.log('📝 Creando chat via CF: $chatId');

      final callable = _functions.httpsCallable('createChat');
      final result = await callable.call({
        'otherUserId': otherUserId,
      }).timeout(const Duration(seconds: 15));

      final data = result.data as Map<String, dynamic>;

      if (data['success'] == true) {
        final newChatId = data['chatId'] as String;
        ReleaseLogger.log('✅ Chat creado exitosamente: $newChatId');
        return newChatId;
      } else {
        throw Exception('Error desconocido al crear chat');
      }
    } on FirebaseFunctionsException catch (e) {
      // Errores específicos de la Cloud Function
      ReleaseLogger.error('❌ Error de Cloud Function: ${e.code} - ${e.message}');

      // Mostrar mensaje user-friendly según el código
      String userMessage = e.message ?? 'Error al crear chat';

      if (e.code == 'permission-denied') {
        if (e.message?.contains('contactos aprobados') ?? false) {
          userMessage = 'No tienes autorización para chatear con este usuario. Deben ser contactos aprobados.';
        } else if (e.message?.contains('bloqueado') ?? false) {
          userMessage = 'No puedes crear un chat. Uno de los usuarios tiene bloqueado al otro.';
        } else if (e.message?.contains('padre/madre') ?? false) {
          userMessage = 'Tu padre/madre ha bloqueado los mensajes con este contacto.';
        }
      } else if (e.code == 'resource-exhausted') {
        userMessage = 'Has excedido el límite de creación de chats. Intenta más tarde.';
      } else if (e.code == 'unauthenticated') {
        userMessage = 'Debes iniciar sesión para crear un chat.';
      }

      throw Exception(userMessage);
    } catch (e) {
      ReleaseLogger.error('❌ Error inesperado creando chat: $e');
      throw Exception('Error al crear chat: $e');
    }
  }

  /// Helper estático para crear chat + navegar (con UI loading)
  ///
  /// Maneja todo el flujo:
  /// 1. Muestra loading dialog
  /// 2. Crea/obtiene chat mediante Cloud Function
  /// 3. Navega a ChatDetailScreen
  /// 4. Muestra errores si fallan
  static Future<void> createAndNavigateToChat({
    required BuildContext context,
    required String otherUserId,
    required String otherUserName,
  }) async {
    final service = CreateChatService();

    // Guardar navigator antes de mostrar dialog
    final navigator = Navigator.of(context, rootNavigator: true);
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    // Mostrar loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: Center(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text('Abriendo chat...'),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    try {
      // ✅ SEGURIDAD: Crear chat mediante Cloud Function
      final chatId = await service.createOrGetChat(
        otherUserId: otherUserId,
      );

      // Cerrar loading dialog
      navigator.pop();

      // Navegar a chat
      if (context.mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ChatDetailScreen(
              chatId: chatId,
              contactId: otherUserId,
              contactName: otherUserName,
            ),
          ),
        );
      }
    } catch (e) {
      // Cerrar loading dialog
      try {
        navigator.pop();
      } catch (_) {
        // Dialog might already be closed
      }

      // Mostrar error
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }
}
