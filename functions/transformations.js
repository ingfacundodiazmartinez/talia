const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const { getRemoteConfig } = require("firebase-admin/remote-config");
const Replicate = require("replicate");
const OpenAI = require("openai");
const sharp = require("sharp");
const axios = require("axios");
const { v4: uuidv4 } = require("uuid");

// ═══════════════════════════════════════════════════════════════
// REMOTE CONFIG: FEATURE FLAGS
// ═══════════════════════════════════════════════════════════════

/**
 * Verificar si el sistema premium está habilitado via Remote Config
 * Si está deshabilitado, todos los usuarios tienen acceso Premium+
 * @returns {Promise<boolean>} true si premium está habilitado, false si está deshabilitado
 */
async function isPremiumSystemEnabled() {
  try {
    const remoteConfig = getRemoteConfig();

    // Usar getTemplate() para leer el Client Remote Config template
    const template = await remoteConfig.getTemplate();

    // Buscar el parámetro premium_enabled
    if (template.parameters && template.parameters.premium_enabled) {
      const param = template.parameters.premium_enabled;
      // El defaultValue puede ser un objeto con 'value' o directamente un string
      let premiumEnabledValue = "true";
      if (param.defaultValue) {
        premiumEnabledValue = param.defaultValue.value || "true";
      }

      // Convertir a boolean (Remote Config guarda como string)
      const isEnabled = premiumEnabledValue.toLowerCase() !== "false";

      console.log(`🎛️ [RemoteConfig] premium_enabled = ${isEnabled} (raw: "${premiumEnabledValue}")`);
      return isEnabled;
    }

    console.log("🎛️ [RemoteConfig] premium_enabled no encontrado, usando default: true");
    return true;
  } catch (error) {
    console.error("❌ [RemoteConfig] Error obteniendo premium_enabled:", error.message);
    // En caso de error, asumir que está habilitado (comportamiento por defecto)
    return true;
  }
}

// ═══════════════════════════════════════════════════════════════
// LÍMITES DE FACE-SWAP POR TIER (sincronizado con Flutter)
// ═══════════════════════════════════════════════════════════════

// Free: límite DIARIO (3/día)
// Premium/Premium+: límite MENSUAL (50/mes y 100/mes)
const FACE_SWAP_LIMITS = {
  free: { limit: 3, period: "daily" },
  premium: { limit: 50, period: "monthly" },
  premium_plus: { limit: 100, period: "monthly" },
};

/**
 * Obtener el día actual en formato YYYY-MM-DD
 */
