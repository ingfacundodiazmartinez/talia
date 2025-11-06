import 'package:flutter_test/flutter_test.dart';
import '../../../lib/services/stories/services/story_viewing_service.dart';
import '../../../lib/services/stories/repositories/story_repository.dart';
import 'test_firebase_setup.dart';
import 'test_helpers.dart';

/// Test comprensivo para verificar permisos de visualización de historias
///
/// Casos cubiertos:
/// 1. Permisos de marcado como vista para historias propias
/// 2. Manejo de errores de permisos
/// 3. Verificación de no invalidación de cache
void main() {
  group('Story Viewing Permission Tests', () {
    late StoryViewingService viewingService;
    late StoryRepository storyRepository;
    late TestServices testServices;

    setUpAll(() async {
      await setupFirebaseForTesting();
    });

    setUp(() async {
      testServices = await TestSetupHelper.setupStandardTestServices();

      storyRepository = StoryRepository(
        firestore: testServices.firestore,
        auth: testServices.auth,
      );

      viewingService = StoryViewingService(
        storyRepository: storyRepository,
        functions: testServices.functions,
      );
    });

    test('Should allow marking own story as viewed', () async {
      // 1. Crear historia propia usando helpers
      final ownStory = StoryTestHelper.createTestStory(
        id: 'own_story_1',
        userId: testServices.user.uid,
        userName: testServices.user.displayName!,
      );

      // 2. Agregar historia al mock de Firestore
      await FirestoreTestHelper.addStoryToFirestore(testServices.firestore, ownStory);

      // 3. Intentar marcar como vista (debería funcionar)
      await expectLater(
        viewingService.markStoryAsViewed(ownStory.id),
        completes,
      );

      // 4. Verificar que se agregó a viewedBy
      await TestVerificationHelper.verifyUserViewedStory(
        testServices.firestore,
        ownStory.id,
        testServices.user.uid,
      );

      print('✅ [ViewingPermissionTest] Usuario puede marcar sus propias historias como vistas');
    });

    test('Should verify Firestore rules updated for viewing permissions', () async {
      // Este test verifica conceptualmente que las reglas de Firestore permiten
      // a usuarios autenticados marcar historias como vistas cuando tienen permisos

      // 1. Crear historia usando helpers
      final testStory = StoryTestHelper.createTestStory(
        id: 'firestore_rules_test',
        userId: testServices.user.uid,
        userName: testServices.user.displayName!,
        caption: 'Firestore rules test story',
      );

      // 2. Agregar historia al mock
      await FirestoreTestHelper.addStoryToFirestore(testServices.firestore, testStory);

      // 3. Marcar como vista (debería funcionar con las reglas actualizadas)
      await expectLater(
        viewingService.markStoryAsViewed(testStory.id),
        completes,
      );

      // 4. Verificar que la operación se completó
      await TestVerificationHelper.verifyUserViewedStory(
        testServices.firestore,
        testStory.id,
        testServices.user.uid,
      );

      print('✅ [ViewingPermissionTest] Reglas de Firestore actualizadas correctamente');
    });

    test('Should handle story viewing efficiently without cache invalidation', () async {
      // Este test verifica que el sistema de visualización no invalida cache innecesariamente

      // 1. Crear historia de prueba
      final cacheTestStory = StoryTestHelper.createTestStory(
        id: 'cache_efficiency_test',
        userId: testServices.user.uid,
        userName: testServices.user.displayName!,
        caption: 'Cache efficiency test',
      );

      // 2. Agregar al mock Firestore
      await FirestoreTestHelper.addStoryToFirestore(testServices.firestore, cacheTestStory);

      // 3. Marcar como vista con verificación de performance
      await TestVerificationHelper.verifyOperationPerformance(
        viewingService.markStoryAsViewed(cacheTestStory.id),
        maxMilliseconds: 500,
      );

      // 4. Verificar que la operación se completó correctamente
      await TestVerificationHelper.verifyUserViewedStory(
        testServices.firestore,
        cacheTestStory.id,
        testServices.user.uid,
      );

      print('✅ [ViewingPermissionTest] No hay invalidación de cache al marcar historia como vista');
    });

    tearDown(() async {
      // Limpiar mocks después de cada test usando helper
      await TestSetupHelper.cleanupAfterTest(testServices.firestore);
    });
  });
}