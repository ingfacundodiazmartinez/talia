import 'package:flutter/material.dart';

/// Widget wrapper que maneja el filtrado de contactos sin rebuilds innecesarios
class FilterableContactItem extends StatelessWidget {
  final ValueNotifier<String> searchQuery;
  final String realName;
  final String displayName;
  final Widget child;

  const FilterableContactItem({
    super.key,
    required this.searchQuery,
    required this.realName,
    required this.displayName,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: searchQuery,
      builder: (context, query, _) {
        // Filtrar por búsqueda
        if (query.isNotEmpty) {
          final matchesRealName = realName.toLowerCase().contains(query);
          final matchesAlias = displayName.toLowerCase().contains(query);
          if (!matchesRealName && !matchesAlias) {
            return SizedBox.shrink();
          }
        }

        return child;
      },
    );
  }
}
