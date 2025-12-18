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
        // ✅ FIX: Also pass photoUrl for cache invalidation
        let photoUrl = args["photoUrl"] as? String
        TaliaPhotoCache.savePhotoData(userId: userId, data: data, photoUrl: photoUrl)
        NSLog("✅ [PhotoCache] Saved photo to App Group for: \(userId) (\(data.count) bytes, url: \(photoUrl?.prefix(30) ?? "nil")...)")
        result(true)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // ✅ NSE Deduplication channel para verificar si messageId ya fue procesado por NSE o Background Handler
    // IMPORTANTE: Usa archivos compartidos via FileManager (más confiable que UserDefaults para NSE)
    let nseDeduplicationChannel = FlutterMethodChannel(name: "com.talia.chat/nse_deduplication", binaryMessenger: controller.binaryMessenger)
    nseDeduplicationChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      let appGroupId = "group.com.talia.chat"
      let processedIdsFileName = "nse_processed_ids.json"
      let backgroundIdsFileName = "background_processed_ids.json"  // ✅ NEW: IDs del background handler
      let debugLogFileName = "nse_debug_log.json"

      // Helper para obtener la URL del container compartido
      func getSharedContainerURL() -> URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
      }

      // Helper para leer array de strings desde archivo JSON
      func readStringArray(from fileName: String) -> [String] {
        guard let containerURL = getSharedContainerURL() else { return [] }
        let fileURL = containerURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
          return []
        }
        return decoded
      }

      // Helper para escribir array de strings a archivo JSON
      func writeStringArray(_ array: [String], to fileName: String) -> Bool {
        guard let containerURL = getSharedContainerURL() else { return false }
        let fileURL = containerURL.appendingPathComponent(fileName)
        do {
          let data = try JSONEncoder().encode(array)
          try data.write(to: fileURL, options: .atomic)
          return true
        } catch {
          NSLog("❌ [NSE Dedup] Error escribiendo archivo: \(error.localizedDescription)")
          return false
        }
      }

      if call.method == "wasProcessedByNSE" {
        // Verificar si un messageId ya fue procesado por el NSE O el Background Handler
        guard let messageId = call.arguments as? String else {
          result(false)
          return
        }

        // ✅ Verificar ambos archivos: NSE y Background Handler
        let nseProcessedIds = readStringArray(from: processedIdsFileName)
        let backgroundProcessedIds = readStringArray(from: backgroundIdsFileName)

        let wasProcessedByNSE = nseProcessedIds.contains(messageId)
        let wasProcessedByBackground = backgroundProcessedIds.contains(messageId)
        let wasProcessed = wasProcessedByNSE || wasProcessedByBackground

        NSLog("🔍 [NSE Dedup] messageId=\(messageId.prefix(8))... NSE=\(wasProcessedByNSE), Background=\(wasProcessedByBackground), Final=\(wasProcessed)")
        result(wasProcessed)

      } else if call.method == "getProcessedByNSE" {
        // Obtener todos los IDs procesados por NSE
        let processedIds = readStringArray(from: processedIdsFileName)
        NSLog("📋 [NSE Dedup] Returning \(processedIds.count) processed IDs (file-based)")
        result(processedIds)

      } else if call.method == "clearProcessedByNSE" {
        // Limpiar lista de IDs procesados
        guard let containerURL = getSharedContainerURL() else {
          result(false)
          return
        }
        let fileURL = containerURL.appendingPathComponent(processedIdsFileName)
        do {
          try FileManager.default.removeItem(at: fileURL)
          NSLog("🧹 [NSE Dedup] Archivo de IDs procesados eliminado")
          result(true)
        } catch {
          // Si no existe el archivo, también es éxito
          NSLog("🧹 [NSE Dedup] Lista limpiada (archivo no existía o eliminado)")
          result(true)
        }

      } else if call.method == "getNSEDebugLogs" {
        // Obtener logs de debug del NSE para diagnóstico
        let debugLogs = readStringArray(from: debugLogFileName)
        NSLog("📋 [NSE Debug] Returning \(debugLogs.count) debug logs (file-based)")
        result(debugLogs)

      } else if call.method == "clearNSEDebugLogs" {
        // Limpiar logs de debug
        guard let containerURL = getSharedContainerURL() else {
          result(false)
          return
        }
        let fileURL = containerURL.appendingPathComponent(debugLogFileName)
        do {
          try FileManager.default.removeItem(at: fileURL)
          NSLog("🧹 [NSE Debug] Archivo de logs eliminado")
          result(true)
        } catch {
          NSLog("🧹 [NSE Debug] Logs limpiados (archivo no existía o eliminado)")
          result(true)
        }

      } else if call.method == "saveMessageIdForDeduplication" {
        // ✅ NUEVO: StreamDetector guarda messageId ANTES de mostrar notificación
        // Así cuando el NSE reciba el mismo mensaje, lo suprimirá
        guard let messageId = call.arguments as? String else {
          NSLog("❌ [NSE Dedup] saveMessageIdForDeduplication: messageId requerido")
          result(false)
          return
        }

        // ✅ MÉTODO 1: UserDefaults con App Group (más confiable para NSE)
        if let sharedDefaults = UserDefaults(suiteName: appGroupId) {
          let key = "processed_\(messageId)"
          sharedDefaults.set(true, forKey: key)
          sharedDefaults.synchronize()  // Forzar sincronización inmediata
          NSLog("✅ [NSE Dedup] messageId guardado en UserDefaults: \(messageId.prefix(8))...")
        }

        // ✅ MÉTODO 2: También guardar en archivo (backup)
        var processedIds = readStringArray(from: processedIdsFileName)
        if !processedIds.contains(messageId) {
          processedIds.append(messageId)
          if processedIds.count > 100 {
            processedIds = Array(processedIds.suffix(100))
          }
          let _ = writeStringArray(processedIds, to: processedIdsFileName)
        }

        result(true)

      } else if call.method == "setAppInForeground" {
        // ✅ NUEVO: Guardar estado foreground/background en App Group
        // NSE lee esto para saber si debe mostrar notificación o no
        guard let isInForeground = call.arguments as? Bool else {
          NSLog("❌ [NSE Dedup] setAppInForeground: bool requerido")
          result(false)
          return
        }

        guard let containerURL = getSharedContainerURL() else {
          result(false)
          return
        }

        let fileURL = containerURL.appendingPathComponent("app_in_foreground.txt")
        do {
          try (isInForeground ? "1" : "0").write(to: fileURL, atomically: true, encoding: .utf8)
          NSLog("✅ [NSE Dedup] App foreground state guardado: \(isInForeground)")
          result(true)
        } catch {
          NSLog("❌ [NSE Dedup] Error guardando foreground state: \(error)")
          result(false)
        }

      } else if call.method == "getNSELastInvoked" {
        // ✅ DEBUG: Verificar si NSE fue invocado (lee timestamp guardado por NSE)
        if let sharedDefaults = UserDefaults(suiteName: appGroupId) {
          let lastInvoked = sharedDefaults.string(forKey: "nse_last_invoked")
          NSLog("🔍 [NSE Debug] Último NSE invocado: \(lastInvoked ?? "never")")
          result(lastInvoked)
        } else {
          result(nil)
        }

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

        // ✅ FIX: Always send existing token if available (even if same)
        // Flutter will save it with updated timestamp
        if let pendingToken = self.pendingVoIPToken {
          NSLog("✅ [VoIP] Sending existing pending token: \(pendingToken.prefix(20))...")

          // Use async to ensure Flutter channel is ready
          DispatchQueue.main.async {
            guard let controller = self.window?.rootViewController as? FlutterViewController else {
              NSLog("❌ [VoIP] FlutterViewController not available")
              return
            }
            let channel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: controller.binaryMessenger)
            channel.invokeMethod("onVoipToken", arguments: pendingToken)
            NSLog("✅ [VoIP] Token sent to Flutter")
          }
        } else {
          NSLog("⚠️ [VoIP] No pending token available - waiting for iOS callback")
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

          // ✅ FIX: NO limpiar mappings aquí - dejar que performEndCallAction lo haga
          // Los mappings se limpiarán automáticamente cuando CallKit ejecute el delegate

          // CRÍTICO: Ejecutar en main thread y con manejo de errores
          DispatchQueue.main.async {
            NSLog("📱 [CallKit] Ejecutando en main thread...")

            // ✅ FIX: Usar CXEndCallAction para terminar la llamada apropiadamente
            // reportCall() solo reporta que terminó remotamente, pero NO cierra el indicador de llamada activa
            // CXEndCallAction es la forma correcta de terminar una llamada desde la app
            let endCallAction = CXEndCallAction(call: uuidToEnd)
            let transaction = CXTransaction(action: endCallAction)

            NSLog("📞 [CallKit] Solicitando fin de llamada via CXCallController...")
            self.callController.request(transaction) { error in
              if let error = error {
                NSLog("⚠️ [CallKit] Error solicitando fin de llamada: \(error.localizedDescription)")
                // Fallback: Si CXCallController falla, intentar reportCall como antes
                NSLog("📞 [CallKit] Fallback: usando reportCall...")
                self.callProvider.reportCall(with: uuidToEnd, endedAt: Date(), reason: .remoteEnded)
              } else {
                NSLog("✅ [CallKit] Llamada terminada exitosamente via CXCallController")
              }
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
        let playSound = args["playSound"] as? Bool ?? true // ✅ FIX #8: Obtener preferencia de sonido

        NSLog("⚡ [Notifications] Mostrando notificación instantánea de: \(senderName), playSound: \(playSound)")
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
          senderPhotoUrl: senderPhotoUrl,
          playSound: playSound // ✅ FIX #8: Pasar preferencia de sonido
        ) { success in
          result(success)
        }

      } else if call.method == "removeAllDeliveredNotifications" {
        // ✅ Remover TODAS las notificaciones del centro de notificaciones
        NSLog("🧹 [Notifications] Removiendo TODAS las notificaciones...")

        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()

        NSLog("✅ [Notifications] Todas las notificaciones removidas")
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
    playSound: Bool = true, // ✅ FIX #8: Parámetro para controlar sonido
    completion: @escaping (Bool) -> Void
  ) {
    let content = UNMutableNotificationContent()
    content.title = senderName
    content.body = messageText
    // ✅ FIX #8: Solo reproducir sonido si está habilitado en preferencias
    content.sound = playSound ? .default : nil
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
        // ✅ FIX: Usar 0.3s en lugar de 0.1s para más estabilidad
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.3, repeats: false)
        let request = UNNotificationRequest(identifier: requestId, content: finalContent, trigger: trigger)

        NSLog("📤 [Notifications] Agregando notificación local: \(senderName) - \(messageText)")
        NSLog("📤 [Notifications] Source: stream_detector, chatId: \(chatId)")

        UNUserNotificationCenter.current().add(request) { error in
          if let error = error {
            NSLog("❌ [Notifications] Error agregando notificación: \(error.localizedDescription)")
            completion(false)
          } else {
            NSLog("✅ [Notifications] Notificación agregada al centro - esperando 0.3s para mostrar")
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

    // ✅ FIX: Handle call_cancelled push to close CallKit
    if let pushType = payloadDict["type"] as? String, pushType == "call_cancelled" {
      NSLog("📵 [VoIP] Call cancelled push received")
      if let callId = payloadDict["callId"] as? String {
        NSLog("📵 [VoIP] Closing CallKit for cancelled call: \(callId)")

        // Find and end the CallKit call
        if let existingUUID = self.firestoreIDToCallUUID[callId] {
          NSLog("📵 [VoIP] Found UUID for callId \(callId): \(existingUUID.uuidString)")
          self.callProvider.reportCall(with: existingUUID, endedAt: Date(), reason: .remoteEnded)

          // Clean up mappings
          self.callUUIDToFirestoreID.removeValue(forKey: existingUUID)
          self.firestoreIDToCallUUID.removeValue(forKey: callId)

          NSLog("✅ [VoIP] CallKit closed for cancelled call \(callId)")
        } else {
          NSLog("⚠️ [VoIP] No UUID found for cancelled callId: \(callId)")
        }

        // Notify Flutter about cancellation
        DispatchQueue.main.async {
          if let controller = self.window?.rootViewController as? FlutterViewController {
            let channel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: controller.binaryMessenger)
            channel.invokeMethod("onCallCancelled", arguments: ["callId": callId])
          }
        }
      }
      completion()
      return
    }

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
      NSLog("✅ [Notifications] Local notification from Stream Detector - showing banner only (no persistence)")
      if #available(iOS 14.0, *) {
        // ✅ NO usar .list - solo banner temporal que no persiste
        completionHandler([.banner, .sound, .badge])
      } else {
        completionHandler([.alert, .sound, .badge])
      }
      return  // ✅ FIX: Salir inmediatamente después de mostrar
    }

    // ✅ FOREGROUND: SIEMPRE suprimir notificaciones FCM de chat
    // StreamDetector ya las maneja (~100ms) - FCM llega 2-5 segundos después
    // No necesitamos heartbeat - si estamos en foreground, StreamDetector está activo
    if notificationType == "chat_message" || notificationType == "group_message" {
      NSLog("⏭️ [Notifications] FOREGROUND - Suprimiendo FCM chat (StreamDetector ya lo mostró)")
      completionHandler([])  // NO mostrar nada
      return
    }

    // Para otros tipos de notificación (llamadas, etc): mostrar normalmente
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .sound, .badge])
      NSLog("✅ [Notifications] Mostrando banner temporal (sin persistencia)")
    } else {
      completionHandler([.alert, .sound, .badge])
      NSLog("✅ [Notifications] Mostrando alert temporal (iOS <14)")
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
