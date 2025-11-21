/// Caller Avatar Widget
///
/// Displays a circular avatar with a pulsing animation for incoming calls.
/// ✅ PHASE 1C: Provides a beautiful visual indicator during ringing state.

import 'package:flutter/material.dart';

class CallerAvatar extends StatefulWidget {
  final String callerName;
  final String? photoUrl;
  final double size;
  final bool animate;

  const CallerAvatar({
    Key? key,
    required this.callerName,
    this.photoUrl,
    this.size = 120.0,
    this.animate = true,
  }) : super(key: key);

  @override
  State<CallerAvatar> createState() => _CallerAvatarState();
}

class _CallerAvatarState extends State<CallerAvatar>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();

    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 1.15,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeInOut,
    ));

    if (widget.animate) {
      _animationController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(CallerAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.animate != oldWidget.animate) {
      if (widget.animate) {
        _animationController.repeat(reverse: true);
      } else {
        _animationController.stop();
        _animationController.reset();
      }
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  String _getInitials(String name) {
    final parts = name.trim().split(' ');
    if (parts.isEmpty) return '?';

    if (parts.length == 1) {
      return parts[0].substring(0, 1).toUpperCase();
    }

    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animationController,
      builder: (context, child) {
        return Stack(
          alignment: Alignment.center,
          children: [
            // Outer pulsing circle (glow effect)
            if (widget.animate)
              Container(
                width: widget.size * _scaleAnimation.value * 1.3,
                height: widget.size * _scaleAnimation.value * 1.3,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withOpacity(0.1 * (1 - (_scaleAnimation.value - 1) / 0.15)),
                ),
              ),

            // Middle pulsing circle
            if (widget.animate)
              Container(
                width: widget.size * _scaleAnimation.value * 1.15,
                height: widget.size * _scaleAnimation.value * 1.15,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(context)
                      .colorScheme
                      .primary
                      .withOpacity(0.15 * (1 - (_scaleAnimation.value - 1) / 0.15)),
                ),
              ),

            // Avatar container
            Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white,
                  width: 4,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: child,
            ),
          ],
        );
      },
      child: widget.photoUrl != null && widget.photoUrl!.isNotEmpty
          ? CircleAvatar(
              radius: widget.size / 2,
              backgroundImage: NetworkImage(widget.photoUrl!),
              backgroundColor: Theme.of(context).colorScheme.primary,
              onBackgroundImageError: (_, __) {
                // Fallback to initials if image fails
              },
              child: null,
            )
          : CircleAvatar(
              radius: widget.size / 2,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: Text(
                _getInitials(widget.callerName),
                style: TextStyle(
                  fontSize: widget.size * 0.4,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
    );
  }
}
