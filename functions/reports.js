const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const { validateReportParams, checkRateLimit, RATE_LIMITS } = require("./helpers");

// Gemini AI para análisis de mensajes
const { GoogleGenerativeAI } = require("@google/generative-ai");
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const genAI = GEMINI_API_KEY ? new GoogleGenerativeAI(GEMINI_API_KEY) : null;

// ═══════════════════════════════════════════════════════════════
// GEMINI AI ANALYSIS FUNCTIONS
// ═══════════════════════════════════════════════════════════════

/**
 * Descargar multimedia de Firebase Storage y prepararlo para Gemini
 * @param {string} url - URL de Firebase Storage
 * @return {Promise<Object|null>} Objeto con datos del archivo o null si falla
 */
async function downloadMultimediaForGemini(url) {
  if (!url) return null;

  try {
    const storage = getStorage();

    // Extraer el path del archivo desde la URL de Firebase Storage
    let filePath = url;

    if (url.includes('firebasestorage.googleapis.com')) {
      const match = url.match(/\/o\/([^?]+)/);
      if (match) {
        filePath = decodeURIComponent(match[1]);
      }
    }

    console.log(`📥 Descargando multimedia: ${filePath}`);

    const bucket = storage.bucket();
    const file = bucket.file(filePath);

    const [buffer] = await file.download();
    const [metadata] = await file.getMetadata();
    const mimeType = metadata.contentType || 'application/octet-stream';

    console.log(`✅ Multimedia descargado: ${mimeType}, ${buffer.length} bytes`);

    return {
      mimeType: mimeType,
      data: buffer.toString('base64'),
    };
  } catch (error) {
    console.error(`❌ Error descargando multimedia de ${url}:`, error.message);
    return null;
  }
}

/**
 * Analiza mensajes por lotes con Gemini AI usando sistema de ponderación avanzada
 * @param {Array} messages - Array de mensajes con {text, timestamp, date}
 * @param {number} days - Número de días del período
 * @param {Date} periodStart - Fecha de inicio del período
 * @param {Date} periodEnd - Fecha de fin del período
 * @param {Array} moodPollResponses - Respuestas de mood polls (opcional)
 * @return {Promise<Object>} Análisis completo con ponderación
 */
// Límites de mensajes para batch processing
const MAX_MESSAGES_PER_BATCH = 300; // Mensajes por batch para análisis parcial
const MAX_BATCHES = 10; // Máximo de batches a procesar

/**
 * Analiza un batch de mensajes y retorna un resumen parcial
 * @param {Array} messages - Batch de mensajes
 * @param {number} batchNumber - Número del batch actual
 * @param {number} totalBatches - Total de batches
 * @param {Object} conversationContexts - Contexto de conversaciones
 * @return {Promise<Object>} Resumen parcial del batch
 */
async function analyzeBatchWithGemini(messages, batchNumber, totalBatches, conversationContexts = {}) {
  if (!genAI || messages.length === 0) {
    return {
      batch_number: batchNumber,
      messages_analyzed: 0,
      sentiment_summary: "neutral",
      sentiment_score: 0.5,
      critical_events: [],
      negative_grave_events: [],
      negative_moderate_events: [],
      positive_significant_events: [],
      positive_moderate_events: [],
      concerns: [],
      positive_aspects: [],
      key_topics: [],
    };
  }

  try {
    const model = genAI.getGenerativeModel({
      model: "gemini-2.5-flash",
    });

    // Construir prompt para análisis de batch
    let promptText = `Eres un experto en psicología infantil. Analiza este BATCH ${batchNumber}/${totalBatches} de mensajes de un niño/adolescente.

═══════════════════════════════════════════════════════════════
BATCH ${batchNumber} DE ${totalBatches} - ${messages.length} MENSAJES
═══════════════════════════════════════════════════════════════`;

    // Agregar contexto de conversaciones
    const contactNames = Object.keys(conversationContexts);
    if (contactNames.length > 0) {
      promptText += `\n\nCONTACTOS EN ESTE BATCH:`;
      contactNames.forEach(name => {
        const ctx = conversationContexts[name];
        if (ctx.messageCount > 0) {
          promptText += `\n• ${name}: ${ctx.messageCount} mensajes`;
        }
      });
    }

    promptText += `\n\n═══════════════════════════════════════════════════════════════
MENSAJES A ANALIZAR
═══════════════════════════════════════════════════════════════\n`;

    const contentParts = [{ text: promptText }];

    // Procesar cada mensaje del batch
    for (const msg of messages) {
      const msgDate = msg.date || new Date();
      const dateStr = `${msgDate.getDate()}/${msgDate.getMonth() + 1} ${msgDate.getHours()}:${String(msgDate.getMinutes()).padStart(2, '0')}`;
      const contactName = msg.chatContactName || 'Contacto';

      let msgText = `\n[${dateStr}] Con ${contactName}: `;
      if (msg.text && msg.text.trim()) {
        msgText += `"${msg.text}"`;
      }
      if (msg.imageUrl) msgText += " [Imagen]";
      if (msg.videoUrl) msgText += " [Video]";
      if (msg.audioUrl) msgText += " [Audio]";

      contentParts.push({ text: msgText });
    }

    // Instrucciones de análisis para batch
    contentParts.push({
      text: `

ANALIZA este batch y responde SOLO en JSON con este formato exacto:
{
  "batch_number": ${batchNumber},
  "messages_analyzed": ${messages.length},
  "sentiment_summary": "positive|negative|neutral",
  "sentiment_score": 0.0 a 1.0,
  "critical_events": ["eventos críticos: bullying, autolesión, amenazas, depresión severa"],
  "negative_grave_events": ["eventos negativos graves: conflictos serios, ansiedad severa"],
  "negative_moderate_events": ["eventos negativos moderados: tristeza, frustración"],
  "positive_significant_events": ["eventos positivos significativos: logros, felicidad profunda"],
  "positive_moderate_events": ["eventos positivos moderados: alegría momentánea"],
  "concerns": ["preocupaciones identificadas de forma GENERAL"],
  "positive_aspects": ["aspectos positivos detectados de forma GENERAL"],
  "key_topics": ["temas principales de conversación en este batch"]
}

REGLAS DE PRIVACIDAD: NO menciones palabras exactas ni nombres de personas.`
    });

    const result = await model.generateContent(contentParts);
    const response = await result.response;
    let text = response.text().trim();

    // Limpiar respuesta
    if (text.startsWith("```json")) text = text.substring(7);
    if (text.startsWith("```")) text = text.substring(3);
    if (text.endsWith("```")) text = text.substring(0, text.length - 3);

    return JSON.parse(text.trim());
  } catch (error) {
    console.error(`❌ Error analizando batch ${batchNumber}:`, error.message);
    return {
      batch_number: batchNumber,
      messages_analyzed: messages.length,
      sentiment_summary: "neutral",
      sentiment_score: 0.5,
      critical_events: [],
      negative_grave_events: [],
      negative_moderate_events: [],
      positive_significant_events: [],
      positive_moderate_events: [],
      concerns: [`Error en batch ${batchNumber}: ${error.message}`],
      positive_aspects: [],
      key_topics: [],
    };
  }
}

