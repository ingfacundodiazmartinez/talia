import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/phone_verification_service.dart';

class PhoneVerificationWidget extends StatefulWidget {
  final Function(String phoneNumber) onVerificationSuccess;
  final VoidCallback? onCancel;
  final String? initialCountryCode;
  final String? initialPhoneNumber;

  const PhoneVerificationWidget({
    super.key,
    required this.onVerificationSuccess,
    this.onCancel,
    this.initialCountryCode = '+54', // Argentina por defecto
    this.initialPhoneNumber,
  });

  @override
  State<PhoneVerificationWidget> createState() =>
      _PhoneVerificationWidgetState();
}

class _PhoneVerificationWidgetState extends State<PhoneVerificationWidget>
    with TickerProviderStateMixin {
  final PhoneVerificationService _verificationService =
      PhoneVerificationService();

  // Controllers
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  final PageController _pageController = PageController();
  final FocusNode _codeFocusNode = FocusNode();

  // Animation Controllers
  late AnimationController _buttonController;
  late AnimationController _progressController;
  late Animation<double> _buttonAnimation;
  late Animation<double> _progressAnimation;

  // Estado
  String _selectedCountryCode = '+54';
  int _currentStep = 0; // 0: teléfono, 1: código
  bool _isLoading = false;
  String? _errorMessage;
  String? _verificationId;

  // Countdown para reenvío
  Timer? _countdownTimer;
  int _resendCountdown = 0;

  // Países disponibles
  final List<Map<String, String>> _countries = [
    {'name': 'Argentina', 'code': '+54', 'flag': '🇦🇷'},
    {'name': 'España', 'code': '+34', 'flag': '🇪🇸'},
    {'name': 'México', 'code': '+52', 'flag': '🇲🇽'},
    {'name': 'Colombia', 'code': '+57', 'flag': '🇨🇴'},
    {'name': 'Chile', 'code': '+56', 'flag': '🇨🇱'},
    {'name': 'Perú', 'code': '+51', 'flag': '🇵🇪'},
    {'name': 'Estados Unidos', 'code': '+1', 'flag': '🇺🇸'},
  ];

  @override
  void initState() {
    super.initState();
    _initializeAnimations();
    _selectedCountryCode = widget.initialCountryCode ?? '+54';
    if (widget.initialPhoneNumber != null) {
      _phoneController.text = widget.initialPhoneNumber!;
    }

    // Limpiar cache de Firestore para evitar datos de usuarios previos
    _clearFirestoreCache();
  }

  /// Limpia el cache de Firestore para evitar que un nuevo usuario
  /// vea datos del usuario anterior
  Future<void> _clearFirestoreCache() async {
    try {
      print('🧹 Limpiando cache de Firestore...');
      await FirebaseFirestore.instance.clearPersistence();
      print('✅ Cache de Firestore limpiado exitosamente');
    } catch (e) {
      // ✅ Este error es NORMAL cuando hay listeners activos de Firestore
      // El mensaje de error "failed-precondition" con "ensure it has been indexed"
      // es confuso pero NO significa que falten índices - es un mensaje genérico
      // de Firestore cuando clearPersistence() no puede ejecutarse.
      print('ℹ️ Cache de Firestore no limpiado (normal si hay streams activos)');
    }
  }

  void _initializeAnimations() {
    _buttonController = AnimationController(
      duration: Duration(milliseconds: 300),
      vsync: this,
    );

    _progressController = AnimationController(
      duration: Duration(milliseconds: 1500),
      vsync: this,
    );

    _buttonAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _buttonController, curve: Curves.easeInOut),
    );

    _progressAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _progressController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    _pageController.dispose();
    _codeFocusNode.dispose();
    _buttonController.dispose();
    _progressController.dispose();
    _countdownTimer?.cancel();
    _verificationService.dispose();
    super.dispose();
  }

  Future<void> _sendVerificationCode() async {
    if (_phoneController.text.trim().isEmpty) {
      _setError('Ingresa tu número de teléfono');
      return;
    }

    _setLoading(true);
    _clearError();

    try {
      final result = await _verificationService.startPhoneVerification(
        phoneNumber: _phoneController.text.trim(),
        countryCode: _selectedCountryCode,
        onCodeSent: () {
          _setLoading(false);
          _goToCodeStep();
          _startResendCountdown();
        },
        onError: (error) {
          _setLoading(false);
          _setError(error);
        },
        onTimeout: () {
          _setLoading(false);
          _setError('Tiempo agotado. Intenta de nuevo.');
        },
      );

      if (result.isSuccess) {
        // Verificación automática (Android)
        final phoneNumber =
            '$_selectedCountryCode${_phoneController.text.trim()}';
        widget.onVerificationSuccess(phoneNumber);
      } else if (result.isError) {
        _setError(result.error ?? 'Error desconocido');
      } else if (result.isCodeSent) {
        _verificationId = result.verificationId;
        // Ya se manejó en onCodeSent
      }
    } catch (e) {
      _setLoading(false);
      _setError('Error enviando código: $e');
    }
  }

  Future<void> _verifyCode() async {
    if (_codeController.text.trim().length != 6) {
      _setError('El código debe tener 6 dígitos');
      return;
    }

    _setLoading(true);
    _clearError();

    try {
      final result = await _verificationService.verifyCode(
        _codeController.text.trim(),
      );

      if (result.isSuccess) {
        _setLoading(false);

        // Verificación exitosa
        final phoneNumber =
            '$_selectedCountryCode${_phoneController.text.trim()}';
        widget.onVerificationSuccess(phoneNumber);
      } else {
        _setLoading(false);
        _setError(result.error ?? 'Código incorrecto');
      }
    } catch (e) {
      _setLoading(false);
      _setError('Error verificando código: $e');
    }
  }

  Future<void> _resendCode() async {
    if (_resendCountdown > 0) return;

    _setLoading(true);
    _clearError();

    try {
      final result = await _verificationService.resendCode(
        phoneNumber: _phoneController.text.trim(),
        countryCode: _selectedCountryCode,
        onCodeSent: () {
          _setLoading(false);
          _startResendCountdown();
        },
        onError: (error) {
          _setLoading(false);
          _setError(error);
        },
      );

      if (result.isError) {
        _setError(result.error ?? 'Error reenviando código');
      }
    } catch (e) {
      _setLoading(false);
      _setError('Error reenviando código: $e');
    }
  }

  void _goToCodeStep() {
    setState(() {
      _currentStep = 1;
    });
    _pageController.animateToPage(
      1,
      duration: Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    ).then((_) {
      // Focus automático en el campo del código después de la animación
      Future.delayed(Duration(milliseconds: 100), () {
        if (mounted) {
          _codeFocusNode.requestFocus();
        }
      });
    });
  }

  void _goBackToPhoneStep() {
    setState(() {
      _currentStep = 0;
      _codeController.clear();
    });
    _pageController.animateToPage(
      0,
      duration: Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _startResendCountdown() {
    if (!mounted) return;

    setState(() {
      _resendCountdown = 30;
    });

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      setState(() {
        _resendCountdown--;
      });

      if (_resendCountdown <= 0) {
        timer.cancel();
      }
    });
  }

  void _setLoading(bool loading) {
    if (!mounted) return;

    setState(() {
      _isLoading = loading;
    });

    if (loading) {
      _progressController.repeat();
      _buttonController.forward();
    } else {
      _progressController.stop();
      _buttonController.reverse();
    }
  }

  void _setError(String error) {
    if (!mounted) return;

    setState(() {
      _errorMessage = error;
    });

    // Vibración de error
    HapticFeedback.lightImpact();
  }

  void _clearError() {
    if (!mounted) return;

    setState(() {
      _errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(20), // Reducido para más espacio
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Contenido scrolleable
          Flexible(
            child: SingleChildScrollView(
              // Asegurar que el teclado no tape los elementos
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
              physics: BouncingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildHeader(),
                  SizedBox(height: 20),
                  _buildProgressIndicator(),
                  SizedBox(height: 24),
                  _buildContent(),
                  if (_errorMessage != null) ...[
                    SizedBox(height: 12),
                    _buildErrorMessage(),
                  ],
                ],
              ),
            ),
          ),
          // Botones siempre visibles fuera del scroll
          SizedBox(height: 16),
          _buildActionButton(),
          SizedBox(height: 12),
          _buildSecondaryActions(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Stack(
      children: [
        Column(
          children: [
            Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Color(0xFF9D7FE8).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.phone_android, size: 32, color: Color(0xFF9D7FE8)),
            ),
            SizedBox(height: 16),
            Text(
              _currentStep == 0 ? 'Verificar Teléfono' : 'Código de Verificación',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF2D3142),
              ),
            ),
            SizedBox(height: 8),
            Text(
              _currentStep == 0
                  ? 'Ingresa tu número de teléfono para recibir un código de verificación'
                  : 'Ingresa el código de 6 dígitos que enviamos a $_selectedCountryCode ${_phoneController.text}',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey[600]),
            ),
          ],
        ),
        // Mostrar icono de ayuda solo en modo no-producción
        if (!kReleaseMode)
          Positioned(
            top: 0,
            right: 0,
            child: IconButton(
              icon: Icon(Icons.help_outline, size: 20, color: Colors.grey[600]),
              onPressed: _showDebugTokenDialog,
              tooltip: 'Ver Debug Token',
            ),
          ),
      ],
    );
  }

  Widget _buildProgressIndicator() {
    return Row(
      children: [
        _buildStepIndicator(0, 'Teléfono'),
        Expanded(
          child: Container(
            height: 2,
            margin: EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: _currentStep >= 1 ? Color(0xFF9D7FE8) : Colors.grey[300],
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ),
        _buildStepIndicator(1, 'Código'),
      ],
    );
  }

  Widget _buildStepIndicator(int step, String label) {
    final isActive = _currentStep >= step;
    final isCompleted = _currentStep > step;

    return Column(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: isActive ? Color(0xFF9D7FE8) : Colors.grey[300],
            shape: BoxShape.circle,
          ),
          child: Icon(
            isCompleted ? Icons.check : Icons.circle,
            size: 16,
            color: Colors.white,
          ),
        ),
        SizedBox(height: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isActive ? Color(0xFF9D7FE8) : Colors.grey[600],
            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    return SizedBox(
      height: 80, // Reducido para dar más espacio a los botones
      child: PageView(
        controller: _pageController,
        physics: NeverScrollableScrollPhysics(),
        children: [_buildPhoneStep(), _buildCodeStep()],
      ),
    );
  }

  Widget _buildPhoneStep() {
    return Column(
      children: [
        Row(
          children: [
            _buildCountrySelector(),
            SizedBox(width: 12),
            Expanded(child: _buildPhoneInput()),
          ],
        ),
      ],
    );
  }

  Widget _buildCountrySelector() {
    final selectedCountry = _countries.firstWhere(
      (country) => country['code'] == _selectedCountryCode,
      orElse: () => _countries.first,
    );

    return GestureDetector(
      onTap: _showCountrySelector,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey[300]!),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(selectedCountry['flag']!, style: TextStyle(fontSize: 24)),
            SizedBox(width: 4),
            Icon(Icons.arrow_drop_down, color: Colors.grey[600], size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildPhoneInput() {
    return TextField(
      controller: _phoneController,
      keyboardType: TextInputType.phone,
      enabled: _currentStep == 0, // Deshabilitar cuando estamos en el paso del código
      decoration: InputDecoration(
        labelText: 'Número de teléfono',
        hintText: '11 1234 5678',
        prefixIcon: Padding(
          padding: EdgeInsets.only(left: 12, right: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _selectedCountryCode,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF9D7FE8),
                ),
              ),
            ],
          ),
        ),
        prefixIconConstraints: BoxConstraints(minWidth: 0, minHeight: 0),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Color(0xFF9D7FE8)),
        ),
      ),
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(15),
      ],
      onChanged: (value) => _clearError(),
    );
  }

  Widget _buildCodeStep() {
    return Column(
      children: [
        TextField(
          controller: _codeController,
          focusNode: _codeFocusNode,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          autofocus: true,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            letterSpacing: 8,
          ),
          decoration: InputDecoration(
            labelText: 'Código de verificación',
            hintText: '123456',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Color(0xFF9D7FE8)),
            ),
          ),
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          onChanged: (value) {
            _clearError();
            if (value.length == 6) {
              _verifyCode();
            }
          },
        ),
      ],
    );
  }

  Widget _buildErrorMessage() {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Colors.red, size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMessage!,
              style: TextStyle(color: Colors.red[700], fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton() {
    return AnimatedBuilder(
      animation: _buttonAnimation,
      builder: (context, child) {
        return Transform.scale(
          scale: _buttonAnimation.value,
          child: SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: _isLoading
                  ? null
                  : (_currentStep == 0 ? _sendVerificationCode : _verifyCode),
              style: ElevatedButton.styleFrom(
                backgroundColor: Color(0xFF9D7FE8),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              child: _isLoading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Text(
                      _currentStep == 0 ? 'Enviar Código' : 'Verificar',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSecondaryActions() {
    if (_currentStep == 0) {
      return TextButton(
        onPressed: widget.onCancel,
        child: Text('Cancelar', style: TextStyle(color: Colors.grey[600])),
      );
    }

    return Column(
      children: [
        if (_resendCountdown > 0)
          Text(
            'Reenviar código en $_resendCountdown segundos',
            style: TextStyle(color: Colors.grey[600], fontSize: 14),
          )
        else
          TextButton(
            onPressed: _isLoading ? null : _resendCode,
            child: Text(
              'Reenviar código',
              style: TextStyle(color: Color(0xFF9D7FE8)),
            ),
          ),
        TextButton(
          onPressed: _goBackToPhoneStep,
          child: Text(
            'Cambiar número',
            style: TextStyle(color: Colors.grey[600]),
          ),
        ),
      ],
    );
  }

  Future<void> _showDebugTokenDialog() async {
    try {
      // Mostrar diálogo de carga
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Center(
          child: CircularProgressIndicator(),
        ),
      );

      // Obtener el token de App Check
      final token = await FirebaseAppCheck.instance.getToken();

      // Cerrar diálogo de carga
      Navigator.of(context).pop();

      // Mostrar el token
      if (token != null) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Row(
              children: [
                Icon(Icons.info_outline, color: Color(0xFF9D7FE8)),
                SizedBox(width: 8),
                Text('Debug Token'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Token de App Check para desarrollo:',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[700],
                  ),
                ),
                SizedBox(height: 12),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: SelectableText(
                    token,
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: Colors.black87,
                    ),
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  'Registra este token en Firebase Console:',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                SizedBox(height: 4),
                Text(
                  'App Check > Apps > com.talia.chat > Manage debug tokens',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[500],
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: token));
                  Navigator.of(context).pop();
                },
                child: Text('Copiar'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text('Cerrar'),
              ),
            ],
          ),
        );
      } else {
        _showErrorDialog('No se pudo obtener el token de App Check');
      }
    } catch (e) {
      // Cerrar diálogo de carga si está abierto
      Navigator.of(context).pop();
      _showErrorDialog('Error obteniendo token: $e');
    }
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red),
            SizedBox(width: 8),
            Text('Error'),
          ],
        ),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  void _showCountrySelector() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.6,
        padding: EdgeInsets.all(16),
        child: Column(
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            SizedBox(height: 16),
            Text(
              'Seleccionar País',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            Expanded(
              child: ListView.builder(
                itemCount: _countries.length,
                itemBuilder: (context, index) {
                  final country = _countries[index];
                  final isSelected = country['code'] == _selectedCountryCode;

                  return ListTile(
                    leading: Text(
                      country['flag']!,
                      style: TextStyle(fontSize: 24),
                    ),
                    title: Text(country['name']!),
                    trailing: Text(
                      country['code']!,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: isSelected
                            ? Color(0xFF9D7FE8)
                            : Colors.grey[600],
                      ),
                    ),
                    selected: isSelected,
                    selectedTileColor: Color(0xFF9D7FE8).withOpacity(0.1),
                    onTap: () {
                      setState(() {
                        _selectedCountryCode = country['code']!;
                      });
                      Navigator.pop(context);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
