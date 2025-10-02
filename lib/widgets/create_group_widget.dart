import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/group_chat_service.dart';
import '../services/chat_permission_service.dart';

class CreateGroupWidget extends StatefulWidget {
  final VoidCallback? onGroupCreated;

  const CreateGroupWidget({super.key, this.onGroupCreated});

  @override
  State<CreateGroupWidget> createState() => _CreateGroupWidgetState();
}

class _CreateGroupWidgetState extends State<CreateGroupWidget>
    with TickerProviderStateMixin {
  final GroupChatService _groupService = GroupChatService();
  final ChatPermissionService _permissionService = ChatPermissionService();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Controllers
  final TextEditingController _groupNameController = TextEditingController();
  final TextEditingController _groupDescriptionController =
      TextEditingController();
  final PageController _pageController = PageController();

  // Animation Controllers
  late AnimationController _stepController;
  late AnimationController _loadingController;
  late Animation<double> _stepAnimation;
  late Animation<double> _loadingAnimation;

  // Estado
  int _currentStep = 0; // 0: configuración, 1: miembros, 2: resultado
  bool _isLoading = false;
  String? _errorMessage;

  // Datos del grupo
  List<ContactInfo> _availableContacts = [];
  final List<ContactInfo> _selectedContacts = [];
  String? _groupAvatar;

  // Resultado de creación
  GroupCreationResult? _creationResult;

  @override
  void initState() {
    super.initState();
    _initializeAnimations();
    _loadAvailableContacts();
  }

  void _initializeAnimations() {
    _stepController = AnimationController(
      duration: Duration(milliseconds: 300),
      vsync: this,
    );

    _loadingController = AnimationController(
      duration: Duration(milliseconds: 1500),
      vsync: this,
    );

    _stepAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _stepController, curve: Curves.easeInOut),
    );

    _loadingAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _loadingController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _groupNameController.dispose();
    _groupDescriptionController.dispose();
    _pageController.dispose();
    _stepController.dispose();
    _loadingController.dispose();
    super.dispose();
  }

  Future<void> _loadAvailableContacts() async {
    try {
      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) return;

      print('🔍 Cargando contactos con aprobación bidireccional...');

      // Usar el nuevo servicio para obtener solo contactos con aprobación bidireccional
      final bidirectionalContactIds = await _permissionService
          .getBidirectionallyApprovedContacts(currentUserId);

      final contacts = <ContactInfo>[];

      for (final contactId in bidirectionalContactIds) {
        // Obtener información del contacto
        final userDoc = await _firestore
            .collection('users')
            .doc(contactId)
            .get();
        final userData = userDoc.data();

        if (userData != null) {
          contacts.add(
            ContactInfo(
              id: contactId,
              name: userData['name'] ?? 'Usuario',
              email: userData['email'] ?? '',
              avatar: userData['photoURL'],
              isOnline: userData['isOnline'] ?? false,
            ),
          );
        }
      }

      print(
        '✅ Encontrados ${contacts.length} contactos con aprobación bidireccional',
      );

      setState(() {
        _availableContacts = contacts;
      });
    } catch (e) {
      print('❌ Error cargando contactos: $e');
    }
  }

  void _nextStep() {
    if (_currentStep < 2) {
      setState(() {
        _currentStep++;
      });
      _pageController.animateToPage(
        _currentStep,
        duration: Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      _stepController.forward();
    }
  }

  void _previousStep() {
    if (_currentStep > 0) {
      setState(() {
        _currentStep--;
      });
      _pageController.animateToPage(
        _currentStep,
        duration: Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
      _stepController.reverse();
    }
  }

  Future<void> _createGroup() async {
    if (_groupNameController.text.trim().isEmpty) {
      _setError('El nombre del grupo es obligatorio');
      return;
    }

    if (_selectedContacts.isEmpty) {
      _setError('Debes seleccionar al menos un contacto');
      return;
    }

    _setLoading(true);
    _clearError();

    try {
      final selectedUserIds = _selectedContacts.map((c) => c.id).toList();

      final result = await _groupService.createGroup(
        name: _groupNameController.text.trim(),
        description: _groupDescriptionController.text.trim(),
        avatar: _groupAvatar,
        initialMembers: selectedUserIds,
      );

      setState(() {
        _creationResult = result;
      });

      if (result.isSuccess) {
        _nextStep(); // Ir a pantalla de éxito
      } else if (result.isPartialSuccess) {
        _nextStep(); // Ir a pantalla de éxito parcial
      } else {
        _setError(result.error ?? 'Error creando grupo');
      }
    } catch (e) {
      _setError('Error creando grupo: $e');
    } finally {
      _setLoading(false);
    }
  }

  void _setLoading(bool loading) {
    setState(() {
      _isLoading = loading;
    });

    if (loading) {
      _loadingController.repeat();
    } else {
      _loadingController.stop();
    }
  }

  void _setError(String error) {
    setState(() {
      _errorMessage = error;
    });
  }

  void _clearError() {
    setState(() {
      _errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          _buildHeader(),
          _buildProgressIndicator(),
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: NeverScrollableScrollPhysics(),
              children: [
                _buildGroupInfoStep(),
                _buildMembersStep(),
                _buildResultStep(),
              ],
            ),
          ),
          _buildActionButtons(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final titles = ['Crear Grupo', 'Agregar Miembros', 'Grupo Creado'];
    final subtitles = [
      'Configura tu grupo de chat',
      'Selecciona quién puede participar',
      'Tu grupo está listo',
    ];

    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF9D7FE8), Color(0xFFB39DDB)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Handle bar
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          SizedBox(height: 20),
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.group_add, color: Colors.white, size: 24),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titles[_currentStep],
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      subtitles[_currentStep],
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.white.withOpacity(0.9),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildProgressIndicator() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          _buildStepIndicator(0, 'Grupo'),
          Expanded(child: _buildStepLine(0)),
          _buildStepIndicator(1, 'Miembros'),
          Expanded(child: _buildStepLine(1)),
          _buildStepIndicator(2, 'Listo'),
        ],
      ),
    );
  }

  Widget _buildStepIndicator(int step, String label) {
    final isActive = _currentStep >= step;
    final isCompleted = _currentStep > step;

    return Column(
      children: [
        AnimatedContainer(
          duration: Duration(milliseconds: 300),
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

  Widget _buildStepLine(int step) {
    final isCompleted = _currentStep > step;

    return Container(
      height: 2,
      margin: EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: isCompleted ? Color(0xFF9D7FE8) : Colors.grey[300],
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }

  Widget _buildGroupInfoStep() {
    return Padding(
      padding: EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Información del Grupo',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2D3142),
            ),
          ),
          SizedBox(height: 20),

          // Avatar del grupo
          Center(
            child: GestureDetector(
              onTap: () {
                // TODO: Implementar selección de avatar
              },
              child: Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: Color(0xFF9D7FE8).withOpacity(0.1),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Color(0xFF9D7FE8).withOpacity(0.3),
                    width: 2,
                  ),
                ),
                child: _groupAvatar != null
                    ? ClipOval(
                        child: Image.network(_groupAvatar!, fit: BoxFit.cover),
                      )
                    : Icon(Icons.group, size: 32, color: Color(0xFF9D7FE8)),
              ),
            ),
          ),
          SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: () {
                // TODO: Implementar selección de foto
              },
              child: Text(
                'Agregar foto del grupo',
                style: TextStyle(color: Color(0xFF9D7FE8)),
              ),
            ),
          ),
          SizedBox(height: 20),

          // Nombre del grupo
          TextField(
            controller: _groupNameController,
            decoration: InputDecoration(
              labelText: 'Nombre del grupo *',
              hintText: 'Ej: Grupo de estudio',
              prefixIcon: Icon(Icons.group, color: Color(0xFF9D7FE8)),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Color(0xFF9D7FE8)),
              ),
            ),
            onChanged: (value) => _clearError(),
          ),
          SizedBox(height: 16),

          // Descripción del grupo
          TextField(
            controller: _groupDescriptionController,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: 'Descripción (opcional)',
              hintText: 'Describe de qué se trata el grupo...',
              prefixIcon: Icon(Icons.description, color: Color(0xFF9D7FE8)),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Color(0xFF9D7FE8)),
              ),
            ),
            onChanged: (value) => _clearError(),
          ),

          if (_errorMessage != null) ...[
            SizedBox(height: 16),
            _buildErrorMessage(),
          ],
        ],
      ),
    );
  }

  Widget _buildMembersStep() {
    return Padding(
      padding: EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Seleccionar Miembros',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2D3142),
            ),
          ),
          SizedBox(height: 8),
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
                    'Solo puedes agregar contactos con aprobación bidireccional (ambos padres aprobaron el contacto). Si faltan permisos, se enviarán solicitudes automáticamente.',
                    style: TextStyle(color: Colors.blue[700], fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 20),

          // Contador de seleccionados
          if (_selectedContacts.isNotEmpty)
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Color(0xFF9D7FE8).withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.people, color: Color(0xFF9D7FE8), size: 20),
                  SizedBox(width: 8),
                  Text(
                    '${_selectedContacts.length} ${_selectedContacts.length == 1 ? 'miembro seleccionado' : 'miembros seleccionados'}',
                    style: TextStyle(
                      color: Color(0xFF9D7FE8),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),

          SizedBox(height: 16),

          // Lista de contactos
          Expanded(
            child: _availableContacts.isEmpty
                ? _buildEmptyContactsState()
                : ListView.builder(
                    itemCount: _availableContacts.length,
                    itemBuilder: (context, index) {
                      final contact = _availableContacts[index];
                      final isSelected = _selectedContacts.contains(contact);

                      return _buildContactItem(contact, isSelected);
                    },
                  ),
          ),

          if (_errorMessage != null) ...[
            SizedBox(height: 16),
            _buildErrorMessage(),
          ],
        ],
      ),
    );
  }

  Widget _buildContactItem(ContactInfo contact, bool isSelected) {
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isSelected ? Color(0xFF9D7FE8).withOpacity(0.1) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected ? Color(0xFF9D7FE8) : Colors.grey[300]!,
          width: isSelected ? 2 : 1,
        ),
      ),
      child: ListTile(
        leading: Stack(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: Color(0xFF9D7FE8).withOpacity(0.2),
              backgroundImage:
                  contact.avatar != null && contact.avatar!.isNotEmpty
                  ? NetworkImage(contact.avatar!)
                  : null,
              child: contact.avatar == null || contact.avatar!.isEmpty
                  ? Text(
                      contact.name.isNotEmpty
                          ? contact.name[0].toUpperCase()
                          : 'U',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF9D7FE8),
                      ),
                    )
                  : null,
            ),
            if (contact.isOnline)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
          ],
        ),
        title: Text(
          contact.name,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(0xFF2D3142),
          ),
        ),
        subtitle: Text(
          contact.email,
          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
        ),
        trailing: AnimatedContainer(
          duration: Duration(milliseconds: 200),
          child: Icon(
            isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
            color: isSelected ? Color(0xFF9D7FE8) : Colors.grey[400],
            size: 24,
          ),
        ),
        onTap: () {
          setState(() {
            if (isSelected) {
              _selectedContacts.remove(contact);
            } else {
              _selectedContacts.add(contact);
            }
          });
          _clearError();
        },
      ),
    );
  }

  Widget _buildEmptyContactsState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.people_outline, size: 64, color: Colors.grey[300]),
          SizedBox(height: 16),
          Text(
            'No tienes contactos con aprobación bidireccional',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey[600],
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Para crear grupos necesitas contactos donde ambos padres se han aprobado mutuamente',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  Widget _buildResultStep() {
    if (_creationResult == null) return SizedBox();

    return Padding(
      padding: EdgeInsets.all(20),
      child: Column(
        children: [
          SizedBox(height: 40),

          // Icono de resultado
          Container(
            padding: EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _creationResult!.isSuccess
                  ? Colors.green.withOpacity(0.1)
                  : Colors.orange.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _creationResult!.isSuccess ? Icons.check_circle : Icons.schedule,
              size: 48,
              color: _creationResult!.isSuccess ? Colors.green : Colors.orange,
            ),
          ),

          SizedBox(height: 24),

          // Título
          Text(
            _creationResult!.isSuccess
                ? '¡Grupo Creado!'
                : 'Grupo Creado Parcialmente',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2D3142),
            ),
            textAlign: TextAlign.center,
          ),

          SizedBox(height: 16),

          // Descripción
          Text(
            _creationResult!.isSuccess
                ? 'Tu grupo "${_groupNameController.text}" está listo y todos los miembros pueden chatear.'
                : 'Tu grupo "${_groupNameController.text}" se creó, pero algunos miembros están pendientes de aprobación.',
            style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            textAlign: TextAlign.center,
          ),

          SizedBox(height: 32),

          // Detalles del resultado
          if (_creationResult!.isPartialSuccess) _buildPartialSuccessDetails(),

          Spacer(),

          // Botón de finalizar
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                widget.onGroupCreated?.call();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Color(0xFF9D7FE8),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                'Ir al Grupo',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPartialSuccessDetails() {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: Colors.orange, size: 20),
              SizedBox(width: 8),
              Text(
                'Miembros Pendientes',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.orange[800],
                ),
              ),
            ],
          ),
          SizedBox(height: 12),
          Text(
            '${_creationResult!.pendingCount} ${_creationResult!.pendingCount == 1 ? 'miembro está' : 'miembros están'} pendientes porque faltan permisos de chat.',
            style: TextStyle(color: Colors.orange[700]),
          ),
          SizedBox(height: 8),
          Text(
            'Se enviaron notificaciones automáticas a los padres. Los miembros se agregarán automáticamente cuando se aprueben todos los permisos.',
            style: TextStyle(color: Colors.orange[700], fontSize: 14),
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

  Widget _buildActionButtons() {
    if (_currentStep == 2) return SizedBox(); // No mostrar botones en resultado

    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: Offset(0, -5),
          ),
        ],
      ),
      child: Row(
        children: [
          if (_currentStep > 0)
            Expanded(
              child: OutlinedButton(
                onPressed: _isLoading ? null : _previousStep,
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Color(0xFF9D7FE8)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: EdgeInsets.symmetric(vertical: 16),
                ),
                child: Text(
                  'Anterior',
                  style: TextStyle(color: Color(0xFF9D7FE8)),
                ),
              ),
            ),

          if (_currentStep > 0) SizedBox(width: 16),

          Expanded(
            flex: _currentStep == 0 ? 1 : 2,
            child: ElevatedButton(
              onPressed: _isLoading
                  ? null
                  : (_currentStep == 1 ? _createGroup : _nextStep),
              style: ElevatedButton.styleFrom(
                backgroundColor: Color(0xFF9D7FE8),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: EdgeInsets.symmetric(vertical: 16),
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
                      _currentStep == 0 ? 'Siguiente' : 'Crear Grupo',
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
}

// Clase para información de contacto
class ContactInfo {
  final String id;
  final String name;
  final String email;
  final String? avatar;
  final bool isOnline;

  ContactInfo({
    required this.id,
    required this.name,
    required this.email,
    this.avatar,
    required this.isOnline,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContactInfo &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
