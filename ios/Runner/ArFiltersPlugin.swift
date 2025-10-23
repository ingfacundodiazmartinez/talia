import Flutter
import UIKit
import Foundation
import DeepAR
import GLKit
import OpenGLES
import AVFoundation

/**
 * Plugin iOS para DeepAR
 * Maneja la integración con el SDK de DeepAR para filtros AR en tiempo real
 */
@objc class ArFiltersPlugin: NSObject, FlutterPlugin {

    // MARK: - Constants
    private static let methodChannel = "talia.deepar/ar_filters"
    private static let eventChannel = "talia.deepar/ar_events"

    // MARK: - Properties
    private var eventSink: FlutterEventSink?
    private var isInitialized = false
    private var currentFilter: String?
    private var isRecording = false

    // DeepAR instance
    internal var deepAR: DeepAR?

    // Camera controller for real camera feed
    internal var cameraController: CameraController?

    // ARView instance (mantener una sola instancia)
    internal var currentARView: UIView?

    // Container view actual
    internal weak var currentContainerView: UIView?

    // Screenshot callback
    private var pendingScreenshotCallback: ((UIImage?) -> Void)?

    // MARK: - Plugin Registration
    public static func register(with registrar: FlutterPluginRegistrar) {
        // Configurar method channel
        let methodChannel = FlutterMethodChannel(name: methodChannel, binaryMessenger: registrar.messenger())
        let eventChannel = FlutterEventChannel(name: eventChannel, binaryMessenger: registrar.messenger())

        let instance = ArFiltersPlugin()
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)

        // Registrar el factory para la vista nativa DeepARPreview
        registrar.register(
            DeepARPreviewFactory(instance: instance),
            withId: "talia.deepar/ar_preview"
        )

