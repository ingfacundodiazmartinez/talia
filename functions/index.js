/**
 * ═══════════════════════════════════════════════════════════════
 * TALIA - Firebase Cloud Functions (Modular Organization)
 * ═══════════════════════════════════════════════════════════════
 *
 * Este archivo solo importa y re-exporta las funciones definidas
 * en archivos modulares organizados por categoría.
 *
 * Estructura:
 * - helpers.js: Utilidades compartidas, validaciones, rate limiting
 * - notifications.js: Notificaciones push
 * - video-calls.js: Generación de tokens Agora para videollamadas
 * - reports.js: Generación de reportes para padres
 * - parent-child.js: Gestión de vínculos padre-hijo
 * - contacts.js: Solicitudes de contacto y bloqueos
 * - groups.js: Gestión de grupos y permisos
 * - moderation.js: Moderación de contenido (IA)
 * - chats.js: Gestión de chats (unread counts, etc.)
 * - emergency.js: Alertas de emergencia
 * - user-profile.js: Gestión de perfiles de usuario
 * - payments.js: Suscripciones y pagos (Stripe/MercadoPago)
 * - scheduled-tasks.js: Tareas programadas (limpieza, etc.)
 * - transformations.js: Transformaciones de imágenes con IA
 * - sticker-functions.js: Sincronización de stickers
 *
 * Última actualización: 2025-11-30
 * ═══════════════════════════════════════════════════════════════
 */

// ═══════════════════════════════════════════════════════════════
// INICIALIZACIÓN
// ═══════════════════════════════════════════════════════════════

const { initializeApp } = require("firebase-admin/app");
require("dotenv").config(); // Cargar variables de entorno

initializeApp(); // Inicializar Firebase Admin SDK

console.log("✅ Firebase Cloud Functions initialized (modular structure)");

// ═══════════════════════════════════════════════════════════════
// IMPORTS DE FUNCIONES POR MÓDULO
// ═══════════════════════════════════════════════════════════════

// Notificaciones
const notifications = require("./notifications");

// ❌ LEGACY - Videollamadas (Agora) - DESACTIVADO
// const videoCalls = require("./video-calls");

// ✅ Videollamadas V2 (Agora) - ÚNICA ARQUITECTURA ACTIVA
const callsV2 = require("./calls_v2/index");

// ❌ LEGACY - Llamadas (Calls Management) - DESACTIVADO
// const calls = require("./calls");

// Reportes
const reports = require("./reports");

// Gestión padre-hijo
const parentChild = require("./parent-child");

// Contactos y bloqueos
const contacts = require("./contacts");

// Grupos (legacy)
const groups = require("./groups");

// Grupos V2 (nueva arquitectura con aprobación parental)
const groupsV2 = require("./groups-v2");

// Moderación de contenido
const moderation = require("./moderation");

// Chats
const chats = require("./chats");

// Emergencias
const emergency = require("./emergency");

// Perfiles de usuario
const userProfile = require("./user-profile");

// Pagos y suscripciones
const payments = require("./payments");

// IAP Verification (Play Store & App Store)
const iapVerification = require("./iap-verification");

// Tareas programadas
const scheduledTasks = require("./scheduled-tasks");

// Transformaciones de imágenes
const transformations = require("./transformations");

// Stickers
const stickerFunctions = require("./sticker-functions");

// Stories
const stories = require("./stories");

// Story Approval (Cloud Functions for secure approval)
const storyApproval = require("./story-approval");

// Trivia (trivias personales en historias)
const trivia = require("./trivia");

// Account Deletion (eliminación segura de cuentas)
const accountDeletion = require("./account-deletion");

// Nudge (empujoncitos efímeros entre usuarios: latido, zumbido, saludo, psst)
const nudge = require("./nudge");

// Migrations (scripts de migración de datos)
const friendsMigration = require("./migrations/migrate-contacts-to-friends");

// Talia Assistant (Chat con IA para todos los usuarios)
const taliaAssistant = require("./talia-assistant");

// Wallet de créditos familiar (Fase 1: modo sombra)
const wallet = require("./wallet");

// ❌ Voice Changer (ElevenLabs) - ELIMINADO
// ❌ Replicate Voice (TTS) - ELIMINADO

// ═══════════════════════════════════════════════════════════════
// RE-EXPORTS
// ═══════════════════════════════════════════════════════════════

// Notificaciones
exports.sendNotificationOnCreate = notifications.sendNotificationOnCreate; // ✅ REACTIVADA - procesa notificaciones con pushSent: false
exports.sendInstantPushNotification = notifications.sendInstantPushNotification;

