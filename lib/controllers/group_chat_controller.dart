import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../services/typing_indicator_service.dart';
import '../services/media_service.dart';
import '../services/media_compression_service.dart';
import '../services/chats/repositories/message_repository.dart';
import '../services/user_settings_service.dart';
import '../services/message_cache_service.dart';
import '../services/favorite_service.dart';
import '../services/read_receipts_service.dart';
import '../services/delivery_receipts_service.dart';
import '../models/chat_message.dart';
import '../utils/release_logger.dart';

/// Controller que maneja la lógica de un chat grupal
///
/// ✅ MIGRADO: Ahora usa Cloud Functions (sendGroupMessage) para envío de mensajes,
/// garantizando moderación, seguridad y TTL automático.
///
/// ✅ OPTIMISTIC UPDATES: Extiende ChangeNotifier para UI reactiva como chats 1-1
///
/// Todos los métodos de envío (texto, imagen, video, audio) pasan por la CF
/// `sendGroupMessage` que maneja:
/// - Validación de membresía
/// - TTL (deleteAt) automático de 7 días
/// - Actualización de lastMessage en el documento del grupo
/// - Trigger de notificaciones push (vía incrementGroupUnreadCount)
class GroupChatController extends ChangeNotifier {
  final String groupId;
  final String groupName;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final FirebaseFunctions _functions;
  final TypingIndicatorService _typingService;
  final MediaService _mediaService;

  // ✅ Repository para acceso a mensajes
  final MessageRepository _messageRepository;

  // UUID generator para localIds
  static const _uuid = Uuid();

  // Paginación
  static const int messagesPerPage = 30;
  DocumentSnapshot? _lastDocument;
  bool _hasMoreMessages = true;
  final List<DocumentSnapshot> _loadedMessages = [];

  // ✅ OPTIMISTIC UPDATES: Lista de mensajes para UI reactiva
  final List<ChatMessage> _messages = [];
  final List<ChatMessage> _pendingMessages = [];
  StreamSubscription<QuerySnapshot>? _messagesSubscription;

  // ✅ Favoritos
  final FavoriteService _favoriteService = FavoriteService();
  StreamSubscription<Set<String>>? _favoritesSubscription;
  Set<String> _favoriteIds = {};

  // Cache de usuarios del grupo
  final Map<String, String> _userNames = {};
  final Map<String, String> _userPhotos = {};
  List<String> _memberIds = [];

  // ✅ FIX: Flag para ignorar errores después de dispose (ej: salir del grupo)
  bool _isDisposed = false;

  GroupChatController({
    required this.groupId,
    required this.groupName,
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    FirebaseFunctions? functions,
    TypingIndicatorService? typingService,
    MediaService? mediaService,
    MessageRepository? messageRepository,
  })  : _firestore = firestore ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance,
        _functions = functions ?? FirebaseFunctions.instanceFor(region: 'us-central1'),
        _typingService = typingService ?? TypingIndicatorService(),
        _mediaService = mediaService ?? MediaService(),
        _messageRepository = messageRepository ?? MessageRepository(
          firestore: firestore ?? FirebaseFirestore.instance,
          auth: auth ?? FirebaseAuth.instance,
        );

  // Getters
  String get currentUserId => _auth.currentUser?.uid ?? '';
  bool get hasMoreMessages => _hasMoreMessages;
  List<DocumentSnapshot> get loadedMessages => _loadedMessages;
  Map<String, String> get userNames => _userNames;
  Map<String, String> get userPhotos => _userPhotos;
  List<String> get memberIds => _memberIds;
  Set<String> get favoriteIds => _favoriteIds;  // ✅ NEW: Favoritos

  /// ✅ OPTIMISTIC: Lista de mensajes para UI (incluye pendientes)
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  List<ChatMessage> get pendingMessages => List.unmodifiable(_pendingMessages);