/**
 * Consolida los resúmenes parciales de todos los batches en un análisis final
 * @param {Array} batchResults - Array de resultados parciales de cada batch
 * @param {number} totalMessages - Total de mensajes analizados
 * @param {number} days - Número de días del período
 * @param {Array} moodPollResponses - Respuestas de mood polls
 * @return {Promise<Object>} Análisis consolidado final
 */
async function consolidateBatchResults(batchResults, totalMessages, days, moodPollResponses = []) {
  if (!genAI || batchResults.length === 0) {
    return getDefaultAnalysis(totalMessages);
  }

  try {
    const model = genAI.getGenerativeModel({
      model: "gemini-2.5-flash",
    });

    // Agregar resúmenes de batches al prompt
    let batchSummaries = batchResults.map(batch => `
BATCH ${batch.batch_number}:
- Mensajes: ${batch.messages_analyzed}
- Sentimiento: ${batch.sentiment_summary} (${batch.sentiment_score})
- Eventos críticos: ${batch.critical_events?.length || 0} (${batch.critical_events?.join(', ') || 'ninguno'})
- Eventos negativos graves: ${batch.negative_grave_events?.length || 0} (${batch.negative_grave_events?.join(', ') || 'ninguno'})
- Eventos negativos moderados: ${batch.negative_moderate_events?.length || 0}
- Eventos positivos significativos: ${batch.positive_significant_events?.length || 0}
- Preocupaciones: ${batch.concerns?.join(', ') || 'ninguna'}
- Aspectos positivos: ${batch.positive_aspects?.join(', ') || 'ninguno'}
- Temas principales: ${batch.key_topics?.join(', ') || 'varios'}`).join('\n');

    // Agregar mood polls si existen
    let moodPollSummary = '';
    if (moodPollResponses.length > 0) {
      moodPollSummary = `\n\n═══════════════════════════════════════════════════════════════
ENCUESTAS DE ÁNIMO (${moodPollResponses.length})
═══════════════════════════════════════════════════════════════`;
      moodPollResponses.forEach((poll, i) => {
        const pollDate = poll.respondedAt ? new Date(poll.respondedAt) : null;
        const dateStr = pollDate ? `${pollDate.getDate()}/${pollDate.getMonth() + 1}` : '';
        moodPollSummary += `\n${i + 1}. [${dateStr}] "${poll.questionText}" → ${poll.selectedEmoji} (sentimiento: ${poll.sentimentScore})`;
      });
    }

    const consolidationPrompt = `Eres un experto en psicología infantil. Analiza los siguientes RESÚMENES DE BATCHES para generar un ANÁLISIS CONSOLIDADO de los últimos ${days} días.

TOTAL DE MENSAJES ANALIZADOS: ${totalMessages}
NÚMERO DE BATCHES PROCESADOS: ${batchResults.length}

═══════════════════════════════════════════════════════════════
RESÚMENES POR BATCH
═══════════════════════════════════════════════════════════════
${batchSummaries}
${moodPollSummary}

═══════════════════════════════════════════════════════════════
SISTEMA DE PONDERACIÓN
═══════════════════════════════════════════════════════════════
- CRÍTICOS (peso x5): bullying, autolesión, amenazas, depresión severa
- NEGATIVOS GRAVES (peso x3): conflictos serios, ansiedad severa
- NEGATIVOS MODERADOS (peso x2): tristeza, frustración
- POSITIVOS SIGNIFICATIVOS (peso x2): logros, felicidad profunda
- REGLA: UN evento crítico domina el análisis, incluso con muchos positivos

Genera el análisis CONSOLIDADO en este formato JSON EXACTO:
{
  "sentiment_overall": "positive|negative|neutral",
  "sentiment_score": 0.0 a 1.0,
  "weighted_sentiment_score": 0.0 a 1.0,
  "mood_description": "descripción breve del estado de ánimo",
  "mood_icon": "emoji representativo",
  "bullying_detected": true|false,
  "bullying_severity": 0.0 a 1.0,
  "bullying_indicators": ["indicadores generales, sin palabras exactas"],
  "positive_aspects": ["aspectos positivos consolidados"],
  "concerns": ["preocupaciones consolidadas"],
  "recommendations": ["recomendaciones para los padres"],
  "suggested_questions": ["3-5 preguntas que el padre puede hacer"],
  "connection_moment": {
    "suggestion": "sugerencia de momento de conexión",
    "activity": "actividad sugerida",
    "reason": "por qué ayudaría",
    "emoji": "emoji"
  },
  "event_analysis": {
    "critical_events": {"count": número, "details": ["tipos generales"]},
    "negative_grave_events": {"count": número, "details": []},
    "negative_moderate_events": {"count": número, "details": []},
    "neutral_events": {"count": número},
    "positive_moderate_events": {"count": número, "details": []},
    "positive_significant_events": {"count": número, "details": []}
  },
  "weighted_calculation": {
    "critical_weight": "valor",
    "negative_grave_weight": "valor",
    "negative_moderate_weight": "valor",
    "positive_significant_weight": "valor",
    "final_weighted_score": "score final",
    "dominant_factor": "qué tipo domina"
  },
  "message_count_positive": número,
  "message_count_negative": número,
  "message_count_neutral": número,
  "batches_processed": ${batchResults.length},
  "total_messages_analyzed": ${totalMessages}
}

IMPORTANTE: Responde SOLO con el JSON.`;

    const result = await model.generateContent(consolidationPrompt);
    const response = await result.response;
    let text = response.text().trim();

    // Limpiar respuesta
    if (text.startsWith("```json")) text = text.substring(7);
    if (text.startsWith("```")) text = text.substring(3);
    if (text.endsWith("```")) text = text.substring(0, text.length - 3);

    const analysis = JSON.parse(text.trim());
    console.log(`✅ Análisis consolidado de ${batchResults.length} batches completado`);

    return analysis;
  } catch (error) {
    console.error(`❌ Error consolidando batches:`, error.message);
    return getDefaultAnalysis(totalMessages);
  }
}

/**
 * Retorna un análisis por defecto cuando hay errores
 */
function getDefaultAnalysis(messageCount) {
  return {
    sentiment_overall: "neutral",
    sentiment_score: 0.5,
    weighted_sentiment_score: 0.5,
    mood_description: "No se pudo analizar",
    mood_icon: "😐",
    bullying_detected: false,
    bullying_severity: 0,
    bullying_indicators: [],
    positive_aspects: [],
    concerns: ["Error en análisis"],
    recommendations: ["Revisar manualmente"],
    event_analysis: {
      critical_events: { count: 0, details: [] },
      negative_grave_events: { count: 0, details: [] },
      negative_moderate_events: { count: 0, details: [] },
      neutral_events: { count: messageCount },
      positive_moderate_events: { count: 0, details: [] },
      positive_significant_events: { count: 0, details: [] },
    },
    weighted_calculation: {
      critical_weight: 0,
      negative_grave_weight: 0,
      negative_moderate_weight: 0,
      positive_significant_weight: 0,
      final_weighted_score: 0.5,
      dominant_factor: "neutral",
    },
    message_count_positive: 0,
    message_count_negative: 0,
    message_count_neutral: messageCount,
  };
}

