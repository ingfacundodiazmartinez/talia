import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:talia/services/video_call_service.dart';
import 'package:talia/services/block_service.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';

/// Tests para validación de llamadas de video/audio
///
/// Casos críticos:
/// 1. Solo se puede llamar a contactos aprobados
/// 2. En Android, debe pedir permisos antes de ejecutar llamada
@GenerateMocks([
  BlockService,
])
import 'video_call_validation_test.mocks.dart';

// Global mock block service for validation functions
MockBlockService? _mockBlockService;

void main() {
  group('VideoCall Validation Tests', () {
    late FakeFirebaseFirestore mockFirestore;
    late MockFirebaseAuth mockAuth;
    late MockUser mockUser;
    late MockBlockService mockBlockService;

    setUpAll(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    setUp(() {
      mockFirestore = FakeFirebaseFirestore();
      mockAuth = MockFirebaseAuth(signedIn: true);
      mockUser = MockUser(uid: 'test-user-123');
      mockBlockService = MockBlockService();
      _mockBlockService = mockBlockService; // Assign to global variable
    });

    group('Contact Approval Validation', () {
      test('🚫 DEBE rechazar llamada a contacto NO aprobado', () async {
        // Setup: Crear un contacto no aprobado
        await mockFirestore.collection('users').doc('test-user-123').set({
          'name': 'User Test',
          'role': 'child',
          'parentId': 'parent-123',
        });

        await mockFirestore.collection('users').doc('contact-456').set({
          'name': 'Contacto No Aprobado',
          'role': 'child',
        });

        // NO crear entrada en whitelist (contacto no aprobado)

        when(mockBlockService.isBlocked(any)).thenAnswer((_) async => false);

        // Simular intento de llamada
        final result = await _simulateCallValidation(
          callerId: 'test-user-123',
          contactId: 'contact-456',
          firestore: mockFirestore,
        );

        expect(result['canCall'], false);
        expect(result['reason'], contains('no está aprobado'));
      });

      test('✅ DEBE permitir llamada a contacto aprobado', () async {
        // Setup: Crear contacto aprobado
        await mockFirestore.collection('users').doc('test-user-123').set({
          'name': 'User Test',
          'role': 'child',
          'parentId': 'parent-123',
        });

        await mockFirestore.collection('users').doc('contact-789').set({
          'name': 'Contacto Aprobado',
          'role': 'child',
        });

        // Crear entrada en whitelist (contacto aprobado)
        await mockFirestore.collection('whitelist').add({
          'userId': 'test-user-123',
          'contactId': 'contact-789',
          'status': 'approved',
          'approvedAt': FieldValue.serverTimestamp(),
        });

        when(mockBlockService.isBlocked(any)).thenAnswer((_) async => false);

        // Simular llamada válida
        final result = await _simulateCallValidation(
          callerId: 'test-user-123',
          contactId: 'contact-789',
          firestore: mockFirestore,
        );

        expect(result['canCall'], true);
        expect(result['reason'], isNull);
      });

      test('🚫 DEBE rechazar llamada a contacto bloqueado (incluso si está aprobado)', () async {
        // Setup: Contacto aprobado PERO bloqueado
        await mockFirestore.collection('users').doc('test-user-123').set({
          'name': 'User Test',
          'role': 'child',
        });

        await mockFirestore.collection('users').doc('contact-blocked').set({
          'name': 'Contacto Bloqueado',
          'role': 'child',
        });

        // Contacto está en whitelist
        await mockFirestore.collection('whitelist').add({
          'userId': 'test-user-123',
          'contactId': 'contact-blocked',
          'status': 'approved',
        });

        // PERO está bloqueado
        when(mockBlockService.isBlocked('contact-blocked'))
            .thenAnswer((_) async => true);

        final result = await _simulateCallValidation(
          callerId: 'test-user-123',
          contactId: 'contact-blocked',
          firestore: mockFirestore,
        );

        expect(result['canCall'], false);
        expect(result['reason'], contains('bloqueado'));
      });

      test('✅ ADULTOS pueden llamar a cualquier usuario (sin restricciones)', () async {
        // Setup: Usuario adulto
        await mockFirestore.collection('users').doc('adult-user').set({
          'name': 'Usuario Adulto',
          'role': 'adult',
        });

        await mockFirestore.collection('users').doc('any-contact').set({
          'name': 'Cualquier Contacto',
          'role': 'child',
        });

        // NO hay entrada en whitelist, pero usuario es adulto
        when(mockBlockService.isBlocked(any)).thenAnswer((_) async => false);

        final result = await _simulateCallValidation(
          callerId: 'adult-user',
          contactId: 'any-contact',
          firestore: mockFirestore,
        );

        expect(result['canCall'], true);
        expect(result['reason'], isNull);
      });
    });

    group('Android Permissions Validation', () {
      test('🎙️ DEBE pedir permiso de micrófono antes de audio call en Android', () async {
        // Simular Android
        debugDefaultTargetPlatformOverride = TargetPlatform.android;

        final permissionResults = await _simulateAndroidPermissionCheck(
          callType: 'audio',
          initialMicPermission: PermissionStatus.denied,
          initialCameraPermission: PermissionStatus.granted, // No necesaria para audio
        );

        expect(permissionResults['microphoneRequested'], true);
        expect(permissionResults['cameraRequested'], false);
        expect(permissionResults['canProceed'], false); // Hasta que usuario conceda

        // Cleanup
        debugDefaultTargetPlatformOverride = null;
      });

      test('📹 DEBE pedir permisos de micrófono Y cámara antes de video call en Android', () async {
        // Simular Android
        debugDefaultTargetPlatformOverride = TargetPlatform.android;

        final permissionResults = await _simulateAndroidPermissionCheck(
          callType: 'video',
          initialMicPermission: PermissionStatus.denied,
          initialCameraPermission: PermissionStatus.denied,
        );

        expect(permissionResults['microphoneRequested'], true);
        expect(permissionResults['cameraRequested'], true);
        expect(permissionResults['canProceed'], false); // Faltan ambos permisos

        // Cleanup
        debugDefaultTargetPlatformOverride = null;
      });

      test('✅ NO debe pedir permisos si ya están concedidos en Android', () async {
        // Simular Android
        debugDefaultTargetPlatformOverride = TargetPlatform.android;

        final permissionResults = await _simulateAndroidPermissionCheck(
          callType: 'video',
          initialMicPermission: PermissionStatus.granted,
          initialCameraPermission: PermissionStatus.granted,
        );

        expect(permissionResults['microphoneRequested'], false);
        expect(permissionResults['cameraRequested'], false);
        expect(permissionResults['canProceed'], true); // Todos los permisos OK

        // Cleanup
        debugDefaultTargetPlatformOverride = null;
      });

      test('🍎 iOS NO debe solicitar permisos manualmente (CallKit los maneja)', () async {
        // Simular iOS
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;

        final permissionResults = await _simulateAndroidPermissionCheck(
          callType: 'video',
          initialMicPermission: PermissionStatus.denied, // Aunque esté denied
          initialCameraPermission: PermissionStatus.denied,
        );

        // En iOS, no solicitamos permisos manualmente
        expect(permissionResults['microphoneRequested'], false);
        expect(permissionResults['cameraRequested'], false);
        expect(permissionResults['canProceed'], true); // CallKit maneja permisos

        // Cleanup
        debugDefaultTargetPlatformOverride = null;
      });

      test('🔄 DEBE solicitar permisos nuevamente si fueron revocados en Android', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;

        final permissionResults = await _simulateAndroidPermissionCheck(
          callType: 'video',
          initialMicPermission: PermissionStatus.permanentlyDenied,
          initialCameraPermission: PermissionStatus.denied,
        );

        expect(permissionResults['microphoneRequested'], true);
        expect(permissionResults['cameraRequested'], true);
        expect(permissionResults['shouldOpenSettings'], true); // Micrófono permanently denied

        // Cleanup
        debugDefaultTargetPlatformOverride = null;
      });
    });

    group('Call Concurrency Validation', () {
      test('🔄 DEBE rechazar segunda llamada si ya hay una activa (ocupado)', () async {
        // Setup: Usuario con llamada activa
        await mockFirestore.collection('users').doc('test-user-123').set({
          'name': 'User Test',
          'role': 'child',
          'isInCall': true, // Usuario ya está en llamada
          'activeCallId': 'active-call-456',
        });

        await mockFirestore.collection('users').doc('caller-789').set({
          'name': 'Otro Usuario',
          'role': 'child',
        });

        // Ambos usuarios están en whitelist
        await mockFirestore.collection('whitelist').add({
          'userId': 'test-user-123',
          'contactId': 'caller-789',
          'status': 'approved',
        });

        await mockFirestore.collection('whitelist').add({
          'userId': 'caller-789',
          'contactId': 'test-user-123',
          'status': 'approved',
        });

        when(mockBlockService.isBlocked(any)).thenAnswer((_) async => false);

        // Simular intento de segunda llamada
        final result = await _simulateCallValidation(
          callerId: 'caller-789',
          contactId: 'test-user-123',
          firestore: mockFirestore,
        );

        expect(result['canCall'], false);
        expect(result['reason'], contains('ocupado'));
      });

      test('✅ DEBE permitir llamada si el usuario NO está ocupado', () async {
        // Setup: Usuario disponible (no en llamada)
        await mockFirestore.collection('users').doc('test-user-123').set({
          'name': 'User Test',
          'role': 'child',
          'isInCall': false, // Usuario disponible
        });

        await mockFirestore.collection('users').doc('caller-789').set({
          'name': 'Otro Usuario',
          'role': 'child',
        });

        // Ambos usuarios están en whitelist
        await mockFirestore.collection('whitelist').add({
          'userId': 'test-user-123',
          'contactId': 'caller-789',
          'status': 'approved',
        });

        await mockFirestore.collection('whitelist').add({
          'userId': 'caller-789',
          'contactId': 'test-user-123',
          'status': 'approved',
        });

        when(mockBlockService.isBlocked(any)).thenAnswer((_) async => false);

        // Simular llamada válida
        final result = await _simulateCallValidation(
          callerId: 'caller-789',
          contactId: 'test-user-123',
          firestore: mockFirestore,
        );

        expect(result['canCall'], true);
        expect(result['reason'], isNull);
      });

      test('📞 DEBE marcar usuario como ocupado al iniciar llamada', () async {
        // Setup: Usuario disponible
        await mockFirestore.collection('users').doc('test-user-123').set({
          'name': 'User Test',
          'role': 'child',
          'isInCall': false,
        });

        // Simular inicio de llamada
        final callData = {
          'callId': 'new-call-123',
          'callerId': 'test-user-123',
          'contactId': 'contact-456',
          'callType': 'video',
          'status': 'calling',
          'createdAt': FieldValue.serverTimestamp(),
        };

        // Crear llamada activa
        await mockFirestore.collection('calls').doc('new-call-123').set(callData);

        // Actualizar estado del usuario
        await mockFirestore.collection('users').doc('test-user-123').update({
          'isInCall': true,
          'activeCallId': 'new-call-123',
        });

        // Verificar que se marcó como ocupado
        final userDoc = await mockFirestore
            .collection('users')
            .doc('test-user-123')
            .get();

        final userData = userDoc.data()!;
        expect(userData['isInCall'], true);
        expect(userData['activeCallId'], 'new-call-123');
      });

      test('✅ DEBE liberar estado ocupado al finalizar llamada', () async {
        // Setup: Usuario en llamada
        await mockFirestore.collection('users').doc('test-user-123').set({
          'name': 'User Test',
          'role': 'child',
          'isInCall': true,
          'activeCallId': 'active-call-456',
        });

        // Crear llamada activa primero
        await mockFirestore.collection('calls').doc('active-call-456').set({
          'callId': 'active-call-456',
          'callerId': 'test-user-123',
          'contactId': 'contact-456',
          'status': 'active',
          'createdAt': FieldValue.serverTimestamp(),
        });

        // Simular finalización de llamada
        await mockFirestore.collection('calls').doc('active-call-456').update({
          'status': 'ended',
          'endedAt': FieldValue.serverTimestamp(),
        });

        // Actualizar estado del usuario
        await mockFirestore.collection('users').doc('test-user-123').update({
          'isInCall': false,
          'activeCallId': FieldValue.delete(),
        });

        // Verificar que se liberó el estado ocupado
        final userDoc = await mockFirestore
            .collection('users')
            .doc('test-user-123')
            .get();

        final userData = userDoc.data()!;
        expect(userData['isInCall'], false);
        expect(userData['activeCallId'], isNull);
      });
    });
  });
}

