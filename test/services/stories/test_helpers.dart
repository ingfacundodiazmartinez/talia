import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:talia/models/story.dart';
import 'test_firebase_setup.dart';

/// Helpers centralizados para tests de stories
/// Implementa principio DRY para eliminar código duplicado

/// Helper para crear historias de prueba con valores por defecto
class StoryTestHelper {
  /// Crea una historia básica con parámetros por defecto
  static Story createTestStory({
    String id = 'test_story_1',
    String userId = 'test_user_1',
    String userName = 'Test User',
    String? userPhotoURL,
    String mediaUrl = 'https://example.com/media.jpg',
    String mediaType = 'image',
    String caption = 'Test story',
    DateTime? createdAt,
    DateTime? expiresAt,
    List<String> viewedBy = const [],
    List<StoryReply> replies = const [],
    StoryStatus status = StoryStatus.approved,
  }) {
    final now = DateTime.now();
    return Story(
      id: id,
      userId: userId,
      userName: userName,
      userPhotoURL: userPhotoURL,
      mediaUrl: mediaUrl,
      mediaType: mediaType,
      caption: caption,
      createdAt: createdAt ?? now,
      expiresAt: expiresAt ?? now.add(Duration(hours: 24)),
      viewedBy: viewedBy,
      replies: replies,
      status: status,
    );
  }

  /// Crea múltiples historias para un usuario
  static List<Story> createUserStories({
    required String userId,
    required String userName,
    int count = 3,
    StoryStatus status = StoryStatus.approved,
    DateTime? baseTime,
  }) {
    final stories = <Story>[];
    final now = baseTime ?? DateTime.now();

    for (int i = 0; i < count; i++) {
      stories.add(createTestStory(
        id: '${userId}_story_$i',
        userId: userId,
        userName: userName,
        caption: '$userName story $i',
        createdAt: now.add(Duration(minutes: i * 10)),
        status: status,
      ));
    }

    return stories;
  }

  /// Crea un UserStories completo
  static UserStories createUserStoriesGroup({
    required String userId,
    required String userName,
    String? userPhotoURL,
    int storyCount = 3,
    bool hasUnviewed = true,
    StoryStatus status = StoryStatus.approved,
  }) {
    final stories = createUserStories(
      userId: userId,
      userName: userName,
      count: storyCount,
      status: status,
    );

    return UserStories(
      userId: userId,
      userName: userName,
      userPhotoURL: userPhotoURL,
      stories: stories,
      hasUnviewed: hasUnviewed,
    );
  }

  /// Convierte Story a Map para Firestore
  static Map<String, dynamic> storyToFirestoreMap(Story story) {
    return {
      'id': story.id,
      'userId': story.userId,
      'userName': story.userName,
      'userPhotoURL': story.userPhotoURL,
      'mediaUrl': story.mediaUrl,
      'mediaType': story.mediaType,
      'caption': story.caption,
      'createdAt': Timestamp.fromDate(story.createdAt),
      'expiresAt': Timestamp.fromDate(story.expiresAt),
      'viewedBy': story.viewedBy,
      'replies': story.replies.map((reply) => {
        'text': reply.text,
        'userId': reply.userId,
        'userName': reply.userName,
        'userPhotoURL': reply.userPhotoURL,
        'timestamp': Timestamp.fromDate(reply.timestamp),
      }).toList(),
      'status': story.status.toString().split('.').last,
    };
  }
}

/// Helper para configurar datos de prueba en Firestore
class FirestoreTestHelper {
  /// Agrega una historia a Firestore mock
  static Future<void> addStoryToFirestore(
    FakeFirebaseFirestore firestore,
    Story story,
  ) async {
    await firestore
        .collection('stories')
        .doc(story.id)
        .set(StoryTestHelper.storyToFirestoreMap(story));
  }

  /// Agrega múltiples historias a Firestore mock
  static Future<void> addStoriesToFirestore(
    FakeFirebaseFirestore firestore,
    List<Story> stories,
  ) async {
    for (final story in stories) {
      await addStoryToFirestore(firestore, story);
    }
  }

