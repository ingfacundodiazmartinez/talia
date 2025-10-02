import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:math';
import 'services/user_role_service.dart';

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

  @override
  void initState() {
    super.initState();
    _checkExistingCode();
  }

  Future<void> _checkExistingCode() async {
    try {
      final parentId = _auth.currentUser?.uid;
      if (parentId == null) return;

      final doc = await _firestore
          .collection('link_codes')
          .where('parentId', isEqualTo: parentId)
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
        }
      }
    } catch (e) {
      print('Error checking existing code: $e');
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
          .where('parentId', isEqualTo: parentId)
          .where('isActive', isEqualTo: true)
          .get();

      for (var doc in oldCodes.docs) {
        await doc.reference.update({'isActive': false});
      }

      // Generar código de 6 dígitos
      final code = _generateRandomCode();
      final expiresAt = DateTime.now().add(Duration(hours: 24));

      // Guardar en Firestore
      await _firestore.collection('link_codes').add({
        'code': code,
        'parentId': parentId,
        'isActive': true,
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(expiresAt),
        'used': false,
      });

      setState(() {
        _linkCode = code;
        _expiryTime = expiresAt;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Código generado exitosamente'),
          backgroundColor: Colors.green,
        ),
      );
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

  String _getTimeRemaining() {
    if (_expiryTime == null) return '';

    final now = DateTime.now();
    final difference = _expiryTime!.difference(now);

    if (difference.isNegative) return 'Expirado';

    final hours = difference.inHours;
    final minutes = difference.inMinutes.remainder(60);

    return 'Expira en ${hours}h ${minutes}m';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Vincular Hijo'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF9D7FE8).withOpacity(0.1), Colors.white],
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
                    color: Color(0xFF9D7FE8).withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.link, size: 80, color: Color(0xFF9D7FE8)),
                ),

                SizedBox(height: 32),

                Text(
                  'Código de Vinculación',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2D3142),
                  ),
                ),

                SizedBox(height: 16),

                Text(
                  'Comparte este código con tu hijo para vincular su cuenta',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                ),

                SizedBox(height: 40),

                if (_linkCode != null) ...[
                  Container(
                    padding: EdgeInsets.all(24),
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
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            _linkCode!.split('').join(' '),
                            style: TextStyle(
                              fontSize: 48,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF9D7FE8),
                              letterSpacing: 8,
                            ),
                          ),
                        ),
                        SizedBox(height: 16),
                        Text(
                          _getTimeRemaining(),
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[600],
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
                        onPressed: _copyToClipboard,
                        icon: Icon(Icons.copy),
                        label: Text('Copiar'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Color(0xFF9D7FE8),
                          side: BorderSide(color: Color(0xFF9D7FE8)),
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
                          foregroundColor: Colors.orange,
                          side: BorderSide(color: Colors.orange),
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
                        backgroundColor: Color(0xFF9D7FE8),
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
                    color: Colors.blue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.blue),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'El código expira en 24 horas y solo puede usarse una vez',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.blue[800],
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⚠️ El código debe tener 6 dígitos'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _isVerifying = true);

    try {
      final childId = _auth.currentUser?.uid;
      if (childId == null) return;

      // Buscar el código
      final linkCodeQuery = await _firestore
          .collection('link_codes')
          .where('code', isEqualTo: code)
          .where('isActive', isEqualTo: true)
          .where('used', isEqualTo: false)
          .limit(1)
          .get();

      if (linkCodeQuery.docs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Código inválido o expirado'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      final linkCodeDoc = linkCodeQuery.docs.first;
      final linkCodeData = linkCodeDoc.data();
      final parentId = linkCodeData['parentId'];
      final expiresAt = (linkCodeData['expiresAt'] as Timestamp).toDate();

      // Verificar si expiró
      if (expiresAt.isBefore(DateTime.now())) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ El código ha expirado'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // Verificar si ya existe un vínculo con este padre en parent_child_links
      final existingLink = await _firestore
          .collection('parent_child_links')
          .where('parentId', isEqualTo: parentId)
          .where('childId', isEqualTo: childId)
          .where('status', isEqualTo: 'approved')
          .limit(1)
          .get();

      if (existingLink.docs.isNotEmpty) {
        print('⚠️ Ya existe un vínculo activo entre este padre e hijo');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚠️ Ya estás vinculado con este padre/madre'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
        Navigator.of(context).pop(false);
        return;
      }

      // Verificar si ya está vinculado con otro padre usando parent_child_links
      final userRoleService = UserRoleService();
      final existingParents = await userRoleService.getLinkedParents(childId);

      if (existingParents.isNotEmpty && !existingParents.contains(parentId)) {
        // Ya tiene un padre - requiere aprobación del primer padre
        print('⚠️ El niño ya tiene un padre. Creando solicitud de aprobación...');

        await _createParentApprovalRequest(
          childId: childId,
          existingParentId: existingParents.first,
          newParentId: parentId,
          linkCodeDocId: linkCodeDoc.id,
        );

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Solicitud enviada. El padre actual debe aprobar esta vinculación.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
          ),
        );

        Navigator.of(context).pop(true);
        return;
      }

      print('🔗 Vinculando hijo $childId con padre $parentId');

      // Crear relación padre-hijo en AMBAS colecciones para compatibilidad
      await _firestore.collection('parent_children').add({
        'parentId': parentId,
        'childId': childId,
        'status': 'approved',
        'linkedAt': FieldValue.serverTimestamp(),
      });
      print('✅ 1/2: Registro creado en parent_children');

      await _firestore.collection('parent_child_links').add({
        'parentId': parentId,
        'childId': childId,
        'status': 'approved',
        'linkedAt': FieldValue.serverTimestamp(),
      });
      print('✅ 2/2: Registro creado en parent_child_links');

      // Actualizar rol del hijo (ahora es child porque tiene padre)
      final userDoc = await _firestore.collection('users').doc(childId).get();
      final age = userDoc.data()?['age'] ?? 0;
      final newRole = await userRoleService.determineUserRole(childId, age);
      await _firestore.collection('users').doc(childId).update({
        'role': newRole,
        'linkedAt': FieldValue.serverTimestamp(),
      });
      print('✅ Rol del hijo actualizado a: $newRole');

      // Actualizar rol del padre (de adult a parent si corresponde)
      final parentDoc = await _firestore.collection('users').doc(parentId).get();
      if (parentDoc.exists) {
        final parentData = parentDoc.data() as Map<String, dynamic>?;
        final parentRole = parentData?['role'] ?? 'adult';

        // Si el padre es 'adult', cambiarlo a 'parent'
        if (parentRole == 'adult') {
          await _firestore.collection('users').doc(parentId).update({
            'role': 'parent',
            'updatedAt': FieldValue.serverTimestamp(),
          });
          print('✅ Rol del padre actualizado de adult a parent');
        }
      }

      // Marcar código como usado
      await linkCodeDoc.reference.update({
        'used': true,
        'usedBy': childId,
        'usedAt': FieldValue.serverTimestamp(),
        'isActive': false,
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ ¡Vinculado exitosamente con tu padre/madre!'),
          backgroundColor: Colors.green,
        ),
      );

      Navigator.of(context).pop(true);
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
    required String linkCodeDocId,
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
        'linkCodeDocId': linkCodeDocId,
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

      print('✅ Solicitud de aprobación creada y notificación enviada');
    } catch (e) {
      print('❌ Error creando solicitud de aprobación: $e');
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Vincular con Padre/Madre'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF9D7FE8).withOpacity(0.1), Colors.white],
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
                    color: Color(0xFF9D7FE8).withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.family_restroom,
                    size: 80,
                    color: Color(0xFF9D7FE8),
                  ),
                ),

                SizedBox(height: 32),

                Text(
                  'Ingresa el Código',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2D3142),
                  ),
                ),

                SizedBox(height: 16),

                Text(
                  'Pídele a tu padre o madre el código de vinculación de 6 dígitos',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                ),

                SizedBox(height: 40),

                Container(
                  padding: EdgeInsets.all(24),
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
                  child: TextField(
                    controller: _codeController,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 12,
                      color: Color(0xFF9D7FE8),
                    ),
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: InputDecoration(
                      hintText: '000000',
                      counterText: '',
                      border: InputBorder.none,
                      hintStyle: TextStyle(
                        color: Colors.grey[300],
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
                      backgroundColor: Color(0xFF9D7FE8),
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
                    color: Colors.green.withOpacity(0.1),
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
                            color: Colors.green[800],
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
