import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/user_code_service.dart';
import '../services/user_role_service.dart';
import '../notification_service.dart';

class AddContactScreen extends StatefulWidget {
  const AddContactScreen({super.key});

  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen>
    with TickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _codeController = TextEditingController();
  final UserCodeService _userCodeService = UserCodeService();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Agregar Contacto'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: [
            Tab(icon: Icon(Icons.qr_code_scanner), text: 'Escanear QR'),
            Tab(icon: Icon(Icons.keyboard), text: 'Código Manual'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildQRScannerTab(), _buildManualCodeTab()],
      ),
    );
  }

  Widget _buildQRScannerTab() {
    return Column(
      children: [
        Expanded(
          flex: 3,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.only(
                bottomLeft: Radius.circular(30),
                bottomRight: Radius.circular(30),
              ),
              child: MobileScannerWidget(onScanned: _handleQRScanned),
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: Container(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.qr_code_scanner, size: 64, color: Color(0xFF9D7FE8)),
                SizedBox(height: 16),
                Text(
                  'Escanea el código QR',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2D3142),
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Pide a tu amigo que abra su perfil y muestre su código QR',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                ),
                if (_errorMessage != null) ...[
                  SizedBox(height: 16),
                  _buildErrorMessage(),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildManualCodeTab() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 20),
          Center(
            child: Container(
              padding: EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Color(0xFF9D7FE8).withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.keyboard, size: 48, color: Color(0xFF9D7FE8)),
            ),
          ),
          SizedBox(height: 24),
          Text(
            'Introduce el código',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2D3142),
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Pide a tu amigo su código único y escríbelo aquí',
            style: TextStyle(fontSize: 14, color: Colors.grey[600]),
          ),
          SizedBox(height: 24),
          TextField(
            controller: _codeController,
            decoration: InputDecoration(
              labelText: 'Código de usuario',
              hintText: 'Ej: TALIA-ABC123',
              prefixIcon: Icon(Icons.tag, color: Color(0xFF9D7FE8)),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Color(0xFF9D7FE8), width: 2),
              ),
            ),
            textCapitalization: TextCapitalization.characters,
            onChanged: (value) {
              setState(() {
                _errorMessage = null;
              });
            },
          ),
          SizedBox(height: 16),
          Container(
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, color: Colors.blue, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'El código tiene el formato TALIA-ABC123 (3 letras y 3 números)',
                    style: TextStyle(color: Colors.blue[700], fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          if (_errorMessage != null) ...[
            SizedBox(height: 16),
            _buildErrorMessage(),
          ],
          SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: _isLoading ? null : _handleManualCode,
              style: ElevatedButton.styleFrom(
                backgroundColor: Color(0xFF9D7FE8),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
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
                      'Buscar Contacto',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ],
      ),
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

  void _handleQRScanned(String? code) {
    if (code != null && code.isNotEmpty) {
      _processContactCode(code);
    }
  }

  void _handleManualCode() {
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() {
        _errorMessage = 'Por favor introduce un código';
      });
      return;
    }

    if (!_userCodeService.isValidCodeFormat(code)) {
      setState(() {
        _errorMessage = 'Formato de código inválido. Debe ser TALIA-ABC123';
      });
      return;
    }

    _processContactCode(code);
  }

  Future<void> _processContactCode(String code) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await _userCodeService.findUserByCode(code);

      if (!result.isFound) {
        setState(() {
          _errorMessage = result.hasError
              ? result.error!
              : 'Código no encontrado. Verifica que esté correcto.';
        });
        return;
      }

      // Verificar que no sea el mismo usuario
      if (result.userId == _auth.currentUser?.uid) {
        setState(() {
          _errorMessage = 'No puedes agregarte a ti mismo como contacto';
        });
        return;
      }

      // Mostrar confirmación
      final confirmed = await _showConfirmationDialog(result);
      if (confirmed) {
        await _sendContactRequest(result);
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error procesando código: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<bool> _showConfirmationDialog(UserCodeResult result) async {
    // Get current user's role
    final currentUserDoc = await _firestore
        .collection('users')
        .doc(_auth.currentUser!.uid)
        .get();
    final currentUserRole = currentUserDoc.data()?['role'] ?? 'child';
    final isAdultOrParent = currentUserRole == 'adult' || currentUserRole == 'parent';

    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            title: Row(
              children: [
                Icon(Icons.person_add, color: Color(0xFF9D7FE8)),
                SizedBox(width: 8),
                Text('Confirmar Contacto'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (result.photoURL != null)
                  CircleAvatar(
                    radius: 40,
                    backgroundImage: NetworkImage(result.photoURL!),
                  )
                else
                  CircleAvatar(
                    radius: 40,
                    backgroundColor: Color(0xFF9D7FE8).withOpacity(0.2),
                    child: Text(
                      result.name![0].toUpperCase(),
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF9D7FE8),
                      ),
                    ),
                  ),
                SizedBox(height: 16),
                Text(
                  result.name!,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2D3142),
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  result.email!,
                  style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                ),
                SizedBox(height: 16),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    isAdultOrParent
                        ? 'Se enviará una solicitud al padre de ${result.name} para que apruebe el contacto.'
                        : '¿Quieres enviar una solicitud a tus padres para agregar a ${result.name} como contacto?',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.blue[700], fontSize: 14),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancelar'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Color(0xFF9D7FE8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text('Enviar Solicitud'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _sendContactRequest(UserCodeResult result) async {
    print('🚀 Iniciando _sendContactRequest para ${result.name}');
    try {
      // Get current user's role and data
      final currentUserDoc = await _firestore
          .collection('users')
          .doc(_auth.currentUser!.uid)
          .get();
      final currentUserRole = currentUserDoc.data()?['role'] ?? 'child';
      final isAdultOrParent = currentUserRole == 'adult' || currentUserRole == 'parent';
      final currentUserName =
          _auth.currentUser?.displayName ?? 'Usuario';

      // Get the contact's role and linked parents
      final userRoleService = UserRoleService();
      final contactDoc = await _firestore.collection('users').doc(result.userId!).get();
      final contactRole = contactDoc.data()?['role'] ?? 'adult';
      final contactLinkedParents = await userRoleService.getLinkedParents(result.userId!);

      print('🔍 Usuario actual role: $currentUserRole');
      print('🔍 Contacto role: $contactRole');
      print('🔍 isAdultOrParent: $isAdultOrParent');
      print('🔍 Padres vinculados del contacto: ${contactLinkedParents.length}');

      if (isAdultOrParent) {
        // ADULT/PARENT FLOW

        // If contact is also adult/parent, add directly without approval
        if (contactRole == 'adult' || contactRole == 'parent') {
          print('🔍 Contacto es adulto/padre, agregando directamente sin aprobación');

          // Create a single bidirectional contact document
          // Both users are stored in users array for easier querying
          final participants = [_auth.currentUser!.uid, result.userId]..sort();

          await _firestore.collection('contacts').add({
            'users': participants,  // Both users in sorted array
            'user1Id': participants[0],
            'user2Id': participants[1],
            'user1Name': participants[0] == _auth.currentUser!.uid ? currentUserName : result.name,
            'user2Name': participants[1] == _auth.currentUser!.uid ? currentUserName : result.name,
            'user1Email': participants[0] == _auth.currentUser!.uid ? _auth.currentUser!.email : result.email,
            'user2Email': participants[1] == _auth.currentUser!.uid ? _auth.currentUser!.email : result.email,
            'status': 'approved',
            'addedAt': FieldValue.serverTimestamp(),
            'addedVia': 'user_code',
            'addedBy': _auth.currentUser!.uid,
          });

          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ Contacto agregado exitosamente'),
              backgroundColor: Colors.green,
            ),
          );
          return;
        }

        // If contact is a child, need approval from child's parents
        if (contactLinkedParents.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '⚠️ Este niño no tiene padres vinculados que puedan aprobar el contacto',
              ),
              backgroundColor: Colors.orange,
            ),
          );
          return;
        }

        // Create contact request for each parent of the child
        for (final contactParentId in contactLinkedParents) {
          print('🔍 Creating contact_request:');
          print('   childId: ${result.userId}');
          print('   contactId: ${_auth.currentUser!.uid}');
          print('   parentId: $contactParentId');
          print('   requesterRole: $currentUserRole');

          await _firestore.collection('contact_requests').add({
            'childId': result.userId, // The child being added
            'contactId': _auth.currentUser!.uid, // The adult requesting
            'parentId': contactParentId, // The child's parent who will approve
            'contactName': currentUserName,
            'contactEmail': _auth.currentUser!.email,
            'childName': result.name,
            'status': 'pending',
            'requestedAt': FieldValue.serverTimestamp(),
            'addedVia': 'user_code',
            'requesterRole': currentUserRole, // Mark the role of requester
          });

          // Send notification to each parent
          await NotificationService().sendContactRequestNotification(
            parentId: contactParentId,
            childName: result.name!,
            contactName: currentUserName,
          );
        }

        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '✅ Solicitud enviada a ${contactLinkedParents.length} padre(s) de ${result.name}',
            ),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        // CHILD FLOW: Send approval request to ALL OWN parents
        final myLinkedParents = await userRoleService.getLinkedParents(_auth.currentUser!.uid);

        if (myLinkedParents.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '⚠️ No tienes padres vinculados que puedan aprobar contactos',
              ),
              backgroundColor: Colors.orange,
            ),
          );
          return;
        }

        // Create request for each of my parents
        for (final myParentId in myLinkedParents) {
          await _firestore.collection('contact_requests').add({
            'childId': _auth.currentUser!.uid, // The child requesting
            'contactId': result.userId, // The contact being added
            'parentId': myParentId, // Own parent who will approve
            'contactName': result.name,
            'contactEmail': result.email,
            'contactCode': _codeController.text.trim(),
            'status': 'pending',
            'requestedAt': FieldValue.serverTimestamp(),
            'addedVia': 'user_code',
            'requesterRole': 'child', // Mark that a child is requesting
          });

          // Send notification to each parent
          await NotificationService().sendContactRequestNotification(
            parentId: myParentId,
            childName: currentUserName,
            contactName: result.name!,
          );
        }

        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Solicitud enviada a ${myLinkedParents.length} padre(s)'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Error enviando solicitud: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}

