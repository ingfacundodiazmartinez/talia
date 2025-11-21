/**
 * Export all Agora call-related Cloud Functions
 * This file aggregates all the V2 call functions
 */

const { createAgoraCall } = require('./createAgoraCall');

module.exports = {
  createAgoraCall,
};