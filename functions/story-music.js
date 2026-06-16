/**
 * ═══════════════════════════════════════════════════════════════
 * TALIA - Generación de música con IA para historias (Sonauto/Treblo)
 * ═══════════════════════════════════════════════════════════════
 *
 * Función callable:
 *   - generateStoryMusic   Genera una canción a partir de un prompt
 *                          (y opcionalmente letra), descontando créditos.
 *
 * Flujo:
 *   1. Moderar el prompt + letra con Gemini (app de menores: fail-closed).
 *   2. Cobrar créditos (spendCredits) ANTES de llamar a la IA.
 *   3. POST a Sonauto /generations → task_id.
 *   4. Polling de /generations/status/{task_id} hasta SUCCESS/FAILURE.
 *   5. GET /generations/{task_id} → result_data.song_paths[0] (URL del CDN).
 *   6. Descargar el audio y subirlo a Firebase Storage (persistencia + control).
 *   7. Si algo falla después del cobro, refundCredits y devolver error.
 *
 * La API key vive en functions/.env como SONAUTO_API_KEY (gitignored).
 * ═══════════════════════════════════════════════════════════════
 */

const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { getStorage } = require("firebase-admin/storage");
const crypto = require("crypto");

const { getFirestore } = require("firebase-admin/firestore");

const wallet = require("./wallet");
const { analyzeMessageWithGemini } = require("./gemini-analyzer");
const { _isPremiumSystemEnabled } = require("./payments");

/// ¿El usuario tiene acceso premium? (premium directo, o premium familiar vía
/// un padre vinculado premium). Si el sistema premium está apagado, todos sí.
function _isPremiumActive(u) {
  if (!u || u.isPremium !== true) return false;
  const exp = u.premiumExpiresAt;
  if (exp && typeof exp.toDate === "function" && exp.toDate() < new Date()) return false;
  return true;
}

async function userHasPremiumAccess(userId) {
  try {
    if (!(await _isPremiumSystemEnabled())) return true; // premium desactivado → libre
  } catch (_) {}
  const db = getFirestore();
  const userDoc = await db.collection("users").doc(userId).get();
  const u = userDoc.data() || {};
  if (_isPremiumActive(u)) return true;
  // Premium familiar: algún padre vinculado con premium activo.
  const parentIds = Array.isArray(u.linkedParentIds) ? u.linkedParentIds : [];
  for (const pid of parentIds) {
    try {
      const p = await db.collection("users").doc(pid).get();
      if (_isPremiumActive(p.data() || {})) return true;
    } catch (_) {}
  }
  return false;
}

const SONAUTO_API_BASE = "https://api.sonauto.ai/v1";

// Tiempo máximo que esperamos la generación antes de abortar (y refundear).
// El timeout del CF es 300s; dejamos margen para la subida a Storage.
const GENERATION_TIMEOUT_MS = 4 * 60 * 1000; // 4 min
const POLL_INTERVAL_MS = 5000; // 5s entre polls (igual al ejemplo oficial)

const MAX_PROMPT_LEN = 500;
const MAX_LYRICS_LEN = 2000;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * Crea la generación en Sonauto y devuelve el task_id.
 */
