// ═══════════════════════════════════════════════════════════════
// CUENTA OFICIAL DE TALIA (historias de sistema)
// ═══════════════════════════════════════════════════════════════
//
// Identidad usada para historias de bienvenida y comunicados.
// NO existe como documento en `users`; el cliente hace special-casing
// por el flag `isOfficial` del Story.
//
// Debe mantenerse sincronizado con lib/utils/official.dart y con el
// backoffice que publica comunicados.

const OFFICIAL_USER_ID = "talia_official";
const OFFICIAL_USER_NAME = "Talia";

// Documento de config editable (desde el admin) para la historia de bienvenida.
const WELCOME_CONFIG_PATH = { collection: "app_config", doc: "welcome_story" };

module.exports = {
  OFFICIAL_USER_ID,
  OFFICIAL_USER_NAME,
  WELCOME_CONFIG_PATH,
};
