import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/stories/repositories/contact_repository.dart';
import '../../utils/release_logger.dart';

/// Modelo para representar un contacto seleccionable
class SelectableContact {
  final String id;
  final String name;
  final String? photoUrl;
  final String? phoneNumber;
  bool isSelected;

  SelectableContact({
    required this.id,
    required this.name,
    this.photoUrl,
    this.phoneNumber,
    this.isSelected = false,
  });
}

/// Controller para la selección de participantes de llamada grupal
///
/// Responsabilidades:
/// - Cargar contactos con cache
/// - Manejar selección múltiple
/// - Filtrar por búsqueda (local)
/// - Validar límites de participantes
class ParticipantSelectorController extends ChangeNotifier {
  final ContactRepository _contactRepository;
  final FirebaseAuth _auth;

  // Estado
  List<SelectableContact> _allContacts = [];
  List<SelectableContact> _filteredContacts = [];
  final Set<String> _selectedIds = {};
  String _searchQuery = '';
  bool _isLoading = true;
  String? _error;

  // Configuración
  static const int maxParticipants = 8; // Límite recomendado para video
  static const int minParticipants = 1; // Mínimo para iniciar llamada

  // Getters
  List<SelectableContact> get contacts => _filteredContacts;
  List<SelectableContact> get selectedContacts =>
      _allContacts.where((c) => _selectedIds.contains(c.id)).toList();
  Set<String> get selectedIds => Set.unmodifiable(_selectedIds);
  int get selectedCount => _selectedIds.length;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get canStartCall => _selectedIds.length >= minParticipants;
  bool get hasReachedLimit => _selectedIds.length >= maxParticipants;
  String get searchQuery => _searchQuery;

  ParticipantSelectorController({
    ContactRepository? contactRepository,
    FirebaseAuth? auth,
  }) : _contactRepository = contactRepository ?? ContactRepository(
         firestore: FirebaseFirestore.instance,
         auth: FirebaseAuth.instance,
       ),
       _auth = auth ?? FirebaseAuth.instance;

  /// Inicializar y cargar contactos
  Future<void> initialize() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      ReleaseLogger.log('Cargando contactos para selector...', tag: 'ParticipantSelector');

      // 1. Obtener IDs de contactos (usa cache si es válido)
      final contactIds = await _contactRepository.getContactIds();

      // Remover el usuario actual de la lista
      final currentUserId = _auth.currentUser?.uid;
      final otherContactIds = contactIds.where((id) => id != currentUserId).toList();

      if (otherContactIds.isEmpty) {
        _allContacts = [];
        _filteredContacts = [];
        _isLoading = false;
        notifyListeners();
        return;
      }

      // 2. Obtener detalles de usuarios en batch
      final usersInfo = await _contactRepository.getUsersInfo(otherContactIds);

      // 3. Crear lista de contactos seleccionables
      _allContacts = otherContactIds.map((id) {
        final userInfo = usersInfo[id];
        return SelectableContact(
          id: id,
          name: userInfo?['name'] as String? ?? 'Usuario',
          photoUrl: userInfo?['photoUrl'] as String?,
          phoneNumber: userInfo?['phoneNumber'] as String?,
        );
      }).toList();

      // Ordenar alfabéticamente
      _allContacts.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

      // Inicialmente mostrar todos
      _filteredContacts = List.from(_allContacts);

      ReleaseLogger.log('Contactos cargados: ${_allContacts.length}', tag: 'ParticipantSelector');

    } catch (e) {
      ReleaseLogger.error('Error cargando contactos: $e', tag: 'ParticipantSelector');
      _error = 'Error al cargar contactos';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Actualizar búsqueda (filtrado local)
  void updateSearch(String query) {
    _searchQuery = query.toLowerCase().trim();

    if (_searchQuery.isEmpty) {
      _filteredContacts = List.from(_allContacts);
    } else {
      _filteredContacts = _allContacts.where((contact) {
        final nameMatch = contact.name.toLowerCase().contains(_searchQuery);
        final phoneMatch = contact.phoneNumber?.contains(_searchQuery) ?? false;
        return nameMatch || phoneMatch;
      }).toList();
    }

    notifyListeners();
  }

  /// Toggle selección de contacto
  void toggleSelection(String contactId) {
    if (_selectedIds.contains(contactId)) {
      _selectedIds.remove(contactId);
      _updateContactSelection(contactId, false);
    } else {
      if (!hasReachedLimit) {
        _selectedIds.add(contactId);
        _updateContactSelection(contactId, true);
      }
    }
    notifyListeners();
  }

  /// Seleccionar contacto
  void selectContact(String contactId) {
    if (!_selectedIds.contains(contactId) && !hasReachedLimit) {
      _selectedIds.add(contactId);
      _updateContactSelection(contactId, true);
      notifyListeners();
    }
  }

  /// Deseleccionar contacto
  void deselectContact(String contactId) {
    if (_selectedIds.contains(contactId)) {
      _selectedIds.remove(contactId);
      _updateContactSelection(contactId, false);
      notifyListeners();
    }
  }

  /// Limpiar todas las selecciones
  void clearSelection() {
    for (final id in _selectedIds) {
      _updateContactSelection(id, false);
    }
    _selectedIds.clear();
    notifyListeners();
  }

  /// Preseleccionar contactos (útil para llamada desde grupo)
  void preselectContacts(List<String> contactIds) {
    clearSelection();
    for (final id in contactIds) {
      if (_selectedIds.length < maxParticipants) {
        _selectedIds.add(id);
        _updateContactSelection(id, true);
      }
    }
    notifyListeners();
  }

  /// Verificar si un contacto está seleccionado
  bool isSelected(String contactId) => _selectedIds.contains(contactId);

  // Helper para actualizar el estado de selección en la lista
  void _updateContactSelection(String contactId, bool selected) {
    final index = _allContacts.indexWhere((c) => c.id == contactId);
    if (index != -1) {
      _allContacts[index].isSelected = selected;
    }
  }

  /// Refrescar contactos (forzar recarga)
  Future<void> refresh() async {
    _contactRepository.invalidateContactsCache();
    await initialize();
  }

  @override
  void dispose() {
    _allContacts.clear();
    _filteredContacts.clear();
    _selectedIds.clear();
    super.dispose();
  }
}