/**
 * Analiza mensajes usando batch processing para volúmenes grandes
 * @param {Array} messages - Array de mensajes
 * @param {number} days - Número de días del período
 * @param {Date} periodStart - Fecha de inicio
 * @param {Date} periodEnd - Fecha de fin
 * @param {Array} moodPollResponses - Respuestas de mood polls
 * @param {Object} conversationContexts - Contexto de conversaciones
 * @param {Function} onProgressUpdate - Callback para actualizar progreso
 * @return {Promise<Object>} Análisis completo
 */
async function analyzeMessagesWithGemini(messages, days, periodStart, periodEnd, moodPollResponses = [], conversationContexts = {}, onProgressUpdate = null) {
  if (!genAI) {
    console.warn("⚠️ Gemini API no configurado, usando análisis básico");
    return getDefaultAnalysis(messages.length);
  }

  const totalMessages = messages.length;
  console.log(`🔄 Iniciando análisis de ${totalMessages} mensajes...`);

  // Determinar si necesitamos batch processing
  const needsBatchProcessing = totalMessages > MAX_MESSAGES_PER_BATCH;

  if (needsBatchProcessing) {
    console.log(`📦 Usando BATCH PROCESSING para ${totalMessages} mensajes`);

    // Dividir mensajes en batches
    const batches = [];
    for (let i = 0; i < totalMessages && batches.length < MAX_BATCHES; i += MAX_MESSAGES_PER_BATCH) {
      batches.push(messages.slice(i, i + MAX_MESSAGES_PER_BATCH));
    }

    // Si hay más mensajes que los que podemos procesar, hacer sampling del resto
    const processedMessagesCount = batches.reduce((sum, batch) => sum + batch.length, 0);
    if (processedMessagesCount < totalMessages) {
      console.log(`⚠️ Limitando a ${MAX_BATCHES} batches (${processedMessagesCount} de ${totalMessages} mensajes)`);
    }

    console.log(`📊 Dividido en ${batches.length} batches`);

    // Procesar cada batch
    const batchResults = [];
    for (let i = 0; i < batches.length; i++) {
      const batch = batches[i];
      const batchNumber = i + 1;

      // Actualizar progreso si hay callback
      if (onProgressUpdate) {
        const baseProgress = 40; // Empezamos en 40%
        const batchProgress = baseProgress + Math.floor((i / batches.length) * 35);
        await onProgressUpdate(batchProgress, `Analizando batch ${batchNumber}/${batches.length}...`);
      }

      console.log(`🔄 Procesando batch ${batchNumber}/${batches.length} (${batch.length} mensajes)...`);

      // Calcular contexto de conversaciones para este batch
      const batchContexts = {};
      batch.forEach(msg => {
        const contactName = msg.chatContactName || 'Contacto';
        if (!batchContexts[contactName]) {
          batchContexts[contactName] = { messageCount: 0 };
        }
        batchContexts[contactName].messageCount++;
      });

      const batchResult = await analyzeBatchWithGemini(batch, batchNumber, batches.length, batchContexts);
      batchResults.push(batchResult);

      console.log(`✅ Batch ${batchNumber} completado - Sentimiento: ${batchResult.sentiment_summary}`);
    }

    // Consolidar todos los resultados
    if (onProgressUpdate) {
      await onProgressUpdate(75, "Consolidando análisis...");
    }

    console.log(`🔄 Consolidando ${batchResults.length} resultados de batches...`);
    const consolidatedAnalysis = await consolidateBatchResults(batchResults, totalMessages, days, moodPollResponses);

    return consolidatedAnalysis;
  }

  // Si no necesita batch processing, usar análisis directo (original optimizado)
  console.log(`📦 Usando análisis directo para ${totalMessages} mensajes`);

  try {
    const model = genAI.getGenerativeModel({
      model: "gemini-2.5-flash",
    });

    const contentParts = [];

    // Construir prompt principal con contexto
    let promptText = `Eres un experto en psicología infantil y análisis de comunicación. Analiza los siguientes mensajes de un niño/adolescente de los ÚLTIMOS ${days} DÍAS.

═══════════════════════════════════════════════════════════════
INFORMACIÓN DEL PERÍODO
═══════════════════════════════════════════════════════════════
- Período: ${periodStart.getDate()}/${periodStart.getMonth() + 1}/${periodStart.getFullYear()} - ${periodEnd.getDate()}/${periodEnd.getMonth() + 1}/${periodEnd.getFullYear()}
- Total de mensajes: ${totalMessages}`;

    // Agregar contexto de conversaciones
    const contactNames = Object.keys(conversationContexts);
    if (contactNames.length > 0) {
      promptText += `\n\n═══════════════════════════════════════════════════════════════
CONTACTOS CON LOS QUE HABLÓ
═══════════════════════════════════════════════════════════════`;
      contactNames.forEach(name => {
        const ctx = conversationContexts[name];
        promptText += `\n• ${name}: ${ctx.messageCount} mensajes`;
      });
    }

    // Agregar información de mood polls si existen
    if (moodPollResponses && moodPollResponses.length > 0) {
      promptText += `\n\n═══════════════════════════════════════════════════════════════
ENCUESTAS DE ÁNIMO RESPONDIDAS (${moodPollResponses.length})
═══════════════════════════════════════════════════════════════`;
      moodPollResponses.forEach((poll, i) => {
        const pollDate = poll.respondedAt ? new Date(poll.respondedAt) : null;
        const dateStr = pollDate ? `${pollDate.getDate()}/${pollDate.getMonth() + 1}` : '';
        promptText += `\n${i + 1}. [${dateStr}] "${poll.questionText}" → ${poll.selectedEmoji} (sentimiento: ${poll.sentimentScore})`;
      });
    }

    promptText += `\n\n═══════════════════════════════════════════════════════════════
MENSAJES DEL NIÑO (enviados por él/ella)
═══════════════════════════════════════════════════════════════`;

    contentParts.push({ text: promptText });

    // Procesar cada mensaje
    for (const msg of messages) {
      const msgDate = msg.date || new Date();
      const dateStr = `${msgDate.getDate()}/${msgDate.getMonth() + 1} ${msgDate.getHours()}:${String(msgDate.getMinutes()).padStart(2, '0')}`;
      const contactName = msg.chatContactName || 'Contacto';

      let msgText = `\n[${dateStr}] Con ${contactName}: `;
      if (msg.text && msg.text.trim()) {
        msgText += `"${msg.text}"`;
      }
      if (msg.imageUrl) msgText += " [Imagen]";
      if (msg.videoUrl) msgText += " [Video]";
      if (msg.audioUrl) msgText += " [Audio]";

      contentParts.push({ text: msgText });
    }

    console.log(`📊 Contenido preparado con ${contentParts.length} partes`);

    // Agregar instrucciones de análisis
    contentParts.push({
      text: `

SISTEMA DE PONDERACIÓN (del más grave al menos grave):
- CRÍTICOS (peso x5): bullying, autolesión, amenazas, depresión severa, ideas suicidas
- NEGATIVOS GRAVES (peso x3): conflictos familiares serios, problemas académicos graves, ansiedad severa, aislamiento social
- NEGATIVOS MODERADOS (peso x2): tristeza persistente, frustración, enojo, problemas menores
- NEUTROS (peso x1): actividades cotidianas, conversaciones normales
- POSITIVOS MODERADOS (peso x1): alegría momentánea, actividades divertidas
- POSITIVOS SIGNIFICATIVOS (peso x2): logros importantes, momentos de felicidad profunda, apoyo social fuerte

REGLAS DE ANÁLISIS:
1. UN SOLO evento CRÍTICO debe dominar el estado general, incluso con múltiples eventos positivos
2. Eventos NEGATIVOS GRAVES requieren al menos 3-4 eventos POSITIVOS SIGNIFICATIVOS para equilibrar
3. El contexto y la frecuencia de eventos negativos es crucial
4. Considera patrones: ¿los eventos negativos están aumentando o disminuyendo?
5. Las encuestas de ánimo (mood polls) dan contexto directo del estado emocional del niño

Proporciona tu análisis en el siguiente formato JSON EXACTO (solo JSON, sin texto adicional):
{
  "sentiment_overall": "positive|negative|neutral",
  "sentiment_score": 0.0 a 1.0,
  "weighted_sentiment_score": 0.0 a 1.0,
  "mood_description": "descripción breve del estado de ánimo considerando ponderación",
  "mood_icon": "emoji representativo",
  "bullying_detected": true|false,
  "bullying_severity": 0.0 a 1.0,
  "bullying_indicators": ["tipos generales de indicadores, SIN palabras exactas ni nombres"],
  "positive_aspects": ["aspectos positivos detectados de forma GENERAL"],
  "concerns": ["preocupaciones identificadas de forma GENERAL, sin mencionar palabras exactas"],
  "recommendations": ["recomendaciones para los padres"],
  "suggested_questions": ["3-5 preguntas que el padre puede hacerle al hijo. USA LOS NOMBRES REALES de los contactos que aparecen arriba en 'CONTACTOS CON LOS QUE HABLÓ'. Ejemplo: '¿Cómo te llevas con María?' NO uses placeholders como [Contacto_1]"],
  "connection_moment": {
    "suggestion": "sugerencia de momento de conexión",
    "activity": "actividad sugerida",
    "reason": "por qué esta actividad ayudaría",
    "emoji": "emoji representativo"
  },
  "event_analysis": {
    "critical_events": {"count": número, "details": ["tipos de eventos críticos de forma GENERAL"]},
    "negative_grave_events": {"count": número, "details": ["tipos de eventos negativos graves"]},
    "negative_moderate_events": {"count": número, "details": ["tipos de eventos negativos moderados"]},
    "neutral_events": {"count": número},
    "positive_moderate_events": {"count": número, "details": ["tipos de eventos positivos moderados"]},
    "positive_significant_events": {"count": número, "details": ["tipos de eventos positivos significativos"]}
  },
  "weighted_calculation": {
    "critical_weight": "valor calculado (críticos * 5)",
    "negative_grave_weight": "valor calculado (neg_graves * 3)",
    "negative_moderate_weight": "valor calculado (neg_moderados * 2)",
    "positive_significant_weight": "valor calculado (pos_significativos * 2)",
    "final_weighted_score": "score final ponderado",
    "dominant_factor": "qué tipo de eventos domina el análisis"
  },
  "message_count_positive": número,
  "message_count_negative": número,
  "message_count_neutral": número
}

REGLAS DE PRIVACIDAD CRÍTICAS:
- NO menciones NUNCA palabras exactas de los mensajes
- NO menciones nombres en concerns, recommendations, bullying_indicators ni positive_aspects
- EXCEPCIÓN: En suggested_questions SÍ puedes usar los nombres de contactos para personalizar las preguntas
- Describe los eventos de forma GENERAL
- Respeta la privacidad del niño en todo momento

IMPORTANTE:
- Responde SOLO con el JSON, sin texto adicional antes o después
- Aplica ESTRICTAMENTE el sistema de ponderación
- Si hay eventos críticos, el sentiment_overall debe ser "negative"`
    });

    console.log(`🚀 Enviando ${contentParts.length} partes de contenido a Gemini...`);
    const result = await model.generateContent(contentParts);
    const response = await result.response;
    const text = response.text();

    // Limpiar la respuesta
    let cleanedResponse = text.trim();
    if (cleanedResponse.startsWith("```json")) {
      cleanedResponse = cleanedResponse.substring(7);
    }
    if (cleanedResponse.startsWith("```")) {
      cleanedResponse = cleanedResponse.substring(3);
    }
    if (cleanedResponse.endsWith("```")) {
      cleanedResponse = cleanedResponse.substring(0, cleanedResponse.length - 3);
    }
    cleanedResponse = cleanedResponse.trim();

    const analysis = JSON.parse(cleanedResponse);
    console.log("🤖 Análisis Gemini completado");

    return analysis;
  } catch (error) {
    console.error("❌ Error analizando mensajes con Gemini:", error);
    return {
      sentiment_overall: "neutral",
      sentiment_score: 0.5,
      weighted_sentiment_score: 0.5,
      mood_description: "No se pudo analizar (error en IA)",
      mood_icon: "😐",
      bullying_detected: false,
      bullying_severity: 0,
      bullying_indicators: [],
      positive_aspects: [],
      concerns: ["Error en análisis de IA: " + error.message],
      recommendations: ["Revisar mensajes manualmente"],
      event_analysis: {
        critical_events: { count: 0, details: [] },
        negative_grave_events: { count: 0, details: [] },
        negative_moderate_events: { count: 0, details: [] },
        neutral_events: { count: messages.length },
        positive_moderate_events: { count: 0, details: [] },
        positive_significant_events: { count: 0, details: [] },
      },
      weighted_calculation: {
        critical_weight: 0,
        negative_grave_weight: 0,
        negative_moderate_weight: 0,
        positive_significant_weight: 0,
        final_weighted_score: 0.5,
        dominant_factor: "neutral",
      },
      message_count_positive: 0,
      message_count_negative: 0,
      message_count_neutral: messages.length,
    };
  }
}

