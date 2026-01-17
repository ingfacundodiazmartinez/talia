import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mock instances para Firebase
late FakeFirebaseFirestore mockFirestore;
late MockFirebaseAuth mockAuth;
late MockUser mockUser;
late MockFirebaseFunctions mockFunctions;

/// Mock class para FirebaseFunctions
class MockFirebaseFunctions implements FirebaseFunctions {
  final Map<String, MockHttpsCallable> _callables = {};

  // Para tests que necesiten configurar respuestas específicas
  Map<String, dynamic>? _mockResponse;
  Exception? _mockError;
  Map<String, dynamic>? _lastParameters;

  @override
  HttpsCallable httpsCallable(
    String name, {
    HttpsCallableOptions? options,
  }) {
    return _callables[name] ??= MockHttpsCallable(name);
  }

  // Métodos adicionales para compatibilidad con tests existentes
  void setMockResponse(Map<String, dynamic> response) {
    _mockResponse = response;
    _mockError = null;
  }

  void setMockError(Exception error) {
    _mockError = error;
    _mockResponse = null;
  }

  Map<String, dynamic>? get lastParameters => _lastParameters;

  String? get lastCalledFunction => _lastCalledFunction;
  String? _lastCalledFunction;

  void _recordCall(String functionName, Map<String, dynamic> parameters) {
    _lastCalledFunction = functionName;
    _lastParameters = parameters;
  }

  void reset() {
    _mockResponse = null;
    _mockError = null;
    _lastCalledFunction = null;
    _lastParameters = null;
    _callables.clear();
  }

  // Método adicional para compatibilidad con MockCloudFunctionService
  Future<Map<String, dynamic>> callFunction(String functionName, Map<String, dynamic> parameters) async {
    _recordCall(functionName, parameters);

    if (_mockError != null) {
      throw _mockError!;
    }

    return _mockResponse ?? {'success': true};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockHttpsCallable implements HttpsCallable {
  final String functionName;
  final MockFirebaseFunctions _parent;

  MockHttpsCallable(this.functionName) : _parent = mockFunctions;

  @override
  Future<HttpsCallableResult<T>> call<T>([dynamic parameters]) async {
    // Registrar la llamada en el parent
    if (parameters is Map<String, dynamic>) {
      _parent._recordCall(functionName, parameters);
    } else {
      _parent._recordCall(functionName, {});
    }

    // Simular delay mínimo sin hacer llamadas reales
    await Future.delayed(Duration(milliseconds: 1));

    return MockHttpsCallableResult<T>(functionName, parameters);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockHttpsCallableResult<T> implements HttpsCallableResult<T> {
  final String functionName;
  final dynamic parameters;

  MockHttpsCallableResult(this.functionName, this.parameters);

  @override
  T get data {
    // Responder según la función llamada
    switch (functionName) {
      case 'approveStory':
        return {
          'success': true,
          'storyId': parameters?['storyId'] ?? 'test_story_id',
          'status': 'approved',
          'approvedBy': 'test_user_id',
          'approvedAt': DateTime.now().toIso8601String(),
          'message': 'Historia aprobada exitosamente',
        } as T;

      case 'rejectStory':
        return {
          'success': true,
          'storyId': parameters?['storyId'] ?? 'test_story_id',
          'status': 'rejected',
          'rejectedBy': 'test_user_id',
          'rejectedAt': DateTime.now().toIso8601String(),
          'reason': parameters?['reason'],
          'message': 'Historia rechazada exitosamente',
        } as T;

      default:
        return {
          'success': true,
          'message': 'Mock function executed successfully',
        } as T;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Setup para testing con Firebase mocks
Future<void> setupFirebaseForTesting() async {
  // Asegurar que Flutter test bindings estén inicializados
  TestWidgetsFlutterBinding.ensureInitialized();

  // Inicializar Firebase para tests (mock)
  try {
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'test-api-key',
        appId: 'test-app-id',
        messagingSenderId: 'test-sender-id',
        projectId: 'test-project',
      ),
    );
  } catch (e) {
    // Firebase ya inicializado, continuar
  }

  // Crear mock Firestore
  mockFirestore = FakeFirebaseFirestore();

  // Crear mock user
  mockUser = MockUser(
    isAnonymous: false,
    uid: 'test_user_id',
    email: 'test@example.com',
    displayName: 'Test User',
    phoneNumber: '+1234567890',
    photoURL: 'https://example.com/photo.jpg',
  );

  // Crear mock Auth con usuario autenticado
  mockAuth = MockFirebaseAuth(mockUser: mockUser, signedIn: true);

  // Crear mock Functions
  mockFunctions = MockFirebaseFunctions();

  // Setup datos de prueba en Firestore
  await _setupFirestoreTestData();
}


/// Setup de datos de prueba en Firestore
Future<void> _setupFirestoreTestData() async {
  // Crear datos de usuarios de prueba
  await mockFirestore.collection('users').doc('test_user_id').set({
    'name': 'Test User',
    'email': 'test@example.com',
    'photoURL': 'https://example.com/photo.jpg',
    'role': 'parent',
    'linkedChildrenIds': ['child1', 'child2'],
    'createdAt': FieldValue.serverTimestamp(),
  });

  await mockFirestore.collection('users').doc('child1').set({
    'name': 'Child 1',
    'email': 'child1@example.com',
    'photoURL': 'https://example.com/child1.jpg',
    'role': 'child',
    'linkedChildrenIds': [],
    'createdAt': FieldValue.serverTimestamp(),
  });

  await mockFirestore.collection('users').doc('child2').set({
    'name': 'Child 2',
    'email': 'child2@example.com',
    'photoURL': 'https://example.com/child2.jpg',
    'role': 'child',
    'linkedChildrenIds': [],
    'createdAt': FieldValue.serverTimestamp(),
  });

  // Crear historias de prueba
  final now = DateTime.now();
  final twentyFourHoursAgo = now.subtract(Duration(hours: 23)); // Dentro del rango

  await mockFirestore.collection('stories').doc('story1').set({
    'userId': 'child1',
    'userName': 'Child 1',
    'userPhotoURL': 'https://example.com/child1.jpg',
    'mediaUrl': 'https://example.com/story1.jpg',
    'mediaType': 'image',
    'caption': 'Test story 1',
    'status': 'approved',
    'createdAt': Timestamp.fromDate(twentyFourHoursAgo),
    'expiresAt': Timestamp.fromDate(now.add(Duration(hours: 1))),
    'viewedBy': [],
    'replies': [],
  });

  await mockFirestore.collection('stories').doc('story2').set({
    'userId': 'child2',
    'userName': 'Child 2',
    'userPhotoURL': 'https://example.com/child2.jpg',
    'mediaUrl': 'https://example.com/story2.jpg',
    'mediaType': 'image',
    'caption': 'Test story 2',
    'status': 'pending',
    'createdAt': Timestamp.fromDate(twentyFourHoursAgo),
    'expiresAt': Timestamp.fromDate(now.add(Duration(hours: 1))),
    'viewedBy': [],
    'replies': [],
  });

  // Crear contactos de prueba
  await mockFirestore.collection('contacts').doc('contact1').set({
    'users': ['test_user_id', 'child1'],
    'status': 'approved',
    'createdAt': FieldValue.serverTimestamp(),
  });

  await mockFirestore.collection('contacts').doc('contact2').set({
    'users': ['test_user_id', 'child2'],
    'status': 'approved',
    'createdAt': FieldValue.serverTimestamp(),
  });
}

/// Limpiar datos de prueba
Future<void> cleanupFirebaseTestData() async {
  // No necesario para FakeFirebaseFirestore, se resetea automáticamente
}