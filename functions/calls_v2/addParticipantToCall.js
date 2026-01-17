/**
 * Add Participant to Existing Call
 *
 * This function adds a new participant to an ongoing call:
 * 1. Validates caller is in the call
 * 2. Validates participant limit (8 max)
 * 3. Validates new participant has contact with ALL current participants
 * 4. Generates Agora RTC token for new participant
 * 5. Updates call document in Firestore
 * 6. Sends push notification to new participant
 */

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const { RtcTokenBuilder, RtcRole } = require('agora-token');
const { sendVoIPPush } = require('../helpers');

// Initialize admin if not already initialized
if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

// Constants
const MAX_PARTICIPANTS = 8;

/**
 * Check if two users have approved contact relationship
 * @param {string} userId1 - First user ID
 * @param {string} userId2 - Second user ID
 * @returns {Promise<boolean>} - True if they have approved contact
 */
async function hasApprovedContact(userId1, userId2) {
  try {
    // Check contacts collection for approved bidirectional relationship
    const contactsQuery = await db.collection('contacts')
      .where('users', 'array-contains', userId1)
      .where('status', '==', 'approved')
      .get();

    for (const doc of contactsQuery.docs) {
      const users = doc.data().users || [];
      if (users.includes(userId2)) {
        return true;
      }
    }

    // Check parent-child relationship
    // Check if userId1 is parent of userId2
    const user1Doc = await db.collection('users').doc(userId1).get();
    if (user1Doc.exists) {
      const linkedChildren = user1Doc.data().linkedChildrenIds || [];
      if (linkedChildren.includes(userId2)) {
        return true;
      }
    }

    // Check if userId2 is parent of userId1
    const user2Doc = await db.collection('users').doc(userId2).get();
    if (user2Doc.exists) {
      const linkedChildren = user2Doc.data().linkedChildrenIds || [];
      if (linkedChildren.includes(userId1)) {
        return true;
      }
    }

    return false;
  } catch (error) {
    console.error(`Error checking contact between ${userId1} and ${userId2}:`, error);
    return false;
  }
}

/**
 * Add a participant to an existing call
 * @param {Object} data - The request data
 * @param {string} data.callId - The ID of the existing call
 * @param {string} data.newParticipantId - The user ID to add
 */
