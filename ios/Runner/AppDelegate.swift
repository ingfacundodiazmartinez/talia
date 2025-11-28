import UIKit
import Flutter
import Firebase
import UserNotifications
import GoogleMaps
import DeepAR
import PushKit
import CallKit
import flutter_callkit_incoming
import Intents  // ✅ Necesario para INPerson e INImage

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate, CXProviderDelegate {
  private var callProvider: CXProvider!
  private var callController: CXCallController!
  private var callUUIDToFirestoreID: [UUID: String] = [:] // Mapeo de UUID CallKit -> callId Firestore
  private var firestoreIDToCallUUID: [String: UUID] = [:] // ✅ PHASE 1B: Reverse mapping for duplicate prevention
  private var pendingVoIPToken: String? = nil // ✅ Guardar token VoIP temporalmente

  // ✅ FIX VIDEO CALL FROM LOCK SCREEN: Store callId that needs navigation after audio activates
  private var pendingVideoCallNavigation: String? = nil

  // ✅ FIX #9: Health check for Stream Detector
  private var lastStreamDetectorHeartbeat: Date? = nil
  private let streamDetectorTimeout: TimeInterval = 30.0 // 30 seconds

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FirebaseApp.configure()

    // Configure Google Maps with API key
    GMSServices.provideAPIKey("AIzaSyDmaRq41cBttgeopHCXh1HvtvGSAegwo7E")

    GeneratedPluginRegistrant.register(with: self)

    // Registrar plugin de DeepAR
    ArFiltersPlugin.register(with: registrar(forPlugin: "ArFiltersPlugin")!)

    // ✅ Setup CallKit Provider FIRST
    setupCallKitProvider()

    // ✅ Registrar VoIP Push Notifications
    voipRegistration()

    // ✅ Setup Method Channel para recibir notificaciones desde Flutter
    setupMethodChannel()

    // ✅ CRÍTICO: Configurar delegate para mostrar notificaciones en foreground
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
      NSLog("✅ [Notifications] UNUserNotificationCenter delegate configured")
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - Method Channel Setup

  private func setupMethodChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return
    }

    // VoIP channel para tokens
    let voipChannel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: controller.binaryMessenger)

    // CallKit channel para mostrar llamadas desde Flutter
    let callKitChannel = FlutterMethodChannel(name: "com.talia.chat/callkit", binaryMessenger: controller.binaryMessenger)

    // ✅ Photo Cache channel para guardar fotos en App Group
    let photoCacheChannel = FlutterMethodChannel(name: "com.talia.chat/photo_cache", binaryMessenger: controller.binaryMessenger)

    // ✅ Handle photo updates from Dart
    photoCacheChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      if call.method == "photoUpdated" {
        guard let args = call.arguments as? [String: Any],
              let userId = args["userId"] as? String,
              let photoBytes = args["photoBytes"] as? FlutterStandardTypedData else {
          NSLog("❌ [PhotoCache] Invalid arguments for photoUpdated")
          result(FlutterError(code: "INVALID_ARGS", message: "Missing userId or photoBytes", details: nil))
          return
        }

        let data = photoBytes.data
        TaliaPhotoCache.savePhotoData(userId: userId, data: data)
        NSLog("✅ [PhotoCache] Saved photo to App Group for: \(userId) (\(data.count) bytes)")
        result(true)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // ✅ NSE Deduplication channel para verificar si messageId ya fue procesado por NSE
    let nseDeduplicationChannel = FlutterMethodChannel(name: "com.talia.chat/nse_deduplication", binaryMessenger: controller.binaryMessenger)
    nseDeduplicationChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      let appGroupId = "group.com.talia.chat"
      let processedMessagesKey = "nse_processed_message_ids"

      if call.method == "wasProcessedByNSE" {
        // Verificar si un messageId ya fue procesado por el NSE
        guard let messageId = call.arguments as? String else {
          result(false)
          return
        }

        guard let userDefaults = UserDefaults(suiteName: appGroupId) else {
          NSLog("⚠️ [NSE Dedup] No se pudo acceder a App Group UserDefaults")
          result(false)
          return
        }

        let processedIds = userDefaults.stringArray(forKey: processedMessagesKey) ?? []
        let wasProcessed = processedIds.contains(messageId)
        NSLog("🔍 [NSE Dedup] messageId=\(messageId.prefix(8))... wasProcessedByNSE=\(wasProcessed)")
        result(wasProcessed)

      } else if call.method == "getProcessedByNSE" {
        // Obtener todos los IDs procesados por NSE
        guard let userDefaults = UserDefaults(suiteName: appGroupId) else {
          result([String]())
          return
        }

        let processedIds = userDefaults.stringArray(forKey: processedMessagesKey) ?? []
        result(processedIds)

      } else if call.method == "clearProcessedByNSE" {
        // Limpiar lista de IDs procesados (llamar al iniciar sesión o cuando sea necesario)
        guard let userDefaults = UserDefaults(suiteName: appGroupId) else {
          result(false)
          return
        }

        userDefaults.removeObject(forKey: processedMessagesKey)
        userDefaults.synchronize()
        NSLog("🧹 [NSE Dedup] Lista de IDs procesados limpiada")
        result(true)

      } else if call.method == "getNSEDebugLogs" {
        // Obtener logs de debug del NSE para diagnóstico
        guard let userDefaults = UserDefaults(suiteName: appGroupId) else {
          result([String]())
          return
        }

        let debugLogs = userDefaults.stringArray(forKey: "nse_debug_log") ?? []
        NSLog("📋 [NSE Debug] Returning \(debugLogs.count) debug logs")
        result(debugLogs)

      } else if call.method == "clearNSEDebugLogs" {
        // Limpiar logs de debug
        guard let userDefaults = UserDefaults(suiteName: appGroupId) else {
          result(false)
          return
        }

        userDefaults.removeObject(forKey: "nse_debug_log")
        userDefaults.synchronize()
        NSLog("🧹 [NSE Debug] Logs limpiados")
        result(true)

      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // ✅ REENVIAR token VoIP guardado si existe
    if let pendingToken = self.pendingVoIPToken {
      NSLog("🔄 [VoIP] Reenviando token guardado a Flutter")
      voipChannel.invokeMethod("onVoipToken", arguments: pendingToken)
      NSLog("✅ [VoIP] Token reenviado exitosamente")
    }

    // Manejar llamadas entrantes desde Flutter (fallback cuando VoIP push no funciona)
    callKitChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else { return }

      if call.method == "showIncomingCall" {
        NSLog("📱 [CallKit] Recibido showIncomingCall desde Flutter")

        guard let args = call.arguments as? [String: Any],
              let callId = args["callId"] as? String,
              let callerId = args["callerId"] as? String,
              let callerName = args["callerName"] as? String else {
          NSLog("❌ [CallKit] Args inválidos")
          result(FlutterError(code: "INVALID_ARGS", message: "Missing required args", details: nil))
          return
        }

        let callType = args["callType"] as? String ?? "video"
        let channelName = args["channelName"] as? String ?? callId
        let isEmergency = args["isEmergency"] as? Bool ?? false

        NSLog("📞 [CallKit] Mostrando llamada: \(callerName) (\(callType))")

        // ✅ PHASE 1B: Check for duplicates using reverse mapping and auto-end old ones
        if let existingUUID = self.firestoreIDToCallUUID[callId] {
          NSLog("⚠️ [CallKit] Duplicate call detected for callId \(callId)")
          NSLog("🧹 [CallKit] Auto-ending old CallKit call with UUID: \(existingUUID.uuidString)")

          // End the old CallKit call
          self.callProvider.reportCall(with: existingUUID, endedAt: Date(), reason: .failed)

          // Clean up old mappings
          self.callUUIDToFirestoreID.removeValue(forKey: existingUUID)
          self.firestoreIDToCallUUID.removeValue(forKey: callId)

          NSLog("✅ [CallKit] Old call ended, proceeding with new call")
        }

        // Crear UUID para CallKit
        let uuid = UUID()

        // ✅ PHASE 1B: Save both forward and reverse mappings
        self.callUUIDToFirestoreID[uuid] = callId
        self.firestoreIDToCallUUID[callId] = uuid

        // Crear update de llamada
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = (callType == "video")

        // Reportar llamada entrante a CallKit
        self.callProvider.reportNewIncomingCall(with: uuid, update: update) { error in
          if let error = error {
            NSLog("❌ [CallKit] Error mostrando llamada: \(error.localizedDescription)")
            result(FlutterError(code: "CALLKIT_ERROR", message: error.localizedDescription, details: nil))
          } else {
            NSLog("✅ [CallKit] Llamada mostrada exitosamente")
            result(true)
          }
        }
      } else if call.method == "getActiveCalls" {
        // ✅ PHASE 1B: Return list of active Firestore call IDs
        NSLog("📋 [CallKit] Getting active calls")

        let activeCallIds = Array(self.firestoreIDToCallUUID.keys)
        NSLog("📋 [CallKit] Active call count: \(activeCallIds.count)")

        result(activeCallIds)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    voipChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else { return }

      if call.method == "requestVoIPToken" {
        // ✅ CRITICAL: Force VoIP re-registration to get a fresh token
        NSLog("🔄 [VoIP] Requesting fresh VoIP token...")

        // Re-initialize VoIP registry to trigger token callback
        let voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
        voipRegistry.delegate = self
        voipRegistry.desiredPushTypes = [.voIP]

        // If we already have a pending token, send it immediately
        if let pendingToken = self.pendingVoIPToken {
          NSLog("✅ [VoIP] Sending existing pending token")
          let channel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: (self.window?.rootViewController as! FlutterViewController).binaryMessenger)
          channel.invokeMethod("onVoipToken", arguments: pendingToken)
        }

        result(true)
      } else if call.method == "endCallKit" {
        NSLog("📵 [CallKit] Recibido endCallKit desde Flutter")

        guard let args = call.arguments as? [String: Any],
              let callId = args["callId"] as? String else {
          NSLog("❌ [CallKit] Args inválidos")
          result(FlutterError(code: "INVALID_ARGS", message: "Missing callId", details: nil))
          return
        }

        NSLog("📝 [CallKit] Buscando UUID para callId: \(callId)")

        // Buscar el UUID de CallKit que corresponde a este callId de Firestore
        var foundUUID: UUID? = nil
        for (uuid, firestoreId) in self.callUUIDToFirestoreID {
          if firestoreId == callId {
            foundUUID = uuid
            break
          }
        }

        if let uuid = foundUUID {
          NSLog("📵 [CallKit] Encontrado UUID: \(uuid.uuidString), terminando llamada...")

          // CRÍTICO: Guardar referencia antes de limpiar
          let uuidToEnd = uuid

          // ✅ PHASE 1B: Limpiar AMBOS mappings PRIMERO para evitar re-entrada
          self.callUUIDToFirestoreID.removeValue(forKey: uuid)
          self.firestoreIDToCallUUID.removeValue(forKey: callId)
          NSLog("🧹 [CallKit] Mappings limpiados preventivamente")

          // CRÍTICO: Ejecutar en main thread y con manejo de errores
          DispatchQueue.main.async {
            NSLog("📱 [CallKit] Ejecutando en main thread...")

            // Verificar que callProvider existe
            guard self.callProvider != nil else {
              NSLog("❌ [CallKit] callProvider es nil!")
              return
            }

            do {
              // Reportar a CallKit que la llamada terminó
              NSLog("📞 [CallKit] Llamando reportCall...")
              self.callProvider.reportCall(with: uuidToEnd, endedAt: Date(), reason: .remoteEnded)
              NSLog("✅ [CallKit] Llamada reportada como terminada exitosamente")
            } catch let error as NSError {
              NSLog("⚠️ [CallKit] Error reportando fin de llamada:")
              NSLog("   - Code: \(error.code)")
              NSLog("   - Domain: \(error.domain)")
              NSLog("   - Description: \(error.localizedDescription)")
              NSLog("   - Continuando de todas formas...")
            } catch {
              NSLog("⚠️ [CallKit] Error desconocido: \(error)")
            }
          }

          // Responder inmediatamente sin esperar
          result(true)
        } else {
          // Si no se encontró el UUID, aún así retornar success (puede que ya se haya limpiado)
          NSLog("⚠️ [CallKit] No se encontró UUID para callId: \(callId)")
          NSLog("📋 [CallKit] Mappings actuales: \(self.callUUIDToFirestoreID)")
          result(true)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // ✅ Notification channel para mostrar notificaciones instantáneas
    let notificationChannel = FlutterMethodChannel(name: "com.talia.chat/notifications", binaryMessenger: controller.binaryMessenger)

    notificationChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else { return }

      if call.method == "showCommunicationNotification" {
        NSLog("📬 [Notifications] Recibido showCommunicationNotification desde Flutter")

        guard let args = call.arguments as? [String: Any],
              let senderId = args["senderId"] as? String,
              let senderName = args["senderName"] as? String,
              let messageText = args["messageText"] as? String else {
          NSLog("❌ [Notifications] Args inválidos")
          result(FlutterError(code: "INVALID_ARGS", message: "Missing required args", details: nil))
          return
        }

        let chatId = args["chatId"] as? String ?? senderId
        let isGroup = args["isGroup"] as? Bool ?? false
        let senderPhotoUrl = args["senderPhotoUrl"] as? String

        NSLog("⚡ [Notifications] Mostrando notificación instantánea de: \(senderName)")
        if let photoUrl = senderPhotoUrl, !photoUrl.isEmpty {
          NSLog("📷 [Notifications] URL de foto recibida: \(photoUrl)")
        }

        // Mostrar notificación INMEDIATAMENTE (sin esperar foto)
        self.showInstantNotification(
          senderName: senderName,
          messageText: messageText,
          senderId: senderId,
          chatId: chatId,
          isGroup: isGroup,
          senderPhotoUrl: senderPhotoUrl
        ) { success in
          result(success)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // ✅ FIX #9: Stream Detector health check channel
    let streamDetectorChannel = FlutterMethodChannel(name: "com.talia.chat/stream_detector", binaryMessenger: controller.binaryMessenger)

    streamDetectorChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else { return }

      if call.method == "heartbeat" {
        // Update last heartbeat timestamp
        self.lastStreamDetectorHeartbeat = Date()
        result(true)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Instant Notifications

  /// Cache en memoria para fotos de perfil (mantiene las últimas 50 fotos)
  private static let photoCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 50  // Máximo 50 fotos en cache
    cache.totalCostLimit = 50 * 1024 * 1024  // Máximo 50 MB
    return cache
  }()

  /// Muestra una notificación local instantánea con foto circular usando Communication Notifications
  /// ✅ NUEVA IMPLEMENTACIÓN: Usa INSendMessageIntent para mostrar foto circular del sender
  private func showInstantNotification(
    senderName: String,
    messageText: String,
    senderId: String,
    chatId: String,
    isGroup: Bool,
    senderPhotoUrl: String?,
    completion: @escaping (Bool) -> Void
  ) {
    let content = UNMutableNotificationContent()
    content.title = senderName
    content.body = messageText
    content.sound = .default
    content.badge = 1
    content.threadIdentifier = chatId

    // ✅ CRITICAL: Agregar TODOS los datos necesarios para la navegación
    content.userInfo = [
      "senderId": senderId,
      "senderName": senderName,
      "chatId": chatId,
      "isGroup": isGroup,
      "messagePreview": messageText,
      "groupName": "",  // iOS no tiene este dato en foreground, pero necesitamos el key
      "type": isGroup ? "group_message" : "chat_message",
      "source": "stream_detector"  // ✅ Identificador para distinguir de FCM
    ]

    // ID único para la notificación
    let requestId = UUID().uuidString

    // Función helper para crear y mostrar la notificación
    func createAndShowNotification(image: UIImage?) {
      var finalContent = content

      if let image = image {
        // Crear INPerson con foto
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

        // Crear INSendMessageIntent
        let intent = INSendMessageIntent(
          recipients: nil,
          outgoingMessageType: .outgoingMessageText,
          content: messageText,
          speakableGroupName: isGroup ? INSpeakableString(spokenPhrase: "Grupo") : nil,
          conversationIdentifier: chatId,
          serviceName: nil,
          sender: sender,
          attachments: nil
        )

        // Asignar imagen explícitamente
        intent.setImage(avatar, forParameterNamed: \.sender)

        // Donar interacción
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)

        // Convertir el intent en notification content
        do {
          finalContent = try content.updating(from: intent) as! UNMutableNotificationContent

          // ✅ CRITICAL FIX: Preservar userInfo después de updating(from:)
          // El método updating(from:) crea un nuevo content que NO preserva el userInfo original
          finalContent.userInfo = content.userInfo

          NSLog("✅ [Notifications] Communication Notification creada con foto circular")
          NSLog("✅ [Notifications] UserInfo preservado: \(finalContent.userInfo)")
        } catch {
          NSLog("⚠️ [Notifications] Error creando Communication Notification: \(error.localizedDescription)")
        }
      } else {
        NSLog("ℹ️ [Notifications] Sin foto de sender, mostrando notificación simple")
      }

      // Mostrar notificación (en main thread)
      DispatchQueue.main.async {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: requestId, content: finalContent, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
          if let error = error {
            NSLog("❌ [Notifications] Error agregando notificación: \(error.localizedDescription)")
            completion(false)
          } else {
            NSLog("✅ [Notifications] Notificación mostrada exitosamente")
            completion(true)
          }
        }
      }
    }

    // ✅ SOLUCIÓN: Usar Communication Notifications con foto
    if let photoUrl = senderPhotoUrl, !photoUrl.isEmpty {
      // Caso 1: Archivo local (ya descargado por Flutter)
      if photoUrl.hasPrefix("/") || photoUrl.hasPrefix("file://") {
        NSLog("📂 [Notifications] Usando archivo local: \(photoUrl)")
        let fileUrl = URL(fileURLWithPath: photoUrl)
        
        do {
          let data = try Data(contentsOf: fileUrl)
          if let image = UIImage(data: data) {
            createAndShowNotification(image: image)
            return
          }
        } catch {
          NSLog("❌ [Notifications] Error leyendo archivo local: \(error)")
        }
        // Si falla, mostrar sin foto
        createAndShowNotification(image: nil)
      }
      // Caso 2: URL remota (descargar)
      else if let url = URL(string: photoUrl) {
        NSLog("📥 [Notifications] Descargando foto para Communication Notification...")

        // Timeout de 5 segundos para descarga rápida
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5.0
        let session = URLSession(configuration: config)

        session.dataTask(with: url) { data, response, error in
          if let data = data, let image = UIImage(data: data) {
            NSLog("✅ [Notifications] Foto descargada")
            createAndShowNotification(image: image)
          } else {
            NSLog("⚠️ [Notifications] No se pudo descargar foto, usando notificación simple")
            createAndShowNotification(image: nil)
          }
        }.resume()
      } else {
        // URL inválida
        createAndShowNotification(image: nil)
      }
    } else {
      // Sin foto
      createAndShowNotification(image: nil)
    }
  }

  /// Crea un attachment desde UIImage para la notificación
  private func createNotificationAttachment(from image: UIImage, identifier: String) -> UNNotificationAttachment? {
    guard let imageData = image.jpegData(compressionQuality: 0.8) else { return nil }

    let tempDir = NSTemporaryDirectory()
    let tempFile = tempDir + identifier + ".jpg"
    let tempUrl = URL(fileURLWithPath: tempFile)

    do {
      try imageData.write(to: tempUrl)
      let attachment = try UNNotificationAttachment(identifier: identifier, url: tempUrl, options: nil)
      return attachment
    } catch {
      NSLog("❌ [Notifications] Error creando attachment: \(error.localizedDescription)")
      return nil
    }
  }

  /// Descarga y cachea una foto en background (no bloquea la notificación)
  private func downloadAndCachePhoto(from urlString: String, senderId: String) {
    guard let url = URL(string: urlString) else { return }

    DispatchQueue.global(qos: .background).async {
      NSLog("📥 [Notifications] Descargando foto para cache: \(urlString)")

      // Timeout de 3 segundos
      let config = URLSessionConfiguration.default
      config.timeoutIntervalForRequest = 3.0
      let session = URLSession(configuration: config)

      session.dataTask(with: url) { data, response, error in
        guard let data = data,
              let image = UIImage(data: data) else {
          NSLog("⚠️ [Notifications] No se pudo descargar/procesar foto")
          return
        }

        // Guardar en cache para próximas notificaciones
        AppDelegate.photoCache.setObject(image, forKey: urlString as NSString)
        NSLog("💾 [Notifications] Foto guardada en cache para próximas notificaciones")

        // También guardar con senderId como key alternativa
        AppDelegate.photoCache.setObject(image, forKey: senderId as NSString)
      }.resume()
    }
  }

  override func application(_ application: UIApplication,
                          didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Foundation.Data) {
    Messaging.messaging().apnsToken = deviceToken
  }

  // MARK: - CallKit Setup

  private func setupCallKitProvider() {
    let configuration = CXProviderConfiguration(localizedName: "Talia")
    configuration.supportsVideo = true
    configuration.maximumCallsPerCallGroup = 1
    configuration.supportedHandleTypes = [.generic]

    callProvider = CXProvider(configuration: configuration)
    callProvider.setDelegate(self, queue: nil)
    callController = CXCallController()

    NSLog("✅ [CallKit] Provider initialized")
  }

  // MARK: - VoIP Push Notifications

  func voipRegistration() {
    let voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
    voipRegistry.delegate = self
    voipRegistry.desiredPushTypes = [.voIP]
    NSLog("✅ [VoIP] Registry initialized")
  }

  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    NSLog("📱 [VoIP] ========== TOKEN RECIBIDO ==========")
    let deviceToken = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
    NSLog("📱 [VoIP] Device Token: \(deviceToken)")

    // Register with plugin if available
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(deviceToken)

    // ✅ GUARDAR token temporalmente
    self.pendingVoIPToken = deviceToken
    NSLog("✅ [VoIP] Token guardado temporalmente")

    // Intentar enviar a Flutter (puede fallar si Flutter no está listo)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: controller.binaryMessenger)
      channel.invokeMethod("onVoipToken", arguments: deviceToken)
      NSLog("✅ [VoIP] Token sent to Flutter")
    } else {
      NSLog("⚠️ [VoIP] Flutter no está listo, token se enviará más tarde")
    }
  }

  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
    // ✅ FIX #18: Reduced excessive DEBUG logs
    NSLog("📞 [VoIP] Push received")

    guard type == .voIP else {
      NSLog("❌ [VoIP] Wrong push type")
      completion()
      return
    }

    let payloadDict = payload.dictionaryPayload

    guard let callId = payloadDict["callId"] as? String,
          let callerId = payloadDict["callerId"] as? String,
          let callerName = payloadDict["callerName"] as? String else {
      NSLog("❌ [VoIP] Missing required fields")
      completion()
      return
    }

    let callType = payloadDict["callType"] as? String ?? "UNKNOWN"
    let isVideo = (callType == "video")

    NSLog("📞 [VoIP] CallKit for \(callerName), type: \(callType), callId: \(callId)")

    // ✅ PHASE 1B: Check for duplicates using reverse mapping and auto-end old ones
    if let existingUUID = self.firestoreIDToCallUUID[callId] {
      NSLog("⚠️ [VoIP] Duplicate VoIP push for callId \(callId)")
      NSLog("🧹 [VoIP] Auto-ending old CallKit call with UUID: \(existingUUID.uuidString)")

      // End the old CallKit call
      self.callProvider.reportCall(with: existingUUID, endedAt: Date(), reason: .failed)

      // Clean up old mappings
      self.callUUIDToFirestoreID.removeValue(forKey: existingUUID)
      self.firestoreIDToCallUUID.removeValue(forKey: callId)

      NSLog("✅ [VoIP] Old call ended, proceeding with new VoIP push")
    }

    // Create CallKit call update
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: callerId)
    update.localizedCallerName = callerName
    update.hasVideo = isVideo

    // Generate new UUID for CallKit and store both mappings
    let callUUID = UUID()
    callUUIDToFirestoreID[callUUID] = callId
    firestoreIDToCallUUID[callId] = callUUID // ✅ PHASE 1B: Reverse mapping

    // Report incoming call to CallKit
    callProvider.reportNewIncomingCall(with: callUUID, update: update) { error in
      if let error = error {
        NSLog("❌ [VoIP] CallKit report error: \(error.localizedDescription)")
      } else {
        NSLog("✅ [VoIP] CallKit reported successfully")

        // Notify Flutter about the incoming call
        if let controller = self.window?.rootViewController as? FlutterViewController {
          let channel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: controller.binaryMessenger)
          channel.invokeMethod("onIncomingCall", arguments: payloadDict)
        } else {
          NSLog("❌ [VoIP] No FlutterViewController")
        }
      }
      completion()
    }
  }

  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    NSLog("❌ [VoIP] Token invalidated")
    SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP("")
  }

  // MARK: - CXProviderDelegate

  func providerDidReset(_ provider: CXProvider) {
    NSLog("📱 [CallKit] Provider reset")
  }

  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    // ✅ FIX #18: Reduced excessive DEBUG logs
    NSLog("✅ [CallKit] User answered call")

    // Get Firestore callId from mapping
    guard let firestoreCallId = callUUIDToFirestoreID[action.callUUID] else {
      NSLog("❌ [CallKit] No mapping found for UUID")
      action.fulfill()
      return
    }

    // ✅ FIX VIDEO FROM LOCK SCREEN: Store callId for navigation when audio activates
    // This ensures video calls navigate to the app even when answered from lock screen
    self.pendingVideoCallNavigation = firestoreCallId
    NSLog("📹 [CallKit] Stored pending video call navigation: \(firestoreCallId)")

    // Notify Flutter immediately to start accepting the call
    DispatchQueue.main.async {
      guard let controller = self.window?.rootViewController as? FlutterViewController else {
        NSLog("❌ [CallKit] No FlutterViewController")
        return
      }

      let channel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: controller.binaryMessenger)
      channel.invokeMethod("onCallAccepted", arguments: ["callId": firestoreCallId])
      NSLog("✅ [CallKit] Flutter notified of acceptance")
    }

    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    NSLog("❌ [CallKit] User ended/rejected call")
    NSLog("🔑 [CallKit] UUID: \(action.callUUID.uuidString)")

    // Get Firestore callId from mapping (if exists)
    let firestoreCallId = callUUIDToFirestoreID[action.callUUID] ?? action.callUUID.uuidString

    // ✅ PHASE 1B: Clean up BOTH mappings PRIMERO para evitar doble procesamiento
    callUUIDToFirestoreID.removeValue(forKey: action.callUUID)
    firestoreIDToCallUUID.removeValue(forKey: firestoreCallId)
    NSLog("🧹 [CallKit] Bidirectional mappings limpiados para UUID: \(action.callUUID.uuidString)")

    // Notify Flutter - CRÍTICO: En main thread
    DispatchQueue.main.async {
      if let controller = self.window?.rootViewController as? FlutterViewController {
        let channel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: controller.binaryMessenger)
        channel.invokeMethod("onCallEnded", arguments: ["callId": firestoreCallId])
        NSLog("✅ [CallKit] Flutter notificado del fin de llamada")
      }
    }

    action.fulfill()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    NSLog("📱 [CallKit] Audio session activated")

    // ✅ FIX VIDEO FROM LOCK SCREEN: When audio activates, force navigation to video call screen
    // This is the moment when iOS allows the app to take over from CallKit UI
    if let callId = self.pendingVideoCallNavigation {
      NSLog("📹 [CallKit] Audio active - triggering video navigation for: \(callId)")
      self.pendingVideoCallNavigation = nil // Clear to prevent duplicate navigation

      // Small delay to ensure Flutter engine is ready and app is fully active
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        guard let controller = self.window?.rootViewController as? FlutterViewController else {
          NSLog("❌ [CallKit] No FlutterViewController for video navigation")
          return
        }

        let channel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: controller.binaryMessenger)
        // Send a specific event to force navigation to the video screen
        channel.invokeMethod("onVideoCallReady", arguments: ["callId": callId])
        NSLog("✅ [CallKit] Flutter notified to show video UI for: \(callId)")
      }
    }
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    NSLog("📱 [CallKit] Audio session deactivated")
  }

  // MARK: - UNUserNotificationCenterDelegate

  // Este método se llama cuando llega una notificación mientras la app está en FOREGROUND
  override func userNotificationCenter(_ center: UNUserNotificationCenter,
                                      willPresent notification: UNNotification,
                                      withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    NSLog("📱 [Notifications] willPresent notification in FOREGROUND")
    NSLog("📱 [Notifications] Title: \(notification.request.content.title)")
    NSLog("📱 [Notifications] Body: \(notification.request.content.body)")

    // ✅ ANTI-DUPLICADOS: Suprimir notificaciones FCM de chat en foreground
    // Stream Detector ya las maneja (<100ms con foto del sender)
    let userInfo = notification.request.content.userInfo
    let notificationType = userInfo["type"] as? String
    let notificationSource = userInfo["source"] as? String

    NSLog("📱 [Notifications] Type: \(notificationType ?? "unknown"), Source: \(notificationSource ?? "fcm")")

    // ✅ DEBUG: Notificar a Flutter para logging
    DispatchQueue.main.async {
      if let controller = self.window?.rootViewController as? FlutterViewController {
        let channel = FlutterMethodChannel(name: "com.talia.chat/debug", binaryMessenger: controller.binaryMessenger)
        channel.invokeMethod("onNotificationWillPresent", arguments: [
          "type": notificationType ?? "unknown",
          "source": notificationSource ?? "fcm",
          "title": notification.request.content.title,
          "body": notification.request.content.body
        ])
      }
    }

    // ✅ CRÍTICO: NO suprimir notificaciones locales del Stream Detector
    if notificationSource == "stream_detector" {
      NSLog("✅ [Notifications] Local notification from Stream Detector - showing")
      if #available(iOS 14.0, *) {
        completionHandler([.banner, .sound, .badge])
      } else {
        completionHandler([.alert, .sound, .badge])
      }
    } else if notificationType == "chat_message" || notificationType == "group_message" {
      // Solo suprimir notificaciones FCM remotas (no tienen "source")
      // ✅ FIX #9: Only suppress if Stream Detector is healthy (heartbeat recent)
      if let lastHeartbeat = lastStreamDetectorHeartbeat {
        let timeSinceHeartbeat = Date().timeIntervalSince(lastHeartbeat)
        if timeSinceHeartbeat < streamDetectorTimeout {
          NSLog("⏭️ [Notifications] Stream Detector healthy (\(Int(timeSinceHeartbeat))s ago) - suppressing FCM")
          completionHandler([])  // NO mostrar nada (Stream Detector ya lo mostró)
          return
        } else {
          NSLog("⚠️ [Notifications] Stream Detector unhealthy (last heartbeat \(Int(timeSinceHeartbeat))s ago) - showing notification")
        }
      } else {
        NSLog("⚠️ [Notifications] No Stream Detector heartbeat received - showing notification")
      }
      // Mostrar notificación FCM porque Stream Detector no está saludable
      if #available(iOS 14.0, *) {
        completionHandler([.banner, .sound, .badge])
      } else {
        completionHandler([.alert, .sound, .badge])
      }
    } else {
      // Para otros tipos (llamadas, etc): mostrar normalmente
      if #available(iOS 14.0, *) {
        completionHandler([.banner, .sound, .badge])
        NSLog("✅ [Notifications] Mostrando con banner + sound + badge (iOS 14+)")
      } else {
        completionHandler([.alert, .sound, .badge])
        NSLog("✅ [Notifications] Mostrando con alert + sound + badge (iOS <14)")
      }
    }
  }

  // Este método se llama cuando el usuario toca la notificación
  override func userNotificationCenter(_ center: UNUserNotificationCenter,
                                      didReceive response: UNNotificationResponse,
                                      withCompletionHandler completionHandler: @escaping () -> Void) {
    NSLog("📱 [Notifications] User tapped notification")
    let userInfo = response.notification.request.content.userInfo
    NSLog("📱 [Notifications] UserInfo: \(userInfo)")

    // ✅ CRITICAL FIX: Manejar tap de Communication Notifications manualmente
    // Las Communication Notifications no pasan correctamente el payload a flutter_local_notifications
    // Por eso enviamos los datos directamente a Flutter via method channel

    if let source = userInfo["source"] as? String, source == "stream_detector" {
      NSLog("📱 [Notifications] Tap de Communication Notification detectado - pasando a Flutter manualmente")

      // Extraer datos de navegación
      if let chatId = userInfo["chatId"] as? String,
         let senderId = userInfo["senderId"] as? String,
         let senderName = userInfo["senderName"] as? String,
         let type = userInfo["type"] as? String {

        NSLog("📱 [Notifications] Navegando a chatId: \(chatId), senderId: \(senderId), type: \(type)")

        // Pasar a Flutter via method channel
        DispatchQueue.main.async {
          if let controller = self.window?.rootViewController as? FlutterViewController {
            let channel = FlutterMethodChannel(name: "com.talia.chat/notifications", binaryMessenger: controller.binaryMessenger)

            let payload: [String: Any] = [
              "chatId": chatId,
              "senderId": senderId,
              "senderName": senderName,
              "type": type,
              "isGroup": userInfo["isGroup"] as? Bool ?? false,
              "messagePreview": userInfo["messagePreview"] as? String ?? "",
              "groupName": userInfo["groupName"] as? String ?? ""
            ]

            channel.invokeMethod("onNotificationTapped", arguments: payload)
            NSLog("✅ [Notifications] Datos de navegación enviados a Flutter")
          }
        }
      }

      completionHandler()
      return
    }

    // Para otras notificaciones (FCM, etc), llamar a super normalmente
    NSLog("📱 [Notifications] Notificación regular - usando super.userNotificationCenter")
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }
}
