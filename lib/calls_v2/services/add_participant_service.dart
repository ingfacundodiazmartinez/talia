/// Add Participant Service - Single responsibility: Add a participant to an existing call
/// Atomic service that calls the Cloud Function to add participants mid-call

import 'package:cloud_functions/cloud_functions.dart';
import '../models/service_response.dart';
import '../../utils/release_logger.dart';

/// Result model for added participant
class AddedParticipant {
  final String participantId;
  final int agoraUid;
  final String displayName;

  AddedParticipant({
    required this.participantId,
    required this.agoraUid,
    required this.displayName,
  });

  factory AddedParticipant.fromMap(Map<String, dynamic> data) {
    return AddedParticipant(
      participantId: data['participantId'] as String,
      agoraUid: data['agoraUid'] as int,
      displayName: data['displayName'] as String? ?? 'Unknown',
    );
  }
}

class AddParticipantService {
  static const String _tag = 'AddParticipantService';
  static const int maxParticipants = 8;

  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  /// Add a participant to an existing call
  ///
  /// Returns the added participant info if successful
  /// Validates:
  /// - Caller is in the call
  /// - New participant has contact with all current participants
  /// - Participant limit (8) not exceeded
  Future<ServiceResponse<AddedParticipant>> execute({
    required String callId,
    required String newParticipantId,
  }) async {
    try {
      ReleaseLogger.log(
        'Adding participant $newParticipantId to call $callId',
        tag: _tag,
      );

      final result = await _functions
          .httpsCallable('addParticipantToCall')
          .call<Map<String, dynamic>>({
        'callId': callId,
        'newParticipantId': newParticipantId,
      });

      ReleaseLogger.log('Cloud Function response received', tag: _tag);

      final data = result.data;

      if (data['success'] != true) {
        return ServiceResponse.error(
          data['error'] ?? 'Failed to add participant',
          errorCode: 'ADD_FAILED',
        );
      }

      final addedParticipant = AddedParticipant.fromMap(data);

      ReleaseLogger.log(
        'Participant added: ${addedParticipant.displayName} (agoraUid: ${addedParticipant.agoraUid})',
        tag: _tag,
      );

      return ServiceResponse.success(addedParticipant);

    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error('Firebase Functions error: ${e.code} - ${e.message}', tag: _tag);

      // Map error codes to user-friendly messages
      String userMessage;
      switch (e.code) {
        case 'not-found':
          userMessage = 'Llamada no encontrada';
          break;
        case 'permission-denied':
          userMessage = e.message ?? 'No tienes permiso para agregar participantes';
          break;
        case 'already-exists':
          userMessage = 'Este usuario ya está en la llamada';
          break;
        case 'resource-exhausted':
          userMessage = 'Máximo $maxParticipants participantes por llamada';
          break;
        default:
          userMessage = e.message ?? 'Error al agregar participante';
      }

      return ServiceResponse.error(
        userMessage,
        errorCode: e.code,
      );
    } catch (e) {
      ReleaseLogger.error('Error adding participant: $e', tag: _tag);
      return ServiceResponse.error(
        'Error al agregar participante: ${e.toString()}',
        errorCode: 'ADD_ERROR',
      );
    }
  }
}
