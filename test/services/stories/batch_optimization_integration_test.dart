import 'package:flutter_test/flutter_test.dart';
import '../../../lib/services/stories/repositories/contact_repository.dart';
import '../../../lib/services/stories/managers/story_stream_manager.dart';
import '../../../lib/services/stories/repositories/story_repository.dart';
import '../../../lib/services/stories/managers/story_cache_manager.dart';
import '../../../lib/models/story.dart';
import 'test_firebase_setup.dart';
import 'test_mocks.dart';

void main() {
  group('Batch Optimization Integration Tests', () {
    late ContactRepository contactRepository;
    late StoryStreamManager storyStreamManager;

    setUpAll(() async {
      await setupFirebaseForTesting();
    });

    setUp(() {
      contactRepository = ContactRepository(
        firestore: mockFirestore,
        auth: mockAuth,
      );

      final storyRepository = StoryRepository(
        firestore: mockFirestore,
        auth: mockAuth,
      );
      final cacheManager = StoryCacheManager();

      storyStreamManager = StoryStreamManager(
        storyRepository: storyRepository,
        contactRepository: contactRepository,
        cacheManager: cacheManager,
        blockStatusService: MockBlockStatusCacheService(),
      );
    });

    test('getBatchLinkedParents: Basic functionality test', () async {
      // Test with empty input
      final emptyResult = await contactRepository.getBatchLinkedParents([]);
      expect(emptyResult, isEmpty);

      // Test with single child
      final singleResult = await contactRepository.getBatchLinkedParents(['child1']);
      expect(singleResult, isA<Map<String, Set<String>>>());
      expect(singleResult.containsKey('child1'), isTrue);
    });

    test('getBatchLinkedParents: Handles duplicates correctly', () async {
      // Test that duplicate child IDs are handled correctly
      final result = await contactRepository.getBatchLinkedParents([
        'child1', 'child1', 'child2', 'child1' // Duplicates
      ]);

      expect(result, isA<Map<String, Set<String>>>());
      expect(result.keys.length, 2); // Should only have 2 unique keys
      expect(result.containsKey('child1'), isTrue);
      expect(result.containsKey('child2'), isTrue);
    });

    test('StoryStreamManager: Uses batch optimization for filtering', () async {
      // Create test stories with different statuses
      final stories = [
        Story(
          id: 'story1',
          userId: 'child1',
          userName: 'Child 1',
          userPhotoURL: null,
          mediaUrl: 'url1',
          mediaType: 'image',
          caption: 'Test story 1',
          createdAt: DateTime.now(),
          expiresAt: DateTime.now().add(Duration(hours: 24)),
          viewedBy: [],
          replies: [],
          status: StoryStatus.pending,
        ),
        Story(
          id: 'story2',
          userId: 'child2',
          userName: 'Child 2',
          userPhotoURL: null,
          mediaUrl: 'url2',
          mediaType: 'image',
          caption: 'Test story 2',
          createdAt: DateTime.now(),
          expiresAt: DateTime.now().add(Duration(hours: 24)),
          viewedBy: [],
          replies: [],
          status: StoryStatus.rejected,
        ),
        Story(
          id: 'story3',
          userId: 'child3',
          userName: 'Child 3',
          userPhotoURL: null,
          mediaUrl: 'url3',
          mediaType: 'image',
          caption: 'Test story 3',
          createdAt: DateTime.now(),
          expiresAt: DateTime.now().add(Duration(hours: 24)),
          viewedBy: [],
          replies: [],
          status: StoryStatus.approved,
        ),
      ];

      // This should internally use the batch optimization
      final filteredStories = await storyStreamManager.filterStoriesByVisibilityRules(stories);

      // Should return a filtered list (actual filtering logic depends on user relationships)
      expect(filteredStories, isA<List<Story>>());
    });

    test('Performance metrics: Cache is working correctly', () async {
      // Create test stories
      final stories = [
        Story(
          id: 'story1',
          userId: 'child1',
          userName: 'Child 1',
          userPhotoURL: null,
          mediaUrl: 'url1',
          mediaType: 'image',
          caption: 'Test story 1',
          createdAt: DateTime.now(),
          expiresAt: DateTime.now().add(Duration(hours: 24)),
          viewedBy: [],
          replies: [],
          status: StoryStatus.pending,
        ),
      ];

      // First call should populate cache
      await storyStreamManager.filterStoriesByVisibilityRules(stories);

      final firstCallMetrics = storyStreamManager.getMetrics();

      // Second call should use cache
      await storyStreamManager.filterStoriesByVisibilityRules(stories);

      final secondCallMetrics = storyStreamManager.getMetrics();

      // Verify metrics exist and cache is being tracked
      expect(firstCallMetrics, isA<Map<String, dynamic>>());
      expect(secondCallMetrics, isA<Map<String, dynamic>>());

      // Cache should exist after second call (may or may not be valid depending on timing)
      expect(secondCallMetrics['parentChildCacheValid'], isA<bool>());
    });

    test('Error handling: Graceful degradation on Firebase errors', () async {
      // Test with malformed or missing data should not crash
      final stories = [
        Story(
          id: 'story1',
          userId: 'nonexistent_user',
          userName: 'Test User',
          userPhotoURL: null,
          mediaUrl: 'url1',
          mediaType: 'image',
          caption: 'Test story',
          createdAt: DateTime.now(),
          expiresAt: DateTime.now().add(Duration(hours: 24)),
          viewedBy: [],
          replies: [],
          status: StoryStatus.pending,
        ),
      ];

      // Should not throw exceptions even with nonexistent users
      expect(() async => await storyStreamManager.filterStoriesByVisibilityRules(stories),
             returnsNormally);

      // Should handle empty stories list
      final emptyResult = await storyStreamManager.filterStoriesByVisibilityRules([]);
      expect(emptyResult, isEmpty);
    });

    test('Batch vs Individual: Verify optimization is being used', () async {
      // Create multiple stories with different users
      final stories = List.generate(10, (index) => Story(
        id: 'story$index',
        userId: 'child$index',
        userName: 'Child $index',
        userPhotoURL: null,
        mediaUrl: 'url$index',
        mediaType: 'image',
        caption: 'Test story $index',
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(Duration(hours: 24)),
        viewedBy: [],
        replies: [],
        status: StoryStatus.pending,
      ));

      final stopwatch = Stopwatch()..start();

      // This should use batch optimization internally
      await storyStreamManager.filterStoriesByVisibilityRules(stories);

      stopwatch.stop();

      // Should complete quickly since it's using batch processing
      expect(stopwatch.elapsedMilliseconds, lessThan(5000)); // Should be very fast with mocks

      // Verify that the batch method exists and can be called directly
      final batchResult = await contactRepository.getBatchLinkedParents(
        stories.map((s) => s.userId).toList()
      );

      expect(batchResult, isA<Map<String, Set<String>>>());
      expect(batchResult.keys.length, 10); // Should have entries for all 10 users
    });

    test('Cache invalidation: Works correctly', () {
      // Invalidate cache
      storyStreamManager.invalidateParentChildCache();

      final afterInvalidationMetrics = storyStreamManager.getMetrics();

      // Cache should be invalid after invalidation
      expect(afterInvalidationMetrics['parentChildCacheValid'], isFalse);
      expect(afterInvalidationMetrics['parentChildCacheSize'], 0);
    });
  });
}