import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/contact_alias_service.dart';
import '../../services/video_call_service.dart';
import 'widgets/group_profile_constants.dart';
import 'widgets/group_profile_header.dart';
import 'widgets/group_member_tile.dart';
import 'widgets/add_members_dialog.dart';
import '../video_call_screen.dart';

class GroupProfileScreen extends StatefulWidget {
  final String groupId;

  const GroupProfileScreen({
    super.key,
    required this.groupId,
  });

  @override
  State<GroupProfileScreen> createState() => _GroupProfileScreenState();
}

class _GroupProfileScreenState extends State<GroupProfileScreen> {
  // ==================== SERVICIOS ====================
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final ContactAliasService _aliasService = ContactAliasService();
  final ImagePicker _picker = ImagePicker();
  final VideoCallService _videoCallService = VideoCallService();

  // ==================== ESTADO ====================
  final TextEditingController _nameController = TextEditingController();
  bool _isAdmin = false;
  bool _isEditing = false;
  bool _isUploading = false;
  String? _currentImageUrl;

  final Map<String, String> _userNames = {};
  final Map<String, String> _userPhotos = {};

  // ==================== LIFECYCLE ====================

  @override
  void initState() {
    super.initState();
    _loadGroupData();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  // ==================== LÓGICA DE NEGOCIO ====================

  Future<void> _loadGroupData() async {
    try {
      final groupDoc = await _firestore.collection('groups').doc(widget.groupId).get();
      final groupData = groupDoc.data();

      if (groupData == null) return;

      final admins = List<String>.from(groupData['admins'] ?? []);
      final currentUserId = _auth.currentUser!.uid;

      setState(() {
        _nameController.text = groupData['name'] ?? '';
        _currentImageUrl = groupData['avatar'];
        _isAdmin = admins.contains(currentUserId);
      });

      final members = List<String>.from(groupData['members'] ?? []);
      for (final memberId in members) {
        await _loadUserData(memberId);
      }
    } catch (e) {
      print('❌ Error cargando datos del grupo: $e');
    }
  }

  Future<void> _loadUserData(String userId) async {
    try {
      final userDoc = await _firestore.collection('users').doc(userId).get();
      final userData = userDoc.data();
      if (userData != null) {
        final realName = userData['name'] ?? 'Usuario';
        final displayName = await _aliasService.getDisplayName(userId, realName);
        setState(() {
          _userNames[userId] = displayName;
          _userPhotos[userId] = userData['photoURL'] ?? '';
        });
      }
    } catch (e) {
      print('❌ Error cargando usuario $userId: $e');
    }
  }

  Future<void> _pickAndUploadImage() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 80,
      );

      if (image == null) return;

      setState(() => _isUploading = true);

      final storageRef = _storage.ref().child('group_images/${widget.groupId}/${DateTime.now().millisecondsSinceEpoch}.jpg');
      await storageRef.putFile(File(image.path));
      final downloadUrl = await storageRef.getDownloadURL();

      await _firestore.collection('groups').doc(widget.groupId).update({
        'avatar': downloadUrl,
      });

      setState(() {
        _currentImageUrl = downloadUrl;
        _isUploading = false;
      });

