// Create Call Service - Single responsibility: Create a new call in Firestore
// Atomic service that ONLY creates call documents

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../models/service_response.dart';
import '../../utils/release_logger.dart';

class CreateCallService {
  static const String _tag = 'CreateCallService';

  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(region: 'us-central1');
  final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Create a new call via Cloud Function
  /// Returns callId and token for the caller
  Future<ServiceResponse<Map<String, dynamic>>> execute({
    required List<String> participantIds,
    required bool isVideo,
    bool isGroup = false,
  }) async {
    try {
      ReleaseLogger.log(
        'Creating call: participants=${participantIds.join(",")}, video=$isVideo, group=$isGroup',
        tag: _tag,
      );

      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        return ServiceResponse.error(
          'User not authenticated',
          errorCode: 'AUTH_ERROR',
        );
      }

      ReleaseLogger.log(
        'User authenticated: ${currentUser.uid}, calling Cloud Function...',
        tag: _tag,
      );

      // Call Cloud Function to create Agora call and generate tokens
      final result = await _functions
          .httpsCallable('createAgoraCall')
          .call<Map<String, dynamic>>({
        'callerId': currentUser.uid,
        'participantIds': participantIds,
        'isVideo': isVideo,
        'isGroup': isGroup,
      });

      ReleaseLogger.log('Cloud Function response received', tag: _tag);

      final data = result.data;

      // Verificar si se alcanzó el límite mensual
      if (data['monthlyLimitReached'] == true) {
        ReleaseLogger.log(
          'Monthly call limit reached: ${data['minutesUsed']}/${data['limitMinutes']} minutes',
          tag: _tag,
        );
        return ServiceResponse.error(
          data['message'] as String? ?? 'Límite mensual alcanzado',
          errorCode: 'MONTHLY_LIMIT_REACHED',
          metadata: {
            'monthlyLimitReached': true,
            'minutesUsed': data['minutesUsed'],
            'minutesRemaining': data['minutesRemaining'],
            'limitMinutes': data['limitMinutes'],
          },
        );
      }

      final callId = data['callId'] as String?;
      final token = data['token'] as String?;
      final channelName = data['channelName'] as String?;
      final agoraUid = data['agoraUid'] as int?;

      // ✅ FIX: Handle busy participants
      final busyParticipants = (data['busyParticipants'] as List<dynamic>?)
          ?.map((e) => e.toString())
          .toList() ?? [];
      final allParticipantsBusy = data['allParticipantsBusy'] as bool? ?? false;

      if (busyParticipants.isNotEmpty) {
        ReleaseLogger.log(
          'Busy participants detected: $busyParticipants, allBusy: $allParticipantsBusy',
          tag: _tag,
        );
      }

      if (callId == null || token == null || channelName == null || agoraUid == null) {
        return ServiceResponse.error(
          'Missing required fields in response',
          errorCode: 'INVALID_RESPONSE',
        );
      }

      ReleaseLogger.log(
        'Call created successfully: $callId, channel: $channelName',
        tag: _tag,
      );

      return ServiceResponse.success({
        'callId': callId,
        'token': token,
        'channelName': channelName,
        'agoraUid': agoraUid,
        'busyParticipants': busyParticipants,
        'allParticipantsBusy': allParticipantsBusy,
      });
    } catch (e) {
      ReleaseLogger.error('Error creating call: $e', tag: _tag);
      return ServiceResponse.error(
        'Failed to create call: ${e.toString()}',
        errorCode: 'CREATE_ERROR',
      );
    }
  }
}