async function createGeneration(apiKey, body) {
  // v3 = Melodia v3 (modelo nuevo, mejor calidad y adherencia al prompt). La
  // versión se selecciona por la URL del endpoint, no por un campo del body.
  const resp = await fetch(`${SONAUTO_API_BASE}/generations/v3`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (!resp.ok) {
    const errText = await resp.text().catch(() => "");
    throw new Error(`Sonauto create ${resp.status}: ${errText.slice(0, 300)}`);
  }
  const data = await resp.json();
  const taskId = data.task_id || data.taskId || data.id;
  if (!taskId) {
    throw new Error(`Sonauto no devolvió task_id: ${JSON.stringify(data).slice(0, 300)}`);
  }
  return String(taskId);
}

/**
 * Pollea el status hasta un estado terminal. Devuelve cuando es SUCCESS.
 * Lanza si FAILURE o timeout.
 */
async function waitForCompletion(apiKey, taskId) {
  const deadline = Date.now() + GENERATION_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await sleep(POLL_INTERVAL_MS);
    let resp;
    try {
      resp = await fetch(`${SONAUTO_API_BASE}/generations/status/${taskId}`, {
        headers: { "Authorization": `Bearer ${apiKey}` },
      });
    } catch (_) {
      continue; // error de red transitorio: reintentar en el próximo ciclo
    }
    if (!resp.ok) continue;

    // El status puede venir como string crudo ("SUCCESS") o como objeto {status}.
    const raw = await resp.text();
    let status = raw.trim().replace(/^"|"$/g, "");
    try {
      const parsed = JSON.parse(raw);
      status = (parsed.status || parsed.state || status).toString();
    } catch (_) {
      // raw ya es el status como string
    }
    status = status.toUpperCase();

    if (status === "SUCCESS" || status === "COMPLETED") return;
    if (status === "FAILURE" || status === "FAILED" || status === "ERROR" || status === "CANCELLED") {
      throw new Error(`Sonauto generation status=${status}`);
    }
    // PENDING / PROCESSING / RUNNING / etc → seguir polleando
  }
  throw new Error("Sonauto generation timeout");
}

/**
 * Obtiene la URL del audio (CDN de Sonauto), las lyrics generadas y el título
 * (si Sonauto lo devuelve) del resultado.
 * @return {Promise<{url: string, lyrics: string|null, title: string|null}>}
 */
async function fetchSongResult(apiKey, taskId) {
  const resp = await fetch(`${SONAUTO_API_BASE}/generations/${taskId}`, {
    headers: { "Authorization": `Bearer ${apiKey}` },
  });
  if (!resp.ok) {
    throw new Error(`Sonauto result ${resp.status}`);
  }
  const data = await resp.json();
  const rd = data.result_data || data;
  const paths = rd.song_paths || data.song_paths || [];
  if (!Array.isArray(paths) || paths.length === 0 || !paths[0]) {
    throw new Error("Sonauto no devolvió song_paths");
  }
  // Sonauto genera las lyrics cuando no es instrumental; el campo puede venir
  // como string o como array de líneas.
  let lyrics = rd.lyrics || data.lyrics || null;
  if (Array.isArray(lyrics)) lyrics = lyrics.join("\n");
  if (typeof lyrics !== "string" || !lyrics.trim()) lyrics = null;
  // Título: Sonauto lo expone en distintos campos según versión. Lo usamos como
  // default editable; si no viene, el cliente deriva uno del prompt.
  let title = rd.title || data.title || rd.song_title || rd.name || null;
  if (typeof title !== "string" || !title.trim()) title = null;
  if (title) title = title.trim().slice(0, 80);
  return { url: paths[0], lyrics, title };
}

/**
 * Descarga el audio del CDN y lo guarda en Storage; devuelve una download URL
 * estable de Firebase (no dependemos de la expiración del CDN de Sonauto).
 */
async function persistToStorage(songUrl, userId, taskId) {
  const resp = await fetch(songUrl);
  if (!resp.ok) {
    throw new Error(`Audio download ${resp.status}`);
  }
  const arrayBuffer = await resp.arrayBuffer();
  const buffer = Buffer.from(arrayBuffer);

  const bucket = getStorage().bucket();
  const filePath = `story_music/${userId}/${taskId}.mp3`;
  const file = bucket.file(filePath);
  const downloadToken = crypto.randomUUID();

  await file.save(buffer, {
    resumable: false,
    contentType: "audio/mpeg",
    metadata: {
      contentType: "audio/mpeg",
      metadata: { firebaseStorageDownloadTokens: downloadToken },
    },
  });

  return `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/${encodeURIComponent(filePath)}?alt=media&token=${downloadToken}`;
}