exports.addParticipantToCall = onCall(
  {
    region: 'us-central1',
    timeoutSeconds: 60,
    memory: '512MB',
    consumeAppCheckToken: false,
  },
  async (request) => {
    const data = request.data;
    const context = { auth: request.auth };

    try {
      // Verify authentication
      if (!context.auth) {
        throw new HttpsError(
          'unauthenticated',
          'User must be authenticated to add participants'
        );
      }

      const callerId = context.auth.uid;
      const { callId, newParticipantId } = data;

      // Validate input
      if (!callId || !newParticipantId) {
        throw new HttpsError(
          'invalid-argument',
          'Missing required parameters: callId and newParticipantId'
        );
      }

      console.log(`📞 Adding participant ${newParticipantId} to call ${callId} by ${callerId}`);

      // Get existing call
      const callRef = db.collection('calls_v2').doc(callId);
      const callDoc = await callRef.get();

      if (!callDoc.exists) {
        throw new HttpsError(
          'not-found',
          'Call not found'
        );
      }

      const callData = callDoc.data();
      const participants = callData.participants || {};
      const channelName = callData.channelName;
      const isVideo = callData.isVideo || false;
      const isGroup = callData.isGroup || false;

      // Verify caller is in the call
      if (!participants[callerId]) {
        throw new HttpsError(
          'permission-denied',
          'You are not a participant in this call'
        );
      }

      // Check if new participant is already in the call
      if (participants[newParticipantId]) {
        throw new HttpsError(
          'already-exists',
          'This user is already in the call'
        );
      }

      // Check participant limit
      const currentParticipantCount = Object.keys(participants).length;
      if (currentParticipantCount >= MAX_PARTICIPANTS) {
        throw new HttpsError(
          'resource-exhausted',
          `Maximum ${MAX_PARTICIPANTS} participants allowed per call`
        );
      }

      // Get current participant IDs (excluding declined/ended)
      const activeParticipantIds = Object.keys(participants).filter(id => {
        const status = participants[id].status;
        return status !== 'declined' && status !== 'ended' && status !== 'missed';
      });

      // Validate new participant has contact with ALL current participants
      console.log(`🔍 Validating contact between ${newParticipantId} and ${activeParticipantIds.length} participants`);

      for (const participantId of activeParticipantIds) {
        const hasContact = await hasApprovedContact(newParticipantId, participantId);
        if (!hasContact) {
          // Get participant name for error message
          const participantDoc = await db.collection('users').doc(participantId).get();
          const participantName = participantDoc.exists
            ? (participantDoc.data().name || 'un participante')
            : 'un participante';

          throw new HttpsError(
            'permission-denied',
            `El contacto no está disponible con ${participantName}`
          );
        }
      }

      console.log(`✅ Contact validation passed for ${newParticipantId}`);

      // Get Agora credentials
      const appId = process.env.AGORA_APP_ID;
      const appCertificate = process.env.AGORA_APP_CERTIFICATE;

      if (!appId || !appCertificate) {
        console.error('Agora credentials not configured');
        throw new HttpsError(
          'failed-precondition',
          'Agora service not properly configured'
        );
      }

      // Generate next agoraUid (find max and add 1)
      let maxAgoraUid = 0;
      for (const p of Object.values(participants)) {
        if (p.agoraUid > maxAgoraUid) {
          maxAgoraUid = p.agoraUid;
        }
      }
      const newAgoraUid = maxAgoraUid + 1;

      // Token expiration (24 hours)
      const expirationTimeInSeconds = 3600 * 24;
      const currentTimestamp = Math.floor(Date.now() / 1000);
      const privilegeExpiredTs = currentTimestamp + expirationTimeInSeconds;

      // Generate token for new participant
      const newToken = RtcTokenBuilder.buildTokenWithUid(
        appId,
        appCertificate,
        channelName,
        newAgoraUid,
        RtcRole.PUBLISHER,
        privilegeExpiredTs
      );

      // Get new participant info
      const newParticipantDoc = await db.collection('users').doc(newParticipantId).get();
      const newParticipantData = newParticipantDoc.exists ? newParticipantDoc.data() : {};
      const newParticipantName = newParticipantData.name || newParticipantData.displayName || 'Unknown';

      // Get caller info for notification
      const callerDoc = await db.collection('users').doc(callerId).get();
      const callerData = callerDoc.exists ? callerDoc.data() : {};
      const callerName = callerData.name || callerData.displayName || 'Unknown';

      // Create new participant entry
      const newParticipantEntry = {
        uid: newParticipantId,
        agoraUid: newAgoraUid,
        token: newToken,
        status: 'ringing',
        displayName: newParticipantName,
        photoUrl: newParticipantData.photoURL || null,
        addedBy: callerId,
        addedAt: admin.firestore.FieldValue.serverTimestamp()
      };

      // Update call document
      await callRef.update({
        [`participants.${newParticipantId}`]: newParticipantEntry,
        isGroup: true, // Ensure it's marked as group call now
        updatedAt: admin.firestore.FieldValue.serverTimestamp()
      });

      console.log(`✅ Added ${newParticipantId} to call document`);

      // Send notifications
      const notificationPromises = [];
      const voipToken = newParticipantData.voipToken;
      const fcmToken = newParticipantData.fcmToken;

      // VoIP push for iOS
      if (voipToken && typeof voipToken === 'string' && voipToken.length > 0) {
        console.log(`📱 Sending VoIP push to ${newParticipantId}`);

        const voipPayload = {
          callId: callId,
          channelName: channelName,
          token: newToken,
          agoraUid: newAgoraUid.toString(),
          callerId: callerId,
          callerName: callerName,
          callType: isVideo ? 'video' : 'audio',
          isVideo: isVideo.toString(),
          isGroup: 'true', // Always true when adding participant
          timestamp: Date.now().toString(),
          addedToCall: 'true' // Indicates this is an addition, not new call
        };

        notificationPromises.push(
          sendVoIPPush(voipToken, voipPayload)
            .then((success) => {
              if (success) {
                console.log(`✅ VoIP push sent to ${newParticipantId}`);
              } else {
                console.warn(`⚠️ VoIP push failed for ${newParticipantId}`);
              }
            })
            .catch(error => {
              console.error(`❌ VoIP push error for ${newParticipantId}:`, error);
            })
        );
      }

      // FCM notification for Android
      if (fcmToken) {
        console.log(`📲 Sending FCM notification to ${newParticipantId}`);

        const message = {
          data: {
            type: 'incoming_call',
            callId: callId,
            channelName: channelName,
            token: newToken,
            agoraUid: newAgoraUid.toString(),
            callerId: callerId,
            callerName: callerName,
            isVideo: isVideo.toString(),
            isGroup: 'true',
            timestamp: Date.now().toString(),
            addedToCall: 'true'
          },
          token: fcmToken,
          android: {
            priority: 'high',
          },
          apns: {
            payload: {
              aps: {
                contentAvailable: true,
                mutableContent: true,
                category: 'INCOMING_CALL'
              }
            },
            headers: {
              'apns-priority': '10'
            }
          }
        };

        notificationPromises.push(
          admin.messaging().send(message)
            .then(() => {
              console.log(`✅ FCM sent to ${newParticipantId}`);
            })
            .catch(error => {
              console.error(`❌ FCM error for ${newParticipantId}:`, error);
            })
        );
      }

      // Wait for notifications (don't fail if they fail)
      await Promise.allSettled(notificationPromises);

      console.log(`✅ Successfully added ${newParticipantId} to call ${callId}`);

      return {
        success: true,
        participantId: newParticipantId,
        agoraUid: newAgoraUid,
        displayName: newParticipantName
      };

    } catch (error) {
      console.error('❌ Error adding participant to call:', error);

      if (error instanceof HttpsError) {
        throw error;
      }

      throw new HttpsError(
        'internal',
        error.message || 'Failed to add participant to call'
      );
    }
  }
);
