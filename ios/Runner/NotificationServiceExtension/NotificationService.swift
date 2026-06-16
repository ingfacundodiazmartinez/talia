import UserNotifications
import Intents  // Para INPerson y Communication Notifications
import UIKit    // Para UIImage

/// NSE: descarga la foto del sender, crea una Communication Notification con
/// foto circular, y marca el delivery receipt (`lastReceivedAt_{uid}`) — incluso
/// con la app COMPLETAMENTE cerrada.
///
/// 🔒 GARANTÍA: la notificación SIEMPRE se entrega. La entrega está blindada
/// con un `deliver()` idempotente + un timer de respaldo absoluto, así ni el
/// receipt ni la descarga de foto pueden impedir que la notificación se
/// muestre. El receipt corre en paralelo (best-effort) y nunca bloquea.
///
/// ⚠️ El receipt se escribe vía REST (HTTP con el idToken del App Group), NO
/// con el SDK de Firestore: el SDK es pesado para el NSE y su write gRPC con
/// la app muerta (socket frío) tardaba demasiado.
@objc(NotificationService)
class NotificationService: UNNotificationServiceExtension {

    private static let appGroupId = "group.com.talia.chat"
    private static let projectId = "talia-chat-app-v2"

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    // Entrega idempotente: se llame desde donde se llame, la notif sale 1 vez.
    private let lock = NSLock()
    private var delivered = false

    private func deliver() {
        lock.lock()
        let shouldDeliver = !delivered
        if shouldDeliver { delivered = true }
        lock.unlock()
        guard shouldDeliver, let handler = contentHandler, let content = bestAttemptContent else { return }
        handler(content)
    }

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        guard let bestAttemptContent = bestAttemptContent else {
            contentHandler(request.content)
            return
        }

        // 🔒 RESPALDO ABSOLUTO: pase lo que pase (foto cuelga, receipt cuelga,
        // crash de red), la notificación se entrega a los 6s como máximo.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 6.0) { [weak self] in
            self?.deliver()
        }

        // Extraer datos del payload
        let senderPhotoUrl = bestAttemptContent.userInfo["senderPhotoUrl"] as? String
        let groupPhotoUrl = bestAttemptContent.userInfo["groupPhotoUrl"] as? String
        let senderId = bestAttemptContent.userInfo["senderId"] as? String ?? "unknown"
        let senderName = bestAttemptContent.userInfo["senderName"] as? String ?? "Usuario"
        let chatId = bestAttemptContent.userInfo["chatId"] as? String ?? senderId
        let pushType = bestAttemptContent.userInfo["type"] as? String
        let isGroupValue = bestAttemptContent.userInfo["isGroup"]
        let isGroupChat: Bool = {
            if let b = isGroupValue as? Bool { return b }
            if let s = isGroupValue as? String { return s == "true" }
            return false
        }()

        // ✅ Delivery receipt vía REST, EN PARALELO (no bloquea la entrega).
        if pushType == "chat_message" && !isGroupChat && !chatId.isEmpty && chatId != "unknown" {
            DeliveryReceiptSender.send(chatId: chatId, appGroupId: Self.appGroupId, projectId: Self.projectId) {}
        }

        // Foto: cache → mostrar; URL → descargar; si nada, entregar tal cual.
        let photoUrlToUse: String? = isGroupChat
            ? ((groupPhotoUrl?.isEmpty == false ? groupPhotoUrl : nil) ?? senderPhotoUrl)
            : senderPhotoUrl
        let photoCacheKey: String = isGroupChat ? "group_\(chatId)" : senderId

        if let cachedImage = TaliaPhotoCache.getCachedPhotoIfUrlMatches(userId: photoCacheKey, currentUrl: photoUrlToUse) {
            applyCommunicationNotification(senderName: senderName, senderId: senderId, chatId: chatId, image: cachedImage)
            deliver()
        } else if let photoUrl = photoUrlToUse, !photoUrl.isEmpty, photoUrl != "null" {
            downloadImage(from: photoUrl) { [weak self] imageData in
                guard let self = self else { return }
                if let imageData = imageData, let image = UIImage(data: imageData) {
                    TaliaPhotoCache.savePhoto(userId: photoCacheKey, image: image, photoUrl: photoUrl)
                    self.applyCommunicationNotification(senderName: senderName, senderId: senderId, chatId: chatId, image: image)
                }
                self.deliver()
            }
        } else {
            deliver()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        deliver()
    }

    // MARK: - Communication Notification

    /// Convierte bestAttemptContent en una Communication Notification con foto.
    /// Si algo falla, deja el contenido como está (igual se entrega).
    private func applyCommunicationNotification(senderName: String, senderId: String, chatId: String, image: UIImage) {
        guard let content = bestAttemptContent,
              let imageData = image.jpegData(compressionQuality: 0.8) else { return }
        let avatar = INImage(imageData: imageData)
        let personHandle = INPersonHandle(value: senderId, type: .unknown)
        let sender = INPerson(personHandle: personHandle, nameComponents: nil, displayName: senderName, image: avatar, contactIdentifier: nil, customIdentifier: senderId)
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: content.body, speakableGroupName: nil, conversationIdentifier: chatId, serviceName: nil, sender: sender, attachments: nil)
        intent.setImage(avatar, forParameterNamed: \INSendMessageIntent.sender)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate { _ in }
        if let updated = try? content.updating(from: intent),
           let mutable = updated.mutableCopy() as? UNMutableNotificationContent {
            bestAttemptContent = mutable
        }
    }

    // MARK: - Descargar imagen

    private func downloadImage(from urlString: String, completion: @escaping (Data?) -> Void) {
        guard let url = URL(string: urlString) else { completion(nil); return }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 4
        URLSession(configuration: config).dataTask(with: url) { data, _, error in
            if error != nil || data == nil || data!.isEmpty { completion(nil); return }
            completion(data)
        }.resume()
    }
}

