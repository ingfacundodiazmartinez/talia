import UserNotifications
import Intents  // Para INPerson y Communication Notifications
import UIKit    // Para UIImage

/// NSE que descarga foto del sender y crea Communication Notification con foto circular
@objc(NotificationService)
class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let bestAttemptContent = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        // Extraer datos del payload
        let senderPhotoUrl = bestAttemptContent.userInfo["senderPhotoUrl"] as? String
        let senderId = bestAttemptContent.userInfo["senderId"] as? String ?? "unknown"
        let senderName = bestAttemptContent.userInfo["senderName"] as? String ?? "Usuario"
        let chatId = bestAttemptContent.userInfo["chatId"] as? String ?? senderId

        // Intentar obtener foto del cache primero
        if let cachedImage = TaliaPhotoCache.getCachedPhoto(userId: senderId) {
            createCommunicationNotification(
                content: bestAttemptContent,
                senderName: senderName,
                senderId: senderId,
                chatId: chatId,
                image: cachedImage
            )
        } else if let photoUrl = senderPhotoUrl, !photoUrl.isEmpty, photoUrl != "null" {
            // Descargar si no está en cache
            downloadImage(from: photoUrl) { [weak self] imageData in
                guard let self = self else { return }

                if let imageData = imageData, let image = UIImage(data: imageData) {
                    // Guardar en cache para próxima vez
                    TaliaPhotoCache.savePhoto(userId: senderId, image: image)

                    self.createCommunicationNotification(
                        content: bestAttemptContent,
                        senderName: senderName,
                        senderId: senderId,
                        chatId: chatId,
                        image: image
                    )
                } else {
                    if let handler = self.contentHandler {
                        handler(bestAttemptContent)
                        self.contentHandler = nil
                    }
                }
            }
        } else {
            contentHandler(bestAttemptContent)
            self.contentHandler = nil
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
            if let handler = self.contentHandler {
                handler(content)
                self.contentHandler = nil
            }
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

                if let handler = self.contentHandler, let finalContent = bestAttemptContent {
                    handler(finalContent)
                    self.contentHandler = nil
                }
            }
        } catch {
            if let handler = self.contentHandler {
                handler(content)
                self.contentHandler = nil
            }
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
