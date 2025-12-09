import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../controllers/controllers.dart';
import '../models/models.dart';

/// Screen for parents to manage group approval requests
///
/// Shows a list of pending approval requests for their children
/// to join groups.
class GroupApprovalScreen extends StatefulWidget {
  const GroupApprovalScreen({super.key});

  @override
  State<GroupApprovalScreen> createState() => _GroupApprovalScreenState();
}

class _GroupApprovalScreenState extends State<GroupApprovalScreen> {
  late GroupApprovalController _controller;

  @override
  void initState() {
    super.initState();
    _controller = GroupApprovalController();
    _setupCallbacks();
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _setupCallbacks() {
    _controller.onRequestsChanged = (requests) {
      if (mounted) setState(() {});
    };

    _controller.onLoadingChanged = (loading) {
      if (mounted) setState(() {});
    };

    _controller.onProcessingChanged = (processing) {
      if (mounted) setState(() {});
    };

    _controller.onError = (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error),
            backgroundColor: Colors.red,
          ),
        );
      }
    };

    _controller.onSuccess = (message) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      }
    };
  }

  Future<void> _handleApprove(String requestId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Aprobar solicitud'),
        content: const Text(
          'Tu hijo/a podra unirse al grupo y chatear con los demas miembros.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Aprobar'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _controller.approveRequest(requestId);
    }
  }

  Future<void> _handleReject(String requestId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rechazar solicitud'),
        content: const Text(
          'Tu hijo/a no podra unirse a este grupo. No podra ser invitado nuevamente.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Rechazar'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _controller.rejectRequest(requestId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: colorScheme.primary,
        foregroundColor: Colors.white,
        title: const Text('Aprobaciones de Grupos'),
      ),
      body: _buildBody(colorScheme),
    );
  }

  Widget _buildBody(ColorScheme colorScheme) {
    if (_controller.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_controller.pendingRequests.isEmpty) {
      return _buildEmptyState(colorScheme);
    }

    return RefreshIndicator(
      onRefresh: _controller.refresh,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _controller.pendingRequests.length,
        itemBuilder: (context, index) {
          final request = _controller.pendingRequests[index];
          return _buildRequestCard(colorScheme, request);
        },
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.check_circle_outline,
              size: 80,
              color: colorScheme.primary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 24),
            Text(
              'Sin solicitudes pendientes',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Cuando tus hijos sean invitados a grupos, las solicitudes apareceran aqui.',
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRequestCard(ColorScheme colorScheme, GroupApprovalRequest request) {
    final daysRemaining = request.expiresAt.difference(DateTime.now()).inDays;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: Child info
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: colorScheme.primaryContainer,
                  child: request.childPhotoURL != null && request.childPhotoURL!.isNotEmpty
                      ? ClipOval(
                          child: CachedNetworkImage(
                            imageUrl: request.childPhotoURL!,
                            width: 40,
                            height: 40,
                            fit: BoxFit.cover,
                            placeholder: (context, url) => Icon(
                              Icons.person,
                              color: colorScheme.primary,
                            ),
                            errorWidget: (context, url, error) => Icon(
                              Icons.person,
                              color: colorScheme.primary,
                            ),
                          ),
                        )
                      : Text(
                          request.childName.isNotEmpty
                              ? request.childName[0].toUpperCase()
                              : 'H',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: colorScheme.primary,
                          ),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        request.childName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'quiere unirse a un grupo',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                // Expiration badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: daysRemaining <= 2
                        ? Colors.red.shade100
                        : Colors.orange.shade100,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.schedule,
                        size: 12,
                        color: daysRemaining <= 2
                            ? Colors.red.shade800
                            : Colors.orange.shade800,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        daysRemaining <= 0
                            ? 'Expira hoy'
                            : 'Expira en $daysRemaining ${daysRemaining == 1 ? 'día' : 'días'}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: daysRemaining <= 2
                              ? Colors.red.shade800
                              : Colors.orange.shade800,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 12),

            // Group info section
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Group name
                  Row(
                    children: [
                      Icon(
                        Icons.group,
                        size: 20,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          request.groupName,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),

                  if (request.groupDescription != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      request.groupDescription!,
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],

                  const SizedBox(height: 12),

                  // Group stats
                  Row(
                    children: [
                      _buildStatChip(
                        colorScheme,
                        Icons.people,
                        '${request.members.length} miembros',
                      ),
                      const SizedBox(width: 8),
                      _buildStatChip(
                        colorScheme,
                        Icons.person,
                        'Creado por ${request.groupCreatorName}',
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Action buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _controller.isRequestProcessing(request.id)
                        ? null
                        : () => _handleReject(request.id),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Rechazar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _controller.isRequestProcessing(request.id)
                        ? null
                        : () => _handleApprove(request.id),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colorScheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: _controller.isRequestProcessing(request.id)
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Text('Aprobar'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatChip(ColorScheme colorScheme, IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
