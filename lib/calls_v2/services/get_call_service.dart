/// Get Call Service - Single responsibility: Fetch a call from Firestore
/// Atomic service that ONLY retrieves call data

import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/call_v2.dart';
import '../models/service_response.dart';
import '../../utils/release_logger.dart';

class GetCallService {
  static const String _tag = 'GetCallService';
  static const String _collection = 'calls_v2';

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Get a single call by ID
  Future<ServiceResponse<CallV2>> execute(String callId) async {
    try {
      ReleaseLogger.log('Fetching call: $callId', tag: _tag);

      final doc = await _firestore.collection(_collection).doc(callId).get();

      if (!doc.exists) {
        return ServiceResponse.error(
          'Call not found',
          errorCode: 'CALL_NOT_FOUND',
        );
      }

      final call = CallV2.fromFirestore(doc);
      ReleaseLogger.log('Call fetched successfully: $callId', tag: _tag);

      return ServiceResponse.success(call);
    } catch (e) {
      ReleaseLogger.error('Error fetching call: $e', tag: _tag);
      return ServiceResponse.error(
        'Failed to fetch call: ${e.toString()}',
        errorCode: 'FETCH_ERROR',
      );
    }
  }
}