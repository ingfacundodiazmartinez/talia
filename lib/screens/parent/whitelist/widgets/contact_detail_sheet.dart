import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../models/grouped_contact.dart';
import '../../../../controllers/whitelist_controller.dart';
import '../../../../services/whitelist/get_contact_moderation_service.dart';
import '../../../../services/whitelist/update_contact_moderation_service.dart';
import '../../../../utils/release_logger.dart';

/// Bottom sheet con detalle del contacto y configuración de moderación
///
/// Muestra:
/// - Info del contacto (nombre, foto, teléfono)
/// - Lista de relaciones con cada hijo
/// - Acciones por estado (aprobar/rechazar/revocar)
/// - Toggle y nivel de moderación para aprobados
class ContactDetailSheet extends StatefulWidget {
  final GroupedContact contact;
  final WhitelistController controller;
  final Function(ChildRelation relation) onApprove;
  final Function(ChildRelation relation) onReject;
  final Function(ChildRelation relation) onRevoke;
  final Function(ChildRelation relation) onReApprove;

  const ContactDetailSheet({
    super.key,
    required this.contact,
    required this.controller,
    required this.onApprove,
    required this.onReject,
    required this.onRevoke,
    required this.onReApprove,
  });

  /// Mostrar el bottom sheet
  static Future<void> show({
    required BuildContext context,
    required GroupedContact contact,
    required WhitelistController controller,
    required Function(ChildRelation relation) onApprove,
    required Function(ChildRelation relation) onReject,
    required Function(ChildRelation relation) onRevoke,
    required Function(ChildRelation relation) onReApprove,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ContactDetailSheet(
        contact: contact,
        controller: controller,
        onApprove: onApprove,
        onReject: onReject,
        onRevoke: onRevoke,
        onReApprove: onReApprove,
      ),
    );
  }

  @override
  State<ContactDetailSheet> createState() => _ContactDetailSheetState();
}

class _ContactDetailSheetState extends State<ContactDetailSheet> {
  // Services
  final GetContactModerationService _getModerationService = GetContactModerationService();
  final UpdateContactModerationService _updateModerationService = UpdateContactModerationService();

  // Estado de moderación por hijo (childId -> {enabled, level})
  final Map<String, Map<String, dynamic>> _moderationState = {};
  final Map<String, bool> _loadingModeration = {};

  @override
  void initState() {
    super.initState();
    // Cargar moderación solo para contactos (no grupos)
    // La carga es en background - no bloquea la UI
    _loadModerationStateAsync();
  }

  /// Cargar moderación en background (solo para contactos, no grupos)
  Future<void> _loadModerationStateAsync() async {
    for (final relation in widget.contact.childRelations) {
      // Solo cargar moderación para contactos aprobados (no grupos)
      if (relation.status == 'approved' && relation.type != 'group_v2') {
        // Inicializar con estado de carga
        if (mounted) {
          setState(() {
            _loadingModeration[relation.childId] = true;
          });
        }
        await _loadModerationForChild(relation);
      }
    }
  }

  Future<void> _loadModerationForChild(ChildRelation relation) async {
    try {
      final result = await _getModerationService.call(
        childId: relation.childId,
        contactId: widget.contact.contactId,
      );

      if (result.success) {
        if (mounted) {
          setState(() {
            _moderationState[relation.childId] = {
              'enabled': result.enabled,
              'level': result.moderationLevel ?? 'medium',
            };
            _loadingModeration[relation.childId] = false;
          });
        }
      }
    } catch (e) {
      ReleaseLogger.error('Error cargando moderación: $e', tag: 'ContactDetailSheet');
      // Establecer valores por defecto
      if (mounted) {
        setState(() {
          _moderationState[relation.childId] = {
            'enabled': false,
            'level': 'medium',
          };
          _loadingModeration[relation.childId] = false;
        });
      }
    }
  }

