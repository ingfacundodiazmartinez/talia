import 'package:flutter_test/flutter_test.dart';

import 'package:talia/services/stories/services/story_approval_service.dart';
import 'package:talia/services/stories/repositories/story_repository.dart';
import 'package:talia/services/stories/managers/story_cache_manager.dart';

import 'test_firebase_setup.dart';

void main() {
  group('StoryApprovalService Cloud Functions Tests', () {
    late StoryApprovalService storyApprovalService;
    late StoryRepository storyRepository;
    late StoryCacheManager cacheManager;

    setUpAll(() async {
      await setupFirebaseForTesting();
    });

    setUp(() {
      storyRepository = StoryRepository(
        firestore: mockFirestore,
        auth: mockAuth,
      );

      cacheManager = StoryCacheManager();

      storyApprovalService = StoryApprovalService(
        storyRepository: storyRepository,
        cacheManager: cacheManager,
        functions: mockFunctions, // Inyectar mock
      );
    });

    test('approveStory: Debe manejar respuesta exitosa', () async {
      // Act
      await storyApprovalService.approveStory('test_story_id');

      // Assert - No debe lanzar excepción
      expect(true, isTrue); // Si llegamos aquí, no hubo excepción
    });

    test('rejectStory: Debe manejar respuesta exitosa', () async {
      // Act
      await storyApprovalService.rejectStory('test_story_id');

      // Assert - No debe lanzar excepción
      expect(true, isTrue); // Si llegamos aquí, no hubo excepción
    });

    test('approveStory: Debe manejar respuesta con mensaje', () async {
      // Act & Assert - No debe lanzar excepción
      await storyApprovalService.approveStory('test_story_id', message: 'Test approval');
      expect(true, isTrue);
    });

    test('rejectStory: Debe manejar respuesta con razón', () async {
      // Act & Assert - No debe lanzar excepción
      await storyApprovalService.rejectStory('test_story_id', reason: 'Test rejection');
      expect(true, isTrue);
    });
  });
}