exports.generateStoryMusic = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 300,
    memory: "512MiB",
    consumeAppCheckToken: true,
  },
  async (request) => {
    const userId = request.auth?.uid;
    if (!userId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    const data = request.data || {};
    const cleanPrompt = (data.prompt || "").toString().trim();
    const cleanLyrics = data.lyrics ? data.lyrics.toString().trim().slice(0, MAX_LYRICS_LEN) : null;
    const isInstrumental = data.instrumental === true;

    if (cleanPrompt.length < 3) {
      throw new HttpsError("invalid-argument", "Describí la canción que querés crear");
    }
    if (cleanPrompt.length > MAX_PROMPT_LEN) {
      throw new HttpsError("invalid-argument", "La descripción es demasiado larga");
    }

    // 🔒 Gate premium: la creación de canciones es exclusiva de Premium/Premium+.
    if (!(await userHasPremiumAccess(userId))) {
      throw new HttpsError("failed-precondition", "PREMIUM_REQUIRED");
    }

    const apiKey = process.env.SONAUTO_API_KEY;
    if (!apiKey) {
      console.error("❌ [generateStoryMusic] SONAUTO_API_KEY no configurado");
      throw new HttpsError("failed-precondition", "Servicio de música no configurado");
    }

    // ── 1. Moderación (fail-closed: app de menores) ──────────────────────
    // Modera tanto la descripción como la letra que escribió el usuario.
    const textToModerate = [cleanPrompt, cleanLyrics].filter(Boolean).join("\n");
    try {
      const moderation = await analyzeMessageWithGemini(
        textToModerate,
        "text",
        "",
        "high",
        [],
        []
      );
      if (moderation && moderation.isInappropriate) {
        console.log(`🚫 [generateStoryMusic] Prompt rechazado: ${moderation.reason}`);
        throw new HttpsError(
          "failed-precondition",
          "El contenido de tu canción no es apropiado. Probá con otra idea."
        );
      }
    } catch (err) {
      if (err instanceof HttpsError) throw err;
      // Si Gemini falla, fail-closed: no generamos.
      console.error("❌ [generateStoryMusic] Moderación falló:", err.message);
      throw new HttpsError("internal", "No pudimos validar el contenido. Intentá de nuevo.");
    }

    const db = require("firebase-admin/firestore").getFirestore();
    void db; // (reservado para futuros logs analíticos)

    let spendTxId = null;
    try {
      // ── 2. Cobrar créditos ANTES de llamar a la IA ─────────────────────
      const spendResult = await wallet._internal.spendCredits(userId, "song_generation", {
        prompt: cleanPrompt.slice(0, 100),
        instrumental: isInstrumental,
        hasLyrics: !!cleanLyrics,
      });
      spendTxId = spendResult.txId;
      console.log(`💳 [generateStoryMusic] Spend OK: ${spendResult.amount} cr, txId=${spendTxId}, newBalance=${spendResult.newBalance}`);

      // ── 3. Crear generación en Sonauto (Melodia v3) ────────────────────
      // v3 siempre genera 1 canción (no usa num_songs). Pedimos mp3 porque el
      // default de v3 es opus/ogg, que no siempre reproduce en iOS.
      //
      // prompt_strength alto (2.5) + style_scale en 1.0 → la canción sigue más
      // de cerca el prompt. Regla v3: exactamente uno de los dos debe ser > 1.0.
      const genBody = {
        prompt: cleanPrompt,
        output_format: "mp3",
        prompt_strength: 2.5,
        style_scale: 1.0,
        // Canciones cortas: Sonauto exige múltiplos de 30s y min < max. El rango
        // más corto válido es [30, 60] → generación más rápida que el default.
        length_range: [30, 60],
      };
      if (cleanLyrics) genBody.lyrics = cleanLyrics;
      if (isInstrumental) {
        genBody.instrumental = true;
      } else {
        // Pide timing palabra-por-palabra para sincronizar la letra con el recorte.
        genBody.align_lyrics = true;
      }

      const taskId = await createGeneration(apiKey, genBody);
      console.log(`🎵 [generateStoryMusic] task_id=${taskId}`);

      // ── 4 + 5. Esperar y obtener la URL del audio ──────────────────────
      await waitForCompletion(apiKey, taskId);
      const songResult = await fetchSongResult(apiKey, taskId);

      // ── 6. Persistir en Storage ────────────────────────────────────────
      const audioUrl = await persistToStorage(songResult.url, userId, taskId);
      console.log(`✅ [generateStoryMusic] Audio guardado: ${audioUrl.slice(0, 80)}...`);

      // Lyrics: prioridad a las que escribió el usuario; sino las generadas.
      const lyrics = isInstrumental ? null : (cleanLyrics || songResult.lyrics || null);

      return {
        success: true,
        audioUrl,
        prompt: cleanPrompt,
        instrumental: isInstrumental,
        lyrics,
        title: songResult.title, // título sugerido por Sonauto (editable en el cliente)
        taskId, // para pedir el alignment (timing) por separado en el crop
        creditsSpent: spendResult.amount,
        newBalance: spendResult.newBalance,
      };
    } catch (err) {
      // Refund si ya cobramos.
      if (spendTxId) {
        try {
          await wallet._internal.refundCredits(spendTxId, "song_generation_failed");
          console.log(`↩️ [generateStoryMusic] Refund OK para txId=${spendTxId}`);
        } catch (refundErr) {
          console.error("❌ [generateStoryMusic] Refund falló:", refundErr.message);
        }
      }
      // Sin créditos: mensaje amigable (spendCredits lanza failed-precondition
      // con message "INSUFFICIENT_CREDITS"). Va ANTES del re-throw genérico de
      // HttpsError para no exponer el código técnico al usuario.
      if (err && err.message && err.message.includes("INSUFFICIENT_CREDITS")) {
        throw new HttpsError(
          "failed-precondition",
          "No te alcanzan los créditos para crear una canción. Conseguí más y volvé a intentar.",
        );
      }
      if (err instanceof HttpsError) throw err;
      console.error("❌ [generateStoryMusic]", err);
      throw new HttpsError("internal", "No se pudo generar la canción. Te devolvimos los créditos.");
    }
  }
);

