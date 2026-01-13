/**
 * ═══════════════════════════════════════════════════════════════
 * MODERATION UTILS
 * ═══════════════════════════════════════════════════════════════
 *
 * Funciones utilitarias para el sistema de moderación.
 * Centralizan lógica que antes estaba duplicada en múltiples lugares.
 */

/**
 * Determina si un mensaje debe ser bloqueado basado en el análisis
 * de moderación y el nivel de moderación configurado.
 *
 * Matriz de bloqueo:
 * - HIGH: Bloquea severity 'low', 'medium', 'high'
 * - MEDIUM: Bloquea severity 'medium', 'high'
 * - LOW: Solo bloquea severity 'high'
 *
 * @param {Object} analysis - Resultado del análisis de moderación
 * @param {boolean} analysis.isInappropriate - Si el contenido es inapropiado
 * @param {string} analysis.severity - Nivel de severidad ('none', 'low', 'medium', 'high')
 * @param {string} moderationLevel - Nivel de moderación configurado ('low', 'medium', 'high')
 * @returns {boolean} - true si debe bloquearse, false si debe aprobarse
 */
function shouldBlockByModerationLevel(analysis, moderationLevel) {
  // Si no hay análisis o no es inapropiado, no bloquear
  if (!analysis?.isInappropriate) {
    return false;
  }

  // Si no hay severity, no bloquear
  if (!analysis.severity) {
    return false;
  }

  // Mapa de severidades que cada nivel de moderación bloquea
  const severityMap = {
    high: ['low', 'medium', 'high'],
    medium: ['medium', 'high'],
    low: ['high']
  };

  // Si el nivel no es válido, usar 'high' como default (más restrictivo)
  const effectiveLevel = severityMap[moderationLevel] ? moderationLevel : 'high';

  // Verificar si la severidad del análisis está en la lista de bloqueo
  return severityMap[effectiveLevel].includes(analysis.severity);
}

module.exports = {
  shouldBlockByModerationLevel
};
