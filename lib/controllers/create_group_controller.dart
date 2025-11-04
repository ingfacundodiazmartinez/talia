import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:firebase_storage/firebase_storage.dart';
import '../services/group_chat_service.dart';
import '../services/chat_permission_service.dart';
import '../services/contact_alias_service.dart';
import '../utils/release_logger.dart';

/// Model para información de contacto
class ContactInfo {
  final String id;
  final String name;
  final String email;
  final String? avatar;

  ContactInfo({
    required this.id,
    required this.name,
    required this.email,
    this.avatar,
  });
}

/// Controller para manejar la lógica de creación de grupos
///
/// Responsabilidades:
/// - Cargar contactos disponibles con aprobación bidireccional
/// - Subir imágenes del grupo a Firebase Storage
/// - Crear grupos usando GroupChatService
/// - Manejo de errores y estados de loading
/// - Obtener datos del usuario actual
class CreateGroupController {
  static const int maxMembers = 50;

  // Servicios privados
  final GroupChatService _groupService;
  final ChatPermissionService _permissionService;
  final ContactAliasService _aliasService;
  final FirebaseFirestore _firestore;
  final firebase_auth.FirebaseAuth _auth;
  final FirebaseStorage _storage;

  // Estado del controller
  List<ContactInfo> _allContacts = [];
  bool _isLoading = false;
  bool _isCreating = false;
  bool _hasError = false;
  String? _errorMessage;

  // Callbacks para comunicación con el screen
  Function(List<ContactInfo>)? onContactsLoaded;
  Function(bool)? onLoadingChanged;
  Function(bool)? onCreatingChanged;
  Function(String)? onError;
  Function(String)? onSuccess;
  Function()? onGroupCreated;

  // Constructor
  CreateGroupController({
    GroupChatService? groupService,
    ChatPermissionService? permissionService,
    ContactAliasService? aliasService,
    FirebaseFirestore? firestore,
    firebase_auth.FirebaseAuth? auth,
    FirebaseStorage? storage,
  }) : _groupService = groupService ?? GroupChatService(),
       _permissionService = permissionService ?? ChatPermissionService(),
       _aliasService = aliasService ?? ContactAliasService(),
       _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? firebase_auth.FirebaseAuth.instance,
       _storage = storage ?? FirebaseStorage.instance;

  // Getters para el estado
  List<ContactInfo> get allContacts => _allContacts;
  bool get isLoading => _isLoading;
  bool get isCreating => _isCreating;
  bool get hasError => _hasError;
  String? get errorMessage => _errorMessage;
  String get currentUserId => _auth.currentUser?.uid ?? '';

  /// Cargar contactos disponibles con aprobación bidireccional
  Future<void> loadAvailableContacts() async {
    try {
      _setLoading(true);
      _clearError();

      final currentUserId = _auth.currentUser?.uid;
      if (currentUserId == null) {
        throw 'Usuario no autenticado';
      }

      ReleaseLogger.log('Cargando contactos con aprobación bidireccional', tag: 'CreateGroup');

      final bidirectionalContactIds = await _permissionService
          .getBidirectionallyApprovedContacts(currentUserId);

      final contacts = <ContactInfo>[];

      for (final contactId in bidirectionalContactIds) {
        try {
          final userDoc = await _firestore.collection('users').doc(contactId).get();
          final userData = userDoc.data();

          if (userData != null) {
            final realName = userData['name'] ?? 'Usuario';
            final displayName = await _aliasService.getDisplayName(contactId, realName);

            contacts.add(
              ContactInfo(
                id: contactId,
                name: displayName,
                email: userData['email'] ?? '',
                avatar: userData['photoURL'],
              ),
            );
          }
        } catch (e) {
          ReleaseLogger.error('Error cargando datos del contacto $contactId: $e', tag: 'CreateGroup');
          // Continuar con otros contactos si uno falla
        }
      }

      _allContacts = contacts;
      ReleaseLogger.log('Encontrados ${contacts.length} contactos', tag: 'CreateGroup');
      onContactsLoaded?.call(contacts);

    } catch (e) {
      ReleaseLogger.error('Error cargando contactos: $e', tag: 'CreateGroup');
      _setError('Error cargando contactos: $e');
    } finally {
      _setLoading(false);
    }
  }

  /// Subir imagen del grupo a Firebase Storage
  Future<String?> uploadGroupImage(File imageFile) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw 'Usuario no autenticado';
      }

      final fileName = 'group_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final storageRef = _storage
          .ref()
          .child('group_images')
          .child(fileName);

      final uploadTask = await storageRef.putFile(imageFile);
      final downloadUrl = await uploadTask.ref.getDownloadURL();

      ReleaseLogger.log('Imagen del grupo subida exitosamente', tag: 'CreateGroup');
      return downloadUrl;
    } catch (e) {
      ReleaseLogger.error('Error subiendo imagen del grupo: $e', tag: 'CreateGroup');
      throw 'Error subiendo imagen del grupo: $e';
    }
  }

  /// Crear nuevo grupo
  Future<bool> createGroup({
    required String groupName,
    required List<ContactInfo> selectedContacts,
    File? groupImageFile,
  }) async {
    try {
      _setCreating(true);
      _clearError();

      // Validaciones
      if (groupName.trim().isEmpty) {
        throw 'El nombre del grupo es obligatorio';
      }

      if (selectedContacts.isEmpty) {
        throw 'Debes seleccionar al menos un contacto';
      }

      if (selectedContacts.length > maxMembers) {
        throw 'No puedes agregar más de $maxMembers miembros';
      }

      // Subir imagen del grupo si existe
      String? imageUrl;
      if (groupImageFile != null) {
        imageUrl = await uploadGroupImage(groupImageFile);
      }

      final selectedUserIds = selectedContacts.map((c) => c.id).toList();

      // Crear el grupo usando el servicio
      final groupId = await _groupService.createGroup(
        name: groupName.trim(),
        memberIds: selectedUserIds,
        imageUrl: imageUrl,
      );

      ReleaseLogger.log('Grupo creado exitosamente: $groupId', tag: 'CreateGroup');
      onSuccess?.call('Grupo "$groupName" creado exitosamente');
      onGroupCreated?.call();

      return true;
    } catch (e) {
      ReleaseLogger.error('Error creando grupo: $e', tag: 'CreateGroup');
      _setError('Error al crear el grupo: $e');
      return false;
    } finally {
      _setCreating(false);
    }
  }

  /// Filtrar contactos por query de búsqueda
  List<ContactInfo> filterContacts(String query) {
    if (query.trim().isEmpty) {
      return List.from(_allContacts);
    }

    final lowerQuery = query.toLowerCase();
    return _allContacts.where((contact) {
      return contact.name.toLowerCase().contains(lowerQuery) ||
          contact.email.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// Verificar si se puede agregar más contactos
  bool canAddMoreContacts(int currentSelectedCount) {
    return currentSelectedCount < maxMembers;
  }

  /// Métodos de utilidad privados
  void _setLoading(bool loading) {
    _isLoading = loading;
    onLoadingChanged?.call(loading);
  }

  void _setCreating(bool creating) {
    _isCreating = creating;
    onCreatingChanged?.call(creating);
  }

  void _setError(String error) {
    _hasError = true;
    _errorMessage = error;
    onError?.call(error);
  }

  void _clearError() {
    _hasError = false;
    _errorMessage = null;
  }
}