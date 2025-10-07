import 'package:cloud_firestore/cloud_firestore.dart';

/// Abstract base class for all user types in the system (Child, Parent, Adult)
abstract class User {
  final String id;
  final String name;
  final DateTime? birthDate;
  final String? photoURL;
  final bool? isOnline;
  final String? role;

  User({
    required this.id,
    required this.name,
    this.birthDate,
    this.photoURL,
    this.isOnline,
    this.role,
  });

  /// Calcula la edad del usuario desde su fecha de nacimiento
  int get age {
    if (birthDate == null) return 0;

    final today = DateTime.now();
    int calculatedAge = today.year - birthDate!.year;

    if (today.month < birthDate!.month ||
        (today.month == birthDate!.month && today.day < birthDate!.day)) {
      calculatedAge--;
    }

    return calculatedAge;
  }

  /// Obtiene las iniciales del nombre del usuario
  String get initials {
    if (name.isEmpty) return 'U';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
  }

  /// Obtiene un usuario específico por su ID desde Firestore
  /// Retorna un DocumentSnapshot para permitir flexibilidad en el tipo de usuario
  static Future<DocumentSnapshot?> getByIdSnapshot(String userId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();

      return doc.exists ? doc : null;
    } catch (e) {
      print('❌ Error obteniendo usuario: $e');
      return null;
    }
  }

  /// Obtiene datos de usuario por ID como Map
  static Future<Map<String, dynamic>?> getById(String userId) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .get();

      if (!doc.exists) return null;

      final data = doc.data() as Map<String, dynamic>;
      return {
        'id': doc.id,
        'name': data['name'],
        'email': data['email'],
        'phone': data['phone'],
        'photoURL': data['photoURL'],
        'birthDate': data['birthDate'],
        'role': data['role'],
        'parentId': data['parentId'],
      };
    } catch (e) {
      print('❌ Error obteniendo usuario por ID: $e');
      return null;
    }
  }

  /// Obtiene datos de usuario por teléfono
  static Future<Map<String, dynamic>?> getByPhone(String phone) async {
    try {
      final querySnapshot = await FirebaseFirestore.instance
          .collection('users')
          .where('phone', isEqualTo: phone)
          .limit(1)
          .get();

      if (querySnapshot.docs.isEmpty) return null;

      final doc = querySnapshot.docs.first;
      final data = doc.data();
      return {
        'id': doc.id,
        'name': data['name'],
        'email': data['email'],
        'phone': data['phone'],
        'photoURL': data['photoURL'],
        'birthDate': data['birthDate'],
        'role': data['role'],
        'parentId': data['parentId'],
      };
    } catch (e) {
      print('❌ Error obteniendo usuario por teléfono: $e');
      return null;
    }
  }

  /// Calcula edad desde birthDate (Timestamp o DateTime)
  static int? calculateAge(dynamic birthDate) {
    if (birthDate == null) return null;

    DateTime date;
    if (birthDate is Timestamp) {
      date = birthDate.toDate();
    } else if (birthDate is DateTime) {
      date = birthDate;
    } else {
      return null;
    }

    final now = DateTime.now();
    int calculatedAge = now.year - date.year;
    if (now.month < date.month ||
        (now.month == date.month && now.day < date.day)) {
      calculatedAge--;
    }
    return calculatedAge;
  }

  /// Parsea la fecha de nacimiento desde diferentes formatos
  static DateTime? parseBirthDate(dynamic birthDateData) {
    if (birthDateData == null) return null;

    if (birthDateData is Timestamp) {
      return birthDateData.toDate();
    } else if (birthDateData is String) {
      return DateTime.tryParse(birthDateData);
    } else if (birthDateData is int) {
      // Si es un número, asumimos que es la edad y calculamos fecha aproximada
      final today = DateTime.now();
      return DateTime(today.year - birthDateData, today.month, today.day);
    }

    return null;
  }

  /// Convierte el modelo a Map para guardarlo en Firestore
  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'birthDate': birthDate != null ? Timestamp.fromDate(birthDate!) : null,
      'photoURL': photoURL,
      'isOnline': isOnline,
      'role': role,
    };
  }

  @override
  String toString() {
    return 'User(id: $id, name: $name, role: $role, age: $age)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is User && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
