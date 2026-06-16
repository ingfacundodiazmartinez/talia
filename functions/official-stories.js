// ═══════════════════════════════════════════════════════════════
// HISTORIAS OFICIALES DE TALIA — Bienvenida
// ═══════════════════════════════════════════════════════════════
//
// Al crear una cuenta (doc en `users/{userId}`), si hay una historia de
// bienvenida configurada y habilitada en `app_config/welcome_story`, se crea
// una historia oficial personal para ese usuario, visible por 24 hs.
//
// Trigger dedicado e independiente de `onUserRegistered` (que está gateado por
// teléfono): la bienvenida debe dispararse para todo usuario nuevo.
//
// Los comunicados (broadcast para todos) NO se crean acá: los publica el
// backoffice vía Admin SDK directamente sobre la colección `stories`.

const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");

const {
  OFFICIAL_USER_ID,
  OFFICIAL_USER_NAME,
  WELCOME_CONFIG_PATH,
} = require("./official");

const TWENTY_FOUR_HOURS_MS = 24 * 60 * 60 * 1000;

exports.onUserCreatedWelcomeStory = onDocumentCreated(
  {
    document: "users/{userId}",
    region: "us-central1",
  },
  async (event) => {
    try {
      const db = getFirestore();
      const userId = event.params.userId;

      // 1. Leer config de bienvenida (editable desde el admin).
      const configSnap = await db
        .collection(WELCOME_CONFIG_PATH.collection)
        .doc(WELCOME_CONFIG_PATH.doc)
        .get();

      if (!configSnap.exists) {
        console.log("[WelcomeStory] No hay config de bienvenida; saltando.");
        return;
      }

      const config = configSnap.data() || {};
      if (config.enabled !== true) {
        console.log("[WelcomeStory] Config deshabilitada; saltando.");
        return;
      }

      const mediaUrl = config.mediaUrl;
      if (!mediaUrl) {
        console.log("[WelcomeStory] Config sin mediaUrl; saltando.");
        return;
      }

      const mediaType = config.mediaType === "video" ? "video" : "image";
      const caption =
        typeof config.caption === "string" && config.caption.trim().length > 0
          ? config.caption.trim()
          : null;

      // 2. Crear la historia de bienvenida (personal, vía availableFor=[userId]).
      const now = Date.now();
      const storyData = {
        userId: OFFICIAL_USER_ID,
        userName: OFFICIAL_USER_NAME,
        userPhotoURL: null,
        mediaType,
        mediaUrl,
        caption,
        filter: null,
        localMediaPath: null,
        status: "approved",
        createdAt: FieldValue.serverTimestamp(),
        expiresAt: Timestamp.fromMillis(now + TWENTY_FOUR_HOURS_MS),
        viewedBy: [],
        visibility: "temporary",
        replies: [],
        availableFor: [userId], // Solo este usuario la ve
        parentViewers: [],
        childViewers: [],
        likedBy: [],
        aiGenerated: false,
        isOfficial: true,
        isBroadcast: false,
        updatedAt: FieldValue.serverTimestamp(),
      };

      await db.collection("stories").add(storyData);
      console.log(`[WelcomeStory] Historia de bienvenida creada para ${userId}`);
    } catch (e) {
      // No re-lanzar: la creación de la cuenta no debe fallar por esto.
      console.error("[WelcomeStory] Error creando historia de bienvenida:", e);
    }
  }
);
