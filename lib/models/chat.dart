import 'package:cloud_firestore/cloud_firestore.dart';
import '../utils/chat_utils.dart';

/// Tipo de chat
enum ChatType {
  individual,
  group;

  String get value {
    switch (this) {
      case ChatType.individual:
        return 'individual';
      case ChatType.group:
        return 'group';
    }
  }

  static ChatType fromString(String? value) {
    switch (value) {
      case 'group':
        return ChatType.group;
      default:
        return ChatType.individual;
    }
  }
}

/// Modelo para la colección 'chats' de Firestore
///
/// Representa un chat individual entre dos usuarios.
/// Para grupos, usar la colección 'groups' con campos adicionales.
///
/// Campos en Firestore:
/// - type: 'individual' | 'group'
/// - participants: [userId1, userId2]
/// - createdAt: Timestamp
/// - lastActivity: Timestamp
/// - lastMessage: String?
/// - lastMessageTime: Timestamp?
/// - lastMessageSenderId: String?
///
/// Campos USER-SPECIFIC (manejados por ChatPreferencesCache, NO en Firestore):
/// - archived, muted, unreadCount, clearedAt
class Chat {
  final String id;
  final ChatType type;
  final List<String> participants;
  final DateTime createdAt;
  final DateTime? lastActivity;
  final String? lastMessage;
  final DateTime? lastMessageTime;
  final String? lastMessageSenderId;

  // Campos de grupo (solo si type == group)
  final String? name;
  final String? description;
  final String? photoURL;
  final List<String>? admins;
  final String? createdBy;

  const Chat({
    required this.id,
    required this.type,
    required this.participants,
    required this.createdAt,
    this.lastActivity,
    this.lastMessage,
    this.lastMessageTime,
    this.lastMessageSenderId,
    // Campos de grupo
    this.name,
    this.description,
    this.photoURL,
    this.admins,
    this.createdBy,
  });

  // ═══════════════════════════════════════════════════════════════
  // FACTORY CONSTRUCTORS
  // ═══════════════════════════════════════════════════════════════

