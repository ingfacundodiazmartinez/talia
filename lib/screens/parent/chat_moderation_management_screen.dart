import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../controllers/chat_moderation_management_controller.dart';
import '../../utils/release_logger.dart';

/// Modelo local para contacto con moderación
class _ContactWithModeration {
  final String contactId;
  final String childId;
  final String chatId;
  final String name;
  final String? photoURL;
  bool moderationEnabled;
  String moderationLevel;
  int blockedCount;
  int messageCount;
  bool hasMessages;
  String status;

  _ContactWithModeration({
    required this.contactId,
    required this.childId,
    required this.chatId,
    required this.name,
    this.photoURL,
    this.moderationEnabled = false,
    this.moderationLevel = 'high',
    this.blockedCount = 0,
    this.messageCount = 0,
    this.hasMessages = false,
    this.status = 'approved',
  });
}

/// Pantalla para gestionar moderación con IA de los contactos del hijo
///
/// OPTIMIZADO: Trae todos los datos una vez y filtra localmente
/// En lugar de 3 StreamBuilders por contacto (1200+ listeners para 400 contactos)
/// ahora usa batch reads + cache local
class ChatModerationManagementScreen extends StatefulWidget {
  const ChatModerationManagementScreen({super.key});

  @override
  State<ChatModerationManagementScreen> createState() =>
      _ChatModerationManagementScreenState();
}

