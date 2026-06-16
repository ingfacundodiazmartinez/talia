/// Identidad de la cuenta oficial de Talia (historias de sistema:
/// bienvenida y comunicados). NO existe como documento en `users`;
/// la UI hace special-casing por el flag `isOfficial` del Story.
///
/// Debe mantenerse sincronizado con la constante equivalente en
/// `functions/official.js` y con lo que escribe el backoffice.
class Official {
  Official._();

  /// userId constante del autor oficial.
  static const String userId = 'talia_official';

  /// Nombre mostrado.
  static const String userName = 'Talia';

  /// Asset usado como avatar oficial (ya cubierto por `assets/images/` en pubspec).
  static const String logoAsset = 'assets/images/logo.png';

  /// True si un userId corresponde a la cuenta oficial.
  static bool isOfficialUser(String? id) => id == userId;
}
