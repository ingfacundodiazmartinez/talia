const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");
const Replicate = require("replicate");
const sharp = require("sharp");
const axios = require("axios");
const { v4: uuidv4 } = require("uuid");

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

      // 4. Determinar qué modelo usar:
      // - Si tiene prompt → p-image-edit (transformación por prompt)
      // - Si no tiene prompt → face-swap (intercambio de cara tradicional)
      const usePromptTransformation = characterData.prompt && characterData.prompt.trim().length > 0;

      console.log(`🤖 [TransformCharacter] Llamando a Replicate API...`);
      console.log(`   Modo: ${usePromptTransformation ? "p-image-edit (prompt)" : "face-swap (tradicional)"}`);
      if (!usePromptTransformation) {
        console.log(`   input_image (personaje): ${characterData.referenceImageUrl}`);
        console.log(`   swap_image (usuario): ${imageUrl}`);
      } else {
        console.log(`   Prompt: ${characterData.prompt}`);
        console.log(`   Imagen usuario: ${imageUrl}`);
      }

      let output;
      let predictionId;
      try {
        console.log(`🚀 [TransformCharacter] Creando predicción...`);

        // Crear predicción según el tipo de transformación
        let prediction;

        // Variable para guardar el path del archivo temporal (para limpieza)
        let tempFilePath = null;

        if (usePromptTransformation) {
          // Usar prunaai/p-image-edit para transformaciones con prompt
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
          // Usar codeplugtech/face-swap para intercambio de cara tradicional
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
      } catch (replicateError) {
        console.error(`❌ Error de Replicate API: ${replicateError.message}`);
        console.error(`   Stack: ${replicateError.stack}`);
        if (predictionId) {
          console.error(`   Prediction ID: ${predictionId}`);
        }
        throw replicateError;
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

      // Limpiar archivo temporal si existe
      if (tempFilePath) {
        await cleanupTempFile(tempFilePath);
      }

      return {
        transformedImageUrl: transformedImageUrl,
        characterName: characterData.name,
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

      // 5. Crear predicción en Replicate
      // Determinar qué modelo usar:
      // - Si tiene prompt → p-image-edit (transformación por prompt)
      // - Si no tiene prompt → face-swap (intercambio de cara tradicional)
      const usePromptTransformation = characterData.prompt && characterData.prompt.trim().length > 0;

      console.log(`🚀 [CreateCharacterTransformation] Creando predicción en Replicate...`);
      console.log(`   Modo: ${usePromptTransformation ? "p-image-edit (prompt)" : "face-swap (tradicional)"}`);

      await statusDocRef.update({
        status: "creating_prediction",
        progress: 0.1,
        message: usePromptTransformation ? "Aplicando transformación..." : "Conectando con IA...",
        transformationType: usePromptTransformation ? "prompt" : "faceSwap",
        updatedAt: FieldValue.serverTimestamp(),
      });

      let prediction;
      let tempFilePath = null; // Para limpieza de archivo temporal después del polling

      if (usePromptTransformation) {
        // Usar prunaai/p-image-edit para transformaciones con prompt
        // Model: prunaai/p-image-edit
        // Costo: ~$0.01 por imagen (100 runs por $1)
        // Ejecución: <1 segundo en H100 GPU
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
            images: [normalized.url], // Imagen con orientación corregida
            turbo: true, // Modo rápido
            aspect_ratio: "match_input_image",
            disable_safety_checker: false,
          },
        });
      } else {
        // Usar codeplugtech/face-swap para intercambio de cara tradicional
        // Model: codeplugtech/face-swap
        // Costo: ~$0.0025 por transformación (400 runs por $1)
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
      // Esto ocurre de forma asíncrona - no esperamos a que termine
      pollPredictionAndUpdateFirestore(replicate, prediction.id, statusDocRef, characterData.name, tempFilePath)
          .catch((error) => {
            console.error(`❌ [PollPrediction] Error: ${error.message}`);
          });

      // 8. Guardar registro en character_transformations (snake_case)
      // TTL: 30 días para analytics
      const analyticsDeleteAt = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);
      await db.collection("character_transformations").add({
        userId: userId,
        characterId: characterId,
        characterName: characterData.name,
        originalImageUrl: imageUrl,
        predictionId: prediction.id,
        statusDocId: statusDocId,
        status: prediction.status,
        createdAt: FieldValue.serverTimestamp(),
        deleteAt: Timestamp.fromDate(analyticsDeleteAt), // TTL: 30 días
      });

      // 9. Retornar inmediatamente - el cliente escuchará Firestore
      return {
        statusDocId: statusDocId,
        predictionId: prediction.id,
        status: prediction.status,
        characterName: characterData.name,
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

