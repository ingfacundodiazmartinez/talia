import UIKit
import Flutter
import Firebase
import UserNotifications
import GoogleMaps
import DeepAR
import PushKit
import CallKit
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate, CXProviderDelegate {
  private var callProvider: CXProvider!
  private var callController: CXCallController!
  private var callUUIDToFirestoreID: [UUID: String] = [:] // Mapeo de UUID CallKit -> callId Firestore
  private var pendingVoIPToken: String? = nil // ✅ Guardar token VoIP temporalmente

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

        // ✅ PROTECCIÓN: Verificar si ya existe una llamada con este callId
        for (existingUUID, existingCallId) in self.callUUIDToFirestoreID {
          if existingCallId == callId {
            NSLog("⚠️ [CallKit] Ya existe una llamada con callId \(callId), ignorando duplicado")
            result(FlutterError(code: "DUPLICATE_CALL", message: "Call already exists", details: nil))
            return
          }
        }

        // Crear UUID para CallKit
        let uuid = UUID()

        // Guardar mapping
        self.callUUIDToFirestoreID[uuid] = callId

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
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    voipChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else { return }

      if call.method == "endCallKit" {
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

          // Limpiar mapping PRIMERO para evitar re-entrada
          self.callUUIDToFirestoreID.removeValue(forKey: uuid)
          NSLog("🧹 [CallKit] Mapping limpiado preventivamente")

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
    NSLog("🚨🚨🚨 TALIA_DEBUG: VoIP Push received")
    NSLog("🚨 TALIA_DEBUG: Payload: \(payload.dictionaryPayload)")

    guard type == .voIP else {
      NSLog("🚨 TALIA_DEBUG: ERROR - Wrong push type")
      completion()
      return
    }

    let payloadDict = payload.dictionaryPayload

    guard let callId = payloadDict["callId"] as? String,
          let callerId = payloadDict["callerId"] as? String,
          let callerName = payloadDict["callerName"] as? String else {
      NSLog("🚨 TALIA_DEBUG: ERROR - Missing required fields in payload")
      completion()
      return
    }

    let callType = payloadDict["callType"] as? String ?? "UNKNOWN"
    let isVideo = (callType == "video")

    NSLog("🚨 TALIA_DEBUG: Showing CallKit for caller: \(callerName)")
    NSLog("🚨 TALIA_DEBUG: Firestore callId: \(callId)")
    NSLog("🚨 TALIA_DEBUG: Call type from payload: '\(callType)'")
    NSLog("🚨 TALIA_DEBUG: isVideo calculated as: \(isVideo)")
    NSLog("🚨 TALIA_DEBUG: Raw payload callType value: \(payloadDict["callType"] ?? "NIL")")

    // ✅ PROTECCIÓN: Verificar si ya existe una llamada con este callId
    for (existingUUID, existingCallId) in self.callUUIDToFirestoreID {
      if existingCallId == callId {
        NSLog("⚠️ [VoIP] Ya existe una llamada con callId \(callId), ignorando VoIP push duplicado")
        completion()
        return
      }
    }

    // Create CallKit call update
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: callerId)
    update.localizedCallerName = callerName
    update.hasVideo = isVideo

    // Generate new UUID for CallKit and store mapping to Firestore callId
    let callUUID = UUID()
    callUUIDToFirestoreID[callUUID] = callId
    NSLog("🚨 TALIA_DEBUG: Created mapping - CallKit UUID: \(callUUID.uuidString) -> Firestore ID: \(callId)")

    // Report incoming call to CallKit
    NSLog("🚨 TALIA_DEBUG: Reporting call to CallKit...")
    callProvider.reportNewIncomingCall(with: callUUID, update: update) { error in
      if let error = error {
        NSLog("🚨 TALIA_DEBUG: ERROR reporting call to CallKit: \(error.localizedDescription)")
      } else {
        NSLog("🚨 TALIA_DEBUG: Call reported to CallKit successfully ✅")

        // Notify Flutter about the incoming call
        if let controller = self.window?.rootViewController as? FlutterViewController {
          NSLog("🚨 TALIA_DEBUG: Notifying Flutter about incoming call...")
          let channel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: controller.binaryMessenger)
          channel.invokeMethod("onIncomingCall", arguments: payloadDict)
          NSLog("🚨 TALIA_DEBUG: Flutter notified ✅")
        } else {
          NSLog("🚨 TALIA_DEBUG: ERROR - No FlutterViewController to notify!")
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
    NSLog("🚨🚨🚨 TALIA_DEBUG: User answered call")
    NSLog("🚨 TALIA_DEBUG: UUID: \(action.callUUID.uuidString)")

    // Get Firestore callId from mapping
    guard let firestoreCallId = callUUIDToFirestoreID[action.callUUID] else {
      NSLog("🚨 TALIA_DEBUG: ERROR - No mapping found for UUID: \(action.callUUID.uuidString)")
      NSLog("🚨 TALIA_DEBUG: Available mappings: \(callUUIDToFirestoreID)")
      action.fulfill()
      return
    }

    NSLog("🚨 TALIA_DEBUG: Mapped to Firestore callId: \(firestoreCallId)")

    // Notify Flutter with Firestore callId - con delay para asegurar que Flutter esté listo
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      if let controller = self.window?.rootViewController as? FlutterViewController {
        NSLog("🚨 TALIA_DEBUG: Sending to Flutter...")
        let channel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: controller.binaryMessenger)
        channel.invokeMethod("onCallAccepted", arguments: ["callId": firestoreCallId])
        NSLog("🚨 TALIA_DEBUG: Sent to Flutter successfully")
      } else {
        NSLog("🚨 TALIA_DEBUG: ERROR - No FlutterViewController found! Retrying...")
        // Reintentar después de otro segundo
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          if let controller = self.window?.rootViewController as? FlutterViewController {
            NSLog("🚨 TALIA_DEBUG: Retry successful, sending to Flutter...")
            let channel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: controller.binaryMessenger)
            channel.invokeMethod("onCallAccepted", arguments: ["callId": firestoreCallId])
            NSLog("🚨 TALIA_DEBUG: Sent to Flutter successfully on retry")
          } else {
            NSLog("🚨 TALIA_DEBUG: ERROR - Flutter still not available after retry")
          }
        }
      }
    }

    NSLog("🚨 TALIA_DEBUG: Fulfilling action...")
    action.fulfill()
    NSLog("🚨 TALIA_DEBUG: Action fulfilled ✅")
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    NSLog("❌ [CallKit] User ended/rejected call")
    NSLog("🔑 [CallKit] UUID: \(action.callUUID.uuidString)")

    // Get Firestore callId from mapping (if exists)
    let firestoreCallId = callUUIDToFirestoreID[action.callUUID] ?? action.callUUID.uuidString

    // Clean up mapping PRIMERO para evitar doble procesamiento
    callUUIDToFirestoreID.removeValue(forKey: action.callUUID)
    NSLog("🧹 [CallKit] Mapping limpiado para UUID: \(action.callUUID.uuidString)")

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

    // IMPORTANTE: Llamar a super para que Flutter también reciba la notificación
    super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
  }

  // Este método se llama cuando el usuario toca la notificación
  override func userNotificationCenter(_ center: UNUserNotificationCenter,
                                      didReceive response: UNNotificationResponse,
                                      withCompletionHandler completionHandler: @escaping () -> Void) {
    NSLog("📱 [Notifications] User tapped notification")
    NSLog("📱 [Notifications] UserInfo: \(response.notification.request.content.userInfo)")

    // IMPORTANTE: Llamar a super para que Flutter maneje la navegación
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }
}
