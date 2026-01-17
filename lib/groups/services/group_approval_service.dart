import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/models.dart';
import '../repositories/repositories.dart';
import '../../utils/release_logger.dart';

/// Service for group approval operations
///
/// Handles parent approval flow for child group membership.
class GroupApprovalService {
  final GroupApprovalRepository _repository;
  final FirebaseFunctions _functions;
  final FirebaseAuth _auth;

  GroupApprovalService({
    GroupApprovalRepository? repository,
    FirebaseFunctions? functions,
    FirebaseAuth? auth,
  })  : _repository = repository ?? GroupApprovalRepository(),
        _functions = functions ?? FirebaseFunctions.instance,
        _auth = auth ?? FirebaseAuth.instance;

  String get _currentUserId => _auth.currentUser?.uid ?? '';

  // ═══════════════════════════════════════════════════════════════
  // QUERIES
  // ═══════════════════════════════════════════════════════════════

  /// Get pending approval requests for current user (parent)
  Future<List<GroupApprovalRequest>> getPendingRequests() async {
    final userId = _currentUserId;
    if (userId.isEmpty) {
      ReleaseLogger.warning(
        'No user authenticated, returning empty list',
        tag: 'GroupApprovalService',
      );
      return [];
    }
    return _repository.getPendingRequestsForParent(userId);
  }

  /// Watch pending approval requests
  Stream<List<GroupApprovalRequest>> watchPendingRequests() {
    final userId = _currentUserId;
    if (userId.isEmpty) {
      ReleaseLogger.warning(
        'No user authenticated, returning empty stream',
        tag: 'GroupApprovalService',
      );
      return Stream.value([]);
    }
    return _repository.watchPendingRequestsForParent(userId);
  }

  /// Get count of pending requests
  Future<int> getPendingCount() async {
    return _repository.getPendingRequestCountForParent(_currentUserId);
  }

  /// Watch count of pending requests
  Stream<int> watchPendingCount() {
    return _repository.watchPendingRequestCountForParent(_currentUserId);
  }

  /// Get a specific request by ID
  Future<GroupApprovalRequest?> getRequest(String requestId) async {
    return _repository.getById(requestId);
  }

  /// Watch a specific request
  Stream<GroupApprovalRequest?> watchRequest(String requestId) {
    return _repository.watchById(requestId);
  }

  /// Get all requests (including processed) for a child
  Future<List<GroupApprovalRequest>> getRequestsForChild(String childId) async {
    return _repository.getRequestsForChild(childId);
  }

  /// Get request history for current parent
  Future<List<GroupApprovalRequest>> getRequestHistory({int? limit}) async {
    return _repository.getAllRequestsForParent(_currentUserId, limit: limit);
  }

  // ═══════════════════════════════════════════════════════════════
  // ACTIONS
  // ═══════════════════════════════════════════════════════════════

  /// Approve a group membership request
  Future<bool> approveRequest(String requestId) async {
    try {
      ReleaseLogger.log(
        'Approving request: $requestId',
        tag: 'GroupApprovalService',
      );

      final callable = _functions.httpsCallable('approveGroupMembership');
      final result = await callable.call({
        'requestId': requestId,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      final success = data['success'] as bool? ?? false;

      if (success) {
        ReleaseLogger.log(
          'Request approved successfully',
          tag: 'GroupApprovalService',
        );
      }

      return success;
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error(
        'Error approving request: ${e.message}',
        tag: 'GroupApprovalService',
      );
      return false;
    } catch (e) {
      ReleaseLogger.error(
        'Error approving request: $e',
        tag: 'GroupApprovalService',
      );
      return false;
    }
  }

  /// Reject a group membership request
  Future<bool> rejectRequest(String requestId) async {
    try {
      ReleaseLogger.log(
        'Rejecting request: $requestId',
        tag: 'GroupApprovalService',
      );

      final callable = _functions.httpsCallable('rejectGroupMembership');
      final result = await callable.call({
        'requestId': requestId,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      final success = data['success'] as bool? ?? false;

      if (success) {
        ReleaseLogger.log(
          'Request rejected successfully',
          tag: 'GroupApprovalService',
        );
      }

      return success;
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error(
        'Error rejecting request: ${e.message}',
        tag: 'GroupApprovalService',
      );
      return false;
    } catch (e) {
      ReleaseLogger.error(
        'Error rejecting request: $e',
        tag: 'GroupApprovalService',
      );
      return false;
    }
  }

  /// Revoke child's membership from a group
  Future<bool> revokeChildMembership({
    required String groupId,
    required String childId,
  }) async {
    try {
      ReleaseLogger.log(
        'Revoking child $childId from group $groupId',
        tag: 'GroupApprovalService',
      );

      final callable = _functions.httpsCallable('revokeGroupMembership');
      final result = await callable.call({
        'groupId': groupId,
        'childId': childId,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      final success = data['success'] as bool? ?? false;

      if (success) {
        ReleaseLogger.log(
          'Membership revoked successfully',
          tag: 'GroupApprovalService',
        );
      }

      return success;
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error(
        'Error revoking membership: ${e.message}',
        tag: 'GroupApprovalService',
      );
      return false;
    } catch (e) {
      ReleaseLogger.error(
        'Error revoking membership: $e',
        tag: 'GroupApprovalService',
      );
      return false;
    }
  }
}
