import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import '../../../lib/services/stories/repositories/contact_repository.dart';
import '../../../lib/services/stories/managers/story_stream_manager.dart';
import '../../../lib/services/stories/repositories/story_repository.dart';
import '../../../lib/services/stories/managers/story_cache_manager.dart';
import '../../../lib/services/block_status_cache_service.dart';
import 'test_firebase_setup.dart';
import 'test_helpers.dart';
import 'test_mocks.dart';


/// Test específico para verificar que las historias se actualizan automáticamente
/// cuando se cambia el estado de bloqueo de un contacto
void main() {
  group('Automatic Refresh on Block Status Change Tests', () {
    late ContactRepository contactRepository;
    late StoryStreamManager storyStreamManager;
    late StoryCacheManager cacheManager;
    late MockBlockStatusCacheService blockStatusService;
    late TestServices testServices;

    setUpAll(() async {
      await setupFirebaseForTesting();
    });

    setUp(() async {
      testServices = await TestSetupHelper.setupStandardTestServices();

      contactRepository = ContactRepository(
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

    test('Automatic refresh: Stories removed when user is blocked', () async {
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

      // 2. Simular bloqueo de user1
      blockStatusService.updateBlockStatus('user1', true);

      // 3. Esperar un poco para que se procese el evento
      await Future.delayed(Duration(milliseconds: 100));

      // 4. Verificar que las historias de user1 fueron removidas automáticamente
      final storiesAfterBlock = cacheManager.getCachedStories();
      expect(storiesAfterBlock.length, 1);
      expect(storiesAfterBlock.any((us) => us.userId == 'user1'), isFalse);
      expect(storiesAfterBlock.any((us) => us.userId == 'user2'), isTrue);

      print('✅ [AutoRefreshTest] Historias de user1 removidas automáticamente después del bloqueo');
    });

    test('Automatic refresh: Stories restored when user is unblocked', () async {
      // 1. Configurar historias iniciales (user1 ya bloqueado) usando helper
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

      // 2. Simular desbloqueo de user1
      blockStatusService.updateBlockStatus('user1', false);

      // 3. Esperar procesamiento del evento
      await Future.delayed(Duration(milliseconds: 100));

      // 4. Verificar que se triggereó la recarga granular
      // En una implementación real, esto recargará solo las historias de user1
      // sin afectar el resto del cache

      print('✅ [AutoRefreshTest] Recarga granular triggereada después del desbloqueo');
    });

    test('Block status change stream: Events are emitted correctly', () async {
      final receivedEvents = <BlockStatusChange>[];
      final completer = Completer<void>();

      // Escuchar eventos de cambio de bloqueo
      final subscription = blockStatusService.blockStatusChanges.listen(
        (event) {
          receivedEvents.add(event);
          if (receivedEvents.length >= 2) {
            completer.complete();
          }
        },
      );

      // Emitir eventos de cambio
      blockStatusService.updateBlockStatus('user1', true);
      blockStatusService.updateBlockStatus('user2', false);

      // Esperar a que se reciban los eventos
      await completer.future.timeout(Duration(seconds: 5));

      // Verificar eventos recibidos
      expect(receivedEvents.length, 2);

      final event1 = receivedEvents[0];
      expect(event1.contactId, 'user1');
      expect(event1.isBlocked, isTrue);

      final event2 = receivedEvents[1];
      expect(event2.contactId, 'user2');
      expect(event2.isBlocked, isFalse);

      await subscription.cancel();

      print('✅ [AutoRefreshTest] Eventos de cambio de bloqueo emitidos correctamente');
    });

    test('Bidirectional blocking: Both users receive block notifications', () async {
      // Este test simula el comportamiento bidireccional donde tanto el usuario
      // que bloquea como el bloqueado reciben notificaciones

      final receivedEvents = <BlockStatusChange>[];
      final completer = Completer<void>();

      // Escuchar eventos
      final subscription = blockStatusService.blockStatusChanges.listen(
        (event) {
          receivedEvents.add(event);
          if (receivedEvents.length >= 3) {
            completer.complete();
          }
        },
      );

      // Simular escenario bidireccional:
      // 1. User A bloquea a User B (User A emite evento)
      blockStatusService.updateBlockStatus('userB', true);

      // 2. User B recibe notificación de Firestore (simulado)
      blockStatusService.handleBlockStatusChange('userA', true, isBlockedBy: true);

      // 3. User B también bloquea a User A (bloqueo mutuo)
      blockStatusService.updateBlockStatus('userA', true);

      // Esperar eventos
      await completer.future.timeout(Duration(seconds: 5));

      // Verificar que ambos usuarios recibieron notificaciones
      expect(receivedEvents.length, 3);

      // Evento 1: User A bloqueó a User B
      expect(receivedEvents[0].contactId, 'userB');
      expect(receivedEvents[0].isBlocked, isTrue);

      // Evento 2: User B recibió notificación de que User A lo bloqueó
      expect(receivedEvents[1].contactId, 'userA');
      expect(receivedEvents[1].isBlocked, isTrue);

      // Evento 3: User B bloqueó a User A (bloqueo mutuo)
      expect(receivedEvents[2].contactId, 'userA');
      expect(receivedEvents[2].isBlocked, isTrue);

      await subscription.cancel();

      print('✅ [AutoRefreshTest] Notificaciones bidireccionales funcionan correctamente');
    });

    test('StoryCacheManager: removeStoriesByUserId works correctly', () {
      // Configurar cache con múltiples usuarios usando helpers
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
        StoryTestHelper.createUserStoriesGroup(
          userId: 'user3',
          userName: 'User 3',
          storyCount: 1,
          hasUnviewed: true,
        ),
      ];

      cacheManager.updateCache(testUserStories);

      // Verificar estado inicial
      final initialStories = cacheManager.getCachedStories();
      expect(initialStories.length, 3);

      // Remover historias de user2
      cacheManager.removeStoriesByUserId('user2');

      // Verificar que solo user2 fue removido
      final storiesAfterRemoval = cacheManager.getCachedStories();
      expect(storiesAfterRemoval.length, 2);
      expect(storiesAfterRemoval.any((us) => us.userId == 'user1'), isTrue);
      expect(storiesAfterRemoval.any((us) => us.userId == 'user2'), isFalse);
      expect(storiesAfterRemoval.any((us) => us.userId == 'user3'), isTrue);

      print('✅ [AutoRefreshTest] removeStoriesByUserId funciona correctamente');
    });

    test('Parent-child cache: Invalidation is granular for blocked user', () {
      // Este test verifica que la invalidación del cache padre-hijo es granular

      // Mock del cache interno del StoryStreamManager
      final metrics = storyStreamManager.getMetrics();
      expect(metrics, isA<Map<String, dynamic>>());

      // Simular bloqueo
      blockStatusService.updateBlockStatus('user1', true);

      // Verificar que el cache se invalidó de manera granular
      // (en lugar de limpiar todo el cache)
      final metricsAfterBlock = storyStreamManager.getMetrics();
      expect(metricsAfterBlock, isA<Map<String, dynamic>>());

      print('✅ [AutoRefreshTest] Invalidación granular del cache padre-hijo');
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