  Future<void> _toggleModeration(ChildRelation relation, bool enabled) async {
    final state = _moderationState[relation.childId];
    if (state == null) return;

    setState(() {
      _loadingModeration[relation.childId] = true;
      _moderationState[relation.childId]!['enabled'] = enabled;
    });

    try {
      final result = await _updateModerationService.call(
        childId: relation.childId,
        contactId: widget.contact.contactId,
        moderationLevel: state['level'] ?? 'medium',
        enabled: enabled,
      );

      if (!result.success) {
        throw Exception(result.message);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(enabled
                ? 'Moderación activada para ${relation.childName}'
                : 'Moderación desactivada'),
            backgroundColor: enabled ? Colors.green : Colors.orange,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      // Revertir
      setState(() {
        _moderationState[relation.childId]!['enabled'] = !enabled;
      });
      ReleaseLogger.error('Error toggle moderation: $e', tag: 'ContactDetailSheet');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loadingModeration[relation.childId] = false);
      }
    }
  }

  Future<void> _changeModerationLevel(ChildRelation relation, String level) async {
    final state = _moderationState[relation.childId];
    if (state == null) return;

    final oldLevel = state['level'];
    setState(() {
      _loadingModeration[relation.childId] = true;
      _moderationState[relation.childId]!['level'] = level;
    });

    try {
      final result = await _updateModerationService.call(
        childId: relation.childId,
        contactId: widget.contact.contactId,
        moderationLevel: level,
        enabled: state['enabled'] ?? false,
      );

      if (!result.success) {
        throw Exception(result.message);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Nivel actualizado a ${_getLevelLabel(level)}'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      // Revertir
      setState(() {
        _moderationState[relation.childId]!['level'] = oldLevel;
      });
      ReleaseLogger.error('Error change level: $e', tag: 'ContactDetailSheet');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loadingModeration[relation.childId] = false);
      }
    }
  }

  String _getLevelLabel(String level) {
    switch (level) {
      case 'high': return 'Alto';
      case 'medium': return 'Medio';
      case 'low': return 'Bajo';
      default: return 'Alto';
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            margin: EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header con info del contacto
          _buildHeader(colorScheme),
          Divider(height: 1),
          // Lista de relaciones con hijos (se muestra inmediatamente)
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 8,
                bottom: 16 + bottomPadding,
              ),
              children: [
                ...widget.contact.childRelations.map((r) => _buildChildSection(r, colorScheme)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ColorScheme colorScheme) {
    return Padding(
      padding: EdgeInsets.all(16),
      child: Row(
        children: [
          // Avatar
          CircleAvatar(
            radius: 28,
            backgroundColor: _getStatusColor().withValues(alpha: 0.1),
            child: widget.contact.contactPhotoURL != null && widget.contact.contactPhotoURL!.isNotEmpty
                ? ClipOval(
                    child: CachedNetworkImage(
                      imageUrl: widget.contact.contactPhotoURL!,
                      width: 56,
                      height: 56,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => _buildInitial(colorScheme),
                      errorWidget: (_, __, ___) => _buildInitial(colorScheme),
                    ),
                  )
                : _buildInitial(colorScheme),
          ),
          SizedBox(width: 16),
          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.contact.contactName,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),
                if (widget.contact.contactPhone != null) ...[
                  SizedBox(height: 2),
                  Text(
                    widget.contact.contactPhone!,
                    style: TextStyle(
                      fontSize: 14,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Cerrar
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _buildInitial(ColorScheme colorScheme) {
    return Text(
      widget.contact.contactName.isNotEmpty
          ? widget.contact.contactName[0].toUpperCase()
          : 'U',
      style: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.bold,
        color: _getStatusColor(),
      ),
    );
  }

  Color _getStatusColor() {
    if (widget.contact.hasPending) return Colors.orange;
    if (widget.contact.hasApproved) return Colors.green;
    if (widget.contact.hasRevoked) return Colors.orange;
    return Colors.red;
  }

  Widget _buildChildSection(ChildRelation relation, ColorScheme colorScheme) {
    final isProcessing = widget.controller.processingRequests.contains(relation.contactDocId);
    final modState = _moderationState[relation.childId];
    final isLoadingMod = _loadingModeration[relation.childId] ?? false;

    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _getRelationColor(relation).withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: Foto del hijo + nombre + estado + acciones
          Row(
            children: [
              // Foto del hijo
              CircleAvatar(
                radius: 14,
                backgroundColor: colorScheme.primaryContainer,
                backgroundImage: relation.childPhotoURL != null && relation.childPhotoURL!.isNotEmpty
                    ? NetworkImage(relation.childPhotoURL!)
                    : null,
                child: relation.childPhotoURL == null || relation.childPhotoURL!.isEmpty
                    ? Text(
                        relation.childName.isNotEmpty ? relation.childName[0].toUpperCase() : '?',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: colorScheme.onPrimaryContainer,
                        ),
                      )
                    : null,
              ),
              SizedBox(width: 8),
              Text(
                relation.childName,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              SizedBox(width: 8),
              _buildStatusBadge(relation),
              Spacer(),
              if (isProcessing)
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                _buildActions(relation, colorScheme),
            ],
          ),
          // Moderación (solo para contactos aprobados, NO para grupos)
          if (relation.status == 'approved' && relation.type != 'group_v2') ...[
            SizedBox(height: 12),
            if (isLoadingMod && modState == null)
              // Mostrar placeholder compacto mientras carga
              _buildModerationLoading(colorScheme)
            else if (modState != null)
              _buildModerationSection(relation, modState, isLoadingMod, colorScheme),
          ],
        ],
      ),
    );
  }

  Color _getRelationColor(ChildRelation relation) {
    switch (relation.status) {
      case 'pending': return Colors.orange;
      case 'approved': return Colors.green;
      case 'rejected': return Colors.red;
      case 'revoked': return Colors.orange;
      default: return Colors.grey;
    }
  }

  Widget _buildStatusBadge(ChildRelation relation) {
    Color color;
    String text;
    IconData icon;

    switch (relation.status) {
      case 'pending':
        color = Colors.orange;
        text = 'Pendiente';
        icon = Icons.schedule;
        break;
      case 'approved':
        color = Colors.green;
        text = 'Aprobado';
        icon = Icons.check_circle;
        break;
      case 'rejected':
        color = Colors.red;
        text = 'Rechazado';
        icon = Icons.cancel;
        break;
      case 'revoked':
        color = Colors.orange;
        text = 'Revocado';
        icon = Icons.remove_circle;
        break;
      default:
        color = Colors.grey;
        text = '?';
        icon = Icons.help;
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(ChildRelation relation, ColorScheme colorScheme) {
    switch (relation.status) {
      case 'pending':
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildActionButton(
              icon: Icons.check,
              color: Colors.green,
              label: 'Aprobar',
              onTap: () {
                widget.onApprove(relation);
                Navigator.pop(context);
              },
            ),
            SizedBox(width: 8),
            _buildActionButton(
              icon: Icons.close,
              color: Colors.red,
              label: 'Rechazar',
              onTap: () {
                widget.onReject(relation);
                Navigator.pop(context);
              },
            ),
          ],
        );
      case 'approved':
        // No permitir que el padre se revoque a sí mismo como contacto
        final currentUserId = FirebaseAuth.instance.currentUser?.uid;
        final isParentContact = widget.contact.contactId == currentUserId;

        if (isParentContact) {
          // Mostrar indicador de que es el padre (no se puede revocar)
          return Container(
            padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.shield, size: 16, color: Colors.grey),
                SizedBox(width: 4),
                Text(
                  'Padre/Madre',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          );
        }

        // Para grupos, usar "Sacar del grupo" con su propia confirmación
        if (relation.type == 'group_v2') {
          return _buildActionButton(
            icon: Icons.group_remove,
            color: Colors.orange[700]!,
            label: 'Sacar',
            onTap: () {
              Navigator.pop(context);
              widget.onRevoke(relation);
            },
          );
        }

        // Para contactos normales, mostrar confirmación de revocación
        return _buildActionButton(
          icon: Icons.block,
          color: Colors.orange[700]!,
          label: 'Revocar',
          onTap: () => _showRevokeConfirmation(relation),
        );
      case 'rejected':
        return _buildActionButton(
          icon: Icons.refresh,
          color: Colors.green,
          label: 'Aprobar',
          onTap: () {
            widget.onReApprove(relation);
            Navigator.pop(context);
          },
        );
      case 'revoked':
        return _buildActionButton(
          icon: Icons.restore,
          color: Colors.green,
          label: 'Habilitar',
          onTap: () {
            widget.onReApprove(relation);
            Navigator.pop(context);
          },
        );
      default:
        return SizedBox.shrink();
    }
  }

  Widget _buildActionButton({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Placeholder compacto mientras carga la moderación
  Widget _buildModerationLoading(ColorScheme colorScheme) {
    return Row(
      children: [
        Icon(
          Icons.psychology,
          size: 16,
          color: colorScheme.onSurfaceVariant,
        ),
        SizedBox(width: 4),
        Text(
          'Mod. IA',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: colorScheme.onSurface,
          ),
        ),
        Spacer(),
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ],
    );
  }

  /// Sección compacta de moderación con selector único
  Widget _buildModerationSection(
    ChildRelation relation,
    Map<String, dynamic> modState,
    bool isLoading,
    ColorScheme colorScheme,
  ) {
    final enabled = modState['enabled'] as bool? ?? false;
    final level = modState['level'] as String? ?? 'medium';

    // Determinar el valor actual del selector (none si está desactivado)
    final currentValue = enabled ? level : 'none';

    return Row(
      children: [
        // Icono y texto compacto
        Icon(
          Icons.psychology,
          size: 16,
          color: colorScheme.onSurfaceVariant,
        ),
        SizedBox(width: 4),
        Text(
          'Mod. IA',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: colorScheme.onSurface,
          ),
        ),
        // Botón de ayuda más pequeño
        GestureDetector(
          onTap: () => _showModerationHelp(context),
          child: Padding(
            padding: EdgeInsets.all(4),
            child: Icon(
              Icons.help_outline,
              size: 14,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Spacer(),
        // Selector compacto
        if (isLoading)
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          _buildCompactLevelSelector(relation, currentValue, colorScheme),
      ],
    );
  }

  Widget _buildCompactLevelSelector(
    ChildRelation relation,
    String currentValue,
    ColorScheme colorScheme,
  ) {
    const aiColor = Color(0xFF5C6BC0);

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildLevelChip('high', 'Alto', currentValue, relation, aiColor, colorScheme),
          _buildLevelChip('medium', 'Medio', currentValue, relation, aiColor, colorScheme),
          _buildLevelChip('low', 'Bajo', currentValue, relation, aiColor, colorScheme),
          _buildLevelChip('none', 'No', currentValue, relation, aiColor, colorScheme),
        ],
      ),
    );
  }

  Widget _buildLevelChip(
    String value,
    String label,
    String currentValue,
    ChildRelation relation,
    Color aiColor,
    ColorScheme colorScheme,
  ) {
    final isSelected = currentValue == value;

    return GestureDetector(
      onTap: () => _setModerationLevel(relation, value),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? aiColor : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            color: isSelected ? Colors.white : colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// Cambiar nivel de moderación (incluyendo activar/desactivar)
  Future<void> _setModerationLevel(ChildRelation relation, String value) async {
    final state = _moderationState[relation.childId];
    if (state == null) return;

    final isNone = value == 'none';
    final newEnabled = !isNone;
    final newLevel = isNone ? 'medium' : value;

    setState(() {
      _loadingModeration[relation.childId] = true;
      _moderationState[relation.childId]!['enabled'] = newEnabled;
      _moderationState[relation.childId]!['level'] = newLevel;
    });

    try {
      final result = await _updateModerationService.call(
        childId: relation.childId,
        contactId: widget.contact.contactId,
        moderationLevel: newLevel,
        enabled: newEnabled,
      );

      if (!result.success) {
        throw Exception(result.message);
      }
    } catch (e) {
      // Revertir en caso de error
      ReleaseLogger.error('Error setModerationLevel: $e', tag: 'ContactDetailSheet');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loadingModeration[relation.childId] = false);
      }
    }
  }

  /// Mostrar diálogo de ayuda sobre moderación
  void _showModerationHelp(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.psychology, color: Color(0xFF5C6BC0)),
            SizedBox(width: 8),
            Text('Moderación con IA'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'La IA analiza los mensajes de este chat y te alerta si detecta contenido inapropiado.',
              style: TextStyle(fontSize: 14),
            ),
            SizedBox(height: 16),
            _buildHelpItem('Alto', 'Detecta grooming, acoso, contenido sexual y violento', Colors.red),
            _buildHelpItem('Medio', 'Detecta contenido inapropiado y lenguaje ofensivo', Colors.orange),
            _buildHelpItem('Bajo', 'Solo detecta contenido explícitamente peligroso', Colors.blue),
            _buildHelpItem('No', 'Sin moderación automática', Colors.grey),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Entendido'),
          ),
        ],
      ),
    );
  }

  Widget _buildHelpItem(String level, String description, Color color) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 50,
            padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              level,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              description,
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showRevokeConfirmation(ChildRelation relation) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red, size: 24),
            SizedBox(width: 8),
            Expanded(child: Text('Revocar contacto')),
          ],
        ),
        content: Text(
          '¿Revocar el contacto de ${relation.childName} con ${widget.contact.contactName}?\n\n'
          'El chat se bloqueará y ninguno podrá enviar mensajes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text('Revocar'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      widget.onRevoke(relation);
      if (mounted) Navigator.pop(context);
    }
  }
}
