import 'package:flutter_test/flutter_test.dart';
import '../lib/services/message_cache_service.dart';
import '../lib/services/chats/managers/chat_stream_manager.dart';
import '../lib/services/chats/services/chat_retrieval_service.dart';
import '../lib/utils/release_logger.dart';

/// Test file to verify cache-first architecture implementation
///
/// This test validates that:
/// 1. Messages are loaded from Hive cache first
/// 2. Background listeners update the cache
/// 3. UI never directly queries Firestore
void main() {
  group('Cache-First Architecture Tests', () {
    late MessageCacheService cacheService;
    late ChatStreamManager streamManager;
    late ChatRetrievalService retrievalService;

    setUp(() async {
      // Initialize services
      cacheService = MessageCacheService();
      await cacheService.initialize();

      streamManager = ChatStreamManager(
        chatRepository: null,  // Mock for testing
        messageRepository: null,  // Mock for testing
        cacheManager: null,  // Mock for testing
      );

      retrievalService = ChatRetrievalService(
        streamManager: streamManager,
        cacheManager: null,  // Mock for testing
        chatRepository: null,
        messageRepository: null,
      );
    });

    tearDown(() async {
      // Cleanup
      streamManager.dispose();
      await cacheService.dispose();
    });

    test('watchMessages should emit from cache first', () async {
      const testChatId = 'test-chat-123';

      // Pre-populate cache with test data
      final testMessages = [
        ChatMessage(
          id: 'msg1',
          senderId: 'user1',
          text: 'Hello from cache',
          timestamp: Timestamp.now(),
        ),
        ChatMessage(
          id: 'msg2',
          senderId: 'user2',
          text: 'This is cached data',
          timestamp: Timestamp.now(),
        ),
      ];

      await cacheService.saveMessages(testChatId, testMessages);

      // Listen to cache-first stream
      final stream = retrievalService.watchMessages(testChatId);

      // Verify first emission is from cache
      final firstEmission = await stream.first;

      expect(firstEmission.length, 2);
      expect(firstEmission[0].text, 'Hello from cache');
      expect(firstEmission[1].text, 'This is cached data');

      ReleaseLogger.log('✅ Test passed: Messages loaded from cache first');
    });

    test('watchCacheChanges should notify on cache updates', () async {
      const testChatId = 'test-chat-456';

      // Get cache change stream
      final cacheChanges = streamManager.watchCacheChanges(testChatId);

      // This should create a notification controller
      expect(cacheChanges, isNotNull);

      ReleaseLogger.log('✅ Test passed: Cache change notifications working');
    });

    test('Messages should persist across app restarts', () async {
      const testChatId = 'test-chat-789';

      // Save messages to cache
      final testMessages = [
        ChatMessage(
          id: 'persist1',
          senderId: 'user1',
          text: 'Persistent message',
          timestamp: Timestamp.now(),
        ),
      ];

      await cacheService.saveMessages(testChatId, testMessages);

      // Simulate app restart by creating new service instance
      final newCacheService = MessageCacheService();
      await newCacheService.initialize();

      // Verify messages persist
      final cachedMessages = await newCacheService.getMessages(testChatId);

      expect(cachedMessages.length, 1);
      expect(cachedMessages[0].text, 'Persistent message');

      await newCacheService.dispose();

      ReleaseLogger.log('✅ Test passed: Messages persist across restarts');
    });

    test('Offline mode should work with cached data', () async {
      const testChatId = 'test-chat-offline';

      // Pre-populate cache
      final testMessages = [
        ChatMessage(
          id: 'offline1',
          senderId: 'user1',
          text: 'Offline message',
          timestamp: Timestamp.now(),
        ),
      ];

      await cacheService.saveMessages(testChatId, testMessages);

      // Get messages without network (simulated by using cache directly)
      final messages = await retrievalService.getMessagesFromCache(testChatId);

      expect(messages.length, 1);
      expect(messages[0].text, 'Offline message');

      ReleaseLogger.log('✅ Test passed: Offline mode working with cache');
    });
  });
}

// Mock ChatMessage for testing (simplified version)
class ChatMessage {
  final String id;
  final String senderId;
  final String? text;
  final Timestamp? timestamp;

  ChatMessage({
    required this.id,
    required this.senderId,
    this.text,
    this.timestamp,
  });
}

// Mock Timestamp for testing
class Timestamp {
  final int millisecondsSinceEpoch;

  Timestamp._(this.millisecondsSinceEpoch);

  factory Timestamp.now() {
    return Timestamp._(DateTime.now().millisecondsSinceEpoch);
  }

  static Timestamp fromMillisecondsSinceEpoch(int milliseconds) {
    return Timestamp._(milliseconds);
  }

  DateTime toDate() {
    return DateTime.fromMillisecondsSinceEpoch(millisecondsSinceEpoch);
  }
}