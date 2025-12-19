import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import 'dart:math';
import 'services/user_role_service.dart';
import 'services/user_cache_service.dart';
import 'widgets/location_permission_dialog.dart';
import 'utils/release_logger.dart';

// ================ PANTALLA PARA PADRES ================
class GenerateLinkCodeScreen extends StatefulWidget {
  const GenerateLinkCodeScreen({super.key});

  @override
  State<GenerateLinkCodeScreen> createState() => _GenerateLinkCodeScreenState();
}

class _GenerateLinkCodeScreenState extends State<GenerateLinkCodeScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  String? _linkCode;
  bool _isGenerating = false;
  DateTime? _expiryTime;
  Timer? _countdownTimer;
  Duration _timeRemaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    _checkExistingCode();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _startCountdownTimer() {
    _countdownTimer?.cancel();

    if (_expiryTime == null) {
      setState(() {
        _timeRemaining = Duration.zero;
      });
      return;
    }

    _updateTimeRemaining();

    _countdownTimer = Timer.periodic(Duration(seconds: 1), (_) {
      _updateTimeRemaining();
    });
  }

  void _updateTimeRemaining() {
    if (_expiryTime == null) return;

    final now = DateTime.now();
    final remaining = _expiryTime!.difference(now);

    setState(() {
      _timeRemaining = remaining.isNegative ? Duration.zero : remaining;
    });

    // Si expiró, limpiar el código
    if (remaining.isNegative) {
      _countdownTimer?.cancel();
      setState(() {
        _linkCode = null;
        _expiryTime = null;
      });
    }
  }

  Color _getExpirationColor() {
    if (_timeRemaining.inSeconds <= 0) return Colors.red;
    if (_timeRemaining.inMinutes < 1) return Colors.orange;
    return Colors.green;
  }

  Future<void> _checkExistingCode() async {
    try {
      final parentId = _auth.currentUser?.uid;
      if (parentId == null) return;

      final doc = await _firestore
          .collection('link_codes')
          .where('createdBy', isEqualTo: parentId)
          .where('isActive', isEqualTo: true)
          .limit(1)
          .get();

      if (doc.docs.isNotEmpty) {
        final data = doc.docs.first.data();
        final expiry = (data['expiresAt'] as Timestamp).toDate();

        if (expiry.isAfter(DateTime.now())) {
          setState(() {
            _linkCode = data['code'];
            _expiryTime = expiry;
          });
          _startCountdownTimer();
        }
      }
    } catch (e) {
      ReleaseLogger.error('Error checking existing code: $e', tag: 'LinkParentChild');
    }
  }

  Future<void> _generateLinkCode() async {
    setState(() => _isGenerating = true);

    try {
      final parentId = _auth.currentUser?.uid;
      if (parentId == null) return;

      // Desactivar códigos anteriores
      final oldCodes = await _firestore
          .collection('link_codes')
          .where('createdBy', isEqualTo: parentId)
          .where('isActive', isEqualTo: true)
          .get();

      for (var doc in oldCodes.docs) {
        await doc.reference.update({'isActive': false});
      }

      // Generar código de 6 dígitos
      final code = _generateRandomCode();
      final expiresAt = DateTime.now().add(Duration(minutes: 5));
      final deleteAt = DateTime.now().add(Duration(minutes: 5)); // TTL para Firestore

      // Guardar en Firestore
      await _firestore.collection('link_codes').add({
        'code': code,
        'parentId': parentId,
        'createdBy': parentId, // Requerido por reglas de seguridad
        'isActive': true,
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(expiresAt),
        'deleteAt': Timestamp.fromDate(deleteAt), // TTL: 5 minutos
        'used': false,
      });

      setState(() {
        _linkCode = code;
        _expiryTime = expiresAt;
      });
      _startCountdownTimer();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      setState(() => _isGenerating = false);
    }
  }

  String _generateRandomCode() {
    final random = Random();
    return List.generate(6, (_) => random.nextInt(10)).join();
  }

  void _copyToClipboard() {
    if (_linkCode != null) {
      Clipboard.setData(ClipboardData(text: _linkCode!));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('📋 Código copiado al portapapeles'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  String _formatTimeRemaining() {
    if (_timeRemaining.inSeconds <= 0) return 'Expirado';

    final minutes = _timeRemaining.inMinutes;
    final seconds = _timeRemaining.inSeconds.remainder(60);
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
  }

  bool get _isExpired => _timeRemaining.inSeconds <= 0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text('Vincular Hijo'),
        backgroundColor: isDarkMode ? colorScheme.surface : colorScheme.primary,
        foregroundColor: isDarkMode ? colorScheme.onSurface : colorScheme.onPrimary,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDarkMode
                ? [
                    colorScheme.primary.withValues(alpha: 0.3),
                    colorScheme.surface,
                  ]
                : [
                    colorScheme.primary.withOpacity(0.1),
                    colorScheme.surface,
                  ],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.link,
                    size: 80,
                    color: colorScheme.primary,
                  ),
                ),

                SizedBox(height: 32),

                Text(
                  'Código de Vinculación',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),

                SizedBox(height: 16),

                Text(
                  'Comparte este código con tu hijo para vincular su cuenta',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),

                SizedBox(height: 40),

                if (_linkCode != null) ...[
                  // Countdown banner
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: _getExpirationColor().withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _getExpirationColor().withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _isExpired ? Icons.timer_off : Icons.timer,
                          color: _getExpirationColor(),
                          size: 20,
                        ),
                        SizedBox(width: 8),
                        Text(
                          _isExpired ? 'Codigo expirado' : 'Expira en: ${_formatTimeRemaining()}',
                          style: TextStyle(
                            color: _getExpirationColor(),
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        if (_isExpired) ...[
                          SizedBox(width: 12),
                          TextButton(
                            onPressed: _generateLinkCode,
                            style: TextButton.styleFrom(
                              foregroundColor: _getExpirationColor(),
                              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                            ),
                            child: Text('Regenerar'),
                          ),
                        ],
                      ],
                    ),
                  ),

                  SizedBox(height: 16),

                  // Code display card
                  Container(
                    padding: EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: isDarkMode
                          ? colorScheme.surfaceContainerHighest
                          : colorScheme.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: isDarkMode
                          ? Border.all(
                              color: colorScheme.outline.withValues(alpha: 0.3),
                              width: 1,
                            )
                          : null,
                      boxShadow: isDarkMode
                          ? null
                          : [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.1),
                                blurRadius: 20,
                                offset: Offset(0, 10),
                              ),
                            ],
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Opacity(
                          opacity: _isExpired ? 0.3 : 1.0,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              _linkCode!.split('').join(' '),
                              style: TextStyle(
                                fontSize: 48,
                                fontWeight: FontWeight.bold,
                                color: colorScheme.primary,
                                letterSpacing: 8,
                                decoration: _isExpired ? TextDecoration.lineThrough : null,
                              ),
                            ),
                          ),
                        ),
                        if (_isExpired)
                          Container(
                            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'EXPIRADO',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),

                  SizedBox(height: 24),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _isExpired ? null : _copyToClipboard,
                        icon: Icon(Icons.copy),
                        label: Text('Copiar'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: colorScheme.primary,
                          side: BorderSide(color: _isExpired ? Colors.grey : colorScheme.primary),
                          padding: EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                      SizedBox(width: 16),
                      OutlinedButton.icon(
                        onPressed: _generateLinkCode,
                        icon: Icon(Icons.refresh),
                        label: Text('Nuevo'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: colorScheme.tertiary,
                          side: BorderSide(color: colorScheme.tertiary),
                          padding: EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ] else ...[
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: _isGenerating ? null : _generateLinkCode,
                      icon: _isGenerating
                          ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Icon(Icons.add_link),
                      label: Text(
                        _isGenerating ? 'Generando...' : 'Generar Código',
                        style: TextStyle(fontSize: 18),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colorScheme.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                ],

                SizedBox(height: 40),

                Container(
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.blue),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'El codigo expira en 5 minutos y solo puede usarse una vez',
                          style: TextStyle(
                            fontSize: 14,
                            color: isDarkMode
                                ? Colors.blue.shade200
                                : Colors.blue.shade800,
                          ),
                        ),
                      ),
                    ],
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

