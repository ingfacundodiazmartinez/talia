//
//  FirebaseUploadService.swift
//  TaliaShareExtension
//
//  Servicio para subir contenido directamente a Firebase desde la Share Extension
//  Usa REST API para Firebase Storage y Firestore
//

import Foundation
import UIKit

/// Resultado del upload
enum UploadResult {
    case success(messageId: String)
    case error(String)
}

/// Tipo de destino para el contenido compartido
enum ShareDestination {
    case chat
    case story
}

/// Servicio para manejar uploads a Firebase desde la Share Extension
class FirebaseUploadService {

    static let shared = FirebaseUploadService()

    // Firebase project config
    private let projectId = "talia-chat-app-v2"
    private let storageBucket = "talia-chat-app-v2.firebasestorage.app"
    private let appGroupId = "group.com.talia.chat"

    // Background session for uploads
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.talia.chat.shareExtension.upload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.sharedContainerIdentifier = appGroupId
        return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
    }()

    private init() {}

    // MARK: - Auth Token Management (via App Group)

    /// Estructura para decodificar credenciales
    private struct Credentials: Codable {
        let userId: String
        let idToken: String
        let timestamp: Int
    }

    /// Cache de credenciales para evitar leer archivo repetidamente
    private var cachedCredentials: Credentials?

    /// Cargar credenciales desde App Group
    private func loadCredentials() -> Credentials? {
        // Retornar cache si existe y es reciente (menos de 5 minutos)
        if let cached = cachedCredentials {
            let age = Date().timeIntervalSince1970 * 1000 - Double(cached.timestamp)
            if age < 5 * 60 * 1000 { // 5 minutos
                return cached
            }
        }

        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            NSLog("❌ [FirebaseUpload] App Group container not available")
            return nil
        }

        let credentialsURL = containerURL.appendingPathComponent("firebase_credentials.json")

        guard FileManager.default.fileExists(atPath: credentialsURL.path) else {
            NSLog("⚠️ [FirebaseUpload] Credentials file not found")
            return nil
        }

        do {
            let data = try Data(contentsOf: credentialsURL)
            let credentials = try JSONDecoder().decode(Credentials.self, from: data)

            // Verificar que el token no sea muy viejo (Firebase tokens expiran en 1 hora)
            let tokenAge = Date().timeIntervalSince1970 * 1000 - Double(credentials.timestamp)
            if tokenAge > 55 * 60 * 1000 { // 55 minutos
                NSLog("⚠️ [FirebaseUpload] Token too old (\(Int(tokenAge / 60000)) min)")
                return nil
            }

            cachedCredentials = credentials
            NSLog("✅ [FirebaseUpload] Loaded credentials for user: \(credentials.userId.prefix(8))...")
            return credentials
        } catch {
            NSLog("❌ [FirebaseUpload] Error loading credentials: \(error)")
            return nil
        }
    }

    /// Obtener token de autenticación desde App Group
    func getAuthToken() -> String? {
        return loadCredentials()?.idToken
    }

    /// Obtener User ID desde App Group
    func getUserId() -> String? {
        return loadCredentials()?.userId
    }

    /// Verificar si el usuario está autenticado
    func isAuthenticated() -> Bool {
        return loadCredentials() != nil
    }

    // MARK: - Upload to Chat

    /// Enviar contenido a uno o más chats
    func sendToChats(
        items: [SharedItem],
        chatIds: [String],
        completion: @escaping (UploadResult) -> Void
    ) {
        guard let token = getAuthToken(), let userId = getUserId() else {
            NSLog("❌ [FirebaseUpload] Not authenticated")
            completion(.error("No estás autenticado. Abre la app primero."))
            return
        }

        NSLog("📤 [FirebaseUpload] Sending \(items.count) items to \(chatIds.count) chats")

        let group = DispatchGroup()
        var lastError: String?
        var successCount = 0

        for chatId in chatIds {
            for item in items {
                group.enter()

                sendSingleItem(item, toChatId: chatId, userId: userId, token: token) { result in
                    switch result {
                    case .success:
                        successCount += 1
                    case .error(let error):
                        lastError = error
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            if successCount > 0 {
                NSLog("✅ [FirebaseUpload] Sent \(successCount) items successfully")
                completion(.success(messageId: "batch_\(successCount)"))
            } else {
                NSLog("❌ [FirebaseUpload] All items failed: \(lastError ?? "Unknown error")")
                completion(.error(lastError ?? "Error al enviar"))
            }
        }
    }

    /// Enviar un item individual a un chat
    private func sendSingleItem(
        _ item: SharedItem,
        toChatId chatId: String,
        userId: String,
        token: String,
        completion: @escaping (UploadResult) -> Void
    ) {
        // Primero verificar si el chat tiene moderación
        checkChatModeration(chatId: chatId, userId: userId, token: token) { [weak self] hasModeration in
            guard let self = self else { return }

            NSLog("📤 [FirebaseUpload] Chat \(chatId) moderation: \(hasModeration)")

            switch item.type {
            case .image, .video:
                guard let fileURL = item.url else {
                    completion(.error("No file URL"))
                    return
                }
                self.uploadMediaAndCreateMessage(
                    fileURL: fileURL,
                    mediaType: item.type == .image ? "image" : "video",
                    chatId: chatId,
                    userId: userId,
                    token: token,
                    useCloudFunction: hasModeration,
                    completion: completion
                )

            case .text, .url:
                let text = item.text ?? ""
                if hasModeration {
                    self.sendMessageViaCloudFunction(
                        text: text,
                        type: "text",
                        mediaURL: nil,
                        chatId: chatId,
                        token: token,
                        completion: completion
                    )
                } else {
                    self.createTextMessage(
                        text: text,
                        chatId: chatId,
                        userId: userId,
                        token: token,
                        completion: completion
                    )
                }
            }
        }
    }

    // MARK: - Moderation Check

    /// Verificar si el chat tiene moderación activada
    private func checkChatModeration(
        chatId: String,
        userId: String,
        token: String,
        completion: @escaping (Bool) -> Void
    ) {
        // 1. Verificar moderación a nivel de chat
        let chatURL = "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents/chats/\(chatId)"

        guard let url = URL(string: chatURL) else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else {
                completion(false)
                return
            }

            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let fields = json["fields"] as? [String: Any] {

                // Verificar moderationEnabled en el chat
                if let modEnabled = fields["moderationEnabled"] as? [String: Any],
                   let value = modEnabled["booleanValue"] as? Bool,
                   value == true {
                    NSLog("🔒 [FirebaseUpload] Chat has moderation enabled")
                    completion(true)
                    return
                }
            }

            // 2. Si no hay moderación en chat, verificar en contacto
            self.checkContactModeration(chatId: chatId, userId: userId, token: token, completion: completion)
        }.resume()
    }

    /// Verificar moderación a nivel de contacto
    private func checkContactModeration(
        chatId: String,
        userId: String,
        token: String,
        completion: @escaping (Bool) -> Void
    ) {
        // Extraer el otro usuario del chatId (formato: user1_user2)
        let parts = chatId.split(separator: "_")
        guard parts.count >= 2 else {
            completion(false)
            return
        }

        let otherUserId = parts[0] == Substring(userId) ? String(parts[1]) : String(parts[0])
        let sortedUsers = [userId, otherUserId].sorted()

        // Buscar contacto - usando query
        let contactsURL = "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents:runQuery"

        guard let url = URL(string: contactsURL) else {
            completion(false)
            return
        }

        let query: [String: Any] = [
            "structuredQuery": [
                "from": [["collectionId": "contacts"]],
                "where": [
                    "fieldFilter": [
                        "field": ["fieldPath": "users"],
                        "op": "EQUAL",
                        "value": ["arrayValue": ["values": sortedUsers.map { ["stringValue": $0] }]]
                    ]
                ],
                "limit": 1
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let jsonData = try? JSONSerialization.data(withJSONObject: query) else {
            completion(false)
            return
        }
        request.httpBody = jsonData

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let results = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let firstResult = results.first,
                  let document = firstResult["document"] as? [String: Any],
                  let fields = document["fields"] as? [String: Any],
                  let moderationSettings = fields["moderationSettings"] as? [String: Any],
                  let mapValue = moderationSettings["mapValue"] as? [String: Any],
                  let mapFields = mapValue["fields"] as? [String: Any],
                  let userModeration = mapFields[userId] as? [String: Any],
                  let userMapValue = userModeration["mapValue"] as? [String: Any],
                  let userMapFields = userMapValue["fields"] as? [String: Any],
                  let enabled = userMapFields["enabled"] as? [String: Any],
                  let enabledValue = enabled["booleanValue"] as? Bool
            else {
                completion(false)
                return
            }

            NSLog("🔒 [FirebaseUpload] Contact moderation for user \(userId): \(enabledValue)")
            completion(enabledValue)
        }.resume()
    }

    // MARK: - Cloud Function

    /// Enviar mensaje via Cloud Function (cuando hay moderación)
    private func sendMessageViaCloudFunction(
        text: String,
        type: String,
        mediaURL: String?,
        chatId: String,
        token: String,
        completion: @escaping (UploadResult) -> Void
    ) {
        let cfURL = "https://us-central1-\(projectId).cloudfunctions.net/sendChatMessage"

        guard let url = URL(string: cfURL) else {
            completion(.error("Invalid CF URL"))
            return
        }

        var body: [String: Any] = [
            "chatId": chatId,
            "text": text,
            "type": type,
            "requiresModeration": true
        ]

        if let mediaURL = mediaURL {
            if type == "image" {
                body["imageUrl"] = mediaURL
            } else if type == "video" {
                body["videoUrl"] = mediaURL
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let jsonData = try? JSONSerialization.data(withJSONObject: ["data": body]) else {
            completion(.error("Error serializing request"))
            return
        }
        request.httpBody = jsonData

        NSLog("📤 [FirebaseUpload] Sending via Cloud Function (moderation)...")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("❌ [FirebaseUpload] CF error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(.error("Error enviando: \(error.localizedDescription)"))
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    completion(.error("Invalid response"))
                }
                return
            }

            if httpResponse.statusCode == 200 {
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let result = json["result"] as? [String: Any],
                   let messageId = result["messageId"] as? String {
                    NSLog("✅ [FirebaseUpload] CF success: \(messageId)")
                    DispatchQueue.main.async {
                        completion(.success(messageId: messageId))
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(.success(messageId: "cf_success"))
                    }
                }
            } else {
                if let data = data, let errorStr = String(data: data, encoding: .utf8) {
                    NSLog("❌ [FirebaseUpload] CF failed (\(httpResponse.statusCode)): \(errorStr)")
                }
                DispatchQueue.main.async {
                    completion(.error("Error enviando (código \(httpResponse.statusCode))"))
                }
            }
        }.resume()
    }

    // MARK: - Upload Media

    /// Subir media a Firebase Storage y crear mensaje
    private func uploadMediaAndCreateMessage(
        fileURL: URL,
        mediaType: String,
        chatId: String,
        userId: String,
        token: String,
        useCloudFunction: Bool = false,
        completion: @escaping (UploadResult) -> Void
    ) {
        // 1. Leer datos del archivo
        guard var fileData = try? Data(contentsOf: fileURL) else {
            completion(.error("No se pudo leer el archivo"))
            return
        }

        // Determinar extensión y content type
        var fileExtension = fileURL.pathExtension.lowercased()
        var contentType: String

        // Convertir HEIC/HEIF a JPEG (Firebase Storage no maneja bien HEIC)
        if fileExtension == "heic" || fileExtension == "heif" {
            NSLog("📤 [FirebaseUpload] Converting HEIC to JPEG...")
            if let image = UIImage(data: fileData),
               let jpegData = image.jpegData(compressionQuality: 0.85) {
                fileData = jpegData
                fileExtension = "jpg"
                NSLog("✅ [FirebaseUpload] Converted to JPEG: \(jpegData.count) bytes")
            }
        }

        switch fileExtension {
        case "jpg", "jpeg":
            contentType = "image/jpeg"
        case "png":
            contentType = "image/png"
        case "gif":
            contentType = "image/gif"
        case "mp4":
            contentType = "video/mp4"
        case "mov":
            contentType = "video/quicktime"
        default:
            // Si es imagen pero extensión desconocida, intentar convertir a JPEG
            if mediaType == "image" {
                if let image = UIImage(data: fileData),
                   let jpegData = image.jpegData(compressionQuality: 0.85) {
                    fileData = jpegData
                    fileExtension = "jpg"
                    contentType = "image/jpeg"
                    NSLog("📤 [FirebaseUpload] Converted unknown image to JPEG")
                } else {
                    contentType = "image/jpeg"
                }
            } else {
                contentType = "video/mp4"
            }
        }

        let fileName = "\(UUID().uuidString).\(fileExtension.isEmpty ? "jpg" : fileExtension)"
        // Storage rules expect: chat_media/{mediaType}/{chatId}/{fileName}
        // mediaType = "images" or "videos"
        let mediaTypeFolder = mediaType == "image" ? "images" : "videos"
        let storagePath = "chat_media/\(mediaTypeFolder)/\(chatId)/\(fileName)"

        // 2. URL de upload a Firebase Storage
        // IMPORTANTE: El path debe estar completamente URL-encoded (incluyendo /)
        guard let encodedPath = storagePath.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) else {
            completion(.error("Error encoding path"))
            return
        }

        let uploadURLString = "https://firebasestorage.googleapis.com/v0/b/\(storageBucket)/o?uploadType=media&name=\(encodedPath)"

        guard let uploadURL = URL(string: uploadURLString) else {
            completion(.error("Invalid upload URL"))
            return
        }

        NSLog("📤 [FirebaseUpload] Uploading to: \(storagePath)")
        NSLog("📤 [FirebaseUpload] URL: \(uploadURLString)")
        NSLog("📤 [FirebaseUpload] Content-Type: \(contentType)")
        NSLog("📤 [FirebaseUpload] File size: \(fileData.count) bytes")

        // 3. Crear request de upload
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        // 4. Ejecutar upload
        let task = URLSession.shared.uploadTask(with: request, from: fileData) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                NSLog("❌ [FirebaseUpload] Upload error: \(error.localizedDescription)")
                completion(.error("Error subiendo archivo: \(error.localizedDescription)"))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.error("Invalid response"))
                return
            }

            NSLog("📤 [FirebaseUpload] Response status: \(httpResponse.statusCode)")

            if httpResponse.statusCode != 200 {
                var errorMessage = "Error subiendo archivo (código \(httpResponse.statusCode))"
                if let data = data, let errorStr = String(data: data, encoding: .utf8) {
                    NSLog("❌ [FirebaseUpload] Upload failed (\(httpResponse.statusCode)): \(errorStr)")

                    // Intentar parsear error de Firebase
                    if let jsonData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let error = jsonData["error"] as? [String: Any],
                       let message = error["message"] as? String {
                        errorMessage = message
                        NSLog("❌ [FirebaseUpload] Firebase error: \(message)")
                    }
                }
                completion(.error(errorMessage))
                return
            }

            // 5. Extraer downloadToken de la respuesta para construir URL accesible
            var downloadToken: String?
            if let data = data {
                if let responseStr = String(data: data, encoding: .utf8) {
                    NSLog("✅ [FirebaseUpload] Upload response: \(responseStr.prefix(500))...")
                }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let token = json["downloadTokens"] as? String {
                    downloadToken = token
                    NSLog("✅ [FirebaseUpload] Got download token: \(token.prefix(20))...")
                }
            }

            // Construir URL pública del archivo con token
            var downloadURL = "https://firebasestorage.googleapis.com/v0/b/\(self.storageBucket)/o/\(encodedPath)?alt=media"
            if let token = downloadToken {
                downloadURL += "&token=\(token)"
            }
            NSLog("✅ [FirebaseUpload] Download URL: \(downloadURL)")

            NSLog("✅ [FirebaseUpload] Upload complete: \(downloadURL.prefix(50))...")

            // 6. Crear mensaje - via CF si hay moderación, directo si no
            if useCloudFunction {
                self.sendMessageViaCloudFunction(
                    text: "",
                    type: mediaType,
                    mediaURL: downloadURL,
                    chatId: chatId,
                    token: token,
                    completion: completion
                )
            } else {
                self.createMediaMessage(
                    mediaURL: downloadURL,
                    mediaType: mediaType,
                    chatId: chatId,
                    userId: userId,
                    token: token,
                    completion: completion
                )
            }
        }

        task.resume()
    }

    // MARK: - Create Messages

    /// Crear mensaje de texto en Firestore
    private func createTextMessage(
        text: String,
        chatId: String,
        userId: String,
        token: String,
        completion: @escaping (UploadResult) -> Void
    ) {
        let messageId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())

        let messageData: [String: Any] = [
            "fields": [
                "id": ["stringValue": messageId],
                "senderId": ["stringValue": userId],
                "text": ["stringValue": text],
                "type": ["stringValue": "text"],
                "timestamp": ["timestampValue": now],
                "isRead": ["booleanValue": false],
                "status": ["stringValue": "sent"],
                "moderationStatus": ["stringValue": "approved"]
            ]
        ]

        createFirestoreDocument(
            collection: "chats/\(chatId)/messages",
            documentId: messageId,
            data: messageData,
            token: token,
            completion: { result in
                switch result {
                case .success:
                    // También actualizar lastMessage del chat
                    self.updateChatLastMessage(chatId: chatId, text: text, userId: userId, token: token)
                    completion(.success(messageId: messageId))
                case .error(let error):
                    completion(.error(error))
                }
            }
        )
    }

    /// Crear mensaje de media en Firestore
    private func createMediaMessage(
        mediaURL: String,
        mediaType: String,
        chatId: String,
        userId: String,
        token: String,
        completion: @escaping (UploadResult) -> Void
    ) {
        let messageId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())

        var fields: [String: Any] = [
            "id": ["stringValue": messageId],
            "senderId": ["stringValue": userId],
            "type": ["stringValue": mediaType],
            "timestamp": ["timestampValue": now],
            "isRead": ["booleanValue": false],
            "status": ["stringValue": "sent"],
            "moderationStatus": ["stringValue": "approved"]
        ]

        // Agregar URL según tipo de media
        if mediaType == "image" {
            fields["imageUrl"] = ["stringValue": mediaURL]
        } else {
            fields["videoUrl"] = ["stringValue": mediaURL]
        }

        let messageData: [String: Any] = ["fields": fields]

        createFirestoreDocument(
            collection: "chats/\(chatId)/messages",
            documentId: messageId,
            data: messageData,
            token: token,
            completion: { result in
                switch result {
                case .success:
                    let preview = mediaType == "image" ? "Imagen" : "Video"
                    self.updateChatLastMessage(chatId: chatId, text: preview, userId: userId, token: token)
                    completion(.success(messageId: messageId))
                case .error(let error):
                    completion(.error(error))
                }
            }
        )
    }

    /// Actualizar lastMessage del chat
    private func updateChatLastMessage(chatId: String, text: String, userId: String, token: String) {
        let now = ISO8601DateFormatter().string(from: Date())

        let updateData: [String: Any] = [
            "fields": [
                "lastMessage": ["stringValue": text],
                "lastMessageSender": ["stringValue": userId],
                "lastMessageTime": ["timestampValue": now],
                "updatedAt": ["timestampValue": now]
            ]
        ]

        let urlString = "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents/chats/\(chatId)?updateMask.fieldPaths=lastMessage&updateMask.fieldPaths=lastMessageSender&updateMask.fieldPaths=lastMessageTime&updateMask.fieldPaths=updatedAt"

        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let jsonData = try? JSONSerialization.data(withJSONObject: updateData) {
            request.httpBody = jsonData

            URLSession.shared.dataTask(with: request) { _, _, error in
                if let error = error {
                    NSLog("⚠️ [FirebaseUpload] Error updating chat: \(error.localizedDescription)")
                } else {
                    NSLog("✅ [FirebaseUpload] Chat lastMessage updated")
                }
            }.resume()
        }
    }

    // MARK: - Create Story

    /// Crear historia desde media compartido
    func createStory(
        item: SharedItem,
        completion: @escaping (UploadResult) -> Void
    ) {
        guard let token = getAuthToken(), let userId = getUserId() else {
            completion(.error("No estás autenticado. Abre la app primero."))
            return
        }

        guard item.type == .image || item.type == .video, let fileURL = item.url else {
            completion(.error("Solo se pueden crear historias con imágenes o videos"))
            return
        }

        NSLog("📤 [FirebaseUpload] Creating story...")

        // 1. Subir media
        guard var fileData = try? Data(contentsOf: fileURL) else {
            completion(.error("No se pudo leer el archivo"))
            return
        }

        var fileExtension = fileURL.pathExtension.lowercased()

        // Convert HEIC/HEIF to JPEG
        if fileExtension == "heic" || fileExtension == "heif" {
            NSLog("📤 [FirebaseUpload] Converting HEIC to JPEG for story...")
            if let image = UIImage(data: fileData),
               let jpegData = image.jpegData(compressionQuality: 0.85) {
                fileData = jpegData
                fileExtension = "jpg"
            }
        }

        let storyId = UUID().uuidString
        let fileName = "\(UUID().uuidString).\(fileExtension)"
        // Storage rules expect: stories/{userId}/{storyId}/{fileName}
        let storagePath = "stories/\(userId)/\(storyId)/\(fileName)"
        let mediaType = item.type == .image ? "image" : "video"

        // Encode path properly for Firebase Storage REST API
        guard let encodedPath = storagePath.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) else {
            completion(.error("Error encoding path"))
            return
        }

        let uploadURLString = "https://firebasestorage.googleapis.com/v0/b/\(storageBucket)/o?uploadType=media&name=\(encodedPath)"

        guard let uploadURL = URL(string: uploadURLString) else {
            completion(.error("Invalid upload URL"))
            return
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(mediaType == "image" ? "image/jpeg" : "video/mp4", forHTTPHeaderField: "Content-Type")

        URLSession.shared.uploadTask(with: request, from: fileData) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                completion(.error("Error subiendo: \(error.localizedDescription)"))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                if let httpResponse = response as? HTTPURLResponse, let data = data, let errorStr = String(data: data, encoding: .utf8) {
                    NSLog("❌ [FirebaseUpload] Story upload failed (\(httpResponse.statusCode)): \(errorStr)")
                }
                completion(.error("Error subiendo archivo"))
                return
            }

            // Extraer downloadToken de la respuesta
            var downloadToken: String?
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let token = json["downloadTokens"] as? String {
                downloadToken = token
            }

            var downloadURL = "https://firebasestorage.googleapis.com/v0/b/\(self.storageBucket)/o/\(encodedPath)?alt=media"
            if let token = downloadToken {
                downloadURL += "&token=\(token)"
            }

            // 2. Crear documento de historia (usar el mismo storyId del path)
            self.createStoryDocument(
                storyId: storyId,
                mediaURL: downloadURL,
                mediaType: mediaType,
                userId: userId,
                token: token,
                completion: completion
            )
        }.resume()
    }

    /// Crear documento de historia en Firestore
    private func createStoryDocument(
        storyId: String,
        mediaURL: String,
        mediaType: String,
        userId: String,
        token: String,
        completion: @escaping (UploadResult) -> Void
    ) {
        let now = Date()
        let expiresAt = now.addingTimeInterval(24 * 60 * 60) // 24 horas

        let nowISO = ISO8601DateFormatter().string(from: now)
        let expiresISO = ISO8601DateFormatter().string(from: expiresAt)

        let storyData: [String: Any] = [
            "fields": [
                "id": ["stringValue": storyId],
                "userId": ["stringValue": userId],
                "mediaUrl": ["stringValue": mediaURL],
                "mediaType": ["stringValue": mediaType],
                "createdAt": ["timestampValue": nowISO],
                "expiresAt": ["timestampValue": expiresISO],
                "viewedBy": ["arrayValue": ["values": []]],
                "isActive": ["booleanValue": true]
            ]
        ]

        createFirestoreDocument(
            collection: "stories",
            documentId: storyId,
            data: storyData,
            token: token,
            completion: completion
        )
    }

    // MARK: - Firestore Helpers

    /// Crear documento en Firestore usando REST API
    private func createFirestoreDocument(
        collection: String,
        documentId: String,
        data: [String: Any],
        token: String,
        completion: @escaping (UploadResult) -> Void
    ) {
        let urlString = "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents/\(collection)/\(documentId)"

        guard let url = URL(string: urlString) else {
            completion(.error("Invalid Firestore URL"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"  // PATCH creates or updates
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let jsonData = try? JSONSerialization.data(withJSONObject: data) else {
            completion(.error("Error serializing data"))
            return
        }

        request.httpBody = jsonData

        NSLog("📝 [FirebaseUpload] Creating document: \(collection)/\(documentId)")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                NSLog("❌ [FirebaseUpload] Firestore error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    completion(.error("Error guardando: \(error.localizedDescription)"))
                }
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                DispatchQueue.main.async {
                    completion(.error("Invalid response"))
                }
                return
            }

            if httpResponse.statusCode == 200 {
                NSLog("✅ [FirebaseUpload] Document created: \(documentId)")
                DispatchQueue.main.async {
                    completion(.success(messageId: documentId))
                }
            } else {
                if let data = data, let errorStr = String(data: data, encoding: .utf8) {
                    NSLog("❌ [FirebaseUpload] Firestore failed (\(httpResponse.statusCode)): \(errorStr)")
                }
                DispatchQueue.main.async {
                    completion(.error("Error guardando (código \(httpResponse.statusCode))"))
                }
            }
        }.resume()
    }
}
