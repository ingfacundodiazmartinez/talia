/**
 * Script para verificar si los usuarios se tienen mutuamente en sus contactos
 */

const admin = require('firebase-admin');

// Inicializar Firebase Admin
admin.initializeApp({
  projectId: 'talia-chat-app-v2',
});

const db = admin.firestore();

/**
 * Normaliza un número telefónico (mismo algoritmo que PhoneNormalizationService)
 */
function normalizePhone(phone) {
  if (!phone) return '';
  let cleaned = phone.replace(/[^\d+]/g, '');
  if (cleaned.startsWith('+54')) {
    let withoutCountryCode = cleaned.substring(3);
    if (withoutCountryCode.startsWith('9')) {
      withoutCountryCode = withoutCountryCode.substring(1);
    }
    return '+54' + withoutCountryCode;
  }
  if (cleaned.startsWith('54') && !cleaned.startsWith('+')) {
    let withoutCountryCode = cleaned.substring(2);
    if (withoutCountryCode.startsWith('9')) {
      withoutCountryCode = withoutCountryCode.substring(1);
    }
    return '+54' + withoutCountryCode;
  }
  return cleaned;
}

/**
 * Genera variaciones de un número
 */
function generateVariations(phone) {
  const normalized = normalizePhone(phone);
  const variations = new Set([normalized]);

  if (normalized.startsWith('+54')) {
    const withoutCode = normalized.substring(3);
    variations.add('+549' + withoutCode);
    variations.add('54' + withoutCode);
    variations.add('549' + withoutCode);
    variations.add(withoutCode);
    variations.add('9' + withoutCode);
  }

  return Array.from(variations);
}

async function checkMatches() {
  try {
    console.log('\n🔍 ========== ANÁLISIS DE MATCHES ==========\n');

    const usersSnapshot = await db.collection('users').get();
    const users = [];

    // Recopilar datos de usuarios
    usersSnapshot.forEach((doc) => {
      const data = doc.data();
      users.push({
        id: doc.id,
        name: data.name,
        phone: data.phone,
        devicePhoneNumbers: data.devicePhoneNumbers || [],
      });
    });

    console.log(`📊 Analizando ${users.length} usuarios\n`);

    // Analizar cada par de usuarios
    for (let i = 0; i < users.length; i++) {
      for (let j = i + 1; j < users.length; j++) {
        const user1 = users[i];
        const user2 = users[j];

        console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
        console.log(`👤 ${user1.name} ↔️ ${user2.name}`);
        console.log('');

        // Verificar si user1 tiene a user2 en sus contactos
        const user2Variations = generateVariations(user2.phone);
        const user1HasUser2 = user2Variations.some(
          variation => user1.devicePhoneNumbers.includes(variation)
        );

        console.log(`📱 ¿${user1.name} tiene a ${user2.name}?`);
        console.log(`   Teléfono de ${user2.name}: ${user2.phone}`);
        console.log(`   Variaciones: ${user2Variations.join(', ')}`);
        console.log(`   Contactos de ${user1.name}: ${user1.devicePhoneNumbers.length} números`);

        if (user1HasUser2) {
          const matchedVariation = user2Variations.find(
            v => user1.devicePhoneNumbers.includes(v)
          );
          console.log(`   ✅ SÍ (match con: "${matchedVariation}")`);
        } else {
          console.log(`   ❌ NO`);
          // Buscar números similares
          const similar = user1.devicePhoneNumbers.filter(
            num => num.includes('3875433') || num.includes('3885087')
          );
          if (similar.length > 0) {
            console.log(`   ⚠️ Números similares encontrados: ${similar.slice(0, 3).join(', ')}`);
          }
        }

        console.log('');

        // Verificar si user2 tiene a user1 en sus contactos
        const user1Variations = generateVariations(user1.phone);
        const user2HasUser1 = user1Variations.some(
          variation => user2.devicePhoneNumbers.includes(variation)
        );

        console.log(`📱 ¿${user2.name} tiene a ${user1.name}?`);
        console.log(`   Teléfono de ${user1.name}: ${user1.phone}`);
        console.log(`   Variaciones: ${user1Variations.join(', ')}`);
        console.log(`   Contactos de ${user2.name}: ${user2.devicePhoneNumbers.length} números`);

        if (user2HasUser1) {
          const matchedVariation = user1Variations.find(
            v => user2.devicePhoneNumbers.includes(v)
          );
          console.log(`   ✅ SÍ (match con: "${matchedVariation}")`);
        } else {
          console.log(`   ❌ NO`);
          const similar = user2.devicePhoneNumbers.filter(
            num => num.includes('3875433') || num.includes('3885087')
          );
          if (similar.length > 0) {
            console.log(`   ⚠️ Números similares encontrados: ${similar.slice(0, 3).join(', ')}`);
          }
        }

        console.log('');

        // Resumen del par
        if (user1HasUser2 && user2HasUser1) {
          console.log('   ✅✅ MATCH BIDIRECCIONAL - Deberían verse mutuamente');
        } else if (user1HasUser2 || user2HasUser1) {
          console.log('   ⚠️ MATCH UNIDIRECCIONAL - Solo uno tiene al otro');
        } else {
          console.log('   ❌❌ SIN MATCH - No se verán en contactos');
        }

        console.log('');
      }
    }

    console.log('✅ Análisis completado\n');

  } catch (error) {
    console.error('❌ Error:', error);
  } finally {
    process.exit(0);
  }
}

checkMatches();
