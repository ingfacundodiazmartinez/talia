import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../controllers/whitelist_controller.dart';
import '../../../../widgets/filterable_request_item.dart';
import '../../../../models/user.dart';

/// Card para mostrar una solicitud pendiente de aprobación
///
/// Muestra:
/// - Checkbox para selección múltiple
/// - Avatar y datos del contacto
/// - Información del hijo
/// - Botones de acción (Aprobar/Rechazar)
class PendingRequestCard extends StatelessWidget {
  final Map<String, dynamic> request;
  final WhitelistController controller;
  final ValueNotifier<String> searchQuery;
  final VoidCallback onSelectionChanged;
  final Function(String, String, Map<String, dynamic>, String) onApprove;
  final Function(String, String) onReject;

  const PendingRequestCard({
    super.key,
    required this.request,
    required this.controller,
    required this.searchQuery,
    required this.onSelectionChanged,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final requestId = request['requestId'] as String;
    final childId = request['childId'] as String;
    final type = request['type'] as String;
    final data = request['data'] as Map<String, dynamic>;
    final isSelected = controller.selectedRequests.contains(requestId);
    final isProcessing = controller.processingRequests.contains(requestId);

    return FutureBuilder<Map<String, dynamic>>(
      future: _getRequestDetails(childId, data, type),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return _buildLoadingCard();
        }

        final details = snapshot.data!;
        final contactName = details['contactName'] ?? 'Usuario';
        final contactAge = details['contactAge'];
        final contactPhotoURL = details['contactPhotoURL'];
        final childName = details['childName'] ?? 'Hijo';
        final parentName = details['parentName'];
        final groupName = details['groupName'];

        return FilterableRequestItem(
          searchQuery: searchQuery,
          contactName: contactName,
          childName: childName,
          child: _buildCard(
            context: context,
            requestId: requestId,
            childId: childId,
            type: type,
            data: data,
            isSelected: isSelected,
            isProcessing: isProcessing,
            contactName: contactName,
            contactAge: contactAge,
            contactPhotoURL: contactPhotoURL,
            childName: childName,
            parentName: parentName,
            groupName: groupName,
          ),
        );
      },
    );
  }

  Widget _buildLoadingCard() {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildCard({
    required BuildContext context,
    required String requestId,
    required String childId,
    required String type,
    required Map<String, dynamic> data,
    required bool isSelected,
    required bool isProcessing,
    required String contactName,
    required int? contactAge,
    required String? contactPhotoURL,
    required String childName,
    required String? parentName,
    required String? groupName,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSelected
            ? colorScheme.primary.withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSelected
              ? colorScheme.primary
              : colorScheme.onSurfaceVariant.withValues(alpha: 0.2),
          width: isSelected ? 2 : 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            if (isSelected) {
              controller.selectedRequests.remove(requestId);
            } else {
              controller.selectedRequests.add(requestId);
            }
            onSelectionChanged();
          },
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Checkbox(
                      value: isSelected,
                      onChanged: (value) {
                        if (value == true) {
                          controller.selectedRequests.add(requestId);
                        } else {
                          controller.selectedRequests.remove(requestId);
                        }
                        onSelectionChanged();
                      },
                      activeColor: colorScheme.primary,
                      visualDensity: VisualDensity.compact,
                    ),
                    SizedBox(width: 4),
                    // ✅ Avatar diferente para grupos vs contactos
                    if (type == 'group_v2') ...[
                      Builder(
                        builder: (context) {
                          final groupAvatar = data['groupAvatar'] as String?;
                          final hasAvatar = groupAvatar != null && groupAvatar.isNotEmpty;
                          return CircleAvatar(
                            radius: 28,
                            backgroundColor: Colors.blue.withValues(alpha: 0.15),
                            backgroundImage: hasAvatar
                                ? CachedNetworkImageProvider(groupAvatar)
                                : null,
                            child: hasAvatar
                                ? null
                                : Icon(
                                    Icons.group,
                                    size: 28,
                                    color: Colors.blue,
                                  ),
                          );
                        },
                      ),
                    ] else ...[
                      CircleAvatar(
                        radius: 28,
                        backgroundColor: colorScheme.primary.withValues(
                          alpha: 0.1,
                        ),
                        child: contactPhotoURL != null && contactPhotoURL.isNotEmpty
                            ? ClipOval(
                                child: CachedNetworkImage(
                                  imageUrl: contactPhotoURL,
                                  width: 56,
                                  height: 56,
                                  fit: BoxFit.cover,
                                  placeholder: (context, url) => Text(
                                    contactName.isNotEmpty
                                        ? contactName[0].toUpperCase()
                                        : 'U',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.primary,
                                    ),
                                  ),
                                  errorWidget: (context, url, error) => Text(
                                    contactName.isNotEmpty
                                        ? contactName[0].toUpperCase()
                                        : 'U',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.primary,
                                    ),
                                  ),
                                ),
                              )
                            : Text(
                                contactName.isNotEmpty
                                    ? contactName[0].toUpperCase()
                                    : 'U',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.primary,
                                ),
                              ),
                      ),
                    ],
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // ✅ Título diferente para grupos vs contactos
                          if (type == 'group_v2') ...[
                            Text(
                              'Invitación al grupo',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.blue,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              groupName ?? 'Grupo',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onSurface,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ] else ...[
                            Text(
                              contactName,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onSurface,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                          SizedBox(height: 4),
                          // ✅ Subtítulo diferente para grupos vs contactos
                          if (type == 'group_v2') ...[
                            Text(
                              'Para: $childName • Creado por: $contactName',
                              style: TextStyle(
                                fontSize: 13,
                                color: colorScheme.onSurfaceVariant,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ] else ...[
                            Row(
                              children: [
                                if (contactAge != null) ...[
                                  Text(
                                    '$contactAge años',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  Text(
                                    ' • ',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                                Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.primary.withValues(
                                      alpha: 0.1,
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    childName,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: colorScheme.primary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (groupName != null) ...[
                                  SizedBox(width: 6),
                                  Icon(Icons.group, size: 14, color: Colors.blue),
                                ],
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      onPressed: isProcessing
                          ? null
                          : () => onReject(requestId, type),
                      icon: Icon(Icons.close_rounded, size: 16),
                      label: Text('Rechazar'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red[600],
                        side: BorderSide(color: Colors.red.shade200),
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        minimumSize: Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: isProcessing
                          ? null
                          : () {
                              if (type == 'group_v2') {
                                _showGroupApprovalDialog(
                                  context: context,
                                  requestId: requestId,
                                  childId: childId,
                                  data: data,
                                  childName: childName,
                                );
                              } else {
                                onApprove(requestId, childId, data, type);
                              }
                            },
                      icon: isProcessing
                          ? SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                              ),
                            )
                          : Icon(Icons.check_rounded, size: 16),
                      label: Text(isProcessing ? 'Procesando' : 'Aprobar'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.green,
                        foregroundColor: Colors.white,
                        padding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 4,
                        ),
                        minimumSize: Size(0, 32),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<Map<String, dynamic>> _getRequestDetails(
    String childId,
    Map<String, dynamic> data,
    String type,
  ) async {
    final result = <String, dynamic>{};

    // Obtener datos del hijo usando modelo User
    final childData = await User.getById(childId);
    result['childName'] = childData?['name'];

    // Obtener datos del padre del hijo
    final parentId = childData?['parentId'];
    if (parentId != null) {
      final parentData = await User.getById(parentId);
      result['parentName'] = parentData?['name'];
    }

    if (type == 'contact') {
      result['contactName'] = data['contactName'];
      result['contactPhone'] = data['contactPhone'];

      // Intentar primero con contactId (si existe), sino con contactPhone
      final contactId = data['contactId'];
      final contactPhone = data['contactPhone'];

      if (contactId != null) {
        final contactData = await User.getById(contactId);
        if (contactData != null) {
          result['contactPhotoURL'] = contactData['photoURL'];
          result['contactAge'] = User.calculateAge(contactData['birthDate']);
        }
      } else if (contactPhone != null) {
        final contactData = await User.getByPhone(contactPhone);
        if (contactData != null) {
          result['contactPhotoURL'] = contactData['photoURL'];
          result['contactAge'] = User.calculateAge(contactData['birthDate']);
        }
      }
    } else if (type == 'group') {
      final groupInfo = data['groupInfo'] as Map<String, dynamic>?;
      final contactInfo = data['contactToApprove'] as Map<String, dynamic>?;

      result['groupName'] = groupInfo?['groupName'];
      result['contactName'] = contactInfo?['name'];

      final contactId = contactInfo?['userId'];
      if (contactId != null) {
        final contactData = await User.getById(contactId);
        if (contactData != null) {
          result['contactPhotoURL'] = contactData['photoURL'];
          result['contactAge'] = User.calculateAge(contactData['birthDate']);
        }
      }
    } else if (type == 'group_v2') {
      // Groups V2: La invitación es para que el hijo entre al grupo
      result['groupName'] = data['groupName'];
      result['contactName'] = data['inviterName'] ?? 'Invitador';
      result['childName'] = data['childName'];

      // Obtener datos del invitador
      final invitedBy = data['invitedBy'];
      if (invitedBy != null) {
        final inviterData = await User.getById(invitedBy);
        if (inviterData != null) {
          result['contactPhotoURL'] = inviterData['photoURL'];
          result['contactAge'] = User.calculateAge(inviterData['birthDate']);
        }
      }
    }

    return result;
  }

  void _showGroupApprovalDialog({
    required BuildContext context,
    required String requestId,
    required String childId,
    required Map<String, dynamic> data,
    required String childName,
  }) {
    final groupName = data['groupName'] as String? ?? 'Grupo';
    final inviterName = data['inviterName'] as String? ?? 'Usuario';
    final groupAvatar = data['groupAvatar'] as String?;
    final members = (data['members'] as List<dynamic>?)
            ?.map((m) => m as Map<String, dynamic>)
            .toList() ??
        [];

    showDialog(
      context: context,
      builder: (dialogContext) {
        final colorScheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: Colors.blue.withValues(alpha: 0.15),
                backgroundImage:
                    groupAvatar != null ? NetworkImage(groupAvatar) : null,
                child: groupAvatar == null
                    ? Icon(Icons.group, size: 24, color: Colors.blue)
                    : null,
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Invitación a Grupo',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.blue,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      groupName,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Creado por: $inviterName',
                  style: TextStyle(
                    fontSize: 14,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  'Participantes (${members.length}):',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 8),
                Container(
                  constraints: BoxConstraints(maxHeight: 150),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: members.length,
                    itemBuilder: (context, index) {
                      final member = members[index];
                      final name = member['name'] as String? ?? 'Usuario';
                      final role = member['role'] as String? ?? 'member';
                      final photoURL = member['photoURL'] as String?;
                      final isCreator = role == 'creator' || role == 'admin';

                      return Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 14,
                              backgroundColor:
                                  colorScheme.primary.withValues(alpha: 0.1),
                              backgroundImage: photoURL != null
                                  ? NetworkImage(photoURL)
                                  : null,
                              child: photoURL == null
                                  ? Text(
                                      name.isNotEmpty
                                          ? name[0].toUpperCase()
                                          : 'U',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: colorScheme.primary,
                                      ),
                                    )
                                  : null,
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                name,
                                style: TextStyle(fontSize: 14),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isCreator)
                              Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.blue.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  'creador',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.blue,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                SizedBox(height: 16),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.orange.withValues(alpha: 0.3),
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
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'La moderación de contenido NO está disponible en grupos. Los mensajes no serán revisados automáticamente.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.orange[800],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  '¿Permitir que $childName se una a este grupo?',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red[600],
                side: BorderSide(color: Colors.red.shade200),
              ),
              child: Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                onApprove(requestId, childId, data, 'group_v2');
              },
              style: FilledButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
              ),
              child: Text('Aprobar'),
            ),
          ],
        );
      },
    );
  }
}
