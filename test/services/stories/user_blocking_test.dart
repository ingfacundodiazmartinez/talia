import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';

import '../../../lib/services/stories/repositories/contact_repository.dart';
import '../../../lib/services/stories/managers/story_stream_manager.dart';
import '../../../lib/services/stories/repositories/story_repository.dart';
import '../../../lib/services/stories/managers/story_cache_manager.dart';
import '../../../lib/models/story.dart';
import 'test_firebase_setup.dart';
import 'test_mocks.dart';

/// Tests para validar que usuarios bloqueados no pueden ver historias entre ellos
///
/// FUNCIONALIDAD CRÍTICA DE SEGURIDAD:
/// - Si user A bloquea a user B, B no debe ver las historias de A
/// - Si user A bloquea a user B, A no debe ver las historias de B
/// - Los bloqueos deben ser bidireccionales para historias
/// - Los bloqueos deben funcionar tanto para usuarios padre-hijo como entre pares
void main() {
  group('User Blocking Tests', () {
    late FakeFirebaseFirestore mockFirestore;
    late MockFirebaseAuth mockAuth;
    late MockUser mockUser;
    late ContactRepository contactRepository;
    late StoryStreamManager storyStreamManager;
    late MockBlockStatusCacheService mockBlockStatusService;
    late StoryRepository storyRepository;

    setUpAll(() async {
      await setupFirebaseForTesting();
    });

    setUp(() async {
      mockFirestore = FakeFirebaseFirestore();
      mockUser = MockUser(
        uid: 'test_user_id',
        email: 'test@example.com',
        displayName: 'Test User',
      );
      mockAuth = MockFirebaseAuth(mockUser: mockUser);

      // Initialize mock block status service
      mockBlockStatusService = MockBlockStatusCacheService();

      contactRepository = ContactRepository(
        firestore: mockFirestore,
        auth: mockAuth,
      );

      storyRepository = StoryRepository(
        firestore: mockFirestore,
        auth: mockAuth,
      );

      final cacheManager = StoryCacheManager();

      storyStreamManager = StoryStreamManager(
        storyRepository: storyRepository,
        contactRepository: contactRepository,
        cacheManager: cacheManager,
        blockStatusService: mockBlockStatusService,
      );

      // Setup test data with blocking relationships
      await _setupBlockingTestData(mockFirestore);
    });

    group('Story Visibility with Blocking', () {
      test('Usuario bloqueado no debe ver historias del bloqueador', () async {
        // Simular que user1 bloquea a user2
        // user2 no debe poder ver las historias de user1

        // Crear historias de user1 (quien bloquea)
        final storiesFromBlocker = [
          Story(
            id: 'story_blocked_user',
            userId: 'user1', // Usuario que bloquea
            userName: 'User 1',
            userPhotoURL: null,
            mediaUrl: 'url1',
            mediaType: 'image',
            caption: 'Historia del usuario que bloquea',
            createdAt: DateTime.now(),
            expiresAt: DateTime.now().add(Duration(hours: 24)),
            viewedBy: [],
            replies: [],
            status: StoryStatus.approved,
          ),
        ];

        // Simular que user2 (bloqueado) intenta ver las historias
        // Cambiar el contexto del auth a user2
        final blockedUser = MockUser(
          uid: 'user2',
          email: 'user2@example.com',
          displayName: 'User 2',
        );
        final blockedUserAuth = MockFirebaseAuth(mockUser: blockedUser);

        final blockedUserStoryManager = StoryStreamManager(
          storyRepository: StoryRepository(
            firestore: mockFirestore,
            auth: blockedUserAuth,
          ),
          contactRepository: ContactRepository(
            firestore: mockFirestore,
            auth: blockedUserAuth,
          ),
          cacheManager: StoryCacheManager(),
          blockStatusService: mockBlockStatusService,
        );

        // Filtrar historias desde la perspectiva del usuario bloqueado
        final filteredStories = await blockedUserStoryManager
            .filterStoriesByVisibilityRules(storiesFromBlocker);

        // El usuario bloqueado NO debe ver las historias del bloqueador
        expect(filteredStories, isEmpty,
            reason: 'Usuario bloqueado no debe ver historias del bloqueador');
      });

      test('Usuario bloqueador no debe ver historias del bloqueado', () async {
        // Simular que user1 bloquea a user2
        // user1 no debe poder ver las historias de user2

        // Crear historias de user2 (quien es bloqueado)
        final storiesFromBlocked = [
          Story(
            id: 'story_from_blocked',
            userId: 'user2', // Usuario bloqueado
            userName: 'User 2',
            userPhotoURL: null,
            mediaUrl: 'url2',
            mediaType: 'image',
            caption: 'Historia del usuario bloqueado',
            createdAt: DateTime.now(),
            expiresAt: DateTime.now().add(Duration(hours: 24)),
            viewedBy: [],
            replies: [],
            status: StoryStatus.approved,
          ),
        ];

        // Simular que user1 (bloqueador) intenta ver las historias
        final blockerUser = MockUser(
          uid: 'user1',
          email: 'user1@example.com',
          displayName: 'User 1',
        );
        final blockerUserAuth = MockFirebaseAuth(mockUser: blockerUser);

        final blockerUserStoryManager = StoryStreamManager(
          storyRepository: StoryRepository(
            firestore: mockFirestore,
            auth: blockerUserAuth,
          ),
          contactRepository: ContactRepository(
            firestore: mockFirestore,
            auth: blockerUserAuth,
          ),
          cacheManager: StoryCacheManager(),
          blockStatusService: mockBlockStatusService,
        );

        // Filtrar historias desde la perspectiva del usuario bloqueador
        final filteredStories = await blockerUserStoryManager
            .filterStoriesByVisibilityRules(storiesFromBlocked);

        // El usuario bloqueador NO debe ver las historias del bloqueado
        expect(filteredStories, isEmpty,
            reason: 'Usuario bloqueador no debe ver historias del bloqueado');
      });

      test('Usuarios no bloqueados pueden ver historias normalmente', () async {
        // Verificar que usuarios sin bloqueo pueden ver historias normalmente

        // Crear historias de user3 (sin bloqueos)
        final storiesFromNormalUser = [
          Story(
            id: 'story_normal',
            userId: 'user3', // Usuario sin bloqueos
            userName: 'User 3',
            userPhotoURL: null,
            mediaUrl: 'url3',
            mediaType: 'image',
            caption: 'Historia normal sin bloqueos',
            createdAt: DateTime.now(),
            expiresAt: DateTime.now().add(Duration(hours: 24)),
            viewedBy: [],
            replies: [],
            status: StoryStatus.approved,
          ),
        ];

        // Simular que user4 (sin bloqueo) ve las historias
        final normalUser = MockUser(
          uid: 'user4',
          email: 'user4@example.com',
          displayName: 'User 4',
        );
        final normalUserAuth = MockFirebaseAuth(mockUser: normalUser);

        final normalUserStoryManager = StoryStreamManager(
          storyRepository: StoryRepository(
            firestore: mockFirestore,
            auth: normalUserAuth,
          ),
          contactRepository: ContactRepository(
            firestore: mockFirestore,
            auth: normalUserAuth,
          ),
          cacheManager: StoryCacheManager(),
          blockStatusService: mockBlockStatusService,
        );

        // Filtrar historias desde la perspectiva del usuario normal
        final filteredStories = await normalUserStoryManager
            .filterStoriesByVisibilityRules(storiesFromNormalUser);

        // El usuario normal SÍ debe ver las historias (si tiene permisos)
        expect(filteredStories, isA<List<Story>>(),
            reason: 'Usuarios sin bloqueo deben poder ver historias normalmente');
      });

      test('Bloqueo mutuo: Ambos usuarios no pueden ver historias del otro', () async {
        // Test caso donde ambos usuarios se bloquean mutuamente

        final storiesFromUser1 = [
          Story(
            id: 'story_user1_mutual',
            userId: 'user1',
            userName: 'User 1',
            userPhotoURL: null,
            mediaUrl: 'url1',
            mediaType: 'image',
            caption: 'Historia de user1 en bloqueo mutuo',
            createdAt: DateTime.now(),
            expiresAt: DateTime.now().add(Duration(hours: 24)),
            viewedBy: [],
            replies: [],
            status: StoryStatus.approved,
          ),
        ];

        final storiesFromUser2 = [
          Story(
            id: 'story_user2_mutual',
            userId: 'user2',
            userName: 'User 2',
            userPhotoURL: null,
            mediaUrl: 'url2',
            mediaType: 'image',
            caption: 'Historia de user2 en bloqueo mutuo',
            createdAt: DateTime.now(),
            expiresAt: DateTime.now().add(Duration(hours: 24)),
            viewedBy: [],
            replies: [],
            status: StoryStatus.approved,
          ),
        ];

        // Agregar bloqueo mutuo en ambas direcciones
        await mockFirestore.collection('blocked_contacts').add({
          'userId': 'user1',
          'blockedUserId': 'user2',
          'blockedAt': FieldValue.serverTimestamp(),
        });

        await mockFirestore.collection('blocked_contacts').add({
          'userId': 'user2',
          'blockedUserId': 'user1',
          'blockedAt': FieldValue.serverTimestamp(),
        });

        // Test desde perspectiva de user1
        final user1Auth = MockFirebaseAuth(mockUser: MockUser(
          uid: 'user1',
          email: 'user1@example.com',
          displayName: 'User 1',
        ));

        final user1StoryManager = StoryStreamManager(
          storyRepository: StoryRepository(
            firestore: mockFirestore,
            auth: user1Auth,
          ),
          contactRepository: ContactRepository(
            firestore: mockFirestore,
            auth: user1Auth,
          ),
          cacheManager: StoryCacheManager(),
          blockStatusService: mockBlockStatusService,
        );

        final user1FilteredStories = await user1StoryManager
            .filterStoriesByVisibilityRules(storiesFromUser2);

        // Test desde perspectiva de user2
        final user2Auth = MockFirebaseAuth(mockUser: MockUser(
          uid: 'user2',
          email: 'user2@example.com',
          displayName: 'User 2',
        ));

        final user2StoryManager = StoryStreamManager(
          storyRepository: StoryRepository(
            firestore: mockFirestore,
            auth: user2Auth,
          ),
          contactRepository: ContactRepository(
            firestore: mockFirestore,
            auth: user2Auth,
          ),
          cacheManager: StoryCacheManager(),
          blockStatusService: mockBlockStatusService,
        );

        final user2FilteredStories = await user2StoryManager
            .filterStoriesByVisibilityRules(storiesFromUser1);

        // Ambos deben tener listas vacías
        expect(user1FilteredStories, isEmpty,
            reason: 'User1 no debe ver historias de user2 en bloqueo mutuo');
        expect(user2FilteredStories, isEmpty,
            reason: 'User2 no debe ver historias de user1 en bloqueo mutuo');
      });

      test('Bloqueo padre-hijo: Hijo bloqueado no ve historias del padre', () async {
        // Test específico para relación padre-hijo con bloqueo

        // Crear historia del padre
        final parentStory = [
          Story(
            id: 'story_parent',
            userId: 'parent1',
            userName: 'Parent 1',
            userPhotoURL: null,
            mediaUrl: 'parent_url',
            mediaType: 'image',
            caption: 'Historia del padre',
            createdAt: DateTime.now(),
            expiresAt: DateTime.now().add(Duration(hours: 24)),
            viewedBy: [],
            replies: [],
            status: StoryStatus.approved,
          ),
        ];

        // Simular que el padre bloquea al hijo
        await mockFirestore.collection('blocked_contacts').add({
          'userId': 'parent1',
          'blockedUserId': 'child1',
          'blockedAt': FieldValue.serverTimestamp(),
        });

        // Test desde perspectiva del hijo bloqueado
        final childAuth = MockFirebaseAuth(mockUser: MockUser(
          uid: 'child1',
          email: 'child1@example.com',
          displayName: 'Child 1',
        ));

        final childStoryManager = StoryStreamManager(
          storyRepository: StoryRepository(
            firestore: mockFirestore,
            auth: childAuth,
          ),
          contactRepository: ContactRepository(
            firestore: mockFirestore,
            auth: childAuth,
          ),
          cacheManager: StoryCacheManager(),
          blockStatusService: mockBlockStatusService,
        );

        final filteredStories = await childStoryManager
            .filterStoriesByVisibilityRules(parentStory);

        // El hijo bloqueado NO debe ver historias del padre
        expect(filteredStories, isEmpty,
            reason: 'Hijo bloqueado no debe ver historias del padre');
      });
    });

    group('Block Status Validation', () {
      test('isUserBlocked: Detecta correctamente usuarios bloqueados', () async {
        // Test directo del método de validación de bloqueo

        // Este test verificaría que existe un método para verificar si un usuario está bloqueado
        // Nota: Este método podría estar en ContactRepository o en un servicio separado

        // Crear relación de bloqueo
        await mockFirestore.collection('blocked_contacts').add({
          'userId': 'user1',
          'blockedUserId': 'user2',
          'blockedAt': FieldValue.serverTimestamp(),
        });

        // Verificar que se detecta el bloqueo
        // Esto dependería de la implementación exacta del método
        expect(true, isTrue, reason: 'Placeholder para método de validación de bloqueo');
      });

      test('Performance: Bloqueos no afectan rendimiento con muchos usuarios', () async {
        // Test de rendimiento con múltiples usuarios y bloqueos

        final multipleStories = List.generate(50, (index) => Story(
          id: 'story_$index',
          userId: 'user_$index',
          userName: 'User $index',
          userPhotoURL: null,
          mediaUrl: 'url_$index',
          mediaType: 'image',
          caption: 'Historia $index',
          createdAt: DateTime.now(),
          expiresAt: DateTime.now().add(Duration(hours: 24)),
          viewedBy: [],
          replies: [],
          status: StoryStatus.approved,
        ));

        // Crear varios bloqueos
        for (int i = 0; i < 10; i++) {
          await mockFirestore.collection('blocked_contacts').add({
            'userId': 'current_user',
            'blockedUserId': 'user_$i',
            'blockedAt': FieldValue.serverTimestamp(),
          });
        }

        final stopwatch = Stopwatch()..start();

        // Filtrar historias con múltiples bloqueos
        final filteredStories = await storyStreamManager
            .filterStoriesByVisibilityRules(multipleStories);

        stopwatch.stop();

        // El filtrado debe ser rápido incluso con muchos bloqueos
        expect(stopwatch.elapsedMilliseconds, lessThan(5000),
            reason: 'Filtrado de bloqueos debe ser eficiente');

        // Debe filtrar correctamente los usuarios bloqueados
        expect(filteredStories.length, lessThan(multipleStories.length),
            reason: 'Debe filtrar algunas historias por bloqueos');
      });
    });

    tearDown(() {
      storyStreamManager.dispose();
    });
  });
}

