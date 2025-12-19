/**
 * Script para limpiar index.js eliminando funciones no usadas
 *
 * Funciones que SÍ se usan (21 funciones):
 */

const USED_FUNCTIONS = new Set([
  'activatePremium',
  'approveGroupPermission',
  // 'blockChat', // ✅ ELIMINADO: Escritura directa desde Flutter + Security Rules
  'cancelSubscription',
  // 'checkMessageBeforeSending', // ✅ ELIMINADO: La moderación ahora se hace SOLO en el trigger
  'checkPremiumStatus',
  'createCheckoutSession',
  'createContactRequest',
  'createEmergency',
  'createGroup',
  'createParentChildLink',
  'generateAgoraToken',
  'generateChildReport',
  'incrementUnreadCount',  // ✅ TRIGGER - necesario
  'markChatAsRead',
  'moderateMessage',  // ✅ TRIGGER - necesario
  'onParentChildLinkCreated',  // ✅ TRIGGER - necesario
  'onParentChildLinkDeleted',  // ✅ TRIGGER - necesario
  'onUserRegistered',  // ✅ TRIGGER - necesario
  'processGroupInvitationsAfterContactApproval',
  'sendNotificationOnCreate',  // ✅ TRIGGER - necesario
  'transformCharacter',
  // 'unblockChat', // ✅ ELIMINADO: Escritura directa desde Flutter + Security Rules
  'unlinkChild',
  'updateContactRequestStatus',
  'updateGroupPermissionStatus',
  'updateUserProfile',
  // ✅ Funciones de stickers (importadas desde sticker-functions.js)
  'syncStickersScheduled',
  'syncStickersManual',
  'cleanupOldStickers',
  // ✅ Webhooks necesarios
  'handleStripeWebhook',
  'handleMercadoPagoWebhook',
  // ✅ Scheduled tasks críticos
  'convertExpiredStoriesToPermanent',
  'cleanupOldMessages',
  'autoResolveEmergencies',
  'cleanupOldRateLimits',
]);

console.log(`✅ Funciones a mantener: ${USED_FUNCTIONS.size}`);
console.log('Funciones:', Array.from(USED_FUNCTIONS).sort().join(', '));