  /// Inicializar el controller
  Future<void> initialize() async {
    // ✅ Verificar autenticación antes de hacer queries
    if (currentUserId.isEmpty) {
      ReleaseLogger.error('No hay usuario autenticado - abortando inicialización', tag: 'GroupChatController');
      return;
    }

    try {
      await loadGroupMembers();
    } catch (e) {
      ReleaseLogger.error('Error en loadGroupMembers: $e', tag: 'GroupChatController');
      // Continuar - el chat puede funcionar sin la lista de miembros
    }

    try {
      await markMessagesAsRead();
    } catch (e) {
      // permission-denied es esperado si el usuario no es miembro del grupo
      if (e.toString().contains('permission-denied')) {
        ReleaseLogger.warning('Sin permisos para marcar mensajes como leídos (¿usuario no es miembro?)', tag: 'GroupChatController');
      } else {
        ReleaseLogger.error('Error en markMessagesAsRead: $e', tag: 'GroupChatController');
      }
    }

    _startMessagesSubscription();
    await _loadFavorites();  // ✅ NEW: Cargar favoritos
  }

  /// ✅ NEW: Cargar IDs de mensajes favoritos
  Future<void> _loadFavorites() async {
    try {
      _favoriteIds = await _favoriteService.getFavoriteMessageIds(
        chatId: groupId,
        isGroupChat: true,
      );

      // Suscribirse a cambios
      _favoritesSubscription = _favoriteService.getFavoriteMessageIdsStream(
        chatId: groupId,
        isGroupChat: true,
      ).listen((ids) {
        if (_isDisposed) return;
        _favoriteIds = ids;
        notifyListeners();
      }, onError: (error) {
        // ✅ FIX: Ignorar errores de permisos (ocurre cuando el usuario sale del grupo)
        if (_isDisposed || _isPermissionError(error)) {
          _favoritesSubscription?.cancel();
          return;
        }
        ReleaseLogger.error('Error en stream de favoritos: $error', tag: 'GroupChatController');
      });

      notifyListeners();
    } catch (e) {
      ReleaseLogger.error('Error loading favorites: $e', tag: 'GroupChatController');
    }
  }

  /// ✅ NEW: Refrescar favoritos (llamar después de toggle)
  Future<void> refreshFavorites() async {
    try {
      _favoriteIds = await _favoriteService.getFavoriteMessageIds(
        chatId: groupId,
        isGroupChat: true,
      );
      notifyListeners();
    } catch (e) {
      ReleaseLogger.error('Error refreshing favorites: $e', tag: 'GroupChatController');
    }
  }

  /// ✅ OPTIMISTIC: Iniciar suscripción a mensajes de Firestore
  void _startMessagesSubscription() {
    _messagesSubscription?.cancel();

    _messagesSubscription = _messageRepository.watchMessages(
      chatId: groupId,
      isGroup: true,
      limit: messagesPerPage,
    ).listen((snapshot) {
      if (_isDisposed) return;
      _handleMessagesSnapshot(snapshot);
    }, onError: (error) {
      // ✅ FIX: Ignorar errores de permisos (ocurre cuando el usuario sale del grupo)
      if (_isDisposed || _isPermissionError(error)) {
        _messagesSubscription?.cancel();
        return;
      }
      ReleaseLogger.error('Error en stream de mensajes del grupo: $error', tag: 'GroupChatController');
    });
  }

  /// ✅ Helper: Check if error is a permission error (expected when leaving group)
  bool _isPermissionError(dynamic error) {
    final errorStr = error.toString().toLowerCase();
    return errorStr.contains('permission') ||
           errorStr.contains('permission_denied') ||
           errorStr.contains('permission-denied') ||
           errorStr.contains('insufficient');
  }

