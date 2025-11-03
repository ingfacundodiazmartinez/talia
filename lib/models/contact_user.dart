import 'package:cloud_firestore/cloud_firestore.dart';
import 'user.dart';

/// Modelo para representar un usuario individual con sus datos completos
/// Usado cuando necesitamos trabajar con información detallada de un contacto
class ContactUser extends User {
  final String? phone;
  final String? email;
  final DateTime? createdAt;
  final DateTime? lastSeen;
  final String? alias; // Alias personalizado que el usuario actual le puso

  ContactUser({
    required String id,
    required String name,
    DateTime? birthDate,
    String? photoURL,
    bool? isOnline,
    String? role,
    this.phone,
    this.email,
    this.createdAt,
    this.lastSeen,
    this.alias,
  }) : super(
          id: id,
          name: name,
          birthDate: birthDate,
          photoURL: photoURL,
          isOnline: isOnline,
          role: role,
        );

  /// Factory para crear desde datos de Firestore
  factory ContactUser.fromFirestore(Map<String, dynamic> data, String id, {String? customAlias}) {
    return ContactUser(
      id: id,
      name: data['name'] ?? 'Usuario',
      birthDate: User.parseBirthDate(data['birthDate']),
      photoURL: data['photoURL'],
      isOnline: data['isOnline'] ?? false,
      role: data['role'],
      phone: data['phone'],
      email: data['email'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      lastSeen: (data['lastSeen'] as Timestamp?)?.toDate(),
      alias: customAlias,
    );
  }

  /// Getters de dominio específicos del contacto

  /// Verificar si el contacto es un niño
  bool get isChild => role == 'child';

  /// Obtener nombre para mostrar (alias si existe, sino nombre real)
  String getDisplayName({String? customAlias}) {
    final aliasToUse = customAlias ?? alias;
    return aliasToUse?.isNotEmpty == true ? aliasToUse! : name;
  }

  /// Fecha de registro (cuándo se unió)
  DateTime? get joinDate => createdAt;

  /// Verificar si está en línea (activo en los últimos 5 minutos)
  @override
  bool get isOnline {
    if (lastSeen == null) return false;
    final now = DateTime.now();
    final difference = now.difference(lastSeen!);
    return difference.inMinutes < 5;
  }

  /// Copia del objeto con nuevos valores
  ContactUser copyWith({
    String? id,
    String? name,
    DateTime? birthDate,
    String? photoURL,
    bool? isOnline,
    String? role,
    String? phone,
    String? email,
    DateTime? createdAt,
    DateTime? lastSeen,
    String? alias,
  }) {
    return ContactUser(
      id: id ?? this.id,
      name: name ?? this.name,
      birthDate: birthDate ?? this.birthDate,
      photoURL: photoURL ?? this.photoURL,
      isOnline: isOnline ?? this.isOnline,
      role: role ?? this.role,
      phone: phone ?? this.phone,
      email: email ?? this.email,
      createdAt: createdAt ?? this.createdAt,
      lastSeen: lastSeen ?? this.lastSeen,
      alias: alias ?? this.alias,
    );
  }

  @override
  String toString() {
    return 'ContactUser(id: $id, name: $name, role: $role, alias: $alias)';
  }
}