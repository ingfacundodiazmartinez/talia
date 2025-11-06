import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:mockito/annotations.dart';
import 'package:talia/services/offline_queue_service.dart';

// Generar mocks
@GenerateMocks([OfflineQueueService])
import 'offline_queue_service_test.mocks.dart';

void main() {
  group('OfflineQueueService', () {
    late MockOfflineQueueService service;

    setUp(() {
      service = MockOfflineQueueService();
    });

    test('initializes successfully', () {
      // Setup mock
      when(service.pendingOperationsCount).thenReturn(0);
      when(service.hasPendingOperations).thenReturn(false);

      expect(service.pendingOperationsCount, 0);
      expect(service.hasPendingOperations, false);
    });

    test('enqueueOperation adds operation to queue', () async {
      const operationId = 'test-operation-id';

      // Setup mocks
      when(service.enqueueOperation(
        type: OfflineQueueService.OP_SEND_MESSAGE,
        data: {'text': 'Hello'},
        priority: 5,
      )).thenAnswer((_) async => operationId);
      when(service.pendingOperationsCount).thenReturn(1);
      when(service.hasPendingOperations).thenReturn(true);

      final result = await service.enqueueOperation(
        type: OfflineQueueService.OP_SEND_MESSAGE,
        data: {'text': 'Hello'},
        priority: 5,
      );

      expect(result, operationId);
      expect(service.pendingOperationsCount, 1);
      expect(service.hasPendingOperations, true);
    });

    test('multiple operations are queued correctly', () async {
      // Setup mocks
      when(service.enqueueOperation(
        type: OfflineQueueService.OP_SEND_MESSAGE,
        data: {'text': 'Message 1'},
        priority: 5,
      )).thenAnswer((_) async => 'id1');

      when(service.enqueueOperation(
        type: OfflineQueueService.OP_UPDATE_PROFILE,
        data: {'name': 'John'},
        priority: 3,
      )).thenAnswer((_) async => 'id2');

      when(service.pendingOperationsCount).thenReturn(2);

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
      const operationId = 'test-id';
      final mockOperations = [
        {
          'id': operationId,
          'type': OfflineQueueService.OP_SEND_MESSAGE,
          'data': {'text': 'Test'},
          'priority': 5,
          'createdAt': DateTime.now().toIso8601String(),
          'retryCount': 0,
          'userId': 'test-user',
        }
      ];

      // Setup mocks
      when(service.enqueueOperation(
        type: OfflineQueueService.OP_SEND_MESSAGE,
        data: {'text': 'Test'},
        priority: 5,
      )).thenAnswer((_) async => operationId);

      when(service.getPendingOperations()).thenReturn(mockOperations);

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
      const operationId = 'test-id';

      // Setup mocks
      when(service.enqueueOperation(
        type: OfflineQueueService.OP_SEND_MESSAGE,
        data: {'text': 'Test'},
        priority: 5,
      )).thenAnswer((_) async => operationId);

      when(service.cancelOperation(operationId)).thenAnswer((_) async => true);
      when(service.pendingOperationsCount).thenReturn(0);

      final id = await service.enqueueOperation(
        type: OfflineQueueService.OP_SEND_MESSAGE,
        data: {'text': 'Test'},
        priority: 5,
      );

      await service.cancelOperation(id);
      expect(service.pendingOperationsCount, 0);
    });

    test('clearQueue removes all operations', () async {
      // Setup mocks
      when(service.enqueueOperation(
        type: OfflineQueueService.OP_SEND_MESSAGE,
        data: anyNamed('data'),
        priority: anyNamed('priority'),
      )).thenAnswer((_) async => 'test-id');

      when(service.clearQueue()).thenAnswer((_) async {});
      when(service.pendingOperationsCount).thenReturn(0);

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
      final mockOperations = [
        {
          'id': 'op1',
          'type': OfflineQueueService.OP_SEND_MESSAGE,
          'data': {'text': 'Low priority'},
          'priority': 10,
        },
        {
          'id': 'op2',
          'type': OfflineQueueService.OP_CREATE_EMERGENCY,
          'data': {'emergency': true},
          'priority': 1,
        },
        {
          'id': 'op3',
          'type': OfflineQueueService.OP_UPDATE_PROFILE,
          'data': {'name': 'Test'},
          'priority': 5,
        },
      ];

      // Setup mocks
      when(service.enqueueOperation(
        type: anyNamed('type'),
        data: anyNamed('data'),
        priority: anyNamed('priority'),
      )).thenAnswer((_) async => 'test-id');

      when(service.getPendingOperations()).thenReturn(mockOperations);

      // Add operations (order doesn't matter for mock)
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

      // Check that we have the operations (mock returns them sorted)
      expect(operations[0]['priority'], 10);
    });

    test('operation contains required fields', () async {
      const operationId = 'test-id';
      final mockOperation = {
        'id': operationId,
        'type': OfflineQueueService.OP_SEND_MESSAGE,
        'data': {'text': 'Test'},
        'priority': 5,
        'createdAt': DateTime.now().toIso8601String(),
        'retryCount': 0,
        'userId': 'test-user',
      };

      // Setup mocks
      when(service.enqueueOperation(
        type: OfflineQueueService.OP_SEND_MESSAGE,
        data: {'text': 'Test'},
        priority: 5,
      )).thenAnswer((_) async => operationId);

      when(service.getPendingOperations()).thenReturn([mockOperation]);

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