  /// ✅ OPTIMISTIC: Procesar snapshot de mensajes y actualizar lista
  void _handleMessagesSnapshot(QuerySnapshot snapshot) {
    final firestoreMessages = snapshot.docs
        .where((doc) => !isBlockedForCurrentUser(doc))
        .map((doc) => ChatMessage.fromFirestore(doc, currentUserId: currentUserId))
        .toList();

    // ✅ FIX: Guardar mensajes en Hive para que la galería de medios funcione
    if (firestoreMessages.isNotEmpty) {
      MessageCacheService().saveMessages(groupId, firestoreMessages);
    }

    // Combinar mensajes de Firestore con pendientes (optimistas)
    final Set<String> firestoreIds = firestoreMessages.map((m) => m.id).toSet();
    final Set<String> firestoreLocalIds = firestoreMessages
        .where((m) => m.localId != null)
        .map((m) => m.localId!)
        .toSet();

    // Filtrar pendientes que ya llegaron de Firestore (por id o localId)
    _pendingMessages.removeWhere((pending) =>
        firestoreIds.contains(pending.id) ||
        firestoreLocalIds.contains(pending.localId));

    // Actualizar lista: pendientes primero (más recientes), luego Firestore
    _messages.clear();
    _messages.addAll(_pendingMessages);
    _messages.addAll(firestoreMessages);

    // ✅ Ordenar por tiempo EFECTIVO (timestamp del servidor, o localTimestamp
    // si todavía no tiene). Evita que un mensaje fallido (sin timestamp de
    // servidor) quede clavado como última burbuja para siempre.
    _messages.sort((a, b) {
      final aTime = a.timestamp?.toDate() ?? a.localTimestamp;
      final bTime = b.timestamp?.toDate() ?? b.localTimestamp;
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return bTime.compareTo(aTime); // descendente: más reciente primero
    });

    // ✅ FIX: Marcar mensajes como leídos cuando llegan mensajes de otros usuarios
    // Esto asegura que los mensajes se marquen como vistos mientras el chat está abierto
    final hasUnreadFromOthers = firestoreMessages.any((msg) =>
      msg.senderId != currentUserId &&
      !(msg.readBy?.contains(currentUserId) ?? false)
    );
    if (hasUnreadFromOthers) {
      markMessagesAsRead();
    }

    notifyListeners();
  }

  /// Cargar miembros del grupo
  /// ✅ OPTIMIZADO: Usa datos desnormalizados o batch queries en paralelo
  Future<void> loadGroupMembers() async {
    try {
      final groupDoc = await _firestore.collection('groups').doc(groupId).get();
      final groupData = groupDoc.data();

      if (groupData == null) return;

      _memberIds = List<String>.from(groupData['members'] ?? []);

      // ✅ OPTIMIZACIÓN 1: Usar datos desnormalizados si existen
      final memberDetails = groupData['memberDetails'] as Map<String, dynamic>?;
      if (memberDetails != null && memberDetails.isNotEmpty) {
        for (final memberId in _memberIds) {
          final details = memberDetails[memberId] as Map<String, dynamic>?;
          if (details != null) {
            _userNames[memberId] = details['name'] ?? 'Usuario';
            _userPhotos[memberId] = details['photoURL'] ?? '';
          }
        }
        ReleaseLogger.log('Cargados ${_memberIds.length} miembros del grupo (desnormalizado)', tag: 'GroupChatController');
        return;
      }

      // ✅ OPTIMIZACIÓN 2: Batch queries en paralelo (fallback)
      if (_memberIds.isEmpty) return;

      final futures = _memberIds.map((memberId) =>
        _firestore.collection('users').doc(memberId).get()
      ).toList();

      final userDocs = await Future.wait(futures);

      for (int i = 0; i < _memberIds.length; i++) {
        final memberId = _memberIds[i];
        final userData = userDocs[i].data();
        if (userData != null) {
          _userNames[memberId] = userData['name'] ?? 'Usuario';
          _userPhotos[memberId] = userData['photoURL'] ?? '';
        }
      }
    } catch (e) {
      ReleaseLogger.error('Error cargando miembros del grupo: $e', tag: 'GroupChatController');
    }
  }

