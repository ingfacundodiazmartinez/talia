// Barrel export para servicios de chat
//
// Este archivo exporta todos los servicios atómicos de chat
// para facilitar imports limpios en controllers y screens.
//
// Uso:
// ```dart
// import 'package:talia/services/chats/chat_services.dart';
// ```

// Cache de preferencias locales (Hive)
export 'chat_preferences_cache.dart';

// === SERVICIOS DE LISTA ===
export 'list_chats_service.dart';
export 'get_chat_service.dart';
export 'search_chats_service.dart';

// === ACCIONES DE CHAT ===
export 'create_chat_service.dart';
export 'archive_chat_service.dart';
export 'unarchive_chat_service.dart';
export 'mute_chat_service.dart';
export 'unmute_chat_service.dart';
export 'delete_chat_service.dart';
export 'clear_chat_service.dart';

// === OPERACIONES DE MENSAJES ===
export 'list_messages_service.dart';
export 'send_message_service.dart';
export 'mark_messages_read_service.dart';
export 'edit_message_service.dart';
export 'delete_message_service.dart';
export 'add_reaction_service.dart';
export 'remove_reaction_service.dart';

// === GRUPOS ===
export 'groups/group_services.dart';
