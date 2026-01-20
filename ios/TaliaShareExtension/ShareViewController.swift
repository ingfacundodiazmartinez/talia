//
//  ShareViewController.swift
//  TaliaShareExtension
//
//  Share Extension con UI completa estilo WhatsApp
//  Soporta envío directo a chats y creación de historias
//

import UIKit
import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Observable State

/// Estado observable para mantener los items compartidos sin perder selección
class ShareExtensionState: ObservableObject {
    @Published var sharedItems: [SharedItem] = []
    @Published var isLoading: Bool = true
}

class ShareViewController: UIViewController {

    private let appGroupId = "group.com.talia.chat"
    private var hostingController: UIHostingController<ShareExtensionView>?

    /// ✅ Estado observable que persiste cuando los items se cargan
    private let shareState = ShareExtensionState()

    override func viewDidLoad() {
        super.viewDidLoad()

        // Mostrar loading inicialmente
        view.backgroundColor = .systemBackground

        // Cargar chats cacheados (síncrono, rápido)
        let cachedChats = loadCachedChats()

        // Verificar autenticación
        let isAuthenticated = FirebaseUploadService.shared.isAuthenticated()
        NSLog("🔑 [ShareExt] Is authenticated: \(isAuthenticated)")

        // ✅ Crear vista SwiftUI con estado observable
        let shareView = ShareExtensionView(
            state: shareState,
            chats: cachedChats,
            isAuthenticated: isAuthenticated,
            onCancel: { [weak self] in
                self?.cancel()
            },
            onSendToChats: { [weak self] selectedChatIds, items in
                NSLog("📤 [ShareExt] ⭐ onSendToChats CALLBACK triggered")
                NSLog("📤 [ShareExt] - selectedChatIds: \(selectedChatIds)")
                NSLog("📤 [ShareExt] - items count: \(items.count)")
                self?.sendToChatsDirectly(chatIds: selectedChatIds, items: items)
            },
            onCreateStory: { [weak self] item in
                self?.createStoryDirectly(item: item)
            },
            onFallbackSend: { [weak self] selectedChatIds, items in
                NSLog("📤 [ShareExt] ⭐ onFallbackSend CALLBACK triggered")
                self?.sendToChats(chatIds: selectedChatIds, items: items)
            }
        )

        // Hostear SwiftUI en UIKit
        let hosting = UIHostingController(rootView: shareView)
        self.hostingController = hosting
        addChild(hosting)
        view.addSubview(hosting.view)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        hosting.didMove(toParent: self)

        // ✅ Cargar contenido compartido de forma asíncrona y actualizar el estado
        loadSharedItemsAsync { [weak self] items in
            guard let self = self else {
                NSLog("❌ [ShareExt] Self is nil after loading items")
                return
            }

            NSLog("📥 [ShareExt] Loaded \(items.count) items")

            // Log detalles de cada item
            for (index, item) in items.enumerated() {
                NSLog("📥 [ShareExt] Item \(index): type=\(item.type.rawValue), hasURL=\(item.url != nil), hasText=\(item.text != nil)")
            }

            // Actualizar estado observable (no reemplaza la vista, mantiene selección)
            DispatchQueue.main.async {
                NSLog("📥 [ShareExt] Updating state with \(items.count) items")
                self.shareState.sharedItems = items
                self.shareState.isLoading = false
                NSLog("📥 [ShareExt] State updated - isLoading: \(self.shareState.isLoading), items: \(self.shareState.sharedItems.count)")
            }
        }
    }

    // MARK: - Load Shared Content (Async)

    private func loadSharedItemsAsync(completion: @escaping ([SharedItem]) -> Void) {
        var items: [SharedItem] = []

        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            DispatchQueue.main.async { completion([]) }
            return
        }

        let group = DispatchGroup()
        let itemsLock = NSLock()