      _showSuccessSnackbar('Imagen actualizada');
    } catch (e) {
      setState(() => _isUploading = false);
      _showErrorSnackbar('Error al actualizar imagen: $e');
    }
  }

  Future<void> _saveGroupName() async {
    if (_nameController.text.trim().isEmpty) {
      _showWarningSnackbar('El nombre no puede estar vacío');
      return;
    }

    try {
      await _firestore.collection('groups').doc(widget.groupId).update({
        'name': _nameController.text.trim(),
      });

      setState(() => _isEditing = false);
      _showSuccessSnackbar('Nombre actualizado');
    } catch (e) {
      _showErrorSnackbar('Error al actualizar nombre: $e');
    }
  }

  void _cancelEditing() {
    setState(() => _isEditing = false);
    _loadGroupData();
  }

  Future<void> _toggleAdmin(String userId, bool isCurrentlyAdmin) async {
    try {
      await _firestore.collection('groups').doc(widget.groupId).update(
        isCurrentlyAdmin
            ? {'admins': FieldValue.arrayRemove([userId])}
            : {'admins': FieldValue.arrayUnion([userId])},
      );

      await _loadGroupData();
      _showSuccessSnackbar(
        isCurrentlyAdmin ? 'Administrador removido' : 'Administrador agregado',
      );
    } catch (e) {
      _showErrorSnackbar('Error: $e');
    }
  }

  Future<void> _removeMember(String userId, String userName) async {
    final confirm = await _showRemoveMemberDialog(userName);
    if (confirm != true) return;

    try {
      final batch = _firestore.batch();
      final groupRef = _firestore.collection('groups').doc(widget.groupId);

      batch.update(groupRef, {
        'members': FieldValue.arrayRemove([userId]),
        'admins': FieldValue.arrayRemove([userId]),
        'pending_members': FieldValue.arrayRemove([userId]),
      });

      await batch.commit();
      await _loadGroupData();
      _showSuccessSnackbar('$userName eliminado del grupo');
    } catch (e) {
      _showErrorSnackbar('Error al eliminar miembro: $e');
    }
  }

  Future<void> _showAddMembersDialog(List<String> currentMembers) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AddMembersDialog(
        groupId: widget.groupId,
        currentMembers: currentMembers,
      ),
    );

    if (result == true) {
      await _loadGroupData();
      _showSuccessSnackbar('Miembros agregados correctamente');
    }
  }

  // ==================== VIDEOLLAMADAS GRUPALES ====================

  Future<void> _startGroupVideoCall(List<String> members) async {
    try {
      final currentUserId = _auth.currentUser!.uid;

      // Obtener datos del grupo
      final groupDoc = await _firestore.collection('groups').doc(widget.groupId).get();
      final groupData = groupDoc.data();

      if (groupData == null) {
        _showErrorSnackbar('Error: No se encontró el grupo');
        return;
      }

      // Filtrar participantes (excluir usuario actual)
      final participantIds = members.where((id) => id != currentUserId).toList();

      if (participantIds.isEmpty) {
        _showWarningSnackbar('No hay otros miembros en el grupo');
        return;
      }

      // Mostrar loading
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Center(
          child: CircularProgressIndicator(),
        ),
      );

      // Obtener nombre del usuario actual
      final currentUserDoc = await _firestore.collection('users').doc(currentUserId).get();
      final currentUserName = currentUserDoc.data()?['name'] ?? 'Usuario';

      // Construir mapa de nombres de participantes
      Map<String, String> participantNames = {};
      for (String participantId in participantIds) {
        final userDoc = await _firestore.collection('users').doc(participantId).get();
        participantNames[participantId] = userDoc.data()?['name'] ?? 'Usuario';
      }

      // Crear videollamada grupal
      final channelName = await _videoCallService.startGroupCall(
        callerId: currentUserId,
        callerName: currentUserName,
        participantIds: participantIds,
        participantNames: participantNames,
        groupId: widget.groupId,
        isEmergency: false,
      );

      // Obtener token de Agora directamente de Cloud Function (sin crear otra llamada)
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

        // Cerrar loading
        if (mounted) Navigator.pop(context);

        // Navegar a pantalla de videollamada
        if (mounted) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => VideoCallScreen(
                callId: channelName,
                channelName: channelName,
                token: token,
                uid: uid,
                isCaller: true,
                remoteName: groupData['name'] ?? 'Grupo',
                receiverId: widget.groupId, // ID del grupo para llamadas grupales
                isVideo: true,
              ),
            ),
          );
        }
      } catch (cloudFunctionError) {
        print('❌ Error generando token de Agora: $cloudFunctionError');

        // Cerrar loading
        if (mounted) Navigator.pop(context);

        _showErrorSnackbar('Error generando token de Agora: $cloudFunctionError');
      }
    } catch (e) {
      // Cerrar loading si está abierto
      if (mounted) Navigator.pop(context);
      _showErrorSnackbar('Error al iniciar videollamada: $e');
      print('❌ Error en _startGroupVideoCall: $e');
    }
  }

  // ==================== DIÁLOGOS ====================

  Future<bool?> _showRemoveMemberDialog(String userName) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Eliminar miembro'),
        content: Text('¿Estás seguro de que quieres eliminar a $userName del grupo?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text('Eliminar'),
          ),
        ],
      ),
    );
  }

  // ==================== SNACKBARS ====================

  void _showSuccessSnackbar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _showErrorSnackbar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _showWarningSnackbar(String message) {
    // Sin mensaje de advertencia
  }

  // ==================== WIDGETS ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: _buildBody(),
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: GroupProfileConstants.primaryColor,
      foregroundColor: Colors.white,
      title: Text('Perfil del grupo'),
      actions: _buildAppBarActions(),
    );
  }

  List<Widget>? _buildAppBarActions() {
    if (!_isAdmin) return null;

    if (_isEditing) {
      return [
        IconButton(
          icon: Icon(Icons.check),
          onPressed: _saveGroupName,
          tooltip: 'Guardar',
        ),
        IconButton(
          icon: Icon(Icons.close),
          onPressed: _cancelEditing,
          tooltip: 'Cancelar',
        ),
      ];
    }

    return [
      IconButton(
        icon: Icon(Icons.edit),
        onPressed: () => setState(() => _isEditing = true),
        tooltip: 'Editar',
      ),
    ];
  }

  Widget _buildBody() {
    return StreamBuilder<DocumentSnapshot>(
      stream: _firestore.collection('groups').doc(widget.groupId).snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Center(child: CircularProgressIndicator());
        }

        final groupData = snapshot.data!.data() as Map<String, dynamic>?;
        if (groupData == null) {
          return Center(child: Text('Grupo no encontrado'));
        }

        final members = List<String>.from(groupData['members'] ?? []);
        final admins = List<String>.from(groupData['admins'] ?? []);
        final pendingMembers = List<String>.from(groupData['pending_members'] ?? []);
        _currentImageUrl = groupData['avatar'];

        return SingleChildScrollView(
          child: Column(
            children: [
              GroupProfileHeader(
                groupData: groupData,
                memberCount: members.length + pendingMembers.length,
                isAdmin: _isAdmin,
                isEditing: _isEditing,
                isUploading: _isUploading,
                currentImageUrl: _currentImageUrl,
                nameController: _nameController,
                onPickImage: _pickAndUploadImage,
              ),
              _buildActionButtons(members),
              _buildMembersList(members, admins, pendingMembers),
            ],
          ),
        );
      },
    );
  }

  Widget _buildActionButtons(List<String> members) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: members.length > 1 ? () => _startGroupVideoCall(members) : null,
              icon: Icon(Icons.videocam, size: 24),
              label: Text(
                'Videollamada Grupal',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: GroupProfileConstants.primaryColor,
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey[300],
                disabledForegroundColor: Colors.grey[600],
                padding: EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMembersList(List<String> members, List<String> admins, List<String> pendingMembers) {
    return Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildMembersHeader(members),
          SizedBox(height: 16),
          // Miembros activos
          ...members.map((memberId) => _buildMemberTile(memberId, admins, isPending: false)),
          // Miembros pendientes
          if (pendingMembers.isNotEmpty) ...[
            SizedBox(height: 16),
            Text(
              'Pendientes de aprobación',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.orange[700],
              ),
            ),
            SizedBox(height: 8),
            ...pendingMembers.map((memberId) => _buildMemberTile(memberId, admins, isPending: true)),
          ],
        ],
      ),
    );
  }

  Widget _buildMembersHeader(List<String> members) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          'Miembros',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.grey[800],
          ),
        ),
        if (_isAdmin)
          ElevatedButton.icon(
            onPressed: () => _showAddMembersDialog(members),
            icon: Icon(Icons.person_add, size: 18),
            label: Text('Agregar'),
            style: ElevatedButton.styleFrom(
              backgroundColor: GroupProfileConstants.primaryColor,
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle: TextStyle(fontSize: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMemberTile(String memberId, List<String> admins, {required bool isPending}) {
    final isUserAdmin = admins.contains(memberId);
    final userName = _userNames[memberId] ?? 'Cargando...';
    final userPhoto = _userPhotos[memberId] ?? '';
    final isCurrentUser = memberId == _auth.currentUser!.uid;

    // Cargar datos del usuario si no están cargados
    if (!_userNames.containsKey(memberId)) {
      _loadUserData(memberId);
    }

    return GroupMemberTile(
      userId: memberId,
      userName: userName,
      userPhoto: userPhoto,
      isUserAdmin: isUserAdmin,
      isCurrentUser: isCurrentUser,
      canManage: _isAdmin && !isPending, // No se puede gestionar si está pendiente
      isPending: isPending,
      onToggleAdmin: () => _toggleAdmin(memberId, isUserAdmin),
      onRemoveMember: () => _removeMember(memberId, userName),
    );
  }
}