  /// Crea un usuario en Firestore mock
  static Future<void> createTestUser(
    FakeFirebaseFirestore firestore, {
    required String userId,
    required String name,
    required String email,
    String role = 'parent',
    List<String> linkedChildrenIds = const [],
    String? photoURL,
  }) async {
    await firestore.collection('users').doc(userId).set({
      'name': name,
      'email': email,
      'photoURL': photoURL,
      'role': role,
      'linkedChildrenIds': linkedChildrenIds,
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Crea múltiples usuarios de prueba con relaciones padre-hijo
  static Future<void> setupTestUsers(
    FakeFirebaseFirestore firestore,
  ) async {
    // Padres
    await createTestUser(
      firestore,
      userId: 'parent1',
      name: 'Parent 1',
      email: 'parent1@example.com',
      role: 'parent',
      linkedChildrenIds: ['child1', 'child2'],
    );

    await createTestUser(
      firestore,
      userId: 'parent2',
      name: 'Parent 2',
      email: 'parent2@example.com',
      role: 'parent',
      linkedChildrenIds: ['child2', 'child3'],
    );

    // Hijos
    await createTestUser(
      firestore,
      userId: 'child1',
      name: 'Child 1',
      email: 'child1@example.com',
      role: 'child',
    );

    await createTestUser(
      firestore,
      userId: 'child2',
      name: 'Child 2',
      email: 'child2@example.com',
      role: 'child',
    );

    await createTestUser(
      firestore,
      userId: 'child3',
      name: 'Child 3',
      email: 'child3@example.com',
      role: 'child',
    );
  }

  /// Crea contactos de prueba
  static Future<void> setupTestContacts(
    FakeFirebaseFirestore firestore,
  ) async {
    await firestore.collection('contacts').doc('contact1').set({
      'users': ['parent1', 'child1'],
      'status': 'approved',
      'createdAt': FieldValue.serverTimestamp(),
    });

    await firestore.collection('contacts').doc('contact2').set({
      'users': ['parent1', 'child2'],
      'status': 'approved',
      'createdAt': FieldValue.serverTimestamp(),
    });

    await firestore.collection('contacts').doc('contact3').set({
      'users': ['parent2', 'child2'],
      'status': 'approved',
      'createdAt': FieldValue.serverTimestamp(),
    });

    await firestore.collection('contacts').doc('contact4').set({
      'users': ['parent2', 'child3'],
      'status': 'approved',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }

  /// Setup completo de datos de prueba
  static Future<void> setupCompleteTestData(
    FakeFirebaseFirestore firestore,
  ) async {
    await setupTestUsers(firestore);
    await setupTestContacts(firestore);

    // Crear historias para cada hijo
    final child1Stories = StoryTestHelper.createUserStories(
      userId: 'child1',
      userName: 'Child 1',
      count: 2,
    );

    final child2Stories = StoryTestHelper.createUserStories(
      userId: 'child2',
      userName: 'Child 2',
      count: 3,
    );

    final child3Stories = StoryTestHelper.createUserStories(
      userId: 'child3',
      userName: 'Child 3',
      count: 1,
    );

    await addStoriesToFirestore(firestore, child1Stories);
    await addStoriesToFirestore(firestore, child2Stories);
    await addStoriesToFirestore(firestore, child3Stories);
  }
}

/// Helper para crear mocks de usuario
class UserTestHelper {
  /// Crea un MockUser con valores por defecto
  static MockUser createMockUser({
    String uid = 'test_user_id',
    String email = 'test@example.com',
    String displayName = 'Test User',
    String? phoneNumber,
    String? photoURL,
    bool isAnonymous = false,
  }) {
    return MockUser(
      uid: uid,
      email: email,
      displayName: displayName,
      phoneNumber: phoneNumber,
      photoURL: photoURL,
      isAnonymous: isAnonymous,
    );
  }

  /// Crea MockFirebaseAuth con usuario autenticado
  static MockFirebaseAuth createMockAuth({
    MockUser? mockUser,
    bool signedIn = true,
  }) {
    final user = mockUser ?? createMockUser();
    return MockFirebaseAuth(
      mockUser: user,
      signedIn: signedIn,
    );
  }
}

/// Helper para verificaciones comunes en tests
class TestVerificationHelper {
  /// Verifica que una historia existe en Firestore
  static Future<void> verifyStoryExistsInFirestore(
    FakeFirebaseFirestore firestore,
    String storyId,
  ) async {
    final doc = await firestore.collection('stories').doc(storyId).get();
    if (!doc.exists) {
      throw Exception('Story $storyId does not exist in Firestore');
    }
  }

  /// Verifica que un usuario está en viewedBy de una historia
  static Future<void> verifyUserViewedStory(
    FakeFirebaseFirestore firestore,
    String storyId,
    String userId,
  ) async {
    final doc = await firestore.collection('stories').doc(storyId).get();
    final viewedBy = List<String>.from(doc.data()!['viewedBy']);
    if (!viewedBy.contains(userId)) {
      throw Exception('User $userId has not viewed story $storyId');
    }
  }

  /// Verifica que un stream emite datos sin timeout
  static Future<T> verifyStreamEmitsData<T>(
    Stream<T> stream, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    return await stream.timeout(timeout).first;
  }

  /// Verifica que una operación se completa rápidamente
  static Future<void> verifyOperationPerformance(
    Future<void> operation, {
    int maxMilliseconds = 500,
  }) async {
    final stopwatch = Stopwatch()..start();
    await operation;
    stopwatch.stop();

    if (stopwatch.elapsedMilliseconds > maxMilliseconds) {
      throw Exception(
        'Operation took ${stopwatch.elapsedMilliseconds}ms, '
        'expected less than ${maxMilliseconds}ms'
      );
    }
  }
}

/// Helper para configuración común de tests
class TestSetupHelper {
  /// Configuración estándar de servicios para tests
  static Future<TestServices> setupStandardTestServices() async {
    final mockFirestore = FakeFirebaseFirestore();
    final mockUser = UserTestHelper.createMockUser();
    final mockAuth = UserTestHelper.createMockAuth(mockUser: mockUser);
    final mockFunctions = MockFirebaseFunctions();

    await FirestoreTestHelper.setupCompleteTestData(mockFirestore);

    return TestServices(
      firestore: mockFirestore,
      auth: mockAuth,
      user: mockUser,
      functions: mockFunctions,
    );
  }

  /// Limpia datos entre tests
  static Future<void> cleanupAfterTest(FakeFirebaseFirestore firestore) async {
    try {
      await firestore.clearPersistence();
    } catch (e) {
      // Ignorar errores de limpieza
    }
  }
}

/// Container para servicios de test
class TestServices {
  final FakeFirebaseFirestore firestore;
  final MockFirebaseAuth auth;
  final MockUser user;
  final MockFirebaseFunctions functions;

  TestServices({
    required this.firestore,
    required this.auth,
    required this.user,
    required this.functions,
  });
}

/// Helper para timing en tests
class TimingTestHelper {
  /// Espera con timeout configurable
  static Future<void> waitWithTimeout({
    Duration delay = const Duration(milliseconds: 100),
    Duration timeout = const Duration(seconds: 5),
  }) async {
    await Future.delayed(delay).timeout(timeout);
  }

  /// Ejecuta operación con timeout y métricas
  static Future<OperationResult<T>> executeWithMetrics<T>(
    Future<T> operation, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final stopwatch = Stopwatch()..start();

    try {
      final result = await operation.timeout(timeout);
      stopwatch.stop();

      return OperationResult<T>(
        result: result,
        elapsedMs: stopwatch.elapsedMilliseconds,
        success: true,
      );
    } catch (e) {
      stopwatch.stop();

      return OperationResult<T>(
        result: null,
        elapsedMs: stopwatch.elapsedMilliseconds,
        success: false,
        error: e,
      );
    }
  }
}

/// Resultado de operación con métricas
class OperationResult<T> {
  final T? result;
  final int elapsedMs;
  final bool success;
  final dynamic error;

  OperationResult({
    required this.result,
    required this.elapsedMs,
    required this.success,
    this.error,
  });
}