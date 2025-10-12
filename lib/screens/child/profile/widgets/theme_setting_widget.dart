import 'package:flutter/material.dart';
import '../../../../theme_service.dart';

/// Widget para cambiar el tema de la aplicación
class ThemeSettingWidget extends StatefulWidget {
  const ThemeSettingWidget({super.key});

  @override
  State<ThemeSettingWidget> createState() => _ThemeSettingWidgetState();
}

class _ThemeSettingWidgetState extends State<ThemeSettingWidget> {
  final ThemeService _themeService = ThemeService();

  Future<void> _toggleTheme(bool value) async {
    await _themeService.toggleTheme();
    setState(() {});

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _themeService.isDarkMode
                ? 'Modo oscuro activado'
                : 'Modo claro activado',
          ),
          backgroundColor: Theme.of(context).colorScheme.primary,
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            _themeService.isDarkMode ? Icons.dark_mode : Icons.light_mode,
            color: colorScheme.primary,
          ),
        ),
        title: Text(
          'Tema de la Aplicación',
          style: TextStyle(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          _themeService.isDarkMode
              ? 'Modo oscuro activado'
              : 'Modo claro activado',
          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
        ),
        trailing: Switch(
          value: _themeService.isDarkMode,
          onChanged: _toggleTheme,
          activeTrackColor: colorScheme.primary,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        tileColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
      ),
    );
  }
}
