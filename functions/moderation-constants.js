/**
 * ═══════════════════════════════════════════════════════════════
 * MODERATION CONSTANTS
 * ═══════════════════════════════════════════════════════════════
 *
 * Constantes centralizadas para el sistema de moderación.
 * Antes estaban hardcodeadas en múltiples lugares de moderation.js.
 */

/**
 * Tiempo de vida del cache de contexto de conversación.
 * Reduce lecturas de Firestore para conversaciones activas.
 */
const CONTEXT_CACHE_TTL_MS = 60000; // 1 minuto

/**
 * Tamaño máximo del cache de contexto.
 * Evita consumo excesivo de memoria.
 */
const CONTEXT_CACHE_MAX_SIZE = 100;

/**
 * Cantidad de mensajes a incluir en el contexto de conversación.
 * Usado para dar contexto a Gemini durante el análisis.
 */
const CONTEXT_MESSAGE_LIMIT = 20;

/**
 * Cantidad de mensajes reportados a incluir en el análisis.
 * Permite a Gemini aprender de las preferencias del usuario.
 */
const REPORTED_MESSAGES_LIMIT = 10;

/**
 * Días de vida para documentos con TTL policy.
 * Usado para auto-eliminación de mensajes via Firestore TTL.
 */
const MESSAGE_TTL_DAYS = 7;

/**
 * Niveles de moderación válidos.
 * Orden de restrictividad: high > medium > low > none
 */
const VALID_MODERATION_LEVELS = ['none', 'low', 'medium', 'high'];

module.exports = {
  CONTEXT_CACHE_TTL_MS,
  CONTEXT_CACHE_MAX_SIZE,
  CONTEXT_MESSAGE_LIMIT,
  REPORTED_MESSAGES_LIMIT,
  MESSAGE_TTL_DAYS,
  VALID_MODERATION_LEVELS,
};
