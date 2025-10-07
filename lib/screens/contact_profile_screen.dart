import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import '../services/video_call_service.dart';
import '../services/block_service.dart';
import '../services/contact_alias_service.dart';
import '../models/user.dart';
import '../models/child.dart';

class ContactProfileScreen extends StatefulWidget {
  final String contactId;
  final String contactName;

  const ContactProfileScreen({
    super.key,
    required this.contactId,
    required this.contactName,
  });

  @override
  State<ContactProfileScreen> createState() => _ContactProfileScreenState();
}

class _ContactProfileScreenState extends State<ContactProfileScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  final VideoCallService _videoCallService = VideoCallService();
  final BlockService _blockService = BlockService();
  final ContactAliasService _aliasService = ContactAliasService();

  bool _isBlocked = false;
  bool _isLoadingBlockStatus = true;

  @override
  void initState() {
    super.initState();
    _checkBlockStatus();
  }

  Future<void> _checkBlockStatus() async {
    final blocked = await _blockService.isBlocked(widget.contactId);
    setState(() {
      _isBlocked = blocked;
      _isLoadingBlockStatus = false;
    });
  }

  Future<void> _toggleBlock() async {
    try {
      if (_isBlocked) {
        // Desbloquear
        final confirm = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Desbloquear contacto'),
            content: Text('¿Deseas desbloquear a ${widget.contactName}?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(backgroundColor: Color(0xFF9D7FE8)),
                child: Text('Desbloquear'),
              ),
            ],
          ),
        );

        if (confirm == true) {
          await _blockService.unblockContact(widget.contactId);
          setState(() {
            _isBlocked = false;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${widget.contactName} desbloqueado'),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      } else {
        // Bloquear
        final confirm = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Bloquear contacto'),
            content: Text(
              '¿Deseas bloquear a ${widget.contactName}?\n\n'
              'No podrás recibir mensajes ni llamadas de este contacto.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: Text('Bloquear'),
              ),
            ],
          ),
        );

        if (confirm == true) {
          await _blockService.blockContact(widget.contactId);
          setState(() {
            _isBlocked = true;
          });
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('${widget.contactName} bloqueado'),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }
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
  }

  String _getRoleLabel(String role) {
    switch (role) {
      case 'parent':
        return 'Padre/Madre';
      case 'child':
        return 'Hijo/a';
      case 'adult':
        return 'Adulto';
      default:
        return role;
    }
  }

  Future<void> _startVideoCall() async {
    try {
      final currentUserId = _auth.currentUser!.uid;

      // Obtener nombre del usuario actual
      final currentUserDoc = await _firestore
          .collection('users')
          .doc(currentUserId)
          .get();
      final currentUserName =
          currentUserDoc.data()?['name'] ?? 'Usuario';

      await _videoCallService.startCall(
        callerId: currentUserId,
        callerName: currentUserName,
        receiverId: widget.contactId,
        receiverName: widget.contactName,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Videollamada iniciada'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      print('Error iniciando videollamada: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al iniciar videollamada'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _showEditNameDialog(String currentName) async {
    final TextEditingController nameController = TextEditingController(text: currentName);

    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Editar nombre del contacto'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Puedes personalizar el nombre de este contacto. Solo tú verás este nombre.',
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
            ),
            SizedBox(height: 16),
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: 'Nombre personalizado',
                hintText: 'Ej: Papá, Mamá, Hermano...',
                border: OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(Icons.clear),
                  onPressed: () => nameController.clear(),
                ),
              ),
              autofocus: true,
              maxLength: 30,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancelar'),
          ),
          if (currentName != widget.contactName)
            TextButton(
              onPressed: () => Navigator.pop(context, '___RESTORE___'),
              child: Text('Restaurar original', style: TextStyle(color: Colors.orange)),
            ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, nameController.text.trim()),
            style: ElevatedButton.styleFrom(backgroundColor: Color(0xFF9D7FE8)),
            child: Text('Guardar'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      try {
        if (result == '___RESTORE___') {
          // Restaurar nombre original (eliminar alias)
          await _aliasService.removeAlias(widget.contactId);

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Nombre restaurado a "${widget.contactName}"'),
                backgroundColor: Colors.green,
              ),
            );
          }
        } else {
          // Guardar nuevo alias
          await _aliasService.setAlias(widget.contactId, result);

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Nombre actualizado a "$result"'),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error al guardar: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _startAudioCall() async {
    try {
      final currentUserId = _auth.currentUser!.uid;

      // Obtener nombre del usuario actual
      final currentUserDoc = await _firestore
          .collection('users')
          .doc(currentUserId)
          .get();
      final currentUserName =
          currentUserDoc.data()?['name'] ?? 'Usuario';

      await _videoCallService.startAudioCall(
        callerId: currentUserId,
        callerName: currentUserName,
        receiverId: widget.contactId,
        receiverName: widget.contactName,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Llamada de audio iniciada'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      print('Error iniciando llamada de audio: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al iniciar llamada'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: colorScheme.background,
      appBar: AppBar(
        title: Text('Perfil'),
        elevation: 0,
        actions: [
          if (!_isLoadingBlockStatus)
            PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'block') {
                  await _toggleBlock();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'block',
                  child: Row(
                    children: [
                      Icon(
                        _isBlocked ? Icons.check_circle : Icons.block,
                        color: _isBlocked ? Colors.green[700] : Colors.red[700],
                      ),
                      SizedBox(width: 8),
                      Text(
                        _isBlocked ? 'Desbloquear' : 'Bloquear',
                        style: TextStyle(
                          color: _isBlocked ? Colors.green[700] : Colors.red[700],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: _firestore.collection('users').doc(widget.contactId).snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(child: CircularProgressIndicator());
          }

          final userData = snapshot.data!.data() as Map<String, dynamic>?;

          if (userData == null) {
            return Center(child: Text('Usuario no encontrado'));
          }

          final photoURL = userData['photoURL'];
          final role = userData['role'] ?? 'adult';
          final isOnline = userData['isOnline'] ?? false;

          // Calculate age using User model
          final birthDate = User.parseBirthDate(userData['birthDate'] ?? userData['age']);
          final today = DateTime.now();
          int age = 0;
          if (birthDate != null) {
            age = (today.year - birthDate.year).toInt();
            if (today.month < birthDate.month ||
                (today.month == birthDate.month && today.day < birthDate.day)) {
              age--;
            }
          }

          return SingleChildScrollView(
            child: Column(
              children: [
                // Header con gradiente
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: isDarkMode
                          ? [
                              colorScheme.primary.withValues(alpha: 0.3),
                              colorScheme.primary.withValues(alpha: 0.2),
                            ]
                          : [
                              Color(0xFF9D7FE8),
                              Color(0xFFB39DDB),
                            ],
                    ),
                  ),
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Column(
                    children: [
                      // Avatar
                      Stack(
                        children: [
                          CircleAvatar(
                            radius: 60,
                            backgroundColor: Colors.white.withValues(alpha: 0.3),
                            backgroundImage: photoURL != null && photoURL!.isNotEmpty
                                ? NetworkImage(photoURL!)
                                : null,
                            child: photoURL == null || photoURL!.isEmpty
                                ? Text(
                                    widget.contactName.isNotEmpty
                                        ? widget.contactName[0].toUpperCase()
                                        : 'U',
                                    style: TextStyle(
                                      fontSize: 48,
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  )
                                : null,
                          ),
                          // Indicador de en línea
                          if (isOnline)
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: Colors.green,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 3),
                                ),
                              ),
                            ),
                        ],
                      ),

                      SizedBox(height: 16),

                      // Nombre con botón de edición
                      StreamBuilder<String>(
                        stream: _aliasService.watchDisplayName(widget.contactId, widget.contactName),
                        initialData: widget.contactName,
                        builder: (context, snapshot) {
                          final displayName = snapshot.data ?? widget.contactName;

                          return Column(
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    displayName,
                                    style: TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                  SizedBox(width: 8),
                                  IconButton(
                                    icon: Icon(Icons.edit, color: Colors.white70, size: 20),
                                    onPressed: () => _showEditNameDialog(displayName),
                                    tooltip: 'Editar nombre',
                                  ),
                                ],
                              ),
                              if (displayName != widget.contactName)
                                Padding(
                                  padding: EdgeInsets.only(top: 4),
                                  child: Text(
                                    'Nombre real: ${widget.contactName}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.white60,
                                      fontStyle: FontStyle.italic,
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),

                      SizedBox(height: 4),

                      // Estado
                      Text(
                        isOnline ? 'En línea' : 'Desconectado',
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),

                SizedBox(height: 20),

                // Botones de acción
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _startVideoCall,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: colorScheme.primary,
                            foregroundColor: colorScheme.onPrimary,
                            padding: EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: Icon(Icons.videocam),
                          label: Text('Video'),
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _startAudioCall,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green[700],
                            foregroundColor: Colors.white,
                            padding: EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: Icon(Icons.phone),
                          label: Text('Audio'),
                        ),
                      ),
                    ],
                  ),
                ),

                SizedBox(height: 20),

                // Información del usuario
                Container(
                  margin: EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 10,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      _buildInfoTile(
                        icon: Icons.cake_outlined,
                        label: 'Edad',
                        value: '$age años',
                      ),
                      Divider(height: 1),
                      _buildInfoTile(
                        icon: Icons.badge_outlined,
                        label: 'Rol',
                        value: _getRoleLabel(role),
                      ),
                    ],
                  ),
                ),

                // Mostrar padres si es un hijo
                if (role == 'child') ...[
                  SizedBox(height: 20),
                  Container(
                    margin: EdgeInsets.symmetric(horizontal: 20),
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.05),
                          blurRadius: 10,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Icon(
                                Icons.family_restroom,
                                color: colorScheme.primary,
                              ),
                              SizedBox(width: 12),
                              Text(
                                'Padres asociados',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Divider(height: 1),
                        FutureBuilder<List<Map<String, dynamic>>>(
                          future: Child(
                            id: widget.contactId,
                            name: widget.contactName,
                          ).getParents(),
                          builder: (context, parentsSnapshot) {
                            if (!parentsSnapshot.hasData) {
                              return Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(child: CircularProgressIndicator()),
                              );
                            }

                            final parents = parentsSnapshot.data!;

                            if (parents.isEmpty) {
                              return Padding(
                                padding: EdgeInsets.all(16),
                                child: Text(
                                  'Sin padres asociados',
                                  style: TextStyle(color: Colors.grey),
                                ),
                              );
                            }

                            return Column(
                              children: parents.map((parent) {
                                return ListTile(
                                  leading: CircleAvatar(
                                    backgroundColor: Color(0xFF9D7FE8).withValues(alpha: 0.2),
                                    backgroundImage: parent['photoURL'] != null &&
                                            parent['photoURL']!.isNotEmpty
                                        ? NetworkImage(parent['photoURL']!)
                                        : null,
                                    child: parent['photoURL'] == null ||
                                            parent['photoURL']!.isEmpty
                                        ? Text(
                                            parent['name'] != null && parent['name']!.isNotEmpty
                                                ? parent['name']![0].toUpperCase()
                                                : 'P',
                                            style: TextStyle(
                                              color: Color(0xFF9D7FE8),
                                              fontWeight: FontWeight.bold,
                                            ),
                                          )
                                        : null,
                                  ),
                                  title: Text(
                                    parent['name'] ?? 'Padre/Madre',
                                    style: TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                  trailing: Icon(
                                    Icons.check_circle,
                                    color: Colors.green,
                                    size: 20,
                                  ),
                                );
                              }).toList(),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],

                SizedBox(height: 40),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildInfoTile({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Color(0xFF9D7FE8).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              color: Color(0xFF9D7FE8),
              size: 24,
            ),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2D3142),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
