import 'package:flutter/material.dart';

// Durations comunes para animaciones
class AnimationDurations {
  static const Duration fast = Duration(milliseconds: 200);
  static const Duration medium = Duration(milliseconds: 300);
  static const Duration slow = Duration(milliseconds: 500);
  static const Duration xSlow = Duration(milliseconds: 800);
}

// Curves comunes para animaciones
class AnimationCurves {
  static const Curve smooth = Curves.easeInOut;
  static const Curve bounce = Curves.elasticOut;
  static const Curve quick = Curves.easeOut;
  static const Curve gentle = Curves.easeInOutCubic;
}

// Widget animado para entrada con fade y slide
class FadeSlideIn extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Curve curve;
  final Offset slideOffset;
  final int delay;

  const FadeSlideIn({
    super.key,
    required this.child,
    this.duration = AnimationDurations.medium,
    this.curve = AnimationCurves.smooth,
    this.slideOffset = const Offset(0, 0.3),
    this.delay = 0,
  });

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: widget.duration, vsync: this);

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: widget.curve));

    _slideAnimation = Tween<Offset>(
      begin: widget.slideOffset,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: widget.curve));

    // Aplicar delay si es necesario
    if (widget.delay > 0) {
      Future.delayed(Duration(milliseconds: widget.delay), () {
        if (mounted) _controller.forward();
      });
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(position: _slideAnimation, child: widget.child),
    );
  }
}

// Widget animado para escala al aparecer
class ScaleIn extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Curve curve;
  final int delay;

  const ScaleIn({
    super.key,
    required this.child,
    this.duration = AnimationDurations.medium,
    this.curve = AnimationCurves.bounce,
    this.delay = 0,
  });

  @override
  State<ScaleIn> createState() => _ScaleInState();
}

class _ScaleInState extends State<ScaleIn> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: widget.duration, vsync: this);

    _scaleAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: widget.curve));

    if (widget.delay > 0) {
      Future.delayed(Duration(milliseconds: widget.delay), () {
        if (mounted) _controller.forward();
      });
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: _scaleAnimation, child: widget.child);
  }
}

// Botón animado con efectos hover y press
class AnimatedButton extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPressed;
  final Color? backgroundColor;
  final EdgeInsetsGeometry? padding;
  final BorderRadiusGeometry? borderRadius;

  const AnimatedButton({
    super.key,
    required this.child,
    this.onPressed,
    this.backgroundColor,
    this.padding,
    this.borderRadius,
  });

  @override
  State<AnimatedButton> createState() => _AnimatedButtonState();
}

class _AnimatedButtonState extends State<AnimatedButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: AnimationDurations.fast,
      vsync: this,
    );

    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _controller, curve: AnimationCurves.quick),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) => _controller.reverse(),
      onTapCancel: () => _controller.reverse(),
      onTap: widget.onPressed,
      child: ScaleTransition(
        scale: _scaleAnimation,
        child: Container(
          padding:
              widget.padding ??
              EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: widget.backgroundColor ?? Theme.of(context).primaryColor,
            borderRadius: widget.borderRadius ?? BorderRadius.circular(12),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

// Transición de página personalizada
class SlidePageRoute<T> extends PageRouteBuilder<T> {
  final Widget page;
  final Offset beginOffset;
  final Offset endOffset;

  SlidePageRoute({
    required this.page,
    this.beginOffset = const Offset(1.0, 0.0),
    this.endOffset = Offset.zero,
  }) : super(
         pageBuilder: (context, animation, secondaryAnimation) => page,
         transitionsBuilder: (context, animation, secondaryAnimation, child) {
           return SlideTransition(
             position: Tween<Offset>(begin: beginOffset, end: endOffset)
                 .animate(
                   CurvedAnimation(
                     parent: animation,
                     curve: AnimationCurves.smooth,
                   ),
                 ),
             child: child,
           );
         },
         transitionDuration: AnimationDurations.medium,
       );
}

// Extensión para navegación animada
extension AnimatedNavigation on BuildContext {
  Future<T?> pushSlide<T extends Object?>(
    Widget page, {
    Offset beginOffset = const Offset(1.0, 0.0),
  }) {
    return Navigator.of(
      this,
    ).push<T>(SlidePageRoute<T>(page: page, beginOffset: beginOffset));
  }
}

// Card animado con hover effect
class AnimatedCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry? padding;

  const AnimatedCard({
    super.key,
    required this.child,
    this.onTap,
    this.margin,
    this.padding,
  });

  @override
  State<AnimatedCard> createState() => _AnimatedCardState();
}

class _AnimatedCardState extends State<AnimatedCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _elevationAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: AnimationDurations.fast,
      vsync: this,
    );

    _elevationAnimation = Tween<double>(begin: 4.0, end: 8.0).animate(
      CurvedAnimation(parent: _controller, curve: AnimationCurves.quick),
    );

    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.02).animate(
      CurvedAnimation(parent: _controller, curve: AnimationCurves.quick),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) => _controller.reverse(),
      onTapCancel: () => _controller.reverse(),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: Card(
              margin: widget.margin ?? EdgeInsets.all(8),
              elevation: _elevationAnimation.value,
              child: Container(
                padding: widget.padding ?? EdgeInsets.all(16),
                child: widget.child,
              ),
            ),
          );
        },
      ),
    );
  }
}

// Staggered list animation
class StaggeredList extends StatelessWidget {
  final List<Widget> children;
  final int staggerDelay;
  final Duration duration;

  const StaggeredList({
    super.key,
    required this.children,
    this.staggerDelay = 100,
    this.duration = AnimationDurations.medium,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: children.asMap().entries.map((entry) {
        int index = entry.key;
        Widget child = entry.value;

        return FadeSlideIn(
          delay: index * staggerDelay,
          duration: duration,
          child: child,
        );
      }).toList(),
    );
  }
}