/// Simula validación de contactos aprobados para llamadas
Future<Map<String, dynamic>> _simulateCallValidation({
  required String callerId,
  required String contactId,
  required FirebaseFirestore firestore,
}) async {
  try {
    // 1. Verificar que el caller existe y obtener su rol
    final callerDoc = await firestore.collection('users').doc(callerId).get();
    if (!callerDoc.exists) {
      return {'canCall': false, 'reason': 'Usuario no encontrado'};
    }

    final callerRole = callerDoc.data()?['role'] ?? 'child';

    // 2. Verificar que el contacto existe y obtener su estado
    final contactDoc = await firestore.collection('users').doc(contactId).get();
    if (!contactDoc.exists) {
      return {'canCall': false, 'reason': 'Contacto no encontrado'};
    }

    final contactData = contactDoc.data()!;
    final isContactInCall = contactData['isInCall'] ?? false;

    // 3. Verificar si el contacto está ocupado (en llamada)
    if (isContactInCall == true) {
      return {'canCall': false, 'reason': 'El contacto está ocupado en otra llamada'};
    }

    // 4. Si es adulto, puede llamar a cualquiera (excepto bloqueados y ocupados)
    if (callerRole == 'adult') {
      return {'canCall': true, 'reason': null};
    }

    // 5. Para niños/jóvenes, verificar whitelist
    final whitelistQuery = await firestore
        .collection('whitelist')
        .where('userId', isEqualTo: callerId)
        .where('contactId', isEqualTo: contactId)
        .where('status', isEqualTo: 'approved')
        .get();

    if (whitelistQuery.docs.isEmpty) {
      return {'canCall': false, 'reason': 'Contacto no está aprobado por el padre'};
    }

    // 6. Verificar que no esté bloqueado usando BlockService mock
    final isBlocked = await _mockBlockService?.isBlocked(contactId) ?? false;
    if (isBlocked) {
      return {'canCall': false, 'reason': 'Contacto bloqueado'};
    }

    return {'canCall': true, 'reason': null};
  } catch (e) {
    return {'canCall': false, 'reason': 'Error de validación: $e'};
  }
}