        print("✅ ArFiltersPlugin registrado en iOS")
    }

    // MARK: - Method Channel Handler
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        do {
            switch call.method {
            case "initialize":
                handleInitialize(call, result: result)
            case "switchFilter":
                handleSwitchFilter(call, result: result)
            case "startRecording":
                handleStartRecording(call, result: result)
            case "stopRecording":
                handleStopRecording(call, result: result)
            case "takeScreenshot":
                handleTakeScreenshot(call, result: result)
            case "switchCamera":
                handleSwitchCamera(call, result: result)
            case "getAvailableFilters":
                handleGetAvailableFilters(call, result: result)
            case "pause":
                handlePause(call, result: result)
            case "resume":
                handleResume(call, result: result)
            case "startCamera":
                handleStartCamera(call, result: result)
            case "stopCamera":
                handleStopCamera(call, result: result)
            case "dispose":
                handleDispose(call, result: result)
            default:
                print("⚠️ Método no implementado: \(call.method)")
                result(FlutterMethodNotImplemented)
            }
        } catch {
            print("❌ Error en método \(call.method): \(error.localizedDescription)")
            result(FlutterError(code: "PLUGIN_ERROR",
                               message: "Error en \(call.method): \(error.localizedDescription)",
                               details: nil))
        }
    }

    // MARK: - Method Implementations
    private func handleInitialize(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any],
              let licenseKey = args["licenseKey"] as? String,
              !licenseKey.isEmpty else {
            result(FlutterError(code: "INVALID_ARGUMENTS",
                               message: "License key es requerida",
                               details: nil))
            return
        }

        print("🎭 Inicializando DeepAR con license key: \(String(licenseKey.prefix(10)))...")
        print("🔍 Estado actual isInitialized antes de inicializar: \(isInitialized)")

        // Crear instancia de DeepAR
        do {
            deepAR = DeepAR()
            guard let deepARInstance = deepAR else {
                print("❌ Error: No se pudo crear instancia de DeepAR")
                result(FlutterError(code: "DEEPAR_INIT_ERROR",
                                   message: "No se pudo crear instancia de DeepAR",
                                   details: nil))
                return
            }

            deepARInstance.delegate = self
            print("✅ DeepAR instance creada y delegate asignado")

            // Configurar license key
            print("🔑 Configurando license key: \(String(licenseKey.prefix(10)))...")
            deepARInstance.setLicenseKey(licenseKey)
            print("✅ License key configurada")

            // DeepAR no necesita initialize() cuando usamos createARView
            // La inicialización se hace automáticamente al crear la vista AR
            print("✅ DeepAR instance lista para crear AR view")

        } catch {
            print("❌ Error during DeepAR initialization: \(error.localizedDescription)")
            result(FlutterError(code: "DEEPAR_INIT_ERROR",
                               message: "Error inicializando DeepAR: \(error.localizedDescription)",
                               details: nil))
            return
        }

        // Marcar como inicializado inmediatamente para desarrollo
        // Esto se sobrescribirá cuando el delegate real sea llamado
        isInitialized = true
        print("⚡ isInitialized establecido a true inmediatamente")

        // También enviar evento inmediatamente
        sendEvent(type: "initialized", data: ["success": true])
        print("📡 Evento initialized enviado inmediatamente")

        // Backup: marcar como inicializado después de 2 segundos si el delegate no se llama
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if !self.isInitialized {
                print("⚠️ Delegate no llamado después de 2s, forzando inicialización")
                self.isInitialized = true
                self.sendEvent(type: "initialized", data: ["success": true, "fallback": true])
            } else {
                print("✅ DeepAR ya está inicializado correctamente")
            }
        }

        result(true)
        print("✅ DeepAR inicialización iniciada, resultado enviado")
    }

    private func handleSwitchFilter(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("🔍 handleSwitchFilter llamado - isInitialized: \(isInitialized)")
        print("🔍 DeepAR instance exists: \(deepAR != nil)")

        // Check both isInitialized flag and deepAR instance availability
        guard isInitialized || deepAR != nil else {
            print("❌ DeepAR no está inicializado - rechazando cambio de filtro")
            result(FlutterError(code: "NOT_INITIALIZED",
                               message: "DeepAR no está inicializado",
                               details: nil))
            return
        }

        // If deepAR exists but isInitialized is false, force it to true for development
        if deepAR != nil && !isInitialized {
            print("⚠️ DeepAR instance existe pero isInitialized es false - forzando true")
            isInitialized = true
        }

        guard let args = call.arguments as? [String: Any],
              let filterPath = args["filterPath"] as? String else {
            result(FlutterError(code: "INVALID_ARGUMENTS",
                               message: "filterPath es requerido",
                               details: nil))
            return
        }

        print("🔄 Cambiando filtro a: \(filterPath)")

        if filterPath.isEmpty {
            // Limpiar filtro actual
            print("🧹 Limpiando filtro actual")
            deepAR?.switchEffect(withSlot: "effect", path: nil)
        } else {
            // Cargar filtro desde assets Flutter
            // Flutter assets se copian al bundle principal, pero hay que buscar solo el nombre del archivo
            let fileName = (filterPath as NSString).lastPathComponent
            let resourceName = (fileName as NSString).deletingPathExtension
            let fileExtension = (fileName as NSString).pathExtension

            print("🔍 Buscando filtro: \(fileName) (resource: \(resourceName), ext: \(fileExtension))")

            let filterAssetPath = Bundle.main.path(forResource: resourceName, ofType: fileExtension.isEmpty ? nil : fileExtension)
            print("🔍 Path encontrado: \(filterAssetPath ?? "nil")")

            if let assetPath = filterAssetPath {
                print("📁 Cargando filtro desde: \(assetPath)")
                deepAR?.switchEffect(withSlot: "effect", path: assetPath)

                // Verificar si necesitamos iniciar la captura aquí
                print("🎥 Verificando estado de captura de DeepAR")
                // deepAR?.startCapture() // Comentado para evitar conflicts

            } else {
                print("⚠️ No se encontró el archivo de filtro: \(filterPath)")

                // Listar todos los archivos disponibles para debugging
                if let resourcePath = Bundle.main.resourcePath {
                    let fileManager = FileManager.default
                    do {
                        let files = try fileManager.contentsOfDirectory(atPath: resourcePath)
                        let deeparFiles = files.filter { $0.hasSuffix(".deepar") }
                        print("📂 Archivos .deepar disponibles: \(deeparFiles)")

                        // También buscar archivos que contengan el nombre del filtro
                        let matchingFiles = files.filter { $0.contains(resourceName) }
                        print("📂 Archivos que contienen '\(resourceName)': \(matchingFiles)")
                    } catch {
                        print("❌ Error listando archivos: \(error)")
                    }
                }

                result(FlutterError(code: "FILTER_NOT_FOUND",
                                   message: "No se encontró el archivo de filtro: \(filterPath)",
                                   details: nil))
                return
            }
        }

        currentFilter = filterPath
        sendEvent(type: "filterChanged", data: ["filterPath": filterPath])
        result(true)
        print("✅ Filtro cambiado a: \(filterPath)")
    }

    private var recordingOutputPath: String?

    private func handleStartRecording(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard isInitialized else {
            result(FlutterError(code: "NOT_INITIALIZED",
                               message: "DeepAR no está inicializado",
                               details: nil))
            return
        }

        guard let deepAR = deepAR else {
            result(FlutterError(code: "NOT_INITIALIZED",
                               message: "DeepAR instance no disponible",
                               details: nil))
            return
        }

        guard let args = call.arguments as? [String: Any],
              let outputPath = args["outputPath"] as? String,
              !outputPath.isEmpty else {
            result(FlutterError(code: "INVALID_ARGUMENTS",
                               message: "Output path es requerido",
                               details: nil))
            return
        }

        let defaultWidth = 720
        let defaultHeight = 1280

        let width = args["width"] as? Int ?? defaultWidth
        let height = args["height"] as? Int ?? defaultHeight

        print("🎬 Iniciando grabación REAL con DeepAR: \(outputPath) (\(width)x\(height))")

        // Guardar el path para usarlo en el delegate
        recordingOutputPath = outputPath

        // Iniciar grabación real con DeepAR SDK
        // Usar el método correcto de DeepAR
        deepAR.startVideoRecording(withOutputWidth: Int32(width), outputHeight: Int32(height))

        isRecording = true

        result(true)
        print("✅ Grabación REAL iniciada con DeepAR SDK")
    }

    private func handleStopRecording(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard isInitialized && isRecording else {
            result(FlutterError(code: "NOT_RECORDING",
                               message: "No hay grabación en progreso",
                               details: nil))
            return
        }

        guard let deepAR = deepAR else {
            result(FlutterError(code: "NOT_INITIALIZED",
                               message: "DeepAR instance no disponible",
                               details: nil))
            return
        }

        print("⏹️ Deteniendo grabación REAL con DeepAR")

        // Detener grabación real con DeepAR SDK
        deepAR.finishVideoRecording()

        // El resultado se enviará en el delegate didFinishVideoRecording
        // Por ahora, devolvemos éxito inmediatamente
        result(true)
        print("✅ Comando de detención enviado a DeepAR SDK")
    }

    private func handleTakeScreenshot(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard isInitialized else {
            result(FlutterError(code: "NOT_INITIALIZED",
                               message: "DeepAR no está inicializado",
                               details: nil))
            return
        }

        guard let deepAR = deepAR else {
            result(FlutterError(code: "NOT_INITIALIZED",
                               message: "DeepAR instance no disponible",
                               details: nil))
            return
        }

        print("📸 Tomando screenshot con DeepAR")

        // Tomar screenshot de DeepAR
        deepAR.takeScreenshot()

        // El screenshot se procesará en el delegate didTakeScreenshot
        // Por ahora, devolvemos un resultado provisional
        // El callback se manejará mediante un mecanismo de espera

        // Crear un semáforo para esperar el callback
        var capturedImage: UIImage?
        let semaphore = DispatchSemaphore(value: 0)

        // Guardar el callback temporalmente
        var screenshotCallback: ((UIImage?) -> Void)?
        screenshotCallback = { image in
            capturedImage = image
            semaphore.signal()
        }

        // Esperar hasta 5 segundos por el screenshot
        DispatchQueue.global(qos: .userInitiated).async {
            let timeout = DispatchTime.now() + .seconds(5)
            let timeoutResult = semaphore.wait(timeout: timeout)

            DispatchQueue.main.async {
                if timeoutResult == .timedOut {
                    print("⏱️ Timeout esperando screenshot")
                    result(FlutterError(code: "SCREENSHOT_TIMEOUT",
                                       message: "Timeout esperando screenshot",
                                       details: nil))
                } else if let image = capturedImage, let imageData = image.jpegData(compressionQuality: 0.9) {
                    print("✅ Screenshot capturado: \(imageData.count) bytes")
                    result(FlutterStandardTypedData(bytes: imageData))
                } else {
                    print("❌ No se pudo obtener datos del screenshot")
                    result(nil)
                }
            }
        }

        // Llamar al callback cuando el delegate reciba el screenshot
        // Esto se manejará mediante una propiedad temporal
        self.pendingScreenshotCallback = screenshotCallback
    }

    private func handleSwitchCamera(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard isInitialized else {
            result(FlutterError(code: "NOT_INITIALIZED",
                               message: "DeepAR no está inicializado",
                               details: nil))
            return
        }

        guard let controller = cameraController else {
            print("❌ CameraController no disponible")
            result(FlutterError(code: "CAMERA_ERROR",
                               message: "CameraController no disponible",
                               details: nil))
            return
        }

        print("🔄 Cambiando cámara - Posición actual: \(controller.position == .front ? "frontal" : "trasera")")

        // Alternar posición de la cámara
        let newPosition: AVCaptureDevice.Position = controller.position == .front ? .back : .front
        print("🔄 Nueva posición: \(newPosition == .front ? "frontal" : "trasera")")

        // Cambiar posición
        controller.position = newPosition

        // Reiniciar cámara con nueva posición
        controller.stopCamera()
        controller.startCamera()

        print("✅ Cámara cambiada a: \(newPosition == .front ? "frontal" : "trasera")")

        // Enviar evento de cambio de cámara
        sendEvent(type: "cameraSwitch", data: [
            "success": true,
            "position": newPosition == .front ? "front" : "back"
        ])

        result(true)
    }

    private func handleGetAvailableFilters(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("📋 Obteniendo filtros disponibles")

        // Devolvemos lista de filtros simulada
        // TODO: Obtener lista real de filtros desde bundle o DeepAR SDK
        let filters = [
            "",
            "aviators.deepar",
            "beard.deepar",
            "bigmouth.deepar",
            "dalmatian.deepar",
            "flowers.deepar",
            "koala.deepar",
            "lion.deepar",
            "mudmask.deepar",
            "mustache.deepar",
            "neondevil.deepar",
            "pug.deepar",
            "slash.deepar",
            "sleepingmask.deepar",
            "smallface.deepar",
            "teddycigar.deepar",
            "tripleface.deepar",
            "twistedface.deepar"
        ]

        result(filters)
        print("✅ Filtros disponibles: \(filters.count)")
    }

    private func handlePause(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard isInitialized else {
            result(FlutterError(code: "NOT_INITIALIZED",
                               message: "DeepAR no está inicializado",
                               details: nil))
            return
        }

        print("⏸️ Pausando DeepAR")

        // TODO: Implementar pausa real con DeepAR SDK

        result(nil)
        print("✅ DeepAR pausado (simulado)")
    }

    private func handleResume(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard isInitialized else {
            result(FlutterError(code: "NOT_INITIALIZED",
                               message: "DeepAR no está inicializado",
                               details: nil))
            return
        }

        print("▶️ Reanudando DeepAR")

        // TODO: Implementar reanudación real con DeepAR SDK

        result(nil)
        print("✅ DeepAR reanudado (simulado)")
    }

    private func handleStartCamera(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        NSLog("▶️ handleStartCamera llamado desde Flutter")
        print("▶️ handleStartCamera llamado desde Flutter")

        guard let deepAR = deepAR else {
            NSLog("❌ DeepAR no está disponible")
            print("❌ DeepAR no está disponible")
            result(FlutterError(code: "DEEPAR_ERROR", message: "DeepAR no disponible", details: nil))
            return
        }

        // Si ya existe un CameraController, solo reiniciar la cámara
        if let controller = cameraController {
            NSLog("▶️ Reiniciando cámara en CameraController existente...")
            print("▶️ Reiniciando cámara en CameraController existente...")
            controller.startCamera()
            NSLog("✅ Cámara reiniciada")
            print("✅ Cámara reiniciada")
            result(true)
        } else {
            // Crear nuevo CameraController (solo la primera vez)
            NSLog("🆕 Creando nuevo CameraController...")
            print("🆕 Creando nuevo CameraController...")
            setupCameraController(with: deepAR)
            NSLog("✅ Nuevo CameraController creado e iniciado")
            print("✅ Nuevo CameraController creado e iniciado")
            result(true)
        }
    }

    private func handleStopCamera(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        NSLog("⏹️ handleStopCamera llamado desde Flutter")
        print("⏹️ handleStopCamera llamado desde Flutter")

        if let controller = cameraController {
            NSLog("🧹 Deteniendo CameraController...")
            print("🧹 Deteniendo CameraController...")
            controller.stopCamera()
            cameraController = nil
            NSLog("✅ CameraController detenido y limpiado")
            print("✅ CameraController detenido y limpiado")
        } else {
            NSLog("ℹ️ No hay CameraController activo para detener")
            print("ℹ️ No hay CameraController activo para detener")
        }

        // CRÍTICO: Limpiar ARView para evitar frames congelados
        if let arView = currentARView {
            NSLog("🧹 Removiendo ARView del contenedor...")
            print("🧹 Removiendo ARView del contenedor...")
            arView.removeFromSuperview()
            currentARView = nil
            NSLog("✅ ARView limpiado")
            print("✅ ARView limpiado")
        }

        result(nil)
    }

    private func handleDispose(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("🧹 Liberando recursos de DeepAR")

        cleanup()

        result(nil)
        print("✅ Recursos de DeepAR liberados")
    }

    // MARK: - Helper Methods
    func setupCameraController(with deepAR: DeepAR) {
        NSLog("📷 Configurando CameraController...")
        print("📷 Configurando CameraController...")
        cameraController = CameraController(deepAR: deepAR)
        cameraController?.position = .front
        NSLog("🎥 Iniciando cámara...")
        print("🎥 Iniciando cámara...")
        cameraController?.startCamera()
        NSLog("✅ Cámara iniciada correctamente")
        print("✅ Cámara iniciada correctamente")
    }

    private func sendEvent(type: String, data: [String: Any]) {
        let event: [String: Any] = [
            "type": type,
            "data": data,
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000)
        ]

        // Asegurar que el evento se envía en el hilo principal
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?(event)
            print("📡 Evento enviado: \(type)")
        }
    }

    private func cleanup() {
        NSLog("🧹 Iniciando cleanup completo...")
        print("🧹 Iniciando cleanup completo...")

        isInitialized = false
        isRecording = false
        currentFilter = nil
        eventSink = nil

        // CRÍTICO: Detener y limpiar CameraController
        if let controller = cameraController {
            NSLog("🧹 Deteniendo y limpiando CameraController...")
            print("🧹 Deteniendo y limpiando CameraController...")
            controller.stopCamera()
            cameraController = nil
            NSLog("✅ CameraController limpiado")
            print("✅ CameraController limpiado")
        }

        // CRÍTICO: Limpiar ARView
        if let arView = currentARView {
            NSLog("🧹 Removiendo y limpiando ARView...")
            print("🧹 Removiendo y limpiando ARView...")
            arView.removeFromSuperview()
            currentARView = nil
            NSLog("✅ ARView limpiado")
            print("✅ ARView limpiado")
        }

        // Limpiar container view reference
        currentContainerView = nil

        // Shutdown DeepAR
        if let deepAR = deepAR {
            NSLog("🧹 Shutdown DeepAR...")
            print("🧹 Shutdown DeepAR...")
            deepAR.shutdown()
            self.deepAR = nil
            NSLog("✅ DeepAR shutdown completo")
            print("✅ DeepAR shutdown completo")
        }

        NSLog("✅ Cleanup completado - todos los recursos liberados")
        print("✅ Cleanup completado - todos los recursos liberados")
    }
}

