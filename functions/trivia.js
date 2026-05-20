/**
 * ═══════════════════════════════════════════════════════════════
 * TRIVIA - Cloud Functions
 * ═══════════════════════════════════════════════════════════════
 *
 * Funciones para el sistema de trivias personales:
 * - closeExpiredTrivias: Cierra trivias expiradas (scheduled)
 * - onTriviaResponseCreated: Notifica al creador (trigger)
 * - sendTriviaExpirationReminder: Recordatorio 1h antes (scheduled)
 * - onTriviaResultsPublished: Notifica ganadores (trigger)
 * - generateTriviaSuggestion: Genera preguntas con IA (callable)
 *
 * ═══════════════════════════════════════════════════════════════
 */

const { onSchedule } = require("firebase-functions/v2/scheduler");
const { onDocumentCreated, onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getStorage } = require("firebase-admin/storage");
const { checkRateLimit } = require("./helpers");
const { GoogleGenerativeAI } = require("@google/generative-ai");

// Configurar Gemini API
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const genAI = GEMINI_API_KEY ? new GoogleGenerativeAI(GEMINI_API_KEY) : null;

// Categorías disponibles para trivias
const TRIVIA_CATEGORIES = {
  familia: { name: "Familia", emoji: "👨‍👩‍👧‍👦", description: "Preguntas sobre tu familia" },
  gustos: { name: "Gustos", emoji: "❤️", description: "Tus cosas favoritas" },
  personalidad: { name: "Personalidad", emoji: "🎭", description: "Cómo eres" },
  cultura: { name: "Cultura", emoji: "🎬", description: "Películas, música, series" },
  curiosidades: { name: "Curiosidades", emoji: "🤔", description: "Datos interesantes" },
};

// ═══════════════════════════════════════════════════════════════
// GET TRIVIA PREVIEW - HTTP endpoint para link previews (OG meta tags)
// ═══════════════════════════════════════════════════════════════

/**
 * Endpoint público para obtener datos de preview de una trivia.
 * Usado por Vercel para generar HTML con Open Graph meta tags.
 */