  /// Marcar mensajes como leídos
  Future<void> markMessagesAsRead() async {
    try {
      if (currentUserId.isEmpty) return;

      // 1. Resetear contador de no leídos (siempre se hace para la UI local)
      await _firestore.collection('groups').doc(groupId).update({
        'unreadCount_$currentUserId': 0,
      });

      // ✅ FIX: Verificar si el usuario tiene activadas las confirmaciones de lectura
      // Si está deshabilitado, no marcamos los mensajes como leídos (readBy)
      final showReceipts = await UserSettingsService().showReadReceipts();

      if (!showReceipts) {
        ReleaseLogger.log('🔒 Confirmaciones de lectura desactivadas - no se marca readBy en grupo $groupId', tag: 'GroupChatController');
        return;
      }

      // 2. Marcar mensajes individuales como leídos (actualizar array readBy[])
      // NO usar where() para evitar problemas de índices - leer todos y filtrar
      final messagesSnapshot = await _firestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(50) // Últimos 50 mensajes
          .get();

      // Batch write para eficiencia
      final batch = _firestore.batch();
      int updateCount = 0;

      for (final doc in messagesSnapshot.docs) {
        final data = doc.data();
        final senderId = data['senderId'] as String?;
        final readBy = List<String>.from(data['readBy'] ?? []);

        // Solo actualizar mensajes de OTROS usuarios que NO estén ya en readBy
        if (senderId != null &&
            senderId != currentUserId &&
            !readBy.contains(currentUserId)) {
          batch.update(doc.reference, {
            'readBy': FieldValue.arrayUnion([currentUserId]),
          });
          updateCount++;
        }
      }

      // Ejecutar batch si hay updates
      if (updateCount > 0) {
        await batch.commit();
      }
    } catch (e) {
      ReleaseLogger.error('⚠️ [markMessagesAsRead] Error marcando mensajes como leídos: $e', tag: 'GroupChatController');
    }
  }

  /// ✅ FIX: Marca mensajes como vistos para actualizar lastOpenedAt (V2 read receipts)
  ///
  /// Esto actualiza lastOpenedAt_{userId} en el group document, lo cual permite
  /// que el sender vea sus mensajes como "seen" cuando message.timestamp < lastOpenedAt
  ///
  /// Llamar cuando:
  /// - El usuario entra al grupo
  /// - El usuario resume la app con el grupo abierto
  Future<void> markAsSeenForReceipts() async {
    try {
      await ReadReceiptsService().markMessagesAsSeen(
        chatId: groupId,
        isGroupChat: true,
      );
      ReleaseLogger.log('✅ Group $groupId: lastOpenedAt actualizado para read receipts');
    } catch (e) {
      ReleaseLogger.error('Failed to mark messages as seen for group $groupId: $e');
    }
  }

  /// ✅ FIX: Marca mensajes como entregados (delivery receipts)
  ///
  /// Actualiza deliveredTo[] para indicar que el usuario recibió los mensajes
  Future<void> markAsDeliveredForReceipts() async {
    try {
      await DeliveryReceiptsService().markMessagesAsDelivered(
        chatId: groupId,
        isGroupChat: true,
      );
      ReleaseLogger.log('✅ Group $groupId: mensajes marcados como entregados');
    } catch (e) {
      ReleaseLogger.error('Failed to mark messages as delivered for group $groupId: $e');
    }
  }

  /// Cargar más mensajes (paginación)
  Future<List<DocumentSnapshot>> loadMoreMessages() async {
    if (!_hasMoreMessages) return [];

    try {
      Query query = _firestore
          .collection('groups')
          .doc(groupId)
          .collection('messages')
          .orderBy('timestamp', descending: true)
          .limit(messagesPerPage);

      if (_lastDocument != null) {
        query = query.startAfterDocument(_lastDocument!);
      }

      final snapshot = await query.get();

      if (snapshot.docs.isEmpty) {
        _hasMoreMessages = false;
        return [];
      }

      _loadedMessages.addAll(snapshot.docs);
      _lastDocument = snapshot.docs.last;
      _hasMoreMessages = snapshot.docs.length == messagesPerPage;

      ReleaseLogger.log('Cargados ${snapshot.docs.length} mensajes más antiguos del grupo', tag: 'GroupChatController');
      return snapshot.docs;
    } catch (e) {
      ReleaseLogger.error('Error cargando más mensajes: $e', tag: 'GroupChatController');
      return [];
    }
  }

