/**
 * ═══════════════════════════════════════════════════════════════
 * GEMINI ANALYZER - Análisis de contenido con IA
 * ═══════════════════════════════════════════════════════════════
 *
 * Funciones de análisis de contenido usando Google Gemini AI.
 * Utilizado por el sistema de moderación para detectar contenido
 * inapropiado en mensajes de chat.
 *
 * ═══════════════════════════════════════════════════════════════
 */

const { GoogleGenerativeAI } = require("@google/generative-ai");

// Configuración de Gemini
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const genAI = GEMINI_API_KEY ? new GoogleGenerativeAI(GEMINI_API_KEY) : null;

if (!genAI) {
  console.warn("⚠️ [GeminiAnalyzer] GEMINI_API_KEY no configurado");
}

/**
 * Analiza un mensaje con Gemini AI para detectar contenido inapropiado
 *
 * @param {string} messageText - Texto del mensaje a analizar
 * @param {string} messageType - Tipo de mensaje (text, image, video, audio)
 * @param {string} conversationContext - Contexto de la conversación (últimos mensajes)
 * @param {string} moderationLevel - Nivel de moderación (high, medium, low)
 * @param {Array} participantsAges - Edades de los participantes
 * @param {Array} participantsLocations - Ubicaciones de los participantes
 * @return {Promise<Object>} Resultado del análisis con isInappropriate, severity, reason
 */
