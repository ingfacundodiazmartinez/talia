const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const { validateReportParams, checkRateLimit, RATE_LIMITS } = require("./helpers");

// ═══════════════════════════════════════════════════════════════
// REPORTS
// ═══════════════════════════════════════════════════════════════

exports.generateChildReport = onCall(
  {
    cors: true,
    consumeAppCheckToken: true,
  },
  async (request) => {
    console.log("📊 Generando reporte de análisis");

    // Verificar que el usuario esté autenticado
    if (!request.auth) {
      console.log("❌ Usuario no autenticado");
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const parentId = request.auth.uid;
    console.log(`✅ Usuario autenticado: ${parentId}`);

    // ✅ VALIDACIÓN DE INPUTS: Validar parámetros
    const validation = validateReportParams(request.data);
    if (!validation.valid) {
      console.error(`❌ Validación de inputs falló: ${validation.error}`);
      throw new HttpsError("invalid-argument", validation.error);
    }

    // ✅ RATE LIMITING: Verificar límite de solicitudes
    const rateLimitCheck = await checkRateLimit(
      parentId,
      "generateReport",
      RATE_LIMITS.generateReport
    );
    if (!rateLimitCheck.allowed) {
      console.warn(
        `🚫 Rate limit excedido para ${parentId} - Reintentar en ${rateLimitCheck.retryAfter}s`
      );
      throw new HttpsError(
        "resource-exhausted",
        `Demasiados reportes solicitados. Intenta nuevamente en ${rateLimitCheck.retryAfter} segundos.`
      );
    }

    // Obtener parámetros (ya validados)
    const { childId, daysBack } = request.data;

    const days = daysBack || 7; // Por defecto 7 días
    console.log(`📅 Analizando últimos ${days} días para hijo: ${childId}`);

    try {
      const db = getFirestore();

      // 1. Verificar que el usuario que llama es padre del niño
      const linkSnapshot = await db
        .collection("parent_children")
        .where("parentId", "==", parentId)
        .where("childId", "==", childId)
        .where("status", "==", "approved")
        .limit(1)
        .get();

      if (linkSnapshot.empty) {
        console.log(`❌ ${parentId} no es padre de ${childId}`);
        throw new HttpsError("permission-denied", "No tienes permiso para ver reportes de este niño");
      }

      console.log(`✅ Relación padre-hijo verificada`);

      // 2. Obtener chats donde participa el hijo
      const chatsSnapshot = await db
        .collection("chats")
        .where("participants", "array-contains", childId)
        .get();

      console.log(`💬 Chats encontrados: ${chatsSnapshot.docs.length}`);

      // 3. Recopilar TODOS los mensajes del HIJO en el período
      const weekAgo = new Date();
      weekAgo.setDate(weekAgo.getDate() - days);

      const allChildMessages = [];

      for (const chatDoc of chatsSnapshot.docs) {
        const chatId = chatDoc.id;

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
          `📨 Chat ${chatId}: ${messagesSnapshot.docs.length} mensajes del hijo`
        );

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

      if (allChildMessages.length === 0) {
        console.log("⚠️ No hay mensajes para analizar");
        throw new HttpsError("not-found", "No hay mensajes de los últimos " + days + " días para analizar");
      }

      // Ordenar mensajes por fecha
      allChildMessages.sort((a, b) => a.date - b.date);

      // 4. Analizar mensajes con Gemini AI (usando el enfoque de ponderación avanzada)
      console.log(`🤖 Analizando ${allChildMessages.length} mensajes con Gemini AI...`);

      const aiAnalysis = await analyzeMessagesWithGemini(allChildMessages, days, weekAgo, new Date());

      console.log(`✅ Análisis con IA completado`);

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

        // Metadata
        aiGenerated: true,
        aiModel: "gemini-pro",
        generatedAt: new Date(),
        percentageChange: percentageChange,
        hasPreviousReport: previousReport !== null,
      };

      // 7. Guardar reporte en Firestore
      const reportRef = await db.collection("weekly_reports").add(report);

      console.log(`✅ Reporte guardado: ${reportRef.id}`);

      // 8. Guardar también el análisis en ai_batch_analysis para compatibilidad
      await db.collection("ai_batch_analysis").add({
        childId: childId,
        messagesAnalyzed: allChildMessages.length,
        analysis: aiAnalysis,
        analyzedAt: new Date(),
      });

      console.log(`✅ Análisis guardado en ai_batch_analysis`);

      return {
        success: true,
        reportId: reportRef.id,
        report: report,
      };
    } catch (error) {
      console.error(`❌ Error generando reporte:`, error);
      // Re-throw HttpsError as-is, wrap others
      if (error.code && error.code.startsWith('functions/')) {
        throw error;
      }
      throw new HttpsError("internal", `Error generando reporte: ${error.message}`);
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
// FUNCIÓN CRÍTICA: Crear vínculo padre-hijo seguro
// ═══════════════════════════════════════════════════════════════
// Esta función maneja la vinculación padre-hijo con validación server-side
// Reemplaza la escritura directa bloqueada en Firestore rules

