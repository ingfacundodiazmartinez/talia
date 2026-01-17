import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

/// Widget reutilizable para avatares circulares con cache persistente
/// Reemplaza CircleAvatar + NetworkImage para evitar re-descargas
class CachedCircleAvatar extends StatelessWidget {
  final String? imageUrl;
  final double radius;
  final String? fallbackText;
  final Color? backgroundColor;
  final Color? textColor;
  final IconData? fallbackIcon;
  final double? iconSize;

  const CachedCircleAvatar({
    super.key,
    this.imageUrl,
    this.radius = 20,
    this.fallbackText,
    this.backgroundColor,
    this.textColor,
    this.fallbackIcon,
    this.iconSize,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bgColor = backgroundColor ?? colorScheme.primaryContainer;
    final fgColor = textColor ?? colorScheme.primary;
    final size = radius * 2;

    Widget fallbackWidget() {
      if (fallbackIcon != null) {
        return Icon(fallbackIcon, size: iconSize ?? radius, color: fgColor);
      }
      final text = fallbackText ?? '';
      final initial = text.isNotEmpty ? text[0].toUpperCase() : '?';
      return Text(
        initial,
        style: TextStyle(
          fontSize: radius * 0.8,
          fontWeight: FontWeight.bold,
          color: fgColor,
        ),
      );
    }

    if (imageUrl == null || imageUrl!.isEmpty) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: bgColor,
        child: fallbackWidget(),
      );
    }

    return CircleAvatar(
      radius: radius,
      backgroundColor: bgColor,
      child: ClipOval(
        child: CachedNetworkImage(
          imageUrl: imageUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          placeholder: (context, url) => fallbackWidget(),
          errorWidget: (context, url, error) => fallbackWidget(),
        ),
      ),
    );
  }
}