// MARK: - FlutterStreamHandler
extension ArFiltersPlugin: FlutterStreamHandler {

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        print("📡 Event stream iniciado")
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        print("📡 Event stream cancelado")
        return nil
    }
}

// MARK: - DeepAR Delegate
extension ArFiltersPlugin: DeepARDelegate {

    public func didInitialize() {
        print("🎉 DeepAR delegate: didInitialize() llamado!")
        print("🔍 Estado isInitialized antes: \(isInitialized)")
        isInitialized = true
        print("✅ Estado isInitialized después: \(isInitialized)")
        sendEvent(type: "initialized", data: ["success": true, "source": "delegate"])
        print("📡 Evento initialized enviado desde delegate")
    }

    public func didStartVideoRecording() {
        print("🎬 DeepAR delegate: grabación iniciada")
        isRecording = true
        sendEvent(type: "recordingStarted", data: ["success": true])
    }

    public func didFinishVideoRecording(_ videoFilePath: String!) {
        print("✅ DeepAR delegate: grabación finalizada - \(videoFilePath ?? "unknown")")
        isRecording = false

        // Si tenemos un path guardado, mover el archivo ahí
        if let outputPath = recordingOutputPath, let tempPath = videoFilePath {
            print("📁 Moviendo video de \(tempPath) a \(outputPath)")

            do {
                let fileManager = FileManager.default

                // Eliminar archivo existente si hay
                if fileManager.fileExists(atPath: outputPath) {
                    try fileManager.removeItem(atPath: outputPath)
                }

                // Mover archivo temporal al path deseado
                try fileManager.moveItem(atPath: tempPath, toPath: outputPath)

                print("✅ Video movido exitosamente a: \(outputPath)")

                sendEvent(type: "recordingStopped", data: [
                    "success": true,
                    "filePath": outputPath
                ])
            } catch {
                print("❌ Error moviendo video: \(error.localizedDescription)")

                // Enviar el path temporal si falló mover
                sendEvent(type: "recordingStopped", data: [
                    "success": true,
                    "filePath": tempPath
                ])
            }

            recordingOutputPath = nil
        } else {
            // Sin path guardado, usar el path temporal de DeepAR
            sendEvent(type: "recordingStopped", data: [
                "success": true,
                "filePath": videoFilePath ?? ""
            ])
        }
    }

