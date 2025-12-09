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

    // ✅ App Group para compartir datos con la app principal
    private let appGroupId = "group.com.talia.chat"
    private let maxStoredIds = 100 // Limitar para no consumir mucha memoria

    // ✅ Archivos compartidos via FileManager (más confiable que UserDefaults para NSE)
    private let processedIdsFileName = "nse_processed_ids.json"
    private let debugLogFileName = "nse_debug_log.json"

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let bestAttemptContent = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        NSLog("📥 [NSE] Recibiendo notificación")
        appendDebugLog("NSE TRIGGERED")

        // Log todas las keys del userInfo para diagnóstico
        let keys = bestAttemptContent.userInfo.keys.map { String(describing: $0) }.joined(separator: ", ")
        NSLog("📦 [NSE] UserInfo keys: \(keys)")
        appendDebugLog("KEYS: \(keys)")

        // ✅ FILTRAR TIPOS SILENCIOSOS: No mostrar notificación para ciertos tipos
        // location_request: Solicitud de ubicación del padre - operación silenciosa
        let notificationType = bestAttemptContent.userInfo["type"] as? String
        NSLog("📋 [NSE] Notification type: \(notificationType ?? "nil")")

        if notificationType == "location_request" {
            NSLog("📍 [NSE] location_request detectado - NO mostrar notificación (operación silenciosa)")
            appendDebugLog("FILTERED: location_request - silent operation")
            // Entregar contenido vacío para suprimir la notificación
            bestAttemptContent.title = ""
            bestAttemptContent.body = ""
            bestAttemptContent.sound = nil
            contentHandler(bestAttemptContent)
            return
        }

        // ✅ Guardar messageId en App Group para que la app Dart sepa que NSE ya lo procesó
        // Intentar múltiples paths ya que FCM puede estructurar los datos de diferentes formas
        var messageId: String? = nil

        // Path 1: Directamente en userInfo
        if let id = bestAttemptContent.userInfo["messageId"] as? String {
            messageId = id
            NSLog("📍 [NSE] messageId encontrado directo: \(id)")
            appendDebugLog("FOUND DIRECT: \(id)")
        }
        // Path 2: Dentro de "data" si existe
        else if let data = bestAttemptContent.userInfo["data"] as? [String: Any],
                let id = data["messageId"] as? String {
            messageId = id
            NSLog("📍 [NSE] messageId encontrado en data: \(id)")
            appendDebugLog("FOUND IN DATA: \(id)")
        }
        // Path 3: Dentro de "aps.alert.data" (alternativo)
        else if let aps = bestAttemptContent.userInfo["aps"] as? [String: Any],
                let alert = aps["alert"] as? [String: Any],
                let id = alert["messageId"] as? String {
            messageId = id
            NSLog("📍 [NSE] messageId encontrado en aps.alert: \(id)")
            appendDebugLog("FOUND IN APS.ALERT: \(id)")
        }

        if let messageId = messageId {
            saveProcessedMessageId(messageId)
            NSLog("💾 [NSE] MessageId guardado en App Group: \(messageId)")
        } else {
            NSLog("⚠️ [NSE] No se encontró messageId en userInfo")
            appendDebugLog("NOT FOUND - checking all values:")
            // Log de todas las keys para diagnóstico
            for (key, value) in bestAttemptContent.userInfo {
                let valueStr = String(describing: value).prefix(100)
                NSLog("📋 [NSE] userInfo[\(key)] = \(valueStr)")
                appendDebugLog("  \(key): \(valueStr)")
            }
        }

        // Obtener información del sender del payload
        let senderPhotoUrl = bestAttemptContent.userInfo["senderPhotoUrl"] as? String
        let senderName = bestAttemptContent.userInfo["senderName"] as? String ?? "Usuario"
        let senderId = bestAttemptContent.userInfo["senderId"] as? String ?? "unknown"

        // Si hay foto del sender, crear Communication Notification
        if let photoUrlString = senderPhotoUrl,
           let photoUrl = URL(string: photoUrlString) {

            NSLog("📥 [NSE] Descargando foto del remitente")

            // Descargar la imagen de forma asíncrona
            downloadImage(from: photoUrl) { [weak self] imageData in
                guard let self = self else { return }

                if let imageData = imageData {
                    NSLog("✅ [NSE] Foto descargada")

                    // Crear Communication Notification
                    self.createCommunicationNotification(
                        content: bestAttemptContent,
                        senderName: senderName,
                        senderId: senderId,
                        avatarData: imageData
                    )
                } else {
                    NSLog("⚠️ [NSE] No se pudo descargar la foto, usando notificación estándar")
                    contentHandler(bestAttemptContent)
                }
            }
        } else {
            NSLog("ℹ️ [NSE] No hay senderPhotoUrl, usando notificación estándar")
            contentHandler(bestAttemptContent)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        NSLog("⏰ [NSE] Tiempo expirado, entregando notificación")
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
                NSLog("✅ [NSE] Communication Notification creada exitosamente")
                self.contentHandler?(updatedContent)
            } else {
                NSLog("⚠️ [NSE] No se pudo actualizar el content con el intent")
                self.contentHandler?(content)
            }
        } catch {
            NSLog("❌ [NSE] Error creando Communication Notification: \(error.localizedDescription)")
            self.contentHandler?(content)
        }
    }

    private func downloadImage(from url: URL, completion: @escaping (Data?) -> Void) {
        let task = URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                NSLog("❌ [NSE] Error descargando imagen: \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let data = data else {
                NSLog("❌ [NSE] No se recibieron datos de imagen")
                completion(nil)
                return
            }

            NSLog("✅ [NSE] Imagen descargada: \(data.count) bytes")
            completion(data)
        }

        task.resume()
    }

    // MARK: - App Group File Storage (más confiable que UserDefaults para NSE)

    /// Obtiene la URL del directorio compartido del App Group
    private func getSharedContainerURL() -> URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    /// Guarda el messageId en archivo compartido para que la app Dart sepa que NSE ya lo procesó
    private func saveProcessedMessageId(_ messageId: String) {
        guard let containerURL = getSharedContainerURL() else {
            NSLog("⚠️ [NSE] No se pudo acceder al App Group container")
            appendDebugLog("ERROR: No se pudo acceder al App Group container")
            return
        }

        let fileURL = containerURL.appendingPathComponent(processedIdsFileName)

        // Leer IDs existentes
        var processedIds: [String] = []
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            processedIds = decoded
        }

        NSLog("📋 [NSE] IDs previos en archivo: \(processedIds.count)")

        // Evitar duplicados
        if !processedIds.contains(messageId) {
            processedIds.append(messageId)

            // Limitar tamaño del array (mantener solo los últimos N)
            if processedIds.count > maxStoredIds {
                processedIds = Array(processedIds.suffix(maxStoredIds))
            }

            // Guardar en archivo
            do {
                let data = try JSONEncoder().encode(processedIds)
                try data.write(to: fileURL, options: .atomic)
                NSLog("✅ [NSE] MessageId guardado en archivo. Total IDs: \(processedIds.count)")
                appendDebugLog("SAVED: \(messageId) (total: \(processedIds.count))")
            } catch {
                NSLog("❌ [NSE] Error guardando IDs: \(error.localizedDescription)")
                appendDebugLog("ERROR writing file: \(error.localizedDescription)")
            }
        } else {
            NSLog("ℹ️ [NSE] MessageId ya existe en archivo")
            appendDebugLog("DUPLICATE: \(messageId)")
        }
    }

    /// Agrega un mensaje de debug al archivo compartido para que Dart pueda leerlo
    private func appendDebugLog(_ message: String) {
        guard let containerURL = getSharedContainerURL() else { return }

        let fileURL = containerURL.appendingPathComponent(debugLogFileName)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let logEntry = "[\(timestamp)] \(message)"

        // Leer logs existentes
        var logs: [String] = []
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            logs = decoded
        }

        logs.append(logEntry)

        // Mantener solo los últimos 20 logs
        if logs.count > 20 {
            logs = Array(logs.suffix(20))
        }

        // Guardar en archivo
        do {
            let data = try JSONEncoder().encode(logs)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("❌ [NSE] Error guardando debug log: \(error.localizedDescription)")
        }
    }
}