class _ChatModerationManagementScreenState
    extends State<ChatModerationManagementScreen> {
  late ChatModerationManagementController _controller;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  bool _isLoading = true;
  List<String> _childrenIds = [];

  // Cache local de contactos por hijo
  final Map<String, List<_ContactWithModeration>> _contactsByChild = {};
  final Map<String, bool> _loadingByChild = {};

  // Filtros
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _filterStatus = 'all'; // 'all', 'active', 'inactive'

  @override
  void initState() {
    super.initState();
    _controller = ChatModerationManagementController();
    _loadLinkedChildren();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadLinkedChildren() async {
    try {
      final linkedChildrenIds = await _controller.loadLinkedChildren();

      if (mounted) {
        setState(() {
          _childrenIds = linkedChildrenIds;
          _isLoading = false;
        });
      }

      // Cargar contactos de cada hijo en paralelo
      for (final childId in linkedChildrenIds) {
        _loadContactsForChild(childId);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error cargando hijos vinculados: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Cargar todos los contactos de un hijo usando Cloud Function
  /// Esto evita problemas de permisos con Firestore Rules
  Future<void> _loadContactsForChild(String childId) async {
    if (_loadingByChild[childId] == true) return;

    setState(() {
      _loadingByChild[childId] = true;
    });

    try {
      ReleaseLogger.log('Cargando contactos para hijo $childId via Cloud Function', tag: 'ChatModerationScreen');

      // Llamar a la Cloud Function que tiene permisos de Admin
      final callable = FirebaseFunctions.instance.httpsCallable('getChildContactsForModeration');
      final result = await callable.call({'childId': childId});

      // Convertir el resultado a Map<String, dynamic> de forma segura
      final data = Map<String, dynamic>.from(result.data as Map);
      final success = data['success'] as bool? ?? false;

      if (!success) {
        throw Exception('La función retornó error');
      }

      final contactsList = (data['contacts'] as List<dynamic>?) ?? [];
      final List<_ContactWithModeration> contacts = [];

      for (final contactData in contactsList) {
        // Convertir cada contacto a Map<String, dynamic>
        final map = Map<String, dynamic>.from(contactData as Map);
        final status = map['status'] as String? ?? 'approved';

        // Solo mostrar contactos que no estén revocados
        if (status == 'revoked') continue;

        contacts.add(_ContactWithModeration(
          contactId: map['contactId'] as String,
          childId: map['childId'] as String,
          chatId: map['chatId'] as String,
          name: map['name'] as String? ?? 'Usuario',
          photoURL: map['photoURL'] as String?,
          moderationEnabled: map['moderationEnabled'] as bool? ?? false,
          moderationLevel: map['moderationLevel'] as String? ?? 'high',
          blockedCount: (map['blockedCount'] as num?)?.toInt() ?? 0,
          messageCount: (map['messageCount'] as num?)?.toInt() ?? 0,
          hasMessages: map['hasMessages'] as bool? ?? false,
          status: status,
        ));
      }

      ReleaseLogger.log('Cargados ${contacts.length} contactos para hijo $childId', tag: 'ChatModerationScreen');

      if (mounted) {
        setState(() {
          _contactsByChild[childId] = contacts;
          _loadingByChild[childId] = false;
        });
      }
    } catch (e) {
      ReleaseLogger.error('Error cargando contactos para hijo $childId: $e', tag: 'ChatModerationScreen');
      if (mounted) {
        setState(() {
          _loadingByChild[childId] = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error cargando contactos: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Filtrar contactos localmente
  List<_ContactWithModeration> _getFilteredContacts(String childId) {
    final contacts = _contactsByChild[childId] ?? [];

    return contacts.where((contact) {
      // Filtro por nombre
      if (_searchQuery.isNotEmpty) {
        if (!contact.name.toLowerCase().contains(_searchQuery)) {
          return false;
        }
      }

      // Filtro por estado
      if (_filterStatus == 'active' && !contact.moderationEnabled) {
        return false;
      }
      if (_filterStatus == 'inactive' && contact.moderationEnabled) {
        return false;
      }

      return true;
    }).toList();
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
        // Barra de búsqueda y filtros
        _buildSearchAndFilters(colorScheme, isDarkMode),
        const SizedBox(height: 16),
        // Card informativo sobre la moderación con IA
        _buildInfoCard(colorScheme),
        // Lista de hijos
        ...List.generate(
          _childrenIds.length,
          (index) => _buildChildCard(_childrenIds[index], colorScheme, isDarkMode),
        ),
      ],
    );
  }

  Widget _buildInfoCard(ColorScheme colorScheme) {
    return Card(
      color: colorScheme.primaryContainer.withValues(alpha: 0.3),
      margin: const EdgeInsets.only(bottom: 20),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, color: colorScheme.primary, size: 24),
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
              'La moderación con IA analiza automáticamente los mensajes para detectar:',
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
                  Icon(Icons.warning_amber_rounded, color: Colors.orange[700], size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Importante: La IA no es 100% precisa. Puede bloquear mensajes seguros o no detectar todo el contenido inapropiado.',
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
    );
  }

  Widget _buildSearchAndFilters(ColorScheme colorScheme, bool isDarkMode) {
    return Column(
      children: [
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            hintText: 'Buscar contacto por nombre...',
            prefixIcon: Icon(Icons.search, color: colorScheme.onSurfaceVariant),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.clear, color: colorScheme.onSurfaceVariant),
                    onPressed: () => _searchController.clear(),
                  )
                : null,
            filled: true,
            fillColor: isDarkMode
                ? colorScheme.surfaceContainerHighest
                : Colors.grey[100],
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildFilterChip(label: 'Todos', value: 'all', colorScheme: colorScheme),
              const SizedBox(width: 8),
              _buildFilterChip(label: 'Activos', value: 'active', colorScheme: colorScheme, icon: Icons.shield),
              const SizedBox(width: 8),
              _buildFilterChip(label: 'Inactivos', value: 'inactive', colorScheme: colorScheme, icon: Icons.shield_outlined),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFilterChip({
    required String label,
    required String value,
    required ColorScheme colorScheme,
    IconData? icon,
  }) {
    final isSelected = _filterStatus == value;
    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: isSelected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
          ],
          Text(label),
        ],
      ),
      selected: isSelected,
      onSelected: (selected) {
        setState(() {
          _filterStatus = selected ? value : 'all';
        });
      },
      selectedColor: colorScheme.primary,
      checkmarkColor: colorScheme.onPrimary,
      labelStyle: TextStyle(
        color: isSelected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
      ),
    );
  }

  Widget _buildBulletPoint(String text, ColorScheme colorScheme) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('• ', style: TextStyle(fontSize: 14, color: colorScheme.primary, fontWeight: FontWeight.bold)),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: colorScheme.onSurface.withValues(alpha: 0.8)),
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
              child: childPhotoURL != null
                  ? ClipOval(
                      child: CachedNetworkImage(
                        imageUrl: childPhotoURL,
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Icon(Icons.child_care, color: colorScheme.onPrimaryContainer),
                        errorWidget: (context, url, error) => Icon(Icons.child_care, color: colorScheme.onPrimaryContainer),
                      ),
                    )
                  : Icon(Icons.child_care, color: colorScheme.onPrimaryContainer),
            ),
            title: Text(
              childName,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            subtitle: const Text('Toca para ver sus contactos'),
            children: [
              _buildContactsList(childId, colorScheme, isDarkMode),
            ],
          ),
        );
      },
    );
  }

  Widget _buildContactsList(String childId, ColorScheme colorScheme, bool isDarkMode) {
    final isLoading = _loadingByChild[childId] ?? true;

    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final allContacts = _contactsByChild[childId] ?? [];
    final filteredContacts = _getFilteredContacts(childId);

    if (allContacts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'No tiene contactos aprobados aún',
          style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 14),
          textAlign: TextAlign.center,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text(
                '${filteredContacts.length} de ${allContacts.length} contactos',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.refresh, size: 20, color: colorScheme.primary),
                onPressed: () => _loadContactsForChild(childId),
                tooltip: 'Actualizar lista',
              ),
            ],
          ),
        ),
        if (filteredContacts.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'No hay contactos que coincidan con los filtros',
              style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: filteredContacts.length,
            itemBuilder: (context, index) {
              return _buildContactTile(filteredContacts[index], colorScheme);
            },
          ),
      ],
    );
  }

  Widget _buildContactTile(_ContactWithModeration contact, ColorScheme colorScheme) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: colorScheme.secondaryContainer,
              child: contact.photoURL != null
                  ? ClipOval(
                      child: CachedNetworkImage(
                        imageUrl: contact.photoURL!,
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        placeholder: (context, url) => Icon(Icons.person, color: colorScheme.onSecondaryContainer),
                        errorWidget: (context, url, error) => Icon(Icons.person, color: colorScheme.onSecondaryContainer),
                      ),
                    )
                  : Icon(Icons.person, color: colorScheme.onSecondaryContainer),
            ),
            title: Text(contact.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  contact.moderationEnabled
                      ? 'Moderación activa - Nivel: ${_getLevelLabel(contact.moderationLevel)}'
                      : 'Moderación desactivada',
                  style: TextStyle(
                    fontSize: 12,
                    color: contact.moderationEnabled ? Colors.green : colorScheme.onSurfaceVariant,
                  ),
                ),
                if (contact.blockedCount > 0)
                  Text(
                    '${contact.blockedCount} mensaje${contact.blockedCount > 1 ? 's' : ''} bloqueado${contact.blockedCount > 1 ? 's' : ''}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.orange,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                if (contact.hasMessages)
                  Text(
                    '${contact.messageCount} mensaje${contact.messageCount > 1 ? 's' : ''} en el chat',
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: contact.moderationEnabled,
                  onChanged: (value) => _toggleModeration(contact, value),
                ),
                PopupMenuButton<String>(
                  icon: Icon(Icons.more_vert, color: colorScheme.onSurfaceVariant),
                  onSelected: (value) {
                    if (value == 'revoke') {
                      _showRevokeConfirmation(contact, colorScheme);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'revoke',
                      child: Row(
                        children: [
                          Icon(Icons.block, color: Colors.red, size: 20),
                          const SizedBox(width: 8),
                          const Text('Revocar contacto', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
            onTap: () {
              Navigator.pushNamed(
                context,
                '/chat_moderation_settings',
                arguments: {
                  'chatId': contact.chatId,
                  'contactName': contact.name,
                },
              );
            },
          ),
          if (contact.moderationEnabled)
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
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
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
                    selected: {contact.moderationLevel},
                    onSelectionChanged: (Set<String> newSelection) {
                      _changeModerationLevel(contact, newSelection.first);
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _getLevelLabel(String level) {
    switch (level) {
      case 'high': return 'Alto';
      case 'medium': return 'Medio';
      case 'low': return 'Bajo';
      default: return 'Alto';
    }
  }

  Future<void> _toggleModeration(_ContactWithModeration contact, bool enabled) async {
    // Actualizar UI inmediatamente (optimistic update)
    setState(() {
      contact.moderationEnabled = enabled;
    });

    try {
      // Usar Cloud Function para evitar problemas de permisos
      final callable = FirebaseFunctions.instance.httpsCallable('updateChildContactModeration');
      final result = await callable.call({
        'childId': contact.childId,
        'contactId': contact.contactId,
        'chatId': contact.chatId,
        'enabled': enabled,
        'level': contact.moderationLevel,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      if (data['success'] != true) {
        throw Exception('Error al actualizar moderación');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              enabled
                  ? 'Moderación activada para ${contact.name}'
                  : 'Moderación desactivada para ${contact.name}',
            ),
            backgroundColor: enabled ? Colors.green : Colors.orange,
          ),
        );
      }
    } catch (e) {
      // Revertir cambio en caso de error
      setState(() {
        contact.moderationEnabled = !enabled;
      });

      ReleaseLogger.error('Error toggling moderation: $e', tag: 'ChatModerationScreen');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _changeModerationLevel(_ContactWithModeration contact, String level) async {
    final oldLevel = contact.moderationLevel;

    // Actualizar UI inmediatamente
    setState(() {
      contact.moderationLevel = level;
    });

    try {
      // Usar Cloud Function para evitar problemas de permisos
      final callable = FirebaseFunctions.instance.httpsCallable('updateChildContactModeration');
      final result = await callable.call({
        'childId': contact.childId,
        'contactId': contact.contactId,
        'chatId': contact.chatId,
        'enabled': contact.moderationEnabled,
        'level': level,
      });

      final data = Map<String, dynamic>.from(result.data as Map);
      if (data['success'] != true) {
        throw Exception('Error al actualizar nivel de moderación');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Nivel de moderación actualizado'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      // Revertir cambio en caso de error
      setState(() {
        contact.moderationLevel = oldLevel;
      });

      ReleaseLogger.error('Error changing moderation level: $e', tag: 'ChatModerationScreen');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Mostrar diálogo de confirmación para revocar contacto
  Future<void> _showRevokeConfirmation(_ContactWithModeration contact, ColorScheme colorScheme) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
            const SizedBox(width: 8),
            const Expanded(child: Text('Revocar contacto')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '¿Estás seguro de que quieres revocar el contacto de tu hijo con ${contact.name}?',
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Esto hará que:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  _buildWarningItem('El chat se bloqueará completamente'),
                  _buildWarningItem('Tu hijo no podrá enviar mensajes'),
                  _buildWarningItem('${contact.name} no podrá enviar mensajes'),
                  _buildWarningItem('Ambos recibirán una notificación'),
                ],
              ),
            ),
            if (contact.hasMessages) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.chat_bubble_outline, color: Colors.orange[700], size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Este chat tiene ${contact.messageCount} mensaje${contact.messageCount > 1 ? 's' : ''}',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.orange[800],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Revocar'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _revokeContact(contact);
    }
  }

  Widget _buildWarningItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• ', style: TextStyle(fontSize: 13, color: Colors.red)),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// Revocar contacto llamando a la Cloud Function
  Future<void> _revokeContact(_ContactWithModeration contact) async {
    // Mostrar loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final callable = FirebaseFunctions.instance.httpsCallable('revokeChildContact');
      final result = await callable.call({
        'childId': contact.childId,
        'contactId': contact.contactId,
      });

      // Cerrar loading
      if (mounted) Navigator.pop(context);

      final data = Map<String, dynamic>.from(result.data as Map);
      final success = data['success'] as bool? ?? false;
      final contactName = data['contactName'] as String? ?? contact.name;

      if (!mounted) return;

      if (success) {
        // Remover contacto de la lista local
        setState(() {
          _contactsByChild[contact.childId]?.removeWhere((c) => c.contactId == contact.contactId);
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Contacto con $contactName revocado'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        final message = data['message'] as String? ?? 'Error desconocido';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      // Cerrar loading si está abierto
      if (mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }

      ReleaseLogger.error('Error revocando contacto: $e', tag: 'ChatModerationScreen');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al revocar contacto: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
