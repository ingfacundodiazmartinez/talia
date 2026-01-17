import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Widget para detectar rebuilds innecesarios en desarrollo
///
/// Uso:
/// ```dart
/// RebuildDetector(
///   name: 'ChatListItem',
///   child: ChatListItem(...),
/// )
/// ```
///
/// En la consola verás:
/// - 🔄 [RebuildDetector] ChatListItem rebuilt (count: 5)
///
/// Si ves un widget rebuildeando muchas veces sin interacción,
/// probablemente hay un stream o listener innecesario.
class RebuildDetector extends StatefulWidget {
  final String name;
  final Widget child;

  /// Si true, solo loguea en debug mode
  final bool debugOnly;

  /// Intervalo mínimo entre logs (para evitar spam)
  final Duration? throttle;

  const RebuildDetector({
    super.key,
    required this.name,
    required this.child,
    this.debugOnly = true,
    this.throttle,
  });

  @override
  State<RebuildDetector> createState() => _RebuildDetectorState();
}

class _RebuildDetectorState extends State<RebuildDetector> {
  int _rebuildCount = 0;
  DateTime? _lastLogTime;

  @override
  Widget build(BuildContext context) {
    _rebuildCount++;

    final shouldLog = !widget.debugOnly || kDebugMode;

    if (shouldLog) {
      final now = DateTime.now();
      final canLog = widget.throttle == null ||
          _lastLogTime == null ||
          now.difference(_lastLogTime!) > widget.throttle!;

      if (canLog) {
        _lastLogTime = now;
        debugPrint('🔄 [RebuildDetector] ${widget.name} rebuilt (count: $_rebuildCount)');
      }
    }

    return widget.child;
  }
}

/// Extensión para usar de forma más limpia
extension RebuildDetectorExtension on Widget {
  /// Envuelve el widget con RebuildDetector
  ///
  /// Uso:
  /// ```dart
  /// ChatListItem(...).detectRebuilds('ChatListItem')
  /// ```
  Widget detectRebuilds(String name, {Duration? throttle}) {
    if (!kDebugMode) return this;

    return RebuildDetector(
      name: name,
      throttle: throttle,
      child: this,
    );
  }
}
