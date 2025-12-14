/**
 * Utilidades para normalización y hashing de números telefónicos.
 *
 * IMPORTANTE: Este archivo es la ÚNICA fuente de verdad para estas funciones.
 * Se usa tanto en Cloud Functions como en Flutter (con lógica idéntica).
 *
 * El salt debe ser idéntico al usado en Flutter:
 * lib/services/phone_normalization_service.dart
 */

const crypto = require("crypto");

// ═══════════════════════════════════════════════════════════════
// CONSTANTES
// ═══════════════════════════════════════════════════════════════

/**
 * Salt secreto para hashing de números telefónicos.
 * IMPORTANTE: Este valor debe ser idéntico al usado en Flutter.
 */
const PHONE_HASH_SALT = "51043c5af83c18c0e2ebce94e554af71b927c7974c84fe3df6323dde13952111";

// ═══════════════════════════════════════════════════════════════
// NORMALIZACIÓN
// ═══════════════════════════════════════════════════════════════

/**
 * Normaliza un número de teléfono al formato E.164 canónico.
 *
 * Para Argentina móvil, SIEMPRE incluye el "9" después del +54.
 * Esto evita que un usuario pueda crear dos cuentas con el mismo número
 * ingresándolo con y sin el "9".
 *
 * Ejemplos Argentina:
 * - "+54 387 5433442" -> "+5493875433442" (se agrega el 9)
 * - "+54 9 387 5433442" -> "+5493875433442" (ya tiene el 9)
 * - "387 5433442" -> "+5493875433442" (se agrega +549)
 *
 * @param {string} phone - El número a normalizar
 * @param {string} defaultCountryCode - Código ISO del país por defecto (ej: 'AR')
 * @returns {string} Número normalizado en formato E.164 canónico
 */
function normalizePhone(phone, defaultCountryCode = "AR") {
  if (!phone || phone.trim() === "") return "";

  // 1. Limpiar caracteres no numéricos (excepto +)
  let cleaned = phone.replace(/[^\d+]/g, "");

  // 2. Si no tiene código de país, agregarlo según el país por defecto
  if (!cleaned.startsWith("+")) {
    if (cleaned.startsWith("54")) {
      cleaned = "+" + cleaned;
    } else if (cleaned.startsWith("0")) {
      // Formato local argentino con 0
      cleaned = "+54" + cleaned.substring(1);
    } else if (defaultCountryCode.toUpperCase() === "AR") {
      // Asumir que es número argentino
      if (cleaned.startsWith("9") && cleaned.length === 11) {
        // Ya tiene el 9 de móvil
        cleaned = "+54" + cleaned;
      } else if (cleaned.length === 10) {
        // Es un móvil sin el 9
        cleaned = "+549" + cleaned;
      } else {
        cleaned = "+54" + cleaned;
      }
    }
  }

  // 3. Normalizar formato argentino - AGREGAR el 9 si no existe
  if (cleaned.startsWith("+54")) {
    const withoutCountryCode = cleaned.substring(3);

    // Si NO empieza con 9, agregarlo (asumiendo que es móvil)
    if (!withoutCountryCode.startsWith("9")) {
      // Solo si tiene 10 dígitos (longitud estándar de móviles argentinos sin el 9)
      if (withoutCountryCode.length === 10) {
        return "+549" + withoutCountryCode;
      }
    }

    return "+54" + withoutCountryCode;
  }

  // 4. Si empieza con 54 sin +, agregar el + y normalizar
  if (cleaned.startsWith("54") && !cleaned.startsWith("+")) {
    return normalizePhone("+" + cleaned, defaultCountryCode);
  }

  return cleaned;
}

// ═══════════════════════════════════════════════════════════════
// HASHING
// ═══════════════════════════════════════════════════════════════

/**
 * Genera un hash SHA-256 de un número telefónico normalizado.
 * @param {string} phone - Número en cualquier formato
 * @returns {string} Hash SHA-256
 */
function hashPhone(phone) {
  if (!phone || phone.trim() === "") return "";
  const normalized = normalizePhone(phone);
  if (!normalized) return "";
  return crypto.createHash("sha256").update(normalized + PHONE_HASH_SALT).digest("hex");
}

/**
 * Genera múltiples hashes para variaciones de un número.
 * Útil para matching bidireccional.
 */
function hashPhoneVariations(phone) {
  const variations = generatePhoneVariations(phone);
  return variations.map((v) => hashPhone(v)).filter((h) => h !== "");
}

// ═══════════════════════════════════════════════════════════════
// VARIACIONES
// ═══════════════════════════════════════════════════════════════

/**
 * Helper: Generar variaciones de un número de teléfono para matching
 * Maneja diferentes formatos: +54XXXXXXXXXX, +549XXXXXXXXXX, etc.
 *
 * Útil para buscar contactos que podrían estar guardados en
 * diferentes formatos en la base de datos o en contactos del dispositivo.
 */
function generatePhoneVariations(phone) {
  if (!phone) return [];

  const normalized = normalizePhone(phone);
  const variations = new Set();

  if (!normalized) return [];

  variations.add(normalized);

  // Si es argentino con 9 (formato canónico)
  if (normalized.startsWith("+549")) {
    const localNumber = normalized.substring(4); // Sin +549

    // Variación SIN el 9 (formato alternativo)
    variations.add("+54" + localNumber);

    // Variaciones sin +
    variations.add("549" + localNumber); // Con 9
    variations.add("54" + localNumber); // Sin 9

    // Variación solo número local
    variations.add("9" + localNumber); // Con 9
    variations.add(localNumber); // Solo local
    variations.add("0" + localNumber); // Formato local con 0
  }
  // Si es argentino sin 9 (lo normalizamos y generamos variaciones)
  else if (normalized.startsWith("+54")) {
    const localNumber = normalized.substring(3); // Sin +54

    // Variación CON el 9 (formato canónico)
    variations.add("+549" + localNumber);

    // Variaciones sin +
    variations.add("54" + localNumber);
    variations.add("549" + localNumber);

    // Variación solo número local
    variations.add(localNumber);
    variations.add("9" + localNumber);
    variations.add("0" + localNumber);
  }
  // Otros países
  else if (normalized.startsWith("+")) {
    variations.add(normalized.substring(1)); // Sin +
  }

  return Array.from(variations);
}

// ═══════════════════════════════════════════════════════════════
// EXPORTS
// ═══════════════════════════════════════════════════════════════

module.exports = {
  PHONE_HASH_SALT,
  normalizePhone,
  hashPhone,
  hashPhoneVariations,
  generatePhoneVariations,
};
