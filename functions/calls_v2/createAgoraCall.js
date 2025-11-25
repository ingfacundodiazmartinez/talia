/**
 * Create Agora Call Cloud Function
 *
 * This function creates a new call with Agora RTC Engine:
 * 1. Generates a unique channel name
 * 2. Creates Agora RTC tokens for all participants
 * 3. Creates the call document in Firestore
 * 4. Sends push notifications to participants
 */

const { onCall, HttpsError } = require('firebase-functions/v2/https');
const admin = require('firebase-admin');
const { v4: uuidv4 } = require('uuid');
const { RtcTokenBuilder, RtcRole } = require('agora-token');
const { sendVoIPPush } = require('../helpers');

// Initialize admin if not already initialized
if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

/**
 * Create an Agora call
 * @param {Object} data - The call data
 * @param {string} data.callerId - The ID of the user initiating the call
 * @param {Array<string>} data.participantIds - Array of participant user IDs
 * @param {boolean} data.isVideo - Whether this is a video call
 * @param {boolean} data.isGroup - Whether this is a group call
 */
exports.createAgoraCall = onCall(
  {
    region: 'us-central1',
    timeoutSeconds: 60,
    memory: '512MB',
    // Allow unenforced App Check for development
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
          'User must be authenticated to create a call'
        );
      }

      const { callerId, participantIds, isVideo = false, isGroup = false } = data;

      // Validate input
      if (!callerId || !participantIds || !Array.isArray(participantIds)) {
        throw new HttpsError(
          'invalid-argument',
          'Missing or invalid required parameters'
        );
      }

      if (participantIds.length === 0) {
        throw new HttpsError(
          'invalid-argument',
          'At least one participant is required'
        );
      }

      // Get Agora credentials from environment
      const appId = process.env.AGORA_APP_ID;
      const appCertificate = process.env.AGORA_APP_CERTIFICATE;

      if (!appId || !appCertificate) {
        console.error('Agora credentials not configured');
        throw new HttpsError(
          'failed-precondition',
          'Agora service not properly configured'
        );
      }

      // Generate unique channel name
      const timestamp = Date.now();
      const channelName = `call_${timestamp}_${uuidv4().substring(0, 8)}`;

      // Generate call ID
      const callId = `${timestamp}_${uuidv4()}`;

      // Token expiration time (24 hours from now)
      const expirationTimeInSeconds = 3600 * 24;
      const currentTimestamp = Math.floor(Date.now() / 1000);
      const privilegeExpiredTs = currentTimestamp + expirationTimeInSeconds;

      // Create participants map with tokens
      const participants = {};
      let uidCounter = 1;

      // Get caller info
      const callerDoc = await db.collection('users').doc(callerId).get();
      const callerData = callerDoc.exists ? callerDoc.data() : {};
      const callerName = callerData.name || callerData.displayName || 'Unknown';

      // Add caller as participant
      const callerUid = uidCounter++;
      const callerToken = RtcTokenBuilder.buildTokenWithUid(
        appId,
        appCertificate,
        channelName,
        callerUid,
        RtcRole.PUBLISHER,
        privilegeExpiredTs
      );

      participants[callerId] = {
        uid: callerId,
        agoraUid: callerUid,
        token: callerToken,
        status: 'calling',
        displayName: callerName,
        joinedAt: admin.firestore.FieldValue.serverTimestamp()
      };

      // Add other participants
      const notificationPromises = [];

      for (const participantId of participantIds) {
        if (participantId === callerId) continue; // Skip caller if included

        const participantUid = uidCounter++;
        const participantToken = RtcTokenBuilder.buildTokenWithUid(
          appId,
          appCertificate,
          channelName,
          participantUid,
          RtcRole.PUBLISHER,
          privilegeExpiredTs
        );

        // Get participant info
        const participantDoc = await db.collection('users').doc(participantId).get();
        const participantData = participantDoc.exists ? participantDoc.data() : {};
        const participantName = participantData.name || participantData.displayName || 'Unknown';

        participants[participantId] = {
          uid: participantId,
          agoraUid: participantUid,
          token: participantToken,
          status: 'ringing',
          displayName: participantName
        };

        // ✅ PHASE 1: VoIP Token Validation
        // Prepare push notifications for participant
        const voipToken = participantData.voipToken;
        const fcmToken = participantData.fcmToken;

        // 🔍 DEBUG: Log token values to diagnose notification issues
        console.log(`🔍 [TOKEN CHECK] Participant ${participantId}:`);
        console.log(`   - voipToken: ${voipToken ? `EXISTS (${voipToken.substring(0, 20)}...)` : 'NULL/UNDEFINED'}`);
        console.log(`   - fcmToken: ${fcmToken ? `EXISTS (${fcmToken.substring(0, 30)}...)` : 'NULL/UNDEFINED'}`);

        // ✅ FIX: Usar sendVoIPPush de helpers.js (APNs directo, no Firebase Messaging)
        // Los tokens VoIP de iOS NO son tokens FCM, requieren APNs
        if (voipToken && typeof voipToken === 'string' && voipToken.length > 0) {
          console.log(`✅ Valid VoIP token found for ${participantId}: ${voipToken.substring(0, 20)}...`);

          // Payload para VoIP push (iOS)
          const voipPayload = {
            callId: callId,
            channelName: channelName,
            token: participantToken,
            agoraUid: participantUid.toString(),
            callerId: callerId,
            callerName: callerName,
            callType: isVideo ? 'video' : 'audio',
            isVideo: isVideo.toString(),
            isGroup: isGroup.toString(),
            timestamp: timestamp.toString()
          };

          // Usar sendVoIPPush que usa APNs directamente
          notificationPromises.push(
            sendVoIPPush(voipToken, voipPayload)
              .then((success) => {
                if (success) {
                  console.log(`✅ VoIP push sent to ${participantId} via APNs`);
                } else {
                  console.warn(`⚠️ VoIP push failed for ${participantId} (APNs provider issue)`);
                }
              })
              .catch(error => {
                console.error(`❌ Failed to send VoIP push to ${participantId}:`, error);
              })
          );
        } else if (voipToken) {
          console.warn(`⚠️ Invalid VoIP token for ${participantId}: ${typeof voipToken}`);
        }

        // Send FCM notification (Android background - data only, no visible notification)
        // ✅ PHASE 2: Send only data payload to avoid duplicate notification before CallKit
        if (fcmToken) {
          const message = {
            // ❌ NO notification payload - this would show a banner before CallKit
            // notification: { ... }

            // ✅ ONLY data payload - processed by background handler to show CallKit
            data: {
              type: 'incoming_call',
              callId: callId,
              channelName: channelName,
              token: participantToken,
              agoraUid: participantUid.toString(),
              callerId: callerId,
              callerName: callerName,
              isVideo: isVideo.toString(),
              isGroup: isGroup.toString(),
              timestamp: timestamp.toString()
            },
            token: fcmToken,
            android: {
              priority: 'high',
              // ❌ NO notification config - CallKit will handle UI
            },
            apns: {
              payload: {
                aps: {
                  // ❌ REMOVED alert/sound/badge - prevents duplicate visible notification
                  // CallKit/VoIP handles the UI, this is only for background data
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

          console.log(`📲 Sending FCM notification to ${participantId}...`);
          notificationPromises.push(
            admin.messaging().send(message)
              .then(() => {
                console.log(`✅ FCM notification sent successfully to ${participantId}`);
              })
              .catch(error => {
                console.error(`❌ Failed to send FCM notification to ${participantId}:`, error);
                // Don't throw, just log the error
              })
          );
        } else {
          console.warn(`⚠️ No FCM token available for ${participantId} - skipping FCM notification`);
        }
      }

      // Determine call type
      const callType = isGroup ? 'group' : 'oneToOne';

      // Create call document
      const callData = {
        channelName: channelName,
        createdBy: callerId,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        isVideo: isVideo,
        isGroup: isGroup,
        participants: participants,
        callType: callType,
        metadata: {
          appId: appId,
          region: 'us-central1'
        }
      };

      // Save to Firestore
      await db.collection('calls_v2').doc(callId).set(callData);

      // 🔍 DEBUG: Log initial participant statuses
      console.log(`📊 [CALL CREATED] Call ${callId} - Participants:`,
        Object.entries(participants).map(([id, p]) => `${id.substring(0, 8)}: ${p.status}`).join(', ')
      );

      // Create user_calls collection documents for incoming call detection
      // This structure allows the app to detect incoming calls without complex indexes
      const userCallPromises = [];

      // For each participant (excluding caller), create an incoming call document
      for (const [userId, participant] of Object.entries(participants)) {
        if (userId === callerId) continue; // Skip the caller

        console.log(`📝 Creating user_calls incoming doc for ${userId}: ${callId}`);

        // Create incoming call document for this participant
        const incomingCallData = {
          status: 'ringing',
          callId: callId,
          callerId: callerId,
          callerName: callerName,
          isVideo: isVideo,
          isGroup: isGroup,
          createdAt: admin.firestore.FieldValue.serverTimestamp(),
          roomId: channelName // For compatibility
        };

        userCallPromises.push(
          db.collection('user_calls')
            .doc(userId)
            .collection('incoming')
            .doc(callId)
            .set(incomingCallData)
            .then(() => {
              console.log(`✅ Created user_calls incoming doc for ${userId}: ${callId}`);
            })
            .catch(error => {
              console.error(`❌ Failed to create user_calls doc for ${userId}: ${error}`);
            })
        );
      }

      // ✅ FIX UX: Solo esperar user_calls (necesario para que receptor detecte llamada)
      // Las notificaciones se envían en background para no bloquear al caller
      await Promise.all(userCallPromises);

      // Enviar notificaciones en background (fire-and-forget)
      // No esperamos - el caller puede ver la pantalla de llamada inmediatamente
      Promise.all(notificationPromises)
        .then(() => console.log(`✅ All notifications sent for call ${callId}`))
        .catch(err => console.error(`⚠️ Some notifications failed for call ${callId}:`, err));

      console.log(`Call created successfully: ${callId}, channel: ${channelName}`);

      // Return caller's token and call info
      return {
        success: true,
        callId: callId,
        channelName: channelName,
        token: callerToken,
        agoraUid: callerUid,
        participants: Object.keys(participants)
      };

    } catch (error) {
      console.error('Error creating Agora call:', error);

      if (error instanceof HttpsError) {
        throw error;
      }

      throw new HttpsError(
        'internal',
        'Failed to create call',
        error.message
      );
    }
  });