// Widget para el escáner QR usando mobile_scanner
class MobileScannerWidget extends StatefulWidget {
  final Function(String?) onScanned;

  const MobileScannerWidget({super.key, required this.onScanned});

  @override
  State<MobileScannerWidget> createState() => _MobileScannerWidgetState();
}

class _MobileScannerWidgetState extends State<MobileScannerWidget> {
  MobileScannerController controller = MobileScannerController();
  bool _hasScanned = false;

  @override
  void initState() {
    super.initState();
    _requestCameraPermission();
  }

  Future<void> _requestCameraPermission() async {
    final status = await Permission.camera.request();
    if (status.isDenied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Se necesita permiso de cámara para escanear códigos QR',
          ),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        MobileScanner(controller: controller, onDetect: _onDetect),
        // Overlay personalizado
        Container(
          decoration: ShapeDecoration(
            shape: QrScannerOverlayShape(
              borderColor: Color(0xFF9D7FE8),
              borderRadius: 10,
              borderLength: 30,
              borderWidth: 10,
              cutOutSize: 250,
            ),
          ),
        ),
      ],
    );
  }

  void _onDetect(BarcodeCapture capture) {
    final List<Barcode> barcodes = capture.barcodes;

    if (!_hasScanned && barcodes.isNotEmpty) {
      final barcode = barcodes.first;
      if (barcode.rawValue != null) {
        _hasScanned = true;
        controller.stop();
        widget.onScanned(barcode.rawValue);

        // Resetear después de un momento para permitir escanear otro código
        Future.delayed(Duration(seconds: 2), () {
          if (mounted) {
            _hasScanned = false;
            controller.start();
          }
        });
      }
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

// Overlay personalizado para el scanner
class QrScannerOverlayShape extends ShapeBorder {
  final Color borderColor;
  final double borderWidth;
  final double borderLength;
  final double borderRadius;
  final double cutOutSize;

  const QrScannerOverlayShape({
    this.borderColor = Colors.white,
    this.borderWidth = 3.0,
    this.borderLength = 40,
    this.borderRadius = 0,
    this.cutOutSize = 250,
  });

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(10);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) {
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addPath(getOuterPath(rect), Offset.zero);
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) {
    Path getLeftTopPath(Rect rect) {
      return Path()
        ..moveTo(rect.left, rect.bottom)
        ..lineTo(rect.left, rect.top + borderRadius)
        ..quadraticBezierTo(
          rect.left,
          rect.top,
          rect.left + borderRadius,
          rect.top,
        )
        ..lineTo(rect.right, rect.top);
    }

    return getLeftTopPath(rect)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left, rect.top + borderRadius);
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final width = rect.width;
    final borderWidthSize = width / 2;
    final height = rect.height;
    final borderHeightSize = height / 2;
    final cutOutWidth = cutOutSize < width ? cutOutSize : width - borderWidth;
    final cutOutHeight = cutOutSize < height
        ? cutOutSize
        : height - borderWidth;

    final backgroundPaint = Paint()
      ..color = Colors.black.withOpacity(0.8)
      ..style = PaintingStyle.fill;

    final boxPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth;

    final cutOutRect = Rect.fromLTWH(
      rect.left + (width - cutOutWidth) / 2 + borderWidth,
      rect.top + (height - cutOutHeight) / 2 + borderWidth,
      cutOutWidth - borderWidth * 2,
      cutOutHeight - borderWidth * 2,
    );

    // Dibujar fondo semitransparente
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(rect),
        Path()
          ..addRRect(
            RRect.fromRectAndRadius(cutOutRect, Radius.circular(borderRadius)),
          )
          ..close(),
      ),
      backgroundPaint,
    );

    // Dibujar esquinas del marco
    final cornerLength = borderLength;
    final cornerPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = borderWidth;

    // Esquina superior izquierda
    canvas.drawPath(
      Path()
        ..moveTo(cutOutRect.left, cutOutRect.top + cornerLength)
        ..lineTo(cutOutRect.left, cutOutRect.top + borderRadius)
        ..quadraticBezierTo(
          cutOutRect.left,
          cutOutRect.top,
          cutOutRect.left + borderRadius,
          cutOutRect.top,
        )
        ..lineTo(cutOutRect.left + cornerLength, cutOutRect.top),
      cornerPaint,
    );

    // Esquina superior derecha
    canvas.drawPath(
      Path()
        ..moveTo(cutOutRect.right - cornerLength, cutOutRect.top)
        ..lineTo(cutOutRect.right - borderRadius, cutOutRect.top)
        ..quadraticBezierTo(
          cutOutRect.right,
          cutOutRect.top,
          cutOutRect.right,
          cutOutRect.top + borderRadius,
        )
        ..lineTo(cutOutRect.right, cutOutRect.top + cornerLength),
      cornerPaint,
    );

    // Esquina inferior izquierda
    canvas.drawPath(
      Path()
        ..moveTo(cutOutRect.left, cutOutRect.bottom - cornerLength)
        ..lineTo(cutOutRect.left, cutOutRect.bottom - borderRadius)
        ..quadraticBezierTo(
          cutOutRect.left,
          cutOutRect.bottom,
          cutOutRect.left + borderRadius,
          cutOutRect.bottom,
        )
        ..lineTo(cutOutRect.left + cornerLength, cutOutRect.bottom),
      cornerPaint,
    );

    // Esquina inferior derecha
    canvas.drawPath(
      Path()
        ..moveTo(cutOutRect.right - cornerLength, cutOutRect.bottom)
        ..lineTo(cutOutRect.right - borderRadius, cutOutRect.bottom)
        ..quadraticBezierTo(
          cutOutRect.right,
          cutOutRect.bottom,
          cutOutRect.right,
          cutOutRect.bottom - borderRadius,
        )
        ..lineTo(cutOutRect.right, cutOutRect.bottom - cornerLength),
      cornerPaint,
    );
  }

  @override
  ShapeBorder scale(double t) {
    return QrScannerOverlayShape(
      borderColor: borderColor,
      borderWidth: borderWidth,
      borderLength: borderLength,
      borderRadius: borderRadius,
      cutOutSize: cutOutSize,
    );
  }
}
