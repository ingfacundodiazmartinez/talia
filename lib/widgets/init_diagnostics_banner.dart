import 'package:flutter/material.dart';

import '../utils/init_diagnostics.dart';

/// Banner amarillo persistente que se muestra arriba de la app cuando hay
/// inits problemáticos (failed / timeout / slow >3s). Solo aparece si hay
/// problemas reales — en arranques limpios no se ve nada.
///
/// Pensado como herramienta de diagnóstico para identificar cuál init es el
/// que está causando el lag del primer send tras cold start. Una vez que se
/// identifique el culpable y se arregle, este widget se puede sacar.
class InitDiagnosticsBanner extends StatelessWidget {
  final Widget child;

  const InitDiagnosticsBanner({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<InitEntry>>(
      valueListenable: InitDiagnostics.instance.entries,
      builder: (context, _, _) {
        final problems = InitDiagnostics.instance.problems;
        if (problems.isEmpty || InitDiagnostics.instance.bannerDismissed) {
          return child;
        }
        return Column(
          children: [
            SafeArea(
              bottom: false,
              child: Material(
                color: Colors.amber.shade800,
                child: InkWell(
                  onTap: () => _showDetails(context, problems),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber,
                            color: Colors.white, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _summary(problems),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(Icons.close,
                              color: Colors.white, size: 18),
                          onPressed: () =>
                              InitDiagnostics.instance.dismissBanner(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Expanded(child: child),
          ],
        );
      },
    );
  }

  String _summary(List<InitEntry> problems) {
    final failed = problems.where((e) => e.failed).toList();
    if (failed.isNotEmpty) {
      final first = failed.first.name;
      return failed.length == 1
          ? 'Init falló: $first'
          : 'Init falló: $first +${failed.length - 1} más';
    }
    final slow = problems.where((e) => e.isSlow).toList();
    if (slow.isNotEmpty) {
      final worst = slow.reduce(
          (a, b) => a.duration > b.duration ? a : b);
      return 'Init lento: ${worst.name} (${worst.duration.inMilliseconds}ms)'
          '${slow.length > 1 ? ' +${slow.length - 1} más' : ''}';
    }
    return '${problems.length} inits con problemas';
  }

  void _showDetails(BuildContext context, List<InitEntry> problems) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Init diagnostics'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final p in problems) ...[
                Row(
                  children: [
                    Icon(
                      p.failed
                          ? Icons.error
                          : (p.isSlow ? Icons.timer : Icons.warning),
                      color: p.failed
                          ? Colors.red
                          : (p.isSlow ? Colors.orange : Colors.amber),
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        p.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Text('${p.duration.inMilliseconds}ms'),
                  ],
                ),
                if (p.errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 22, top: 2),
                    child: Text(
                      p.errorMessage!,
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ),
                const Divider(height: 16),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }
}