/**
 * Devuelve el timing palabra-por-palabra (alignment) de una generación.
 * El alignment es un post-proceso asíncrono de Sonauto; el cliente llama esta
 * función con reintentos hasta que `alignmentStatus === "SUCCESS"`.
 *
 * @return {{alignmentStatus: string, words: Array<{start:number,end:number,word:string}>|null}}
 */
exports.getMusicAlignment = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 30,
    memory: "256MiB",
    consumeAppCheckToken: true,
  },
  async (request) => {
    const userId = request.auth?.uid;
    if (!userId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }
    const taskId = (request.data?.taskId || "").toString().trim();
    if (!taskId) {
      throw new HttpsError("invalid-argument", "taskId requerido");
    }
    const apiKey = process.env.SONAUTO_API_KEY;
    if (!apiKey) {
      throw new HttpsError("failed-precondition", "Servicio de música no configurado");
    }
    try {
      const resp = await fetch(`${SONAUTO_API_BASE}/generations/${taskId}`, {
        headers: { "Authorization": `Bearer ${apiKey}` },
      });
      if (!resp.ok) {
        throw new Error(`Sonauto result ${resp.status}`);
      }
      const data = await resp.json();
      const alignmentStatus = (data.alignment_status || "UNKNOWN").toString();
      let words = data.word_aligned_lyrics;
      if (!Array.isArray(words)) words = null;
      return { alignmentStatus, words };
    } catch (err) {
      console.error("❌ [getMusicAlignment]", err.message);
      throw new HttpsError("internal", "No se pudo obtener el timing de la letra");
    }
  }
);
