import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:permission_handler/permission_handler.dart';
import 'ai_analysis_service.dart';
import 'notification_service.dart';
import 'child_profile_screen.dart';
import 'theme_service.dart';
import 'animations.dart';
import 'widgets/stories_section.dart';
import 'widgets/emergency_button.dart';
import 'services/location_service.dart';
import 'services/emergency_service.dart';
import 'services/chat_permission_service.dart';
import 'services/chat_block_service.dart';
import 'services/user_role_service.dart';
import 'screens/add_contact_screen.dart';
import 'screens/my_code_screen.dart';
import 'widgets/create_group_widget.dart';
import 'services/group_chat_service.dart';
import 'services/video_call_service.dart';
import 'screens/video_call_screen.dart';
import 'screens/audio_call_screen.dart';
// import 'screens/ar_camera_screen.dart'; // Temporalmente deshabilitado

class ChildHomeScreen extends StatefulWidget {
  const ChildHomeScreen({super.key});

  @override
  State<ChildHomeScreen> createState() => _ChildHomeScreenState();
}

class _ChildHomeScreenState extends State<ChildHomeScreen> {
  int _selectedIndex = 0;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final LocationService _locationService = LocationService();
  final ChatPermissionService _permissionService = ChatPermissionService();
  final ChatBlockService _blockService = ChatBlockService();
  final VideoCallService _videoCallService = VideoCallService();

  StreamSubscription<QuerySnapshot>? _incomingCallsSubscription;

  @override
  void initState() {
    super.initState();
    _initializeLocationTracking();
    _listenForIncomingCalls();
  }

  // Inicializar tracking de ubicación
  Future<void> _initializeLocationTracking() async {
    // Esperar un poco para que la app se cargue completamente
    await Future.delayed(Duration(seconds: 2));

    // Habilitar tracking en background
    await _locationService.enableBackgroundTracking();

    // Iniciar tracking de ubicación en foreground
    await _locationService.startLocationTracking();

    print('✅ Tracking de ubicación inicializado (foreground + background)');
  }

  // Verificar si el usuario tiene padres vinculados
  Future<bool> _hasLinkedParents() async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return false;

      final userRoleService = UserRoleService();
      final linkedParents = await userRoleService.getLinkedParents(currentUserId);

