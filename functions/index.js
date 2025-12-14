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
exports.unlinkChild = parentChild.unlinkChild;
exports.onParentChildLinkCreated = parentChild.onParentChildLinkCreated;
exports.onParentChildLinkDeleted = parentChild.onParentChildLinkDeleted;
exports.requestChildLocation = parentChild.requestChildLocation;

// Contactos y bloqueos
exports.findUserByCode = contacts.findUserByCode;
exports.createContactRequest = contacts.createContactRequest;
exports.updateContactRequestStatus = contacts.updateContactRequestStatus;
exports.blockChat = contacts.blockChat;
exports.unblockChat = contacts.unblockChat;
exports.invalidateChatOnContactDelete = contacts.invalidateChatOnContactDelete;
exports.syncDeviceContacts = contacts.syncDeviceContacts;
exports.approveContactFromRequest = contacts.approveContactFromRequest;
exports.autoApproveContact = contacts.autoApproveContact;
exports.createContactFromGroupInvitation = contacts.createContactFromGroupInvitation;
exports.getChildContactsForModeration = contacts.getChildContactsForModeration;
exports.updateChildContactModeration = contacts.updateChildContactModeration;
exports.updateContactStatus = contacts.updateContactStatus;

// Grupos (legacy - mantener para compatibilidad durante migración)
exports.createGroup = groups.createGroup;
exports.leaveGroup = groups.leaveGroup;
exports.approveGroupPermission = groups.approveGroupPermission;
exports.updateGroupPermissionStatus = groups.updateGroupPermissionStatus;
exports.processGroupInvitationsAfterContactApproval = groups.processGroupInvitationsAfterContactApproval;

// Grupos V2 (nueva arquitectura con aprobación parental)
exports.createGroupV2 = groupsV2.createGroupV2;
exports.approveGroupMembership = groupsV2.approveGroupMembership;
exports.rejectGroupMembership = groupsV2.rejectGroupMembership;
exports.revokeGroupMembership = groupsV2.revokeGroupMembership;
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

// Moderación de contenido
// ✅ ELIMINADO: checkMessageBeforeSending - La moderación ahora se hace SOLO en el trigger moderateMessage
// exports.checkMessageBeforeSending = moderation.checkMessageBeforeSending;
exports.moderateMessage = moderation.moderateMessage;
exports.createApprovedMessage = moderation.createApprovedMessage;

// Chats
exports.incrementUnreadCount = chats.incrementUnreadCount;
exports.incrementGroupUnreadCount = chats.incrementGroupUnreadCount;
exports.sendChatMessage = chats.sendChatMessage;
exports.sendGroupMessage = chats.sendGroupMessage;
exports.createChat = chats.createChat;

// Emergencias
exports.createEmergency = emergency.createEmergency;

// Perfiles de usuario
exports.updateUserProfile = userProfile.updateUserProfile;
exports.onUserRegistered = userProfile.onUserRegistered;
exports.onPresenceChanged = userProfile.onPresenceChanged;

// Pagos y suscripciones
exports.checkPremiumStatus = payments.checkPremiumStatus;
exports.activatePremium = payments.activatePremium;
exports.createCheckoutSession = payments.createCheckoutSession;
exports.cancelSubscription = payments.cancelSubscription;
exports.handleStripeWebhook = payments.handleStripeWebhook;
exports.handleMercadoPagoWebhook = payments.handleMercadoPagoWebhook;

// Tareas programadas
exports.convertExpiredStoriesToPermanent = scheduledTasks.convertExpiredStoriesToPermanent;
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
exports.replyToStory = stories.replyToStory;
exports.likeStory = stories.likeStory;

// Story Approval (Secure Cloud Functions)
exports.createStory = storyApproval.createStory;
exports.approveStory = storyApproval.approveStory;
exports.rejectStory = storyApproval.rejectStory;

// Story availableFor Sync Triggers (mantener sincronizado con contactos/bloqueos)
exports.onBlockCreated = storyApproval.onBlockCreated;
exports.onBlockDeleted = storyApproval.onBlockDeleted;
exports.onContactCreated = storyApproval.onContactCreated;
exports.onContactUpdated = storyApproval.onContactUpdated;
exports.onContactDeleted = storyApproval.onContactDeleted;

// Story Notifications (notificar contactos cuando se sube historia)
exports.onStoryApproved = storyApproval.onStoryApproved;
exports.onStoryCreatedApproved = storyApproval.onStoryCreatedApproved;

// ═══════════════════════════════════════════════════════════════
// VIDEOLLAMADAS V2 (Agora) - NUEVA ARQUITECTURA
// ═══════════════════════════════════════════════════════════════

exports.createAgoraCall = callsV2.createAgoraCall;
exports.addParticipantToCall = callsV2.addParticipantToCall;
exports.onCallV2Updated = callsV2.onCallV2Updated; // Trigger para mensaje de llamada y tracking de minutos

// ═══════════════════════════════════════════════════════════════
// ❌ VOICE CHANGER y TTS - ELIMINADOS
// ═══════════════════════════════════════════════════════════════

console.log("✅ Todas las funciones exportadas correctamente (incluye Agora V2)");