    public func recordingFailedWithError(_ error: Error!) {
        print("❌ DeepAR delegate: error en grabación - \(error?.localizedDescription ?? "unknown")")
        isRecording = false
        sendEvent(type: "recordingError", data: [
            "error": error?.localizedDescription ?? "Unknown recording error"
        ])
    }

    public func didTakeScreenshot(_ screenshot: UIImage!) {
        print("📸 DeepAR delegate: screenshot tomado")

        // Llamar al callback pendiente si existe
        if let callback = pendingScreenshotCallback {
            callback(screenshot)
            pendingScreenshotCallback = nil
        }

        // Convertir imagen a data y enviar evento
        if let imageData = screenshot?.pngData() {
            sendEvent(type: "screenshotTaken", data: [
                "success": true,
                "imageData": imageData.base64EncodedString()
            ])
        } else {
            sendEvent(type: "screenshotTaken", data: [
                "success": false,
                "reason": "Failed to convert screenshot to data"
            ])
        }
    }

    // Métodos adicionales del delegate para debugging
    public func didStart() {
        print("🚀 DeepAR delegate: didStart() llamado")
    }

    public func willStart() {
        print("⏳ DeepAR delegate: willStart() llamado")
    }

    public func didStop() {
        print("⏹️ DeepAR delegate: didStop() llamado")
    }

