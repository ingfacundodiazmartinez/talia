import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:intl/intl.dart';
import '../services/block_service.dart';
import '../services/contact_alias_service.dart';
import '../services/favorite_service.dart';
import '../models/user.dart';
import '../models/child.dart';
import 'video_call_screen.dart';
import 'audio_call_screen.dart';
import '../widgets/profile_photo_viewer.dart';
import 'child/profile/widgets/media_gallery_widget.dart';

class ContactProfileScreen extends StatefulWidget {
  final String contactId;
  final String contactName;
  final String chatId;

  const ContactProfileScreen({
    super.key,
    required this.contactId,
    required this.contactName,
    required this.chatId,
  });

  @override
  State<ContactProfileScreen> createState() => _ContactProfileScreenState();
}

class _ContactProfileScreenState extends State<ContactProfileScreen>
    with TickerProviderStateMixin {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final BlockService _blockService = BlockService();
  final ContactAliasService _aliasService = ContactAliasService();

  bool _isBlocked = false;
  bool _isLoadingBlockStatus = true;

  // Tab controller para las pestañas
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _checkBlockStatus();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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
          // Contacto bloqueado - sin mensaje
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

  String _formatBirthday(DateTime? birthDate) {
    if (birthDate == null) return '';

    final months = {
      1: 'enero',
      2: 'febrero',
      3: 'marzo',
      4: 'abril',
      5: 'mayo',
      6: 'junio',
      7: 'julio',
      8: 'agosto',
      9: 'septiembre',
      10: 'octubre',
      11: 'noviembre',
      12: 'diciembre',
    };

    final day = birthDate.day;
    final month = months[birthDate.month] ?? '';

    return '$day de $month';
  }

  Future<void> _startVideoCall() async {
    if (!mounted) return;

    // LÓGICA OPTIMISTA: Abrir pantalla inmediatamente
    // El perfil se cierra automáticamente cuando se retorna de la videollamada
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => VideoCallScreen(
          callId: DateTime.now().millisecondsSinceEpoch.toString(),
          receiverId: widget.contactId,
          remoteName: widget.contactName,
          isCaller: true,
          isVideo: true,
          // Token y credenciales se obtienen en background
        ),
      ),
    );

    // Cerrar el perfil después de que termine la videollamada
    if (mounted) {
      Navigator.pop(context);
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
            SizedBox(height: 12),
            Container(
              padding: EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Borra todo el texto para restaurar el nombre original',
                      style: TextStyle(fontSize: 12, color: Colors.blue[800]),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),
            TextField(
              controller: nameController,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Nombre personalizado',
                hintText: 'Ej: Papá, Mamá, Hermano...',
                border: OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(Icons.clear),
                  onPressed: () => nameController.clear(),
                  tooltip: 'Borrar para restaurar nombre original',
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

    if (result != null) {
      try {
        // Verificar si el resultado está vacío O es el comando de restaurar
        final shouldRemoveAlias = result.isEmpty || result == '___RESTORE___';

        if (shouldRemoveAlias) {
          // Restaurar nombre original (eliminar alias)
          await _aliasService.removeAlias(widget.contactId);
          // El StreamBuilder se actualizará automáticamente
        } else {
          // Guardar nuevo alias
          await _aliasService.setAlias(widget.contactId, result);
          // El StreamBuilder se actualizará automáticamente
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
    if (!mounted) return;

    // LÓGICA OPTIMISTA: Abrir pantalla de AUDIO inmediatamente
    // El perfil se cierra automáticamente cuando se retorna de la llamada
    final callId = DateTime.now().millisecondsSinceEpoch.toString();

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AudioCallScreen(
          callId: callId,
          // No pasamos credenciales - se obtendrán en background
          channelName: null,
          token: null,
          uid: null,
          remoteName: widget.contactName,
          receiverId: widget.contactId, // Necesario para iniciar la llamada
          isCaller: true,
        ),
      ),
    );

    // Cerrar el perfil después de que termine la llamada
    if (mounted) {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: colorScheme.surface,
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

          // Usar User.age getter para calcular la edad
          final birthDate = User.parseBirthDate(userData['birthDate'] ?? userData['age']);
          final age = User.calculateAge(birthDate);

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
                      // Avatar (clickeable para ampliar)
                      Stack(
                        children: [
                          ClickableAvatar(
                            photoUrl: photoURL,
                            name: widget.contactName,
                            radius: 60,
                            backgroundColor: Colors.white.withValues(alpha: 0.3),
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
                            foregroundColor: Colors.white,
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
                        value: birthDate != null
                            ? '$age años (${_formatBirthday(birthDate)})'
                            : '$age años',
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
                                  leading: ClickableAvatar(
                                    photoUrl: parent['photoURL'] != null && parent['photoURL']!.isNotEmpty
                                        ? parent['photoURL']!
                                        : null,
                                    name: parent['name'] ?? 'Padre/Madre',
                                    radius: 20,
                                    backgroundColor: Color(0xFF9D7FE8).withValues(alpha: 0.2),
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

                // Tabs para Perfil y Favoritos
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
                    children: [
                      // Tab Bar
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(16),
                            topRight: Radius.circular(16),
                          ),
                        ),
                        child: TabBar(
                          controller: _tabController,
                          indicatorColor: colorScheme.primary,
                          labelColor: colorScheme.primary,
                          unselectedLabelColor: colorScheme.onSurfaceVariant,
                          indicatorWeight: 3,
                          dividerColor: Colors.transparent,
                          tabs: [
                            Tab(
                              icon: Icon(Icons.info_outline),
                              text: 'Perfil',
                            ),
                            Tab(
                              icon: Icon(Icons.star_outline),
                              text: 'Favoritos',
                            ),
                          ],
                        ),
                      ),
                      // Tab View
                      SizedBox(
                        height: 400, // Fixed height for the tab content
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            // Tab 1: Galería de medios (como estaba antes)
                            Padding(
                              padding: EdgeInsets.all(16),
                              child: MediaGalleryWidget(
                                chatId: widget.chatId,
                                isOwnProfile: false,
                              ),
                            ),
                            // Tab 2: Mensajes favoritos
                            _buildFavoritesTab(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                SizedBox(height: 40),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildFavoritesTab() {
    final colorScheme = Theme.of(context).colorScheme;

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: FavoriteService().getFavoriteMessagesStream(
        chatId: widget.chatId,
        isGroupChat: false, // Este es un chat 1-1 ya que es contact profile
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 40,
                  height: 40,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    valueColor: AlwaysStoppedAnimation<Color>(colorScheme.primary),
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  'Cargando favoritos...',
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          );
        }

        if (snapshot.hasError) {
          print('❌ Error cargando favoritos: ${snapshot.error}');
          return Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      Icons.error_outline_rounded,
                      color: Colors.red,
                      size: 48,
                    ),
                  ),
                  SizedBox(height: 20),
                  Text(
                    'Error al cargar favoritos',
                    style: TextStyle(
                      color: Colors.red,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    snapshot.error.toString(),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 12,
                    ),
                  ),
                  SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () {
                      // Trigger rebuild
                      setState(() {});
                    },
                    icon: Icon(Icons.refresh, size: 18),
                    label: Text('Reintentar'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colorScheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        final favoriteMessages = snapshot.data ?? [];

        if (favoriteMessages.isEmpty) {
          return Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: colorScheme.primary.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.star_border_rounded,
                      color: colorScheme.primary,
                      size: 48,
                    ),
                  ),
                  SizedBox(height: 24),
                  Text(
                    'Sin mensajes favoritos',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Los mensajes que marques como favoritos aparecerán aquí',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: colorScheme.onSurfaceVariant,
                      fontSize: 14,
                      height: 1.4,
                    ),
                  ),
                  SizedBox(height: 20),
                  Container(
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: colorScheme.outline.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          color: colorScheme.primary,
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Mantén presionado un mensaje para marcarlo como favorito',
                            style: TextStyle(
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return ListView.separated(
          padding: EdgeInsets.all(16),
          itemCount: favoriteMessages.length,
          separatorBuilder: (context, index) => SizedBox(height: 12),
          itemBuilder: (context, index) {
            final messageData = favoriteMessages[index];

            final text = messageData['text'] ?? '';
            final timestamp = messageData['timestamp'] as Timestamp?;
            final senderId = messageData['senderId'] ?? '';
            final isMe = senderId == firebase_auth.FirebaseAuth.instance.currentUser?.uid;
            final mediaType = messageData['mediaType'] as String?;
            final mediaUrl = messageData['mediaUrl'] as String?;

            final formattedTime = timestamp != null
                ? DateFormat('dd/MM/yyyy HH:mm').format(timestamp.toDate())
                : '';

            return Container(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Colors.amber.withValues(alpha: 0.3),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.amber.withValues(alpha: 0.1),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header con info del remitente y fecha
                  Row(
                    children: [
                      Container(
                        padding: EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.star,
                          color: Colors.amber[600],
                          size: 16,
                        ),
                      ),
                      SizedBox(width: 8),
                      Text(
                        isMe ? 'Tú' : widget.contactName,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: colorScheme.primary,
                          fontSize: 14,
                        ),
                      ),
                      Spacer(),
                      Text(
                        formattedTime,
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),

                  // Contenido del mensaje
                  if (mediaType != null && mediaUrl != null) ...[
                    // Mensaje con media
                    Row(
                      children: [
                        Icon(
                          mediaType == 'image'
                              ? Icons.image
                              : mediaType == 'video'
                                  ? Icons.videocam
                                  : Icons.audiotrack,
                          color: colorScheme.onSurfaceVariant,
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            mediaType == 'image'
                                ? 'Imagen'
                                : mediaType == 'video'
                                    ? 'Video'
                                    : 'Audio',
                            style: TextStyle(
                              fontStyle: FontStyle.italic,
                              color: colorScheme.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (text.isNotEmpty) ...[
                      SizedBox(height: 4),
                      Text(
                        text,
                        style: TextStyle(
                          fontSize: 14,
                          color: colorScheme.onSurface,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ] else if (text.isNotEmpty) ...[
                    // Solo texto
                    Text(
                      text,
                      style: TextStyle(
                        fontSize: 14,
                        color: colorScheme.onSurface,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildInfoTile({
    required IconData icon,
    required String label,
    required String value,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              color: colorScheme.primary,
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
                    color: isDarkMode ? Colors.grey[400] : Colors.grey[600],
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
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