// ❌ LEGACY VIDEOLLAMADAS - DESACTIVADAS (solo usar V2)
// exports.generateAgoraToken = videoCalls.generateAgoraToken;
// exports.initiateVideoCall = videoCalls.initiateVideoCall;

// ❌ LEGACY CALLS MANAGEMENT - DESACTIVADO (solo usar V2)
// exports.createCall = calls.createCall;
// exports.addParticipants = calls.addParticipants;
// exports.acceptCall = calls.acceptCall;
// exports.updateCallStatus = calls.updateCallStatus;

// Reportes
exports.generateChildReport = reports.generateChildReport;
exports.onPendingReportCreated = reports.onPendingReportCreated;

// Gestión padre-hijo
exports.createParentChildLink = parentChild.createParentChildLink;
exports.validateLinkCode = parentChild.validateLinkCode;
exports.ensureLinkedChildrenIds = parentChild.ensureLinkedChildrenIds;
exports.unlinkChild = parentChild.unlinkChild;
exports.onParentChildLinkCreated = parentChild.onParentChildLinkCreated;
exports.onParentChildLinkUpdated = parentChild.onParentChildLinkUpdated;
exports.onParentChildLinkDeleted = parentChild.onParentChildLinkDeleted;
exports.requestChildLocation = parentChild.requestChildLocation;
exports.requestUnlink = parentChild.requestUnlink;

// Contactos y bloqueos
exports.findUserByCode = contacts.findUserByCode;
exports.createContactRequest = contacts.createContactRequest;
// REMOVED: updateContactRequestStatus - padres usan Firestore directo + Security Rules
// REMOVED: blockChat, unblockChat - escritura directa desde Flutter + Security Rules en blocked_chats y chats
exports.invalidateChatOnContactDelete = contacts.invalidateChatOnContactDelete;
exports.onContactApprovalRequested = contacts.onContactApprovalRequested;
exports.syncDeviceContacts = contacts.syncDeviceContacts;
// REMOVED: approveContactFromRequest - padres usan WhitelistController + Security Rules
exports.autoApproveContact = contacts.autoApproveContact;
exports.createContactFromGroupInvitation = contacts.createContactFromGroupInvitation;
exports.getChildContactsForModeration = contacts.getChildContactsForModeration;
// REMOVED: updateChildContactModeration, getContactModerationStatus - lectura/escritura directa desde Flutter
exports.updateContactStatus = contacts.updateContactStatus;
exports.revokeChildContact = contacts.revokeChildContact;
exports.migrateContactsUserData = contacts.migrateContactsUserData;

// Grupos (legacy - solo funciones aún en uso)
// createGroup, leaveGroup, approveGroupPermission, updateGroupPermissionStatus REMOVED - not used
exports.processGroupInvitationsAfterContactApproval = groups.processGroupInvitationsAfterContactApproval;

// Grupos V2 (nueva arquitectura con aprobación parental)
exports.createGroupV2 = groupsV2.createGroupV2;
// REMOVED: approveGroupMembership, rejectGroupMembership, revokeGroupMembership
// Escritura directa desde Flutter + Security Rules en groups_v2 y group_approval_requests
exports.addGroupMembersV2 = groupsV2.addGroupMembersV2;
exports.removeGroupMemberV2 = groupsV2.removeGroupMemberV2;
exports.leaveGroupV2 = groupsV2.leaveGroupV2;
exports.updateGroupInfoV2 = groupsV2.updateGroupInfoV2;
exports.getGroupApprovalRequests = groupsV2.getGroupApprovalRequests;
exports.onGroupApprovalRequestCreated = groupsV2.onGroupApprovalRequestCreated;
exports.onParentChildUnlinkV2 = groupsV2.onParentChildUnlinkV2;
exports.expireGroupApprovalRequests = groupsV2.expireGroupApprovalRequests;
exports.onGroupV2MessageCreated = groupsV2.onGroupV2MessageCreated;
exports.promoteGroupAdmin = groupsV2.promoteGroupAdmin;
exports.demoteGroupAdmin = groupsV2.demoteGroupAdmin;
exports.sendGroupV2Message = groupsV2.sendGroupV2Message; // ✅ Envío de mensajes con moderación

