import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:talia/services/voip_service.dart';
import 'package:talia/services/callkit_service.dart';
import 'package:talia/services/video_calls/services/call_state_service.dart';

/// Mock instances para Firebase (video calls)
late FakeFirebaseFirestore mockFirestore;
late MockFirebaseAuth mockAuth;
late MockUser mockUser;
late MockVideoCallFunctions mockFunctions;
late MockVoIPService mockVoIPService;
late MockCallKitService mockCallKitService;
late MockCallStateService mockCallStateService;

/// Mock class para FirebaseFunctions específica para video calls
class MockVideoCallFunctions implements FirebaseFunctions {
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

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockHttpsCallable implements HttpsCallable {
  final String functionName;
  final MockVideoCallFunctions _parent;

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
    // Responder según la función llamada para video calls
    switch (functionName) {
      case 'generateAgoraToken':
        return {
          'success': true,
          'token': 'test_agora_token_${DateTime.now().millisecondsSinceEpoch}',
          'uid': parameters?['uid'] ?? 12345,
          'appId': 'test_agora_app_id',
          'channelName': parameters?['channelName'] ?? 'test_channel',
          'message': 'Token generado exitosamente',
        } as T;

      case 'startVideoCall':
        return {
          'success': true,
          'callId': 'test_call_${DateTime.now().millisecondsSinceEpoch}',
          'channelName': parameters?['channelName'] ?? 'test_channel',
          'token': 'test_token',
          'uid': 12345,
          'message': 'Videollamada iniciada exitosamente',
        } as T;

      case 'endVideoCall':
        return {
          'success': true,
          'callId': parameters?['callId'] ?? 'test_call_id',
          'status': 'ended',
          'endedAt': DateTime.now().toIso8601String(),
          'message': 'Videollamada terminada exitosamente',
        } as T;

      default:
        return {
          'success': true,
          'message': 'Mock video call function executed successfully',
        } as T;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Mock class para VoIPService
class MockVoIPService implements VoIPService {
  @override
  Stream<Map<String, dynamic>> get pendingCallStream => Stream.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<void> showIncomingCall(Map<String, dynamic> callData) async {}

  @override
  Future<void> endCall(String callId) async {}

  @override
  Future<void> acceptCall(String callId) async {}

  @override
  Future<void> rejectCall(String callId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Mock class para CallKitService
class MockCallKitService implements CallKitService {
  @override
  Future<void> initialize({
    Function(Map<String, dynamic>)? onCallAccepted,
    Function(String)? onCallDeclined,
    Function(String)? onCallEnded,
    Function(String)? onCallKitShown,
  }) async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<void> reportIncomingCall(Map<String, dynamic> callData) async {}

  @override
  Future<void> reportCallEnded(String callId) async {}

  @override
  Future<void> reportCallConnected(String callId) async {}

  @override
  bool get isInitialized => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Mock class para CallStateService
class MockCallStateService implements CallStateService {
  @override
  Stream<CallStateUpdate> get callStateStream => Stream.empty();

  @override
  Stream<List<IncomingCall>> get incomingCallsStream => Stream.empty();

  @override
  void startMonitoringCall(String callId) {}

  @override
  void stopMonitoringCall(String callId) {}

  @override
  void startMonitoringIncomingCalls(String userId) {}

  @override
  void stopMonitoringIncomingCalls() {}

  @override
  List<IncomingCall> getCurrentIncomingCalls() => [];

  @override
  Future<List<ActiveCall>> getActiveCalls(String userId) async => [];

  @override
  Future<bool> hasActiveCalls(String userId) async => false;

  @override
  void registerExternalServices({
    dynamic voipService,
    dynamic callKitService,
  }) {
    // Mock implementation - just log that services were registered
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Setup para testing con Firebase mocks específico para video calls
Future<void> setupFirebaseForVideoCallTesting() async {
  // Asegurar que Flutter test bindings estén inicializados
  TestWidgetsFlutterBinding.ensureInitialized();

  // Inicializar Firebase para tests (mock)
  try {
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'test-video-call-api-key',
        appId: 'test-video-call-app-id',
        messagingSenderId: 'test-video-call-sender-id',
        projectId: 'test-video-call-project',
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
    uid: 'test_video_caller_id',
    email: 'test.caller@example.com',
    displayName: 'Test Video Caller',
    phoneNumber: '+1234567890',
    photoURL: 'https://example.com/caller.jpg',
  );

  // Crear mock Auth con usuario autenticado
  mockAuth = MockFirebaseAuth(mockUser: mockUser, signedIn: true);

  // Crear mock Functions para video calls
  mockFunctions = MockVideoCallFunctions();

  // Crear mock services para video calls
  mockVoIPService = MockVoIPService();
  mockCallKitService = MockCallKitService();
  mockCallStateService = MockCallStateService();

  // Setup datos de prueba en Firestore para video calls
  await _setupVideoCallTestData();
}

/// Setup de datos de prueba en Firestore para video calls
Future<void> _setupVideoCallTestData() async {
  // Crear datos de usuarios de prueba
  await mockFirestore.collection('users').doc('test_video_caller_id').set({
    'name': 'Test Video Caller',
    'email': 'test.caller@example.com',
    'photoURL': 'https://example.com/caller.jpg',
    'role': 'parent',
    'linkedChildrenIds': ['test_receiver_1', 'test_receiver_2'],
    'createdAt': FieldValue.serverTimestamp(),
  });

  await mockFirestore.collection('users').doc('test_receiver_1').set({
    'name': 'Test Receiver 1',
    'email': 'receiver1@example.com',
    'photoURL': 'https://example.com/receiver1.jpg',
    'role': 'child',
    'linkedChildrenIds': [],
    'createdAt': FieldValue.serverTimestamp(),
  });

  await mockFirestore.collection('users').doc('test_receiver_2').set({
    'name': 'Test Receiver 2',
    'email': 'receiver2@example.com',
    'photoURL': 'https://example.com/receiver2.jpg',
    'role': 'child',
    'linkedChildrenIds': [],
    'createdAt': FieldValue.serverTimestamp(),
  });

  // Add a user that integration tests will expect
  await mockFirestore.collection('users').doc('test-receiver').set({
    'name': 'Test Receiver',
    'email': 'receiver@example.com',
    'photoURL': 'https://example.com/receiver.jpg',
    'role': 'child',
    'linkedChildrenIds': [],
    'createdAt': FieldValue.serverTimestamp(),
  });

  // Crear videollamadas de prueba
  final now = DateTime.now();

  await mockFirestore.collection('video_calls').doc('test_call_1').set({
    'callerId': 'test_video_caller_id',
    'callerName': 'Test Video Caller',
    'receiverId': 'test_receiver_1',
    'receiverName': 'Test Receiver 1',
    'isVideo': true,
    'status': 'calling',
    'channelName': 'test_channel_1',
    'token': 'test_token_1',
    'uid': 12345,
    'agoraAppId': 'test_agora_app_id',
    'createdAt': now.toIso8601String(),
    'type': 'video',
  });

  await mockFirestore.collection('video_calls').doc('test_call_2').set({
    'callerId': 'test_receiver_2',
    'callerName': 'Test Receiver 2',
    'receiverId': 'test_video_caller_id',
    'receiverName': 'Test Video Caller',
    'isVideo': false,
    'status': 'accepted',
    'channelName': 'test_channel_2',
    'token': 'test_token_2',
    'uid': 67890,
    'agoraAppId': 'test_agora_app_id',
    'createdAt': now.subtract(Duration(minutes: 5)).toIso8601String(),
    'acceptedAt': now.subtract(Duration(minutes: 4)).toIso8601String(),
    'type': 'audio',
  });

  // Crear contactos de prueba
  await mockFirestore.collection('contacts').doc('contact1').set({
    'users': ['test_video_caller_id', 'test_receiver_1'],
    'status': 'approved',
    'createdAt': FieldValue.serverTimestamp(),
  });

  await mockFirestore.collection('contacts').doc('contact2').set({
    'users': ['test_video_caller_id', 'test_receiver_2'],
    'status': 'approved',
    'createdAt': FieldValue.serverTimestamp(),
  });
}

/// Limpiar datos de prueba para video calls
Future<void> cleanupVideoCallTestData() async {
  // Reset mock functions
  mockFunctions.reset();

  // No necesario para FakeFirebaseFirestore, se resetea automáticamente
}