// ═══════════════════════════════════════════════════════════════
// REPORTS - ASYNC GENERATION
// ═══════════════════════════════════════════════════════════════

/**
 * Solicitar generación de reporte (async)
 * Solo crea el pending_report y retorna inmediatamente
 * El procesamiento real ocurre en onPendingReportCreated
 */
exports.generateChildReport = onCall(
  {
    cors: true,
    consumeAppCheckToken: true,
  },
  async (request) => {
    console.log("📊 Solicitando generación de reporte async");

    // Verificar autenticación
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const parentId = request.auth.uid;

    // Validar parámetros
    const validation = validateReportParams(request.data);
    if (!validation.valid) {
      throw new HttpsError("invalid-argument", validation.error);
    }

    // Rate limiting
    const rateLimitCheck = await checkRateLimit(
      parentId,
      "generateReport",
      RATE_LIMITS.generateReport
    );
    if (!rateLimitCheck.allowed) {
      throw new HttpsError(
        "resource-exhausted",
        `Demasiados reportes solicitados. Intenta en ${rateLimitCheck.retryAfter} segundos.`
      );
    }

    const { childId, daysBack } = request.data;
    const days = daysBack || 7;

    const db = getFirestore();

    // ✅ OPTIMIZACIÓN: Ejecutar queries en PARALELO para reducir latencia
    const [linkSnapshot, childDoc, existingPending] = await Promise.all([
      // 1. Verificar relación padre-hijo
      db.collection("parent_children")
        .where("parentId", "==", parentId)
        .where("childId", "==", childId)
        .where("status", "==", "approved")
        .limit(1)
        .get(),

      // 2. Obtener nombre del hijo
      db.collection("users").doc(childId).get(),

      // 3. Verificar si ya hay un reporte pendiente
      db.collection("pending_reports")
        .where("parentId", "==", parentId)
        .where("childId", "==", childId)
        .where("status", "==", "processing")
        .limit(1)
        .get(),

      // Límite semanal ELIMINADO - ahora con ads el usuario puede generar reportes ilimitados
    ]);

    // Validar relación padre-hijo
    if (linkSnapshot.empty) {
      throw new HttpsError("permission-denied", "No tienes permiso para ver reportes de este niño");
    }

    // Si ya hay un reporte pendiente, retornar ese
    if (!existingPending.empty) {
      console.log(`⚠️ Ya hay un reporte pendiente para ${childId}`);
      return {
        success: true,
        pending: true,
        pendingReportId: existingPending.docs[0].id,
        message: "Ya hay un reporte en proceso. Te notificaremos cuando esté listo.",
      };
    }

    // Obtener nombre del hijo
    let childName = "tu hijo";
    if (childDoc.exists) {
      childName = childDoc.data().name || childDoc.data().displayName || "tu hijo";
    }

    // Crear pending_report (esto triggerea onPendingReportCreated)
    const pendingReport = {
      parentId,
      childId,
      childName,
      daysBack: days,
      status: "processing",
      requestedAt: new Date(),
      progress: 0,
      progressMessage: "Iniciando análisis...",
    };

    const pendingRef = await db.collection("pending_reports").add(pendingReport);
    console.log(`✅ Pending report creado: ${pendingRef.id}`);

    return {
      success: true,
      pending: true,
      pendingReportId: pendingRef.id,
      message: "Estamos generando el reporte. Te notificaremos cuando esté listo.",
    };
  }
);