function getCurrentDay() {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, "0");
  const day = String(now.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

/**
 * Obtener el mes actual en formato YYYY-MM
 */
function getCurrentMonth() {
  const now = new Date();
  const year = now.getFullYear();
  const month = String(now.getMonth() + 1).padStart(2, "0");
  return `${year}-${month}`;
}

/**
 * Verificar si el usuario puede usar face-swap según su plan
 * @param {string} userId - ID del usuario
 * @returns {Promise<{canUse: boolean, remaining: number, limit: number, tier: string, period: string}>}
 */
async function checkFaceSwapLimit(userId) {
  const db = getFirestore();

  try {
    // 0. Verificar si el sistema premium está habilitado
    // Si está deshabilitado, todos los usuarios tienen acceso Premium+ sin límites
    const premiumEnabled = await isPremiumSystemEnabled();
    if (!premiumEnabled) {
      console.log(`🎁 [FaceSwapLimit] Premium disabled - Usuario ${userId} tiene acceso Premium+ ilimitado`);
      return {
        canUse: true,
        remaining: 999999, // Prácticamente ilimitado
        limit: 999999,
        tier: "premium_plus",
        period: "unlimited",
        premiumDisabled: true,
      };
    }

    // 1. Obtener tier del usuario
    const userDoc = await db.collection("users").doc(userId).get();
    let tier = "free";

    if (userDoc.exists) {
      const userData = userDoc.data();
      const isPremium = userData.isPremium === true;
      const premiumExpiresAt = userData.premiumExpiresAt;

      // Verificar si el premium ha expirado
      if (isPremium && premiumExpiresAt) {
        const expiryDate = premiumExpiresAt.toDate ? premiumExpiresAt.toDate() : new Date(premiumExpiresAt);
        if (expiryDate > new Date()) {
          tier = userData.subscriptionTier || "premium";
        }
      } else if (isPremium && !premiumExpiresAt) {
        tier = userData.subscriptionTier || "premium";
      }
    }

    // 2. Obtener configuración de límites para este tier
    const limitConfig = FACE_SWAP_LIMITS[tier] || FACE_SWAP_LIMITS.free;
    const { limit, period } = limitConfig;

    // 3. Obtener uso actual
    const limitsDoc = await db.collection("user_limits").doc(userId).get();

    if (!limitsDoc.exists) {
      // Primera vez, puede usar
      return { canUse: true, remaining: limit, limit, tier, period };
    }

    const limitsData = limitsDoc.data();
    let count = 0;
    let isNewPeriod = false;

    if (period === "daily") {
      const currentDay = getCurrentDay();
      const savedDay = limitsData.faceSwapDay;
      count = limitsData.faceSwapDailyCount || 0;
      isNewPeriod = savedDay !== currentDay;
    } else {
      const currentMonth = getCurrentMonth();
      const savedMonth = limitsData.faceSwapMonth;
      count = limitsData.faceSwapMonthlyCount || 0;
      isNewPeriod = savedMonth !== currentMonth;
    }

    // Si es un nuevo período, resetear contador
    if (isNewPeriod) {
      count = 0;
    }

    const remaining = Math.max(0, limit - count);
    const canUse = count < limit;

    console.log(`🔒 [FaceSwapLimit] Usuario: ${userId}, Tier: ${tier}, Usado: ${count}/${limit}, Puede usar: ${canUse}`);

    return { canUse, remaining, limit, tier, period, count };
  } catch (error) {
    console.error(`❌ [FaceSwapLimit] Error verificando límites: ${error.message}`);
    // En caso de error, denegar por seguridad
    return { canUse: false, remaining: 0, limit: 0, tier: "error", period: "unknown" };
  }
}

/**
 * Incrementar el contador de face-swap del usuario
 * @param {string} userId - ID del usuario
 * @param {string} tier - Tier del usuario (para saber si es diario o mensual)
 */
async function incrementFaceSwapCount(userId, tier) {
  const db = getFirestore();
  const limitConfig = FACE_SWAP_LIMITS[tier] || FACE_SWAP_LIMITS.free;
  const { period } = limitConfig;

  try {
    const docRef = db.collection("user_limits").doc(userId);

    if (period === "daily") {
      const currentDay = getCurrentDay();
      await docRef.set({
        faceSwapDay: currentDay,
        faceSwapDailyCount: FieldValue.increment(1),
        lastFaceSwapDaily: FieldValue.serverTimestamp(),
      }, { merge: true });
    } else {
      const currentMonth = getCurrentMonth();
      await docRef.set({
        faceSwapMonth: currentMonth,
        faceSwapMonthlyCount: FieldValue.increment(1),
        lastFaceSwapMonthly: FieldValue.serverTimestamp(),
      }, { merge: true });
    }

    console.log(`📈 [FaceSwapLimit] Contador incrementado para ${userId} (${period})`);
  } catch (error) {
    console.error(`❌ [FaceSwapLimit] Error incrementando contador: ${error.message}`);
  }
}

// ═══════════════════════════════════════════════════════════════
// HELPER: Selección de modelo de IA
// ═══════════════════════════════════════════════════════════════

/**
 * Determinar qué modelo de IA usar para la transformación
 * @param {object} characterData - Datos del personaje de Firestore
 * @returns {string} Identificador del modelo: 'face_swap', 'p_image_edit', o 'nano_banana'
 */
function determineAiModel(characterData) {
  const aiModel = characterData.aiModel || "auto";

  switch (aiModel) {
    case "face_swap":
      return "face_swap";
    case "p_image_edit":
      return "p_image_edit";
    case "nano_banana":
      return "nano_banana";
    case "auto":
    default:
      // Comportamiento legacy: usar prompt para determinar
      const hasPrompt = characterData.prompt && characterData.prompt.trim().length > 0;
      return hasPrompt ? "p_image_edit" : "face_swap";
  }
}

/**
 * Editar imagen usando Nano Banana de Google (via Replicate)
 * Edita una imagen existente basándose en el prompt (image-to-image)
 * Precio: ~$0.039/imagen
 * @param {string} prompt - Prompt para la edición
 * @param {string} inputImageUrl - URL de la imagen a editar
 * @returns {Promise<string>} URL de la imagen editada
 */
async function transformWithNanoBanana(prompt, inputImageUrl) {
  const replicateToken = process.env.REPLICATE_API_TOKEN;
  if (!replicateToken) {
    throw new Error("REPLICATE_API_TOKEN no configurado");
  }

  const replicate = new Replicate({ auth: replicateToken });

  console.log(`🍌 [Nano-Banana] Editando imagen con prompt: ${prompt.substring(0, 100)}...`);
  console.log(`   Input image: ${inputImageUrl.substring(0, 80)}...`);

  const output = await replicate.run("google/nano-banana", {
    input: {
      prompt: prompt,
      image_input: [inputImageUrl],
      aspect_ratio: "match_input_image",
      output_format: "png",
    },
  });

  console.log(`✅ [Nano-Banana] Imagen editada exitosamente`);

  // Replicate devuelve URL directamente (o array de URLs)
  const resultUrl = Array.isArray(output) ? output[0] : output;

  if (!resultUrl) {
    console.error(`❌ [Nano-Banana] Response inesperado:`, JSON.stringify(output).substring(0, 200));
    throw new Error("Nano Banana no devolvió una URL válida");
  }

  console.log(`✅ [Nano-Banana] Resultado: ${resultUrl}`);
  return resultUrl;
}

// ═══════════════════════════════════════════════════════════════
// HELPER: Normalizar orientación de imagen (fix EXIF rotation)
// ═══════════════════════════════════════════════════════════════

/**
 * Descarga una imagen, corrige su orientación EXIF, y la sube a Storage temporal.
 * Necesario porque iPhones guardan la orientación en EXIF metadata y algunos
 * modelos de IA (como p-image-edit) no la respetan.
 *
 * @param {string} imageUrl - URL de la imagen original
 * @param {string} userId - ID del usuario (para organizar en Storage)
 * @returns {Promise<{url: string, filePath: string|null}>} - URL y path del archivo temporal
 */
async function normalizeImageOrientation(imageUrl, userId) {
  console.log(`🔄 [NormalizeImage] Procesando imagen para corregir orientación EXIF`);
  console.log(`   URL original: ${imageUrl}`);

  try {
    // 1. Descargar la imagen
    const response = await axios.get(imageUrl, {
      responseType: "arraybuffer",
      timeout: 30000,
    });

    const imageBuffer = Buffer.from(response.data);
    console.log(`   Imagen descargada: ${imageBuffer.length} bytes`);

    // 2. Leer metadata para diagnosticar
    const metadata = await sharp(imageBuffer).metadata();
    console.log(`   Metadata: ${metadata.width}x${metadata.height}, orientation: ${metadata.orientation || 'none'}, format: ${metadata.format}`);

    // 3. Procesar con sharp: rotate() auto-rota según EXIF y elimina el tag
    // Usamos keepExif: false para asegurar que no quede metadata conflictiva
    const processedBuffer = await sharp(imageBuffer)
        .rotate() // Auto-rotate based on EXIF orientation (if present)
        .withMetadata({ orientation: undefined }) // Remove orientation tag
        .jpeg({ quality: 90 }) // Re-encode as JPEG to ensure clean output
        .toBuffer();

    // 4. Verificar resultado
    const outputMetadata = await sharp(processedBuffer).metadata();
    console.log(`   Output: ${outputMetadata.width}x${outputMetadata.height}, orientation: ${outputMetadata.orientation || 'none'}`);
    console.log(`   Imagen procesada: ${processedBuffer.length} bytes`);

    // 3. Subir a Firebase Storage (carpeta temporal con TTL)
    const bucket = getStorage().bucket();
    const fileName = `temp_transformations/${userId}/${uuidv4()}.jpg`;
    const file = bucket.file(fileName);

    await file.save(processedBuffer, {
      metadata: {
        contentType: "image/jpeg",
        // Metadata para limpieza automática (24 horas)
        customMetadata: {
          createdAt: new Date().toISOString(),
          expiresAt: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
        },
      },
      public: true, // Hacer público temporalmente para que p-image-edit pueda acceder
    });

    // Generar URL pública directa (más confiable que signed URLs)
    const publicUrl = `https://storage.googleapis.com/${bucket.name}/${fileName}`;

    console.log(`   Imagen normalizada subida: ${fileName}`);
    console.log(`   URL pública: ${publicUrl}`);

    return { url: publicUrl, filePath: fileName };
  } catch (error) {
    console.error(`❌ [NormalizeImage] Error: ${error.message}`);
    // Si falla, retornar la URL original (mejor que fallar completamente)
    console.log(`   Usando URL original como fallback`);
    return { url: imageUrl, filePath: null };
  }
}

/**
 * Elimina un archivo temporal de Firebase Storage
 * @param {string|null} filePath - Path del archivo a eliminar
 */
async function cleanupTempFile(filePath) {
  if (!filePath) return;

  try {
    const bucket = getStorage().bucket();
    await bucket.file(filePath).delete();
    console.log(`🧹 [Cleanup] Archivo temporal eliminado: ${filePath}`);
  } catch (error) {
    // No es crítico si falla - el archivo expirará eventualmente
    console.warn(`⚠️ [Cleanup] No se pudo eliminar ${filePath}: ${error.message}`);
  }
}

// ═══════════════════════════════════════════════════════════════
// TRANSFORMATIONS
// ═══════════════════════════════════════════════════════════════

exports.transformCharacter = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 300, // 5 minutos para transformaciones con IA
    memory: "1GiB", // Más memoria para procesamiento de imágenes
    consumeAppCheckToken: true,
  },
  async (request) => {
    const {imageUrl, characterId} = request.data;
    const userId = request.auth?.uid;

    console.log(`🎭 [TransformCharacter] Iniciando transformación`);
    console.log(`   Usuario: ${userId}`);
    console.log(`   Imagen: ${imageUrl}`);
    console.log(`   Personaje: ${characterId}`);

    if (!userId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    if (!imageUrl || !characterId) {
      throw new HttpsError("invalid-argument", "imageUrl y characterId son requeridos");
    }

    // ✅ VERIFICAR LÍMITES SEGÚN PLAN
    const limitCheck = await checkFaceSwapLimit(userId);
    if (!limitCheck.canUse) {
      const periodText = limitCheck.period === "daily" ? "hoy" : "este mes";
      throw new HttpsError(
        "resource-exhausted",
        `Has alcanzado el límite de ${limitCheck.limit} transformaciones ${periodText}. ` +
        `Actualiza a Premium para obtener más transformaciones.`
      );
    }

    const db = getFirestore();

    try {
      // 1. Obtener datos del personaje
      const characterDoc = await db.collection("characters").doc(characterId).get();

      if (!characterDoc.exists) {
        throw new HttpsError("not-found", "Personaje no encontrado");
      }

      const characterData = characterDoc.data();

      if (!characterData.enabled) {
        throw new HttpsError("failed-precondition", "Personaje deshabilitado");
      }

      console.log(`✅ [TransformCharacter] Personaje encontrado: ${characterData.name}`);

      // 2. Verificar que existe el API token de Replicate
      const replicateToken = process.env.REPLICATE_API_TOKEN;

      if (!replicateToken) {
        console.error("❌ [TransformCharacter] REPLICATE_API_TOKEN no configurado");
        throw new HttpsError("failed-precondition", "Servicio de transformación no configurado");
      }

      // 3. Inicializar Replicate client
      const replicate = new Replicate({
        auth: replicateToken,
      });

      // 4. Determinar qué modelo usar según configuración del personaje
      const selectedModel = determineAiModel(characterData);

      console.log(`🤖 [TransformCharacter] Modelo seleccionado: ${selectedModel}`);
      if (selectedModel === "face_swap") {
        console.log(`   input_image (personaje): ${characterData.referenceImageUrl}`);
        console.log(`   swap_image (usuario): ${imageUrl}`);
      } else {
        console.log(`   Prompt: ${characterData.prompt}`);
        console.log(`   Imagen usuario: ${imageUrl}`);
      }

      let output;
      let predictionId;
      try {
        // Variable para guardar el path del archivo temporal (para limpieza)
        let tempFilePath = null;

        // ═══════════════════════════════════════════════════════════════
        // Nano Banana: Edición directa con OpenAI (sin polling)
        // ═══════════════════════════════════════════════════════════════
        if (selectedModel === "nano_banana") {
          if (!characterData.prompt || !characterData.prompt.trim()) {
            throw new HttpsError("invalid-argument", "Nano Banana requiere un prompt configurado en el personaje");
          }

          console.log(`🎨 [TransformCharacter] Usando Nano Banana 1.5...`);
          const nanoBananaUrl = await transformWithNanoBanana(characterData.prompt, imageUrl);

          // Nano Banana retorna directamente, no hay polling
          output = nanoBananaUrl;
          predictionId = `nano_banana_${Date.now()}`;
          console.log(`✅ [TransformCharacter] Nano Banana completado`);

        } else {
          // ═══════════════════════════════════════════════════════════════
          // REPLICATE: p-image-edit o face-swap (con polling)
          // ═══════════════════════════════════════════════════════════════
          console.log(`🚀 [TransformCharacter] Creando predicción en Replicate...`);

          let prediction;

          if (selectedModel === "p_image_edit") {
            // Usar prunaai/p-image-edit para transformaciones con prompt
            if (!characterData.prompt || !characterData.prompt.trim()) {
              throw new HttpsError("invalid-argument", "p-image-edit requiere un prompt configurado en el personaje");
            }

            // Normalizar orientación EXIF (fix para fotos de iPhone rotadas)
            const normalized = await normalizeImageOrientation(imageUrl, userId);
            tempFilePath = normalized.filePath;
            console.log(`   Imagen normalizada: ${normalized.url.substring(0, 100)}...`);

            prediction = await replicate.predictions.create({
              model: "prunaai/p-image-edit",
              input: {
                prompt: characterData.prompt,
                images: [normalized.url], // Imagen con orientación corregida
                turbo: true,
                aspect_ratio: "match_input_image",
                disable_safety_checker: false,
              },
            });
          } else {
            // face_swap: Usar codeplugtech/face-swap para intercambio de cara tradicional
            prediction = await replicate.predictions.create({
              version: "278a81e7ebb22db98bcba54de985d22cc1abeead2754eb1f2af717247be69b34",
              input: {
                input_image: characterData.referenceImageUrl,
                swap_image: imageUrl,
              },
            });
          }

          predictionId = prediction.id;
          console.log(`✅ [TransformCharacter] Predicción creada: ${predictionId}`);
          console.log(`   Estado inicial: ${prediction.status}`);

          // Hacer polling del estado hasta que complete
          let currentPrediction = prediction;
          let pollCount = 0;
          const maxPolls = 60; // 60 polls x 2 segundos = 2 minutos máximo

          while (
            currentPrediction.status !== "succeeded" &&
            currentPrediction.status !== "failed" &&
            currentPrediction.status !== "canceled" &&
            pollCount < maxPolls
          ) {
            // Esperar 2 segundos antes de hacer polling
            await new Promise((resolve) => setTimeout(resolve, 2000));

            // Obtener estado actualizado
            currentPrediction = await replicate.predictions.get(predictionId);
            pollCount++;

            // Log de progreso
            const progressInfo = [];
            progressInfo.push(`Poll #${pollCount}`);
            progressInfo.push(`Estado: ${currentPrediction.status}`);

            if (currentPrediction.logs) {
              const logs = currentPrediction.logs.split("\n").filter((line) => line.trim());
              const lastLog = logs[logs.length - 1];
              if (lastLog) {
                progressInfo.push(`Log: ${lastLog.substring(0, 100)}`);
              }
            }

            console.log(`⏳ [TransformCharacter] ${progressInfo.join(" | ")}`);
          }

          if (currentPrediction.status === "succeeded") {
            output = currentPrediction.output;
            console.log(`✅ [TransformCharacter] Predicción completada exitosamente`);
          } else if (currentPrediction.status === "failed") {
            console.error(`❌ [TransformCharacter] Predicción falló`);
            console.error(`   Error: ${currentPrediction.error}`);
            throw new Error(`Transformación falló: ${currentPrediction.error || "Error desconocido"}`);
          } else if (currentPrediction.status === "canceled") {
            throw new Error("Transformación cancelada");
          } else {
            throw new Error(`Timeout esperando transformación (${pollCount} intentos)`);
          }
        } // End of Replicate else block
      } catch (transformError) {
        console.error(`❌ Error en transformación: ${transformError.message}`);
        console.error(`   Stack: ${transformError.stack}`);
        if (predictionId) {
          console.error(`   Prediction ID: ${predictionId}`);
        }
        throw transformError;
      }

      console.log(`✅ [TransformCharacter] Transformación completada`);
      console.log(`   Output type: ${typeof output}`);
      console.log(`   Output constructor: ${output?.constructor?.name}`);
      console.log(`   Output is null: ${output === null}`);
      console.log(`   Output is undefined: ${output === undefined}`);
      console.log(`   Output toString: ${output}`);
      console.log(`   Output keys: ${Object.keys(output || {})}`);

      if (output && typeof output.url === "function") {
        console.log(`   Output tiene método url()`);
      }

      // Intentar obtener la URL de diferentes formas
      let transformedImageUrl;

      // Esperar a que el output se complete si es un FileOutput
      if (output && typeof output.url === "function") {
        transformedImageUrl = await output.url();
        console.log(`   URL desde output.url(): ${transformedImageUrl}`);
      } else if (Array.isArray(output)) {
        transformedImageUrl = output[0];
        console.log(`   URL desde array[0]: ${transformedImageUrl}`);
      } else if (typeof output === "string") {
        transformedImageUrl = output;
        console.log(`   URL directa string: ${transformedImageUrl}`);
      } else {
        transformedImageUrl = output;
        console.log(`   URL directa: ${transformedImageUrl}`);
      }

      console.log(`   URL final transformada: ${transformedImageUrl}`);

      if (!transformedImageUrl) {
        throw new HttpsError("internal", "No se generó imagen de salida");
      }

      // 5. Registrar analytics (opcional)
      // ✅ RENAMED: characterTransformations → character_transformations (snake_case)
      // TTL: 30 días para analytics
      const analyticsDeleteAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);
      await db.collection("character_transformations").add({
        userId: userId,
        characterId: characterId,
        characterName: characterData.name,
        originalImageUrl: imageUrl,
        transformedImageUrl: transformedImageUrl,
        timestamp: new Date(),
        deleteAt: Timestamp.fromDate(analyticsDeleteAt), // TTL: 30 días
      });

      console.log(`📊 [TransformCharacter] Analytics guardado`);

      // ✅ INCREMENTAR CONTADOR DE USO
      await incrementFaceSwapCount(userId, limitCheck.tier);

      // Limpiar archivo temporal si existe
      if (tempFilePath) {
        await cleanupTempFile(tempFilePath);
      }

      return {
        transformedImageUrl: transformedImageUrl,
        characterName: characterData.name,
        remaining: limitCheck.remaining - 1,
      };
    } catch (error) {
      console.error("❌ [TransformCharacter] Error:", error);

      // Limpiar archivo temporal incluso si hay error
      if (typeof tempFilePath !== "undefined" && tempFilePath) {
        await cleanupTempFile(tempFilePath).catch(() => {});
      }

      // Si es un HttpsError, lanzarlo directamente
      if (error.code) {
        throw error;
      }

      // Error de Replicate API
      if (error.message && error.message.includes("Replicate")) {
        throw new HttpsError("unavailable", `Error en servicio de IA: ${error.message}`);
      }

      // Error genérico
      throw new HttpsError("internal", `Error transformando imagen: ${error.message}`);
    }
  },
);

