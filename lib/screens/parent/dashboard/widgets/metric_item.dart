import 'package:flutter/material.dart';

class MetricItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool isAlert;
  final VoidCallback? onTap;

  const MetricItem({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.isAlert = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final child = Container(
      margin: EdgeInsets.symmetric(horizontal: 4),
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isAlert
              ? Colors.red.withValues(alpha: 0.3)
              : Colors.white.withValues(alpha: 0.2),
          width: 1.5,
        ),
        boxShadow: isAlert
            ? [
                BoxShadow(
                  color: Colors.red.withValues(alpha: 0.2),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isAlert
                  ? Colors.red.withValues(alpha: 0.2)
                  : Colors.white.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: isAlert ? Colors.red[100] : Colors.white,
              size: 20,
            ),
          ),
          SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: 0.5,
            ),
          ),
          SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: 0.85),
              fontWeight: FontWeight.w500,
              height: 1.2,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );

    // Si hay onTap, hacer clickeable
    if (onTap != null) {
      return Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: child,
        ),
      );
    }

    return Expanded(child: child);
  }
}
