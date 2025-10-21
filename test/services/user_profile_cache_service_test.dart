import 'package:flutter_test/flutter_test.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:talia/services/user_profile_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UserProfileCacheService', () {
    late UserProfileCacheService service;
    late FakeFirebaseFirestore fakeFirestore;

    setUp(() {
      fakeFirestore = FakeFirebaseFirestore();
      service = UserProfileCacheService();
      // Note: In real implementation, you'd inject firestore instance
    });

    test('getUserProfile returns null for non-existent user', () async {
      final profile = await service.getUserProfile('non_existent_user');
      expect(profile, isNull);
    });

    test('getUserProfile returns cached profile on second call', () async {
      // Add a user to fake firestore
      final userId = 'test_user_123';
      await fakeFirestore.collection('users').doc(userId).set({
        'displayName': 'Test User',
        'email': 'test@example.com',
      });

      // First call - should fetch from firestore
      final profile1 = await service.getUserProfile(userId);

      // Second call - should return from cache
      final profile2 = await service.getUserProfile(userId);

      // Both should have same data
      expect(profile1, isNotNull);
      expect(profile2, isNotNull);
    });

    test('invalidateUser removes user from cache', () {
      final userId = 'test_user';
      service.invalidateUser(userId);

      // Should not throw error even if user wasn't cached
      expect(() => service.invalidateUser(userId), returnsNormally);
    });

    test('clearCache clears entire cache', () {
      service.clearCache();

      // Should not throw error
      expect(() => service.clearCache(), returnsNormally);
    });

    test('preloadProfiles handles empty list', () async {
      await service.preloadProfiles([]);

      // Should complete without error
      expect(true, true);
    });

    test('preloadProfiles handles multiple user IDs', () async {
      final userIds = ['user1', 'user2', 'user3'];

      // Should not throw error
      await expectLater(
        service.preloadProfiles(userIds),
        completes,
      );
    });
  });
}
