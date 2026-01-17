/// Watch Call Service - Single responsibility: Watch call updates in real-time
/// Atomic service that ONLY provides a stream of call updates

import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/call_v2.dart';
import '../../utils/release_logger.dart';

class WatchCallService {
  static const String _tag = 'WatchCallService';
  static const String _collection = 'calls_v2';

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Watch a call for real-time updates
  Stream<CallV2?> execute(String callId) {
    ReleaseLogger.log('Starting to watch call: $callId', tag: _tag);

    return _firestore
        .collection(_collection)
        .doc(callId)
        .snapshots()
        .map((snapshot) {
      if (snapshot.exists) {
        final call = CallV2.fromFirestore(snapshot);
        ReleaseLogger.log(
          '🔄 [WatchCallService] Firestore update: $callId - endedAt=${call.endedAt}, endedBy=${call.endedBy}',
          tag: _tag,
        );
        return call;
      }
      ReleaseLogger.log('Call document deleted: $callId', tag: _tag);
      return null;
    });
  }
}