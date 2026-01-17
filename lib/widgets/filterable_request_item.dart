import 'package:flutter/material.dart';

/// Widget wrapper que maneja el filtrado de solicitudes de lista blanca
/// sin rebuilds innecesarios
class FilterableRequestItem extends StatelessWidget {
  final ValueNotifier<String> searchQuery;
  final String contactName;
  final String childName;
  final Widget child;

  const FilterableRequestItem({
    super.key,
    required this.searchQuery,
    required this.contactName,
    required this.childName,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: searchQuery,
      builder: (context, query, _) {
        // Filtrar por búsqueda
        if (query.isNotEmpty) {
          final matchesContact = contactName.toLowerCase().contains(query);
          final matchesChild = childName.toLowerCase().contains(query);
          if (!matchesContact && !matchesChild) {
            return SizedBox.shrink();
          }
        }

        return child;
      },
    );
  }
}
