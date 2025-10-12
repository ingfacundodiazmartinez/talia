import 'package:flutter/material.dart';
import 'dart:async';
import '../services/offline_queue_service.dart';
import '../services/network_status_service.dart';

/// Widget que muestra el estado de sincronización offline
///
/// Muestra:
/// - Indicador cuando hay operaciones pendientes
/// - Progreso de sincronización
/// - Estado de conexión
class OfflineSyncIndicator extends StatefulWidget {
  final bool showWhenEmpty;

  const OfflineSyncIndicator({
    super.key,
    this.showWhenEmpty = false,
  });

  @override
  State<OfflineSyncIndicator> createState() => _OfflineSyncIndicatorState();
}

class _OfflineSyncIndicatorState extends State<OfflineSyncIndicator> {
  StreamSubscription<bool>? _networkSubscription;
  Timer? _updateTimer;
  int _pendingCount = 0;
  bool _isConnected = true;

  @override
  void initState() {
    super.initState();
    _updatePendingCount();

    // Actualizar cada 2 segundos
    _updateTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _updatePendingCount();
    });

    // Escuchar cambios de red
    _networkSubscription = NetworkStatusService().connectionStatus.listen(
      (isConnected) {
        setState(() {
          _isConnected = isConnected;
        });
      },
    );
  }

  @override
  void dispose() {
    _networkSubscription?.cancel();
    _updateTimer?.cancel();
    super.dispose();
  }

  void _updatePendingCount() {
    final count = offlineQueue.pendingOperationsCount;
    if (count != _pendingCount) {
      setState(() {
        _pendingCount = count;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // No mostrar si no hay operaciones pendientes y showWhenEmpty es false
    if (_pendingCount == 0 && !widget.showWhenEmpty) {
      return const SizedBox.shrink();
    }

    // Determinar color e icono según estado
    Color backgroundColor;
    IconData icon;
    String message;

    if (!_isConnected) {
      backgroundColor = Colors.orange.shade600;
      icon = Icons.cloud_off;
      message = _pendingCount > 0
          ? '$_pendingCount operaciones pendientes'
          : 'Sin conexión';
    } else if (_pendingCount > 0) {
      backgroundColor = Colors.blue.shade600;
      icon = Icons.cloud_sync;
      message = 'Sincronizando $_pendingCount operaciones...';
    } else {
      backgroundColor = Colors.green.shade600;
      icon = Icons.cloud_done;
      message = 'Todo sincronizado';
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 6),
          Text(
            message,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (_pendingCount > 0 && _isConnected) ...[
            const SizedBox(width: 6),
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Widget flotante que muestra el estado de sincronización en la esquina
class FloatingOfflineSyncIndicator extends StatelessWidget {
  const FloatingOfflineSyncIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 16,
      right: 16,
      child: SafeArea(
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(20),
          child: const OfflineSyncIndicator(showWhenEmpty: false),
        ),
      ),
    );
  }
}

/// Bottom sheet para mostrar detalles de operaciones pendientes
class PendingOperationsSheet extends StatelessWidget {
  const PendingOperationsSheet({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) => const PendingOperationsSheet(),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final operations = offlineQueue.getPendingOperations();

    return Container(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Operaciones Pendientes',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const Divider(),
          if (operations.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Column(
                  children: [
                    Icon(Icons.cloud_done, size: 48, color: Colors.green),
                    SizedBox(height: 8),
                    Text('No hay operaciones pendientes'),
                  ],
                ),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: operations.length,
                itemBuilder: (context, index) {
                  final op = operations[index];
                  return ListTile(
                    leading: _getOperationIcon(op['type'] as String),
                    title: Text(_getOperationTitle(op['type'] as String)),
                    subtitle: Text(
                      'Prioridad: ${op['priority']} | Reintentos: ${op['retryCount']}',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () {
                        offlineQueue.cancelOperation(op['id'] as String);
                        Navigator.pop(context);
                        PendingOperationsSheet.show(context);
                      },
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 16),
          if (operations.isNotEmpty) ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      offlineQueue.clearQueue();
                      Navigator.pop(context);
                    },
                    child: const Text('Limpiar Todo'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      offlineQueue.syncPendingOperations();
                      Navigator.pop(context);
                    },
                    child: const Text('Sincronizar Ahora'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Icon _getOperationIcon(String type) {
    switch (type) {
      case OfflineQueueService.OP_SEND_MESSAGE:
        return const Icon(Icons.message, color: Colors.blue);
      case OfflineQueueService.OP_UPDATE_PROFILE:
        return const Icon(Icons.person, color: Colors.purple);
      case OfflineQueueService.OP_UPLOAD_FILE:
        return const Icon(Icons.upload_file, color: Colors.orange);
      case OfflineQueueService.OP_CREATE_EMERGENCY:
        return const Icon(Icons.emergency, color: Colors.red);
      case OfflineQueueService.OP_BLOCK_USER:
        return const Icon(Icons.block, color: Colors.red);
      case OfflineQueueService.OP_UNBLOCK_USER:
        return const Icon(Icons.check_circle, color: Colors.green);
      default:
        return const Icon(Icons.settings, color: Colors.grey);
    }
  }

  String _getOperationTitle(String type) {
    switch (type) {
      case OfflineQueueService.OP_SEND_MESSAGE:
        return 'Enviar mensaje';
      case OfflineQueueService.OP_UPDATE_PROFILE:
        return 'Actualizar perfil';
      case OfflineQueueService.OP_UPLOAD_FILE:
        return 'Subir archivo';
      case OfflineQueueService.OP_CREATE_EMERGENCY:
        return 'Crear emergencia';
      case OfflineQueueService.OP_BLOCK_USER:
        return 'Bloquear usuario';
      case OfflineQueueService.OP_UNBLOCK_USER:
        return 'Desbloquear usuario';
      default:
        return 'Operación desconocida';
    }
  }
}
