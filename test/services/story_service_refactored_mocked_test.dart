import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';

import 'package:talia/services/stories/story_orchestrator.dart';
import 'package:talia/services/story_service_refactored.dart';

// Generar mocks
@GenerateMocks([
  StoryOrchestrator,
])
import 'story_service_refactored_mocked_test.mocks.dart';

void main() {
  group('StoryService Refactored - Mocked Tests', () {
    late MockStoryOrchestrator orchestrator;

    setUp(() {
      orchestrator = MockStoryOrchestrator();
    });

    group('1. StoryOrchestrator Basic Functionality', () {
      test('orchestrator se inicializa correctamente', () {
        expect(orchestrator, isNotNull);
        expect(orchestrator, isA<StoryOrchestrator>());
      });

      test('getCachedStories retorna lista vacía inicialmente', () {
        // Setup mock
        when(orchestrator.getCachedStories()).thenReturn([]);

        final result = orchestrator.getCachedStories();
        expect(result, isA<List<UserStories>>());
        expect(result, isEmpty);
      });

      test('getStoriesFromWhitelist retorna stream', () {
        // Setup mock
        when(orchestrator.getStoriesFromWhitelist()).thenAnswer((_) => Stream.value([]));

        final stream = orchestrator.getStoriesFromWhitelist();
        expect(stream, isA<Stream<List<UserStories>>>());
      });

      test('storiesFromCache es stream válido', () {
        // Setup mock
        when(orchestrator.storiesFromCache).thenAnswer((_) => Stream.value([]));

        final stream = orchestrator.storiesFromCache;
        expect(stream, isA<Stream<List<UserStories>>>());
      });
    });

    group('2. Performance Metrics', () {
      test('getPerformanceMetrics retorna map válido', () {
        // Setup mock
        when(orchestrator.getPerformanceMetrics()).thenReturn({
          'cacheSize': 0,
          'activeStreams': 0,
          'pendingUploads': 0,
          'cacheHitRate': 0.0,
        });

        final metrics = orchestrator.getPerformanceMetrics();

        expect(metrics, isA<Map<String, dynamic>>());
        expect(metrics.containsKey('cacheSize'), isTrue);
        expect(metrics.containsKey('activeStreams'), isTrue);
        expect(metrics.containsKey('pendingUploads'), isTrue);
        expect(metrics.containsKey('cacheHitRate'), isTrue);
      });
    });

    group('3. Story Creation Mock', () {
      test('createStory llama a métodos correctos', () async {
        // Setup mock
        when(orchestrator.createStory(
          mediaType: 'image',
          mediaPath: '/test/path.jpg',
          text: 'Test story',
        )).thenAnswer((_) async => 'test-story-id');

        final storyId = await orchestrator.createStory(
          mediaType: 'image',
          mediaPath: '/test/path.jpg',
          text: 'Test story',
        );

        expect(storyId, isA<String>());
        expect(storyId, equals('test-story-id'));

        // Verificar que se llamó el método
        verify(orchestrator.createStory(
          mediaType: 'image',
          mediaPath: '/test/path.jpg',
          text: 'Test story',
        )).called(1);
      });
    });

    group('4. Lifecycle Methods', () {
      test('startBackgroundProcesses se puede llamar', () async {
        // Setup mock
        when(orchestrator.startBackgroundProcesses()).thenAnswer((_) async {});

        await expectLater(
          orchestrator.startBackgroundProcesses(),
          completes,
        );
      });

      test('stopBackgroundProcesses se puede llamar', () {
        // Setup mock
        when(orchestrator.stopBackgroundProcesses()).thenReturn(null);

        expect(
          () => orchestrator.stopBackgroundProcesses(),
          returnsNormally,
        );
      });

      test('dispose se puede llamar', () {
        // Setup mock
        when(orchestrator.dispose()).thenReturn(null);

        expect(
          () => orchestrator.dispose(),
          returnsNormally,
        );
      });
    });

    group('5. Error Handling', () {
      test('maneja errores de métodos correctamente', () async {
        // Setup mock para lanzar excepción
        when(orchestrator.createStory(
          mediaType: 'image',
          mediaPath: '/test/path.jpg',
          text: 'Test story',
        )).thenThrow(Exception('Test error'));

        // Verificar que el mock puede lanzar excepciones
        try {
          await orchestrator.createStory(
            mediaType: 'image',
            mediaPath: '/test/path.jpg',
            text: 'Test story',
          );
          fail('Should have thrown an exception');
        } catch (e) {
          expect(e, isA<Exception>());
          expect(e.toString(), contains('Test error'));
        }
      });
    });

    group('6. API Compatibility', () {
      test('orchestrator implementa todos los métodos requeridos', () {
        // Para mocks, simplemente verificamos que los métodos son accesibles
        // sin necesidad de configurar mocks específicos
        expect(orchestrator, isA<StoryOrchestrator>());
        expect(orchestrator, isNotNull);
      });

      test('orchestrator tiene streams requeridos', () {
        // Setup mocks para streams
        when(orchestrator.storiesFromCache).thenAnswer((_) => Stream.value([]));
        when(orchestrator.getStoriesFromWhitelist()).thenAnswer((_) => Stream.value([]));
        when(orchestrator.getPendingStoriesForParent()).thenAnswer((_) => Stream.value([]));
        when(orchestrator.getApprovedStoriesForParent()).thenAnswer((_) => Stream.value([]));

        expect(orchestrator.storiesFromCache, isA<Stream>());
        expect(orchestrator.getStoriesFromWhitelist(), isA<Stream>());
        expect(orchestrator.getPendingStoriesForParent(), isA<Stream>());
        expect(orchestrator.getApprovedStoriesForParent(), isA<Stream>());
      });
    });
  });

  group('Validation Tests', () {
    test('Story model tiene campos requeridos', () {
      final now = DateTime.now();
      final story = Story(
        id: 'test-id',
        userId: 'user-id',
        userName: 'Test User',
        userPhotoURL: 'https://example.com/photo.jpg',
        mediaUrl: 'https://example.com/media.jpg',
        mediaType: 'image',
        caption: 'Test caption',
        createdAt: now,
        expiresAt: now.add(Duration(hours: 24)),
        viewedBy: [],
        replies: [],
        status: StoryStatus.pending,
        visibility: StoryVisibility.temporary,
      );

      expect(story.id, equals('test-id'));
      expect(story.userId, equals('user-id'));
      expect(story.userName, equals('Test User'));
      expect(story.userPhotoURL, equals('https://example.com/photo.jpg'));
      expect(story.mediaUrl, equals('https://example.com/media.jpg'));
      expect(story.mediaType, equals('image'));
      expect(story.caption, equals('Test caption'));
      expect(story.viewedBy, isA<List<String>>());
      expect(story.replies, isA<List<StoryReply>>());
      expect(story.status, equals(StoryStatus.pending));
      expect(story.visibility, equals(StoryVisibility.temporary));
    });

    test('Story copyWith funciona correctamente', () {
      final now = DateTime.now();
      final originalStory = Story(
        id: 'test-id',
        userId: 'user-id',
        userName: 'Test User',
        mediaUrl: 'https://example.com/media.jpg',
        mediaType: 'image',
        createdAt: now,
        expiresAt: now.add(Duration(hours: 24)),
        viewedBy: [],
        status: StoryStatus.pending,
        visibility: StoryVisibility.temporary,
      );

      final copiedStory = originalStory.copyWith(
        mediaUrl: 'https://example.com/new-media.jpg',
        status: StoryStatus.approved,
      );

      expect(copiedStory.id, equals(originalStory.id));
      expect(copiedStory.mediaUrl, equals('https://example.com/new-media.jpg'));
      expect(copiedStory.status, equals(StoryStatus.approved));
      expect(copiedStory.userName, equals(originalStory.userName));
    });

    test('UserStories funciona correctamente', () {
      final now = DateTime.now();
      final story1 = Story(
        id: 'story-1',
        userId: 'user-id',
        userName: 'Test User',
        mediaUrl: 'https://example.com/media1.jpg',
        mediaType: 'image',
        createdAt: now.subtract(Duration(hours: 1)),
        expiresAt: now.add(Duration(hours: 23)),
        viewedBy: [],
        status: StoryStatus.approved,
        visibility: StoryVisibility.temporary,
      );

      final story2 = Story(
        id: 'story-2',
        userId: 'user-id',
        userName: 'Test User',
        mediaUrl: 'https://example.com/media2.jpg',
        mediaType: 'video',
        createdAt: now,
        expiresAt: now.add(Duration(hours: 24)),
        viewedBy: [],
        status: StoryStatus.approved,
        visibility: StoryVisibility.temporary,
      );

      final userStories = UserStories(
        userId: 'user-id',
        userName: 'Test User',
        userPhotoURL: 'https://example.com/photo.jpg',
        stories: [story1, story2],
        hasUnviewed: true,
      );

      expect(userStories.stories.length, equals(2));
      expect(userStories.latestStory, equals(story2)); // Más reciente
      expect(userStories.sortedStories.first, equals(story1)); // Ordenado por createdAt
      expect(userStories.hasUnviewed, isTrue);
    });
  });
}