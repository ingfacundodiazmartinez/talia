import 'package:flutter/material.dart';

/// Widget reutilizable para items de FAQ (Preguntas Frecuentes)
///
/// Responsabilidades:
/// - UI expandible/colapsable para preguntas y respuestas
/// - Animaciones suaves de expansión
/// - Soporte para contenido rico (enlaces, formateo)
///
/// Elimina 6 métodos _buildFAQItem() duplicados en:
/// - help_support_screen.dart
/// - faq_screen.dart
/// - otros archivos con preguntas frecuentes
class FAQItemWidget extends StatefulWidget {
  final String question;
  final String answer;
  final bool initiallyExpanded;
  final IconData? icon;
  final Color? iconColor;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final TextStyle? questionStyle;
  final TextStyle? answerStyle;

  const FAQItemWidget({
    super.key,
    required this.question,
    required this.answer,
    this.initiallyExpanded = false,
    this.icon,
    this.iconColor,
    this.padding,
    this.margin,
    this.questionStyle,
    this.answerStyle,
  });

  @override
  State<FAQItemWidget> createState() => _FAQItemWidgetState();
}

class _FAQItemWidgetState extends State<FAQItemWidget>
    with SingleTickerProviderStateMixin {
  late bool _isExpanded;
  late AnimationController _animationController;
  late Animation<double> _expandAnimation;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.initiallyExpanded;
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _expandAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    );

    if (_isExpanded) {
      _animationController.value = 1.0;
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _animationController.forward();
      } else {
        _animationController.reverse();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      margin: widget.margin ?? const EdgeInsets.symmetric(vertical: 4.0),
      child: Card(
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        child: InkWell(
          onTap: _toggleExpanded,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: widget.padding ?? const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header con pregunta
                Row(
                  children: [
                    if (widget.icon != null) ...[
                      Icon(
                        widget.icon,
                        color: widget.iconColor ?? colorScheme.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                    ],
                    Expanded(
                      child: Text(
                        widget.question,
                        style: widget.questionStyle ??
                          theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onSurface,
                          ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: _isExpanded ? 0.5 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.keyboard_arrow_down,
                        color: colorScheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),

                // Respuesta expandible
                SizeTransition(
                  sizeFactor: _expandAnimation,
                  axisAlignment: 0.0,
                  child: Padding(
                    padding: EdgeInsets.only(
                      top: 12.0,
                      left: widget.icon != null ? 32.0 : 0.0,
                    ),
                    child: Text(
                      widget.answer,
                      style: widget.answerStyle ??
                        theme.textTheme.bodyMedium?.copyWith(
                          color: colorScheme.onSurface.withOpacity(0.8),
                          height: 1.5,
                        ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lista de FAQs con categorías
class FAQListWidget extends StatelessWidget {
  final List<FAQItem> items;
  final String? title;
  final EdgeInsetsGeometry? padding;

  const FAQListWidget({
    super.key,
    required this.items,
    this.title,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: padding ?? const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title!,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
          ],
          ...items.map((item) => FAQItemWidget(
            question: item.question,
            answer: item.answer,
            icon: item.icon,
            iconColor: item.iconColor,
            initiallyExpanded: item.initiallyExpanded,
          )),
        ],
      ),
    );
  }
}

/// Modelo de datos para items de FAQ
class FAQItem {
  final String question;
  final String answer;
  final IconData? icon;
  final Color? iconColor;
  final bool initiallyExpanded;

  const FAQItem({
    required this.question,
    required this.answer,
    this.icon,
    this.iconColor,
    this.initiallyExpanded = false,
  });
}