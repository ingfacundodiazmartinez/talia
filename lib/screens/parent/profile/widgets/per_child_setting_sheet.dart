import 'package:flutter/material.dart';

import '../../../../models/child.dart';

/// Bottom-sheet que permite configurar un ajuste booleano (ej. auto-aprobación)
/// de forma individual por cada hijo vinculado.
///
/// Solo se usa cuando el padre tiene MÁS DE UN hijo vinculado. Con un solo hijo
/// la pantalla muestra el switch clásico (comportamiento sin cambios).
class PerChildSettingSheet extends StatefulWidget {
  final String title;
  final String description;
  final IconData icon;
  final List<Child> children;

  /// Valor actual (ya resuelto con fallback al global) para un hijo.
  final bool Function(String childId) valueFor;

  /// Persiste el nuevo valor para un hijo. Devuelve cuando terminó.
  final Future<void> Function(String childId, bool enabled) onChanged;

  const PerChildSettingSheet({
    super.key,
    required this.title,
    required this.description,
    required this.icon,
    required this.children,
    required this.valueFor,
    required this.onChanged,
  });

  static Future<void> show({
    required BuildContext context,
    required String title,
    required String description,
    required IconData icon,
    required List<Child> children,
    required bool Function(String childId) valueFor,
    required Future<void> Function(String childId, bool enabled) onChanged,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PerChildSettingSheet(
        title: title,
        description: description,
        icon: icon,
        children: children,
        valueFor: valueFor,
        onChanged: onChanged,
      ),
    );
  }

  @override
  State<PerChildSettingSheet> createState() => _PerChildSettingSheetState();
}

class _PerChildSettingSheetState extends State<PerChildSettingSheet> {
  late final Map<String, bool> _values;

  @override
  void initState() {
    super.initState();
    _values = {
      for (final child in widget.children) child.id: widget.valueFor(child.id),
    };
  }

  Future<void> _onToggle(String childId, bool enabled) async {
    setState(() => _values[childId] = enabled);
    try {
      await widget.onChanged(childId, enabled);
    } catch (e) {
      // Revertir si falló la persistencia.
      if (mounted) {
        setState(() => _values[childId] = !enabled);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('No se pudo guardar el cambio: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Row(
              children: [
                Icon(widget.icon, color: colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.description,
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: widget.children.length,
              separatorBuilder: (context, index) => const SizedBox(height: 4),
              itemBuilder: (context, index) {
                final child = widget.children[index];
                final enabled = _values[child.id] ?? false;
                return SwitchListTile(
                  value: enabled,
                  onChanged: (v) => _onToggle(child.id, v),
                  activeThumbColor: colorScheme.primary,
                  secondary: CircleAvatar(
                    backgroundColor: colorScheme.primaryContainer,
                    backgroundImage:
                        (child.photoURL != null && child.photoURL!.isNotEmpty)
                            ? NetworkImage(child.photoURL!)
                            : null,
                    child: (child.photoURL == null || child.photoURL!.isEmpty)
                        ? Text(
                            child.initials,
                            style: TextStyle(
                              color: colorScheme.onPrimaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : null,
                  ),
                  title: Text(
                    child.name,
                    style: TextStyle(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  subtitle: Text(
                    enabled ? 'Activado' : 'Desactivado',
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 12),
        ],
      ),
    );
  }
}