// ═══════════════════════════════════════════════════════════════
// BACKGROUND REPORT PROCESSING
// ═══════════════════════════════════════════════════════════════

/**
 * Trigger: Cuando se crea un pending_report, procesar en background
 */
exports.onPendingReportCreated = onDocumentCreated(
  "pending_reports/{reportId}",
  async (event) => {
    const snapshot = event.data;
    if (!snapshot) {
      console.log("❌ No data en el evento");
      return;
    }

    const reportId = event.params.reportId;
    const data = snapshot.data();
    const { parentId, childId, childName, daysBack } = data;

    console.log(`🚀 Procesando reporte ${reportId} para hijo ${childId}`);

    const db = getFirestore();
    const reportRef = db.collection("pending_reports").doc(reportId);

    try {
      // Actualizar progreso
      await reportRef.update({
        progress: 10,
        progressMessage: "Recopilando mensajes...",
      });

      // Obtener chats donde participa el hijo
      const chatsSnapshot = await db
        .collection("chats")
        .where("participants", "array-contains", childId)
        .get();

      console.log(`💬 Chats encontrados: ${chatsSnapshot.docs.length}`);

      // Usar daysBack del pending report
      const days = daysBack || 7;

      // 3. Recopilar TODOS los mensajes del HIJO en el período
      const weekAgo = new Date();
      weekAgo.setDate(weekAgo.getDate() - days);

      const allChildMessages = [];
      const conversationContexts = {}; // Para tracking de con quién habla

      for (const chatDoc of chatsSnapshot.docs) {
        const chatId = chatDoc.id;
        const chatData = chatDoc.data();

        // Determinar el nombre del contacto (el otro participante del chat)
        let contactName = 'Contacto';
        let contactId = null;

        // Para chats 1:1, obtener el otro participante
        if (chatData.participants && chatData.participants.length === 2) {
          contactId = chatData.participants.find(p => p !== childId);
        }

        // Obtener nombre del contacto
        if (chatData.participantNames && contactId) {
          contactName = chatData.participantNames[contactId] || 'Contacto';
        } else if (chatData.name) {
          // Si es un grupo, usar el nombre del grupo
          contactName = chatData.name;
        }

        // Si no tenemos nombre, intentar obtenerlo del documento del usuario
        if (contactName === 'Contacto' && contactId) {
          try {
            const contactDoc = await db.collection('users').doc(contactId).get();
            if (contactDoc.exists) {
              contactName = contactDoc.data().name || contactDoc.data().displayName || 'Contacto';
            }
          } catch (e) {
            // Ignorar errores, usar "Contacto"
          }
        }

        // Obtener solo mensajes enviados POR EL HIJO
        const messagesSnapshot = await db
          .collection("chats")
          .doc(chatId)
          .collection("messages")
          .where("senderId", "==", childId)
          .where("timestamp", ">=", weekAgo)
          .orderBy("timestamp", "asc")
          .get();

        console.log(
          `📨 Chat con ${contactName}: ${messagesSnapshot.docs.length} mensajes del hijo`
        );

        // Trackear contexto de conversación
        if (messagesSnapshot.docs.length > 0) {
          if (!conversationContexts[contactName]) {
            conversationContexts[contactName] = { messageCount: 0 };
          }
          conversationContexts[contactName].messageCount += messagesSnapshot.docs.length;
        }

        for (const msgDoc of messagesSnapshot.docs) {
          const msgData = msgDoc.data();
          const text = msgData.text || "";
          const hasText = text.trim().length > 0;

          // Detectar multimedia
          const imageUrl = msgData.imageUrl || msgData.image || null;
          const videoUrl = msgData.videoUrl || msgData.video || null;
          const audioUrl = msgData.audioUrl || msgData.audio || null;
          const hasMultimedia = imageUrl || videoUrl || audioUrl;

          // Incluir el mensaje si tiene texto O multimedia
          if (hasText || hasMultimedia) {
            const message = {
              id: msgDoc.id,
              text: text,
              timestamp: msgData.timestamp,
              date: msgData.timestamp.toDate(),
              type: msgData.type || 'text',
              chatContactName: contactName, // Nombre del contacto
            };

            // Agregar URLs de multimedia si existen
            if (imageUrl) message.imageUrl = imageUrl;
            if (videoUrl) message.videoUrl = videoUrl;
            if (audioUrl) message.audioUrl = audioUrl;

            allChildMessages.push(message);
          }
        }
      }

      console.log(`📊 Total mensajes del hijo: ${allChildMessages.length}`);
      console.log(`👥 Contactos: ${Object.keys(conversationContexts).join(', ')}`);

      // Actualizar progreso
      await reportRef.update({
        progress: 30,
        progressMessage: `Encontrados ${allChildMessages.length} mensajes...`,
      });

      // 3.5. Obtener respuestas de mood polls del período
      let moodPollResponses = [];
      try {
        const pollResponsesSnapshot = await db
          .collection("mood_poll_responses")
          .where("userId", "==", childId)
          .where("respondedAt", ">=", weekAgo)
          .orderBy("respondedAt", "desc")
          .get();

        moodPollResponses = pollResponsesSnapshot.docs.map(doc => ({
          id: doc.id,
          ...doc.data(),
          respondedAt: doc.data().respondedAt?.toDate() || new Date(),
        }));

        console.log(`📊 Mood poll responses encontradas: ${moodPollResponses.length}`);
      } catch (error) {
        console.warn(`⚠️ Error obteniendo mood polls: ${error.message}`);
        // No fallar, continuar sin polls
      }

      if (allChildMessages.length === 0 && moodPollResponses.length === 0) {
        console.log("⚠️ No hay mensajes ni polls para analizar");
        // Marcar como completado pero sin datos
        await reportRef.update({
          status: "completed",
          progress: 100,
          progressMessage: "No hay datos para analizar",
          completedAt: new Date(),
          noData: true,
        });
        return; // Salir sin error, pero sin generar reporte
      }

      // Ordenar mensajes por fecha
      allChildMessages.sort((a, b) => a.date - b.date);

      // Actualizar progreso
      await reportRef.update({
        progress: 40,
        progressMessage: "Analizando con IA...",
      });

      // 4. Analizar mensajes con Gemini AI (usando batch processing para volúmenes grandes)
      console.log(`🤖 Analizando ${allChildMessages.length} mensajes y ${moodPollResponses.length} mood polls con Gemini AI...`);

      // Callback para actualizar progreso durante el batch processing
      const onProgressUpdate = async (progress, message) => {
        try {
          await reportRef.update({
            progress: progress,
            progressMessage: message,
          });
        } catch (e) {
          console.warn(`⚠️ Error actualizando progreso: ${e.message}`);
        }
      };

      const aiAnalysis = await analyzeMessagesWithGemini(
        allChildMessages,
        days,
        weekAgo,
        new Date(),
        moodPollResponses,
        conversationContexts,
        onProgressUpdate // Pasar callback de progreso
      );

      console.log(`✅ Análisis con IA completado`);

      // Actualizar progreso final
      await reportRef.update({
        progress: 80,
        progressMessage: "Generando reporte...",
      });

      // 4.5. Calcular estadísticas de mood polls
      const moodPollStats = calculateMoodPollStats(moodPollResponses);
      console.log(`📊 Mood poll stats: ${JSON.stringify(moodPollStats)}`);

      // Calcular estadísticas de multimedia
      const multimediaStats = {
        totalImages: 0,
        totalVideos: 0,
        totalAudios: 0,
        totalMultimedia: 0,
      };

      allChildMessages.forEach((msg) => {
        if (msg.imageUrl) multimediaStats.totalImages++;
        if (msg.videoUrl) multimediaStats.totalVideos++;
        if (msg.audioUrl) multimediaStats.totalAudios++;
      });

      multimediaStats.totalMultimedia =
        multimediaStats.totalImages +
        multimediaStats.totalVideos +
        multimediaStats.totalAudios;

      console.log(`📊 Estadísticas multimedia: ${multimediaStats.totalImages} imágenes, ${multimediaStats.totalVideos} videos, ${multimediaStats.totalAudios} audios`);

      // 5. Buscar reporte anterior para calcular variación
      let percentageChange = 0;
      let previousReport = null;

      try {
        const previousReportsSnapshot = await db
          .collection("weekly_reports")
          .where("childId", "==", childId)
          .where("parentId", "==", parentId)
          .orderBy("generatedAt", "desc")
          .limit(1)
          .get();

        if (!previousReportsSnapshot.empty) {
          previousReport = previousReportsSnapshot.docs[0].data();
          const previousAvgSentiment = previousReport.avgSentiment || 0.5;
          const currentAvgSentiment = aiAnalysis.weighted_sentiment_score || aiAnalysis.sentiment_score || 0.5;

          // Calcular cambio porcentual
          // Convertir sentimientos de escala 0-1 a escala -100 a +100 para mejor interpretación
          const previousScore = (previousAvgSentiment - 0.5) * 200; // -100 a +100
          const currentScore = (currentAvgSentiment - 0.5) * 200; // -100 a +100

          // Calcular diferencia absoluta (no porcentaje para evitar divisiones por cero)
          percentageChange = Math.round(currentScore - previousScore);

          console.log(`📈 Comparación con reporte anterior:`);
          console.log(`   Sentimiento anterior: ${previousAvgSentiment.toFixed(2)} (${previousScore.toFixed(1)})`);
          console.log(`   Sentimiento actual: ${currentAvgSentiment.toFixed(2)} (${currentScore.toFixed(1)})`);
          console.log(`   Cambio: ${percentageChange > 0 ? '+' : ''}${percentageChange} puntos`);
        } else {
          console.log(`ℹ️ No hay reportes anteriores para comparar`);
        }
      } catch (error) {
        console.warn(`⚠️ Error calculando variación con reporte anterior: ${error.message}`);
        // No fallar la función por esto, simplemente dejar percentageChange en 0
      }

      // 6. Construir reporte completo usando los resultados de Gemini
      const report = {
        childId: childId,
        parentId: parentId,
        period: `Últimos ${days} días`,
        periodDays: days,
        periodStart: weekAgo,
        periodEnd: new Date(),
        totalMessages: allChildMessages.length,

        // Estadísticas multimedia
        totalImages: multimediaStats.totalImages,
        totalVideos: multimediaStats.totalVideos,
        totalAudios: multimediaStats.totalAudios,
        totalMultimedia: multimediaStats.totalMultimedia,

        // Sentimiento general
        sentiment_overall: aiAnalysis.sentiment_overall,
        avgSentiment: aiAnalysis.weighted_sentiment_score || aiAnalysis.sentiment_score || 0.5,
        weightedSentimentScore: aiAnalysis.weighted_sentiment_score,
        originalSentimentScore: aiAnalysis.sentiment_score,

        // Estado de ánimo
        moodIcon: aiAnalysis.mood_icon || "😐",
        moodStatus: aiAnalysis.mood_description || "neutral",

        // Contadores de mensajes
        positiveCount: aiAnalysis.message_count_positive || 0,
        negativeCount: aiAnalysis.message_count_negative || 0,
        neutralCount: aiAnalysis.message_count_neutral || 0,

        // Bullying
        bullyingDetected: aiAnalysis.bullying_detected || false,
        bullyingSeverity: aiAnalysis.bullying_severity || 0,
        bullyingIndicators: aiAnalysis.bullying_indicators || [],
        bullyingIncidents: aiAnalysis.bullying_detected ? 1 : 0,

        // Aspectos positivos y preocupaciones
        positiveAspects: aiAnalysis.positive_aspects || [],
        concerns: aiAnalysis.concerns || [],
        recommendations: aiAnalysis.recommendations || [],

        // Análisis ponderado completo
        eventAnalysis: aiAnalysis.event_analysis || {},
        weightedCalculation: aiAnalysis.weighted_calculation || {},

        // Mood Poll Data
        moodPollStats: moodPollStats,
        moodPollResponses: moodPollResponses.map(r => ({
          questionText: r.questionText,
          selectedOptionText: r.selectedOptionText,
          selectedEmoji: r.selectedEmoji,
          sentimentScore: r.sentimentScore,
          respondedAt: r.respondedAt,
        })),

        // Preguntas sugeridas para conversar
        suggestedQuestions: aiAnalysis.suggested_questions || generateDefaultQuestions(aiAnalysis, moodPollResponses),

        // Momento de conexión semanal
        connectionMoment: aiAnalysis.connection_moment || generateConnectionMoment(aiAnalysis, moodPollResponses),

        // Metadata
        aiGenerated: true,
        aiModel: "gemini-pro",
        generatedAt: new Date(),
        percentageChange: percentageChange,
        hasPreviousReport: previousReport !== null,
      };

      // 7. Guardar reporte en Firestore
      const finalReportRef = await db.collection("weekly_reports").add(report);
      const finalReportId = finalReportRef.id;

      console.log(`✅ Reporte guardado: ${finalReportId}`);

      // 8. Guardar también el análisis en ai_batch_analysis para compatibilidad
      await db.collection("ai_batch_analysis").add({
        childId: childId,
        messagesAnalyzed: allChildMessages.length,
        analysis: aiAnalysis,
        analyzedAt: new Date(),
      });

      // 9. Actualizar pending_report como completado
      await reportRef.update({
        status: "completed",
        progress: 100,
        progressMessage: "Reporte listo",
        completedAt: new Date(),
        reportId: finalReportId,
      });

      console.log(`✅ Pending report ${reportId} marcado como completado`);

      // 10. Enviar notificación push al padre
      try {
        const parentDoc = await db.collection("users").doc(parentId).get();
        if (parentDoc.exists && parentDoc.data().fcmToken) {
          // ✅ Fetch user notification preferences
          let notificationPrefs = { soundEnabled: true, vibrationEnabled: true };
          try {
            const prefsDoc = await db.collection("notification_preferences").doc(parentId).get();
            if (prefsDoc.exists) {
              notificationPrefs.soundEnabled = prefsDoc.data().soundEnabled !== false;
              notificationPrefs.vibrationEnabled = prefsDoc.data().vibrationEnabled !== false;
            }
          } catch (e) { /* use defaults */ }

          // ✅ Select channel based on combination of sound/vibration preferences
          let channelId;
          if (notificationPrefs.soundEnabled && notificationPrefs.vibrationEnabled) {
            channelId = "talia_sound_vibration";
          } else if (notificationPrefs.soundEnabled && !notificationPrefs.vibrationEnabled) {
            channelId = "talia_sound_only";
          } else if (!notificationPrefs.soundEnabled && notificationPrefs.vibrationEnabled) {
            channelId = "talia_vibration_only";
          } else {
            channelId = "talia_silent";
          }

          const messaging = getMessaging();
          await messaging.send({
            token: parentDoc.data().fcmToken,
            notification: {
              title: "Reporte listo",
              body: `El reporte de ${childName} ya está disponible`,
            },
            data: {
              type: "report_ready",
              reportId: finalReportId,
              childId: childId,
              childName: childName,
            },
            android: {
              priority: "high",
              notification: {
                channelId: channelId,
                clickAction: "FLUTTER_NOTIFICATION_CLICK",
              },
            },
            apns: {
              headers: { "apns-priority": "10" },
              payload: {
                aps: {
                  alert: {
                    title: "Reporte listo",
                    body: `El reporte de ${childName} ya está disponible`,
                  },
                  // badge manejado por la app, no desde server
                  ...(notificationPrefs.soundEnabled && { sound: "default" }),
                },
              },
            },
          });
          console.log(`📱 Notificación enviada a padre ${parentId}`);
        }
      } catch (notifError) {
        console.error(`⚠️ Error enviando notificación:`, notifError);
        // No fallar por esto
      }

      console.log(`✅ Reporte ${finalReportId} generado exitosamente`);

    } catch (error) {
      console.error(`❌ Error generando reporte:`, error);

      // Marcar pending_report como fallido
      try {
        await reportRef.update({
          status: "failed",
          progress: 0,
          progressMessage: "Error al generar reporte",
          error: error.message || "Error desconocido",
          failedAt: new Date(),
        });
      } catch (updateError) {
        console.error(`❌ Error actualizando estado de fallo:`, updateError);
      }
    }
  }
);

