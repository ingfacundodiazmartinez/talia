/**
 * Script para verificar que los hashes de teléfono coincidan con Flutter.
 *
 * Uso: node scripts/verify-phone-hash.js
 *
 * Este script genera hashes para números de prueba y los muestra.
 * Comparar con la salida de los tests de Flutter para verificar consistencia.
 */

const { normalizePhone, hashPhone } = require("../phone-utils");

// ═══════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════

console.log("═══════════════════════════════════════════════════════════════");
console.log("VERIFICACIÓN DE HASHES DE TELÉFONO");
console.log("═══════════════════════════════════════════════════════════════\n");

const testCases = [
  "+5493875433442",
  "+54 9 387 543-3442",
  "5493875433442",
  "93875433442",
  "3875433442",
  "+5491155667788",
];

console.log("Números de prueba y sus hashes:\n");

for (const phone of testCases) {
  const normalized = normalizePhone(phone);
  const hash = hashPhone(phone);
  console.log(`Input:      ${phone}`);
  console.log(`Normalized: ${normalized}`);
  console.log(`Hash:       ${hash}`);
  console.log("");
}

// Verificar que formatos diferentes del mismo número produzcan el mismo hash
console.log("═══════════════════════════════════════════════════════════════");
console.log("VERIFICACIÓN DE CONSISTENCIA");
console.log("═══════════════════════════════════════════════════════════════\n");

const sameNumberFormats = [
  "+5493875433442",
  "+54 9 387 543-3442",
  "5493875433442",
  "3875433442",
];

const hashes = new Set(sameNumberFormats.map((f) => hashPhone(f)));

if (hashes.size === 1) {
  console.log("✅ PASS: Todos los formatos del mismo número producen el mismo hash");
  console.log(`   Hash: ${[...hashes][0]}`);
} else {
  console.log("❌ FAIL: Los formatos producen hashes diferentes!");
  for (const format of sameNumberFormats) {
    console.log(`   ${format} -> ${hashPhone(format)}`);
  }
}

console.log("\n═══════════════════════════════════════════════════════════════");
console.log("SIMULACIÓN DE MATCHING BIDIRECCIONAL");
console.log("═══════════════════════════════════════════════════════════════\n");

const userAPhone = "+5493875433442";
const userBPhone = "+5491155667788";

const userAPhoneHash = hashPhone(userAPhone);
const userBPhoneHash = hashPhone(userBPhone);

// User A tiene a User B en contactos
const userAContactHashes = [userBPhoneHash, hashPhone("+5491122334455")];

// User B tiene a User A en contactos
const userBContactHashes = [userAPhoneHash, hashPhone("+5491166778899")];

const aHasB = userAContactHashes.includes(userBPhoneHash);
const bHasA = userBContactHashes.includes(userAPhoneHash);

console.log(`User A (${userAPhone}):`);
console.log(`  phoneHash: ${userAPhoneHash}`);
console.log(`  tiene a User B: ${aHasB}`);
console.log("");
console.log(`User B (${userBPhone}):`);
console.log(`  phoneHash: ${userBPhoneHash}`);
console.log(`  tiene a User A: ${bHasA}`);
console.log("");
console.log(`Match bidireccional: ${aHasB && bHasA ? "✅ SÍ" : "❌ NO"}`);

console.log("\n═══════════════════════════════════════════════════════════════");
console.log("HASH PARA COMPARAR CON FLUTTER");
console.log("═══════════════════════════════════════════════════════════════\n");
console.log("Copia este hash y compáralo con la salida del test de Flutter:");
console.log(`Número: +5493875433442`);
console.log(`Hash:   ${hashPhone("+5493875433442")}`);
console.log("\nSi coinciden, la implementación es consistente entre plataformas.");
