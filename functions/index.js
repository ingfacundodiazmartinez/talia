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
 * Última actualización: 2025-10-28
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

// Videollamadas
const videoCalls = require("./video-calls");

// Reportes
const reports = require("./reports");

// Gestión padre-hijo
const parentChild = require("./parent-child");

// Contactos y bloqueos
const contacts = require("./contacts");

// Grupos
const groups = require("./groups");

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

// ═══════════════════════════════════════════════════════════════
// RE-EXPORTS
// ═══════════════════════════════════════════════════════════════

// Notificaciones
exports.sendNotificationOnCreate = notifications.sendNotificationOnCreate;

// Videollamadas
exports.generateAgoraToken = videoCalls.generateAgoraToken;

// Reportes
exports.generateChildReport = reports.generateChildReport;

// Gestión padre-hijo
exports.createParentChildLink = parentChild.createParentChildLink;
exports.unlinkChild = parentChild.unlinkChild;
exports.onParentChildLinkCreated = parentChild.onParentChildLinkCreated;
exports.onParentChildLinkDeleted = parentChild.onParentChildLinkDeleted;

// Contactos y bloqueos
exports.createContactRequest = contacts.createContactRequest;
exports.updateContactRequestStatus = contacts.updateContactRequestStatus;
exports.blockChat = contacts.blockChat;
exports.unblockChat = contacts.unblockChat;

// Grupos
exports.createGroup = groups.createGroup;
exports.approveGroupPermission = groups.approveGroupPermission;
exports.updateGroupPermissionStatus = groups.updateGroupPermissionStatus;
exports.processGroupInvitationsAfterContactApproval = groups.processGroupInvitationsAfterContactApproval;

// Moderación de contenido
exports.checkMessageBeforeSending = moderation.checkMessageBeforeSending;
exports.moderateMessage = moderation.moderateMessage;

// Chats
exports.incrementUnreadCount = chats.incrementUnreadCount;
exports.markChatAsRead = chats.markChatAsRead;

// Emergencias
exports.createEmergency = emergency.createEmergency;

// Perfiles de usuario
exports.updateUserProfile = userProfile.updateUserProfile;
exports.onUserRegistered = userProfile.onUserRegistered;

// Pagos y suscripciones
exports.checkPremiumStatus = payments.checkPremiumStatus;
exports.activatePremium = payments.activatePremium;
exports.createCheckoutSession = payments.createCheckoutSession;
exports.cancelSubscription = payments.cancelSubscription;
exports.handleStripeWebhook = payments.handleStripeWebhook;
exports.handleMercadoPagoWebhook = payments.handleMercadoPagoWebhook;

// Tareas programadas
exports.convertExpiredStoriesToPermanent = scheduledTasks.convertExpiredStoriesToPermanent;
exports.cleanupOldMessages = scheduledTasks.cleanupOldMessages;
exports.autoResolveEmergencies = scheduledTasks.autoResolveEmergencies;
exports.cleanupOldRateLimits = scheduledTasks.cleanupOldRateLimits;

// Transformaciones de imágenes
exports.transformCharacter = transformations.transformCharacter;

// Stickers
exports.syncStickersScheduled = stickerFunctions.syncStickersScheduled;
exports.syncStickersManual = stickerFunctions.syncStickersManual;
exports.cleanupOldStickers = stickerFunctions.cleanupOldStickers;

console.log("✅ Todas las funciones exportadas correctamente");