// Funciones auxiliares para análisis (replicadas desde Dart)
function analyzeSentiment(message) {
  if (!message) return { sentiment: "neutral", score: 0.0 };

  const messageLower = message.toLowerCase();

  const sentimentKeywords = {
    // Positivas
    feliz: 0.8,
    bien: 0.6,
    genial: 0.9,
    excelente: 0.9,
    bueno: 0.7,
    alegre: 0.8,
    contento: 0.8,
    divertido: 0.7,
    amo: 0.9,
    "me gusta": 0.7,
    increíble: 0.9,
    perfecto: 0.8,
    hermoso: 0.8,
    maravilloso: 0.9,
    fantástico: 0.9,
    gracias: 0.6,
    jaja: 0.7,
    jeje: 0.7,
    lol: 0.7,
    "😊": 0.8,
    "😄": 0.8,
    "😃": 0.8,
    "❤️": 0.9,
    "😍": 0.9,
    "👍": 0.7,
    "✨": 0.6,
    "🎉": 0.8,
    "😁": 0.8,
    // Negativas
    triste: -0.8,
    mal: -0.6,
    horrible: -0.9,
    terrible: -0.9,
    odio: -0.9,
    feo: -0.7,
    aburrido: -0.5,
    molesto: -0.7,
    enojado: -0.8,
    furioso: -0.9,
    llorar: -0.7,
    deprimido: -0.9,
    asqueroso: -0.8,
    malo: -0.7,
    pésimo: -0.9,
    "no me gusta": -0.7,
    detesto: -0.9,
    "😢": -0.8,
    "😭": -0.9,
    "😡": -0.9,
    "😞": -0.7,
    "😔": -0.7,
    "👎": -0.7,
    "💔": -0.9,
    "😠": -0.8,
  };

  let totalScore = 0.0;
  let matchCount = 0;

  Object.keys(sentimentKeywords).forEach((keyword) => {
    if (messageLower.includes(keyword)) {
      totalScore += sentimentKeywords[keyword];
      matchCount++;
    }
  });

  const avgScore = matchCount > 0 ? totalScore / matchCount : 0.0;

  let sentiment;
  if (avgScore > 0.3) {
    sentiment = "positive";
  } else if (avgScore < -0.3) {
    sentiment = "negative";
  } else {
    sentiment = "neutral";
  }

  return { sentiment: sentiment, score: avgScore };
}