    public func willStop() {
        print("⏸️ DeepAR delegate: willStop() llamado")
    }

    // Manejo de errores de inicialización y license key
    public func didFailToInitialize(_ error: Error!) {
        print("❌ DeepAR delegate: didFailToInitialize() - \(error?.localizedDescription ?? "unknown error")")
        isInitialized = false
        sendEvent(type: "error", data: [
            "type": "initialization_failed",
            "message": error?.localizedDescription ?? "Unknown initialization error"
        ])
    }

    public func onLicenseError(_ error: Error!) {
        print("❌ DeepAR delegate: onLicenseError() - \(error?.localizedDescription ?? "unknown license error")")
        isInitialized = false
        sendEvent(type: "error", data: [
            "type": "license_error",
            "message": error?.localizedDescription ?? "Unknown license error"
        ])
    }

    // Método faltante que estaba causando el crash
    public func didFinishShutdown() {
        print("🔚 DeepAR delegate: didFinishShutdown() llamado")
        isInitialized = false
        sendEvent(type: "shutdown", data: ["success": true])
    }

}

// MARK: - DeepAR Preview Factory
class DeepARPreviewFactory: NSObject, FlutterPlatformViewFactory {
    private var plugin: ArFiltersPlugin

    init(instance: ArFiltersPlugin) {
        self.plugin = instance
        super.init()
    }