exports.getTriviaPreview = onRequest(
  {
    region: "us-central1",
    cors: true,
  },
  async (req, res) => {
    if (req.method !== 'GET') {
      return res.status(405).json({ error: 'Method not allowed' });
    }

    const triviaId = req.query.id || req.path.split('/').pop();

    if (!triviaId) {
      return res.status(400).json({ error: 'Trivia ID is required' });
    }

    console.log(`📖 [TriviaPreview] Fetching trivia: ${triviaId}`);

    const db = getFirestore();

    try {
      const triviaDoc = await db.collection("trivias").doc(triviaId).get();

      if (!triviaDoc.exists) {
        console.log(`📖 [TriviaPreview] Trivia not found: ${triviaId}`);
        return res.status(404).json({
          found: false,
          error: 'Trivia not found'
        });
      }

      const triviaData = triviaDoc.data();

      // Solo devolver datos públicos para el preview
      const previewData = {
        found: true,
        title: triviaData.title || '¿Cuánto me conoces?',
        creatorName: triviaData.creatorName || 'Un amigo',
        creatorPhotoURL: triviaData.creatorPhotoURL || '',
        backgroundImageUrl: triviaData.backgroundImageUrl || '',
        questionCount: triviaData.questions?.length || 0,
        isActive: triviaData.status === 'active',
      };

      console.log(`✅ [TriviaPreview] Returning preview for: ${triviaId}`);

      res.set('Cache-Control', 'public, max-age=300, s-maxage=300');
      return res.status(200).json(previewData);

    } catch (error) {
      console.error(`❌ [TriviaPreview] Error fetching trivia ${triviaId}:`, error);
      return res.status(500).json({
        found: false,
        error: 'Internal server error'
      });
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// CIERRE AUTOMÁTICO DE TRIVIAS EXPIRADAS
// ═══════════════════════════════════════════════════════════════

/**
 * Scheduled function: Cierra trivias expiradas cada hora
 *
 * Busca trivias activas cuyo expiresAt ya pasó y las marca como expired.
 */
exports.closeExpiredTrivias = onSchedule(
  {
    schedule: "every 1 hours",
    timeZone: "America/Argentina/Buenos_Aires",
    region: "us-central1",
  },
  async (event) => {
    console.log("🕐 [Trivia] Checking for expired trivias...");

    const db = getFirestore();
    const storage = getStorage();
    const bucket = storage.bucket();
    const now = Timestamp.now();

    try {
      const expiredSnapshot = await db
        .collection("trivias")
        .where("status", "==", "active")
        .where("expiresAt", "<=", now)
        .get();

      if (expiredSnapshot.empty) {
        console.log("✅ [Trivia] No expired trivias found");
        return;
      }

      const batch = db.batch();
      const expiredTrivias = [];

      for (const doc of expiredSnapshot.docs) {
        const triviaData = doc.data();

        batch.update(doc.ref, {
          status: "expired",
          closedAt: FieldValue.serverTimestamp(),
        });

        expiredTrivias.push({
          id: doc.id,
          creatorId: triviaData.creatorId,
          title: triviaData.title,
          backgroundImageUrl: triviaData.backgroundImageUrl,
        });

        // Obtener imágenes de preguntas para eliminar
        const questionsSnapshot = await db
          .collection("trivias")
          .doc(doc.id)
          .collection("questions")
          .get();

        // Eliminar imágenes de preguntas
        for (const questionDoc of questionsSnapshot.docs) {
          const questionData = questionDoc.data();
          if (questionData.imageUrl) {
            try {
              const questionImagePath = extractStoragePath(questionData.imageUrl);
              if (questionImagePath) {
                await bucket.file(questionImagePath).delete();
                console.log(`🗑️ [Trivia] Deleted question image: ${questionImagePath}`);
              }
            } catch (imgError) {
              console.log(`⚠️ [Trivia] Could not delete question image: ${imgError.message}`);
            }
          }
        }

        // Eliminar imagen de fondo
        if (triviaData.backgroundImageUrl) {
          try {
            const bgImagePath = extractStoragePath(triviaData.backgroundImageUrl);
            if (bgImagePath) {
              await bucket.file(bgImagePath).delete();
              console.log(`🗑️ [Trivia] Deleted background image: ${bgImagePath}`);
            }
          } catch (imgError) {
            console.log(`⚠️ [Trivia] Could not delete background image: ${imgError.message}`);
          }
        }
      }

      await batch.commit();
      console.log(`✅ [Trivia] Closed ${expiredTrivias.length} expired trivias`);

      // Notificar a los creadores
      for (const trivia of expiredTrivias) {
        await db.collection("notifications").add({
          userId: trivia.creatorId,
          type: "trivia_expired",
          title: "Tu trivia ha expirado",
          body: `La trivia "${trivia.title}" ha finalizado`,
          data: { triviaId: trivia.id },
          createdAt: FieldValue.serverTimestamp(),
          read: false,
          pushSent: false,
        });
      }
    } catch (error) {
      console.error("❌ [Trivia] Error closing expired trivias:", error);
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// NOTIFICACIÓN: ALGUIEN RESPONDIÓ TU TRIVIA
// ═══════════════════════════════════════════════════════════════

/**
 * Trigger: Cuando se crea una respuesta de trivia
 *
 * Notifica al creador cuando alguien completa su trivia.
 * Rate limited: máx 5 notificaciones por hora al creador.
 */
exports.onTriviaResponseCreated = onDocumentCreated(
  {
    document: "trivia_responses/{responseId}",
    region: "us-central1",
  },
  async (event) => {
    const response = event.data?.data();
    if (!response) return;

    // Solo notificar si es respuesta completada o parcial
    if (response.status !== "completed" && response.status !== "partial") {
      return;
    }

    const db = getFirestore();

    try {
      // Obtener la trivia
      const triviaDoc = await db
        .collection("trivias")
        .doc(response.triviaId)
        .get();

      if (!triviaDoc.exists) {
        console.log("⚠️ [Trivia] Trivia not found:", response.triviaId);
        return;
      }

      const trivia = triviaDoc.data();
      const creatorId = trivia.creatorId;

      // Rate limiting: max 5 notificaciones por hora
      const rateLimitKey = `trivia_response_${creatorId}`;
      const canNotify = await checkRateLimit(rateLimitKey, 5, 3600000); // 1 hora

      if (!canNotify) {
        console.log(`⚠️ [Trivia] Rate limit exceeded for creator ${creatorId}`);
        return;
      }

      // Crear notificación
      await db.collection("notifications").add({
        userId: creatorId,
        type: "trivia_response",
        title: "Nueva respuesta en tu trivia",
        body: `${response.oderName} respondió tu trivia "${trivia.title}"`,
        data: {
          triviaId: response.triviaId,
          oderId: response.oderId,
          oderName: response.oderName,
          score: response.totalScore,
        },
        createdAt: FieldValue.serverTimestamp(),
        read: false,
        pushSent: false,
      });

      console.log(
        `📩 [Trivia] Notification sent to creator ${creatorId} for response from ${response.oderId}`
      );
    } catch (error) {
      console.error("❌ [Trivia] Error sending response notification:", error);
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// RECORDATORIO: 1 HORA ANTES DE EXPIRAR
// ═══════════════════════════════════════════════════════════════

/**
 * Scheduled function: Recordatorio al creador 1h antes de expirar
 *
 * Ejecuta cada 15 minutos y busca trivias que expiran en la próxima hora.
 */
exports.sendTriviaExpirationReminder = onSchedule(
  {
    schedule: "every 15 minutes",
    timeZone: "America/Argentina/Buenos_Aires",
    region: "us-central1",
  },
  async (event) => {
    console.log("🔔 [Trivia] Checking for expiring trivias...");

    const db = getFirestore();
    const now = new Date();
    const oneHourFromNow = new Date(now.getTime() + 60 * 60 * 1000);
    const oneHourAnd15MinFromNow = new Date(now.getTime() + 75 * 60 * 1000);

    try {
      const expiringSnapshot = await db
        .collection("trivias")
        .where("status", "==", "active")
        .where("expiresAt", ">=", Timestamp.fromDate(oneHourFromNow))
        .where("expiresAt", "<=", Timestamp.fromDate(oneHourAnd15MinFromNow))
        .get();

      if (expiringSnapshot.empty) {
        console.log("✅ [Trivia] No trivias expiring soon");
        return;
      }

      for (const doc of expiringSnapshot.docs) {
        const trivia = doc.data();

        // Verificar que no se haya enviado ya
        if (trivia.reminderSent) {
          continue;
        }

        // Crear notificación
        await db.collection("notifications").add({
          userId: trivia.creatorId,
          type: "trivia_expiring",
          title: "Tu trivia expira pronto",
          body: `"${trivia.title}" expira en 1 hora. ${trivia.participantCount || 0} personas han respondido.`,
          data: { triviaId: doc.id },
          createdAt: FieldValue.serverTimestamp(),
          read: false,
          pushSent: false,
        });

        // Marcar como enviado
        await doc.ref.update({ reminderSent: true });

        console.log(
          `🔔 [Trivia] Expiration reminder sent for trivia ${doc.id}`
        );
      }
    } catch (error) {
      console.error("❌ [Trivia] Error sending expiration reminders:", error);
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// NOTIFICACIÓN: RESULTADOS PUBLICADOS (TOP 3)
// ═══════════════════════════════════════════════════════════════

/**
 * Trigger: Cuando se actualizan los resultados de una trivia
 *
 * Notifica a los ganadores (top 3) cuando el creador comparte los resultados.
 */
exports.onTriviaResultsPublished = onDocumentUpdated(
  {
    document: "trivias/{triviaId}",
    region: "us-central1",
  },
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();

    if (!before || !after) return;

    // Solo cuando se publica resultsStoryId (antes no existía, ahora sí)
    if (before.resultsStoryId || !after.resultsStoryId) {
      return;
    }

    const triviaId = event.params.triviaId;
    const db = getFirestore();

    console.log(`🏆 [Trivia] Results published for trivia ${triviaId}`);

    try {
      // Obtener top 3 respuestas
      const topSnapshot = await db
        .collection("trivia_responses")
        .where("triviaId", "==", triviaId)
        .where("status", "in", ["completed", "partial"])
        .orderBy("totalScore", "desc")
        .orderBy("completedAt", "asc")
        .limit(3)
        .get();

      if (topSnapshot.empty) {
        console.log("⚠️ [Trivia] No responses for trivia:", triviaId);
        return;
      }

      const medals = ["1er", "2do", "3er"];
      const emojis = ["🥇", "🥈", "🥉"];

      for (let i = 0; i < topSnapshot.docs.length; i++) {
        const response = topSnapshot.docs[i].data();

        // No notificar al creador si por alguna razón está en el top
        if (response.oderId === after.creatorId) {
          continue;
        }

        await db.collection("notifications").add({
          userId: response.oderId,
          type: "trivia_winner",
          title: `${emojis[i]} ¡Felicitaciones! ${medals[i]} lugar`,
          body: `Quedaste en ${medals[i]} lugar en la trivia "${after.title}" con ${response.totalScore} puntos`,
          data: {
            triviaId: triviaId,
            storyId: after.resultsStoryId,
            rank: i + 1,
            score: response.totalScore,
          },
          createdAt: FieldValue.serverTimestamp(),
          read: false,
          pushSent: false,
        });

        console.log(
          `🏆 [Trivia] Winner notification sent to ${response.oderId} (rank ${i + 1})`
        );
      }
    } catch (error) {
      console.error("❌ [Trivia] Error sending winner notifications:", error);
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// GENERADOR DE SUGERENCIAS DE PREGUNTAS (IA)
// ═══════════════════════════════════════════════════════════════

/**
 * Callable function: Genera una pregunta de trivia usando IA
 *
 * Input: { category?: string }
 * Output: { question, options, correctOptionIndex }
 *
 * Rate limited: 10 sugerencias por hora por usuario
 */
exports.generateTriviaSuggestion = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false, // TODO: Habilitar en producción
  },
  async (request) => {
    // Verificar autenticación
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión");
    }

    const userId = request.auth.uid;
    const { category } = request.data || {};

    // Rate limiting: max 10 sugerencias por hora
    const rateLimitKey = `trivia_suggestion_${userId}`;
    const canGenerate = await checkRateLimit(rateLimitKey, 10, 3600000);

    if (!canGenerate) {
      throw new HttpsError(
        "resource-exhausted",
        "Has alcanzado el límite de sugerencias. Intenta de nuevo en 1 hora."
      );
    }

    console.log(
      `🎯 [Trivia] Generating suggestion for user ${userId}, category: ${category || "random"}`
    );

    try {
      // Por ahora, retornamos preguntas predefinidas
      // TODO: Integrar con Claude API para generación real
      const suggestion = await generateFallbackSuggestion(category);

      return {
        question: suggestion.question,
        options: suggestion.options,
        correctOptionIndex: suggestion.correctOptionIndex,
        category: suggestion.category,
      };
    } catch (error) {
      console.error("❌ [Trivia] Error generating suggestion:", error);
      throw new HttpsError("internal", "Error generando la pregunta");
    }
  }
);

// ═══════════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════════

/**
 * Extraer el path de Storage desde una URL de descarga
 *
 * Las URLs de Firebase Storage tienen el formato:
 * https://firebasestorage.googleapis.com/v0/b/{bucket}/o/{encodedPath}?alt=media&token={token}
 *
 * Esta función extrae {encodedPath} y lo decodifica.
 */
function extractStoragePath(downloadUrl) {
  if (!downloadUrl) return null;

  try {
    // Extraer el path codificado de la URL
    const match = downloadUrl.match(/\/o\/([^?]+)/);
    if (!match || !match[1]) return null;

    // Decodificar el path (los / están codificados como %2F)
    return decodeURIComponent(match[1]);
  } catch (error) {
    console.log(`⚠️ [Trivia] Error extracting storage path: ${error.message}`);
    return null;
  }
}

/**
 * Generar pregunta predefinida (fallback)
 */
async function generateFallbackSuggestion(categoryId) {
  // IMPORTANTE: Todas las preguntas deben ser GENERALES sobre el creador de la trivia.
  // NO deben ser específicas a la relación con quien responde (nada de "nos conocimos", etc.)
  const suggestions = {
    familia: [
      {
        question: "¿Cuántos hermanos tengo?",
        options: ["Ninguno", "1", "2", "3 o más"],
        correctOptionIndex: 1,
        category: "familia",
      },
      {
        question: "¿Tengo mascota?",
        options: ["Sí, un perro", "Sí, un gato", "Sí, otro animal", "No tengo"],
        correctOptionIndex: 0,
        category: "familia",
      },
      {
        question: "¿Soy el mayor, menor o del medio en mi familia?",
        options: ["Mayor", "Menor", "Del medio", "Hijo único"],
        correctOptionIndex: 0,
        category: "familia",
      },
      {
        question: "¿Dónde vivo actualmente?",
        options: ["Con mis padres", "Solo/a", "Con roommates", "Con pareja"],
        correctOptionIndex: 0,
        category: "familia",
      },
    ],
    gustos: [
      {
        question: "¿Cuál es mi comida favorita?",
        options: ["Pizza", "Hamburguesa", "Sushi", "Tacos"],
        correctOptionIndex: 0,
        category: "gustos",
      },
      {
        question: "¿Cuál es mi color favorito?",
        options: ["Azul", "Rojo", "Verde", "Negro"],
        correctOptionIndex: 0,
        category: "gustos",
      },
      {
        question: "¿Qué tipo de música prefiero?",
        options: ["Pop", "Rock", "Reggaeton", "Electrónica"],
        correctOptionIndex: 0,
        category: "gustos",
      },
      {
        question: "¿Prefiero playa o montaña?",
        options: ["Playa", "Montaña"],
        correctOptionIndex: 0,
        category: "gustos",
      },
    ],
    cultura: [
      {
        question: "¿Qué plataforma de streaming uso más?",
        options: ["Netflix", "Disney+", "HBO Max", "Amazon Prime"],
        correctOptionIndex: 0,
        category: "cultura",
      },
      {
        question: "¿Qué tipo de películas prefiero?",
        options: ["Acción", "Comedia", "Terror", "Románticas"],
        correctOptionIndex: 0,
        category: "cultura",
      },
      {
        question: "¿Cuál es mi videojuego favorito?",
        options: ["Shooters", "RPG", "Deportes", "No juego videojuegos"],
        correctOptionIndex: 0,
        category: "cultura",
      },
    ],
    personalidad: [
      {
        question: "¿Qué me da más miedo?",
        options: ["Arañas/insectos", "Alturas", "Oscuridad", "Hablar en público"],
        correctOptionIndex: 0,
        category: "personalidad",
      },
      {
        question: "¿Soy más de día o de noche?",
        options: ["De día", "De noche"],
        correctOptionIndex: 1,
        category: "personalidad",
      },
      {
        question: "¿Soy introvertido o extrovertido?",
        options: ["Introvertido", "Extrovertido", "Ambivertido"],
        correctOptionIndex: 0,
        category: "personalidad",
      },
      {
        question: "¿Qué hago un domingo típico?",
        options: ["Descanso en casa", "Salgo con amigos", "Hago deporte", "Trabajo/estudio"],
        correctOptionIndex: 0,
        category: "personalidad",
      },
    ],
    curiosidades: [
      {
        question: "¿Cuál es mi superpoder deseado?",
        options: ["Volar", "Invisibilidad", "Leer mentes", "Super fuerza"],
        correctOptionIndex: 0,
        category: "curiosidades",
      },
      {
        question: "¿Si ganara la lotería, qué haría primero?",
        options: ["Viajar", "Comprar casa", "Invertir", "Regalar a familia"],
        correctOptionIndex: 0,
        category: "curiosidades",
      },
      {
        question: "¿Prefiero café o té?",
        options: ["Café", "Té", "Ninguno"],
        correctOptionIndex: 0,
        category: "curiosidades",
      },
      {
        question: "¿A qué época me gustaría viajar?",
        options: ["Futuro", "Edad Media", "Los 80s", "Egipto antiguo"],
        correctOptionIndex: 0,
        category: "curiosidades",
      },
    ],
  };

  // Si no hay categoría o es random, elegir una al azar
  const categories = Object.keys(suggestions);
  const actualCategory =
    categoryId && suggestions[categoryId]
      ? categoryId
      : categories[Math.floor(Math.random() * categories.length)];

  const categorySuggestions = suggestions[actualCategory];
  const randomIndex = Math.floor(Math.random() * categorySuggestions.length);

  return categorySuggestions[randomIndex];
}

// ═══════════════════════════════════════════════════════════════
// GENERADOR MASIVO DE SUGERENCIAS (BACKOFFICE)
// ═══════════════════════════════════════════════════════════════

/**
 * Callable function: Genera múltiples preguntas de trivia usando IA (para backoffice)
 *
 * Input: { categoryId: string, count: number }
 * Output: { suggestions: Array<{ question, options, correctOptionIndex, categoryId }> }
 *
 * Solo accesible desde el backoffice (admin)
 */
exports.generateTriviaSuggestions = onCall(
  {
    region: "us-central1",
    enforceAppCheck: false,
  },
  async (request) => {
    // Verificar autenticación
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Debes iniciar sesión");
    }

    const userId = request.auth.uid;
    const { categoryId, count = 5 } = request.data || {};

    // Validar count
    const actualCount = Math.min(Math.max(1, count), 20); // Entre 1 y 20

    console.log(
      `🎯 [Trivia] Generating ${actualCount} suggestions for category: ${categoryId || "random"} (user: ${userId})`
    );

    // Verificar que es un admin (verificar en colección admins o similar)
    const db = getFirestore();
    const userDoc = await db.collection("users").doc(userId).get();

    if (!userDoc.exists) {
      throw new HttpsError("permission-denied", "Usuario no encontrado");
    }

    // Verificar si Gemini está configurado
    if (!genAI) {
      console.warn("⚠️ [Trivia] Gemini API no configurado, usando fallback");
      const fallbackSuggestions = [];
      for (let i = 0; i < actualCount; i++) {
        const suggestion = await generateFallbackSuggestion(categoryId);
        fallbackSuggestions.push({
          ...suggestion,
          categoryId: categoryId || suggestion.category,
          enabled: true,
        });
      }
      return { suggestions: fallbackSuggestions };
    }

    try {
      const suggestions = await generateWithGemini(categoryId, actualCount);
      return { suggestions };
    } catch (error) {
      console.error("❌ [Trivia] Error generating with AI:", error);

      // Fallback a preguntas predefinidas
      const fallbackSuggestions = [];
      for (let i = 0; i < actualCount; i++) {
        const suggestion = await generateFallbackSuggestion(categoryId);
        fallbackSuggestions.push({
          ...suggestion,
          categoryId: categoryId || suggestion.category,
          enabled: true,
        });
      }
      return { suggestions: fallbackSuggestions };
    }
  }
);

/**
 * Genera preguntas de trivia usando Gemini AI
 */
async function generateWithGemini(categoryId, count) {
  const category = TRIVIA_CATEGORIES[categoryId];
  const categoryName = category ? category.name : "General";
  const categoryDescription = category ? category.description : "Preguntas variadas";

  const prompt = `Genera ${count} preguntas de trivia para una app de chat familiar.

CATEGORÍA: ${categoryName} - ${categoryDescription}

REGLAS IMPORTANTES:
1. Las preguntas deben ser sobre el CREADOR de la trivia (quien hace la pregunta sobre sí mismo)
2. NO incluir preguntas sobre relaciones entre personas (nada de "cómo nos conocimos", "desde cuándo somos amigos")
3. Las preguntas deben ser apropiadas para toda la familia (niños incluidos)
4. Cada pregunta debe tener entre 2 y 4 opciones
5. Las opciones deben ser variadas y plausibles
6. El índice de respuesta correcta es 0 (el creador debe ajustar la respuesta correcta)

FORMATO DE RESPUESTA (JSON válido):
{
  "suggestions": [
    {
      "question": "¿Cuál es mi...?",
      "options": ["Opción 1", "Opción 2", "Opción 3", "Opción 4"],
      "correctOptionIndex": 0,
      "categoryId": "${categoryId || 'curiosidades'}"
    }
  ]
}

Genera exactamente ${count} preguntas creativas y variadas. Solo responde con el JSON, sin explicaciones.`;

  const model = genAI.getGenerativeModel({ model: "gemini-2.5-flash-lite" });

  const result = await model.generateContent(prompt);
  const response = await result.response;
  const text = response.text();

  // Parsear la respuesta JSON
  let parsedResponse;
  try {
    // Limpiar posibles markdown code blocks
    const cleanText = text.replace(/```json\n?/g, "").replace(/```\n?/g, "").trim();
    parsedResponse = JSON.parse(cleanText);
  } catch (parseError) {
    console.error("❌ [Trivia] Error parsing Gemini response:", parseError);
    console.log("Raw response:", text);
    throw new Error("Error parsing AI response");
  }

  if (!parsedResponse.suggestions || !Array.isArray(parsedResponse.suggestions)) {
    throw new Error("Invalid AI response format");
  }

  // Validar y normalizar cada sugerencia
  const validSuggestions = parsedResponse.suggestions
    .filter(s => s.question && Array.isArray(s.options) && s.options.length >= 2)
    .map(s => ({
      question: s.question,
      options: s.options.slice(0, 4), // Máximo 4 opciones
      correctOptionIndex: Math.min(s.correctOptionIndex || 0, s.options.length - 1),
      categoryId: categoryId || s.categoryId || "curiosidades",
      enabled: true,
    }));

  console.log(`✅ [Trivia] Generated ${validSuggestions.length} suggestions with Gemini`);

  return validSuggestions;
}