function detectBullying(message) {
  if (!message) return { hasBullying: false, severity: "none" };

  const messageLower = message.toLowerCase();

  const bullyingKeywords = [
    "tonto",
    "idiota",
    "estúpido",
    "burro",
    "inútil",
    "gordo",
    "feo",
    "perdedor",
    "nadie",
    "basura",
    "patético",
    "fracasado",
    "ridículo",
    "asco",
    "muérete",
    "mátate",
    "no sirves",
    "eres un",
    "callate",
    "cállate",
    "inservible",
    "débil",
    "te odio",
    "todos te odian",
    "nadie te quiere",
  ];

  const highSeverityKeywords = [
    "muérete",
    "mátate",
    "suicídate",
    "te odio",
    "todos te odian",
  ];

  let matchCount = 0;
  let hasHighSeverity = false;

  bullyingKeywords.forEach((keyword) => {
    if (messageLower.includes(keyword)) {
      matchCount++;
      if (highSeverityKeywords.includes(keyword)) {
        hasHighSeverity = true;
      }
    }
  });

  const hasBullying = matchCount > 0;
  let severity = "none";

  if (hasBullying) {
    if (hasHighSeverity || matchCount >= 3) {
      severity = "high";
    } else if (matchCount >= 2) {
      severity = "medium";
    } else {
      severity = "low";
    }
  }

  return {
    hasBullying: hasBullying,
    severity: severity,
    keywordCount: matchCount,
  };
}