/**
 * Crear una predicción de transformación y hacer polling en background
 * El cliente escucha cambios en Firestore para obtener progreso en tiempo real
 */
exports.createCharacterTransformation = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 300, // 5 minutos - necesitamos tiempo para el polling
    memory: "512MiB",
    consumeAppCheckToken: true,
  },
  async (request) => {
    const {imageUrl, characterId} = request.data;
    const userId = request.auth?.uid;

    console.log(`🎭 [CreateCharacterTransformation] Iniciando creación de predicción`);
    console.log(`   Usuario: ${userId}`);
    console.log(`   Personaje: ${characterId}`);

    if (!userId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    if (!imageUrl || !characterId) {
      throw new HttpsError("invalid-argument", "imageUrl y characterId son requeridos");
    }

    // ✅ VERIFICAR LÍMITES SEGÚN PLAN
    const limitCheck = await checkFaceSwapLimit(userId);
    if (!limitCheck.canUse) {
      const periodText = limitCheck.period === "daily" ? "hoy" : "este mes";
      throw new HttpsError(
        "resource-exhausted",
        `Has alcanzado el límite de ${limitCheck.limit} transformaciones ${periodText}. ` +
        `Actualiza a Premium para obtener más transformaciones.`
      );
    }

    const db = getFirestore();

    try {
      // 1. Obtener datos del personaje
      const characterDoc = await db.collection("characters").doc(characterId).get();

      if (!characterDoc.exists) {
        throw new HttpsError("not-found", "Personaje no encontrado");
      }

      const characterData = characterDoc.data();

      if (!characterData.enabled) {
        throw new HttpsError("failed-precondition", "Personaje deshabilitado");
      }

      // 2. Verificar API token de Replicate
      const replicateToken = process.env.REPLICATE_API_TOKEN;

      if (!replicateToken) {
        throw new HttpsError("failed-precondition", "Servicio de transformación no configurado");
      }

      // 3. Inicializar Replicate client
      const replicate = new Replicate({
        auth: replicateToken,
      });

      // 4. Crear documento de estado en Firestore PRIMERO
      // ✅ RENAMED: transformationStatus → transformation_status (snake_case)
      const statusDocRef = db.collection("transformation_status").doc();
      const statusDocId = statusDocRef.id;

      // TTL: 24 horas después de crear (se actualizará cuando complete)
      const deleteAt = new Date(Date.now() + 24 * 60 * 60 * 1000);

      await statusDocRef.set({
        userId: userId,
        characterId: characterId,
        characterName: characterData.name,
        status: "initializing",
        progress: 0.05,
        message: "Iniciando transformación...",
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
        deleteAt: Timestamp.fromDate(deleteAt), // TTL: 24 horas
      });

      console.log(`📄 [CreateCharacterTransformation] Documento de estado creado: ${statusDocId}`);

      // 5. Determinar qué modelo usar según configuración del personaje
      const selectedModel = determineAiModel(characterData);

      console.log(`🚀 [CreateCharacterTransformation] Modelo seleccionado: ${selectedModel}`);

      const transformationTypeMap = {
        "face_swap": "faceSwap",
        "p_image_edit": "prompt",
        "nano_banana": "nanoBanana",
      };

      await statusDocRef.update({
        status: "creating_prediction",
        progress: 0.1,
        message: selectedModel === "nano_banana" ? "Editando con Nano Banana..." : "Conectando con IA...",
        transformationType: transformationTypeMap[selectedModel] || "faceSwap",
        aiModel: selectedModel,
        updatedAt: FieldValue.serverTimestamp(),
      });

      let prediction = null;
      let tempFilePath = null;
      let nanoBananaResultUrl = null;

      // ═══════════════════════════════════════════════════════════════
      // Nano Banana: Edición directa con OpenAI (sin polling)
      // ═══════════════════════════════════════════════════════════════
      if (selectedModel === "nano_banana") {
        if (!characterData.prompt || !characterData.prompt.trim()) {
          throw new HttpsError("invalid-argument", "Nano Banana requiere un prompt configurado en el personaje");
        }

        console.log(`🎨 [CreateCharacterTransformation] Usando Nano Banana 1.5`);
        console.log(`   Prompt: ${characterData.prompt}`);

        await statusDocRef.update({
          status: "generating",
          progress: 0.3,
          message: `Editando imagen con ${characterData.name}...`,
          updatedAt: FieldValue.serverTimestamp(),
        });

        try {
          // Normalizar orientación EXIF (fix para fotos de iPhone rotadas)
          await statusDocRef.update({
            status: "processing_image",
            progress: 0.15,
            message: "Preparando imagen...",
            updatedAt: FieldValue.serverTimestamp(),
          });

          const normalized = await normalizeImageOrientation(imageUrl, userId);
          tempFilePath = normalized.filePath;
          console.log(`   Imagen normalizada: ${normalized.url.substring(0, 100)}...`);

          nanoBananaResultUrl = await transformWithNanoBanana(characterData.prompt, normalized.url);

          // Nano Banana completó exitosamente - actualizar estado final
          await statusDocRef.update({
            status: "succeeded",
            progress: 1.0,
            message: "¡Transformación completada!",
            outputUrl: nanoBananaResultUrl,
            completedAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
          });

          console.log(`✅ [CreateCharacterTransformation] Nano Banana completado`);

          // Limpiar archivo temporal
          if (tempFilePath) {
            await cleanupTempFile(tempFilePath);
          }
        } catch (nanoBananaError) {
          console.error(`❌ [CreateCharacterTransformation] Error Nano Banana: ${nanoBananaError.message}`);
          await statusDocRef.update({
            status: "failed",
            progress: 0,
            message: `Error: ${nanoBananaError.message}`,
            error: nanoBananaError.message,
            updatedAt: FieldValue.serverTimestamp(),
          });
          // Limpiar archivo temporal en caso de error
          if (tempFilePath) {
            await cleanupTempFile(tempFilePath).catch(() => {});
          }
          throw nanoBananaError;
        }
      } else {
        // ═══════════════════════════════════════════════════════════════
        // REPLICATE: p-image-edit o face-swap (con polling async)
        // ═══════════════════════════════════════════════════════════════
        if (selectedModel === "p_image_edit") {
          if (!characterData.prompt || !characterData.prompt.trim()) {
            throw new HttpsError("invalid-argument", "p-image-edit requiere un prompt configurado en el personaje");
          }

          console.log(`🎨 [CreateCharacterTransformation] Usando p-image-edit`);
          console.log(`   Prompt: ${characterData.prompt}`);
          console.log(`   Imagen usuario: ${imageUrl}`);

          // Normalizar orientación EXIF (fix para fotos de iPhone rotadas)
          await statusDocRef.update({
            status: "processing_image",
            progress: 0.15,
            message: "Preparando imagen...",
            updatedAt: FieldValue.serverTimestamp(),
          });

          const normalized = await normalizeImageOrientation(imageUrl, userId);
          tempFilePath = normalized.filePath;
          console.log(`   Imagen normalizada: ${normalized.url.substring(0, 100)}...`);

          prediction = await replicate.predictions.create({
            model: "prunaai/p-image-edit",
            input: {
              prompt: characterData.prompt,
              images: [normalized.url],
              turbo: true,
              aspect_ratio: "match_input_image",
              disable_safety_checker: false,
            },
          });
        } else {
          // face_swap: Usar codeplugtech/face-swap
          console.log(`🔄 [CreateCharacterTransformation] Usando face-swap`);
          prediction = await replicate.predictions.create({
            version: "278a81e7ebb22db98bcba54de985d22cc1abeead2754eb1f2af717247be69b34",
            input: {
              input_image: characterData.referenceImageUrl,
              swap_image: imageUrl,
            },
          });
        }

        console.log(`✅ [CreateCharacterTransformation] Predicción creada: ${prediction.id}`);
        console.log(`   Estado: ${prediction.status}`);

        // 6. Actualizar con predictionId
        await statusDocRef.update({
          predictionId: prediction.id,
          status: prediction.status,
          progress: 0.2,
          message: `Procesando con ${characterData.name}...`,
          updatedAt: FieldValue.serverTimestamp(),
        });

        // 7. Hacer polling en background y actualizar Firestore
        pollPredictionAndUpdateFirestore(replicate, prediction.id, statusDocRef, characterData.name, tempFilePath)
            .catch((error) => {
              console.error(`❌ [PollPrediction] Error: ${error.message}`);
            });
      }

      // 8. Guardar registro en character_transformations (snake_case)
      // TTL: 30 días para analytics
      const analyticsDeleteAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);
      await db.collection("character_transformations").add({
        userId: userId,
        characterId: characterId,
        characterName: characterData.name,
        originalImageUrl: imageUrl,
        predictionId: prediction?.id || `nano_banana_${Date.now()}`,
        statusDocId: statusDocId,
        status: selectedModel === "nano_banana" ? "succeeded" : prediction.status,
        aiModel: selectedModel,
        createdAt: FieldValue.serverTimestamp(),
        deleteAt: Timestamp.fromDate(analyticsDeleteAt), // TTL: 30 días
      });

      // 9. Incrementar contador de uso (hacerlo aquí para evitar race conditions)
      await incrementFaceSwapCount(userId, limitCheck.tier);

      // 10. Retornar inmediatamente - el cliente escuchará Firestore
      return {
        statusDocId: statusDocId,
        predictionId: prediction?.id || `nano_banana_${statusDocId}`,
        status: prediction?.status || "succeeded",
        characterName: characterData.name,
        remaining: limitCheck.remaining - 1,
      };
    } catch (error) {
      console.error("❌ [CreateCharacterTransformation] Error:", error);

      if (error.code) {
        throw error;
      }

      throw new HttpsError("internal", `Error creando transformación: ${error.message}`);
    }
  },
);

