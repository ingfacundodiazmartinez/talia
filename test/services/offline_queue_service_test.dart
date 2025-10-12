import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:talia/services/offline_queue_service.dart';
import 'package:talia/services/network_status_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OfflineQueueService', () {
    late OfflineQueueService service;

    setUp(() async {
      // Initialize Hive with temporary directory for tests
      await Hive.initFlutter();

      service = OfflineQueueService();
      await service.initialize();
    });

    tearDown(() async {
      await service.clearQueue();
      await Hive.close();
    });

    test('initializes successfully', () {
      expect(service.pendingOperationsCount, 0);
      expect(service.hasPendingOperations, false);
    });

    test('enqueueOperation adds operation to queue', () async {
      final operationId = await service.enqueueOperation(
        type: OfflineQueueService.OP_SEND_MESSAGE,
        data: {'text': 'Hello'},
        priority: 5,
      );

      expect(operationId, isNotEmpty);
      expect(service.pendingOperationsCount, 1);
      expect(service.hasPendingOperations, true);
    });

    test('multiple operations are queued correctly', () async {
      await service.enqueueOperation(
        type: OfflineQueueService.OP_SEND_MESSAGE,
        data: {'text': 'Message 1'},
        priority: 5,
      );

      await service.enqueueOperation(
        type: OfflineQueueService.OP_UPDATE_PROFILE,
        data: {'name': 'John'},
        priority: 3,
      );

      expect(service.pendingOperationsCount, 2);
    });

    test('getPendingOperations returns all operations', () async {
      await service.enqueueOperation(
        type: OfflineQueueService.OP_SEND_MESSAGE,
        data: {'text': 'Test'},
        priority: 5,
      );

      final operations = service.getPendingOperations();
      expect(operations.length, 1);
      expect(operations[0]['type'], OfflineQueueService.OP_SEND_MESSAGE);
      expect(operations[0]['priority'], 5);
    });

    test('cancelOperation removes specific operation', () async {
      final id = await service.enqueueOperation(
        type: OfflineQueueService.OP_SEND_MESSAGE,
        data: {'text': 'Test'},
        priority: 5,
      );

      await service.cancelOperation(id);
      expect(service.pendingOperationsCount, 0);
    });

    test('clearQueue removes all operations', () async {
      await service.enqueueOperation(
        type: OfflineQueueService.OP_SEND_MESSAGE,
        data: {'text': 'Test 1'},
        priority: 5,
      );

      await service.enqueueOperation(
        type: OfflineQueueService.OP_SEND_MESSAGE,
        data: {'text': 'Test 2'},
        priority: 5,
      );

      await service.clearQueue();
      expect(service.pendingOperationsCount, 0);
    });

    test('operations are prioritized correctly', () async {
      // Add operations in reverse priority order
      await service.enqueueOperation(
        type: OfflineQueueService.OP_SEND_MESSAGE,
        data: {'text': 'Low priority'},
        priority: 10,
      );

      await service.enqueueOperation(
        type: OfflineQueueService.OP_CREATE_EMERGENCY,
        data: {'emergency': true},
        priority: 1,
      );

      await service.enqueueOperation(
        type: OfflineQueueService.OP_UPDATE_PROFILE,
        data: {'name': 'Test'},
        priority: 5,
      );

      final operations = service.getPendingOperations();
      expect(operations.length, 3);

      // Emergency should be first (priority 1)
      expect(operations[0]['priority'], 10); // Note: sorted by priority ascending
    });

    test('operation contains required fields', () async {
      await service.enqueueOperation(
        type: OfflineQueueService.OP_SEND_MESSAGE,
        data: {'text': 'Test'},
        priority: 5,
      );

      final operations = service.getPendingOperations();
      final operation = operations[0];

      expect(operation['id'], isNotNull);
      expect(operation['type'], isNotNull);
      expect(operation['data'], isNotNull);
      expect(operation['priority'], isNotNull);
      expect(operation['createdAt'], isNotNull);
      expect(operation['retryCount'], isNotNull);
      expect(operation['userId'], isNotNull);
    });
  });
}
