import 'package:flutter/material.dart';
import '../../services/accessibility_service.dart';

/// Pantalla de configuración de accesibilidad
class AccessibilitySettingsScreen extends StatefulWidget {
  const AccessibilitySettingsScreen({super.key});

  @override
  State<AccessibilitySettingsScreen> createState() =>
      _AccessibilitySettingsScreenState();
}

class _AccessibilitySettingsScreenState
    extends State<AccessibilitySettingsScreen> {
  double _textScale = 1.0;
  bool _highContrast = false;
  bool _reduceAnimations = false;
  bool _boldText = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  void _loadSettings() {
    setState(() {
      _textScale = accessibility.textScale;
      _highContrast = accessibility.highContrast;
      _reduceAnimations = accessibility.reduceAnimations;
      _boldText = accessibility.boldText;
    });
  }

  Future<void> _updateTextScale(double value) async {
    await accessibility.setTextScale(value);
    setState(() {
      _textScale = value;
    });
    // Mostrar snackbar con feedback
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Tamaño de texto: ${(value * 100).toInt()}%'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  Future<void> _updateHighContrast(bool value) async {
    await accessibility.setHighContrast(value);
    setState(() {
      _highContrast = value;
    });
    // Recargar app para aplicar cambios de tema
    _showRestartDialog();
  }

  Future<void> _updateReduceAnimations(bool value) async {
    await accessibility.setReduceAnimations(value);
    setState(() {
      _reduceAnimations = value;
    });
  }

  Future<void> _updateBoldText(bool value) async {
    await accessibility.setBoldText(value);
    setState(() {
      _boldText = value;
    });
  }

  void _showRestartDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reiniciar aplicación'),
        content: const Text(
          'Algunos cambios requieren reiniciar la aplicación para aplicarse completamente.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _resetToDefaults() async {
    await accessibility.resetToDefaults();
    _loadSettings();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Configuración restaurada a valores por defecto'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Accesibilidad'),
        actions: [
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: 'Restaurar valores por defecto',
            onPressed: _resetToDefaults,
          ),
        ],
      ),
      body: ListView(
        children: [
          // Header con información
          Container(
            padding: const EdgeInsets.all(16),
            color: Theme.of(context).primaryColor.withValues(alpha: 0.1),
            child: Row(
              children: [
                const Icon(Icons.accessibility, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Configuración de Accesibilidad',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Personaliza la app para mejorar tu experiencia',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Tamaño de texto
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.text_fields),
                    const SizedBox(width: 12),
                    Text(
                      'Tamaño de Texto',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Ajusta el tamaño del texto en toda la aplicación',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Text('A', style: TextStyle(fontSize: 12)),
                    Expanded(
                      child: Slider(
                        value: _textScale,
                        min: 0.8,
                        max: 2.0,
                        divisions: 12,
                        label: '${(_textScale * 100).toInt()}%',
                        onChanged: _updateTextScale,
                      ),
                    ),
                    const Text('A', style: TextStyle(fontSize: 24)),
                  ],
                ),
                Center(
                  child: Text(
                    'Tamaño actual: ${(_textScale * 100).toInt()}%',
                    style: TextStyle(
                      fontSize: 16 * _textScale,
                      fontWeight: _boldText ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const Divider(),

          // Alto contraste
          SwitchListTile(
            secondary: const Icon(Icons.contrast),
            title: const Text('Alto Contraste'),
            subtitle: const Text(
              'Usa colores con mayor contraste para mejor visibilidad',
            ),
            value: _highContrast,
            onChanged: _updateHighContrast,
          ),

          const Divider(),

          // Reducir animaciones
          SwitchListTile(
            secondary: const Icon(Icons.animation),
            title: const Text('Reducir Animaciones'),
            subtitle: const Text(
              'Desactiva animaciones y transiciones',
            ),
            value: _reduceAnimations,
            onChanged: _updateReduceAnimations,
          ),

          const Divider(),

          // Texto en negrita
          SwitchListTile(
            secondary: const Icon(Icons.format_bold),
            title: const Text('Texto en Negrita'),
            subtitle: const Text(
              'Hace el texto más grueso y fácil de leer',
            ),
            value: _boldText,
            onChanged: _updateBoldText,
          ),

          const Divider(),

          // Información adicional
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Compatibilidad con lectores de pantalla',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Esta aplicación es compatible con TalkBack (Android) y VoiceOver (iOS).',
                ),
                const SizedBox(height: 8),
                const Text(
                  'Para activar el lector de pantalla:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text('• Android: Configuración → Accesibilidad → TalkBack'),
                const Text('• iOS: Configuración → Accesibilidad → VoiceOver'),
              ],
            ),
          ),

          // Botón de prueba
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Prueba de Contraste',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                _buildContrastTest(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContrastTest() {
    final colorPairs = [
      (Colors.black, Colors.white, 'Negro sobre blanco'),
      (Colors.white, Colors.black, 'Blanco sobre negro'),
      (Colors.blue.shade700, Colors.white, 'Azul sobre blanco'),
      (Colors.grey.shade600, Colors.white, 'Gris sobre blanco'),
    ];

    return Column(
      children: colorPairs.map((pair) {
        final hasGoodContrast = AccessibilityService.hasGoodContrast(
          pair.$1,
          pair.$2,
        );

        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: pair.$2,
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    pair.$3,
                    style: TextStyle(color: pair.$1, fontSize: 16),
                  ),
                ),
                Icon(
                  hasGoodContrast ? Icons.check_circle : Icons.warning,
                  color: hasGoodContrast ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 4),
                Text(
                  hasGoodContrast ? 'Bueno' : 'Bajo',
                  style: TextStyle(
                    color: hasGoodContrast ? Colors.green : Colors.orange,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}
