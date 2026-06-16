import 'package:flutter/material.dart';

/// Widgets reutilizables para explicar el sistema de amigos/historias
/// Usado en: ParentContactsScreen, ChildContactsScreen, AdultContactsScreen

/// Header que aparece arriba de la lista de amigos
class FriendsExplanationHeader extends StatelessWidget {
  const FriendsExplanationHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.auto_stories,
            size: 20,
            color: colorScheme.primary,
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Estas personas pueden ver tus historias',
              style: TextStyle(
                fontSize: 13,
                color: colorScheme.onSurface,
              ),
            ),
          ),
          FriendsInfoButton(),
        ],
      ),
    );
  }
}

/// Card explicativo para el empty state
class FriendsExplanationCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;

  const FriendsExplanationCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 24, color: colorScheme.primary),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurface,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Empty state completo para cuando no hay amigos
class FriendsEmptyState extends StatelessWidget {
  const FriendsEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return SingleChildScrollView(
      padding: EdgeInsets.all(24),
      child: Column(
        children: [
          // Header explicativo
          FriendsExplanationHeader(),
          SizedBox(height: 48),
          // Icono
          Container(
            padding: EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: colorScheme.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.auto_stories,
              size: 48,
              color: colorScheme.primary,
            ),
          ),
          SizedBox(height: 24),
          Text(
            'Tu círculo está vacío',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: colorScheme.onSurface,
            ),
          ),
          SizedBox(height: 16),
          // Explicación del flujo
          FriendsExplanationCard(
            icon: Icons.person_add,
            title: 'Para que vean tus historias',
            description: 'Invitá a alguien a tu círculo desde su perfil',
          ),
          SizedBox(height: 12),
          FriendsExplanationCard(
            icon: Icons.visibility,
            title: 'Para ver historias de otros',
            description: 'Pediles que te inviten a su círculo',
          ),
        ],
      ),
    );
  }
}

/// Info button para mostrar en el tab
class FriendsInfoButton extends StatelessWidget {
  const FriendsInfoButton({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: () => showFriendsExplanationSheet(context),
      child: Icon(
        Icons.info_outline,
        size: 14,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Muestra el bottom sheet con la explicación completa
void showFriendsExplanationSheet(BuildContext context) {
  final colorScheme = Theme.of(context).colorScheme;

  showModalBottomSheet(
    context: context,
    backgroundColor: colorScheme.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => Padding(
      padding: EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_stories, color: colorScheme.primary),
              SizedBox(width: 12),
              Text(
                '¿Cómo funcionan las historias?',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.onSurface,
                ),
              ),
            ],
          ),
          SizedBox(height: 20),
          _ExplanationRow(
            icon: Icons.person_add,
            text: 'Para que alguien vea tus historias, invitalo a tu círculo desde su perfil',
          ),
          SizedBox(height: 12),
          _ExplanationRow(
            icon: Icons.visibility,
            text: 'Para ver las historias de alguien, esa persona tiene que invitarte a su círculo',
          ),
          SizedBox(height: 12),
          _ExplanationRow(
            icon: Icons.swap_horiz,
            text: 'Si ambos se invitan, los dos pueden ver las historias del otro',
          ),
          SizedBox(height: 24),
        ],
      ),
    ),
  );
}

class _ExplanationRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _ExplanationRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: colorScheme.primary),
        SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 14,
              color: colorScheme.onSurface,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