// ================ PANTALLA PARA HIJOS ================
class EnterLinkCodeScreen extends StatefulWidget {
  const EnterLinkCodeScreen({super.key});

  @override
  State<EnterLinkCodeScreen> createState() => _EnterLinkCodeScreenState();
}

class _EnterLinkCodeScreenState extends State<EnterLinkCodeScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final TextEditingController _codeController = TextEditingController();
  bool _isVerifying = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _verifyAndLink() async {
    final code = _codeController.text.trim().replaceAll(' ', '');

    if (code.length != 6) {
      return;
    }

    setState(() => _isVerifying = true);

    try {
      final childId = _auth.currentUser?.uid;
      if (childId == null) return;

      // 🔒 SEGURIDAD: Usar Cloud Function para validar código
      // Esto previene enumeración de códigos de otros usuarios
      final functions = FirebaseFunctions.instance;
      final validateResult = await functions.httpsCallable('validateLinkCode').call({
        'code': code,
      });

      final validationData = validateResult.data as Map<String, dynamic>;

      if (validationData['valid'] != true) {
        final error = validationData['error'] ?? 'Código inválido o expirado';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ $error'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // Si ya está vinculado
      if (validationData['alreadyLinked'] == true) {
        ReleaseLogger.log('Ya existe un vínculo activo entre este padre e hijo', tag: 'LinkParentChild');
        Navigator.of(context).pop(false);
        return;
      }

      final parentId = validationData['parentId'] as String;

      // Verificar si ya está vinculado con otro padre usando parent_children
      final userRoleService = UserRoleService();
      final existingParents = await userRoleService.getLinkedParents(childId);

      if (existingParents.isNotEmpty && !existingParents.contains(parentId)) {
        // Ya tiene un padre - requiere aprobación del primer padre
        ReleaseLogger.log('El niño ya tiene un padre. Creando solicitud de aprobación...', tag: 'LinkParentChild');

        await _createParentApprovalRequest(
          childId: childId,
          existingParentId: existingParents.first,
          newParentId: parentId,
          linkCode: code, // Usar código en lugar de docId para seguridad
        );

        Navigator.of(context).pop(true);
        return;
      }

      ReleaseLogger.log('Vinculando hijo $childId con padre $parentId', tag: 'LinkParentChild');

      // 🔒 SEGURIDAD: Usar Cloud Function para crear vínculo
      // Las Firestore rules ahora bloquean la escritura directa
      try {
        final functions = FirebaseFunctions.instance;
        final result = await functions.httpsCallable('createParentChildLink').call({
          'parentId': parentId,
          'childId': childId,
          'code': code,
        });

        if (result.data['success'] == true) {
          ReleaseLogger.log('Vínculo creado por Cloud Function - Padre: ${result.data['parentName']}, Hijo: ${result.data['childName']}', tag: 'LinkParentChild');

          // Cachear datos del padre en Hive para que aparezca correctamente en contactos
          await UserCacheService().refreshUser(parentId);
        } else {
          throw Exception('Error en Cloud Function: ${result.data['message'] ?? 'Unknown error'}');
        }
      } catch (e) {
        ReleaseLogger.error('Error al llamar Cloud Function: $e', tag: 'LinkParentChild');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Error al crear vínculo: $e'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 4),
          ),
        );
        return;
      }

      // NOTA: Código de migración de whitelist deshabilitado (colección eliminada)
      // El sistema ahora usa 'contacts' y 'parent_children'
      /*
      print('🔄 Migrando contactos existentes del niño al padre...');
      final existingContacts = await _firestore
          .collection('whitelist')
          .where('childId', isEqualTo: childId)
          .get();

      int migratedCount = 0;
      for (var contactDoc in existingContacts.docs) {
        final contactData = contactDoc.data();
        final contactId = contactData['contactId'];

        if (contactId == parentId) continue;

        final existingApproval = await _firestore
            .collection('whitelist')
            .where('childId', isEqualTo: childId)
            .where('contactId', isEqualTo: contactId)
            .where('approvedBy', isEqualTo: parentId)
            .limit(1)
            .get();

        if (existingApproval.docs.isEmpty) {
          await contactDoc.reference.update({
            'approvedBy': parentId,
            'migratedAt': FieldValue.serverTimestamp(),
            'previouslyAutoApproved': contactData['autoApproved'] ?? false,
          });
          migratedCount++;
          print('  ✓ Contacto $contactId migrado al padre');
        }
      }
      */

      // NOTA: Código de notificación de contactos migrados deshabilitado
      // La colección 'whitelist' fue eliminada del sistema
      // Se mantiene el código comentado para referencia histórica
      /*
      int migratedCount = 0;
      if (migratedCount > 0) {
        // Notificar al padre sobre los contactos migrados
        await _firestore.collection('notifications').add({
          'userId': parentId,
          'title': 'Contactos Existentes',
          'body': 'Tu hijo ya tenía $migratedCount contacto${migratedCount > 1 ? 's' : ''} agregado${migratedCount > 1 ? 's' : ''}. Puedes revisarlos en Control Parental.',
          'type': 'contacts_migrated',
          'priority': 'normal',
          'read': false,
          'createdAt': FieldValue.serverTimestamp(),
          'data': {
            'childId': childId,
            'contactCount': migratedCount,
          },
        });
        ReleaseLogger.log('Notificación enviada al padre sobre contactos migrados', tag: 'LinkParentChild');
      }
      */

      // Actualizar rol del hijo (ahora es child porque tiene padre)
      final userDoc = await _firestore.collection('users').doc(childId).get();
      final userData = userDoc.data();

      // Calcular edad desde birthDate
      int age = 0;
      if (userData?['birthDate'] != null) {
        DateTime? birthDate;
        if (userData!['birthDate'] is Timestamp) {
          birthDate = (userData['birthDate'] as Timestamp).toDate();
        } else if (userData['birthDate'] is String) {
          birthDate = DateTime.tryParse(userData['birthDate']);
        }
        if (birthDate != null) {
          final today = DateTime.now();
          age = today.year - birthDate.year;
          if (today.month < birthDate.month ||
              (today.month == birthDate.month && today.day < birthDate.day)) {
            age--;
          }
        }
      } else if (userData?['age'] != null) {
        // Fallback a age si no hay birthDate (compatibilidad con datos antiguos)
        age = userData!['age'] ?? 0;
      }

      final newRole = await userRoleService.determineUserRole(childId, age);
      await _firestore.collection('users').doc(childId).update({
        'role': newRole,
        'linkedAt': FieldValue.serverTimestamp(),
      });
      ReleaseLogger.log('Rol del hijo actualizado a: $newRole', tag: 'LinkParentChild');

      // Actualizar rol del padre (de adult a parent si corresponde)
      final parentDoc = await _firestore.collection('users').doc(parentId).get();
      if (parentDoc.exists) {
        final parentData = parentDoc.data();
        final parentRole = parentData?['role'] ?? 'adult';

        // Si el padre es 'adult', cambiarlo a 'parent'
        if (parentRole == 'adult') {
          await _firestore.collection('users').doc(parentId).update({
            'role': 'parent',
            'updatedAt': FieldValue.serverTimestamp(),
          });
          ReleaseLogger.log('Rol del padre actualizado de adult a parent', tag: 'LinkParentChild');
        }
      }

      // NOTA: El código de vinculación se marca como usado por la Cloud Function createParentChildLink
      // No es necesario hacerlo aquí de forma redundante

      // Solicitar permisos de ubicación para niños que vinculan su primer padre
      // Solo si es el primer padre (no tiene otros padres vinculados) Y no tiene permisos ya concedidos
      if (existingParents.isEmpty && mounted) {
        // Verificar si los permisos ya fueron concedidos
        final locationAlwaysStatus = await Permission.locationAlways.status;

        if (!locationAlwaysStatus.isGranted) {
          ReleaseLogger.log('Solicitando permisos de ubicación para el niño (permisos no concedidos)', tag: 'LinkParentChild');

          // En iOS: solicitar directamente sin mostrar diálogo personalizado
          // En Android: mostrar diálogo explicativo primero
          if (Platform.isIOS) {
            // iOS: solicitar permisos directamente
            await Permission.location.request();
            await Permission.locationAlways.request();
          } else {
            // Android: mostrar diálogo explicativo
            await LocationPermissionDialog.show(context);
          }
        } else {
          ReleaseLogger.log('Permisos de ubicación ya concedidos, omitiendo solicitud', tag: 'LinkParentChild');
        }
      }

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      setState(() => _isVerifying = false);
    }
  }

  Future<void> _createParentApprovalRequest({
    required String childId,
    required String existingParentId,
    required String newParentId,
    required String linkCode,
  }) async {
    try {
      // Obtener información del niño y del nuevo padre
      final childDoc = await _firestore.collection('users').doc(childId).get();
      final newParentDoc = await _firestore.collection('users').doc(newParentId).get();

      final childName = childDoc.data()?['name'] ?? 'Usuario';
      final newParentName = newParentDoc.data()?['name'] ?? 'Usuario';

      // Crear solicitud de aprobación en Firestore
      await _firestore.collection('parent_approval_requests').add({
        'childId': childId,
        'childName': childName,
        'existingParentId': existingParentId,
        'newParentId': newParentId,
        'newParentName': newParentName,
        'linkCode': linkCode, // Usar código en lugar de docId
        'status': 'pending', // pending, approved, rejected
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Enviar notificación al padre existente
      await _firestore.collection('notifications').add({
        'userId': existingParentId,
        'title': 'Solicitud de Vinculación',
        'body': '$childName quiere vincular a $newParentName como padre/madre adicional',
        'type': 'parent_approval_request',
        'priority': 'high',
        'read': false,
        'createdAt': FieldValue.serverTimestamp(),
        'data': {
          'childId': childId,
          'childName': childName,
          'newParentId': newParentId,
          'newParentName': newParentName,
        },
      });

      ReleaseLogger.log('Solicitud de aprobación creada y notificación enviada', tag: 'LinkParentChild');
    } catch (e) {
      ReleaseLogger.error('Error creando solicitud de aprobación: $e', tag: 'LinkParentChild');
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text('Vincular con Padre/Madre'),
        backgroundColor: isDarkMode ? colorScheme.surface : colorScheme.primary,
        foregroundColor: isDarkMode ? colorScheme.onSurface : colorScheme.onPrimary,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDarkMode
                ? [
                    colorScheme.primary.withValues(alpha: 0.3),
                    colorScheme.surface,
                  ]
                : [Color(0xFF9D7FE8).withOpacity(0.1), Colors.white],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.family_restroom,
                    size: 80,
                    color: colorScheme.primary,
                  ),
                ),

                SizedBox(height: 32),

                Text(
                  'Ingresa el Código',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSurface,
                  ),
                ),

                SizedBox(height: 16),

                Text(
                  'Pídele a tu padre o madre el código de vinculación de 6 dígitos',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),

                SizedBox(height: 40),

                Container(
                  padding: EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: isDarkMode
                        ? colorScheme.surfaceContainerHighest
                        : colorScheme.surface,
                    borderRadius: BorderRadius.circular(20),
                    border: isDarkMode
                        ? Border.all(
                            color: colorScheme.outline.withValues(alpha: 0.3),
                            width: 1,
                          )
                        : null,
                    boxShadow: isDarkMode
                        ? null
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 20,
                              offset: Offset(0, 10),
                            ),
                          ],
                  ),
                  child: TextField(
                    controller: _codeController,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 12,
                      color: colorScheme.primary,
                    ),
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: InputDecoration(
                      hintText: '000000',
                      counterText: '',
                      border: InputBorder.none,
                      hintStyle: TextStyle(
                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                        letterSpacing: 12,
                      ),
                    ),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ),

                SizedBox(height: 32),

                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _isVerifying ? null : _verifyAndLink,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colorScheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: _isVerifying
                        ? CircularProgressIndicator(color: Colors.white)
                        : Text('Vincular', style: TextStyle(fontSize: 18)),
                  ),
                ),

                SizedBox(height: 24),

                Container(
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.security, color: Colors.green),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Tu padre/madre podrá proteger tu cuenta y aprobar tus contactos',
                          style: TextStyle(
                            fontSize: 14,
                            color: isDarkMode
                                ? Colors.green.shade200
                                : Colors.green.shade800,
                          ),
                        ),
                      ),
                    ],
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
