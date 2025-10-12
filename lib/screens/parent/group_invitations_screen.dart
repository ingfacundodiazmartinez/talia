import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/group_invitation_service.dart';

/// Pantalla para que padres gestionen invitaciones a grupos
///
/// Muestra dos tipos de solicitudes:
/// 1. Invitaciones donde su hijo fue invitado (debe aprobar contactos)
/// 2. Solicitudes donde otro niño quiere unirse a un grupo de su hijo (aprobar contacto)
class GroupInvitationsScreen extends StatefulWidget {
  const GroupInvitationsScreen({super.key});

  @override
  State<GroupInvitationsScreen> createState() => _GroupInvitationsScreenState();
}

class _GroupInvitationsScreenState extends State<GroupInvitationsScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final GroupInvitationService _invitationService = GroupInvitationService();

  final Set<String> _processingInvitations = {};

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Invitaciones a Grupos'),
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _getInvitationsStream(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline, size: 64, color: colorScheme.error),
                  const SizedBox(height: 16),
                  Text('Error: ${snapshot.error}'),
                ],
              ),
            );
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final invitations = snapshot.data?.docs ?? [];

          if (invitations.isEmpty) {
            return _buildEmptyState(colorScheme);
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: invitations.length,
            itemBuilder: (context, index) {
              final doc = invitations[index];
              final data = doc.data() as Map<String, dynamic>;

              return _buildInvitationCard(
                invitationId: doc.id,
                data: data,
                colorScheme: colorScheme,
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 80,
            color: colorScheme.primary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            'Sin invitaciones pendientes',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Aquí aparecerán las solicitudes de grupos',
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInvitationCard({
    required String invitationId,
    required Map<String, dynamic> data,
    required ColorScheme colorScheme,
  }) {
    final currentUserId = _auth.currentUser?.uid;
    final invitedParentApproval = data['invitedParentApproval'] as Map<String, dynamic>?;
    final isInvitedParent = invitedParentApproval?['parentId'] == currentUserId;
    final isProcessing = _processingInvitations.contains(invitationId);

    if (isInvitedParent) {
      return _buildInvitedParentCard(
        invitationId: invitationId,
        data: data,
        colorScheme: colorScheme,
        isProcessing: isProcessing,
      );
    } else {
      return _buildMemberParentCard(
        invitationId: invitationId,
        data: data,
        colorScheme: colorScheme,
        isProcessing: isProcessing,
      );
    }
  }

  /// Tarjeta para el padre del niño invitado
  Widget _buildInvitedParentCard({
    required String invitationId,
    required Map<String, dynamic> data,
    required ColorScheme colorScheme,
    required bool isProcessing,
  }) {
    final groupName = data['groupName'] ?? 'Grupo';
    final requiredApprovals = data['requiredApprovals'] as Map<String, dynamic>? ?? {};
    final invitedChildId = data['invitedChildId'] as String;
    final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();
    final invitedParentApproval = data['invitedParentApproval'] as Map<String, dynamic>;
    final alreadyApproved = invitedParentApproval['status'] == 'approved';

    // Calcular tiempo restante
    final timeRemaining = expiresAt != null
        ? expiresAt.difference(DateTime.now())
        : null;

    return FutureBuilder<Map<String, String>>(
      future: _loadMemberNames(requiredApprovals.keys.toList(), invitedChildId),
      builder: (context, snapshot) {
        final memberNames = snapshot.data ?? {};
        final invitedName = memberNames[invitedChildId] ?? 'Tu hijo';

        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: alreadyApproved
                  ? Colors.green.withValues(alpha: 0.3)
                  : colorScheme.primary.withValues(alpha: 0.3),
              width: 2,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.group_add,
                        color: colorScheme.primary,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '🎉 Invitación a Grupo',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          Text(
                            groupName,
                            style: TextStyle(
                              fontSize: 14,
                              color: colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (timeRemaining != null && timeRemaining.inHours > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: timeRemaining.inHours < 24
                              ? Colors.orange.withValues(alpha: 0.1)
                              : colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.timer_outlined,
                              size: 14,
                              color: timeRemaining.inHours < 24
                                  ? Colors.orange
                                  : colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${timeRemaining.inHours}h',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: timeRemaining.inHours < 24
                                    ? Colors.orange
                                    : colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '$invitedName ha sido invitado al grupo "$groupName"',
                  style: TextStyle(
                    fontSize: 14,
                    color: colorScheme.onSurface,
                  ),
                ),
                if (requiredApprovals.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.orange.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 16,
                              color: Colors.orange.shade800,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Requiere aprobar contactos:',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                                color: Colors.orange.shade800,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ...requiredApprovals.entries.map((entry) {
                          final memberId = entry.key;
                          final approval = entry.value as Map<String, dynamic>;
                          final memberName = memberNames[memberId] ?? 'Usuario';
                          final status = approval['status'] as String;

                          return Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(
                              children: [
                                Icon(
                                  status == 'approved'
                                      ? Icons.check_circle
                                      : Icons.pending,
                                  size: 16,
                                  color: status == 'approved'
                                      ? Colors.green
                                      : Colors.grey,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    memberName,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ],
                if (alreadyApproved) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle, color: Colors.green, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Has aprobado esta invitación. Esperando aprobación de otros padres...',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.green.shade800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: isProcessing
                              ? null
                              : () => _handleRejectInvitation(invitationId),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: colorScheme.error,
                            side: BorderSide(color: colorScheme.error),
                          ),
                          child: const Text('Rechazar'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: isProcessing
                              ? null
                              : () => _handleApproveInvitation(invitationId),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: colorScheme.primary,
                            foregroundColor: colorScheme.onPrimary,
                          ),
                          child: isProcessing
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Aprobar y Unirse'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// Tarjeta para padres de miembros del grupo (deben aprobar al nuevo miembro)
  Widget _buildMemberParentCard({
    required String invitationId,
    required Map<String, dynamic> data,
    required ColorScheme colorScheme,
    required bool isProcessing,
  }) {
    final currentUserId = _auth.currentUser?.uid;
    final groupName = data['groupName'] ?? 'Grupo';
    final invitedChildId = data['invitedChildId'] as String;
    final requiredApprovals = data['requiredApprovals'] as Map<String, dynamic>? ?? {};

    // Encontrar el memberId que corresponde al padre actual
    String? myChildId;
    Map<String, dynamic>? myApproval;

    for (final entry in requiredApprovals.entries) {
      final approval = entry.value as Map<String, dynamic>;
      if (approval['parentId'] == currentUserId) {
        myChildId = entry.key;
        myApproval = approval;
        break;
      }
    }

    if (myChildId == null || myApproval == null) {
      return const SizedBox.shrink();
    }

    final alreadyApproved = myApproval['status'] == 'approved';

    return FutureBuilder<Map<String, String>>(
      future: _loadMemberNames([invitedChildId, myChildId], null),
      builder: (context, snapshot) {
        final memberNames = snapshot.data ?? {};
        final invitedName = memberNames[invitedChildId] ?? 'Un niño';
        final myChildName = memberNames[myChildId] ?? 'Tu hijo';

        return Card(
          margin: const EdgeInsets.only(bottom: 16),
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: alreadyApproved
                  ? Colors.green.withValues(alpha: 0.3)
                  : colorScheme.primary.withValues(alpha: 0.3),
              width: 2,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.person_add,
                        color: colorScheme.primary,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '👥 Solicitud de Contacto',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          Text(
                            'Grupo: $groupName',
                            style: TextStyle(
                              fontSize: 14,
                              color: colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '$invitedName quiere unirse al grupo "$groupName" donde está $myChildName.',
                  style: TextStyle(
                    fontSize: 14,
                    color: colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '¿Aprobar a $invitedName como contacto?',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                if (alreadyApproved) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle, color: Colors.green, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Has aprobado este contacto',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.green.shade800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: isProcessing
                              ? null
                              : () => _handleRejectMemberApproval(
                                  invitationId,
                                  myChildId!,
                                ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: colorScheme.error,
                            side: BorderSide(color: colorScheme.error),
                          ),
                          child: const Text('Rechazar'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: isProcessing
                              ? null
                              : () => _handleApproveMemberContact(
                                  invitationId,
                                  myChildId!,
                                ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: colorScheme.primary,
                            foregroundColor: colorScheme.onPrimary,
                          ),
                          child: isProcessing
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Aprobar Contacto'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Future<Map<String, String>> _loadMemberNames(
    List<String> userIds,
    String? additionalUserId,
  ) async {
    final names = <String, String>{};
    final allIds = [...userIds, if (additionalUserId != null) additionalUserId];

    for (final userId in allIds) {
      try {
        final doc = await _firestore.collection('users').doc(userId).get();
        names[userId] = doc.data()?['name'] ?? 'Usuario';
      } catch (e) {
        names[userId] = 'Usuario';
      }
    }

    return names;
  }

  Future<void> _handleApproveInvitation(String invitationId) async {
    setState(() => _processingInvitations.add(invitationId));

    final result = await _invitationService.approveInvitationByInvitedParent(
      invitationId: invitationId,
    );

    setState(() => _processingInvitations.remove(invitationId));

    if (mounted) {
      if (!result['success']) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ ${result['error']}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _handleApproveMemberContact(
    String invitationId,
    String memberId,
  ) async {
    setState(() => _processingInvitations.add(invitationId));

    final result = await _invitationService.approveMemberContact(
      invitationId: invitationId,
      memberId: memberId,
    );

    setState(() => _processingInvitations.remove(invitationId));

    if (mounted) {
      if (!result['success']) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ ${result['error']}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _handleRejectInvitation(String invitationId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rechazar Invitación'),
        content: const Text(
          '¿Estás seguro de que quieres rechazar esta invitación? Esta acción no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Rechazar'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _processingInvitations.add(invitationId));

    final result = await _invitationService.rejectInvitation(
      invitationId: invitationId,
    );

    setState(() => _processingInvitations.remove(invitationId));

    if (mounted) {
      if (!result['success']) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ ${result['error']}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _handleRejectMemberApproval(
    String invitationId,
    String memberId,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rechazar Contacto'),
        content: const Text(
          '¿Estás seguro de que quieres rechazar este contacto? Esto cancelará la invitación al grupo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Rechazar'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _processingInvitations.add(invitationId));

    final result = await _invitationService.rejectInvitation(
      invitationId: invitationId,
      memberId: memberId,
    );

    setState(() => _processingInvitations.remove(invitationId));

    if (mounted) {
      if (!result['success']) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ ${result['error']}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Stream<QuerySnapshot> _getInvitationsStream() {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      return const Stream.empty();
    }

    // Esta query solo obtiene invitaciones donde el usuario es padre del invitado
    // Para las solicitudes como padre de miembro, necesitamos filtrar en el builder
    return _firestore
        .collection('groupInvitations')
        .where('status', isEqualTo: 'pending_approvals')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }
}
