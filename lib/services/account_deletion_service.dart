import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../utils/release_logger.dart';

/// Servicio para eliminación segura de cuentas
///
/// Llama a Cloud Function que maneja toda la lógica de eliminación
/// server-side para garantizar integridad de datos.
class AccountDeletionService {
  final FirebaseFunctions _functions;
  final FirebaseAuth _auth;

  static final AccountDeletionService _instance = AccountDeletionService._internal();

  factory AccountDeletionService() => _instance;

  AccountDeletionService._internal()
      : _functions = FirebaseFunctions.instanceFor(region: 'us-central1'),
        _auth = FirebaseAuth.instance;

  /// Constructor para testing con inyección de dependencias
  AccountDeletionService.withDependencies({
    required FirebaseFunctions functions,
    required FirebaseAuth auth,
  })  : _functions = functions,
        _auth = auth;

  /// Eliminar cuenta del usuario actual
  ///
  /// [confirmationText] - Debe ser exactamente "ELIMINAR" para confirmar
  ///
  /// Retorna el resultado de la eliminación con las colecciones eliminadas
  ///
  /// Throws:
  /// - Exception si el usuario no está autenticado
  /// - Exception si la confirmación no es correcta
  /// - Exception si hay error en la Cloud Function
  Future<AccountDeletionResult> deleteAccount({
    required String confirmationText,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw AccountDeletionException('Usuario no autenticado');
    }

    if (confirmationText != 'ELIMINAR') {
      throw AccountDeletionException(
        'Debes escribir ELIMINAR para confirmar la eliminación',
      );
    }

    ReleaseLogger.log(
      'Iniciando eliminación de cuenta para: ${user.uid}',
      tag: 'AccountDeletion',
    );

    try {
      final callable = _functions.httpsCallable(
        'deleteUserAccount',
        options: HttpsCallableOptions(
          timeout: const Duration(minutes: 5),
        ),
      );

      final result = await callable.call<Map<String, dynamic>>({
        'confirmationText': confirmationText,
      });

      final data = result.data;

      if (data['success'] == true) {
        ReleaseLogger.log(
          'Cuenta eliminada exitosamente',
          tag: 'AccountDeletion',
        );

        // Sign out localmente (la cuenta ya fue eliminada en el servidor)
        await _auth.signOut();

        return AccountDeletionResult(
          success: true,
          message: data['message'] ?? 'Cuenta eliminada exitosamente',
          deletedCollections: List<String>.from(
            data['deletedCollections'] ?? [],
          ),
        );
      } else {
        throw AccountDeletionException(
          data['message'] ?? 'Error desconocido al eliminar cuenta',
        );
      }
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error(
        'Error de Cloud Function: ${e.code} - ${e.message}',
        tag: 'AccountDeletion',
      );

      String userMessage;
      switch (e.code) {
        case 'unauthenticated':
          userMessage = 'Tu sesión ha expirado. Por favor, inicia sesión de nuevo.';
          break;
        case 'invalid-argument':
          userMessage = e.message ?? 'Confirmación inválida';
          break;
        case 'not-found':
          userMessage = 'No se encontró tu cuenta';
          break;
        case 'permission-denied':
          userMessage = 'No tienes permiso para realizar esta acción';
          break;
        default:
          userMessage = 'Error al eliminar cuenta. Intenta de nuevo.';
      }

      throw AccountDeletionException(userMessage);
    } catch (e) {
      ReleaseLogger.error(
        'Error inesperado: $e',
        tag: 'AccountDeletion',
      );
      throw AccountDeletionException(
        'Error inesperado al eliminar cuenta: $e',
      );
    }
  }

  /// Verificar si el usuario puede eliminar su cuenta
  ///
  /// Retorna información sobre el tipo de cuenta y advertencias
  Future<AccountDeletionPreview> getDeletePreview() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw AccountDeletionException('Usuario no autenticado');
    }

    // Por ahora retornamos información básica
    // En el futuro podríamos llamar a una CF para obtener más detalles
    return AccountDeletionPreview(
      canDelete: true,
      warnings: [
        'Todos tus mensajes serán eliminados',
        'Tu perfil y foto serán eliminados',
        'Tus historias serán eliminadas',
        'Perderás conexión con tus contactos',
      ],
    );
  }
}

/// Resultado de la eliminación de cuenta
class AccountDeletionResult {
  final bool success;
  final String message;
  final List<String> deletedCollections;

  AccountDeletionResult({
    required this.success,
    required this.message,
    this.deletedCollections = const [],
  });
}

/// Vista previa de eliminación de cuenta
class AccountDeletionPreview {
  final bool canDelete;
  final List<String> warnings;
  final String? blockingReason;

  AccountDeletionPreview({
    required this.canDelete,
    this.warnings = const [],
    this.blockingReason,
  });
}

/// Excepción específica para errores de eliminación de cuenta
class AccountDeletionException implements Exception {
  final String message;

  AccountDeletionException(this.message);

  @override
  String toString() => message;
}
