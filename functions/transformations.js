const { onDocumentCreated, onDocumentDeleted } = require("firebase-functions/v2/firestore");
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const { getStorage } = require("firebase-admin/storage");

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

      console.log(`🤖 [TransformCharacter] Llamando a Replicate API...`);
      console.log(`   input_image (personaje): ${characterData.referenceImageUrl}`);
      console.log(`   swap_image (usuario): ${imageUrl}`);

      // 4. Llamar a codeplugtech Face Swap model (82% más barato)
      // Model: codeplugtech/face-swap
      // Costo: ~$0.0025 por transformación (400 runs por $1) - 82% ahorro vs cdingram
      // Corre en GPU A100, tarda ~10-12 segundos
      //
      // OPTIMIZACIÓN: Usar predictions.create + polling para obtener progreso en tiempo real
      let output;
      let predictionId;
      try {
        console.log(`🚀 [TransformCharacter] Creando predicción...`);

        // Crear predicción (no espera a que termine)
        const prediction = await replicate.predictions.create({
          version: "278a81e7ebb22db98bcba54de985d22cc1abeead2754eb1f2af717247be69b34",
          input: {
            input_image: characterData.referenceImageUrl, // Imagen del personaje (objetivo)
            swap_image: imageUrl, // Imagen del usuario (cara a intercambiar)
          },
        });

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
      await db.collection("characterTransformations").add({
        userId: userId,
        characterId: characterId,
        characterName: characterData.name,
        originalImageUrl: imageUrl,
        transformedImageUrl: transformedImageUrl,
        timestamp: new Date(),
      });

      console.log(`📊 [TransformCharacter] Analytics guardado`);

      return {
        transformedImageUrl: transformedImageUrl,
        characterName: characterData.name,
      };
    } catch (error) {
      console.error("❌ [TransformCharacter] Error:", error);

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
      const Replicate = require("replicate");
      const replicate = new Replicate({
        auth: replicateToken,
      });

      // 4. Crear documento de estado en Firestore PRIMERO
      const statusDocRef = db.collection("transformationStatus").doc();
      const statusDocId = statusDocRef.id;

      await statusDocRef.set({
        userId: userId,
        characterId: characterId,
        characterName: characterData.name,
        status: "initializing",
        progress: 0.05,
        message: "Iniciando transformación...",
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });

      console.log(`📄 [CreateCharacterTransformation] Documento de estado creado: ${statusDocId}`);

      // 5. Crear predicción en Replicate
      console.log(`🚀 [CreateCharacterTransformation] Creando predicción en Replicate...`);

      await statusDocRef.update({
        status: "creating_prediction",
        progress: 0.1,
        message: "Conectando con IA...",
        updatedAt: FieldValue.serverTimestamp(),
      });

      const prediction = await replicate.predictions.create({
        version: "278a81e7ebb22db98bcba54de985d22cc1abeead2754eb1f2af717247be69b34",
        input: {
          input_image: characterData.referenceImageUrl,
          swap_image: imageUrl,
        },
      });

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
      pollPredictionAndUpdateFirestore(replicate, prediction.id, statusDocRef, characterData.name)
          .catch((error) => {
            console.error(`❌ [PollPrediction] Error: ${error.message}`);
          });

      // 8. Guardar registro en characterTransformations
      await db.collection("characterTransformations").add({
        userId: userId,
        characterId: characterId,
        characterName: characterData.name,
        originalImageUrl: imageUrl,
        predictionId: prediction.id,
        statusDocId: statusDocId,
        status: prediction.status,
        createdAt: FieldValue.serverTimestamp(),
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
 */
async function pollPredictionAndUpdateFirestore(replicate, predictionId, statusDocRef, characterName) {
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
          return; // Terminar polling
        case "canceled":
          await statusDocRef.update({
            status: "canceled",
            progress: 0,
            message: "Transformación cancelada",
            canceledAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
          });

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

    console.error(`⏰ [PollPrediction] Timeout después de ${pollCount} polls`);
  } catch (error) {
    console.error(`❌ [PollPrediction] Error durante polling: ${error.message}`);

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

      const Replicate = require("replicate");
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

