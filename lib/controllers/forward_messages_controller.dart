import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../utils/release_logger.dart';
import '../services/contact_alias_service.dart';

/// Controller para manejar la lógica de negocio de ForwardMessagesScreen
///
/// Responsabilidades:
/// - Cargar chats disponibles para el usuario
/// - Cargar grupos disponibles para el usuario
/// - Obtener datos de contactos
/// - Manejar estado de carga
/// - Filtrar chat original del listado
/// - Abstraer operaciones Firebase del screen
class ForwardMessagesController {
  // Firebase services
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;
  final ContactAliasService _aliasService;

  // Estado interno
  List<ChatItem> _chats = [];
  List<GroupItem> _groups = [];
  bool _isLoading = true;

  // Stream controllers para notificar cambios
  final StreamController<List<ChatItem>> _chatsController = StreamController<List<ChatItem>>.broadcast();
  final StreamController<List<GroupItem>> _groupsController = StreamController<List<GroupItem>>.broadcast();
  final StreamController<bool> _isLoadingController = StreamController<bool>.broadcast();

  /// Constructor
  ForwardMessagesController({
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
    ContactAliasService? aliasService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance,
       _aliasService = aliasService ?? ContactAliasService();

  // Getters para estado actual
  List<ChatItem> get chats => _chats;
  List<GroupItem> get groups => _groups;
  bool get isLoading => _isLoading;

  // Streams para escuchar cambios
  Stream<List<ChatItem>> get chatsStream => _chatsController.stream;
  Stream<List<GroupItem>> get groupsStream => _groupsController.stream;
  Stream<bool> get isLoadingStream => _isLoadingController.stream;

  /// Inicializar controller - cargar chats y grupos
  Future<void> initialize({required String originalChatId}) async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        ReleaseLogger.error('Usuario no autenticado al cargar chats y grupos', tag: 'ForwardMessages');
        _updateLoadingState(false);
        return;
      }

      ReleaseLogger.log('Cargando chats y grupos para usuario $currentUserId', tag: 'ForwardMessages');

      // Cargar chats y grupos en paralelo
      final results = await Future.wait([
        _loadChats(currentUserId, originalChatId),
        _loadGroups(currentUserId),
      ]);

      final chatsList = results[0] as List<ChatItem>;
      final groupsList = results[1] as List<GroupItem>;

      _updateChatsData(chatsList);
      _updateGroupsData(groupsList);
      _updateLoadingState(false);

      ReleaseLogger.log('Carga completada: ${chatsList.length} chats, ${groupsList.length} grupos', tag: 'ForwardMessages');
    } catch (e) {
      ReleaseLogger.error('Error cargando chats y grupos: $e', tag: 'ForwardMessages');
      _updateLoadingState(false);
    }
  }

  /// Cargar chats individuales del usuario
  Future<List<ChatItem>> _loadChats(String currentUserId, String originalChatId) async {
    try {
      ReleaseLogger.log('Cargando chats individuales del usuario', tag: 'ForwardMessages');

      final chatsSnapshot = await _firestore
          .collection('chats')
          .where('participants', arrayContains: currentUserId)
          .get();

      final chatsList = <ChatItem>[];
      for (final doc in chatsSnapshot.docs) {
        // Saltar el chat original
        if (doc.id == originalChatId) continue;

        final chatItem = await _processChatDocument(doc, currentUserId);
        if (chatItem != null) {
          chatsList.add(chatItem);
        }
      }

      ReleaseLogger.log('${chatsList.length} chats individuales procesados', tag: 'ForwardMessages');
      return chatsList;
    } catch (e) {
      ReleaseLogger.error('Error cargando chats individuales: $e', tag: 'ForwardMessages');
      return [];
    }
  }

  /// Procesar documento de chat individual
  Future<ChatItem?> _processChatDocument(DocumentSnapshot doc, String currentUserId) async {
    try {
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) return null;

      final participants = List<String>.from(data['participants'] ?? []);
      final otherUserId = participants.firstWhere(
        (id) => id != currentUserId,
        orElse: () => '',
      );

      if (otherUserId.isEmpty) return null;

      // Obtener información del contacto
      final contactData = await _getContactData(otherUserId);
      if (contactData == null) return null;

      final realName = contactData['name'] ?? 'Usuario';
      final displayName = await _aliasService.getDisplayName(otherUserId, realName);

      return ChatItem(
        chatId: doc.id,
        contactId: otherUserId,
        contactName: displayName,
        contactPhotoUrl: contactData['photoURL'],
        isOnline: contactData['isOnline'] ?? false,
      );
    } catch (e) {
      ReleaseLogger.error('Error procesando chat ${doc.id}: $e', tag: 'ForwardMessages');
      return null;
    }
  }

  /// Cargar grupos del usuario
  Future<List<GroupItem>> _loadGroups(String currentUserId) async {
    try {
      ReleaseLogger.log('Cargando grupos del usuario', tag: 'ForwardMessages');

      final groupsSnapshot = await _firestore
          .collection('groups')
          .where('members', arrayContains: currentUserId)
          .get();

      final groupsList = <GroupItem>[];
      for (final doc in groupsSnapshot.docs) {
        final groupItem = _processGroupDocument(doc);
        if (groupItem != null) {
          groupsList.add(groupItem);
        }
      }

      ReleaseLogger.log('${groupsList.length} grupos procesados', tag: 'ForwardMessages');
      return groupsList;
    } catch (e) {
      ReleaseLogger.error('Error cargando grupos: $e', tag: 'ForwardMessages');
      return [];
    }
  }

  /// Procesar documento de grupo
  GroupItem? _processGroupDocument(DocumentSnapshot doc) {
    try {
      final data = doc.data() as Map<String, dynamic>?;
      if (data == null) return null;

      return GroupItem(
        groupId: doc.id,
        groupName: data['name'] ?? 'Grupo',
        groupPhotoUrl: data['avatar'], // Campo correcto es 'avatar' no 'imageUrl'
        membersCount: (data['members'] as List?)?.length ?? 0,
      );
    } catch (e) {
      ReleaseLogger.error('Error procesando grupo ${doc.id}: $e', tag: 'ForwardMessages');
      return null;
    }
  }

  /// Obtener datos del contacto
  Future<Map<String, dynamic>?> _getContactData(String contactId) async {
    try {
      final userDoc = await _firestore.collection('users').doc(contactId).get();
      return userDoc.data();
    } catch (e) {
      ReleaseLogger.error('Error obteniendo datos del contacto $contactId: $e', tag: 'ForwardMessages');
      return null;
    }
  }

  /// Actualizar datos de chats
  void _updateChatsData(List<ChatItem> chats) {
    _chats = chats;
    _chatsController.add(_chats);
  }

  /// Actualizar datos de grupos
  void _updateGroupsData(List<GroupItem> groups) {
    _groups = groups;
    _groupsController.add(_groups);
  }

  /// Actualizar estado de carga
  void _updateLoadingState(bool isLoading) {
    _isLoading = isLoading;
    _isLoadingController.add(_isLoading);
  }

  /// Obtener ID del usuario actual
  String? get currentUserId => _auth.currentUser?.uid;

  /// Verificar si hay chats o grupos disponibles
  bool get hasChatsOrGroups => _chats.isNotEmpty || _groups.isNotEmpty;

  /// Limpiar recursos
  void dispose() {
    ReleaseLogger.log('Disposing ForwardMessagesController', tag: 'ForwardMessages');
    _chatsController.close();
    _groupsController.close();
    _isLoadingController.close();
  }
}

/// Modelo para representar un chat individual
class ChatItem {
  final String chatId;
  final String contactId;
  final String contactName;
  final String? contactPhotoUrl;
  final bool isOnline;

  ChatItem({
    required this.chatId,
    required this.contactId,
    required this.contactName,
    this.contactPhotoUrl,
    required this.isOnline,
  });

  @override
  String toString() => 'ChatItem(chatId: $chatId, contactName: $contactName)';
}

/// Modelo para representar un grupo
class GroupItem {
  final String groupId;
  final String groupName;
  final String? groupPhotoUrl;
  final int membersCount;

  GroupItem({
    required this.groupId,
    required this.groupName,
    this.groupPhotoUrl,
    required this.membersCount,
  });

  @override
  String toString() => 'GroupItem(groupId: $groupId, groupName: $groupName, members: $membersCount)';
}