/**
 * Función auxiliar para hacer polling de predicción y actualizar Firestore
 * @param {string|null} tempFilePath - Path del archivo temporal a limpiar cuando termine
 */
async function pollPredictionAndUpdateFirestore(replicate, predictionId, statusDocRef, characterName, tempFilePath = null) {
  let pollCount = 0;
  const maxPolls = 60; // 60 polls x 2 segundos = 2 minutos máximo

  try {
    while (pollCount < maxPolls) {
      await new Promise((resolve) => setTimeout(resolve, 2000)); // Esperar 2 segundos
      pollCount++;

      // Obtener estado actualizado de Replicate
      const currentPrediction = await replicate.predictions.get(predictionId);

      console.log(`⏳ [PollPrediction] Poll #${pollCount}: ${currentPrediction.status}`);

      // Calcular progreso
      let progress = 0.2;
      let message = "Procesando...";

      switch (currentPrediction.status) {
        case "starting":
          progress = 0.3;
          message = "Iniciando modelo de IA...";
          break;
        case "processing":
          // Progreso incremental entre 0.3 y 0.9
          progress = 0.3 + (pollCount / maxPolls) * 0.6;
          message = "Transformando imagen...";
          break;
        case "succeeded":
          progress = 1.0;
          message = "¡Transformación completada!";

          // Obtener URL de salida
          let outputUrl;
          if (currentPrediction.output && typeof currentPrediction.output.url === "function") {
            outputUrl = await currentPrediction.output.url();
          } else if (Array.isArray(currentPrediction.output)) {
            outputUrl = currentPrediction.output[0];
          } else if (typeof currentPrediction.output === "string") {
            outputUrl = currentPrediction.output;
          } else {
            outputUrl = currentPrediction.output;
          }

          // Actualizar con resultado
          await statusDocRef.update({
            status: "succeeded",
            progress: 1.0,
            message: message,
            outputUrl: outputUrl,
            completedAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
          });

          console.log(`✅ [PollPrediction] Completado: ${outputUrl}`);
          // Limpiar archivo temporal
          await cleanupTempFile(tempFilePath);
          return; // Terminar polling
        case "failed":
          await statusDocRef.update({
            status: "failed",
            progress: 0,
            message: "Transformación falló",
            error: currentPrediction.error || "Error desconocido",
            failedAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
          });

          console.error(`❌ [PollPrediction] Falló: ${currentPrediction.error}`);
          // Limpiar archivo temporal
          await cleanupTempFile(tempFilePath);
          return; // Terminar polling
        case "canceled":
          await statusDocRef.update({
            status: "canceled",
            progress: 0,
            message: "Transformación cancelada",
            canceledAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
          });
          // Limpiar archivo temporal
          await cleanupTempFile(tempFilePath);

          console.log(`⚠️ [PollPrediction] Cancelado`);
          return; // Terminar polling
      }

      // Actualizar progreso en Firestore
      await statusDocRef.update({
        status: currentPrediction.status,
        progress: progress,
        message: message,
        pollCount: pollCount,
        updatedAt: FieldValue.serverTimestamp(),
      });
    }

    // Si llegamos aquí, hubo timeout
    await statusDocRef.update({
      status: "timeout",
      progress: 0,
      message: "Tiempo de espera agotado",
      error: `Timeout después de ${maxPolls * 2} segundos`,
      failedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });

    // Limpiar archivo temporal
    await cleanupTempFile(tempFilePath);

    console.error(`⏰ [PollPrediction] Timeout después de ${pollCount} polls`);
  } catch (error) {
    console.error(`❌ [PollPrediction] Error durante polling: ${error.message}`);

    // Limpiar archivo temporal
    await cleanupTempFile(tempFilePath);

    // Intentar actualizar Firestore con el error
    try {
      await statusDocRef.update({
        status: "error",
        progress: 0,
        message: "Error durante procesamiento",
        error: error.message,
        failedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    } catch (updateError) {
      console.error(`❌ [PollPrediction] No se pudo actualizar error en Firestore: ${updateError.message}`);
    }
  }
}

/**
 * Obtener el estado de una predicción de Replicate
 */
exports.getTransformationStatus = onCall(
  {
    region: "us-central1",
    timeoutSeconds: 30,
    memory: "256MiB",
    consumeAppCheckToken: true,
  },
  async (request) => {
    const {predictionId} = request.data;
    const userId = request.auth?.uid;

    if (!userId) {
      throw new HttpsError("unauthenticated", "Usuario no autenticado");
    }

    if (!predictionId) {
      throw new HttpsError("invalid-argument", "predictionId es requerido");
    }

    try {
      const replicateToken = process.env.REPLICATE_API_TOKEN;

      if (!replicateToken) {
        throw new HttpsError("failed-precondition", "Servicio de transformación no configurado");
      }

      const replicate = new Replicate({
        auth: replicateToken,
      });

      // Obtener estado de la predicción
      const prediction = await replicate.predictions.get(predictionId);

      console.log(`📊 [GetTransformationStatus] ${predictionId}: ${prediction.status}`);

      // Preparar respuesta
      const response = {
        predictionId: prediction.id,
        status: prediction.status,
        createdAt: prediction.created_at,
      };

      // Si completó exitosamente, agregar URL
      if (prediction.status === "succeeded") {
        // El output puede ser un array o un FileOutput
        let outputUrl;
        if (prediction.output && typeof prediction.output.url === "function") {
          outputUrl = await prediction.output.url();
        } else if (Array.isArray(prediction.output)) {
          outputUrl = prediction.output[0];
        } else if (typeof prediction.output === "string") {
          outputUrl = prediction.output;
        } else {
          outputUrl = prediction.output;
        }

        response.outputUrl = outputUrl;
        console.log(`✅ [GetTransformationStatus] Completado: ${outputUrl}`);
      }

      // Si falló, agregar error
      if (prediction.status === "failed") {
        response.error = prediction.error || "Error desconocido";
        console.error(`❌ [GetTransformationStatus] Falló: ${response.error}`);
      }

      // Agregar logs si existen (últimas 3 líneas)
      if (prediction.logs) {
        const logs = prediction.logs.split("\n").filter((line) => line.trim());
        response.lastLogs = logs.slice(-3);
      }

      return response;
    } catch (error) {
      console.error("❌ [GetTransformationStatus] Error:", error);

      if (error.code) {
        throw error;
      }

      throw new HttpsError("internal", `Error obteniendo estado: ${error.message}`);
    }
  },
);

// ═══════════════════════════════════════════════════════════════
// MIGRACIÓN Y SINCRONIZACIÓN DE linkedChildrenIds
// ═══════════════════════════════════════════════════════════════

/**
 * Función de migración para poblar linkedChildrenIds en usuarios existentes
 * EJECUTAR UNA SOLA VEZ después del deploy
 */

