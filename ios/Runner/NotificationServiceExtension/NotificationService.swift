import UserNotifications
import Intents  // Para INPerson y Communication Notifications
import UIKit    // Para UIImage
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore

/// NSE que descarga foto del sender y crea Communication Notification con foto circular.
/// ADEMÁS: marca delivery receipt (`lastReceivedAt_{uid}`) en el chat doc cuando llega
/// una push de chat_message — funciona incluso con la app principal totalmente cerrada.
@objc(NotificationService)
class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?
    /// Audit #1: grupo para esperar la write del delivery receipt antes de
    /// entregar el contenido. Si NSE es killed antes (time will expire), la
    /// notificación se entrega igual via `serviceExtensionTimeWillExpire`.
    private var receiptGroup: DispatchGroup?

    /// Entrega el contenido al sistema esperando hasta `timeout` por la
    /// confirmación de Firestore. Si ya pasó el budget de la NSE, igual entrega.
    private func deliverContent(_ content: UNNotificationContent) {
        guard let handler = self.contentHandler else { return }
        self.contentHandler = nil
        if let group = self.receiptGroup {
            // Esperar fuera del thread principal para no bloquearlo.
            DispatchQueue.global(qos: .userInitiated).async {
                _ = group.wait(timeout: .now() + 2.5)
                handler(content)
            }
        } else {
            handler(content)
        }
    }

    /// Configurar Firebase una sola vez por proceso de NSE.
    /// Como NSE puede ser reusada (mismo proceso para múltiples pushes), guardamos
    /// un flag estático. Si ya está configurada, no la reconfigure.
    private static var firebaseConfigured = false

    private static func ensureFirebaseConfigured() {
        guard !firebaseConfigured else { return }
        // Opciones hardcoded del proyecto (talia-chat-app-v2). Valores públicos
        // — son los mismos del GoogleService-Info.plist que ya vive en Runner.
        let options = FirebaseOptions(
            googleAppID: "1:858375352661:ios:cfdb7fe8506f903361bfdc",
            gcmSenderID: "858375352661"
        )
        options.apiKey = "AIzaSyDQNZf12r6tPZ6ErEVBW7Wu2x7KBYYn6_w"
        options.projectID = "talia-chat-app-v2"
        options.storageBucket = "talia-chat-app-v2.firebasestorage.app"
        options.databaseURL = "https://talia-chat-app-v2-default-rtdb.firebaseio.com"
        options.bundleID = "com.talia.chat"
        FirebaseApp.configure(options: options)

        // Configurar Auth para leer del shared keychain (mismo grupo que la app
        // principal — ver Runner.entitlements + NSE.entitlements).
        do {
            try Auth.auth().useUserAccessGroup("J642AAS7WP.com.talia.chat.shared")
            NSLog("✅ [NSE] Firebase configurado + shared keychain")
        } catch {
            NSLog("⚠️ [NSE] Error shared keychain: %@", "\(error)")
        }
        firebaseConfigured = true
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let bestAttemptContent = bestAttemptContent else {
            // Sin contenido mutable — entregamos el request original sin esperar
            // receipt (no hay chatId que marcar de todos modos).
            contentHandler(request.content)
            self.contentHandler = nil
            return
        }

        // Extraer datos del payload
        let senderPhotoUrl = bestAttemptContent.userInfo["senderPhotoUrl"] as? String
        let senderId = bestAttemptContent.userInfo["senderId"] as? String ?? "unknown"
        let senderName = bestAttemptContent.userInfo["senderName"] as? String ?? "Usuario"
        let chatId = bestAttemptContent.userInfo["chatId"] as? String ?? senderId
        let pushType = bestAttemptContent.userInfo["type"] as? String
        // ✅ Audit #10: usar `isGroup` del payload (no heurística chatId != senderId).
        // El CF lo envía como string "true"/"false" (FCM data values son strings).
        let isGroupValue = bestAttemptContent.userInfo["isGroup"]
        let isGroupChat: Bool = {
            if let b = isGroupValue as? Bool { return b }
            if let s = isGroupValue as? String { return s == "true" }
            return false
        }()

        // ✅ DELIVERY RECEIPT (server-confirmed). Audit #1: bloqueamos hasta ~2.5s
        // en `deliverContent` esperando la confirmación de Firestore. Si el NSE
        // es killed antes, se pierde — pero ese caso es raro (Apple da
        // ~24-30s de budget). Solo aplica a chat_message 1-1.
        let group = DispatchGroup()
        self.receiptGroup = group
        if pushType == "chat_message" && !isGroupChat && !chatId.isEmpty && chatId != "unknown" {
            Self.ensureFirebaseConfigured()
            if let uid = Auth.auth().currentUser?.uid {
                group.enter()
                Firestore.firestore()
                    .collection("chats")
                    .document(chatId)
                    .updateData([
                        "lastReceivedAt_\(uid)": FieldValue.serverTimestamp()
                    ]) { error in
                        if let error = error {
                            NSLog("⚠️ [NSE] Error marcando lastReceivedAt: %@", "\(error)")
                        } else {
                            NSLog("📬 [NSE] lastReceivedAt_%@ actualizado para %@", uid, chatId)
                        }
                        group.leave()
                    }
            } else {
                NSLog("⚠️ [NSE] currentUser nil — receipt no posible")
            }
        }

        // ✅ FIX: Usar getCachedPhotoIfUrlMatches para detectar fotos actualizadas
        // Si la URL cambió, retorna nil y fuerza re-descarga
        if let cachedImage = TaliaPhotoCache.getCachedPhotoIfUrlMatches(userId: senderId, currentUrl: senderPhotoUrl) {
            createCommunicationNotification(
                content: bestAttemptContent,
                senderName: senderName,
                senderId: senderId,
                chatId: chatId,
                image: cachedImage
            )
        } else if let photoUrl = senderPhotoUrl, !photoUrl.isEmpty, photoUrl != "null" {
            // Descargar si no está en cache O si la URL cambió
            downloadImage(from: photoUrl) { [weak self] imageData in
                guard let self = self else { return }

                if let imageData = imageData, let image = UIImage(data: imageData) {
                    // ✅ FIX: Guardar en cache CON la URL para futura comparación
                    TaliaPhotoCache.savePhoto(userId: senderId, image: image, photoUrl: photoUrl)

                    self.createCommunicationNotification(
                        content: bestAttemptContent,
                        senderName: senderName,
                        senderId: senderId,
                        chatId: chatId,
                        image: image
                    )
                } else {
                    self.deliverContent(bestAttemptContent)
                }
            }
        } else {
            self.deliverContent(bestAttemptContent)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    // MARK: - Crear Communication Notification con INPerson

    private func createCommunicationNotification(
        content: UNMutableNotificationContent,
        senderName: String,
        senderId: String,
        chatId: String,
        image: UIImage
    ) {
        // Crear INPerson con foto
        let personHandle = INPersonHandle(value: senderId, type: .unknown)
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            self.deliverContent(content)
            return
        }
        let avatar = INImage(imageData: imageData)
        let sender = INPerson(
            personHandle: personHandle,
            nameComponents: nil,
            displayName: senderName,
            image: avatar,
            contactIdentifier: nil,
            customIdentifier: senderId
        )

        // Crear INSendMessageIntent
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: nil,
            conversationIdentifier: chatId,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )

        // Asignar imagen
        intent.setImage(avatar, forParameterNamed: \INSendMessageIntent.sender)

        // Donar interacción
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = INInteractionDirection.incoming
        interaction.donate { _ in }

        // Convertir a Communication Notification
        do {
            let updatedContent = try content.updating(from: intent)

            if let mutableContent = updatedContent.mutableCopy() as? UNMutableNotificationContent {
                bestAttemptContent = mutableContent
                if let finalContent = bestAttemptContent {
                    self.deliverContent(finalContent)
                } else {
                    self.deliverContent(content)
                }
            } else {
                self.deliverContent(content)
            }
        } catch {
            self.deliverContent(content)
        }
    }

    // MARK: - Descargar imagen

    private func downloadImage(from urlString: String, completion: @escaping (Data?) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5

        let session = URLSession(configuration: config)
        session.dataTask(with: url) { data, _, error in
            if error != nil || data == nil || data!.isEmpty {
                completion(nil)
                return
            }
            completion(data)
        }.resume()
    }
}
