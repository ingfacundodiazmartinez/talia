import 'package:flutter/material.dart';
import '../../../services/account_deletion_service.dart';

/// Dialog para confirmar eliminación de cuenta
///
/// Requiere que el usuario escriba "ELIMINAR" para confirmar.
/// Llama a Cloud Function para eliminación segura server-side.
class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({super.key});

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  final _confirmationController = TextEditingController();
  final _accountDeletionService = AccountDeletionService();

  bool _isLoading = false;
  String _confirmationText = '';

  @override
  void dispose() {
    _confirmationController.dispose();
    super.dispose();
  }

  bool get _canDelete => _confirmationText.trim().toUpperCase() == 'ELIMINAR';

  Future<void> _deleteAccount() async {
    if (!_canDelete) return;

    setState(() => _isLoading = true);

    try {
      final result = await _accountDeletionService.deleteAccount(
        confirmationText: 'ELIMINAR',
      );

      if (!mounted) return;

      // Cerrar dialog
      Navigator.of(context).pop();

      // Mostrar mensaje de éxito brevemente
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );

      // Navegar al login y limpiar stack
      await Future.delayed(Duration(milliseconds: 500));
      if (mounted) {
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/login',
          (route) => false,
        );
      }
    } on AccountDeletionException catch (e) {
      setState(() => _isLoading = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error inesperado: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      title: Row(
        children: [
          Icon(Icons.warning, color: Colors.red),
          SizedBox(width: 8),
          Text('Eliminar Cuenta'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Advertencia
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.warning_amber,
                        color: Colors.red,
                        size: 20,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'ADVERTENCIA',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.red,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Esta acción es PERMANENTE e IRREVERSIBLE.',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.red[800],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),

            // Lista de datos a eliminar
            Text(
              'Se eliminarán permanentemente:',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            SizedBox(height: 8),
            _buildDeleteItem('• Tu perfil y foto', colorScheme),
            _buildDeleteItem('• Todos los mensajes y chats', colorScheme),
            _buildDeleteItem('• Tus historias', colorScheme),
            _buildDeleteItem('• Vínculos con hijos o padres', colorScheme),
            _buildDeleteItem('• Historial de ubicaciones', colorScheme),
            _buildDeleteItem('• Conexión con tus contactos', colorScheme),
            SizedBox(height: 20),

            // Campo de confirmación
            Text(
              'Escribe ELIMINAR para confirmar:',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            SizedBox(height: 8),
            TextField(
              controller: _confirmationController,
              enabled: !_isLoading,
              textCapitalization: TextCapitalization.characters,
              onChanged: (value) {
                setState(() => _confirmationText = value);
              },
              decoration: InputDecoration(
                hintText: 'ELIMINAR',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                suffixIcon: _canDelete
                    ? Icon(Icons.check_circle, color: Colors.red)
                    : null,
              ),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
              ),
            ),

            if (_confirmationText.isNotEmpty && !_canDelete) ...[
              SizedBox(height: 8),
              Text(
                'Escribe exactamente "ELIMINAR"',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.orange,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: Text('Cancelar'),
        ),
        ElevatedButton(
          onPressed: _isLoading || !_canDelete ? null : _deleteAccount,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red,
            foregroundColor: Colors.white,
            disabledBackgroundColor: Colors.red.withValues(alpha: 0.3),
          ),
          child: _isLoading
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : Text('Eliminar Cuenta'),
        ),
      ],
    );
  }

  Widget _buildDeleteItem(String text, ColorScheme colorScheme) {
    return Padding(
      padding: EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          color: colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
