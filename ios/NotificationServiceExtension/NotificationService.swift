//
//  NotificationService.swift
//  NotificationServiceExtension
//
//  Created by Ola GG on 05/10/2025.
//

import UserNotifications

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

        // Intentar obtener la URL de la imagen del payload
        if let imageUrlString = bestAttemptContent.userInfo["imageUrl"] as? String,
           let imageUrl = URL(string: imageUrlString) {

            print("📥 [NotificationService] Descargando imagen de: \(imageUrlString)")

            // Descargar la imagen de forma asíncrona
            downloadImage(from: imageUrl) { [weak self] attachment in
                guard let self = self else { return }

                if let attachment = attachment {
                    print("✅ [NotificationService] Imagen descargada y agregada como attachment")
                    bestAttemptContent.attachments = [attachment]
                } else {
                    print("⚠️ [NotificationService] No se pudo descargar la imagen")
                }

                contentHandler(bestAttemptContent)
            }
        } else {
            print("ℹ️ [NotificationService] No hay imageUrl en el payload")
            contentHandler(bestAttemptContent)
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

    private func downloadImage(from url: URL, completion: @escaping (UNNotificationAttachment?) -> Void) {
        let task = URLSession.shared.downloadTask(with: url) { localURL, response, error in
            if let error = error {
                print("❌ [NotificationService] Error descargando imagen: \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let localURL = localURL else {
                print("❌ [NotificationService] URL local no disponible")
                completion(nil)
                return
            }

            // Crear directorio temporal para guardar la imagen
            let tempDirectory = FileManager.default.temporaryDirectory
            let fileName = url.lastPathComponent.isEmpty ? "sender_photo.jpg" : url.lastPathComponent
            let tempFileURL = tempDirectory.appendingPathComponent(fileName)

            do {
                // Remover archivo si ya existe
                if FileManager.default.fileExists(atPath: tempFileURL.path) {
                    try FileManager.default.removeItem(at: tempFileURL)
                }

                // Mover el archivo descargado al directorio temporal
                try FileManager.default.moveItem(at: localURL, to: tempFileURL)

                // Crear el attachment
                let attachment = try UNNotificationAttachment(
                    identifier: "sender-photo",
                    url: tempFileURL,
                    options: nil
                )

                print("✅ [NotificationService] Attachment creado: \(tempFileURL)")
                completion(attachment)
            } catch {
                print("❌ [NotificationService] Error creando attachment: \(error.localizedDescription)")
                completion(nil)
            }
        }

        task.resume()
    }
}
