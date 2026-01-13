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

/**
 * Obtiene información de los participantes (edades y ubicaciones)
 * usando una única lectura batch de Firestore.
 *
 * OPTIMIZACIÓN: Reemplaza N queries secuenciales con 1 batch read.
 * Antes: O(n) queries donde n = número de participantes
 * Después: O(1) query batch
 *
 * @param {FirebaseFirestore.Firestore} db - Instancia de Firestore
 * @param {string[]} participantIds - Array de IDs de usuarios
 * @returns {Promise<{ages: number[], locations: string[]}>}
 */
async function getParticipantsInfo(db, participantIds) {
  const ages = [];
  const locations = [];

  // Si no hay participantes, retornar arrays vacíos
  if (!participantIds || participantIds.length === 0) {
    return { ages, locations };
  }

  try {
    // Crear referencias a todos los documentos de usuarios
    const userRefs = participantIds.map(id => db.collection('users').doc(id));

    // Fetch batch de todos los documentos en UNA sola llamada
    const userDocs = await db.getAll(...userRefs);

    // Procesar cada documento
    for (const doc of userDocs) {
      if (!doc.exists) continue;

      const userData = doc.data();

      // Extraer edad si existe birthDate
      if (userData.birthDate) {
        const birthDate = userData.birthDate.toDate
          ? userData.birthDate.toDate()
          : new Date(userData.birthDate);
        const age = Math.floor((new Date() - birthDate) / (365.25 * 24 * 60 * 60 * 1000));
        ages.push(age);
      }

      // Extraer ubicación (preferir location sobre country)
      const location = userData.location || userData.country;
      if (location) {
        locations.push(location);
      }
    }
  } catch (error) {
    console.error('Error fetching participants info:', error);
    // En caso de error, retornar arrays vacíos para no bloquear el flujo
  }

  return { ages, locations };
}

module.exports = {
  shouldBlockByModerationLevel,
  getParticipantsInfo
};
