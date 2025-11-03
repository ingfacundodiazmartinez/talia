import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../../../widgets/profile_photo_viewer.dart';
import '../../../services/video_call_service.dart';
import '../../video_call_screen.dart';

/// AppBar personalizado para pantallas de chat grupal
class GroupChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String groupId;
  final String groupName;
  final VoidCallback onTap;

  const GroupChatAppBar({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.onTap,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () {
          Navigator.of(context).pop();
        },
      ),
      title: InkWell(
        onTap: onTap,
        child: StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('groups')
              .doc(groupId)
              .snapshots(),
          builder: (context, snapshot) {
            final groupData = snapshot.data?.data() as Map<String, dynamic>?;
            final photoURL = groupData?['avatar'] as String? ?? '';
            final members = groupData?['members'] as List<dynamic>? ?? [];
            final memberCount = members.length;

            return Row(
              children: [
                // Avatar del grupo (clickeable para ver ampliado)
                ClickableAvatar(
                  photoUrl: photoURL.isNotEmpty ? photoURL : null,
                  name: groupName,
                  radius: 18,
                ),
                const SizedBox(width: 12),
                // Nombre y miembros
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        groupName,
                        style: const TextStyle(fontSize: 16),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '$memberCount miembros',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDarkMode
                              ? colorScheme.onSurface.withValues(alpha: 0.7)
                              : colorScheme.onPrimary.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('groups')
              .doc(groupId)
              .snapshots(),
          builder: (context, snapshot) {
            final groupData = snapshot.data?.data() as Map<String, dynamic>?;
            final members = List<String>.from(groupData?['members'] ?? []);
            final canStartCall = members.length > 1;

            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Botón de llamada de audio
                IconButton(
                  icon: const Icon(Icons.phone),
                  onPressed: canStartCall ? () => _startGroupAudioCall(context, members) : null,
                  tooltip: 'Llamada grupal',
                ),
                // Botón de videollamada
                IconButton(
                  icon: const Icon(Icons.videocam),
                  onPressed: canStartCall ? () => _startGroupVideoCall(context, members) : null,
                  tooltip: 'Videollamada grupal',
                ),
              ],
            );
          },
        ),
      ],
      backgroundColor: isDarkMode ? colorScheme.surface : colorScheme.primary,
      foregroundColor:
          isDarkMode ? colorScheme.onSurface : colorScheme.onPrimary,
    );
  }

  // ==================== VIDEOLLAMADAS GRUPALES ====================

  Future<void> _startGroupVideoCall(BuildContext context, List<String> members) async {
    await _startGroupCall(context, members, isVideo: true);
  }

  Future<void> _startGroupAudioCall(BuildContext context, List<String> members) async {
    await _startGroupCall(context, members, isVideo: false);
  }

  Future<void> _startGroupCall(BuildContext context, List<String> members, {required bool isVideo}) async {
    bool dialogShown = false;

    try {
      final currentUserId = FirebaseAuth.instance.currentUser!.uid;
      final firestore = FirebaseFirestore.instance;
      final videoCallService = VideoCallService();

      // Obtener datos del grupo
      final groupDoc = await firestore.collection('groups').doc(groupId).get();
      final groupData = groupDoc.data();

      if (groupData == null) {
        _showErrorSnackbar(context, 'Error: No se encontró el grupo');
        return;
      }

      // Filtrar participantes (excluir usuario actual)
      final participantIds = members.where((id) => id != currentUserId).toList();

      if (participantIds.isEmpty) {
        _showWarningSnackbar(context, 'No hay otros miembros en el grupo');
        return;
      }

      // Mostrar loading
      if (context.mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const Center(
            child: CircularProgressIndicator(),
          ),
        );
        dialogShown = true;
      }

      // Obtener nombre del usuario actual
      final currentUserDoc = await firestore.collection('users').doc(currentUserId).get();
      final currentUserName = currentUserDoc.data()?['name'] ?? 'Usuario';

      // Construir mapa de nombres de participantes
      Map<String, String> participantNames = {};
      for (String participantId in participantIds) {
        final userDoc = await firestore.collection('users').doc(participantId).get();
        participantNames[participantId] = userDoc.data()?['name'] ?? 'Usuario';
      }

      // Crear llamada grupal
      final channelName = isVideo
          ? await videoCallService.startGroupCall(
              callerId: currentUserId,
              callerName: currentUserName,
              participantIds: participantIds,
              participantNames: participantNames,
              groupId: groupId,
              isEmergency: false,
            )
          : await videoCallService.startGroupAudioCall(
              callerId: currentUserId,
              callerName: currentUserName,
              participantIds: participantIds,
              participantNames: participantNames,
              groupId: groupId,
              isEmergency: false,
            );

      // Obtener token de Agora
      print('🎫 Generando token de Agora para llamada grupal...');

      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('generateAgoraToken');

      try {
        final result = await callable.call({
          'channelName': channelName,
          'uid': 0, // 0 = Agora asigna automáticamente
        });

        final token = result.data['token'] as String;
        final uid = result.data['uid'] as int;

        print('✅ Token de Agora generado para llamada grupal');
        print('✅ UID asignado: $uid');

        // Navegar a pantalla de videollamada ANTES de cerrar loading
        if (context.mounted) {
          try {
            print('🚀 Navegando a VideoCallScreen...');
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => VideoCallScreen(
                  callId: channelName,
                  channelName: channelName,
                  token: token,
                  uid: uid,
                  isCaller: true,
                  remoteName: groupData['name'] ?? 'Grupo',
                  receiverId: groupId, // ID del grupo para llamadas grupales
                  isVideo: isVideo,
                ),
              ),
            );
            print('✅ Navegación a VideoCallScreen completada');
          } catch (navigationError) {
            print('❌ Error al navegar a VideoCallScreen: $navigationError');
            _showErrorSnackbar(context, 'Error al abrir videollamada: $navigationError');
          }
        }

        // Cerrar loading DESPUÉS de navegar
        if (dialogShown && context.mounted) {
          Navigator.pop(context);
          dialogShown = false;
          print('✅ Loading dialog cerrado');
        }
      } catch (cloudFunctionError) {
        print('❌ Error generando token de Agora: $cloudFunctionError');

        // Cerrar loading
        if (dialogShown && context.mounted) {
          Navigator.pop(context);
          dialogShown = false;
        }

        _showErrorSnackbar(context, 'Error generando token de Agora: $cloudFunctionError');
      }
    } catch (e) {
      // Cerrar loading si está abierto
      if (dialogShown && context.mounted) {
        Navigator.pop(context);
        dialogShown = false;
      }

      _showErrorSnackbar(context, 'Error al iniciar ${isVideo ? "videollamada" : "llamada"}: $e');
      print('❌ Error en _startGroupCall: $e');
    }
  }

  // ==================== SNACKBARS ====================

  void _showErrorSnackbar(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _showWarningSnackbar(BuildContext context, String message) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.orange),
    );
  }
}
