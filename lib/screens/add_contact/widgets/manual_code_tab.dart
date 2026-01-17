import 'package:flutter/material.dart';

/// Tab para ingresar un codigo manualmente
///
/// Responsabilidades:
/// - Mostrar campo de texto para codigo
/// - Validar formato de codigo
/// - Proveer instrucciones al usuario
/// - Mostrar mensajes de error
class ManualCodeTab extends StatelessWidget {
  final TextEditingController codeController;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback onSubmit;
  final ValueChanged<String> onChanged;

  const ManualCodeTab({
    super.key,
    required this.codeController,
    required this.isLoading,
    required this.onSubmit,
    required this.onChanged,
    this.errorMessage,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      padding: EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 20),
          _buildIconHeader(colorScheme),
          SizedBox(height: 24),
          _buildTitle(colorScheme),
          SizedBox(height: 8),
          _buildSubtitle(colorScheme),
          SizedBox(height: 24),
          _buildCodeTextField(colorScheme),
          SizedBox(height: 16),
          _buildInfoBanner(),
          if (errorMessage != null) ...[
            SizedBox(height: 16),
            _buildErrorMessage(errorMessage!),
          ],
          SizedBox(height: 32),
          _buildSubmitButton(colorScheme),
        ],
      ),
    );
  }

  Widget _buildIconHeader(ColorScheme colorScheme) {
    return Center(
      child: Container(
        padding: EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.keyboard, size: 48, color: colorScheme.primary),
      ),
    );
  }

  Widget _buildTitle(ColorScheme colorScheme) {
    return Text(
      'Introduce el codigo',
      style: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: colorScheme.onSurface,
      ),
    );
  }

  Widget _buildSubtitle(ColorScheme colorScheme) {
    return Text(
      'Pide a tu amigo su codigo unico y escribelo aqui',
      style: TextStyle(fontSize: 14, color: colorScheme.onSurfaceVariant),
    );
  }

  Widget _buildCodeTextField(ColorScheme colorScheme) {
    return TextField(
      controller: codeController,
      decoration: InputDecoration(
        labelText: 'Codigo de usuario',
        hintText: 'Ej: TALIA-ABC123',
        prefixIcon: Icon(Icons.tag, color: colorScheme.primary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: colorScheme.primary, width: 2),
        ),
      ),
      textCapitalization: TextCapitalization.characters,
      onChanged: onChanged,
    );
  }

  Widget _buildInfoBanner() {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: Colors.blue, size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'El codigo tiene el formato TALIA-ABC123 (3 letras y 3 numeros)',
              style: TextStyle(color: Colors.blue[700], fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorMessage(String message) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red, size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: Colors.red[700], fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitButton(ColorScheme colorScheme) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton(
        onPressed: isLoading ? null : onSubmit,
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: isLoading
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Text(
                'Buscar Contacto',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}
