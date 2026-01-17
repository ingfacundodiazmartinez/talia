/**
 * Export all Agora call-related Cloud Functions
 * This file aggregates all the V2 call functions
 */

const { createAgoraCall } = require('./createAgoraCall');
const { addParticipantToCall } = require('./addParticipantToCall');
const { onCallV2Updated } = require('./onCallEnded');

module.exports = {
  createAgoraCall,
  addParticipantToCall,
  onCallV2Updated,
};