// ═══════════════════════════════════════════════════════════════
// MOOD POLL HELPERS
// ═══════════════════════════════════════════════════════════════

/**
 * Calcula estadísticas de mood polls
 */
function calculateMoodPollStats(responses) {
  if (!responses || responses.length === 0) {
    return {
      totalPolls: 0,
      answeredPolls: 0,
      participationRate: 0,
      averageSentiment: 0,
      moodEmoji: "😐",
      moodDescription: "Sin datos",
      positiveCount: 0,
      negativeCount: 0,
      neutralCount: 0,
    };
  }

  const totalSentiment = responses.reduce((sum, r) => sum + (r.sentimentScore || 0), 0);
  const avgSentiment = totalSentiment / responses.length;

  const positiveCount = responses.filter(r => (r.sentimentScore || 0) > 0).length;
  const negativeCount = responses.filter(r => (r.sentimentScore || 0) < 0).length;
  const neutralCount = responses.filter(r => (r.sentimentScore || 0) === 0).length;

  let moodEmoji, moodDescription;
  if (avgSentiment >= 1.5) {
    moodEmoji = "😊";
    moodDescription = "Muy positivo";
  } else if (avgSentiment >= 0.5) {
    moodEmoji = "🙂";
    moodDescription = "Positivo";
  } else if (avgSentiment >= -0.5) {
    moodEmoji = "😐";
    moodDescription = "Neutral";
  } else if (avgSentiment >= -1.5) {
    moodEmoji = "😕";
    moodDescription = "Algo bajo";
  } else {
    moodEmoji = "😢";
    moodDescription = "Preocupante";
  }

  return {
    totalPolls: responses.length,
    answeredPolls: responses.length,
    participationRate: 100,
    averageSentiment: avgSentiment,
    moodEmoji,
    moodDescription,
    positiveCount,
    negativeCount,
    neutralCount,
  };
}

/**
 * Genera preguntas sugeridas basadas en el análisis
 */
function generateDefaultQuestions(aiAnalysis, moodPollResponses) {
  const questions = [];

  // Basado en concerns del análisis
  if (aiAnalysis.concerns && aiAnalysis.concerns.length > 0) {
    if (aiAnalysis.concerns.some(c => c.toLowerCase().includes("social") || c.toLowerCase().includes("amigo"))) {
      questions.push("¿Cómo te estás llevando con tus amigos últimamente?");
    }
    if (aiAnalysis.concerns.some(c => c.toLowerCase().includes("escuela") || c.toLowerCase().includes("estudio"))) {
      questions.push("¿Hay algo del colegio que te esté preocupando?");
    }
    if (aiAnalysis.concerns.some(c => c.toLowerCase().includes("trist") || c.toLowerCase().includes("ánimo"))) {
      questions.push("¿Hay algo que te haya hecho sentir mal esta semana?");
    }
  }

  // Basado en mood polls negativos
  const negativePolls = moodPollResponses.filter(r => (r.sentimentScore || 0) < 0);
  if (negativePolls.length > 0) {
    const lastNegative = negativePolls[0];
    if (lastNegative.questionText) {
      questions.push(`Sobre "${lastNegative.questionText}" - ¿Querés contarme más?`);
    }
  }

  // Preguntas generales si no hay específicas
  if (questions.length === 0) {
    questions.push("¿Cuál fue el mejor momento de tu semana?");
    questions.push("¿Hay algo en lo que te pueda ayudar?");
  }

  // Basado en aspectos positivos
  if (aiAnalysis.positive_aspects && aiAnalysis.positive_aspects.length > 0) {
    questions.push("Contame más sobre las cosas buenas que pasaron esta semana");
  }

  return questions.slice(0, 5); // Máximo 5 preguntas
}

/**
 * Genera el momento de conexión semanal
 */
function generateConnectionMoment(aiAnalysis, moodPollResponses) {
  const moment = {
    suggestion: "",
    activity: "",
    reason: "",
    emoji: "💬",
  };

  // Determinar el tipo de momento basado en el análisis
  const sentiment = aiAnalysis.weighted_sentiment_score || aiAnalysis.sentiment_score || 0.5;

  if (sentiment < 0.4) {
    // Sentimiento bajo - momento de apoyo
    moment.suggestion = "Tu hijo parece necesitar un poco de apoyo extra esta semana";
    moment.activity = "Dedica 15 minutos a conversar sin distracciones, preguntándole cómo se siente";
    moment.reason = "Los momentos de atención plena ayudan a fortalecer el vínculo y la confianza";
    moment.emoji = "🤗";
  } else if (sentiment < 0.6) {
    // Sentimiento neutro - momento de conexión
    moment.suggestion = "Es un buen momento para conectar a través de una actividad compartida";
    moment.activity = "Hagan algo juntos que a ambos les guste: jugar, cocinar, pasear";
    moment.reason = "Las actividades compartidas crean memorias positivas y fortalecen la relación";
    moment.emoji = "🎮";
  } else {
    // Sentimiento positivo - momento de celebración
    moment.suggestion = "¡Tu hijo tuvo una buena semana! Es momento de celebrar juntos";
    moment.activity = "Reconoce sus logros y planeen algo especial para hacer juntos";
    moment.reason = "Celebrar los momentos positivos refuerza conductas saludables";
    moment.emoji = "🎉";
  }

  // Personalizar basado en mood polls
  if (moodPollResponses.length > 0) {
    const avgPollSentiment = moodPollResponses.reduce((sum, r) => sum + (r.sentimentScore || 0), 0) / moodPollResponses.length;

    if (avgPollSentiment < -0.5) {
      moment.suggestion = "Las encuestas muestran que tu hijo podría estar pasando por un momento difícil";
      moment.activity = "Preguntale directamente: '¿Hay algo que te preocupe?' y escuchá sin juzgar";
      moment.emoji = "💙";
    }
  }

  return moment;
}

// ═══════════════════════════════════════════════════════════════
// FUNCIÓN CRÍTICA: Crear vínculo padre-hijo seguro
// ═══════════════════════════════════════════════════════════════
// Esta función maneja la vinculación padre-hijo con validación server-side
// Reemplaza la escritura directa bloqueada en Firestore rules

