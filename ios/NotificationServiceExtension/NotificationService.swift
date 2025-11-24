//
//  NotificationService.swift
//  NotificationServiceExtension
//
//  Created by Ola GG on 05/10/2025.
//

import UserNotifications
import Intents
import UIKit

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

        print("📥 [NotificationService] Recibiendo notificación")
        print("📦 [NotificationService] UserInfo: \(bestAttemptContent.userInfo)")

        // Obtener información del sender del payload
        let senderPhotoUrl = bestAttemptContent.userInfo["senderPhotoUrl"] as? String
        let senderName = bestAttemptContent.userInfo["senderName"] as? String ?? "Usuario"
        let senderId = bestAttemptContent.userInfo["senderId"] as? String ?? "unknown"

        // Si hay foto del sender, crear Communication Notification
        if let photoUrlString = senderPhotoUrl,
           let photoUrl = URL(string: photoUrlString) {

            print("📥 [NotificationService] Descargando foto del remitente: \(photoUrlString)")

            // Descargar la imagen de forma asíncrona
            downloadImage(from: photoUrl) { [weak self] imageData in
                guard let self = self else { return }

                if let imageData = imageData {
                    print("✅ [NotificationService] Foto descargada")

                    // Crear Communication Notification
                    self.createCommunicationNotification(
                        content: bestAttemptContent,
                        senderName: senderName,
                        senderId: senderId,
                        avatarData: imageData
                    )
                } else {
                    print("⚠️ [NotificationService] No se pudo descargar la foto, usando notificación estándar")
                    contentHandler(bestAttemptContent)
                }
            }
        } else {
            print("ℹ️ [NotificationService] No hay senderPhotoUrl, usando notificación estándar")
            contentHandler(bestAttemptContent)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        print("⏰ [NotificationService] Tiempo expirado, entregando notificación")
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    // MARK: - Helper Methods

    private func createCommunicationNotification(
        content: UNMutableNotificationContent,
        senderName: String,
        senderId: String,
        avatarData: Data
    ) {
        do {
            // Crear INPersonHandle con el ID del sender
            let personHandle = INPersonHandle(value: senderId, type: .unknown)

            // Crear INImage con los datos de la foto del sender
            let avatar = INImage(imageData: avatarData)

            // Crear INPerson con el nombre, handle y avatar
            let sender = INPerson(
                personHandle: personHandle,
                nameComponents: nil,
                displayName: senderName,
                image: avatar,
                contactIdentifier: nil,
                customIdentifier: senderId
            )

            // Crear el intent de mensaje
            let intent = INSendMessageIntent(
                recipients: nil,
                outgoingMessageType: .outgoingMessageText,
                content: content.body,
                speakableGroupName: nil,
                conversationIdentifier: senderId,
                serviceName: nil,
                sender: sender,
                attachments: nil
            )

            // Configurar la imagen del sender en el intent
            intent.setImage(avatar, forParameterNamed: \.sender)

            // Crear interaction para donar al sistema
            let interaction = INInteraction(intent: intent, response: nil)
            interaction.direction = .incoming

            // Convertir el intent en notification content
            if let updatedContent = try? content.updating(from: intent) as? UNMutableNotificationContent {
                print("✅ [NotificationService] Communication Notification creada exitosamente")
                self.contentHandler?(updatedContent)
            } else {
                print("⚠️ [NotificationService] No se pudo actualizar el content con el intent")
                self.contentHandler?(content)
            }
        } catch {
            print("❌ [NotificationService] Error creando Communication Notification: \(error.localizedDescription)")
            self.contentHandler?(content)
        }
    }

    private func downloadImage(from url: URL, completion: @escaping (Data?) -> Void) {
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                print("❌ [NotificationService] Error descargando imagen: \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let data = data else {
                print("❌ [NotificationService] No se recibieron datos de imagen")
                completion(nil)
                return
            }

            print("✅ [NotificationService] Imagen descargada: \(data.count) bytes")
            completion(data)
        }

        task.resume()
    }
}
