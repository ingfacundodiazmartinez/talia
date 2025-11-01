/**
 * ═══════════════════════════════════════════════════════════════
 * STORIES - Cloud Functions para gestión de historias
 * ═══════════════════════════════════════════════════════════════
 */

const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");

const db = getFirestore();

/**
 * Trigger que se ejecuta cuando se crea una solicitud de aprobación de historia
 * Crea automáticamente una notificación para el padre
 */
exports.onStoryApprovalRequestCreated = onDocumentCreated(
  {
    document: "story_approval_requests/{requestId}",
    region: "us-central1",
  },
  async (event) => {
    const requestData = event.data.data();
    const requestId = event.params.requestId;

    console.log("📸 [Story] Nueva solicitud de aprobación:", requestId);
    console.log("   - parentId:", requestData.parentId);
    console.log("   - childId:", requestData.childId);
    console.log("   - storyId:", requestData.storyId);

    try {
      // Obtener información del hijo
      const childDoc = await db.collection("users").doc(requestData.childId).get();

      if (!childDoc.exists) {
        console.error("❌ [Story] Child not found:", requestData.childId);
        return;
      }

      const childName = childDoc.data().name || "Tu hijo";

      // Crear notificación para el padre
      const notificationRef = await db.collection("notifications").add({
        userId: requestData.parentId,
        type: "story_approval_request",
        title: `Nueva historia de ${childName}`,
        body: `${childName} ha creado una nueva historia y necesita tu aprobación`,
        senderId: requestData.childId,
        timestamp: FieldValue.serverTimestamp(),
        read: false,
        priority: "normal",
        data: {
          childId: requestData.childId,
          childName: childName,
          storyId: requestData.storyId,
          requestId: requestId,
        },
      });

      console.log("✅ [Story] Notificación creada:", notificationRef.id);
      console.log("   - Para padre:", requestData.parentId);
      console.log("   - De hijo:", childName);

      return { success: true, notificationId: notificationRef.id };
    } catch (error) {
      console.error("❌ [Story] Error creando notificación:", error);
      throw error;
    }
  }
);
