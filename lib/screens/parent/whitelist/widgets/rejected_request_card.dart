import 'package:flutter/material.dart';
import '../../../../controllers/whitelist_controller.dart';
import '../../../../widgets/filterable_request_item.dart';
import '../../../../models/user.dart';

/// Card para mostrar una solicitud rechazada
///
/// Muestra:
/// - Avatar y datos del contacto
/// - Información del hijo
/// - Botón para re-aprobar
class RejectedRequestCard extends StatelessWidget {
  final Map<String, dynamic> request;
  final WhitelistController controller;
  final ValueNotifier<String> searchQuery;
  final Function(String, String, Map<String, dynamic>, String) onReApprove;

  const RejectedRequestCard({
    super.key,
    required this.request,
    required this.controller,
    required this.searchQuery,
    required this.onReApprove,
  });

  @override
  Widget build(BuildContext context) {
    final requestId = request['requestId'] as String;
    final childId = request['childId'] as String;
    final type = request['type'] as String;
    final data = request['data'] as Map<String, dynamic>;
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
        final groupName = details['groupName'];
        final parentName = details['parentName'];
        final parentPhotoURL = details['parentPhotoURL'];

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
            contactName: contactName,
            contactAge: contactAge,
            contactPhotoURL: contactPhotoURL,
            childName: childName,
            groupName: groupName,
            parentName: parentName,
            parentPhotoURL: parentPhotoURL,
            isProcessing: isProcessing,
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
    required String contactName,
    required int? contactAge,
    required String? contactPhotoURL,
    required String childName,
    required String? groupName,
    required String? parentName,
    required String? parentPhotoURL,
    required bool isProcessing,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: EdgeInsets.only(bottom: 8),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.orange.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: Colors.orange.withValues(alpha: 0.1),
            backgroundImage:
                contactPhotoURL != null && contactPhotoURL.isNotEmpty
                ? NetworkImage(contactPhotoURL)
                : null,
            child: contactPhotoURL == null || contactPhotoURL.isEmpty
                ? Text(
                    contactName.isNotEmpty ? contactName[0].toUpperCase() : 'U',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.orange,
                    ),
                  )
                : null,
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                SizedBox(height: 4),
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
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        childName,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.orange,
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
            ),
          ),
          SizedBox(width: 8),
          FilledButton.icon(
            onPressed: isProcessing
                ? null
                : () => onReApprove(requestId, childId, data, type),
            icon: isProcessing
                ? SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : Icon(Icons.check_rounded, size: 16),
            label: Text(isProcessing ? 'Procesando' : 'Aprobar'),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              minimumSize: Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
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
      result['parentPhotoURL'] = parentData?['photoURL'];
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
    }

    return result;
  }
}
