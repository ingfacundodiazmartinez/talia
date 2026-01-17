import 'dart:async';
import 'package:talia/services/block_service.dart';
import 'package:talia/services/block_status_cache_service.dart';

/// Mock centralizado del BlockService para tests
class MockBlockService implements BlockService {
  @override
  Future<void> blockContact(String contactId) async {
    // Mock implementation - no actual blocking
  }

  @override
  Future<void> unblockContact(String contactId) async {
    // Mock implementation - no actual unblocking
  }

  @override
  Future<bool> isBlocked(String contactId) async => false;

  @override
  Future<bool> isBlockedBy(String contactId) async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Mock centralizado del BlockStatusCacheService para tests
class MockBlockStatusCacheService implements BlockStatusCacheService {
  final StreamController<BlockStatusChange> _blockStatusController =
      StreamController<BlockStatusChange>.broadcast();
  final Map<String, bool> _mockBlockStatuses = {};

  @override
  Stream<BlockStatusChange> get blockStatusChanges => _blockStatusController.stream;

  @override
  Future<bool> isBlocked(String contactId) async {
    final key = 'blocked_$contactId';
    return _mockBlockStatuses[key] ?? false;
  }

  @override
  Future<bool> isBlockedBy(String contactId) async {
    final key = 'blockedBy_$contactId';
    return _mockBlockStatuses[key] ?? false;
  }

  @override
  void updateBlockStatus(String contactId, bool isBlocked) {
    final key = 'blocked_$contactId';
    _mockBlockStatuses[key] = isBlocked;

    _blockStatusController.add(BlockStatusChange(
      contactId: contactId,
      isBlocked: isBlocked,
      timestamp: DateTime.now(),
    ));
  }

  // Método adicional para tests que necesitan simular comportamiento bidireccional
  @override
  void handleBlockStatusChange(String contactId, bool isBlocked, {bool isBlockedBy = false}) {
    final key = isBlockedBy ? 'blockedBy_$contactId' : 'blocked_$contactId';
    _mockBlockStatuses[key] = isBlocked;

    _blockStatusController.add(BlockStatusChange(
      contactId: contactId,
      isBlocked: isBlocked,
      timestamp: DateTime.now(),
    ));
  }

  @override
  void dispose() {
    _blockStatusController.close();
    _mockBlockStatuses.clear();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}