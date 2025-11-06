import 'package:mockito/mockito.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// Mock para FirebaseFunctions usado en tests
class MockFirebaseFunctions extends Mock implements FirebaseFunctions {
  final Map<String, MockHttpsCallable> _callables = {};

  @override
  HttpsCallable httpsCallable(String name, [HttpsCallableOptions? options]) {
    return _callables.putIfAbsent(name, () => MockHttpsCallable(name));
  }

  /// Registrar mock para una función específica
  void mockFunction(String name, Future<HttpsCallableResult> Function(dynamic) handler) {
    final callable = _callables.putIfAbsent(name, () => MockHttpsCallable(name));
    callable.setHandler(handler);
  }

  /// Registrar mock con resultado específico
  void mockFunctionResult(String name, Map<String, dynamic> result) {
    mockFunction(name, (_) async => MockHttpsCallableResult(result));
  }

  /// Registrar mock que lanza error
  void mockFunctionError(String name, Exception error) {
    mockFunction(name, (_) async => throw error);
  }

  /// Limpiar todos los mocks
  void clearMocks() {
    _callables.clear();
  }

  /// Verificar si una función fue llamada
  bool wasCalled(String name) {
    return _callables[name]?.wasCalled ?? false;
  }

  /// Obtener argumentos de la última llamada
  dynamic getLastCallArguments(String name) {
    return _callables[name]?.lastCallArguments;
  }

  /// Obtener número de veces que fue llamada
  int getCallCount(String name) {
    return _callables[name]?.callCount ?? 0;
  }
}

/// Mock para HttpsCallable
class MockHttpsCallable extends Mock implements HttpsCallable {
  final String functionName;
  Future<HttpsCallableResult> Function(dynamic)? _handler;
  bool wasCalled = false;
  dynamic lastCallArguments;
  int callCount = 0;

  MockHttpsCallable(this.functionName);

  void setHandler(Future<HttpsCallableResult> Function(dynamic) handler) {
    _handler = handler;
  }

  @override
  Future<HttpsCallableResult> call([dynamic parameters]) async {
    wasCalled = true;
    callCount++;
    lastCallArguments = parameters;

    if (_handler != null) {
      return await _handler!(parameters);
    }

    // Respuesta por defecto para evitar errores
    return MockHttpsCallableResult({'success': true});
  }
}

/// Mock para HttpsCallableResult
class MockHttpsCallableResult extends Mock implements HttpsCallableResult {
  final dynamic _data;

  MockHttpsCallableResult(this._data);

  @override
  dynamic get data => _data;
}

// ═══════════════════════════════════════════════════════════════
// MOCKS ESPECÍFICOS PARA STORIES
// ═══════════════════════════════════════════════════════════════

/// Mock preconfigurado para createStory Cloud Function
class CreateStoryMock {
  static void success(MockFirebaseFunctions mockFunctions, {
    String storyId = 'test-story-123',
    String status = 'approved',
  }) {
    mockFunctions.mockFunctionResult('createStory', {
      'success': true,
      'storyId': storyId,
      'status': status,
      'createdAt': DateTime.now().toIso8601String(),
      'message': status == 'pending'
          ? 'Historia creada. Esperando aprobación de tus padres.'
          : 'Historia creada y publicada exitosamente.'
    });
  }

  static void rateLimitError(MockFirebaseFunctions mockFunctions) {
    mockFunctions.mockFunctionError('createStory',
      FirebaseFunctionsException(
        'resource-exhausted',
        'Has excedido el límite de 5 historias por hora. Espera un poco.',
      )
    );
  }

  static void validationError(MockFirebaseFunctions mockFunctions, String message) {
    mockFunctions.mockFunctionError('createStory',
      FirebaseFunctionsException(
        'invalid-argument',
        message,
      )
    );
  }

  static void unauthenticatedError(MockFirebaseFunctions mockFunctions) {
    mockFunctions.mockFunctionError('createStory',
      FirebaseFunctionsException(
        'unauthenticated',
        'Usuario no autenticado',
      )
    );
  }
}

/// Mock preconfigurado para approveStory Cloud Function
class ApproveStoryMock {
  static void success(MockFirebaseFunctions mockFunctions, {
    String storyId = 'test-story-123',
  }) {
    mockFunctions.mockFunctionResult('approveStory', {
      'success': true,
      'storyId': storyId,
      'status': 'approved',
      'approvedBy': 'test-parent-id',
      'approvedAt': DateTime.now().toIso8601String(),
      'message': 'Historia aprobada exitosamente'
    });
  }

  static void permissionError(MockFirebaseFunctions mockFunctions) {
    mockFunctions.mockFunctionError('approveStory',
      FirebaseFunctionsException(
        'permission-denied',
        'No tienes permisos para aprobar esta historia',
      )
    );
  }

  static void notFoundError(MockFirebaseFunctions mockFunctions) {
    mockFunctions.mockFunctionError('approveStory',
      FirebaseFunctionsException(
        'not-found',
        'Historia no encontrada',
      )
    );
  }
}

/// Mock preconfigurado para rejectStory Cloud Function
class RejectStoryMock {
  static void success(MockFirebaseFunctions mockFunctions, {
    String storyId = 'test-story-123',
    String reason = 'Contenido inapropiado',
  }) {
    mockFunctions.mockFunctionResult('rejectStory', {
      'success': true,
      'storyId': storyId,
      'status': 'rejected',
      'rejectedBy': 'test-parent-id',
      'rejectedAt': DateTime.now().toIso8601String(),
      'reason': reason,
      'message': 'Historia rechazada exitosamente'
    });
  }
}

/// Mock preconfigurado para replyToStory Cloud Function
class ReplyToStoryMock {
  static void success(MockFirebaseFunctions mockFunctions, {
    String messageId = 'test-message-123',
  }) {
    mockFunctions.mockFunctionResult('replyToStory', {
      'success': true,
      'messageId': messageId,
      'message': 'Respuesta enviada exitosamente'
    });
  }

  static void storyExpiredError(MockFirebaseFunctions mockFunctions) {
    mockFunctions.mockFunctionError('replyToStory',
      FirebaseFunctionsException(
        'failed-precondition',
        'Esta historia ya expiró (más de 24 horas)',
      )
    );
  }

  static void blockedUserError(MockFirebaseFunctions mockFunctions) {
    mockFunctions.mockFunctionError('replyToStory',
      FirebaseFunctionsException(
        'permission-denied',
        'No puedes responder a historias de usuarios bloqueados',
      )
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// HELPER PARA CONFIGURAR MOCKS EN TESTS
// ═══════════════════════════════════════════════════════════════

class CloudFunctionTestHelper {
  static MockFirebaseFunctions setupMocks() {
    final mockFunctions = MockFirebaseFunctions();

    // Configurar respuestas por defecto exitosas
    CreateStoryMock.success(mockFunctions);
    ApproveStoryMock.success(mockFunctions);
    RejectStoryMock.success(mockFunctions);
    ReplyToStoryMock.success(mockFunctions);

    return mockFunctions;
  }

  static void setupRateLimitScenario(MockFirebaseFunctions mockFunctions) {
    // Primera llamada exitosa
    CreateStoryMock.success(mockFunctions);

    // Luego configurar para que falle por rate limit
    Future.delayed(Duration(milliseconds: 100), () {
      CreateStoryMock.rateLimitError(mockFunctions);
    });
  }

  static void setupParentChildScenario(MockFirebaseFunctions mockFunctions) {
    // Hijo crea historia -> pending
    CreateStoryMock.success(mockFunctions, status: 'pending');

    // Padre aprueba
    ApproveStoryMock.success(mockFunctions);
  }
}