  /// Crear desde DocumentSnapshot de Firestore
  factory Chat.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return Chat.fromMap(doc.id, data);
  }

  /// Crear desde Map (útil para testing y serialización)
  factory Chat.fromMap(String id, Map<String, dynamic> data) {
    return Chat(
      id: id,
      type: ChatType.fromString(data['type'] as String?),
      participants: List<String>.from(data['participants'] ?? []),
      createdAt: _parseDateTime(data['createdAt']) ?? DateTime.now(),
      lastActivity: _parseDateTime(data['lastActivity']),
      lastMessage: data['lastMessage'] as String?,
      lastMessageTime: _parseDateTime(data['lastMessageTime']),
      lastMessageSenderId: data['lastMessageSenderId'] as String?,
      // Campos de grupo
      name: data['name'] as String?,
      description: data['description'] as String?,
      photoURL: data['photoURL'] as String?,
      admins: data['admins'] != null
          ? List<String>.from(data['admins'])
          : null,
      createdBy: data['createdBy'] as String?,
    );
  }

  /// Helper para parsear DateTime de Firestore
  static DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  // ═══════════════════════════════════════════════════════════════
  // SERIALIZATION
  // ═══════════════════════════════════════════════════════════════

  /// Convertir a Map para Firestore
  Map<String, dynamic> toMap() {
    return {
      'type': type.value,
      'participants': participants,
      'createdAt': Timestamp.fromDate(createdAt),
      if (lastActivity != null)
        'lastActivity': Timestamp.fromDate(lastActivity!),
      if (lastMessage != null) 'lastMessage': lastMessage,
      if (lastMessageTime != null)
        'lastMessageTime': Timestamp.fromDate(lastMessageTime!),
      if (lastMessageSenderId != null)
        'lastMessageSenderId': lastMessageSenderId,
      // Campos de grupo
      if (name != null) 'name': name,
      if (description != null) 'description': description,
      if (photoURL != null) 'photoURL': photoURL,
      if (admins != null) 'admins': admins,
      if (createdBy != null) 'createdBy': createdBy,
    };
  }

  // ═══════════════════════════════════════════════════════════════
  // COMPUTED GETTERS (Domain Logic)
  // ═══════════════════════════════════════════════════════════════

  /// Es un chat de grupo
  bool get isGroup => type == ChatType.group;

  /// Es un chat individual
  bool get isIndividual => type == ChatType.individual;

  /// Obtener el ID del otro participante en un chat individual
  String getOtherParticipantId(String currentUserId) {
    if (isGroup) return '';
    return participants.firstWhere(
      (id) => id != currentUserId,
      orElse: () => '',
    );
  }

  /// Verificar si un usuario es participante
  bool hasParticipant(String userId) => participants.contains(userId);

  /// Verificar si un usuario es admin (solo grupos)
  bool isAdmin(String userId) => admins?.contains(userId) ?? false;

  /// Verificar si el chat tiene mensajes
  bool get hasMessages => lastMessage != null && lastMessage!.isNotEmpty;

  /// Tiempo formateado para UI
  String get formattedTime => ChatUtils.formatChatTime(
        lastMessageTime != null ? Timestamp.fromDate(lastMessageTime!) : null,
      );

  /// Nombre para mostrar en UI
  /// Para grupos: usa el nombre del grupo
  /// Para individuales: debe resolverse externamente con datos del usuario
  String get displayName => isGroup ? (name ?? 'Grupo') : '';

  // ═══════════════════════════════════════════════════════════════
  // COPY WITH
  // ═══════════════════════════════════════════════════════════════

  /// Crear copia con campos modificados
  Chat copyWith({
    String? id,
    ChatType? type,
    List<String>? participants,
    DateTime? createdAt,
    DateTime? lastActivity,
    String? lastMessage,
    DateTime? lastMessageTime,
    String? lastMessageSenderId,
    String? name,
    String? description,
    String? photoURL,
    List<String>? admins,
    String? createdBy,
  }) {
    return Chat(
      id: id ?? this.id,
      type: type ?? this.type,
      participants: participants ?? this.participants,
      createdAt: createdAt ?? this.createdAt,
      lastActivity: lastActivity ?? this.lastActivity,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      lastMessageSenderId: lastMessageSenderId ?? this.lastMessageSenderId,
      name: name ?? this.name,
      description: description ?? this.description,
      photoURL: photoURL ?? this.photoURL,
      admins: admins ?? this.admins,
      createdBy: createdBy ?? this.createdBy,
    );
  }

  // ═══════════════════════════════════════════════════════════════
  // STATIC METHODS - ID Generation
  // ═══════════════════════════════════════════════════════════════

  /// Generar ID para chat individual entre dos usuarios
  /// Los IDs se ordenan alfabéticamente para consistencia
  static String generateIndividualChatId(String userId1, String userId2) {
    return ChatUtils.getChatId(userId1, userId2);
  }

  // ═══════════════════════════════════════════════════════════════
  // STATIC METHODS - Firestore Queries
  // ═══════════════════════════════════════════════════════════════

  static final _firestore = FirebaseFirestore.instance;
  static const _collection = 'chats';

  /// Obtener referencia a la colección
  static CollectionReference<Map<String, dynamic>> get collectionRef =>
      _firestore.collection(_collection);

  /// Obtener chat por ID
  static Future<Chat?> getById(String chatId) async {
    final doc = await collectionRef.doc(chatId).get();
    if (!doc.exists) return null;
    return Chat.fromFirestore(doc);
  }

  /// Stream de un chat específico
  static Stream<Chat?> watchById(String chatId) {
    return collectionRef.doc(chatId).snapshots().map((doc) {
      if (!doc.exists) return null;
      return Chat.fromFirestore(doc);
    });
  }

  /// Buscar chat individual entre dos usuarios
  static Future<Chat?> findIndividualChat(
    String userId1,
    String userId2,
  ) async {
    final query = await collectionRef
        .where('type', isEqualTo: 'individual')
        .where('participants', arrayContains: userId1)
        .get();

    for (final doc in query.docs) {
      final chat = Chat.fromFirestore(doc);
      if (chat.participants.contains(userId2) &&
          chat.participants.length == 2) {
        return chat;
      }
    }
    return null;
  }

  /// Stream de chats del usuario (paginado, ordenado por actividad)
  ///
  /// IMPORTANTE: Este es el query principal optimizado para escalar.
  /// - Usa índice compuesto: participants (array-contains) + lastActivity (desc)
  /// - Paginación con cursor (startAfterDocument)
  /// - Filtros adicionales (archived, muted) se aplican localmente via ChatPreferencesCache
  static Stream<List<Chat>> watchByUser(
    String userId, {
    int limit = 50,
    DocumentSnapshot? startAfter,
  }) {
    Query<Map<String, dynamic>> query = collectionRef
        .where('participants', arrayContains: userId)
        .orderBy('lastActivity', descending: true)
        .limit(limit);

    if (startAfter != null) {
      query = query.startAfterDocument(startAfter);
    }

    return query.snapshots().map(
      (snapshot) => snapshot.docs.map(Chat.fromFirestore).toList(),
    );
  }

  /// Query paginado de chats (para cargar más)
  static Future<List<Chat>> getByUser(
    String userId, {
    int limit = 50,
    DocumentSnapshot? startAfter,
  }) async {
    Query<Map<String, dynamic>> query = collectionRef
        .where('participants', arrayContains: userId)
        .orderBy('lastActivity', descending: true)
        .limit(limit);

    if (startAfter != null) {
      query = query.startAfterDocument(startAfter);
    }

    final snapshot = await query.get();
    return snapshot.docs.map(Chat.fromFirestore).toList();
  }

  /// Contar chats del usuario (útil para verificaciones)
  static Future<int> countByUser(String userId) async {
    final snapshot = await collectionRef
        .where('participants', arrayContains: userId)
        .count()
        .get();
    return snapshot.count ?? 0;
  }

  // ═══════════════════════════════════════════════════════════════
  // EQUALITY
  // ═══════════════════════════════════════════════════════════════

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Chat && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() {
    return 'Chat(id: $id, type: ${type.value}, participants: $participants)';
  }
}
