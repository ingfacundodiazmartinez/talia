import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Pantalla para gestionar moderación con IA de los contactos del hijo
///
/// Permite al padre:
/// - Ver lista de contactos aprobados del hijo
/// - Activar/desactivar moderación por contacto
/// - Ver resumen de mensajes bloqueados
class ChatModerationManagementScreen extends StatefulWidget {
  const ChatModerationManagementScreen({super.key});

  @override
  State<ChatModerationManagementScreen> createState() =>
      _ChatModerationManagementScreenState();
}

class _ChatModerationManagementScreenState
    extends State<ChatModerationManagementScreen> {
  final _firestore = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  bool _isLoading = true;
  List<String> _childrenIds = [];

  @override
  void initState() {
    super.initState();
    _loadLinkedChildren();
  }

  Future<void> _loadLinkedChildren() async {
    try {
      final currentUserId = _auth.currentUser!.uid;

      // Obtener hijos vinculados
      final childrenSnapshot = await _firestore
          .collection('parent_children')
          .where('parentId', isEqualTo: currentUserId)
          .get();

      if (mounted) {
        setState(() {
          _childrenIds =
              childrenSnapshot.docs.map((doc) => doc['childId'] as String).toList();
          _isLoading = false;
        });
      }
    } catch (e) {
      print('❌ Error cargando hijos vinculados: $e');
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Moderación con IA'),
        backgroundColor: isDarkMode ? colorScheme.surface : colorScheme.primary,
        foregroundColor:
            isDarkMode ? colorScheme.onSurface : colorScheme.onPrimary,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _childrenIds.isEmpty
              ? _buildNoChildren(colorScheme)
              : _buildChildrenList(colorScheme, isDarkMode),
    );
  }

  Widget _buildNoChildren(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.family_restroom,
            size: 80,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'No tienes hijos vinculados',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Vincula a tu hijo para configurar la moderación',
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildChildrenList(ColorScheme colorScheme, bool isDarkMode) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Card informativo sobre la moderación con IA
        Card(
          color: colorScheme.primaryContainer.withValues(alpha: 0.3),
          margin: const EdgeInsets.only(bottom: 20),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: colorScheme.primary,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '¿Qué es la Moderación con IA?',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'La moderación con IA analiza automáticamente los mensajes usando Google Gemini para detectar:',
                  style: TextStyle(
                    fontSize: 14,
                    color: colorScheme.onSurface.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(height: 8),
                _buildBulletPoint('Bullying y acoso', colorScheme),
                _buildBulletPoint('Contenido sexual o inapropiado', colorScheme),
                _buildBulletPoint('Grooming y manipulación', colorScheme),
                _buildBulletPoint('Violencia o amenazas', colorScheme),
                _buildBulletPoint('Lenguaje ofensivo', colorScheme),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.orange.withValues(alpha: 0.3),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: Colors.orange[700],
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Importante: La IA no es 100% precisa. Puede bloquear mensajes seguros o no detectar todo el contenido inapropiado. Se recomienda mantener comunicación abierta con tus hijos.',
                          style: TextStyle(
                            fontSize: 12,
                            color: colorScheme.onSurface.withValues(alpha: 0.9),
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        // Lista de hijos
        ...List.generate(
          _childrenIds.length,
          (index) => _buildChildCard(_childrenIds[index], colorScheme, isDarkMode),
        ),
      ],
    );
  }

  Widget _buildBulletPoint(String text, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '• ',
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChildCard(String childId, ColorScheme colorScheme, bool isDarkMode) {
    return FutureBuilder<DocumentSnapshot>(
      future: _firestore.collection('users').doc(childId).get(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        final childData = snapshot.data!.data() as Map<String, dynamic>?;
        final childName = childData?['name'] ?? 'Usuario';
        final childPhotoURL = childData?['photoURL'] as String?;

        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          child: ExpansionTile(
            leading: CircleAvatar(
              radius: 24,
              backgroundColor: colorScheme.primaryContainer,
              backgroundImage:
                  childPhotoURL != null ? NetworkImage(childPhotoURL) : null,
              child: childPhotoURL == null
                  ? Icon(Icons.child_care, color: colorScheme.onPrimaryContainer)
                  : null,
            ),
            title: Text(
              childName,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            subtitle: const Text('Toca para ver sus contactos'),
            children: [
              _buildApprovedContactsList(childId, colorScheme, isDarkMode),
            ],
          ),
        );
      },
    );
  }

  Widget _buildApprovedContactsList(
    String childId,
    ColorScheme colorScheme,
    bool isDarkMode,
  ) {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('contact_requests')
          .where('childId', isEqualTo: childId)
          .where('status', isEqualTo: 'approved')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Error cargando contactos: ${snapshot.error}',
              style: TextStyle(color: colorScheme.error),
            ),
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          );
        }

        final approvedContacts = snapshot.data?.docs ?? [];

        if (approvedContacts.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'No tiene contactos aprobados aún',
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
          );
        }

        return ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: approvedContacts.length,
          itemBuilder: (context, index) {
            final contactDoc = approvedContacts[index];
            final contactData = contactDoc.data() as Map<String, dynamic>;
            final contactId = contactData['contactId'] as String;

            return _buildContactTile(
              childId: childId,
              contactId: contactId,
              colorScheme: colorScheme,
              isDarkMode: isDarkMode,
            );
          },
        );
      },
    );
  }

  Widget _buildContactTile({
    required String childId,
    required String contactId,
    required ColorScheme colorScheme,
    required bool isDarkMode,
  }) {
    // Generar chatId (mismo formato que en la app)
    final chatId = _ContactTileWidgetState._generateChatId(childId, contactId);

    return _ContactTileWidget(
      key: ValueKey(chatId), // Usar chatId como key para evitar reconstrucciones
      chatId: chatId,
      contactId: contactId,
      colorScheme: colorScheme,
      firestore: _firestore,
    );
  }
}