async function analyzeMessageWithGemini(
  messageText,
  messageType = "text",
  conversationContext = "",
  moderationLevel = "high",
  participantsAges = [],
  participantsLocations = []
) {
  if (!genAI) {
    console.warn("⚠️ Gemini API no configurado, aprobando mensaje automáticamente");
    return {
      isInappropriate: false,
      severity: "none",
      reason: "API no configurada",
    };
  }

  try {
    // Usar gemini-2.5-flash-lite (drop-in replacement de 2.0-flash-lite,
    // mismo precio $0.10/$0.40 por 1M tokens, mejor calidad).
    const model = genAI.getGenerativeModel({
      model: "gemini-2.5-flash-lite",
    });

    const contextSection = conversationContext
      ? `\nCONTEXTO DE LA CONVERSACIÓN (últimos mensajes):\n${conversationContext}\n`
      : "";

    // Determinar si AMBOS participantes son adultos
    const allAdults =
      participantsAges.length >= 2 &&
      participantsAges.every((age) => age >= 18);
    const hasMinor = participantsAges.some((age) => age < 18);

    // Construir sección de contexto de participantes
    const participantsSection = `
INFORMACIÓN DE LOS PARTICIPANTES:
- Edades: ${participantsAges.length > 0 ? participantsAges.join(", ") + " años" : "no especificadas"}
- Ubicaciones: ${participantsLocations.length > 0 ? participantsLocations.join(", ") : "no especificadas"}
- Contexto: ${allAdults ? "AMBOS son adultos (>18 años)" : hasMinor ? "Hay al menos UN MENOR presente (<18 años)" : "Edades no especificadas"}
`;

    // Determinar instrucciones según el nivel de moderación
    let moderationInstructions;
    if (moderationLevel === "high") {
      moderationInstructions = `
NIVEL DE MODERACIÓN: HIGH (ESTRICTO)
- Bloquea contenido potencialmente peligroso, insultos directos y palabrotas
- Protege a menores de contenido cuestionable
- Permite lenguaje coloquial y tono informal sin insultos
- Ante duda sobre si es insulto o tono: bloquea
`;
    } else if (moderationLevel === "medium") {
      moderationInstructions = `
NIVEL DE MODERACIÓN: MEDIUM (EQUILIBRADO)
- Bloquea insultos directos, palabrotas y contenido sexual
- Permite lenguaje coloquial, sarcasmo e ironía sin insultos
- Más flexible con el tono, pero estricto con el contenido
- Solo bloquea cuando hay clara intención ofensiva
`;
    } else {
      moderationInstructions = `
NIVEL DE MODERACIÓN: LOW (PERMISIVO)
- Solo bloquea contenido MUY severo: amenazas, contenido sexual explícito, grooming, autolesión
- Permite lenguaje coloquial y vulgaridades si AMBOS son adultos
- Da el beneficio de la duda: si no estás completamente seguro, NO bloquees
- Respeta la libertad de expresión entre adultos
`;
    }

    // Instrucciones específicas según edad de participantes Y nivel de moderación
    let ageInstructions = "";
    if (allAdults) {
      if (moderationLevel === "high") {
        ageInstructions = `
⚠️ IMPORTANTE - CHAT ENTRE ADULTOS (NIVEL HIGH):
- AMBOS participantes son adultos (>18 años)
- BLOQUEA insultos directos y palabrotas
- Permite tono informal y lenguaje coloquial sin insultos
- El usuario quiere conversación respetuosa
`;
      } else if (moderationLevel === "medium") {
        ageInstructions = `
⚠️ IMPORTANTE - CHAT ENTRE ADULTOS (NIVEL MEDIUM):
- AMBOS participantes son adultos (>18 años)
- BLOQUEA solo insultos claros y contenido sexual
- Permite lenguaje coloquial, sarcasmo e ironía
- Sé flexible con el tono, estricto con el contenido
`;
      } else {
        ageInstructions = `
⚠️ IMPORTANTE - CHAT ENTRE ADULTOS (NIVEL LOW):
- AMBOS participantes son adultos (>18 años)
- NO bloquees vulgaridades o palabrotas entre adultos
- NO bloquees bromas adultas o humor irreverente
- Solo bloquea contenido muy peligroso: amenazas, acoso severo, contenido ilegal
- Respeta la libertad de expresión
`;
      }
    } else if (hasMinor) {
      ageInstructions = `
⚠️ IMPORTANTE - HAY UN MENOR PRESENTE:
- Al menos uno de los participantes es menor de 18 años
- Aplica protección de menores según nivel configurado
- HIGH: Bloquea insultos, palabrotas y contenido inapropiado
- MEDIUM: Bloquea insultos claros y contenido sexual
- LOW: Solo bloquea contenido muy severo
`;
    }

    const prompt = `Eres un experto en psicología infantil y protección de menores. Analiza el siguiente mensaje para detectar contenido inapropiado.

${participantsSection}
${moderationInstructions}
${ageInstructions}
${contextSection}
MENSAJE ACTUAL A ANALIZAR:
"${messageText}"
Tipo: ${messageType}

CATEGORÍAS DE CONTENIDO INAPROPIADO (ordenadas por gravedad):

🚨 CRÍTICO (severity: high):
- Amenazas de violencia física o daño
- Contenido sexual explícito o solicitudes sexuales
- Grooming o manipulación emocional de menores
- Autolesión o ideación suicida
- Compartir información personal peligrosa (dirección, ubicación en tiempo real)
- Contenido relacionado con drogas duras o actividades ilegales graves

⚠️ GRAVE (severity: medium) - SIEMPRE BLOQUEAR EN AMBOS NIVELES:
- Insultos directos: estúpido/a, tonto/a, idiota, feo/a, gordo/a, imbécil, tarado/a, etc.
- Palabrotas y lenguaje vulgar: puto/a, pelotudo/a, boludo/a, gil, mierda, carajo, verga, pija, hijo de puta, forro, etc.
- Insultos sexuales: zorra, perra, trola, maricón, tortillera, etc.
- Insinuaciones sexuales o violentas
- Acoso, discriminación, discurso de odio
- Burlas sobre apariencia física, capacidades o identidad

⚡ MODERADO (severity: low) - SOLO BLOQUEAR EN NIVEL HIGH:
- Tono levemente agresivo, sarcástico o irónico SIN insultos
- Ejemplos: "no seas exagerado", "qué pesado sos", "dale ya"
- Impaciencia o frustración expresada sin insultos

✅ APROPIADO (severity: none):
- Conversación normal, amistosa y respetuosa
- Emojis y expresiones comunes
- Temas apropiados para la edad

⚠️ REGLAS CRÍTICAS SEGÚN NIVEL DE MODERACIÓN:

NIVEL HIGH (estricto - solo conversación cordial):
- Bloquea TODO lo que no sea conversación cordial y educada
- Bloquea: insultos, palabrotas, sarcasmo agresivo, tono hostil, impaciencia
- Solo permite: conversación amistosa, respetuosa y positiva
- Ante cualquier duda sobre el tono: BLOQUEA con severity: low

NIVEL MEDIUM (equilibrado):
- Bloquea insultos directos y palabrotas (severity: medium)
- Permite sarcasmo, ironía y tono informal SIN insultos
- Solo bloquea cuando hay clara intención ofensiva

NIVEL LOW (permisivo en tono, estricto en contenido):
- Bloquea TODOS los insultos y palabrotas (severity: medium)
- Bloquea insinuaciones sexuales o violentas (severity: medium)
- Es PERMISIVO con el TONO: permite sarcasmo, ironía, impaciencia SIN insultos
- Ante duda sobre si es insulto: BLOQUEA. Ante duda sobre si es solo tono: PERMITE

IMPORTANTE: Los usuarios pueden REPORTAR mensajes manualmente. Si un mensaje fue reportado previamente por el usuario, considéralo como evidencia de que ese tipo de contenido le molesta y sé más estricto con mensajes similares.

Responde ÚNICAMENTE con un objeto JSON en este formato exacto (sin markdown, sin texto adicional):
{
  "isInappropriate": true/false,
  "severity": "none/low/medium/high",
  "reason": "categoría general del problema SIN citar el contenido del mensaje"
}

⚠️ SEGURIDAD: NUNCA incluyas el contenido del mensaje en la razón. Solo indica la CATEGORÍA general del problema.

EJEMPLOS DE RAZONES CORRECTAS:
- "Lenguaje vulgar u obsceno"
- "Lenguaje ofensivo o insultos"
- "Tono negativo o agresivo"
- "Contenido violento o amenazante"
- "Acoso o bullying"
- "Contenido sexual inapropiado"
- "Discriminación o discurso de odio"

EJEMPLOS DETALLADOS (cópialos LITERALMENTE):

Nivel HIGH (estricto - conversación cordial):
- "puto" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "hijo de puta" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "sos un idiota" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje ofensivo o insultos"}
- "pelotudo" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "boludo" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "no seas exagerado" → {"isInappropriate": true, "severity": "low", "reason": "Tono negativo o agresivo"}
- "qué pesado sos" → {"isInappropriate": true, "severity": "low", "reason": "Tono negativo o agresivo"}
- "dale ya" → {"isInappropriate": true, "severity": "low", "reason": "Tono negativo o agresivo"}
- "hola cómo estás" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}

Nivel LOW (permisivo en tono, estricto en insultos):
- "puto" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "hijo de puta" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "sos un idiota" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje ofensivo o insultos"}
- "pelotudo" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "boludo" → {"isInappropriate": true, "severity": "medium", "reason": "Lenguaje vulgar u obsceno"}
- "no seas exagerado" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}
- "qué pesado sos" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}
- "dale ya" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}
- "hola cómo estás" → {"isInappropriate": false, "severity": "none", "reason": "Conversación apropiada"}`;

    console.log(
      `🔍 [Gemini Moderation] Analizando mensaje (nivel: ${moderationLevel}, hasMinor: ${hasMinor})`
    );

    const result = await model.generateContent(prompt);
    const response = await result.response;
    const text = response.text();

    // Extraer JSON de la respuesta
    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (!jsonMatch) {
      console.error(
        "❌ Respuesta de Gemini no tiene formato JSON válido:",
        text
      );
      return {
        isInappropriate: false,
        severity: "none",
        reason: "Error parsing respuesta",
      };
    }

    const analysis = JSON.parse(jsonMatch[0]);
    console.log(`🤖 Análisis Gemini:`, analysis);

    return analysis;
  } catch (error) {
    console.error("❌ Error analizando mensaje con Gemini:", error);
    // En caso de error, aprobar el mensaje (fail-open para no bloquear conversaciones)
    return {
      isInappropriate: false,
      severity: "none",
      reason: "Error en análisis",
    };
  }
}

module.exports = {
  analyzeMessageWithGemini,
};
