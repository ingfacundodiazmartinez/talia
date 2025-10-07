import 'package:cloud_firestore/cloud_firestore.dart';
import 'user.dart';

/// Modelo para usuarios con rol de Adulto (no padre ni hijo)
class Adult extends User {
  Adult({
    required super.id,
    required super.name,
    super.birthDate,
    super.photoURL,
    super.isOnline,
  }) : super(role: 'adult');

  /// Crea una instancia de Adult desde un documento de Firestore
  factory Adult.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      throw Exception('Document data is null');
    }

    return Adult(
      id: doc.id,
      name: data['name'] ?? 'Usuario',
      birthDate: User.parseBirthDate(data['birthDate'] ?? data['age']),
      photoURL: data['photoURL'],
      isOnline: data['isOnline'],
    );
  }

  /// Crea una instancia de Adult desde un Map
  factory Adult.fromMap(String id, Map<String, dynamic> data) {
    return Adult(
      id: id,
      name: data['name'] ?? 'Usuario',
      birthDate: User.parseBirthDate(data['birthDate'] ?? data['age']),
      photoURL: data['photoURL'],
      isOnline: data['isOnline'],
    );
  }

  /// Obtiene un adulto específico por su ID desde Firestore
  static Future<Adult?> getById(String adultId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(adultId)
          .get();

      if (!doc.exists) return null;

      return Adult.fromFirestore(doc);
    } catch (e) {
      print('❌ Error obteniendo adulto: $e');
      return null;
    }
  }

  /// Stream de los datos del adulto
  Stream<DocumentSnapshot> getUserDataStream() {
    return FirebaseFirestore.instance
        .collection('users')
        .doc(id)
        .snapshots();
  }

  /// Obtiene todos los contactos del adulto
  Future<List<DocumentSnapshot>> loadAllContacts() async {
    try {
      final query = await FirebaseFirestore.instance
          .collection('contacts')
          .where('users', arrayContains: id)
          .get();

      return query.docs;
    } catch (e) {
      print('❌ Error cargando contactos: $e');
      return [];
    }
  }

  @override
  String toString() {
    return 'Adult(id: $id, name: $name, age: $age)';
  }
}
