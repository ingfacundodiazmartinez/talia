/**
 * Group chat summaries with Gemini.
 *
 * Use case: cuando un user vuelve a un grupo donde tiene muchos mensajes
 * sin leer (≥20), el cliente le ofrece un resumen IA. Esta CF genera ese
 * resumen on-demand, server-side, validando membresía y visibilidad.
 *
 * Diseño:
 *  - Efímero: NO se guarda en Firestore. Cada llamada regenera.
 *  - Free: no consume créditos. Costo Gemini ~$0.0005/llamada.
 *  - Validación: caller debe ser miembro del grupo. Filtra mensajes que no
 *    son visibles para el caller (visibleTo) o bloqueados por moderación.
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { getFirestore, FieldPath } = require("firebase-admin/firestore");
const { GoogleGenerativeAI } = require("@google/generative-ai");

const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const genAI = GEMINI_API_KEY ? new GoogleGenerativeAI(GEMINI_API_KEY) : null;

const MAX_MESSAGES_TO_SUMMARIZE = 200;

exports.summarizeGroupUnread = onCall(
  { cors: true, consumeAppCheckToken: true },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }
    if (!genAI) {
      throw new HttpsError("failed-precondition", "Gemini no configurado");
    }

    const uid = request.auth.uid;
    const { groupId, messageIds } = request.data || {};

    if (!groupId || typeof groupId !== "string") {
      throw new HttpsError("invalid-argument", "groupId requerido");
    }
    if (!Array.isArray(messageIds) || messageIds.length === 0) {
      throw new HttpsError("invalid-argument", "messageIds requerido (array)");
    }
    if (messageIds.length > MAX_MESSAGES_TO_SUMMARIZE) {
      throw new HttpsError(
        "invalid-argument",
        `Máximo ${MAX_MESSAGES_TO_SUMMARIZE} mensajes por resumen`
      );
    }

    const db = getFirestore();

    // 🔒 Validar membresía.
    const groupDoc = await db.collection("groups_v2").doc(groupId).get();
    if (!groupDoc.exists) {
      throw new HttpsError("not-found", "Grupo no encontrado");
    }
    const groupData = groupDoc.data();
    const members = groupData.members || [];
    if (!members.includes(uid)) {
      throw new HttpsError("permission-denied", "No sos miembro del grupo");
    }
    const groupName = groupData.name || "Grupo";

    // Traer los mensajes (lotes de 10 por límite de Firestore whereIn).
    const messagesCol = db.collection("groups_v2").doc(groupId).collection("messages");
    const msgs = [];
    for (let i = 0; i < messageIds.length; i += 10) {
      const batch = messageIds.slice(i, i + 10);
      const snap = await messagesCol
        .where(FieldPath.documentId(), "in", batch)
        .get();
      for (const doc of snap.docs) {
        msgs.push({ id: doc.id, ...doc.data() });
      }
    }

    // Filtrar mensajes que el caller NO puede ver o que están bloqueados.
    const visible = msgs.filter((m) => {
      if (m.isDeleted || m.isDeletedForEveryone) return false;
      if (m.moderationStatus === "blocked") return false;
      // visibleTo null/undefined = visible para todos (legacy).
      if (Array.isArray(m.visibleTo) && !m.visibleTo.includes(uid)) return false;
      return true;
    });

    if (visible.length === 0) {
      return {
        success: true,
        summary: "No hay mensajes nuevos para resumir.",
        messagesIncluded: 0,
      };
    }

    // Ordenar por timestamp asc.
    visible.sort((a, b) => {
      const at = a.timestamp?.toMillis ? a.timestamp.toMillis() : 0;
      const bt = b.timestamp?.toMillis ? b.timestamp.toMillis() : 0;
      return at - bt;
    });

    // Armar el contexto para Gemini.
    const lines = visible.map((m) => {
      const sender = m.senderName || "Usuario";
      let body = m.text || "";
      if (!body) {
        if (m.imageUrl) body = "[imagen]";
        else if (m.videoUrl) body = "[video]";
        else if (m.audioUrl) body = m.transcription ? `[audio: "${m.transcription}"]` : "[audio]";
        else body = "[mensaje]";
      }
      return `${sender}: ${body}`;
    });

    const prompt = `Resumí brevemente la conversación del grupo "${groupName}" para alguien que se perdió estos ${visible.length} mensajes. Reglas:
- Máximo 3-4 frases cortas, en español rioplatense neutro.
- Mencioná los temas principales y quién dijo qué cuando es relevante.
- NO repitas mensajes literales; abstraé.
- NO inventes nada que no esté en los mensajes.
- Si la conversación es triviale (saludos, stickers, etc.), decilo así: "Mayormente saludos y charla casual".
- NO uses bullet points ni listas. Texto corrido.

Mensajes (en orden):
${lines.join("\n")}`;

    try {
      const model = genAI.getGenerativeModel({ model: "gemini-2.5-flash-lite" });
      const result = await model.generateContent(prompt);
      const summary = (await result.response).text().trim();

      return {
        success: true,
        summary,
        messagesIncluded: visible.length,
      };
    } catch (err) {
      console.error("[summarizeGroupUnread] Gemini error:", err);
      throw new HttpsError("internal", "Error generando resumen");
    }
  }
);