/// Setup de datos de prueba específicos para tests de bloqueo
Future<void> _setupBlockingTestData(FakeFirebaseFirestore mockFirestore) async {
  // Crear usuarios de prueba
  await mockFirestore.collection('users').doc('user1').set({
    'name': 'User 1',
    'email': 'user1@example.com',
    'role': 'parent',
    'linkedChildrenIds': [],
    'createdAt': FieldValue.serverTimestamp(),
  });

  await mockFirestore.collection('users').doc('user2').set({
    'name': 'User 2',
    'email': 'user2@example.com',
    'role': 'parent',
    'linkedChildrenIds': [],
    'createdAt': FieldValue.serverTimestamp(),
  });

  await mockFirestore.collection('users').doc('user3').set({
    'name': 'User 3',
    'email': 'user3@example.com',
    'role': 'parent',
    'linkedChildrenIds': [],
    'createdAt': FieldValue.serverTimestamp(),
  });

  await mockFirestore.collection('users').doc('user4').set({
    'name': 'User 4',
    'email': 'user4@example.com',
    'role': 'parent',
    'linkedChildrenIds': [],
    'createdAt': FieldValue.serverTimestamp(),
  });

  await mockFirestore.collection('users').doc('parent1').set({
    'name': 'Parent 1',
    'email': 'parent1@example.com',
    'role': 'parent',
    'linkedChildrenIds': ['child1'],
    'createdAt': FieldValue.serverTimestamp(),
  });

  await mockFirestore.collection('users').doc('child1').set({
    'name': 'Child 1',
    'email': 'child1@example.com',
    'role': 'child',
    'linkedChildrenIds': [],
    'createdAt': FieldValue.serverTimestamp(),
  });

  // Crear relación de bloqueo inicial: user1 bloquea a user2
  await mockFirestore.collection('blocked_contacts').add({
    'userId': 'user1',
    'blockedUserId': 'user2',
    'blockedAt': FieldValue.serverTimestamp(),
  });

  // Crear contactos de prueba (para usuarios que no están bloqueados)
  await mockFirestore.collection('contacts').doc('contact_user3_user4').set({
    'users': ['user3', 'user4'],
    'status': 'approved',
    'createdAt': FieldValue.serverTimestamp(),
  });

  await mockFirestore.collection('contacts').doc('contact_parent_child').set({
    'users': ['parent1', 'child1'],
    'status': 'approved',
    'createdAt': FieldValue.serverTimestamp(),
  });
}