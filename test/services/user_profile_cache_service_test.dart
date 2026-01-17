import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:talia/services/user_profile_cache_service.dart';

// Generar mocks
@GenerateMocks([UserProfileCacheService])
import 'user_profile_cache_service_test.mocks.dart';

void main() {
  group('UserProfileCacheService', () {
    late MockUserProfileCacheService service;

    setUp(() {
      service = MockUserProfileCacheService();
    });

    test('getUserProfile returns null for non-existent user', () async {
      // Setup mock to return null for non-existent user
      when(service.getUserProfile('non_existent_user'))
          .thenAnswer((_) async => null);

      final profile = await service.getUserProfile('non_existent_user');
      expect(profile, isNull);
      verify(service.getUserProfile('non_existent_user')).called(1);
    });

    test('getUserProfile returns cached profile on second call', () async {
      final userId = 'test_user_123';
      final mockProfile = {
        'id': userId,
        'name': 'Test User',
        'email': 'test@example.com',
        'photoURL': 'https://example.com/photo.jpg',
      };

      // Setup mock to return same profile data
      when(service.getUserProfile(userId))
          .thenAnswer((_) async => mockProfile);

      // First call
      final profile1 = await service.getUserProfile(userId);

      // Second call
      final profile2 = await service.getUserProfile(userId);

      // Both should have same data
      expect(profile1, isNotNull);
      expect(profile2, isNotNull);
      expect(profile1, equals(profile2));
      verify(service.getUserProfile(userId)).called(2);
    });

    test('invalidateUser removes user from cache', () {
      final userId = 'test_user';

      // Setup mock to not throw
      when(service.invalidateUser(userId)).thenReturn(null);

      service.invalidateUser(userId);

      // Should not throw error even if user wasn't cached
      expect(() => service.invalidateUser(userId), returnsNormally);
      verify(service.invalidateUser(userId)).called(2);
    });

    test('clearCache clears entire cache', () {
      // Setup mock to not throw
      when(service.clearCache()).thenReturn(null);

      service.clearCache();

      // Should not throw error
      expect(() => service.clearCache(), returnsNormally);
      verify(service.clearCache()).called(2);
    });

    test('preloadProfiles handles empty list', () async {
      // Setup mock to complete without error
      when(service.preloadProfiles([]))
          .thenAnswer((_) async {});

      await service.preloadProfiles([]);

      // Should complete without error
      verify(service.preloadProfiles([])).called(1);
    });

    test('preloadProfiles handles multiple user IDs', () async {
      final userIds = ['user1', 'user2', 'user3'];

      // Setup mock to complete without error
      when(service.preloadProfiles(userIds))
          .thenAnswer((_) async {});

      // Should not throw error
      await expectLater(
        service.preloadProfiles(userIds),
        completes,
      );

      verify(service.preloadProfiles(userIds)).called(1);
    });
  });
}
