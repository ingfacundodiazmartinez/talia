import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/emergency_service.dart';

class EmergencyButton extends StatefulWidget {
  final VoidCallback? onEmergencyActivated;
  final bool isFloating;
  final double size;

  const EmergencyButton({
    super.key,
    this.onEmergencyActivated,
    this.isFloating = false,
    this.size = 80.0,
  });

  @override
  State<EmergencyButton> createState() => _EmergencyButtonState();
}

class _EmergencyButtonState extends State<EmergencyButton>
    with TickerProviderStateMixin {
  final EmergencyService _emergencyService = EmergencyService();

  late AnimationController _pulseController;
  late AnimationController _pressController;
  late Animation<double> _pulseAnimation;
  late Animation<double> _scaleAnimation;

  bool _isPressed = false;
  bool _isActivating = false;
  bool _isInCooldown = false;

  @override
  void initState() {
    super.initState();
    _initializeAnimations();
    _checkCooldownStatus();
  }

  void _initializeAnimations() {
    // Animación de pulso continuo
    _pulseController = AnimationController(
      duration: Duration(seconds: 2),
      vsync: this,
    );

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.1).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Animación de presión
    _pressController = AnimationController(
      duration: Duration(milliseconds: 150),
      vsync: this,
    );

    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.9).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeInOut),
    );

    // Iniciar pulso continuo
    _pulseController.repeat(reverse: true);
  }

  Future<void> _checkCooldownStatus() async {
    final inCooldown = await _emergencyService.isInCooldown();
    if (mounted) {
      setState(() {
        _isInCooldown = inCooldown;
      });
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _pressController.dispose();
    super.dispose();
  }

  Future<void> _onEmergencyPressed() async {
    if (_isActivating || _isInCooldown) return;

    setState(() {
      _isPressed = true;
      _isActivating = true;
    });

    // Animación de presión
    await _pressController.forward();

    // Vibración fuerte
    HapticFeedback.heavyImpact();

    // Mostrar diálogo de confirmación
    final confirmed = await _showConfirmationDialog();

    if (confirmed) {
      // Activar emergencia
      final success = await _emergencyService.activateEmergency(
        context: context,
      );

      if (success) {
        widget.onEmergencyActivated?.call();

        // Actualizar estado de cooldown
        setState(() {
          _isInCooldown = true;
        });

        // Programar verificación de cooldown
        Future.delayed(Duration(minutes: 2), () {
          if (mounted) {
            _checkCooldownStatus();
          }
        });
      }
    }

    // Resetear animación
    await _pressController.reverse();

    if (mounted) {
      setState(() {
        _isPressed = false;
        _isActivating = false;
      });
    }
  }

  Future<bool> _showConfirmationDialog() async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) {
            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.red, size: 28),
                  SizedBox(width: 8),
                  Text(
                    'Confirmar Emergencia',
                    style: TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '¿Estás seguro de que quieres activar el botón de emergencia?',
                    style: TextStyle(fontSize: 16),
                  ),
                  SizedBox(height: 12),
                  Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '• Se notificará a tus padres inmediatamente\n'
                      '• Se enviará tu ubicación actual\n'
                      '• Se realizará una llamada automática',
                      style: TextStyle(fontSize: 14, color: Colors.red[700]),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(
                    'Cancelar',
                    style: TextStyle(color: Colors.grey[600], fontSize: 16),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    'SÍ, ES EMERGENCIA',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_pulseAnimation, _scaleAnimation]),
      builder: (context, child) {
        return Transform.scale(
          scale:
              _scaleAnimation.value *
              (_isInCooldown ? 1.0 : _pulseAnimation.value),
          child: GestureDetector(
            onTap: _isInCooldown ? null : _onEmergencyPressed,
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: _isInCooldown
                    ? LinearGradient(
                        colors: [Colors.grey[400]!, Colors.grey[600]!],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : LinearGradient(
                        colors: [Colors.red[400]!, Colors.red[600]!],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                boxShadow: [
                  BoxShadow(
                    color: (_isInCooldown ? Colors.grey : Colors.red)
                        .withValues(alpha: 0.3),
                    blurRadius: 15,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Círculo interior
                  Container(
                    width: widget.size * 0.7,
                    height: widget.size * 0.7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                    ),
                  ),

                  // Contenido del botón
                  if (_isActivating)
                    SizedBox(
                      width: widget.size * 0.4,
                      height: widget.size * 0.4,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: Colors.red,
                      ),
                    )
                  else if (_isInCooldown)
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.access_time,
                          color: Colors.grey[600],
                          size: widget.size * 0.25,
                        ),
                        SizedBox(height: 2),
                        Text(
                          'ESPERA',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: widget.size * 0.1,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    )
                  else
                    Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.emergency,
                          color: Colors.red,
                          size: widget.size * 0.3,
                        ),
                        SizedBox(height: 2),
                        Text(
                          'SOS',
                          style: TextStyle(
                            color: Colors.red,
                            fontSize: widget.size * 0.15,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// Widget de botón de emergencia flotante
class FloatingEmergencyButton extends StatelessWidget {
  final VoidCallback? onEmergencyActivated;

  const FloatingEmergencyButton({super.key, this.onEmergencyActivated});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 20,
      right: 20,
      child: EmergencyButton(
        isFloating: true,
        size: 70,
        onEmergencyActivated: onEmergencyActivated,
      ),
    );
  }
}

// Widget de botón de emergencia para la barra superior
class HeaderEmergencyButton extends StatelessWidget {
  final VoidCallback? onEmergencyActivated;

  const HeaderEmergencyButton({super.key, this.onEmergencyActivated});

  @override
  Widget build(BuildContext context) {
    return EmergencyButton(
      size: 50,
      onEmergencyActivated: onEmergencyActivated,
    );
  }
}