/// Widget separado para evitar reconstrucciones innecesarias del StreamBuilder
class _ContactTileWidget extends StatefulWidget {
  final String chatId;
  final String contactId;
  final ColorScheme colorScheme;
  final FirebaseFirestore firestore;

  const _ContactTileWidget({
    super.key,
    required this.chatId,
    required this.contactId,
    required this.colorScheme,
    required this.firestore,
  });

  @override
  State<_ContactTileWidget> createState() => _ContactTileWidgetState();
}

class _ContactTileWidgetState extends State<_ContactTileWidget> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool? _pendingModerationState; // Estado temporal mientras se actualiza

  static String _generateChatId(String userId1, String userId2) {
    final sortedIds = [userId1, userId2]..sort();
    return '${sortedIds[0]}_${sortedIds[1]}';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Importante: llamar a super.build cuando usas AutomaticKeepAliveClientMixin
    // Primero obtenemos los datos del usuario (contacto)
    return StreamBuilder<DocumentSnapshot>(
      stream: widget.firestore.collection('users').doc(widget.contactId).snapshots(),
      builder: (context, userSnapshot) {
        final userData = userSnapshot.data?.data() as Map<String, dynamic>?;
        final contactName = userData?['name'] ?? 'Usuario';
        final contactPhotoURL = userData?['photoURL'] as String?;

        // Luego obtenemos los datos del chat
        return StreamBuilder<DocumentSnapshot>(
          stream: widget.firestore.collection('chats').doc(widget.chatId).snapshots(),
          builder: (context, chatSnapshot) {
            final chatData = chatSnapshot.data?.data() as Map<String, dynamic>?;
            final serverModerationEnabled = chatData?['moderationEnabled'] ?? false;
            final serverModerationLevel = chatData?['moderationLevel'] ?? 'high';

            // Usar el estado pendiente si existe (durante actualización),
            // de lo contrario usar el valor del servidor
            // Solo usar serverModerationEnabled si tenemos datos válidos del snapshot
            final bool displayValue;
            if (_pendingModerationState != null) {
              // Hay una actualización pendiente, mostrar el estado pendiente
              displayValue = _pendingModerationState!;
            } else if (chatSnapshot.hasData && chatSnapshot.data != null && chatSnapshot.data!.exists) {
              // Tenemos datos válidos del servidor, usarlos
              displayValue = serverModerationEnabled;

              // Si el servidor confirmó el cambio, limpiar el estado pendiente
              if (_pendingModerationState != null && _pendingModerationState == serverModerationEnabled) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    setState(() {
                      _pendingModerationState = null;
                    });
                  }
                });
              }
            } else {
              // No hay datos válidos, mantener el estado pendiente o usar false por defecto
              displayValue = _pendingModerationState ?? false;
            }

            // Contar mensajes bloqueados
            return StreamBuilder<QuerySnapshot>(
              stream: widget.firestore
                  .collection('chats')
                  .doc(widget.chatId)
                  .collection('messages')
                  .where('moderationStatus', isEqualTo: 'blocked')
                  .snapshots(),
              builder: (context, blockedSnapshot) {
                final blockedCount = blockedSnapshot.data?.docs.length ?? 0;

                return Card(
                  margin: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Column(
                    children: [
                      ListTile(
                        leading: CircleAvatar(
                          backgroundColor: widget.colorScheme.secondaryContainer,
                          backgroundImage: contactPhotoURL != null ? NetworkImage(contactPhotoURL) : null,
                          child: contactPhotoURL == null
                              ? Icon(
                                  Icons.person,
                                  color: widget.colorScheme.onSecondaryContainer,
                                )
                              : null,
                        ),
                        title: Text(contactName),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              displayValue
                                  ? 'Moderación activa - Nivel: ${_getLevelLabel(serverModerationLevel)}'
                                  : 'Moderación desactivada',
                              style: TextStyle(
                                fontSize: 12,
                                color: displayValue ? Colors.green : widget.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (blockedCount > 0)
                              Text(
                                '$blockedCount mensaje${blockedCount > 1 ? 's' : ''} bloqueado${blockedCount > 1 ? 's' : ''}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.orange,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                          ],
                        ),
                        trailing: Switch(
                          value: displayValue,
                          onChanged: (value) {
                            // Actualizar estado pendiente inmediatamente para feedback visual
                            setState(() {
                              _pendingModerationState = value;
                            });

                            // Luego actualizar en el servidor
                            _toggleModeration(
                              context: context,
                              chatId: widget.chatId,
                              contactName: contactName,
                              enabled: value,
                              level: serverModerationLevel,
                              firestore: widget.firestore,
                            );
                          },
                        ),
                        onTap: () {
                          // Navegar a pantalla de detalles de moderación
                          Navigator.pushNamed(
                            context,
                            '/chat_moderation_settings',
                            arguments: {
                              'chatId': widget.chatId,
                              'contactName': contactName,
                            },
                          );
                        },
                      ),
                      // Selector de nivel (solo visible cuando moderación está activa)
                      if (displayValue)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Nivel de moderación',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: widget.colorScheme.onSurface,
                                ),
                              ),
                              SizedBox(height: 8),
                              SegmentedButton<String>(
                                segments: [
                                  ButtonSegment(
                                    value: 'high',
                                    label: Text('Alto', style: TextStyle(fontSize: 12)),
                                    icon: Icon(Icons.shield, size: 16),
                                  ),
                                  ButtonSegment(
                                    value: 'medium',
                                    label: Text('Medio', style: TextStyle(fontSize: 12)),
                                    icon: Icon(Icons.shield_moon, size: 16),
                                  ),
                                  ButtonSegment(
                                    value: 'low',
                                    label: Text('Bajo', style: TextStyle(fontSize: 12)),
                                    icon: Icon(Icons.shield_outlined, size: 16),
                                  ),
                                ],
                                selected: {serverModerationLevel},
                                onSelectionChanged: (Set<String> newSelection) {
                                  _changeModerationLevel(
                                    context: context,
                                    chatId: widget.chatId,
                                    level: newSelection.first,
                                    firestore: widget.firestore,
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  String _getLevelLabel(String level) {
    switch (level) {
      case 'high':
        return 'Alto';
      case 'medium':
        return 'Medio';
      case 'low':
        return 'Bajo';
      default:
        return 'Alto';
    }
  }

  static Future<void> _toggleModeration({
    required BuildContext context,
    required String chatId,
    required String contactName,
    required bool enabled,
    required String level,
    required FirebaseFirestore firestore,
  }) async {
    try {
      final currentUserId = FirebaseAuth.instance.currentUser!.uid;

      // Extraer los IDs de los participantes del chatId
      final participantIds = chatId.split('_');

      print('🔧 Toggle Moderation - chatId: $chatId');
      print('🔧 participantIds: $participantIds');
      print('🔧 enabled: $enabled (type: ${enabled.runtimeType})');
      print('🔧 level: $level');
      print('🔧 currentUserId: $currentUserId');

      // Asegurar que el documento del chat existe con los campos necesarios
      final updateData = {
        'participants': participantIds, // Necesario para las reglas de seguridad
        'moderationEnabled': enabled,
        'moderationLevel': level, // Guardar nivel
        'moderationParentId': enabled ? currentUserId : null,
        'moderationEnabledAt': enabled ? FieldValue.serverTimestamp() : null,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      print('🔧 Data to update: $updateData');

      await firestore.collection('chats').doc(chatId).set(
        updateData,
        SetOptions(merge: true),
      );

      print('✅ Update successful!');

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              enabled
                  ? 'Moderación activada para $contactName'
                  : 'Moderación desactivada para $contactName',
            ),
            backgroundColor: enabled ? Colors.green : Colors.orange,
          ),
        );
      }
    } catch (e) {
      print('❌ Error actualizando moderación: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  static Future<void> _changeModerationLevel({
    required BuildContext context,
    required String chatId,
    required String level,
    required FirebaseFirestore firestore,
  }) async {
    try {
      await firestore.collection('chats').doc(chatId).update({
        'moderationLevel': level,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      print('✅ Nivel de moderación actualizado: $level');

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Nivel de moderación actualizado'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print('❌ Error actualizando nivel: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