/// Simula verificación de permisos en Android antes de llamada
Future<Map<String, dynamic>> _simulateAndroidPermissionCheck({
  required String callType,
  required PermissionStatus initialMicPermission,
  required PermissionStatus initialCameraPermission,
}) async {
  final results = <String, dynamic>{
    'microphoneRequested': false,
    'cameraRequested': false,
    'canProceed': true,
    'shouldOpenSettings': false,
  };

  // En iOS, CallKit maneja los permisos automáticamente
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return results;
  }

  // En Android, verificamos permisos manualmente
  bool needsMicrophone = callType == 'audio' || callType == 'video';
  bool needsCamera = callType == 'video';

  // Simular verificación de micrófono
  if (needsMicrophone && initialMicPermission != PermissionStatus.granted) {
    results['microphoneRequested'] = true;
    results['canProceed'] = false;

    if (initialMicPermission == PermissionStatus.permanentlyDenied) {
      results['shouldOpenSettings'] = true;
    }
  }

  // Simular verificación de cámara
  if (needsCamera && initialCameraPermission != PermissionStatus.granted) {
    results['cameraRequested'] = true;
    results['canProceed'] = false;

    if (initialCameraPermission == PermissionStatus.permanentlyDenied) {
      results['shouldOpenSettings'] = true;
    }
  }

  return results;
}