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

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    FirebaseApp.configure()

    // Configure Google Maps with API key
    GMSServices.provideAPIKey("AIzaSyDmaRq41cBttgeopHCXh1HvtvGSAegwo7E")

    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self as UNUserNotificationCenterDelegate
    }

    GeneratedPluginRegistrant.register(with: self)

    // Registrar plugin de DeepAR
    ArFiltersPlugin.register(with: registrar(forPlugin: "ArFiltersPlugin")!)

    // ✅ Setup CallKit Provider FIRST
    setupCallKitProvider()

    // ✅ Registrar VoIP Push Notifications
    voipRegistration()

    // ✅ Setup Method Channel para recibir notificaciones desde Flutter
    setupMethodChannel()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // MARK: - Method Channel Setup

  private func setupMethodChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return
    }

    let channel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: controller.binaryMessenger)
    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else { return }

      if call.method == "endCallKit" {
        guard let args = call.arguments as? [String: Any],
              let callId = args["callId"] as? String else {
          result(FlutterError(code: "INVALID_ARGS", message: "Missing callId", details: nil))
          return
        }

        // Buscar el UUID de CallKit que corresponde a este callId de Firestore
        for (uuid, firestoreId) in self.callUUIDToFirestoreID {
          if firestoreId == callId {
            NSLog("📵 [CallKit] Terminando llamada en CallKit UI - UUID: \(uuid.uuidString)")

            // Reportar a CallKit que la llamada terminó
            self.callProvider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)

            // Limpiar el mapping
            self.callUUIDToFirestoreID.removeValue(forKey: uuid)

            result(true)
            return
          }
        }

        // Si no se encontró el UUID, aún así retornar success (puede que ya se haya limpiado)
        NSLog("⚠️ [CallKit] No se encontró UUID para callId: \(callId)")
        result(true)
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

    // Send to Flutter
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: controller.binaryMessenger)
      channel.invokeMethod("onVoipToken", arguments: deviceToken)
      NSLog("✅ [VoIP] Token sent to Flutter")
    }
  }

  func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
    NSLog("📱 [VoIP] ========== PUSH RECIBIDO ==========")
    NSLog("📱 [VoIP] Payload: \(payload.dictionaryPayload)")

    guard type == .voIP else {
      NSLog("❌ [VoIP] Wrong type")
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

    let callType = payloadDict["callType"] as? String ?? "video"
    let isVideo = (callType == "video")

    NSLog("✅ [VoIP] Showing CallKit for \(callerName)")
    NSLog("📝 [VoIP] Firestore callId: \(callId)")

    // Create CallKit call update
    let update = CXCallUpdate()
    update.remoteHandle = CXHandle(type: .generic, value: callerId)
    update.localizedCallerName = callerName
    update.hasVideo = isVideo

    // Generate new UUID for CallKit and store mapping to Firestore callId
    let callUUID = UUID()
    callUUIDToFirestoreID[callUUID] = callId
    NSLog("🔑 [VoIP] CallKit UUID: \(callUUID.uuidString) -> Firestore ID: \(callId)")

    // Report incoming call to CallKit
    callProvider.reportNewIncomingCall(with: callUUID, update: update) { error in
      if let error = error {
        NSLog("❌ [VoIP] Error reporting call: \(error.localizedDescription)")
      } else {
        NSLog("✅ [VoIP] Call reported to CallKit successfully")

        // Notify Flutter about the incoming call
        if let controller = self.window?.rootViewController as? FlutterViewController {
          let channel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: controller.binaryMessenger)
          channel.invokeMethod("onIncomingCall", arguments: payloadDict)
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
    NSLog("✅ [CallKit] User answered call")
    NSLog("🔑 [CallKit] UUID: \(action.callUUID.uuidString)")

    // Get Firestore callId from mapping
    guard let firestoreCallId = callUUIDToFirestoreID[action.callUUID] else {
      NSLog("❌ [CallKit] No mapping found for UUID: \(action.callUUID.uuidString)")
      action.fulfill()
      return
    }

    NSLog("📝 [CallKit] Mapped to Firestore callId: \(firestoreCallId)")

    // Notify Flutter with Firestore callId
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: controller.binaryMessenger)
      channel.invokeMethod("onCallAccepted", arguments: ["callId": firestoreCallId])
    }

    action.fulfill()
  }

  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    NSLog("❌ [CallKit] User ended/rejected call")
    NSLog("🔑 [CallKit] UUID: \(action.callUUID.uuidString)")

    // Get Firestore callId from mapping (if exists)
    let firestoreCallId = callUUIDToFirestoreID[action.callUUID] ?? action.callUUID.uuidString

    // Clean up mapping
    callUUIDToFirestoreID.removeValue(forKey: action.callUUID)

    // Notify Flutter
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(name: "com.talia.chat/voip", binaryMessenger: controller.binaryMessenger)
      channel.invokeMethod("onCallEnded", arguments: ["callId": firestoreCallId])
    }

    action.fulfill()
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    NSLog("📱 [CallKit] Audio session activated")
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    NSLog("📱 [CallKit] Audio session deactivated")
  }
}
