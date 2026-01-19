/**
 * Script para restaurar un UID de Firebase Auth
 *
 * Esto es útil cuando:
 * - Un usuario Auth fue borrado pero su documento Firestore sigue existiendo
 * - El usuario verificó su teléfono de nuevo y Firebase le dio un UID nuevo
 * - Queremos restaurar el UID viejo para que coincida con el documento Firestore
 *
 * Uso: node restore-auth-uid.js
 */

const admin = require('firebase-admin');

// Inicializar Firebase Admin
if (!admin.apps.length) {
  admin.initializeApp();
}

const auth = admin.auth();
const db = admin.firestore();

// ═══════════════════════════════════════════════════════════════
// CONFIGURACIÓN - Datos de Mica
// ═══════════════════════════════════════════════════════════════

const PHONE_NUMBER = '+5493885087814';
const OLD_UID = '5CE2O3BPgkNcpUhw2XkdDlJAw9A3';  // UID del documento Firestore (huérfano)
const NEW_UID = '5lXl4v9O0USsVEJfPUwxefn71Zl2';  // UID de Firebase Auth actual (sin documento)

// ═══════════════════════════════════════════════════════════════

async function restoreAuthUid() {
  console.log('\n' + '='.repeat(60));
  console.log('RESTAURAR UID DE FIREBASE AUTH');
  console.log('='.repeat(60));
  console.log(`\nTeléfono: ${PHONE_NUMBER}`);
  console.log(`UID viejo (Firestore): ${OLD_UID}`);
  console.log(`UID nuevo (Auth actual): ${NEW_UID}`);
  console.log('');

  // 1. Verificar estado actual
  console.log('1. VERIFICANDO ESTADO ACTUAL...\n');

  // Verificar documento Firestore con UID viejo
  const oldDoc = await db.collection('users').doc(OLD_UID).get();
  if (!oldDoc.exists) {
    console.log(`   ❌ ERROR: No existe documento Firestore con UID viejo: ${OLD_UID}`);
    console.log('   Abortando...\n');
    return;
  }
  console.log(`   ✅ Documento Firestore existe con UID viejo`);
  console.log(`      Nombre: ${oldDoc.data().name}`);
  console.log(`      Teléfono: ${oldDoc.data().phone}`);

  // Verificar que NO existe Auth user con UID viejo
  try {
    await auth.getUser(OLD_UID);
    console.log(`   ❌ ERROR: Ya existe un Auth user con el UID viejo!`);
    console.log('   Abortando...\n');
    return;
  } catch (err) {
    if (err.code === 'auth/user-not-found') {
      console.log(`   ✅ No existe Auth user con UID viejo (esperado)`);
    } else {
      throw err;
    }
  }

  // Verificar que SÍ existe Auth user con UID nuevo
  try {
    const newAuthUser = await auth.getUser(NEW_UID);
    console.log(`   ✅ Auth user actual existe con UID nuevo`);
    console.log(`      Teléfono Auth: ${newAuthUser.phoneNumber}`);
  } catch (err) {
    if (err.code === 'auth/user-not-found') {
      console.log(`   ❌ ERROR: No existe Auth user con UID nuevo: ${NEW_UID}`);
      console.log('   Abortando...\n');
      return;
    }
    throw err;
  }

  // 2. Borrar el Auth user nuevo
  console.log('\n2. BORRANDO AUTH USER NUEVO...\n');

  try {
    await auth.deleteUser(NEW_UID);
    console.log(`   ✅ Auth user ${NEW_UID} eliminado`);
  } catch (err) {
    console.log(`   ❌ ERROR borrando Auth user: ${err.message}`);
    console.log('   Abortando...\n');
    return;
  }

  // 3. Crear Auth user con UID viejo
  console.log('\n3. CREANDO AUTH USER CON UID VIEJO...\n');

  try {
    const newUser = await auth.createUser({
      uid: OLD_UID,
      phoneNumber: PHONE_NUMBER,
    });
    console.log(`   ✅ Auth user creado exitosamente`);
    console.log(`      UID: ${newUser.uid}`);
    console.log(`      Teléfono: ${newUser.phoneNumber}`);
  } catch (err) {
    console.log(`   ❌ ERROR creando Auth user: ${err.message}`);
    console.log('\n   ⚠️  ATENCIÓN: El Auth user nuevo fue borrado pero no se pudo crear el viejo!');
    console.log('   El usuario no podrá iniciar sesión hasta que se resuelva manualmente.\n');
    return;
  }

  // 4. Verificar resultado final
  console.log('\n4. VERIFICANDO RESULTADO FINAL...\n');

  try {
    const restoredUser = await auth.getUser(OLD_UID);
    console.log(`   ✅ Auth user restaurado:`);
    console.log(`      UID: ${restoredUser.uid}`);
    console.log(`      Teléfono: ${restoredUser.phoneNumber}`);

    const firestoreDoc = await db.collection('users').doc(OLD_UID).get();
    if (firestoreDoc.exists) {
      console.log(`   ✅ Documento Firestore conectado:`);
      console.log(`      Nombre: ${firestoreDoc.data().name}`);
      console.log(`      Role: ${firestoreDoc.data().role}`);
    }
  } catch (err) {
    console.log(`   ⚠️ Error verificando: ${err.message}`);
  }

  console.log('\n' + '='.repeat(60));
  console.log('✅ RESTAURACIÓN COMPLETADA');
  console.log('='.repeat(60));
  console.log('\nMica ahora puede iniciar sesión con su teléfono y');
  console.log('debería entrar directamente a la app con sus datos.\n');
}

// Ejecutar
restoreAuthUid()
  .then(() => process.exit(0))
  .catch(err => {
    console.error('\n❌ Error fatal:', err);
    process.exit(1);
  });
