/// Groups V2 Module
///
/// New groups system with parent approval for children.
/// Use this module for all group-related operations.
///
/// Example:
/// ```dart
/// import 'package:talia/groups/groups.dart';
///
/// // Create a group
/// final controller = CreateGroupController();
/// await controller.createGroup(
///   name: 'Mi Grupo',
///   memberIds: ['user1', 'user2'],
/// );
/// ```
library;

// Models
export 'models/models.dart';

// Repositories
export 'repositories/repositories.dart';

// Services
export 'services/services.dart';

// Controllers
export 'controllers/controllers.dart';

// Screens
export 'screens/screens.dart';
