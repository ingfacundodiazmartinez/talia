import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import '../services/message_forward_service.dart';
import '../services/contact_alias_service.dart';

/// Controller para el Forward Message Screen
///
/// Responsabilidades:
/// - Cargar chats y grupos disponibles
/// - Gestionar selección de destinos
/// - Ejecutar forward de mensajes
/// - Mantener estado de la pantalla
class ForwardMessageController extends ChangeNotifier {
  final ChatMessage message;
  final String? chatId;
  final String? contactName;

  // Dependencies
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final ContactAliasService _aliasService;
  final MessageForwardService _forwardService;

  // State
  final Set<String> _selectedChatIds = {};
  final Set<String> _selectedGroupIds = {};
  List<ChatItem> _chats = [];
  List<GroupItem> _groups = [];
  bool _isLoading = true;
  bool _isForwarding = false;

  ForwardMessageController({
    required this.message,
    this.chatId,
    this.contactName,
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    ContactAliasService? aliasService,
    MessageForwardService? forwardService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? FirebaseAuth.instance,
       _aliasService = aliasService ?? ContactAliasService(),
       _forwardService = forwardService ?? MessageForwardService();

  // Getters
  String get currentUserId => _auth.currentUser?.uid ?? '';
  List<ChatItem> get chats => _chats;
  List<GroupItem> get groups => _groups;
  bool get isLoading => _isLoading;
  bool get isForwarding => _isForwarding;
  Set<String> get selectedChatIds => _selectedChatIds;
  Set<String> get selectedGroupIds => _selectedGroupIds;
  int get totalSelectedCount => _selectedChatIds.length + _selectedGroupIds.length;

  /// Inicializar el controller
  Future<void> initialize() async {
    await _loadChatsAndGroups();
  }

  /// Cargar chats y grupos disponibles
  Future<void> _loadChatsAndGroups() async {
    try {
      _isLoading = true;
      notifyListeners();

      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return;

      // Cargar chats individuales
      final chatsSnapshot = await _firestore
          .collection('chats')
          .where('participants', arrayContains: currentUserId)
          .get();

      final chatsList = <ChatItem>[];
      for (final doc in chatsSnapshot.docs) {
        final data = doc.data();
        final participants = List<String>.from(data['participants'] ?? []);
        final otherUserId = participants.firstWhere(
          (id) => id != currentUserId,
          orElse: () => '',
        );

        if (otherUserId.isEmpty) continue;

        // Obtener info del contacto
        final userDoc = await _firestore.collection('users').doc(otherUserId).get();
        final userData = userDoc.data();

        if (userData != null) {
          final realName = userData['name'] ?? 'Usuario';
          final displayName = await _aliasService.getDisplayName(otherUserId, realName);

          chatsList.add(ChatItem(
            chatId: doc.id,
            contactId: otherUserId,
            contactName: displayName,
            contactPhotoUrl: userData['photoURL'],
          ));
        }
      }

      // Cargar grupos
      final groupsSnapshot = await _firestore
          .collection('groups')
          .where('members', arrayContains: currentUserId)
          .get();

      final groupsList = <GroupItem>[];
      for (final doc in groupsSnapshot.docs) {
        final data = doc.data();
        groupsList.add(GroupItem(
          groupId: doc.id,
          groupName: data['name'] ?? 'Grupo',
          groupPhotoUrl: data['photoURL'],
          membersCount: (data['members'] as List?)?.length ?? 0,
        ));
      }

      _chats = chatsList;
      _groups = groupsList;
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _isLoading = false;
      notifyListeners();
      throw Exception('Error cargando chats y grupos: $e');
    }
  }

  /// Toggle selección de chat
  void toggleChatSelection(String chatId) {
    if (_selectedChatIds.contains(chatId)) {
      _selectedChatIds.remove(chatId);
    } else {
      _selectedChatIds.add(chatId);
    }
    notifyListeners();
  }

  /// Toggle selección de grupo
  void toggleGroupSelection(String groupId) {
    if (_selectedGroupIds.contains(groupId)) {
      _selectedGroupIds.remove(groupId);
    } else {
      _selectedGroupIds.add(groupId);
    }
    notifyListeners();
  }

  /// Forward mensaje a destinos seleccionados
  Future<void> forwardMessage() async {
    if (_isForwarding || totalSelectedCount == 0) return;

    try {
      _isForwarding = true;
      notifyListeners();

      // Forward usando el servicio unificado
      await _forwardService.forwardMultipleMessages(
        originalMessages: [message],
        targetChatIds: _selectedChatIds.toList(),
        targetGroupIds: _selectedGroupIds.toList(),
        originalChatId: chatId,
        originalContactName: contactName,
      );

      _isForwarding = false;
      notifyListeners();
    } catch (e) {
      _isForwarding = false;
      notifyListeners();
      throw Exception('Error reenviando mensaje: $e');
    }
  }
}

/// Modelo para chat individual
class ChatItem {
  final String chatId;
  final String contactId;
  final String contactName;
  final String? contactPhotoUrl;

  ChatItem({
    required this.chatId,
    required this.contactId,
    required this.contactName,
    this.contactPhotoUrl,
  });
}

/// Modelo para grupo
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
}