      return linkedParents.isNotEmpty;
    } catch (e) {
      print('❌ Error verificando padres vinculados: $e');
      return false;
    }
  }

  // Escuchar llamadas entrantes
  void _listenForIncomingCalls() {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) return;

    _incomingCallsSubscription = _videoCallService
        .watchIncomingCalls(currentUserId)
        .listen(
      (snapshot) {
        for (var change in snapshot.docChanges) {
          if (change.type == DocumentChangeType.added) {
            final callData = change.doc.data() as Map<String, dynamic>;
            final callId = change.doc.id;
            final callerName = callData['callerName'] ?? 'Desconocido';
            final callerId = callData['callerId'];
            final channelName = callData['channelName'];

            // Mostrar diálogo de llamada entrante
            _showIncomingCallDialog(
              callId: callId,
              callerName: callerName,
              callerId: callerId,
              channelName: channelName,
            );
          }
        }
      },
      onError: (error) {
        // Ignorar errores de permisos durante cierre de sesión
        if (error.toString().contains('permission-denied')) {
          print('ℹ️ Listener de video_calls cancelado (cierre de sesión)');
        } else {
          print('⚠️ Error en listener de video_calls: $error');
        }
      },
    );

    print('👂 Escuchando llamadas entrantes para usuario: $currentUserId');
  }

  // Mostrar diálogo de llamada entrante
  void _showIncomingCallDialog({
    required String callId,
    required String callerName,
    required String callerId,
    required String channelName,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.videocam, color: Color(0xFF9D7FE8), size: 30),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Videollamada entrante',
                  style: TextStyle(fontSize: 18),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: Color(0xFF9D7FE8).withOpacity(0.2),
                child: Text(
                  callerName.isNotEmpty ? callerName[0].toUpperCase() : 'U',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF9D7FE8),
                  ),
                ),
              ),
              SizedBox(height: 16),
              Text(
                '$callerName te está llamando...',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16),
              ),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: () async {
                // Rechazar llamada
                try {
                  await _videoCallService.rejectCall(callId);
                  Navigator.pop(context);
                } catch (e) {
                  print('❌ Error rechazando llamada: $e');
                  Navigator.pop(context);
                }
              },
              icon: Icon(Icons.call_end, color: Colors.red),
              label: Text('Rechazar', style: TextStyle(color: Colors.red)),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                // Aceptar llamada
                try {
                  await _videoCallService.acceptCall(callId);
                  Navigator.pop(context);

                  // Navegar a la pantalla de videollamada
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => VideoCallScreen(
                        callId: callId,
                        channelName: channelName,
                        token: '', // En producción, generar desde servidor
                        uid: _auth.currentUser!.uid.hashCode,
                        isCaller: false,
                        remoteName: callerName,
                      ),
                    ),
                  );
                } catch (e) {
                  print('❌ Error aceptando llamada: $e');
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error al aceptar la llamada'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              icon: Icon(Icons.videocam, color: Colors.white),
              label: Text('Aceptar'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  void dispose() {
    _locationService.dispose();
    _incomingCallsSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      _buildChatList(),
      _buildContactsScreen(),
      _buildProfileScreen(),
    ];

    return Scaffold(
      body: screens[_selectedIndex],
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 10,
              offset: Offset(0, -5),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _selectedIndex,
          onTap: (index) => setState(() => _selectedIndex = index),
          selectedItemColor: Color(0xFF9D7FE8),
          unselectedItemColor: Colors.grey,
          items: [
            BottomNavigationBarItem(
              icon: Icon(Icons.chat_bubble_outline),
              activeIcon: Icon(Icons.chat_bubble),
              label: 'Chats',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.people_outline),
              activeIcon: Icon(Icons.people),
              label: 'Contactos',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: 'Perfil',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatList() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF9D7FE8), Color(0xFFB39DDB)],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '¡Hola! 👋',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Tus conversaciones seguras',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white.withOpacity(0.9),
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () {
                          showModalBottomSheet(
                            context: context,
                            isScrollControlled: true,
                            backgroundColor: Colors.transparent,
                            builder: (context) => CreateGroupWidget(
                              onGroupCreated: () {
                                setState(() {});
                              },
                            ),
                          );
                        },
                        child: Container(
                          padding: EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.group_add,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                      ),
                      SizedBox(width: 12),
                      GestureDetector(
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => MyCodeScreen(),
                            ),
                          );
                        },
                        child: Container(
                          padding: EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.qr_code,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                      ),
                      SizedBox(width: 12),
                      FutureBuilder<bool>(
                        future: _hasLinkedParents(),
                        builder: (context, snapshot) {
                          if (snapshot.data == true) {
                            return Row(
                              children: [
                                HeaderEmergencyButton(
                                  onEmergencyActivated: () {
                                    print('🆘 Emergencia activada desde el header');
                                  },
                                ),
                                SizedBox(width: 12),
                              ],
                            );
                          }
                          return SizedBox.shrink();
                        },
                      ),
                      Container(
                        padding: EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.shield,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(30),
                    topRight: Radius.circular(30),
                  ),
                ),
                child: StreamBuilder<QuerySnapshot>(
                  stream: _firestore
                      .collection('chats')
                      .where(
                        'participants',
                        arrayContains: _auth.currentUser?.uid,
                      )
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.error_outline,
                              size: 48,
                              color: Colors.red,
                            ),
                            SizedBox(height: 16),
                            Text('Error: ${snapshot.error}'),
                          ],
                        ),
                      );
                    }

                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return Center(child: CircularProgressIndicator());
                    }

                    if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                      // Mostrar historias incluso cuando no hay chats
                      return ListView(
                        padding: EdgeInsets.all(16),
                        children: [
                          StoriesHeader(),
                          StoriesSection(),
                          SizedBox(height: 24),
                          Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.chat_bubble_outline,
                                  size: 64,
                                  color: Colors.grey[300],
                                ),
                                SizedBox(height: 16),
                                Text(
                                  'No tienes conversaciones aún',
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    }

                    return FutureBuilder<List<Widget>>(
                      future: _buildCategorizedChatList(snapshot.data!.docs),
                      builder: (context, chatListSnapshot) {
                        if (chatListSnapshot.connectionState ==
                            ConnectionState.waiting) {
                          return Center(child: CircularProgressIndicator());
                        }

                        if (!chatListSnapshot.hasData ||
                            chatListSnapshot.data!.isEmpty) {
                          return Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.chat_bubble_outline,
                                  size: 64,
                                  color: Colors.grey[300],
                                ),
                                SizedBox(height: 16),
                                Text(
                                  'No tienes conversaciones aún',
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          );
                        }

                        return ListView(
                          padding: EdgeInsets.all(16),
                          children: chatListSnapshot.data!,
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<List<Widget>> _buildCategorizedChatList(
    List<QueryDocumentSnapshot> chatDocs,
  ) async {
    final List<Widget> widgets = [];
    final List<Map<String, dynamic>> parentChats = [];
    final List<Map<String, dynamic>> otherChats = [];

    // Agregar sección de historias al principio
    widgets.add(StoriesHeader());
    widgets.add(StoriesSection());
    widgets.add(SizedBox(height: 16));

    // Obtener y agregar grupos
    try {
      final groupChatService = GroupChatService();
      final groupsSnapshot = await _firestore
          .collection('groups')
          .where('members', arrayContains: _auth.currentUser?.uid)
          .where('isActive', isEqualTo: true)
          .orderBy('lastActivity', descending: true)
          .get();

      if (groupsSnapshot.docs.isNotEmpty) {
        widgets.add(
          Padding(
            padding: EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              'Grupos',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Color(0xFF2D3142),
              ),
            ),
          ),
        );

        for (final groupDoc in groupsSnapshot.docs) {
          final groupData = groupDoc.data();
          widgets.add(_buildGroupChatItem(
            groupId: groupDoc.id,
            groupName: groupData['name'] ?? 'Grupo',
            memberCount: (groupData['members'] as List?)?.length ?? 0,
            lastMessage: 'Toca para abrir',
            messageCount: groupData['messageCount'] ?? 0,
          ));
        }

        widgets.add(SizedBox(height: 16));
      }
    } catch (e) {
      print('Error obteniendo grupos: $e');
    }

    // Obtener padres vinculados del usuario actual
    final userRoleService = UserRoleService();
    final linkedParents = await userRoleService.getLinkedParents(_auth.currentUser?.uid ?? '');
    final parentId = linkedParents.isNotEmpty ? linkedParents.first : null;

    // Separar chats de padres y otros
    for (final chatDoc in chatDocs) {
      final chatData = chatDoc.data() as Map<String, dynamic>;
      final participants = List<String>.from(chatData['participants'] ?? []);
      final otherUserId = participants.firstWhere(
        (id) => id != _auth.currentUser?.uid,
        orElse: () => '',
      );

      if (otherUserId.isEmpty) continue;

      try {
        final userDoc = await _firestore
            .collection('users')
            .doc(otherUserId)
            .get();
        final userData = userDoc.data();

        final chatInfo = {
          'chatDoc': chatDoc,
          'chatData': chatData,
          'otherUserId': otherUserId,
          'userData': userData,
        };

        // Si es el padre o un padre vinculado, ponerlo en parentChats
        if (otherUserId == parentId || (userData?['isParent'] == true)) {
          parentChats.add(chatInfo);
        } else {
          otherChats.add(chatInfo);
        }
      } catch (e) {
        print('Error obteniendo datos del usuario $otherUserId: $e');
      }
    }

    // Agregar chats de padres primero (si no existen chats, crear placeholder)
    if (parentId != null) {
      // Verificar si ya existe un chat con el padre
      final existingParentChat = parentChats.any(
        (chat) => chat['otherUserId'] == parentId,
      );

      if (!existingParentChat) {
        // Crear chat placeholder con el padre
        try {
          final parentDoc = await _firestore
              .collection('users')
              .doc(parentId)
              .get();
          final parentData = parentDoc.data();

          if (parentData != null) {
            widgets.add(_buildParentChatHeader());
            widgets.add(
              _buildChatItem(
                chatId: _getChatId(_auth.currentUser!.uid, parentId),
                userId: parentId,
                name: parentData['name'] ?? 'Padre/Madre',
                lastMessage: 'Inicia una conversación',
                time: '',
                unreadCount: 0,
                isOnline: parentData['isOnline'] ?? false,
                photoURL: parentData['photoURL'],
                isParent: true,
                isEmpty: true,
              ),
            );
          }
        } catch (e) {
          print('Error obteniendo datos del padre: $e');
        }
      }
    }

    // Agregar chats de padres existentes
    if (parentChats.isNotEmpty) {
      if (widgets.isEmpty) {
        widgets.add(_buildParentChatHeader());
      }

      // Ordenar chats de padres por tiempo
      parentChats.sort((a, b) {
        final aTime = a['chatData']['lastMessageTime'] as Timestamp?;
        final bTime = b['chatData']['lastMessageTime'] as Timestamp?;

        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;

        return bTime.compareTo(aTime);
      });

      for (final chat in parentChats) {
        final chatDoc = chat['chatDoc'] as QueryDocumentSnapshot;
        final chatData = chat['chatData'] as Map<String, dynamic>;
        final userData = chat['userData'] as Map<String, dynamic>?;
        final otherUserId = chat['otherUserId'] as String;

        widgets.add(
          _buildChatItem(
            chatId: chatDoc.id,
            userId: otherUserId,
            name: userData?['name'] ?? 'Usuario',
            lastMessage: chatData['lastMessage'] ?? '',
            time: _formatTime(chatData['lastMessageTime']),
            unreadCount: 0,
            isOnline: userData?['isOnline'] ?? false,
            photoURL: userData?['photoURL'],
            isParent: true,
          ),
        );
      }
    }

    // Agregar separador si hay chats de padres y otros chats
    if (widgets.isNotEmpty && otherChats.isNotEmpty) {
      widgets.add(SizedBox(height: 16));
      widgets.add(_buildOtherChatsHeader());
    }

    // Agregar otros chats
    if (otherChats.isNotEmpty) {
      if (widgets.isEmpty) {
        widgets.add(_buildOtherChatsHeader());
      }

      // Ordenar otros chats por tiempo
      otherChats.sort((a, b) {
        final aTime = a['chatData']['lastMessageTime'] as Timestamp?;
        final bTime = b['chatData']['lastMessageTime'] as Timestamp?;

        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;

        return bTime.compareTo(aTime);
      });

      for (final chat in otherChats) {
        final chatDoc = chat['chatDoc'] as QueryDocumentSnapshot;
        final chatData = chat['chatData'] as Map<String, dynamic>;
        final userData = chat['userData'] as Map<String, dynamic>?;
        final otherUserId = chat['otherUserId'] as String;

        widgets.add(
          _buildChatItem(
            chatId: chatDoc.id,
            userId: otherUserId,
            name: userData?['name'] ?? 'Usuario',
            lastMessage: chatData['lastMessage'] ?? '',
            time: _formatTime(chatData['lastMessageTime']),
            unreadCount: 0,
            isOnline: userData?['isOnline'] ?? false,
            photoURL: userData?['photoURL'],
            isParent: false,
          ),
        );
      }
    }

    return widgets;
  }

  Widget _buildParentChatHeader() {
    return Padding(
      padding: EdgeInsets.only(bottom: 12, left: 4),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.shield, size: 16, color: Colors.green),
          ),
          SizedBox(width: 8),
          Text(
            'Familia',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF2D3142),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOtherChatsHeader() {
    return Padding(
      padding: EdgeInsets.only(bottom: 12, left: 4),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Color(0xFF9D7FE8).withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.people, size: 16, color: Color(0xFF9D7FE8)),
          ),
          SizedBox(width: 8),
          Text(
            'Contactos',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF2D3142),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(dynamic timestamp) {
    if (timestamp == null) return '';

    final DateTime dateTime = (timestamp as Timestamp).toDate();
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays > 0) {
      if (difference.inDays == 1) return 'Ayer';
      return '${difference.inDays}d';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m';
    } else {
      return 'Ahora';
    }
  }

  Widget _buildGroupChatItem({
    required String groupId,
    required String groupName,
    required int memberCount,
    required String lastMessage,
    required int messageCount,
  }) {
    return GestureDetector(
      onTap: () {
        // TODO: Navegar a pantalla de chat de grupo
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Abriendo grupo: $groupName')),
        );
      },
      child: Container(
        margin: EdgeInsets.only(bottom: 8),
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: Color(0xFF4CAF50).withOpacity(0.2),
              child: Icon(
                Icons.group,
                color: Color(0xFF4CAF50),
                size: 28,
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          groupName,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF2D3142),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Color(0xFF4CAF50).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '$memberCount miembros',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF4CAF50),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(
                    lastMessage,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatItem({
    required String chatId,
    required String userId,
    required String name,
    required String lastMessage,
    required String time,
    required int unreadCount,
    required bool isOnline,
    String? photoURL,
    bool isParent = false,
    bool isEmpty = false,
  }) {
    return FutureBuilder<ChatBlockStatus>(
      future: _blockService.getChatBlockStatus(
        childId: _auth.currentUser!.uid,
        contactId: userId,
      ),
      builder: (context, blockSnapshot) {
        final isBlocked = blockSnapshot.data?.isBlocked ?? false;
        final blockReason = blockSnapshot.data?.displayReason ?? '';

        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ChatDetailScreen(
                  chatId: chatId,
                  contactId: userId,
                  contactName: name,
                ),
              ),
            );
          },
          child: Container(
            margin: EdgeInsets.only(bottom: 8),
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isBlocked
                  ? Colors.grey[200]
                  : unreadCount > 0
                  ? Color(0xFF9D7FE8).withOpacity(0.05)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Stack(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: isBlocked
                          ? Colors.grey[400]!.withOpacity(0.3)
                          : Color(0xFF9D7FE8).withOpacity(0.2),
                      backgroundImage: photoURL != null && photoURL.isNotEmpty
                          ? NetworkImage(photoURL)
                          : null,
                      child: photoURL == null || photoURL.isEmpty
                          ? Text(
                              name.isNotEmpty ? name[0].toUpperCase() : 'U',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: isBlocked
                                    ? Colors.grey[600]
                                    : Color(0xFF9D7FE8),
                              ),
                            )
                          : null,
                    ),
                    if (isOnline)
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: Colors.green,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                      ),
                  ],
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: isBlocked
                              ? Colors.grey[600]
                              : Color(0xFF2D3142),
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        isBlocked ? 'Chat bloqueado' : lastMessage,
                        style: TextStyle(
                          fontSize: 14,
                          color: isBlocked
                              ? Colors.grey[500]
                              : Colors.grey[600],
                          fontStyle: isBlocked
                              ? FontStyle.italic
                              : FontStyle.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Column(
                  children: [
                    if (isBlocked)
                      Icon(Icons.block, size: 16, color: Colors.grey[500]),
                    if (isBlocked) SizedBox(height: 4),
                    Text(
                      time,
                      style: TextStyle(
                        fontSize: 12,
                        color: isBlocked
                            ? Colors.grey[500]
                            : unreadCount > 0
                            ? Color(0xFF9D7FE8)
                            : Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildContactsScreen() {
    return Scaffold(
      appBar: AppBar(
        title: Text('Mis Contactos'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<List<String>>(
        stream: _permissionService.watchBidirectionallyApprovedContacts(
          _auth.currentUser?.uid ?? '',
        ),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.people_outline, size: 64, color: Colors.grey[300]),
                  SizedBox(height: 16),
                  Text(
                    'No tienes contactos con aprobación bidireccional',
                    style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Para chatear necesitas que ambos padres aprueben el contacto',
                    style: TextStyle(fontSize: 14, color: Colors.grey[500]),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          final contactIds = snapshot.data!;

          return ListView.builder(
            padding: EdgeInsets.all(16),
            itemCount: contactIds.length,
            itemBuilder: (context, index) {
              final contactId = contactIds[index];

              return FutureBuilder<DocumentSnapshot>(
                future: _firestore.collection('users').doc(contactId).get(),
                builder: (context, userSnapshot) {
                  if (!userSnapshot.hasData) {
                    return SizedBox();
                  }

                  final userData =
                      userSnapshot.data!.data() as Map<String, dynamic>?;
                  final name = userData?['name'] ?? 'Usuario';
                  final isOnline = userData?['isOnline'] ?? false;
                  final photoURL = userData?['photoURL'];

                  return _buildContactCard(
                    contactId: contactId,
                    name: name,
                    status: isOnline ? 'En línea' : 'Desconectado',
                    isOnline: isOnline,
                    photoURL: photoURL,
                  );
                },
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => AddContactScreen()),
          );
        },
        backgroundColor: Color(0xFF9D7FE8),
        child: Icon(Icons.person_add),
      ),
    );
  }

  Widget _buildContactCard({
    required String contactId,
    required String name,
    required String status,
    required bool isOnline,
    String? photoURL,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Stack(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: Color(0xFF9D7FE8).withOpacity(0.2),
                backgroundImage: photoURL != null && photoURL.isNotEmpty
                    ? NetworkImage(photoURL)
                    : null,
                child: photoURL == null || photoURL.isEmpty
                    ? Text(
                        name.isNotEmpty ? name[0].toUpperCase() : 'U',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF9D7FE8),
                        ),
                      )
                    : null,
              ),
              if (isOnline)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 4),
                Text(
                  status,
                  style: TextStyle(
                    fontSize: 14,
                    color: isOnline ? Colors.green : Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () {
              final chatId = _getChatId(_auth.currentUser!.uid, contactId);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ChatDetailScreen(
                    chatId: chatId,
                    contactId: contactId,
                    contactName: name,
                  ),
                ),
              );
            },
            icon: Icon(Icons.chat_bubble_outline, color: Color(0xFF9D7FE8)),
          ),
        ],
      ),
    );
  }

  String _getChatId(String user1, String user2) {
    final users = [user1, user2]..sort();
    return '${users[0]}_${users[1]}';
  }

  void _showAddContactDialog() {
    final TextEditingController phoneController = TextEditingController();
    final TextEditingController nameController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.person_add, color: Color(0xFF9D7FE8)),
            SizedBox(width: 8),
            Text('Agregar Contacto'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Solicita a tus padres que aprueben este contacto',
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
            ),
            SizedBox(height: 16),
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: 'Nombre del contacto',
                prefixIcon: Icon(Icons.person, color: Color(0xFF9D7FE8)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            SizedBox(height: 12),
            TextField(
              controller: phoneController,
              decoration: InputDecoration(
                labelText: 'Teléfono del contacto',
                prefixIcon: Icon(Icons.phone, color: Color(0xFF9D7FE8)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              keyboardType: TextInputType.phone,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (nameController.text.isEmpty || phoneController.text.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Por favor completa todos los campos'),
                    backgroundColor: Colors.orange,
                  ),
                );
                return;
              }

              try {
                await _firestore.collection('contact_requests').add({
                  'childId': _auth.currentUser!.uid,
                  'contactName': nameController.text.trim(),
                  'contactPhone': phoneController.text.trim(),
                  'status': 'pending',
                  'requestedAt': FieldValue.serverTimestamp(),
                });

                // Obtener todos los padres vinculados
                final userRoleService = UserRoleService();
                final linkedParents = await userRoleService.getLinkedParents(_auth.currentUser!.uid);

                // Enviar notificación a todos los padres
                for (final parentId in linkedParents) {
                  await NotificationService().sendContactRequestNotification(
                    parentId: parentId,
                    childName: _auth.currentUser?.displayName ?? 'Tu hijo',
                    contactName: nameController.text.trim(),
                  );
                }

                Navigator.pop(context);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Solicitud enviada a tus padres'),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Color(0xFF9D7FE8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text('Solicitar'),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileScreen() {
    return ChildProfileScreen();
  }
}

// Pantalla de detalle del chat
class ChatDetailScreen extends StatefulWidget {
  final String chatId;
  final String contactId;
  final String contactName;

  const ChatDetailScreen({
    super.key,
    required this.chatId,
    required this.contactId,
    required this.contactName,
  });

  @override
  State<ChatDetailScreen> createState() => _ChatDetailScreenState();
}

// Clases para mensajes optimistas
enum MessageStatus {
  sending,
  sent,
  error,
}

class PendingMessage {
  final String id;
  final String text;
  final DateTime timestamp;
  MessageStatus status;
  String? error;

  PendingMessage({
    required this.id,
    required this.text,
    required this.timestamp,
    this.status = MessageStatus.sending,
    this.error,
  });
}

class _ChatDetailScreenState extends State<ChatDetailScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final AIAnalysisService _aiService = AIAnalysisService();
  final ChatPermissionService _permissionService = ChatPermissionService();
  final ChatBlockService _blockService = ChatBlockService();

  // Lista de mensajes pendientes para envío optimista
  final List<PendingMessage> _pendingMessages = [];

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _retryMessage(PendingMessage pendingMessage) async {
    // Cambiar estado a "enviando"
    setState(() {
      pendingMessage.status = MessageStatus.sending;
      pendingMessage.error = null;
    });

    final messageText = pendingMessage.text;

    try {
      // Verificar si el chat está bloqueado
      final blockStatus = await _blockService.getChatBlockStatus(
        childId: _auth.currentUser!.uid,
        contactId: widget.contactId,
      );

      if (blockStatus.isBlocked) {
        setState(() {
          pendingMessage.status = MessageStatus.error;
          pendingMessage.error = 'Chat bloqueado';
        });
        return;
      }

      // Verificar permisos bidireccionales
      final permissionResult = await _permissionService.canUsersChat(
        _auth.currentUser!.uid,
        widget.contactId,
      );

      if (!permissionResult.isAllowed) {
        setState(() {
          pendingMessage.status = MessageStatus.error;
          pendingMessage.error = 'Sin permisos';
        });
        return;
      }

      // Enviar a Firestore
      await _firestore.collection('chats').doc(widget.chatId).set({
        'participants': [_auth.currentUser!.uid, widget.contactId],
        'lastMessage': messageText,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSender': _auth.currentUser!.uid,
      }, SetOptions(merge: true));

      await _firestore
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .add({
            'senderId': _auth.currentUser!.uid,
            'receiverId': widget.contactId,
            'text': messageText,
            'timestamp': FieldValue.serverTimestamp(),
            'isRead': false,
          });

      // Remover de pendientes cuando se envíe exitosamente
      setState(() {
        _pendingMessages.removeWhere((msg) => msg.id == pendingMessage.id);
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Mensaje reenviado exitosamente'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      print('Error reenviando mensaje: $e');
      setState(() {
        pendingMessage.status = MessageStatus.error;
        pendingMessage.error = 'Error al enviar';
      });
    }
  }

  void _sendMessage() async {
    if (_messageController.text.trim().isEmpty) return;

    final messageText = _messageController.text.trim();
    final messageId = DateTime.now().millisecondsSinceEpoch.toString();

    // 1. Crear mensaje pendiente y agregarlo a la lista INMEDIATAMENTE
    final pendingMessage = PendingMessage(
      id: messageId,
      text: messageText,
      timestamp: DateTime.now(),
    );

    setState(() {
      _pendingMessages.add(pendingMessage);
    });

    // 2. Limpiar el TextField
    _messageController.clear();

    // 3. Hacer scroll al final
    Future.delayed(Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });

    // 4. LUEGO verificar y enviar en background
    try {
      // Verificar si el chat está bloqueado
      print(
        '🔒 Verificando si el chat está bloqueado entre ${_auth.currentUser!.uid} y ${widget.contactId}',
      );
      final blockStatus = await _blockService.getChatBlockStatus(
        childId: _auth.currentUser!.uid,
        contactId: widget.contactId,
      );

      if (blockStatus.isBlocked) {
        print('❌ Chat bloqueado: ${blockStatus.reason}');
        // Marcar como error
        setState(() {
          pendingMessage.status = MessageStatus.error;
          pendingMessage.error = 'Chat bloqueado: ${blockStatus.displayReason}';
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'No puedes enviar mensajes. ${blockStatus.displayReason}',
              ),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 4),
            ),
          );
        }
        return;
      }

      // Verificar permisos bidireccionales
      print(
        '🔍 Verificando permisos bidireccionales entre ${_auth.currentUser!.uid} y ${widget.contactId}',
      );
      final permissionResult = await _permissionService.canUsersChat(
        _auth.currentUser!.uid,
        widget.contactId,
      );

      if (!permissionResult.isAllowed) {
        print('❌ Permisos no permitidos: ${permissionResult.missingApprovals}');

        String errorMessage = 'No puedes chatear con este contacto. ';
        if (permissionResult.missingApprovals != null &&
            permissionResult.missingApprovals!.isNotEmpty) {
          errorMessage += 'Faltan aprobaciones de padres.';
        } else if (permissionResult.error != null) {
          errorMessage += permissionResult.error!;
        }

        // Marcar como error
        setState(() {
          pendingMessage.status = MessageStatus.error;
          pendingMessage.error = errorMessage;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(errorMessage),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
        }
        return;
      }

      print('✅ Permisos bidireccionales confirmados, enviando mensaje');

      // Enviar a Firestore
      await _firestore.collection('chats').doc(widget.chatId).set({
        'participants': [_auth.currentUser!.uid, widget.contactId],
        'lastMessage': messageText,
        'lastMessageTime': FieldValue.serverTimestamp(),
        'lastMessageSender': _auth.currentUser!.uid,
      }, SetOptions(merge: true));

      await _firestore
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .add({
            'senderId': _auth.currentUser!.uid,
            'receiverId': widget.contactId,
            'text': messageText,
            'timestamp': FieldValue.serverTimestamp(),
            'isRead': false,
          });

      // 5. Cuando complete exitosamente, remover de pendientes
      print('✅ Mensaje enviado exitosamente, removiendo de pendientes');
      setState(() {
        _pendingMessages.removeWhere((msg) => msg.id == messageId);
      });
    } catch (e) {
      print('❌ Error enviando mensaje: $e');
      // Marcar como error
      setState(() {
        pendingMessage.status = MessageStatus.error;
        pendingMessage.error = 'Error al enviar';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al enviar mensaje'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ChatBlockStatus>(
      stream: _blockService.watchChatBlockStatus(
        childId: _auth.currentUser!.uid,
        contactId: widget.contactId,
      ),
      builder: (context, blockSnapshot) {
        final isBlocked = blockSnapshot.data?.isBlocked ?? false;
        final blockReason = blockSnapshot.data?.displayReason ?? '';

        return Scaffold(
          appBar: AppBar(
            backgroundColor: isBlocked ? Colors.grey[600] : Color(0xFF9D7FE8),
            foregroundColor: Colors.white,
            title: Row(
              children: [
                StreamBuilder<DocumentSnapshot>(
                  stream: _firestore
                      .collection('users')
                      .doc(widget.contactId)
                      .snapshots(),
                  builder: (context, snapshot) {
                    final userData = snapshot.hasData
                        ? snapshot.data!.data() as Map<String, dynamic>?
                        : null;
                    final photoURL = userData?['photoURL'];

                    return CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.white.withOpacity(0.3),
                      backgroundImage: photoURL != null && photoURL!.isNotEmpty
                          ? NetworkImage(photoURL!)
                          : null,
                      child: photoURL == null || photoURL!.isEmpty
                          ? Text(
                              widget.contactName.isNotEmpty
                                  ? widget.contactName[0].toUpperCase()
                                  : 'U',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : null,
                    );
                  },
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.contactName, style: TextStyle(fontSize: 16)),
                      StreamBuilder<DocumentSnapshot>(
                        stream: _firestore
                            .collection('users')
                            .doc(widget.contactId)
                            .snapshots(),
                        builder: (context, snapshot) {
                          if (!snapshot.hasData) return SizedBox();
                          final userData =
                              snapshot.data!.data() as Map<String, dynamic>?;
                          final isOnline = userData?['isOnline'] ?? false;
                          return Text(
                            isOnline ? 'En línea' : 'Desconectado',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              if (!isBlocked)
                IconButton(
                  icon: Icon(Icons.phone, color: Colors.white),
                  onPressed: () async {
                    try {
                      final videoCallService = VideoCallService();
                      final currentUserId = _auth.currentUser!.uid;

                      // Obtener nombre del usuario actual
                      final currentUserDoc = await _firestore
                          .collection('users')
                          .doc(currentUserId)
                          .get();
                      final currentUserName = currentUserDoc.data()?['name'] ?? 'Usuario';

                      // Iniciar la llamada de audio
                      final callId = await videoCallService.startAudioCall(
                        callerId: currentUserId,
                        callerName: currentUserName,
                        receiverId: widget.contactId,
                        receiverName: widget.contactName,
                      );

                      // Obtener el nombre del canal desde Firestore
                      final callDoc = await _firestore.collection('video_calls').doc(callId).get();
                      final channelName = callDoc.data()?['channelName'] ?? callId;

                      // Generar token de Agora desde Cloud Function
                      print('🎫 Generando token de Agora para audio...');
                      final callable = FirebaseFunctions.instance.httpsCallable('generateAgoraToken');
                      final result = await callable.call({
                        'channelName': channelName,
                        'uid': currentUserId.hashCode,
                      });

                      final token = result.data['token'];
                      print('✅ Token generado: ${token.substring(0, 20)}...');

                      // Navegar a la pantalla de llamada de audio
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => AudioCallScreen(
                            callId: callId,
                            channelName: channelName,
                            token: token,
                            uid: currentUserId.hashCode,
                            isCaller: true,
                            remoteName: widget.contactName,
                          ),
                        ),
                      );
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error iniciando llamada: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  },
                  tooltip: 'Llamada de audio',
                ),
              if (!isBlocked)
                IconButton(
                  icon: Icon(Icons.videocam, color: Colors.white),
                  onPressed: () async {
                    try {
                      final videoCallService = VideoCallService();
                      final currentUserId = _auth.currentUser!.uid;

                      // Obtener nombre del usuario actual
                      final currentUserDoc = await _firestore
                          .collection('users')
                          .doc(currentUserId)
                          .get();
                      final currentUserName = currentUserDoc.data()?['name'] ?? 'Usuario';

                      // Iniciar la videollamada
                      final callId = await videoCallService.startCall(
                        callerId: currentUserId,
                        callerName: currentUserName,
                        receiverId: widget.contactId,
                        receiverName: widget.contactName,
                      );

                      // Obtener el nombre del canal desde Firestore
                      final callDoc = await _firestore.collection('video_calls').doc(callId).get();
                      final channelName = callDoc.data()?['channelName'] ?? callId;

                      // Generar token de Agora desde Cloud Function
                      print('🎫 Generando token de Agora...');
                      final callable = FirebaseFunctions.instance.httpsCallable('generateAgoraToken');
                      final result = await callable.call({
                        'channelName': channelName,
                        'uid': currentUserId.hashCode,
                      });

                      final token = result.data['token'];
                      print('✅ Token generado: ${token.substring(0, 20)}...');

                      // Navegar a la pantalla de videollamada
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => VideoCallScreen(
                            callId: callId,
                            channelName: channelName,
                            token: token,
                            uid: currentUserId.hashCode,
                            isCaller: true,
                            remoteName: widget.contactName,
                          ),
                        ),
                      );
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Error iniciando videollamada: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  },
                  tooltip: 'Videollamada',
                ),
            ],
          ),
          body: isBlocked
              ? _buildBlockedChatBody(blockReason)
              : Column(
                  children: [
                    Expanded(
                      child: StreamBuilder<QuerySnapshot>(
                        stream: _firestore
                            .collection('chats')
                            .doc(widget.chatId)
                            .collection('messages')
                            .orderBy('timestamp', descending: false)
                            .snapshots(),
                        builder: (context, snapshot) {
                          if (snapshot.hasError) {
                            return Center(
                              child: Text('Error: ${snapshot.error}'),
                            );
                          }

                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return Center(child: CircularProgressIndicator());
                          }

                          // Solo mostrar mensaje vacío si no hay mensajes de Firestore NI pendientes
                          if ((!snapshot.hasData ||
                              snapshot.data!.docs.isEmpty) && _pendingMessages.isEmpty) {
                            return Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.chat_bubble_outline,
                                    size: 64,
                                    color: Colors.grey[300],
                                  ),
                                  SizedBox(height: 16),
                                  Text(
                                    'Comienza una conversación',
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: Colors.grey[600],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }

                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (_scrollController.hasClients) {
                              _scrollController.jumpTo(
                                _scrollController.position.maxScrollExtent,
                              );
                            }
                          });

                          // Combinar mensajes de Firestore + mensajes pendientes
                          final firestoreMessages = snapshot.data?.docs ?? [];
                          final totalCount = firestoreMessages.length + _pendingMessages.length;

                          return ListView.builder(
                            controller: _scrollController,
                            padding: EdgeInsets.all(16),
                            itemCount: totalCount,
                            itemBuilder: (context, index) {
                              // Primero mostrar mensajes de Firestore
                              if (index < firestoreMessages.length) {
                                final messageDoc = firestoreMessages[index];
                                final messageData =
                                    messageDoc.data() as Map<String, dynamic>;
                                final isMe =
                                    messageData['senderId'] ==
                                    _auth.currentUser!.uid;
                                final timestamp =
                                    messageData['timestamp'] as Timestamp?;
                                final timeString = timestamp != null
                                    ? '${timestamp.toDate().hour}:${timestamp.toDate().minute.toString().padLeft(2, '0')}'
                                    : '';

                                return _buildMessageBubble(
                                  text: messageData['text'] ?? '',
                                  isMe: isMe,
                                  time: timeString,
                                );
                              }

                              // Luego mostrar mensajes pendientes
                              final pendingIndex = index - firestoreMessages.length;
                              final pendingMsg = _pendingMessages[pendingIndex];
                              final timeString =
                                  '${pendingMsg.timestamp.hour}:${pendingMsg.timestamp.minute.toString().padLeft(2, '0')}';

                              return _buildMessageBubble(
                                text: pendingMsg.text,
                                isMe: true, // Siempre es el usuario actual
                                time: timeString,
                                status: pendingMsg.status,
                                error: pendingMsg.error,
                                onRetry: pendingMsg.status == MessageStatus.error
                                    ? () => _retryMessage(pendingMsg)
                                    : null,
                              );
                            },
                          );
                        },
                      ),
                    ),
                    _buildMessageInput(),
                  ],
                ),
        );
      },
    );
  }

  /// Construye la interfaz cuando el chat está bloqueado
  Widget _buildBlockedChatBody(String reason) {
    return Container(
      decoration: BoxDecoration(color: Colors.grey[100]),
      child: Column(
        children: [
          // Mostrar mensajes existentes pero en gris/deshabilitado
          Expanded(
            child: ColorFiltered(
              colorFilter: ColorFilter.mode(
                Colors.grey.withOpacity(0.6),
                BlendMode.color,
              ),
              child: StreamBuilder<QuerySnapshot>(
                stream: _firestore
                    .collection('chats')
                    .doc(widget.chatId)
                    .collection('messages')
                    .orderBy('timestamp', descending: false)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(child: Text('Error: ${snapshot.error}'));
                  }

                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return Center(
                      child: CircularProgressIndicator(color: Colors.grey),
                    );
                  }

                  if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.block, size: 64, color: Colors.grey[400]),
                          SizedBox(height: 16),
                          Text(
                            'Chat bloqueado',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey[600],
                            ),
                          ),
                          SizedBox(height: 8),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 40),
                            child: Text(
                              reason,
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey[500],
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  return ListView.builder(
                    controller: _scrollController,
                    padding: EdgeInsets.all(16),
                    itemCount: snapshot.data!.docs.length,
                    itemBuilder: (context, index) {
                      final message = snapshot.data!.docs[index];
                      final data = message.data() as Map<String, dynamic>;
                      final isMe = data['senderId'] == _auth.currentUser!.uid;
                      final text = data['text'] ?? '';
                      final timestamp = data['timestamp'] as Timestamp?;

                      return Opacity(
                        opacity: 0.5, // Hacer mensajes semi-transparentes
                        child: _buildMessageBubble(
                          text: text,
                          isMe: isMe,
                          time: timestamp != null
                              ? '${timestamp.toDate().hour}:${timestamp.toDate().minute.toString().padLeft(2, '0')}'
                              : '',
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),

          // Mensaje de bloqueo y input deshabilitado
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.red[50],
              border: Border(
                top: BorderSide(color: Colors.red[200]!, width: 1),
              ),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(Icons.block, color: Colors.red[600], size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Esta conversación ha sido bloqueada',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.red[700],
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                Text(
                  reason,
                  style: TextStyle(fontSize: 12, color: Colors.red[600]),
                ),
                SizedBox(height: 16),

                // Input deshabilitado
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          enabled: false,
                          decoration: InputDecoration(
                            hintText: 'No puedes enviar mensajes',
                            hintStyle: TextStyle(color: Colors.grey[500]),
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                      Icon(Icons.send, color: Colors.grey[400]),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble({
    required String text,
    required bool isMe,
    required String time,
    MessageStatus? status,
    String? error,
    VoidCallback? onRetry,
  }) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Container(
            margin: EdgeInsets.only(bottom: 4),
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7,
            ),
            decoration: BoxDecoration(
              color: isMe ? Color(0xFF9D7FE8) : Colors.grey[200],
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomLeft: isMe ? Radius.circular(16) : Radius.circular(4),
                bottomRight: isMe ? Radius.circular(4) : Radius.circular(16),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    color: isMe ? Colors.white : Colors.black87,
                    fontSize: 15,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  time,
                  style: TextStyle(
                    color: isMe ? Colors.white70 : Colors.grey[600],
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          // Indicador de estado para mensajes pendientes
          if (status != null) _buildStatusIndicator(status, error, onRetry),
          SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildStatusIndicator(MessageStatus status, String? error, VoidCallback? onRetry) {
    switch (status) {
      case MessageStatus.sending:
        return Padding(
          padding: EdgeInsets.only(right: 16, top: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.grey[600]!),
                ),
              ),
              SizedBox(width: 6),
              Text(
                'Enviando...',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[600],
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        );
      case MessageStatus.sent:
        return Padding(
          padding: EdgeInsets.only(right: 16, top: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle, size: 12, color: Colors.green),
              SizedBox(width: 6),
              Text(
                'Enviado',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.green,
                ),
              ),
            ],
          ),
        );
      case MessageStatus.error:
        return Padding(
          padding: EdgeInsets.only(right: 16, top: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error, size: 12, color: Colors.red),
              SizedBox(width: 6),
              Text(
                error ?? 'Error',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.red,
                ),
              ),
              if (onRetry != null) ...[
                SizedBox(width: 8),
                GestureDetector(
                  onTap: onRetry,
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.red[50],
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.red[300]!),
                    ),
                    child: Text(
                      'Reintentar',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.red[700],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
    }
  }

  Future<void> _openARCamera() async {
    // Temporalmente deshabilitado para probar SMS
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('🎭 Filtros AR en desarrollo - Próximamente!'),
        backgroundColor: Colors.orange,
      ),
    );
  }

  Future<void> _sendImageMessage(String imagePath) async {
    try {
      // TODO: Implementar subida de imagen y envío como mensaje
      print('📸 Enviando imagen con filtro AR: $imagePath');

      // Por ahora, solo mostrar un mensaje de confirmación
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('¡Foto con filtro AR tomada! 🎭'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      print('❌ Error sending image message: $e');
    }
  }

  Widget _buildMessageInput() {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: Offset(0, -5),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: InputDecoration(
                        hintText: 'Escribe un mensaje...',
                        border: InputBorder.none,
                      ),
                      maxLines: null,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.face_retouching_natural,
                      color: Color(0xFF9D7FE8),
                    ),
                    onPressed: _openARCamera,
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.emoji_emotions_outlined,
                      color: Color(0xFF9D7FE8),
                    ),
                    onPressed: () {},
                  ),
                ],
              ),
            ),
          ),
          SizedBox(width: 8),
          Container(
            decoration: BoxDecoration(
              color: Color(0xFF9D7FE8),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: Icon(Icons.send, color: Colors.white),
              onPressed: _sendMessage,
            ),
          ),
        ],
      ),
    );
  }
}
