import '../../../utils/release_logger.dart';
import '../repositories/story_repository.dart';

/// Helper para validaciones de autenticación que se repiten en los servicios de stories
class AuthValidationHelper {

  /// Valida que el usuario esté autenticado y retorna el userId
  /// Lanza una excepción si el usuario no está autenticado
  static String ensureAuthenticated(StoryRepository repository, {String? context}) {
    final currentUserId = repository.currentUserId;

    if (currentUserId == null) {
      final errorMessage = 'Usuario no autenticado';
      final fullContext = context != null ? '[$context] $errorMessage' : errorMessage;

      ReleaseLogger.error(fullContext, tag: 'AuthValidation');
      throw Exception(fullContext);
    }

    return currentUserId;
  }

  /// Valida que el usuario esté autenticado, pero retorna null si no lo está
  /// (para casos donde queremos manejar el null graciosamente)
  static String? checkAuthenticated(StoryRepository repository, {String? context}) {
    final currentUserId = repository.currentUserId;

    if (currentUserId == null) {
      final errorMessage = 'Usuario no autenticado';
      final fullContext = context != null ? '[$context] $errorMessage' : errorMessage;

      ReleaseLogger.warning(fullContext, tag: 'AuthValidation');
    }

    return currentUserId;
  }

  /// Ejecuta una función solo si el usuario está autenticado
  /// Útil para casos donde queremos retornar una lista vacía o valor por defecto
  static T executeIfAuthenticated<T>(
    StoryRepository repository,
    T Function(String userId) authenticatedAction,
    T defaultValue, {
    String? context,
  }) {
    final currentUserId = checkAuthenticated(repository, context: context);

    if (currentUserId == null) {
      return defaultValue;
    }

    return authenticatedAction(currentUserId);
  }

  /// Ejecuta una función async solo si el usuario está autenticado
  static Future<T> executeIfAuthenticatedAsync<T>(
    StoryRepository repository,
    Future<T> Function(String userId) authenticatedAction,
    T defaultValue, {
    String? context,
  }) async {
    final currentUserId = checkAuthenticated(repository, context: context);

    if (currentUserId == null) {
      return defaultValue;
    }

    return await authenticatedAction(currentUserId);
  }
}