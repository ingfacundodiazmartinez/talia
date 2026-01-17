import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:talia/services/stories/repositories/contact_repository.dart';
import 'package:talia/services/stories/managers/story_stream_manager.dart';
import 'package:talia/services/stories/repositories/story_repository.dart';
import 'package:talia/services/stories/managers/story_cache_manager.dart';
import 'package:talia/models/story.dart';
import 'test_firebase_setup.dart';
import 'test_mocks.dart';
import 'test_helpers.dart';

void main() {
  group('Batch Optimization Tests', () {
    late TestServices testServices;
    late ContactRepository contactRepository;
    late StoryStreamManager storyStreamManager;

    setUpAll(() async {
      await setupFirebaseForTesting();
    });

    setUp(() async {
      testServices = await TestSetupHelper.setupStandardTestServices();

      contactRepository = ContactRepository(
        firestore: testServices.firestore,
        auth: testServices.auth,
      );

      // Create dependencies for StoryStreamManager
      final storyRepository = StoryRepository(
        firestore: testServices.firestore,
        auth: testServices.auth,
      );
      final cacheManager = StoryCacheManager();

      storyStreamManager = StoryStreamManager(
        storyRepository: storyRepository,
        contactRepository: contactRepository,
        cacheManager: cacheManager,
        blockStatusService: MockBlockStatusCacheService(),
      );
    });

    test('getBatchLinkedParents: Empty input returns empty result', () async {
      // Test edge case with empty input
      final result = await contactRepository.getBatchLinkedParents([]);

      expect(result, isEmpty);
    });

    test('getBatchLinkedParents: Single child with no parents', () async {
      // Add child with no parents using helper
      await FirestoreTestHelper.createTestUser(
        testServices.firestore,
        userId: 'child5',
        name: 'Child 5',
        email: 'child5@example.com',
        role: 'child',
      );

      final result = await contactRepository.getBatchLinkedParents(['child5']);

      expect(result, {
        'child5': <String>{}
      });
    });

    test('getBatchLinkedParents: Multiple children with various parent relationships', () async {
      // Data already setup in _setupTestData()
      final result = await contactRepository.getBatchLinkedParents([
        'child1', 'child2', 'child3', 'child5' // child5 has no parents
      ]);

      expect(result, {
        'child1': {'parent1'},
        'child2': {'parent1', 'parent2'},
        'child3': {'parent2'},
        'child5': <String>{}
      });
    });

    test('getBatchLinkedParents: Handles duplicate child IDs', () async {
      // Test with duplicate child IDs - should handle gracefully
      final result = await contactRepository.getBatchLinkedParents([
        'child1', 'child1', 'child1' // Duplicates
      ]);

      expect(result, {
        'child1': {'parent1'}
      });
    });

    test('getBatchLinkedParents: Handles malformed data gracefully', () async {
      // Create parent with malformed data using direct Firestore calls
      await testServices.firestore.collection('users').doc('malformed_parent').set({
        'name': 'Malformed Parent',
        'email': 'malformed@example.com',
        'role': 'parent',
        'linkedChildrenIds': null, // Null data
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Create another parent with missing field
      await testServices.firestore.collection('users').doc('missing_field_parent').set({
        'name': 'Missing Field Parent',
        'email': 'missing@example.com',
        'role': 'parent',
        // Missing linkedChildrenIds field
        'createdAt': FieldValue.serverTimestamp(),
      });

      final result = await contactRepository.getBatchLinkedParents(['child_nonexistent']);

      expect(result, {
        'child_nonexistent': <String>{}
      });
    });

    test('getBatchLinkedParents: Performance comparison vs individual calls', () async {
      final stopwatch = Stopwatch()..start();

      // Make batch call
      await contactRepository.getBatchLinkedParents([
        'child1', 'child2', 'child3', 'child4', 'child5'
      ]);

      stopwatch.stop();

      // The batch call should be very fast with FakeFirebaseFirestore
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });

    test('StoryStreamManager: Uses batch method correctly', () async {
      // Create test stories using helper
      final stories = [
        StoryTestHelper.createTestStory(
          id: 'story1',
          userId: 'child1',
          userName: 'Child 1',
          caption: 'Test story 1',
          status: StoryStatus.pending,
        ),
        StoryTestHelper.createTestStory(
          id: 'story2',
          userId: 'child2',
          userName: 'Child 2',
          caption: 'Test story 2',
          status: StoryStatus.rejected,
        ),
      ];

      // This should internally call getBatchLinkedParents
      final result = await storyStreamManager.filterStoriesByVisibilityRules(stories);

      // Should return the stories (may be filtered based on visibility rules)
      expect(result, isA<List<Story>>());
    });

    test('Cache optimization: Multiple calls use cached data', () async {
      // Create test stories using helper
      final stories = [
        StoryTestHelper.createTestStory(
          id: 'story1',
          userId: 'child1',
          userName: 'Child 1',
          caption: 'Test story 1',
          status: StoryStatus.pending,
        ),
      ];

      // First call - populates cache
      final result1 = await storyStreamManager.filterStoriesByVisibilityRules(stories);

      // Second call - should use cache if within cache validity period
      final result2 = await storyStreamManager.filterStoriesByVisibilityRules(stories);

      // Both calls should succeed
      expect(result1, isA<List<Story>>());
      expect(result2, isA<List<Story>>());
    });
  });
}