  /// Enviar mensaje de texto usando Cloud Function (seguro con moderación)
  /// ✅ OPTIMISTIC: Muestra el mensaje inmediatamente mientras se procesa en el servidor
  Future<bool> sendTextMessage({
    required String text,
    Map<String, dynamic>? replyTo,
  }) async {
    if (text.trim().isEmpty || currentUserId.isEmpty) return false;

    // 1. Generar localId único
    final localId = _uuid.v4();

    // 2. Crear mensaje optimista usando factory (igual que chats 1-1)
    final optimisticMessage = ChatMessage.optimistic(
      id: localId,
      senderId: currentUserId,
      text: text.trim(),
      type: 'text',
      replyTo: replyTo,
    );

    // 3. Agregar a lista de pendientes y notificar UI
    _pendingMessages.add(optimisticMessage);
    _messages.insert(0, optimisticMessage);
    notifyListeners();

    ReleaseLogger.log('📤 [Optimistic] Mensaje agregado: ${localId.substring(0, 8)}...', tag: 'GroupChatController');

    try {
      final callable = _functions.httpsCallable('sendGroupMessage');

      final data = <String, dynamic>{
        'groupId': groupId,
        'text': text.trim(),
        'localId': localId, // ✅ Enviar localId para deduplicación
      };

      if (replyTo != null) {
        data['replyTo'] = replyTo;
      }

      await callable.call(data);

      // ✅ El listener de Firestore reemplazará el mensaje optimista con el real
      ReleaseLogger.log('✅ Mensaje de texto enviado via Cloud Function al grupo', tag: 'GroupChatController');
      return true;
    } on FirebaseFunctionsException catch (e) {
      // ❌ Error: Marcar como fallido
      _markMessageAsError(localId);
      ReleaseLogger.error('❌ Error CF enviando mensaje al grupo: ${e.code} - ${e.message}', tag: 'GroupChatController');
      return false;
    } catch (e) {
      // ❌ Error: Marcar como fallido
      _markMessageAsError(localId);
      ReleaseLogger.error('❌ Error enviando mensaje al grupo: $e', tag: 'GroupChatController');
      return false;
    }
  }

  /// Marcar mensaje como error cuando falla el envío
  void _markMessageAsError(String messageId) {
    final index = _messages.indexWhere((m) => m.id == messageId);
    if (index != -1) {
      _messages[index] = _messages[index].copyWith(status: MessageStatus.error);
      notifyListeners();
    }
    _pendingMessages.removeWhere((m) => m.id == messageId);
  }

  /// Enviar imagen usando Cloud Function (seguro con moderación y TTL automático)
  /// ✅ OPTIMISTIC: Muestra la imagen inmediatamente mientras se sube
  Future<bool> sendImage({required ImageSource source}) async {
    if (currentUserId.isEmpty) return false;

    try {
      // 1. Seleccionar imagen primero
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(
        source: source,
        imageQuality: 70,
        maxWidth: 1920,
        maxHeight: 1920,
      );

      if (pickedFile == null) {
        ReleaseLogger.log('⚠️ No se seleccionó imagen', tag: 'GroupChatController');
        return false;
      }

      // 2. Crear mensaje optimista con path LOCAL (se muestra inmediatamente)
      final localId = _uuid.v4();
      final optimisticMessage = ChatMessage.optimistic(
        id: localId,
        senderId: currentUserId,
        type: 'image',
        localPath: pickedFile.path, // ✅ FIX: Usar localPath para imagen local
      );

      _pendingMessages.add(optimisticMessage);
      _messages.insert(0, optimisticMessage);
      notifyListeners(); // ✅ UI se actualiza inmediatamente

      // 3. ✅ OPTIMIZACIÓN: Comprimir imagen antes de subir
      final imageFile = File(pickedFile.path);
      final compressedFile = await MediaCompressionService().compressImage(imageFile);
      final fileToUpload = compressedFile ?? imageFile;

      // 4. Subir imagen en background
      final imageUrl = await _mediaService.uploadImageFile(
        imageFile: fileToUpload,
        chatId: groupId,
        userId: currentUserId,
      );

      if (imageUrl == null) {
        // Error al subir - marcar como error
        _markMessageAsError(localId);
        ReleaseLogger.error('❌ Error subiendo imagen', tag: 'GroupChatController');
        return false;
      }

      // 5. Enviar mensaje via Cloud Function
      final callable = _functions.httpsCallable('sendGroupMessage');
      await callable.call(<String, dynamic>{
        'groupId': groupId,
        'imageUrl': imageUrl,
        'localId': localId, // Para reconciliar con el mensaje optimista
      });

      // 6. Remover de pendientes (el mensaje llegará por el stream de Firestore)
      _pendingMessages.removeWhere((m) => m.id == localId);

      ReleaseLogger.log('✅ Imagen enviada via Cloud Function al grupo', tag: 'GroupChatController');
      return true;
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error('❌ Error CF enviando imagen al grupo: ${e.code} - ${e.message}', tag: 'GroupChatController');
      return false;
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando imagen al grupo: $e', tag: 'GroupChatController');
      return false;
    }
  }

