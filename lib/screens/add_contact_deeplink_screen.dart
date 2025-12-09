import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../services/contact_request_service.dart';
import '../utils/release_logger.dart';

/// Pantalla para agregar contacto via deep link
///
/// Se muestra cuando el usuario abre un link de tipo:
/// - talia://add/{userId}
/// - https://taliachat.com/add/{userId}
///
/// Muestra información del usuario a agregar y permite
/// enviar solicitud de contacto o cancelar.
class AddContactDeeplinkScreen extends StatefulWidget {
  final String targetUserId;

  const AddContactDeeplinkScreen({
    super.key,
    required this.targetUserId,
  });

  @override
  State<AddContactDeeplinkScreen> createState() => _AddContactDeeplinkScreenState();
}

class _AddContactDeeplinkScreenState extends State<AddContactDeeplinkScreen> {
  final ContactRequestService _contactRequestService = ContactRequestService();

  bool _isLoading = true;
  bool _isSending = false;
  String? _error;
  Map<String, dynamic>? _targetUserData;

  @override
  void initState() {
    super.initState();
    _loadTargetUser();
  }

  Future<void> _loadTargetUser() async {
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) {
        setState(() {
          _error = 'Debes iniciar sesión para agregar contactos';
          _isLoading = false;
        });
        return;
      }

      // Verificar que no sea el mismo usuario
      if (widget.targetUserId == currentUser.uid) {
        setState(() {
          _error = 'No puedes agregarte a ti mismo como contacto';
          _isLoading = false;
        });
        return;
      }

      // Cargar datos del usuario objetivo
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.targetUserId)
          .get();

      if (!userDoc.exists) {
        setState(() {
          _error = 'Usuario no encontrado';
          _isLoading = false;
        });
        return;
      }

      setState(() {
        _targetUserData = userDoc.data();
        _isLoading = false;
      });
    } catch (e) {
      ReleaseLogger.error('Error loading target user: $e');
      setState(() {
        _error = 'Error cargando información del usuario';
        _isLoading = false;
      });
    }
  }

  Future<void> _sendContactRequest() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null || _targetUserData == null) return;

    setState(() => _isSending = true);

    try {
      // Obtener datos del usuario actual
      final currentUserDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .get();

      final currentUserData = currentUserDoc.data() ?? {};

      final result = await _contactRequestService.sendContactRequest(
        contactUserId: widget.targetUserId,
        currentUserId: currentUser.uid,
        currentUserName: currentUserData['name'] ?? 'Usuario',
        currentUserEmail: currentUser.email ?? '',
        contactName: _targetUserData!['name'] ?? 'Usuario',
        contactEmail: _targetUserData!['email'] ?? '',
      );

      if (!mounted) return;

      if (result.success) {
        final message = result.status == 'approved'
            ? 'Contacto agregado exitosamente'
            : 'Solicitud de contacto enviada';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.of(context).pop(true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.errorMessage ?? 'Error enviando solicitud'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ReleaseLogger.error('Error sending contact request: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agregar Contacto'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _buildBody(colorScheme),
    );
  }

  Widget _buildBody(ColorScheme colorScheme) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 64,
                color: colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 16,
                  color: colorScheme.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cerrar'),
              ),
            ],
          ),
        ),
      );
    }

    return _buildUserInfo(colorScheme);
  }

  Widget _buildUserInfo(ColorScheme colorScheme) {
    final name = _targetUserData?['name'] ?? 'Usuario';
    final photoURL = _targetUserData?['photoURL'] as String?;
    final age = _targetUserData?['age'];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Spacer(),
            // Avatar
            CircleAvatar(
              radius: 60,
              backgroundColor: colorScheme.primaryContainer,
              backgroundImage: photoURL != null && photoURL.isNotEmpty
                  ? CachedNetworkImageProvider(photoURL)
                  : null,
              child: photoURL == null || photoURL.isEmpty
                  ? Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        color: colorScheme.primary,
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 24),
            // Nombre
            Text(
              name,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
            if (age != null) ...[
              const SizedBox(height: 8),
              Text(
                '$age años',
                style: TextStyle(
                  fontSize: 16,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 32),
            // Mensaje
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Se enviará una solicitud de contacto a este usuario.',
                      style: TextStyle(
                        fontSize: 14,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            // Botones
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isSending ? null : () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _isSending ? null : _sendContactRequest,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colorScheme.primary,
                      foregroundColor: colorScheme.onPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: _isSending
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Agregar'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
