//
//  NotificationService.swift
//  NotificationServiceExtension
//
//  Created by Ola GG on 05/10/2025.
//

import UserNotifications
import Intents  // ✅ CRÍTICO: Para INPerson y Communication Notifications
import UIKit    // ✅ CRÍTICO: Para UIImage

@objc(NotificationService)
class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override init() {
        super.init()
        NSLog("[NSE] INIT - NotificationService class instantiated")
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        NSLog("[NSE] DIDRECEIVE - Method called, about to process notification")
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        NSLog("[NSE] START - Notification Service Extension executing")

        guard let bestAttemptContent = bestAttemptContent else {
            NSLog("[NSE] ERROR - Could not get bestAttemptContent")
            contentHandler(request.content)
            return
        }

        // Extraer datos del payload
        let senderPhotoUrl = bestAttemptContent.userInfo["senderPhotoUrl"] as? String
        let senderId = bestAttemptContent.userInfo["senderId"] as? String ?? "unknown"
        let senderName = bestAttemptContent.userInfo["senderName"] as? String ?? "Usuario"
        let chatId = bestAttemptContent.userInfo["chatId"] as? String ?? senderId

        NSLog("[NSE] Data received: sender=%@, chatId=%@", senderName, chatId)

        // ✅ UNIFIED: Try to get cached photo from shared App Group (0ms latency)
        if let cachedImage = TaliaPhotoCache.getCachedPhoto(userId: senderId) {
            NSLog("[NSE] Using cached photo for: %@", senderName)

            createCommunicationNotification(
                content: bestAttemptContent,
                senderName: senderName,
                senderId: senderId,
                chatId: chatId,
                image: cachedImage
            )
        } else if let photoUrl = senderPhotoUrl, !photoUrl.isEmpty, photoUrl != "null" {
            NSLog("[NSE] Cache MISS - Downloading photo (fallback): %@", photoUrl)

            // ⚠️ FALLBACK: Descargar si no está en cache (solo para mensajes antiguos)
            downloadImage(from: photoUrl) { [weak self] imageData in
                guard let self = self else { return }

                if let imageData = imageData, let image = UIImage(data: imageData) {
                    NSLog("[NSE] Photo downloaded (fallback), creating Communication Notification")

                    // ✅ Save to cache for next time
                    TaliaPhotoCache.savePhoto(userId: senderId, image: image)

                    self.createCommunicationNotification(
                        content: bestAttemptContent,
                        senderName: senderName,
                        senderId: senderId,
                        chatId: chatId,
                        image: image
                    )
                } else {
                    NSLog("[NSE] WARNING - Could not download photo, showing standard notification")
                    if let handler = self.contentHandler {
                        handler(bestAttemptContent)
                        self.contentHandler = nil
                    }
                }
            }
        } else {
            NSLog("[NSE] INFO - No sender photo, showing standard notification")
            contentHandler(bestAttemptContent)
            self.contentHandler = nil
        }
    }

    override func serviceExtensionTimeWillExpire() {
        NSLog("[NSE] TIMEOUT - Extension time expired")
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    // MARK: - Helper: Crear Communication Notification con INPerson

    private func createCommunicationNotification(
        content: UNMutableNotificationContent,
        senderName: String,
        senderId: String,
        chatId: String,
        image: UIImage
    ) {
        // Crear INPerson con foto (igual que AppDelegate.swift:344-354)
        let personHandle = INPersonHandle(value: senderId, type: .unknown)
        let avatar = INImage(imageData: image.jpegData(compressionQuality: 0.8)!)
        let sender = INPerson(
            personHandle: personHandle,
            nameComponents: nil,
            displayName: senderName,
            image: avatar,
            contactIdentifier: nil,
            customIdentifier: senderId
        )

        // Crear INSendMessageIntent (igual que AppDelegate.swift:357-366)
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

        // Asignar imagen explícitamente (AppDelegate.swift:369)
        intent.setImage(avatar, forParameterNamed: \INSendMessageIntent.sender)

        // Donar interacción (AppDelegate.swift:372-374)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = INInteractionDirection.incoming
        interaction.donate { (error: Error?) in
            if let error = error {
                NSLog("[NSE] ERROR donating interaction: %@", error.localizedDescription)
            }
        }

        // ✅ LO MÁS IMPORTANTE: Convertir a Communication Notification (AppDelegate.swift:378)
        do {
            let updatedContent = try content.updating(from: intent)

            // ✅ CRÍTICO: Actualizar bestAttemptContent con el contenido modificado
            if let mutableContent = updatedContent.mutableCopy() as? UNMutableNotificationContent {
                bestAttemptContent = mutableContent
                NSLog("[NSE] SUCCESS - Communication Notification created with circular photo")

                // ✅ DEVOLVER EL CONTENIDO ACTUALIZADO AHORA
                if let handler = self.contentHandler, let content = bestAttemptContent {
                    handler(content)
                    self.contentHandler = nil  // Prevenir múltiples llamadas
                }
            }
        } catch {
            NSLog("[NSE] ERROR creating Communication Notification: %@", error.localizedDescription)
            // Fallback: devolver contenido original
            if let handler = self.contentHandler {
                handler(content)
                self.contentHandler = nil
            }
        }
    }

    // MARK: - Helper: Descargar imagen

    private func downloadImage(from urlString: String, completion: @escaping (Data?) -> Void) {
        guard let url = URL(string: urlString) else {
            NSLog("[NSE] ERROR - Invalid URL: %@", urlString)
            completion(nil)
            return
        }

        // Timeout de 3 segundos para descarga
        let session = URLSession(configuration: .default)
        let task = session.dataTask(with: url) { data, response, error in
            if let error = error {
                NSLog("[NSE] ERROR downloading image: %@", error.localizedDescription)
                completion(nil)
                return
            }

            guard let data = data, !data.isEmpty else {
                NSLog("[NSE] ERROR - Empty image data")
                completion(nil)
                return
            }

            NSLog("[NSE] SUCCESS - Image downloaded (%lu bytes)", data.count)
            completion(data)
        }

        task.resume()
    }
}