  /// Enviar video usando Cloud Function (seguro con moderación y TTL automático)
  Future<bool> sendVideoFromFile({
    required String videoPath,
    Function(String)? onShowMessage,
    VoidCallback? onHideMessage,
  }) async {
    if (currentUserId.isEmpty) return false;

    try {
      ReleaseLogger.log('Procesando video: $videoPath', tag: 'GroupChatController');
      final File videoFile = File(videoPath);

      // 1. Comprimir y validar video
      final MediaCompressionService compressionService = MediaCompressionService();

      // Notificar que se está comprimiendo
      onShowMessage?.call('Comprimiendo video...');

      final File? validatedVideo = await compressionService.validateVideo(
        videoFile,
        onProgress: (progress) {
          ReleaseLogger.log('Progreso de compresión: ${progress.toStringAsFixed(0)}%', tag: 'GroupChatController');
        },
      );

      // Ocultar mensaje de compresión
      onHideMessage?.call();

      if (validatedVideo == null) {
        ReleaseLogger.error('No se pudo comprimir el video bajo 10 MB', tag: 'GroupChatController');
        onShowMessage?.call('El video es muy grande y no se pudo comprimir bajo el límite de 10 MB. Intenta con un video más corto.');
        throw Exception('El video no se pudo comprimir bajo el límite de 10 MB');
      }

      // 2. Subir video comprimido
      final videoUrl = await _mediaService.uploadVideoFile(
        videoFile: validatedVideo,
        chatId: groupId,
        userId: currentUserId,
      );

      if (videoUrl == null) return false;

      // 3. Enviar mensaje via Cloud Function (maneja TTL y lastMessage automáticamente)
      final callable = _functions.httpsCallable('sendGroupMessage');

      await callable.call(<String, dynamic>{
        'groupId': groupId,
        'videoUrl': videoUrl,
      });

      ReleaseLogger.log('✅ Video enviado via Cloud Function al grupo', tag: 'GroupChatController');
      return true;
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error('❌ Error CF enviando video al grupo: ${e.code} - ${e.message}', tag: 'GroupChatController');
      return false;
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando video al grupo: $e', tag: 'GroupChatController');
      return false;
    }
  }

  /// Enviar audio usando Cloud Function (seguro con moderación y TTL automático)
  /// Nota: Ya no usa optimistic updates para garantizar seguridad via Cloud Functions
  Future<bool> sendAudio({
    required String audioPath,
    required List<double> waveformData,
  }) async {
    if (currentUserId.isEmpty) return false;

    try {
      ReleaseLogger.log('Subiendo audio del grupo...', tag: 'GroupChatController');

      // 1. Subir audio a Storage
      final audioUrl = await _mediaService.uploadAudio(
        audioPath: audioPath,
        chatId: groupId,
        userId: currentUserId,
      );

      if (audioUrl == null) {
        ReleaseLogger.error('Error subiendo audio a Storage', tag: 'GroupChatController');
        return false;
      }

      // 2. Enviar mensaje via Cloud Function (maneja TTL y lastMessage automáticamente)
      final callable = _functions.httpsCallable('sendGroupMessage');

      await callable.call(<String, dynamic>{
        'groupId': groupId,
        'audioUrl': audioUrl,
        'waveformData': waveformData,
      });

      ReleaseLogger.log('✅ Audio enviado via Cloud Function al grupo', tag: 'GroupChatController');
      return true;
    } on FirebaseFunctionsException catch (e) {
      ReleaseLogger.error('❌ Error CF enviando audio al grupo: ${e.code} - ${e.message}', tag: 'GroupChatController');
      return false;
    } catch (e) {
      ReleaseLogger.error('❌ Error enviando audio al grupo: $e', tag: 'GroupChatController');
      return false;
    }
  }