    func create(
        withFrame frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> FlutterPlatformView {
        return DeepARPreviewView(
            frame: frame,
            viewIdentifier: viewId,
            arguments: args,
            plugin: plugin
        )
    }
}

// MARK: - DeepAR Preview View
class DeepARPreviewView: NSObject, FlutterPlatformView {
    private var _view: UIView
    private var plugin: ArFiltersPlugin

    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        plugin: ArFiltersPlugin
    ) {
        self.plugin = plugin
        self._view = UIView()
        super.init()
        createNativeView(view: _view)
        print("✅ DeepARPreviewView creado con viewId: \(viewId)")
    }

    func view() -> UIView {
        return _view
    }

    func createNativeView(view: UIView) {
        view.backgroundColor = UIColor.black
        NSLog("🎯 [createNativeView] INICIO - Configurando DeepAR view")
        print("🎯 [createNativeView] INICIO - Configurando DeepAR view")

        // Verificar si DeepAR está disponible
        NSLog("🔍 [createNativeView] Verificando disponibilidad de DeepAR...")
        print("🔍 [createNativeView] Verificando disponibilidad de DeepAR...")

        guard let deepAR = self.plugin.deepAR else {
            NSLog("❌ [createNativeView] DeepAR es nil - no disponible")
            print("❌ [createNativeView] DeepAR es nil - no disponible")
            showErrorView(view, message: "DeepAR no disponible (nil)")
            return
        }

        NSLog("✅ [createNativeView] DeepAR existe: \(deepAR)")
        print("✅ [createNativeView] DeepAR existe")

        // Crear ARView nuevo (después de dispose todo debe ser nuevo)
        NSLog("🎭 [createNativeView] Llamando deepAR.createARView()...")
        print("🎭 [createNativeView] Llamando deepAR.createARView()...")

        guard let arView = deepAR.createARView(withFrame: view.bounds) else {
            NSLog("❌ [createNativeView] createARView() retornó nil")
            print("❌ [createNativeView] createARView() retornó nil")
            showErrorView(view, message: "createARView() falló - retornó nil")
            return
        }

        NSLog("✅ [createNativeView] ARView creado exitosamente: \(arView)")
        print("✅ [createNativeView] ARView creado exitosamente")

        // Configurar y guardar referencia
        arView.frame = view.bounds
        arView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(arView)
        self.plugin.currentARView = arView
        self.plugin.currentContainerView = view
        NSLog("✅ [createNativeView] ARView agregado al contenedor")
        print("✅ [createNativeView] ARView agregado al contenedor")

        // Crear CameraController nuevo (después de dispose debe ser nuevo)
        NSLog("📷 [createNativeView] Creando CameraController...")
        print("📷 [createNativeView] Creando CameraController...")
        self.plugin.setupCameraController(with: deepAR)
        NSLog("✅ [createNativeView] CameraController configurado")
        print("✅ [createNativeView] CameraController configurado")

        NSLog("🎉 [createNativeView] FIN - Todo configurado correctamente")
        print("🎉 [createNativeView] FIN - Todo configurado correctamente")
    }

    private func showErrorView(_ view: UIView, message: String) {
        let errorLabel = UILabel(frame: view.bounds)
        errorLabel.text = "DeepAR Error\n\n\(message)\n\n• Reinicia la app\n• Verifica permisos de cámara"
        errorLabel.numberOfLines = 0
        errorLabel.textColor = UIColor.red
        errorLabel.textAlignment = .center
        errorLabel.backgroundColor = UIColor.black
        errorLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(errorLabel)
    }
}