// Moderación de contenido
// ✅ checkMessageBeforeSending - Usado para verificar moderación antes de enviar (incluye modo checkOnly para edición de mensajes bloqueados)
exports.checkMessageBeforeSending = moderation.checkMessageBeforeSending;
exports.moderateMessage = moderation.moderateMessage;
exports.createApprovedMessage = moderation.createApprovedMessage;
exports.setOwnModeration = moderation.setOwnModeration; // ✅ Permite a adultos configurar su propia moderación
exports.moderateImageWithOpenAI = moderation.moderateImageWithOpenAI; // ✅ Moderación de imágenes con OpenAI (Premium+)
exports.moderateAudioWithWhisper = moderation.moderateAudioWithWhisper; // ✅ Moderación de audios con Whisper + Gemini (Premium+)
exports.moderateMultimedia = moderation.moderateMultimedia; // ✅ Función unificada para moderar multimedia (Premium+)
exports.checkMultimediaModerationStatus = moderation.checkMultimediaModerationStatus; // ✅ Verificar estado de moderación multimedia

// Chats - Message Triggers
exports.onChatMessageCreated = chats.onChatMessageCreated;           // ✅ Principal: Security, TTL, chat metadata
exports.onGroupMessageCreated = chats.onGroupMessageCreated;         // ✅ Principal: Groups legacy (colección 'groups')
exports.incrementUnreadCount = chats.incrementUnreadCount;           // @deprecated - alias de onChatMessageCreated
exports.incrementGroupUnreadCount = chats.incrementGroupUnreadCount; // @deprecated - alias de onGroupMessageCreated

// Chats - Callable Functions
exports.sendChatMessage = chats.sendChatMessage;
exports.sendGroupMessage = chats.sendGroupMessage;
exports.createChat = chats.createChat;
exports.cleanupDeliveredMessages = chats.cleanupDeliveredMessages; // V2: Eliminar mensajes cuando ambos recibieron

// Emergencias
exports.createEmergency = emergency.createEmergency;

// Perfiles de usuario
exports.updateUserProfile = userProfile.updateUserProfile;
exports.checkPhoneDuplicate = userProfile.checkPhoneDuplicate;
exports.checkExistingUserByPhone = userProfile.checkExistingUserByPhone;
exports.generateUserCode = userProfile.generateUserCode;
exports.onUserRegistered = userProfile.onUserRegistered;
exports.onPresenceChanged = userProfile.onPresenceChanged;
exports.onUserNameUpdated = userProfile.onUserNameUpdated;

// Pagos y suscripciones
exports.checkPremiumStatus = payments.checkPremiumStatus;
exports.activatePremium = payments.activatePremium;
// createCheckoutSession REMOVED - use IAP instead (verifyPlayStorePurchase, verifyAppStorePurchase)
exports.cancelSubscription = payments.cancelSubscription;
// handleStripeWebhook REMOVED - Stripe not implemented
// handleMercadoPagoWebhook REMOVED - MercadoPago no longer used

// IAP Verification (In-App Purchases)
exports.verifyPlayStorePurchase = iapVerification.verifyPlayStorePurchase;
exports.verifyAppStorePurchase = iapVerification.verifyAppStorePurchase;
exports.handlePlayStoreNotification = iapVerification.handlePlayStoreNotification;
exports.handleAppStoreNotification = iapVerification.handleAppStoreNotification;
exports.validateDiscountCode = iapVerification.validateDiscountCode;
exports.applyDiscountCode = iapVerification.applyDiscountCode;

// Tareas programadas
exports.convertExpiredStoriesToPermanent = scheduledTasks.convertExpiredStoriesToPermanent;
exports.cleanupExpiredStoryApprovalRequests = scheduledTasks.cleanupExpiredStoryApprovalRequests;
// cleanupOldMessages ELIMINADO - Reemplazado por Firestore TTL Policy (campo deleteAt)
exports.autoResolveEmergencies = scheduledTasks.autoResolveEmergencies;
exports.cleanupOldRateLimits = scheduledTasks.cleanupOldRateLimits;
exports.cleanupOldNotifications = scheduledTasks.cleanupOldNotifications;

// Transformaciones de imágenes
exports.transformCharacter = transformations.transformCharacter;
exports.createCharacterTransformation = transformations.createCharacterTransformation;

// Stickers
exports.syncStickersScheduled = stickerFunctions.syncStickersScheduled;
exports.syncStickersManual = stickerFunctions.syncStickersManual;
exports.cleanupOldStickers = stickerFunctions.cleanupOldStickers;

// Stories
exports.onStoryApprovalRequestCreated = stories.onStoryApprovalRequestCreated;
exports.onStoryDeleted = stories.onStoryDeleted;
exports.replyToStory = stories.replyToStory;
exports.likeStory = stories.likeStory;
exports.getStoryPreview = stories.getStoryPreview;

// Story Approval (Secure Cloud Functions)
exports.createStory = storyApproval.createStory;
exports.approveStory = storyApproval.approveStory;
exports.rejectStory = storyApproval.rejectStory;
exports.restoreStoryToPending = storyApproval.restoreStoryToPending;