  /// @deprecated Use [sendAudio] instead. Mantenido por compatibilidad.
  @Deprecated('Use sendAudio() en su lugar - ahora usa Cloud Functions')
  Future<String?> sendAudioOptimistic({
    required String audioPath,
    required List<double> waveformData,
  }) async {
    final success = await sendAudio(audioPath: audioPath, waveformData: waveformData);
    return success ? 'cf_message' : null;
  }

  // ✅ ELIMINADOS: _updateGroupDocument y _sendNotifications
  // Las Cloud Functions ahora manejan:
  // - sendGroupMessage: crea el mensaje con TTL y actualiza lastMessage
  // - incrementGroupUnreadCount trigger: envía notificaciones push automáticamente

  /// Stream de mensajes recientes
  /// ✅ REFACTORED: Now uses MessageRepository instead of direct Firestore access
  /// ✅ FILTRADO: Excluye mensajes donde currentUserId está en blockedFor
  Stream<QuerySnapshot> watchRecentMessages() {
    return _messageRepository.watchMessages(
      chatId: groupId,
      isGroup: true,
      limit: messagesPerPage,
    );
  }

  /// Filtrar documentos excluyendo los bloqueados para el usuario actual
  /// Usar en el UI: snapshot.docs donde !isBlockedForCurrentUser(doc)
  bool isBlockedForCurrentUser(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) return false;
    final blockedFor = data['blockedFor'] as List<dynamic>?;
    if (blockedFor == null || blockedFor.isEmpty) return false;
    return blockedFor.contains(currentUserId);
  }

  /// Stream de usuarios escribiendo
  Stream<List<String>> watchTypingUsers() {
    return _typingService.watchGroupTypingUsers(groupId, currentUserId);
  }

  /// Establecer estado de escritura
  void setTyping(bool isTyping) {
    _typingService.setTyping(groupId, isTyping, isGroup: true);
  }

  /// Detener escritura
  void stopTyping() {
    _typingService.stopTyping();
  }

  /// Establecer estado de grabación de audio
  void setRecording(bool isRecording) {
    _typingService.setRecording(groupId, isRecording, isGroup: true);
  }

  /// Detener grabación
  void stopRecording() {
    _typingService.stopRecording();
  }

  /// Stream de actividad de usuarios (typing/recording)
  Stream<Map<String, UserActivityState>> watchGroupActivity() {
    return _typingService.watchGroupActivity(groupId, currentUserId);
  }

  /// Obtener nombre de usuario por ID
  String getUserName(String userId) {
    return _userNames[userId] ?? 'Usuario';
  }

  /// Obtener foto de usuario por ID
  String getUserPhoto(String userId) {
    return _userPhotos[userId] ?? '';
  }

  /// Eliminar mensaje (solo si fue enviado por el usuario actual y hace menos de 5 minutos)
  Future<bool> deleteMessage(String messageId, [Timestamp? timestamp]) async {
    if (currentUserId.isEmpty) return false;

    try {
      // Verificar que no hayan pasado más de 5 minutos
      if (timestamp != null) {
        final now = DateTime.now();
        final messageTime = timestamp.toDate();
        final difference = now.difference(messageTime);

        if (difference.inMinutes >= 5) {
          ReleaseLogger.log('No se puede eliminar: Han pasado más de 5 minutos', tag: 'GroupChatController');
          return false;
        }
      }

      // Eliminar mensaje (hard delete)
      await _firestore
          .collection('groups_v2')
          .doc(groupId)
          .collection('messages')
          .doc(messageId)
          .delete();

      ReleaseLogger.log('Mensaje eliminado exitosamente del grupo', tag: 'GroupChatController');
      return true;
    } catch (e) {
      ReleaseLogger.error('Error eliminando mensaje del grupo: $e', tag: 'GroupChatController');
      return false;
    }
  }

  /// Limpiar recursos
  @override
  void dispose() {
    _isDisposed = true;  // ✅ FIX: Marcar como disposed PRIMERO para ignorar errores pendientes
    _messagesSubscription?.cancel();
    _favoritesSubscription?.cancel();
    stopTyping();
    super.dispose();
  }
}