/// Escribe `lastReceivedAt_{uid}` en el chat doc vía Firestore REST usando las
/// credenciales del App Group. Best-effort, sin Firebase SDK.
enum DeliveryReceiptSender {

    private struct Credentials: Codable {
        let userId: String
        var idToken: String
        var timestamp: Int
        var refreshToken: String?
        var apiKey: String?
    }

    static func send(chatId: String, appGroupId: String, projectId: String, completion: @escaping () -> Void) {
        guard let creds = loadCredentials(appGroupId: appGroupId) else { completion(); return }
        freshIdToken(creds) { token in
            guard let token = token else { completion(); return }
            patchReceipt(chatId: chatId, uid: creds.userId, idToken: token, projectId: projectId, completion: completion)
        }
    }

    private static func loadCredentials(appGroupId: String) -> Credentials? {
        guard let url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)?
                .appendingPathComponent("firebase_credentials.json"),
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    private static func freshIdToken(_ creds: Credentials, completion: @escaping (String?) -> Void) {
        let ageMs = Date().timeIntervalSince1970 * 1000 - Double(creds.timestamp)
        if ageMs < 50 * 60 * 1000 { completion(creds.idToken); return }
        guard let refreshToken = creds.refreshToken, let apiKey = creds.apiKey,
              let url = URL(string: "https://securetoken.googleapis.com/v1/token?key=\(apiKey)") else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = refreshToken.addingPercentEncoding(withAllowedCharacters: allowed) ?? refreshToken
        req.httpBody = "grant_type=refresh_token&refresh_token=\(encoded)".data(using: .utf8)
        req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newToken = json["id_token"] as? String else { completion(nil); return }
            completion(newToken)
        }.resume()
    }

    private static func patchReceipt(chatId: String, uid: String, idToken: String, projectId: String, completion: @escaping () -> Void) {
        let field = "lastReceivedAt_\(uid)"
        let urlStr = "https://firestore.googleapis.com/v1/projects/\(projectId)/databases/(default)/documents/chats/\(chatId)?updateMask.fieldPaths=\(field)"
        guard let url = URL(string: urlStr) else { completion(); return }
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let body: [String: Any] = ["fields": [field: ["timestampValue": nowISO]]]
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 4
        URLSession.shared.dataTask(with: req) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                NSLog("📬 [NSE] Receipt REST status %d", http.statusCode)
            }
            completion()
        }.resume()
    }
}