// Story availableFor Sync Triggers (mantener sincronizado con contactos/bloqueos)
exports.onBlockCreated = storyApproval.onBlockCreated;
exports.onBlockDeleted = storyApproval.onBlockDeleted;
exports.onContactCreated = storyApproval.onContactCreated;
exports.onContactUpdated = storyApproval.onContactUpdated;
exports.onContactDeleted = storyApproval.onContactDeleted;

// Story Notifications (notificar contactos cuando se sube historia)
exports.onStoryApproved = storyApproval.onStoryApproved;
exports.onStoryCreatedApproved = storyApproval.onStoryCreatedApproved;

// FOMO Notifications (notificar no-amigos para incentivar solicitudes de amistad)
exports.sendFomoNotifications = storyApproval.sendFomoNotifications;
exports.sendFomoNotificationsOnCreate = storyApproval.sendFomoNotificationsOnCreate;

// ═══════════════════════════════════════════════════════════════
// NUDGE (Empujoncitos efímeros entre usuarios)
// ═══════════════════════════════════════════════════════════════

exports.sendNudge = nudge.sendNudge;

// ═══════════════════════════════════════════════════════════════
// VIDEOLLAMADAS V2 (Agora) - NUEVA ARQUITECTURA
// ═══════════════════════════════════════════════════════════════

exports.createAgoraCall = callsV2.createAgoraCall;
exports.addParticipantToCall = callsV2.addParticipantToCall;
exports.onCallV2Updated = callsV2.onCallV2Updated; // Trigger para mensaje de llamada y tracking de minutos

// ═══════════════════════════════════════════════════════════════
// ❌ VOICE CHANGER y TTS - ELIMINADOS
// ═══════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════
// ACCOUNT DELETION (Eliminación segura de cuentas)
// ═══════════════════════════════════════════════════════════════

exports.deleteUserAccount = accountDeletion.deleteUserAccount;

// ═══════════════════════════════════════════════════════════════
// TRIVIA (Trivias personales en historias)
// ═══════════════════════════════════════════════════════════════

exports.closeExpiredTrivias = trivia.closeExpiredTrivias;
exports.onTriviaResponseCreated = trivia.onTriviaResponseCreated;
exports.sendTriviaExpirationReminder = trivia.sendTriviaExpirationReminder;
exports.onTriviaResultsPublished = trivia.onTriviaResultsPublished;
exports.generateTriviaSuggestion = trivia.generateTriviaSuggestion;
exports.getTriviaPreview = trivia.getTriviaPreview;

// ═══════════════════════════════════════════════════════════════
// TALIA ASSISTANT (Chat con IA para todos los usuarios)
// ═══════════════════════════════════════════════════════════════

exports.onUserCreatedCreateTaliaChat = taliaAssistant.onUserCreatedCreateTaliaChat;
exports.onMessageToTalia = taliaAssistant.onMessageToTalia;
exports.onStoryCreatedTaliaReaction = taliaAssistant.onStoryCreatedTaliaReaction;
exports.processTaliaPendingReactions = taliaAssistant.processTaliaPendingReactions;
// exports.taliaDailyProactiveMessages = taliaAssistant.taliaDailyProactiveMessages; // ⏸️ PAUSADO - Mensajes proactivos desactivados

// ═══════════════════════════════════════════════════════════════
// MIGRATIONS (Scripts de migración de datos - ejecutar una vez)
// ═══════════════════════════════════════════════════════════════

// Friends Feature Migration - Convierte contactos existentes en amigos
exports.migrateContactsToFriends = friendsMigration.migrateContactsToFriends;
exports.checkMigrationStatus = friendsMigration.checkMigrationStatus;

// ═══════════════════════════════════════════════════════════════
// WALLET DE CRÉDITOS FAMILIAR (Fase 1: modo sombra)
// ═══════════════════════════════════════════════════════════════
// Documentación: WALLET_SPEC.md
// Estado: los créditos se acumulan, pero la app cliente todavía no los consume.
// Cuando el feature flag wallet_enabled se active, los usuarios ya tendrán saldo.

exports.getWalletStatus = wallet.getWalletStatus;
exports.claimWelcomeBonus = wallet.claimWelcomeBonus;
exports.claimDailyBonus = wallet.claimDailyBonus;
exports.earnCreditsFromAd = wallet.earnCreditsFromAd;
exports.grantPremiumMonthlyToAll = wallet.grantPremiumMonthlyToAll;

console.log("✅ Todas las funciones exportadas correctamente (incluye Agora V2, Trivia, Talia Assistant, Migrations, Wallet)");
