import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/models.dart';

/// Repository for Group Approval Requests
///
/// Handles all Firestore operations for group approval requests.
class GroupApprovalRepository {
  final FirebaseFirestore _firestore;

  static const String _collectionName = 'group_approval_requests';

  GroupApprovalRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _collection =>
      _firestore.collection(_collectionName);

  /// Get an approval request by ID
  Future<GroupApprovalRequest?> getById(String requestId) async {
    final doc = await _collection.doc(requestId).get();
    if (!doc.exists) return null;
    return GroupApprovalRequest.fromFirestore(doc.id, doc.data()!);
  }

  /// Watch an approval request by ID
  Stream<GroupApprovalRequest?> watchById(String requestId) {
    return _collection.doc(requestId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return GroupApprovalRequest.fromFirestore(doc.id, doc.data()!);
    });
  }

  /// Get pending requests for a parent
  Future<List<GroupApprovalRequest>> getPendingRequestsForParent(
    String parentId,
  ) async {
    final snapshot = await _collection
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true)
        .get();

    return snapshot.docs
        .map((doc) => GroupApprovalRequest.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  /// Watch pending requests for a parent
  Stream<List<GroupApprovalRequest>> watchPendingRequestsForParent(
    String parentId,
  ) {
    return _collection
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => GroupApprovalRequest.fromFirestore(doc.id, doc.data()))
            .toList());
  }

  /// Get count of pending requests for a parent
  Future<int> getPendingRequestCountForParent(String parentId) async {
    final snapshot = await _collection
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'pending')
        .count()
        .get();

    return snapshot.count ?? 0;
  }

  /// Watch count of pending requests for a parent
  Stream<int> watchPendingRequestCountForParent(String parentId) {
    return _collection
        .where('parentId', isEqualTo: parentId)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .map((snapshot) => snapshot.docs.length);
  }

  /// Get requests for a specific child
  Future<List<GroupApprovalRequest>> getRequestsForChild(String childId) async {
    final snapshot = await _collection
        .where('childId', isEqualTo: childId)
        .orderBy('createdAt', descending: true)
        .get();

    return snapshot.docs
        .map((doc) => GroupApprovalRequest.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  /// Get requests for a specific group
  Future<List<GroupApprovalRequest>> getRequestsForGroup(String groupId) async {
    final snapshot = await _collection
        .where('groupId', isEqualTo: groupId)
        .where('status', isEqualTo: 'pending')
        .get();

    return snapshot.docs
        .map((doc) => GroupApprovalRequest.fromFirestore(doc.id, doc.data()))
        .toList();
  }

  /// Get all requests for a parent (all statuses)
  Future<List<GroupApprovalRequest>> getAllRequestsForParent(
    String parentId, {
    int? limit,
  }) async {
    var query = _collection
        .where('parentId', isEqualTo: parentId)
        .orderBy('createdAt', descending: true);

    if (limit != null) {
      query = query.limit(limit);
    }

    final snapshot = await query.get();

    return snapshot.docs
        .map((doc) => GroupApprovalRequest.fromFirestore(doc.id, doc.data()))
        .toList();
  }
}
