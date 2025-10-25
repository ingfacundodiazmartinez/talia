//
//  NotificationService.swift
//  NotificationServiceExtension
//
//  Created by Ola GG on 05/10/2025.
//

import UserNotifications
import Intents
import UIKit
import ImageIO

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
        let imageUrl = bestAttemptContent.userInfo["imageUrl"] as? String

        // Si hay foto del sender, crear Communication Notification
        if let photoUrlString = senderPhotoUrl,
           let photoUrl = URL(string: photoUrlString) {

            print("📥 [NotificationService] Descargando foto del remitente: \(photoUrlString)")

            // Descargar la imagen de forma asíncrona
            downloadImage(from: photoUrl) { [weak self] imageData in
                guard let self = self else { return }

                if let imageData = imageData {
                    print("✅ [NotificationService] Foto descargada")

                    // Si hay imageUrl, también descargarla y agregarla como attachment
                    if let imageUrlString = imageUrl,
                       let messageImageUrl = URL(string: imageUrlString) {
                        print("📥 [NotificationService] Descargando imagen del mensaje: \(imageUrlString)")

                        self.downloadImage(from: messageImageUrl) { messageImageData in
                            if let messageImageData = messageImageData {
                                print("✅ [NotificationService] Imagen del mensaje descargada")

                                // Corregir orientación EXIF y guardar como attachment
                                if let correctedImage = self.correctImageOrientation(data: messageImageData),
                                   let attachment = self.createImageAttachment(from: correctedImage) {
                                    bestAttemptContent.attachments = [attachment]
                                    print("✅ [NotificationService] Attachment agregado con orientación corregida")
                                }
                            }

                            // Crear Communication Notification con o sin attachment
                            self.createCommunicationNotification(
                                content: bestAttemptContent,
                                senderName: senderName,
                                senderId: senderId,
                                avatarData: imageData
                            )
                        }
                    } else {
                        // No hay imagen del mensaje, solo crear Communication Notification
                        self.createCommunicationNotification(
                            content: bestAttemptContent,
                            senderName: senderName,
                            senderId: senderId,
                            avatarData: imageData
                        )
                    }
                } else {
                    print("⚠️ [NotificationService] No se pudo descargar la foto, usando notificación estándar")
                    contentHandler(bestAttemptContent)
                }
            }
        } else {
            print("ℹ️ [NotificationService] No hay senderPhotoUrl")

            // Aunque no haya foto del sender, si hay imagen del mensaje, agregarla
            if let imageUrlString = imageUrl,
               let messageImageUrl = URL(string: imageUrlString) {
                print("📥 [NotificationService] Descargando imagen del mensaje: \(imageUrlString)")

                downloadImage(from: messageImageUrl) { [weak self] messageImageData in
                    guard let self = self else { return }

                    if let messageImageData = messageImageData {
                        print("✅ [NotificationService] Imagen del mensaje descargada")

                        // Corregir orientación EXIF y guardar como attachment
                        if let correctedImage = self.correctImageOrientation(data: messageImageData),
                           let attachment = self.createImageAttachment(from: correctedImage) {
                            bestAttemptContent.attachments = [attachment]
                            print("✅ [NotificationService] Attachment agregado con orientación corregida")
                        }
                    }

                    contentHandler(bestAttemptContent)
                }
            } else {
                contentHandler(bestAttemptContent)
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            print("⏰ [NotificationService] Tiempo expirado, entregando notificación")
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

    /// Corrige la orientación de una imagen según sus metadatos EXIF
    private func correctImageOrientation(data: Data) -> UIImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            print("⚠️ [NotificationService] No se pudo crear CGImageSource")
            return UIImage(data: data)
        }

        guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            print("⚠️ [NotificationService] No se pudo crear CGImage")
            return UIImage(data: data)
        }

        // Leer metadatos EXIF
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let orientationValue = properties[kCGImagePropertyOrientation] as? UInt32 else {
            print("✅ [NotificationService] Sin metadatos EXIF, usando imagen original")
            return UIImage(cgImage: cgImage)
        }

        let orientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up
        print("📐 [NotificationService] Orientación EXIF detectada: \(orientation.rawValue)")

        // Determinar la orientación UIImage correspondiente
        let uiOrientation: UIImage.Orientation
        switch orientation {
        case .up:
            uiOrientation = .up
        case .down:
            uiOrientation = .down
        case .left:
            uiOrientation = .left
        case .right:
            uiOrientation = .right
        case .upMirrored:
            uiOrientation = .upMirrored
        case .downMirrored:
            uiOrientation = .downMirrored
        case .leftMirrored:
            uiOrientation = .leftMirrored
        case .rightMirrored:
            uiOrientation = .rightMirrored
        }

        if uiOrientation != .up {
            print("🔄 [NotificationService] Corrigiendo orientación de \(orientation.rawValue) a .up")
        } else {
            print("✅ [NotificationService] Sin necesidad de corregir orientación")
        }

        return UIImage(cgImage: cgImage, scale: 1.0, orientation: uiOrientation)
    }

    /// Crea un UNNotificationAttachment a partir de una UIImage
    private func createImageAttachment(from image: UIImage) -> UNNotificationAttachment? {
        // Convertir UIImage a JPEG data
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            print("❌ [NotificationService] No se pudo convertir imagen a JPEG")
            return nil
        }

        // Crear un archivo temporal para guardar la imagen
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let tempFile = tempDirectory.appendingPathComponent(UUID().uuidString + ".jpg")

        do {
            // Guardar la imagen en el archivo temporal
            try imageData.write(to: tempFile)

            // Crear el attachment
            let attachment = try UNNotificationAttachment(
                identifier: UUID().uuidString,
                url: tempFile,
                options: [UNNotificationAttachmentOptionsTypeHintKey: "public.jpeg"]
            )

            print("✅ [NotificationService] Attachment creado: \(tempFile.lastPathComponent)")
            return attachment
        } catch {
            print("❌ [NotificationService] Error creando attachment: \(error.localizedDescription)")
            return nil
        }
    }
}
