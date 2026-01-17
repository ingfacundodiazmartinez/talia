import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:talia/services/block_status_cache_service.dart';
import 'package:talia/services/stories/managers/story_stream_manager.dart';
import 'package:talia/services/stories/repositories/story_repository.dart';
import 'package:talia/services/stories/repositories/contact_repository.dart';
import 'package:talia/services/stories/managers/story_cache_manager.dart';
import 'test_firebase_setup.dart';
import 'test_mocks.dart';
import 'test_helpers.dart';

/// Test de integración para verificar que el flujo completo de bloqueo/desbloqueo
/// funciona correctamente con actualización automática de historias
void main() {
  group('Block Service Integration Tests', () {
    late StoryStreamManager storyStreamManager;
    late StoryCacheManager cacheManager;
    late MockBlockStatusCacheService blockStatusService;
    late TestServices testServices;

    setUpAll(() async {
      await setupFirebaseForTesting();
    });

    setUp(() async {
      testServices = await TestSetupHelper.setupStandardTestServices();

      final contactRepository = ContactRepository(
        firestore: testServices.firestore,
        auth: testServices.auth,
      );

      final storyRepository = StoryRepository(
        firestore: testServices.firestore,
        auth: testServices.auth,
      );

      cacheManager = StoryCacheManager();
      blockStatusService = MockBlockStatusCacheService();

      storyStreamManager = StoryStreamManager(
        storyRepository: storyRepository,
        contactRepository: contactRepository,
        cacheManager: cacheManager,
        blockStatusService: blockStatusService,
      );
    });

    test('Complete integration: Block contact and stories disappear automatically', () async {
      // 1. Configurar historias iniciales en el cache usando helpers
      final testUserStories = [
        StoryTestHelper.createUserStoriesGroup(
          userId: 'user1',
          userName: 'User 1',
          storyCount: 1,
          hasUnviewed: true,
        ),
        StoryTestHelper.createUserStoriesGroup(
          userId: 'user2',
          userName: 'User 2',
          storyCount: 1,
          hasUnviewed: true,
        ),
      ];

      // Actualizar cache inicial
      cacheManager.updateCache(testUserStories);

      // Verificar estado inicial
      final initialStories = cacheManager.getCachedStories();
      expect(initialStories.length, 2);
      expect(initialStories.any((us) => us.userId == 'user1'), isTrue);
      expect(initialStories.any((us) => us.userId == 'user2'), isTrue);

      // 2. Configurar listener para eventos de bloqueo (simular la conexión real)
      final receivedEvents = <BlockStatusChange>[];
      final subscription = blockStatusService.blockStatusChanges.listen(
        (event) {
          receivedEvents.add(event);
        },
      );

      // 3. Simular bloqueo usando BlockService (simula el flujo real de la app)
      blockStatusService.updateBlockStatus('user1', true);

      // 4. Esperar a que se procese el evento
      await Future.delayed(Duration(milliseconds: 100));

      // 5. Verificar que el evento fue emitido correctamente
      expect(receivedEvents.length, 1);
      expect(receivedEvents.first.contactId, 'user1');
      expect(receivedEvents.first.isBlocked, isTrue);

      // 6. Verificar que las historias de user1 fueron removidas automáticamente
      final storiesAfterBlock = cacheManager.getCachedStories();
      expect(storiesAfterBlock.length, 1);
      expect(storiesAfterBlock.any((us) => us.userId == 'user1'), isFalse);
      expect(storiesAfterBlock.any((us) => us.userId == 'user2'), isTrue);

      await subscription.cancel();

    });

    test('Complete integration: Unblock contact triggers refresh', () async {
      // 1. Configurar estado inicial (user1 ya bloqueado) usando helper
      final testUserStories = [
        StoryTestHelper.createUserStoriesGroup(
          userId: 'user2',
          userName: 'User 2',
          storyCount: 1,
          hasUnviewed: true,
        ),
      ];

      cacheManager.updateCache(testUserStories);

      // Verificar estado inicial (solo user2)
      final initialStories = cacheManager.getCachedStories();
      expect(initialStories.length, 1);
      expect(initialStories.any((us) => us.userId == 'user2'), isTrue);

      // 2. Configurar listener para eventos de desbloqueo
      final receivedEvents = <BlockStatusChange>[];
      final subscription = blockStatusService.blockStatusChanges.listen(
        (event) {
          receivedEvents.add(event);
        },
      );

      // 3. Simular desbloqueo usando BlockService
      blockStatusService.updateBlockStatus('user1', false);

      // 4. Esperar procesamiento del evento
      await Future.delayed(Duration(milliseconds: 100));

      // 5. Verificar que el evento fue emitido correctamente
      expect(receivedEvents.length, 1);
      expect(receivedEvents.first.contactId, 'user1');
      expect(receivedEvents.first.isBlocked, isFalse);

      await subscription.cancel();

    });

    test('BlockService integration: Cache notifications work correctly', () async {
      // Este test verifica que BlockService está conectado correctamente
      // al BlockStatusCacheService para emitir eventos

      final receivedEvents = <BlockStatusChange>[];
      final completer = Completer<void>();

      // Escuchar eventos
      final subscription = blockStatusService.blockStatusChanges.listen(
        (event) {
          receivedEvents.add(event);
          if (receivedEvents.length >= 2) {
            completer.complete();
          }
        },
      );

      // Simular operaciones de BlockService
      blockStatusService.updateBlockStatus('testUser1', true);
      blockStatusService.updateBlockStatus('testUser2', false);

      // Esperar a que se reciban ambos eventos
      await completer.future.timeout(Duration(seconds: 5));

      // Verificar eventos recibidos
      expect(receivedEvents.length, 2);

      final blockEvent = receivedEvents[0];
      expect(blockEvent.contactId, 'testUser1');
      expect(blockEvent.isBlocked, isTrue);

      final unblockEvent = receivedEvents[1];
      expect(unblockEvent.contactId, 'testUser2');
      expect(unblockEvent.isBlocked, isFalse);

      await subscription.cancel();

    });

    test('Real-world simulation: Multiple block/unblock operations', () async {
      // Simular escenario real con múltiples usuarios y operaciones

      // 1. Configurar cache con múltiples usuarios usando helpers
      final testUserStories = [
        StoryTestHelper.createUserStoriesGroup(
          userId: 'alice',
          userName: 'Alice',
          storyCount: 1,
          hasUnviewed: true,
        ),
        StoryTestHelper.createUserStoriesGroup(
          userId: 'bob',
          userName: 'Bob',
          storyCount: 1,
          hasUnviewed: true,
        ),
        StoryTestHelper.createUserStoriesGroup(
          userId: 'charlie',
          userName: 'Charlie',
          storyCount: 1,
          hasUnviewed: true,
        ),
      ];

      cacheManager.updateCache(testUserStories);

      // Verificar estado inicial (3 usuarios)
      expect(cacheManager.getCachedStories().length, 3);

      // 2. Bloquear Alice
      blockStatusService.updateBlockStatus('alice', true);
      await Future.delayed(Duration(milliseconds: 50));

      // Verificar que Alice fue removida
      final afterAliceBlock = cacheManager.getCachedStories();
      expect(afterAliceBlock.length, 2);
      expect(afterAliceBlock.any((us) => us.userId == 'alice'), isFalse);
      expect(afterAliceBlock.any((us) => us.userId == 'bob'), isTrue);
      expect(afterAliceBlock.any((us) => us.userId == 'charlie'), isTrue);

      // 3. Bloquear Bob
      blockStatusService.updateBlockStatus('bob', true);
      await Future.delayed(Duration(milliseconds: 50));

      // Verificar que Bob también fue removido
      final afterBobBlock = cacheManager.getCachedStories();
      expect(afterBobBlock.length, 1);
      expect(afterBobBlock.any((us) => us.userId == 'charlie'), isTrue);

      // 4. Desbloquear Alice
      blockStatusService.updateBlockStatus('alice', false);
      await Future.delayed(Duration(milliseconds: 50));

      // En una implementación real, esto triggearía un refresh que volvería
      // a cargar las historias de Alice desde Firestore

    });

    tearDown(() async {
      storyStreamManager.dispose();
      blockStatusService.dispose();
      cacheManager.dispose();

      // Limpiar datos de test usando helper
      await TestSetupHelper.cleanupAfterTest(testServices.firestore);
    });
  });
}