        for extensionItem in extensionItems {
            guard let attachments = extensionItem.attachments else { continue }

            for attachment in attachments {
                group.enter()

                if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    attachment.loadItem(forTypeIdentifier: UTType.image.identifier) { data, error in
                        defer { group.leave() }

                        if let error = error {
                            NSLog("❌ [ShareExt] Error loading image: \(error)")
                            return
                        }

                        if let url = data as? URL {
                            NSLog("✅ [ShareExt] Got image URL: \(url.lastPathComponent)")
                            itemsLock.lock()
                            items.append(SharedItem(type: .image, url: url, text: nil))
                            itemsLock.unlock()
                        } else if let image = data as? UIImage {
                            NSLog("✅ [ShareExt] Got UIImage, saving to temp...")
                            if let url = self.saveImageToTemp(image) {
                                itemsLock.lock()
                                items.append(SharedItem(type: .image, url: url, text: nil))
                                itemsLock.unlock()
                            } else {
                                NSLog("❌ [ShareExt] Failed to save UIImage to temp")
                            }
                        } else {
                            NSLog("❌ [ShareExt] Unknown image data type: \(type(of: data))")
                        }
                    }
                } else if attachment.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    attachment.loadItem(forTypeIdentifier: UTType.movie.identifier) { data, error in
                        defer { group.leave() }
                        guard error == nil, let url = data as? URL else { return }
                        itemsLock.lock()
                        items.append(SharedItem(type: .video, url: url, text: nil))
                        itemsLock.unlock()
                    }
                } else if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    attachment.loadItem(forTypeIdentifier: UTType.url.identifier) { data, error in
                        defer { group.leave() }
                        guard error == nil, let url = data as? URL else { return }
                        itemsLock.lock()
                        items.append(SharedItem(type: .url, url: nil, text: url.absoluteString))
                        itemsLock.unlock()
                    }
                } else if attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    attachment.loadItem(forTypeIdentifier: UTType.plainText.identifier) { data, error in
                        defer { group.leave() }
                        guard error == nil, let text = data as? String else { return }
                        itemsLock.lock()
                        items.append(SharedItem(type: .text, url: nil, text: text))
                        itemsLock.unlock()
                    }
                } else {
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            completion(items)
        }
    }

    private func saveImageToTemp(_ image: UIImage) -> URL? {
        // Usar compresión más agresiva para evitar problemas de memoria en Share Extension
        // Share Extensions tienen límite de ~120MB de memoria
        guard let data = image.jpegData(compressionQuality: 0.7) else {
            NSLog("❌ [ShareExt] Failed to get JPEG data from image")
            return nil
        }

        let fileName = "shared_\(Int(Date().timeIntervalSince1970))_\(UUID().uuidString.prefix(8)).jpg"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try data.write(to: tempURL)
            NSLog("✅ [ShareExt] Saved temp image: \(fileName) (\(data.count / 1024) KB)")
            return tempURL
        } catch {
            NSLog("❌ [ShareExt] Failed to write temp image: \(error)")
            return nil
        }
    }

    // MARK: - Load Cached Chats

    private func loadCachedChats() -> [CachedChat] {
        NSLog("🔍 [ShareExt] Loading cached chats...")
        NSLog("🔍 [ShareExt] App Group ID: \(appGroupId)")

        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            NSLog("❌ [ShareExt] App Group container not available - check entitlements!")
            return [CachedChat(id: "test", name: "App Group no disponible", photoURL: nil, isGroup: false, lastMessage: "Verifica los entitlements", lastMessageTime: nil)]
        }

        NSLog("📁 [ShareExt] Container URL: \(containerURL.path)")

        let cacheURL = containerURL.appendingPathComponent("chats_cache.json")
        NSLog("📄 [ShareExt] Cache URL: \(cacheURL.path)")

        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            NSLog("⚠️ [ShareExt] Cache file not found - main app needs to cache chats first")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: containerURL.path) {
                NSLog("📁 [ShareExt] Files in container: \(files)")
            }
            return [CachedChat(id: "test", name: "Abre la app primero", photoURL: nil, isGroup: false, lastMessage: "Ve a Chats para sincronizar", lastMessageTime: nil)]
        }

        do {
            let data = try Data(contentsOf: cacheURL)
            NSLog("📊 [ShareExt] Read \(data.count) bytes from cache")

            if let jsonString = String(data: data, encoding: .utf8) {
                NSLog("📝 [ShareExt] JSON preview: \(String(jsonString.prefix(200)))...")
            }

            let chats = try JSONDecoder().decode([CachedChat].self, from: data)
            NSLog("✅ [ShareExt] Loaded \(chats.count) cached chats")
            return chats
        } catch {
            NSLog("❌ [ShareExt] Error loading cached chats: \(error)")
            return [CachedChat(id: "test", name: "Error cargando cache", photoURL: nil, isGroup: false, lastMessage: "\(error.localizedDescription)", lastMessageTime: nil)]
        }
    }

    // MARK: - Actions

    private func cancel() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    // MARK: - Direct Upload (without opening main app)

    /// Enviar contenido directamente a chats usando Firebase REST API
    private func sendToChatsDirectly(chatIds: [String], items: [SharedItem]) {
        NSLog("📤 [ShareExt] sendToChatsDirectly called - chatIds: \(chatIds.count), items: \(items.count)")

        guard !chatIds.isEmpty else {
            NSLog("❌ [ShareExt] No chats selected")
            showError("Selecciona al menos un chat")
            return
        }

        guard !items.isEmpty else {
            NSLog("❌ [ShareExt] No items to send")
            showError("No hay contenido para enviar")
            return
        }

        // Verificar autenticación
        let isAuth = FirebaseUploadService.shared.isAuthenticated()
        let userId = FirebaseUploadService.shared.getUserId() ?? "nil"
        NSLog("📤 [ShareExt] Auth check - isAuth: \(isAuth), userId: \(userId)")

        if !isAuth {
            showError("No autenticado. Abre la app Talia primero.")
            return
        }

        NSLog("📤 [ShareExt] Sending \(items.count) items directly to \(chatIds.count) chats...")

        FirebaseUploadService.shared.sendToChats(items: items, chatIds: chatIds) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let messageId):
                    NSLog("✅ [ShareExt] Direct send successful: \(messageId)")
                    self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                case .error(let error):
                    NSLog("❌ [ShareExt] Direct send failed: \(error)")
                    self?.showError("Error: \(error)")
                }
            }
        }
    }

    /// Crear historia directamente usando Firebase REST API
    private func createStoryDirectly(item: SharedItem) {
        NSLog("📤 [ShareExt] Creating story directly...")

        FirebaseUploadService.shared.createStory(item: item) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let storyId):
                    NSLog("✅ [ShareExt] Story created: \(storyId)")
                    self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                case .error(let error):
                    NSLog("❌ [ShareExt] Story creation failed: \(error)")
                    self?.showError(error)
                }
            }
        }
    }

    /// Mostrar error al usuario (sin cerrar automáticamente)
    private func showError(_ message: String) {
        let alert = UIAlertController(
            title: "Error",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Reintentar", style: .default) { _ in
            // No cerrar, permitir reintentar
        })
        alert.addAction(UIAlertAction(title: "Cerrar", style: .cancel) { [weak self] _ in
            self?.cancel()
        })
        present(alert, animated: true)
    }

    /// Mostrar info de debug
    private func showDebugAlert(_ title: String, _ message: String) {
        let alert = UIAlertController(
            title: title,
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Fallback: Save to App Group (when not authenticated)

    private func sendToChats(chatIds: [String], items: [SharedItem]) {
        guard !chatIds.isEmpty else {
            NSLog("❌ [ShareExt] No chats selected (fallback)")
            showError("Selecciona al menos un chat")
            return
        }

        guard !items.isEmpty else {
            NSLog("❌ [ShareExt] No items to send (fallback)")
            showError("No hay contenido para enviar")
            return
        }

        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            NSLog("❌ [ShareExt] App Group container not available for sending")
            showError("Error de configuración. Abre la app e intenta de nuevo.")
            return
        }

        // Copiar archivos al App Group
        var savedItems: [[String: Any]] = []
        let sharedMediaDir = containerURL.appendingPathComponent("shared_media", isDirectory: true)
        try? FileManager.default.createDirectory(at: sharedMediaDir, withIntermediateDirectories: true)

        for item in items {
            var itemData: [String: Any] = ["type": item.type.rawValue]

            if let url = item.url {
                let fileName = "\(Int(Date().timeIntervalSince1970))_\(url.lastPathComponent)"
                let destURL = sharedMediaDir.appendingPathComponent(fileName)
                do {
                    try? FileManager.default.removeItem(at: destURL)
                    try FileManager.default.copyItem(at: url, to: destURL)
                    itemData["path"] = destURL.path
                    NSLog("✅ [ShareExt] Copied file to: \(destURL.path)")
                } catch {
                    NSLog("❌ [ShareExt] Error copying file: \(error)")
                }
            }

            if let text = item.text {
                itemData["text"] = text
            }

            savedItems.append(itemData)
        }

        // Guardar petición de envío
        let pendingShare: [String: Any] = [
            "chatIds": chatIds,
            "items": savedItems,
            "timestamp": Date().timeIntervalSince1970
        ]

        if let userDefaults = UserDefaults(suiteName: appGroupId),
           let jsonData = try? JSONSerialization.data(withJSONObject: pendingShare) {
            userDefaults.set(jsonData, forKey: "pending_share")
            userDefaults.synchronize()
            NSLog("✅ [ShareExt] Saved pending share for \(chatIds.count) chats with \(savedItems.count) items")
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        } else {
            NSLog("❌ [ShareExt] Failed to save pending share")
            showError("Error guardando contenido")
        }
    }
}

