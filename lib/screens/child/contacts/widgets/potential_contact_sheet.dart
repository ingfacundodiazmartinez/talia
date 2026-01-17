import 'package:flutter/material.dart';
import '../../../../models/contact.dart';

/// Sheet para mostrar detalles de un contacto sugerido y solicitar aprobación
///
/// Muestra:
/// - Nombre del contacto (de la agenda)
/// - Número de teléfono
/// - Mensaje explicativo
/// - Botón "Solicitar aprobación"
class PotentialContactSheet extends StatelessWidget {
  final Contact contact;
  final String deviceContactName;
  final String phoneNumber;
  final VoidCallback onRequestApproval;
  final bool isLoading;
  final String explanationMessage;

  const PotentialContactSheet({
    super.key,
    required this.contact,
    required this.deviceContactName,
    required this.phoneNumber,
    required this.onRequestApproval,
    required this.explanationMessage,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 16,
        bottom: MediaQuery.of(context).padding.bottom + 24,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          SizedBox(height: 24),

          // Avatar grande con icono
          CircleAvatar(
            radius: 48,
            backgroundColor: Colors.teal.shade50,
            child: Icon(
              Icons.person_outline,
              size: 48,
              color: Colors.teal.shade600,
            ),
          ),
          SizedBox(height: 16),

          // Nombre del contacto
          Text(
            deviceContactName,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: colorScheme.onSurface,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 8),

          // Número de teléfono
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.phone_outlined,
                size: 18,
                color: colorScheme.onSurfaceVariant,
              ),
              SizedBox(width: 8),
              Text(
                phoneNumber,
                style: TextStyle(
                  fontSize: 16,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          SizedBox(height: 24),

          // Mensaje explicativo
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.teal.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.teal.shade200,
                width: 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 24,
                  color: Colors.teal.shade700,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    explanationMessage,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.teal.shade900,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 24),

          // Botón de solicitar aprobación
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton.icon(
              onPressed: isLoading ? null : onRequestApproval,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.teal.shade600,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: isLoading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Icon(Icons.send_rounded),
              label: Text(
                isLoading ? 'Solicitando...' : 'Solicitar aprobación',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          SizedBox(height: 12),

          // Botón cancelar
          SizedBox(
            width: double.infinity,
            height: 48,
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'Cancelar',
                style: TextStyle(
                  fontSize: 16,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Método estático para mostrar el sheet
  static Future<void> show({
    required BuildContext context,
    required Contact contact,
    required String deviceContactName,
    required String phoneNumber,
    required String explanationMessage,
    required Future<void> Function() onRequestApproval,
  }) async {
    bool isLoading = false;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => PotentialContactSheet(
          contact: contact,
          deviceContactName: deviceContactName,
          phoneNumber: phoneNumber,
          explanationMessage: explanationMessage,
          isLoading: isLoading,
          onRequestApproval: () async {
            setState(() => isLoading = true);
            try {
              await onRequestApproval();
              if (context.mounted) {
                Navigator.pop(context);
              }
            } catch (e) {
              setState(() => isLoading = false);
              rethrow;
            }
          },
        ),
      ),
    );
  }
}