// MARK: - Data Models

struct SharedItem {
    enum ItemType: String {
        case image, video, url, text
    }
    let type: ItemType
    let url: URL?
    let text: String?
}

struct CachedChat: Codable, Identifiable {
    let id: String
    let name: String
    let photoURL: String?
    let isGroup: Bool
    let lastMessage: String?
    let lastMessageTime: Double?

    var displayTime: String {
        guard let time = lastMessageTime else { return "" }
        let date = Date(timeIntervalSince1970: time / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - SwiftUI Views

struct ShareExtensionView: View {
    /// ✅ Estado observable que persiste cuando se actualizan los items
    @ObservedObject var state: ShareExtensionState

    let chats: [CachedChat]
    let isAuthenticated: Bool
    let onCancel: () -> Void
    let onSendToChats: ([String], [SharedItem]) -> Void
    let onCreateStory: (SharedItem) -> Void
    let onFallbackSend: ([String], [SharedItem]) -> Void

    @State private var searchText = ""
    @State private var selectedChatIds: Set<String> = []
    @State private var selectedDestination: ShareDestination = .chat
    @State private var isSending = false
    @State private var debugMessage: String = ""

    enum ShareDestination {
        case chat
        case story
    }

    var filteredChats: [CachedChat] {
        if searchText.isEmpty {
            return chats
        }
        return chats.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var individualChats: [CachedChat] {
        filteredChats.filter { !$0.isGroup }
    }

    var groupChats: [CachedChat] {
        filteredChats.filter { $0.isGroup }
    }

    /// Determinar si se puede crear historia (solo 1 imagen o video)
    var canCreateStory: Bool {
        guard state.sharedItems.count == 1 else { return false }
        let item = state.sharedItems[0]
        return item.type == .image || item.type == .video
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // ✅ Mostrar loading mientras se cargan los items
                if state.isLoading {
                    Spacer()
                    ProgressView("Cargando contenido...")
                    Spacer()
                } else if state.sharedItems.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        Text("No hay contenido para compartir")
                            .foregroundColor(.gray)
                    }
                    Spacer()
                } else {
                    // Preview de items compartidos (máximo 3 para evitar problemas de memoria)
                    HStack {
                        ForEach(0..<min(state.sharedItems.count, 3), id: \.self) { index in
                            itemPreview(state.sharedItems[index])
                        }
                        if state.sharedItems.count > 3 {
                            Text("+\(state.sharedItems.count - 3)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(8)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)

                    // Contador de items
                    Text("\(state.sharedItems.count) elemento(s) seleccionado(s)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Selector de destino (Chat / Historia)
                    if canCreateStory {
                        destinationPicker
                            .padding(.horizontal)
                            .padding(.top, 12)
                    }

                    // Contenido según destino seleccionado
                    if selectedDestination == .story {
                        storyContent
                    } else {
                        chatContent
                    }
                }
            }
            .navigationTitle("Compartir")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancelar") {
                        onCancel()
                    }
                    .disabled(isSending)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if selectedDestination == .chat && !state.isLoading && !state.sharedItems.isEmpty {
                        Button("Enviar") {
                            sendToSelectedChats()
                        }
                        .disabled(selectedChatIds.isEmpty || isSending)
                        .fontWeight(.semibold)
                    }
                }
            }
            .overlay {
                if isSending {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    ProgressView("Enviando...")
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                }
            }
            // Debug banner - siempre visible con info útil
            .safeAreaInset(edge: .top) {
                HStack {
                    Text("📊 \(state.sharedItems.count) items | \(selectedChatIds.count) chats | Auth: \(isAuthenticated ? "✓" : "✗")")
                    Spacer()
                    if !debugMessage.isEmpty {
                        Text(debugMessage)
                            .fontWeight(.medium)
                    }
                }
                .font(.caption)
                .foregroundColor(.white)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(isSending ? Color.orange : (isAuthenticated ? Color.green : Color.red))
            }
            .onAppear {
                NSLog("👁 [ShareExt] View appeared - items: \(state.sharedItems.count), loading: \(state.isLoading)")
            }
            .onChange(of: state.sharedItems.count) { newCount in
                NSLog("📦 [ShareExt] Items changed to: \(newCount)")
                if !isSending {
                    debugMessage = "Loaded \(newCount) items"
                }
            }
            .onChange(of: selectedChatIds.count) { newCount in
                NSLog("✅ [ShareExt] Selected chats changed to: \(newCount)")
            }
        }
    }

    // MARK: - Destination Picker

    var destinationPicker: some View {
        HStack(spacing: 12) {
            destinationButton(
                title: "Chat",
                icon: "message.fill",
                isSelected: selectedDestination == .chat
            ) {
                selectedDestination = .chat
            }

            destinationButton(
                title: "Historia",
                icon: "circle.dashed",
                isSelected: selectedDestination == .story
            ) {
                selectedDestination = .story
            }
        }
    }

    func destinationButton(title: String, icon: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title)
            }
            .font(.subheadline)
            .fontWeight(.medium)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.blue : Color(.systemGray5))
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(8)
        }
    }

    // MARK: - Story Content

    var storyContent: some View {
        VStack(spacing: 20) {
            Spacer()

            // Preview grande
            if let item = state.sharedItems.first {
                largePreview(item)
                    .frame(maxWidth: 250, maxHeight: 350)
            }

            // Info
            Text("Tu historia estará visible por 24 horas")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Botón de crear
            Button {
                createStory()
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("Crear Historia")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 14)
                .background(Color.blue)
                .cornerRadius(25)
            }
            .disabled(isSending)

            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    func largePreview(_ item: SharedItem) -> some View {
        if item.type == .image, let url = item.url, let uiImage = UIImage(contentsOfFile: url.path) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        } else if item.type == .video {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.gray.opacity(0.3))
                Image(systemName: "video.fill")
                    .font(.largeTitle)
                    .foregroundColor(.gray)
            }
        }
    }

    // MARK: - Chat Content

    var chatContent: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                TextField("Buscar", text: $searchText)
            }
            .padding(10)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .padding(.horizontal)
            .padding(.top, 8)

            if chats.isEmpty {
                emptyState
            } else {
                chatList
            }
        }
    }

    @ViewBuilder
    func itemPreview(_ item: SharedItem) -> some View {
        switch item.type {
        case .image:
            // Defensivo: verificar URL y cargar imagen de forma segura
            if let url = item.url {
                // Usar una imagen cacheada para evitar cargar repetidamente
                if FileManager.default.fileExists(atPath: url.path),
                   let uiImage = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 50, height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    // Archivo no existe o no se pudo cargar
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.orange.opacity(0.3))
                        .frame(width: 50, height: 50)
                        .overlay(Image(systemName: "exclamationmark.triangle").foregroundColor(.orange))
                }
            } else {
                // Sin URL
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 50, height: 50)
                    .overlay(Image(systemName: "photo").foregroundColor(.gray))
            }
        case .video:
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 50, height: 50)
                .overlay(Image(systemName: "video.fill").foregroundColor(.gray))
        case .url, .text:
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.1))
                .frame(width: 50, height: 50)
                .overlay(Image(systemName: item.type == .url ? "link" : "text.alignleft").foregroundColor(.blue))
        }
    }

    var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "message.fill")
                .font(.system(size: 50))
                .foregroundColor(.gray)
            Text("No hay chats disponibles")
                .font(.headline)
                .foregroundColor(.gray)
            Text("Abre Talia para cargar tus chats")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    var chatList: some View {
        List {
            // Chats individuales
            if !individualChats.isEmpty {
                Section(header: Text("Chats recientes")) {
                    ForEach(individualChats) { chat in
                        ChatRow(chat: chat, isSelected: selectedChatIds.contains(chat.id))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggleSelection(chat.id)
                            }
                    }
                }
            }

            // Grupos
            if !groupChats.isEmpty {
                Section(header: Text("Grupos")) {
                    ForEach(groupChats) { chat in
                        ChatRow(chat: chat, isSelected: selectedChatIds.contains(chat.id))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggleSelection(chat.id)
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func toggleSelection(_ chatId: String) {
        NSLog("🔘 [ShareExt] toggleSelection: \(chatId)")
        NSLog("🔘 [ShareExt] Before: \(selectedChatIds)")

        if selectedChatIds.contains(chatId) {
            selectedChatIds.remove(chatId)
        } else {
            selectedChatIds.insert(chatId)
        }

        NSLog("🔘 [ShareExt] After: \(selectedChatIds)")
        debugMessage = "Selected: \(selectedChatIds.count) chats"
    }

    // MARK: - Actions

    private func sendToSelectedChats() {
        // Debug: mostrar estado actual
        let authStatus = isAuthenticated

        // ✅ STEP 1: Log que se presionó el botón
        debugMessage = "⏳ STEP1: Botón presionado..."
        NSLog("📤 [ShareExt] ========== SEND BUTTON PRESSED ==========")
        NSLog("📤 [ShareExt] selectedChatIds: \(Array(selectedChatIds))")
        NSLog("📤 [ShareExt] state.sharedItems.count: \(state.sharedItems.count)")
        NSLog("📤 [ShareExt] isAuthenticated: \(authStatus)")

        guard !selectedChatIds.isEmpty else {
            debugMessage = "❌ ERROR: No hay chats seleccionados"
            NSLog("❌ [ShareExt] No chats selected when send pressed")
            return
        }

        guard !state.sharedItems.isEmpty else {
            debugMessage = "❌ ERROR: No hay items para enviar"
            NSLog("❌ [ShareExt] No items when send pressed")
            return
        }

        // ✅ STEP 2: Validación pasó
        debugMessage = "⏳ STEP2: Validación OK. Auth=\(authStatus)"
        NSLog("📤 [ShareExt] Sending to \(selectedChatIds.count) chats with \(state.sharedItems.count) items")

        // Capturar items AHORA
        let itemsToSend = state.sharedItems
        let chatsToSend = Array(selectedChatIds)

        NSLog("📤 [ShareExt] Captured \(itemsToSend.count) items and \(chatsToSend.count) chats")
        NSLog("📤 [ShareExt] Auth status: \(authStatus)")

        isSending = true

        // Llamar directamente
        if authStatus {
            debugMessage = "⏳ Subiendo..."
            onSendToChats(chatsToSend, itemsToSend)
        } else {
            debugMessage = "⚠️ Sin auth, guardando..."
            onFallbackSend(chatsToSend, itemsToSend)
        }
    }

    private func createStory() {
        guard let item = state.sharedItems.first else { return }
        isSending = true
        onCreateStory(item)
    }
}

struct ChatRow: View {
    let chat: CachedChat
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            if let photoURL = chat.photoURL, let url = URL(string: photoURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        avatarPlaceholder
                    }
                }
                .frame(width: 50, height: 50)
                .clipShape(Circle())
            } else {
                avatarPlaceholder
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let lastMessage = chat.lastMessage, !lastMessage.isEmpty {
                    Text(lastMessage)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundColor(isSelected ? .blue : .gray.opacity(0.5))
        }
        .padding(.vertical, 4)
    }

    var avatarPlaceholder: some View {
        Circle()
            .fill(Color.gray.opacity(0.3))
            .frame(width: 50, height: 50)
            .overlay(
                Image(systemName: chat.isGroup ? "person.3.fill" : "person.fill")
                    .foregroundColor(.gray)
            )
    }
}
