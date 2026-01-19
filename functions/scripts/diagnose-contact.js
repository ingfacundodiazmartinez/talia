/**
 * Script de diagnóstico para investigar por qué un contacto no aparece entre los contactos de un usuario.
 *
 * Uso:
 *   cd functions
 *   node scripts/diagnose-contact.js <userId1> <userId2>
 *
 * Ejemplo:
 *   node scripts/diagnose-contact.js 2kMTCgEn86OMOw791ZZH7lvEUro1 rra6nJfQ4cWBiL2ZrriLKfMpZzk1
 */

const admin = require('firebase-admin');

// Inicializar Firebase Admin (usa las credenciales por defecto del proyecto)
if (!admin.apps.length) {
  admin.initializeApp();
}

const db = admin.firestore();

// Colores para la consola
const colors = {
  reset: '\x1b[0m',
  red: '\x1b[31m',
  green: '\x1b[32m',
  yellow: '\x1b[33m',
  blue: '\x1b[34m',
  magenta: '\x1b[35m',
  cyan: '\x1b[36m',
  bold: '\x1b[1m',
};

function log(message, color = 'reset') {
  console.log(`${colors[color]}${message}${colors.reset}`);
}

function logSection(title) {
  console.log('\n' + '═'.repeat(60));
  log(`  ${title}`, 'bold');
  console.log('═'.repeat(60));
}

function logField(label, value, color = 'reset') {
  console.log(`  ${label}: ${colors[color]}${value}${colors.reset}`);
}

async function getUserInfo(userId) {
  const userDoc = await db.collection('users').doc(userId).get();
  if (!userDoc.exists) {
    return null;
  }
  const data = userDoc.data();
  return {
    id: userId,
    name: data.name || data.displayName || '(sin nombre)',
    role: data.role || 'child',
    phone: data.phone || '(sin teléfono)',
    parentId: data.parentId || null,
    linkedChildren: data.linkedChildren || [],
    blocked: data.blocked || false,
    blockedUsers: data.blockedUsers || [],
    // Campos para sync de contactos
    phoneHash: data.phoneHash || null,
    devicePhoneHashes: data.devicePhoneHashes || [],
    lastContactsSync: data.lastContactsSync || null,
  };
}

async function getContactInfo(userId1, userId2) {
  // Generar ID del contacto (ordenados alfabéticamente)
  const sorted = [userId1, userId2].sort();
  const contactId = `${sorted[0]}_${sorted[1]}`;

  const contactDoc = await db.collection('contacts').doc(contactId).get();
  if (!contactDoc.exists) {
    return { exists: false, id: contactId };
  }

  const data = contactDoc.data();
  return {
    exists: true,
    id: contactId,
    ...data,
  };
}

async function getChatInfo(userId1, userId2) {
  // Los chats pueden tener diferentes formatos de ID
  const sorted = [userId1, userId2].sort();
  const chatId = `${sorted[0]}_${sorted[1]}`;

  const chatDoc = await db.collection('chats').doc(chatId).get();
  if (!chatDoc.exists) {
    return null;
  }

  return {
    id: chatId,
    ...chatDoc.data(),
  };
}

async function getParentChildLink(parentId, childId) {
  const linkDoc = await db.collection('parent_child_links').doc(`${parentId}_${childId}`).get();
  if (!linkDoc.exists) {
    return null;
  }
  return linkDoc.data();
}

async function diagnoseContact(userId1, userId2) {
  log('\n🔍 DIAGNÓSTICO DE CONTACTO', 'cyan');
  log(`   Usuario 1: ${userId1}`, 'cyan');
  log(`   Usuario 2: ${userId2}`, 'cyan');

  // ═══════════════════════════════════════════════════════════════
  // 1. INFORMACIÓN DE USUARIOS
  // ═══════════════════════════════════════════════════════════════
  logSection('1. INFORMACIÓN DE USUARIOS');

  const user1 = await getUserInfo(userId1);
  const user2 = await getUserInfo(userId2);

  if (!user1) {
    log(`❌ Usuario 1 (${userId1}) NO EXISTE en Firestore`, 'red');
    return;
  }

  if (!user2) {
    log(`❌ Usuario 2 (${userId2}) NO EXISTE en Firestore`, 'red');
    return;
  }

  console.log('\n  📱 Usuario 1:');
  logField('    ID', user1.id);
  logField('    Nombre', user1.name);
  logField('    Rol', user1.role, user1.role === 'parent' ? 'magenta' : 'blue');
  logField('    Teléfono', user1.phone);
  if (user1.role === 'child' && user1.parentId) {
    logField('    Padre asignado', user1.parentId, 'yellow');
  }
  if (user1.role === 'parent' && user1.linkedChildren.length > 0) {
    logField('    Hijos vinculados', user1.linkedChildren.join(', '), 'yellow');
  }

  console.log('\n  📱 Usuario 2:');
  logField('    ID', user2.id);
  logField('    Nombre', user2.name);
  logField('    Rol', user2.role, user2.role === 'parent' ? 'magenta' : 'blue');
  logField('    Teléfono', user2.phone);
  if (user2.role === 'child' && user2.parentId) {
    logField('    Padre asignado', user2.parentId, 'yellow');
  }
  if (user2.role === 'parent' && user2.linkedChildren.length > 0) {
    logField('    Hijos vinculados', user2.linkedChildren.join(', '), 'yellow');
  }

  // ═══════════════════════════════════════════════════════════════
  // 2. DOCUMENTO DE CONTACTO
  // ═══════════════════════════════════════════════════════════════
  logSection('2. DOCUMENTO DE CONTACTO');

  const contact = await getContactInfo(userId1, userId2);

  if (!contact.exists) {
    log(`❌ NO EXISTE documento de contacto`, 'red');
    logField('  ID esperado', contact.id);
    log('\n  💡 CAUSA PROBABLE: Nunca se creó una solicitud de contacto entre estos usuarios', 'yellow');
  } else {
    log(`✅ Documento de contacto EXISTE`, 'green');
    logField('  ID', contact.id);

    // Status
    const statusColors = {
      'approved': 'green',
      'pending': 'yellow',
      'rejected': 'red',
      'revoked': 'red',
      'potential': 'blue',
    };
    logField('  Status', contact.status, statusColors[contact.status] || 'reset');

    // Type
    if (contact.type) {
      logField('  Tipo', contact.type, contact.type === 'parent_child_link' ? 'magenta' : 'reset');
      if (contact.type === 'parent_child_link') {
        log('  ⚠️ Este es un link padre-hijo interno, NO aparece en la whitelist', 'yellow');
      }
    }

    // Blocked
    if (contact.blocked) {
      log(`\n  🚫 CONTACTO BLOQUEADO`, 'red');
      logField('    Bloqueado por', contact.blockedBy, 'red');
      if (contact.blockedAt) {
        logField('    Fecha de bloqueo', new Date(contact.blockedAt._seconds * 1000).toISOString(), 'red');
      }
    }

    // Users array
    logField('  Users', JSON.stringify(contact.users));

    // Verificar si el array users está correcto
    if (!contact.users || !contact.users.includes(userId1) || !contact.users.includes(userId2)) {
      log('  ⚠️ PROBLEMA: El array "users" no contiene ambos IDs correctamente', 'red');
    }

    // Auto approved
    logField('  Auto-aprobado', contact.autoApproved ? 'Sí' : 'No');

    // Parent viewers
    if (contact.parentViewers && contact.parentViewers.length > 0) {
      logField('  Padres que pueden ver', contact.parentViewers.join(', '));
    }

    // Created info
    logField('  Creado por', contact.createdBy);
    if (contact.createdAt) {
      logField('  Creado el', new Date(contact.createdAt._seconds * 1000).toISOString());
    }
    if (contact.createdVia) {
      logField('  Creado vía', contact.createdVia);
    }

    // Approvals
    if (contact.approvals && Object.keys(contact.approvals).length > 0) {
      console.log('\n  📋 Aprobaciones:');
      for (const [childId, approval] of Object.entries(contact.approvals)) {
        const approvalStatusColor = approval.status === 'approved' ? 'green' :
                                    approval.status === 'pending' ? 'yellow' : 'red';
        console.log(`    • Hijo ${childId}:`);
        logField('      Status', approval.status, approvalStatusColor);
        if (approval.parentId) {
          logField('      Padre asignado', approval.parentId);
        }
        if (approval.approvedBy) {
          logField('      Aprobado por', approval.approvedBy);
        }
        if (approval.rejectedBy) {
          logField('      Rechazado por', approval.rejectedBy, 'red');
        }
      }
    } else {
      log('  📋 Sin aprobaciones requeridas (usuarios son padres o no tienen padre asignado)', 'cyan');
    }

    // Revocation info
    if (contact.status === 'revoked') {
      console.log('\n  🚫 Información de revocación:');
      logField('    Revocado por', contact.revokedBy, 'red');
      if (contact.revokedAt) {
        logField('    Fecha', new Date(contact.revokedAt._seconds * 1000).toISOString(), 'red');
      }
      if (contact.revokedReason) {
        logField('    Razón', contact.revokedReason, 'red');
      }
    }

    // Discovered by (para potential contacts)
    if (contact.discoveredBy) {
      logField('  Descubierto por', contact.discoveredBy);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 3. CHAT ENTRE USUARIOS
  // ═══════════════════════════════════════════════════════════════
  logSection('3. CHAT ENTRE USUARIOS');

  const chat = await getChatInfo(userId1, userId2);

  if (!chat) {
    log('  ℹ️ No existe chat entre estos usuarios', 'cyan');
  } else {
    log('  ✅ Existe chat entre estos usuarios', 'green');
    logField('    ID', chat.id);
    logField('    Tipo', chat.type || 'direct');
    if (chat.blocked) {
      log('    🚫 CHAT BLOQUEADO', 'red');
      logField('      Bloqueado por', chat.blockedBy, 'red');
    }
    if (chat.lastMessage) {
      logField('    Último mensaje', chat.lastMessage);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 4. BLOQUEOS A NIVEL DE USUARIO
  // ═══════════════════════════════════════════════════════════════
  logSection('4. BLOQUEOS A NIVEL DE USUARIO');

  const user1BlockedUser2 = user1.blockedUsers && user1.blockedUsers.includes(userId2);
  const user2BlockedUser1 = user2.blockedUsers && user2.blockedUsers.includes(userId1);

  if (user1BlockedUser2) {
    log(`  🚫 ${user1.name} tiene bloqueado a ${user2.name}`, 'red');
  }
  if (user2BlockedUser1) {
    log(`  🚫 ${user2.name} tiene bloqueado a ${user1.name}`, 'red');
  }
  if (!user1BlockedUser2 && !user2BlockedUser1) {
    log('  ✅ No hay bloqueos entre usuarios', 'green');
  }

  // ═══════════════════════════════════════════════════════════════
  // 5. SINCRONIZACIÓN DE CONTACTOS DEL DISPOSITIVO
  // ═══════════════════════════════════════════════════════════════
  logSection('5. SINCRONIZACIÓN DE CONTACTOS DEL DISPOSITIVO');

  // Verificar si ambos usuarios tienen phoneHash
  console.log('\n  📱 Estado de phoneHash (requerido para ser encontrado):');
  if (user1.phoneHash) {
    log(`    ✅ ${user1.name} tiene phoneHash: ${user1.phoneHash.substring(0, 20)}...`, 'green');
  } else {
    log(`    ❌ ${user1.name} NO tiene phoneHash (no puede ser encontrado por otros)`, 'red');
  }

  if (user2.phoneHash) {
    log(`    ✅ ${user2.name} tiene phoneHash: ${user2.phoneHash.substring(0, 20)}...`, 'green');
  } else {
    log(`    ❌ ${user2.name} NO tiene phoneHash (no puede ser encontrado por otros)`, 'red');
  }

  // Verificar última sincronización
  console.log('\n  🔄 Última sincronización de contactos:');
  if (user1.lastContactsSync) {
    const date1 = new Date(user1.lastContactsSync._seconds * 1000);
    logField(`    ${user1.name}`, date1.toISOString());
  } else {
    log(`    ⚠️ ${user1.name} NUNCA ha sincronizado contactos`, 'yellow');
  }

  if (user2.lastContactsSync) {
    const date2 = new Date(user2.lastContactsSync._seconds * 1000);
    logField(`    ${user2.name}`, date2.toISOString());
  } else {
    log(`    ⚠️ ${user2.name} NUNCA ha sincronizado contactos`, 'yellow');
  }

  // Verificar si se tienen mutuamente en devicePhoneHashes
  console.log('\n  🔍 Verificación de matching bidireccional:');
  const user1HasUser2 = user2.phoneHash && user1.devicePhoneHashes.includes(user2.phoneHash);
  const user2HasUser1 = user1.phoneHash && user2.devicePhoneHashes.includes(user1.phoneHash);

  if (user1HasUser2) {
    log(`    ✅ ${user1.name} tiene a ${user2.name} en su agenda (hash coincide)`, 'green');
  } else {
    log(`    ❌ ${user1.name} NO tiene a ${user2.name} en su agenda sincronizada`, 'red');
    if (!user2.phoneHash) {
      log(`       → Causa: ${user2.name} no tiene phoneHash guardado`, 'yellow');
    } else if (user1.devicePhoneHashes.length === 0) {
      log(`       → Causa: ${user1.name} no ha sincronizado ningún contacto`, 'yellow');
    } else {
      log(`       → Causa: El número de ${user2.name} no está en la agenda de ${user1.name}`, 'yellow');
    }
  }

  if (user2HasUser1) {
    log(`    ✅ ${user2.name} tiene a ${user1.name} en su agenda (hash coincide)`, 'green');
  } else {
    log(`    ❌ ${user2.name} NO tiene a ${user1.name} en su agenda sincronizada`, 'red');
    if (!user1.phoneHash) {
      log(`       → Causa: ${user1.name} no tiene phoneHash guardado`, 'yellow');
    } else if (user2.devicePhoneHashes.length === 0) {
      log(`       → Causa: ${user2.name} no ha sincronizado ningún contacto`, 'yellow');
    } else {
      log(`       → Causa: El número de ${user1.name} no está en la agenda de ${user2.name}`, 'yellow');
    }
  }

  logField('\n  📊 Cantidad de hashes en devicePhoneHashes', '');
  logField(`    ${user1.name}`, `${user1.devicePhoneHashes.length} contactos`);
  logField(`    ${user2.name}`, `${user2.devicePhoneHashes.length} contactos`);

  // ═══════════════════════════════════════════════════════════════
  // 6. VÍNCULOS PADRE-HIJO
  // ═══════════════════════════════════════════════════════════════
  logSection('6. VÍNCULOS PADRE-HIJO');

  // Si alguno es hijo, verificar vínculo con su padre
  if (user1.role === 'child' && user1.parentId) {
    const link = await getParentChildLink(user1.parentId, userId1);
    if (link) {
      log(`  ✅ ${user1.name} tiene vínculo activo con su padre`, 'green');
      logField('    Status del vínculo', link.status);
    } else {
      log(`  ⚠️ ${user1.name} tiene parentId pero no hay documento en parent_child_links`, 'yellow');
    }
  } else if (user1.role === 'child') {
    log(`  ⚠️ ${user1.name} es hijo pero NO tiene padre asignado`, 'yellow');
    log('    Los contactos no requieren aprobación parental', 'cyan');
  }

  if (user2.role === 'child' && user2.parentId) {
    const link = await getParentChildLink(user2.parentId, userId2);
    if (link) {
      log(`  ✅ ${user2.name} tiene vínculo activo con su padre`, 'green');
      logField('    Status del vínculo', link.status);
    } else {
      log(`  ⚠️ ${user2.name} tiene parentId pero no hay documento en parent_child_links`, 'yellow');
    }
  } else if (user2.role === 'child') {
    log(`  ⚠️ ${user2.name} es hijo pero NO tiene padre asignado`, 'yellow');
    log('    Los contactos no requieren aprobación parental', 'cyan');
  }

  // ═══════════════════════════════════════════════════════════════
  // 7. DIAGNÓSTICO FINAL
  // ═══════════════════════════════════════════════════════════════
  logSection('7. DIAGNÓSTICO FINAL');

  const issues = [];

  if (!contact.exists) {
    issues.push('❌ No existe documento de contacto - necesita crearse una solicitud');
  } else {
    if (contact.status === 'pending') {
      issues.push('⏳ El contacto está pendiente de aprobación');

      // Verificar quién necesita aprobar
      if (contact.approvals) {
        for (const [childId, approval] of Object.entries(contact.approvals)) {
          if (approval.status === 'pending') {
            issues.push(`   → Falta aprobación del padre de ${childId}`);
          }
        }
      }
    }

    if (contact.status === 'rejected') {
      issues.push('❌ El contacto fue RECHAZADO');
    }

    if (contact.status === 'revoked') {
      issues.push('❌ El contacto fue REVOCADO');
    }

    if (contact.status === 'potential') {
      issues.push('ℹ️ Es un contacto POTENCIAL (sugerido), no una solicitud real');
    }

    if (contact.blocked) {
      issues.push(`🚫 El contacto está BLOQUEADO por ${contact.blockedBy}`);
    }

    if (contact.type === 'parent_child_link') {
      issues.push('ℹ️ Es un link padre-hijo interno, no aparece en whitelist');
    }

    // Verificar array users
    if (!contact.users || contact.users.length !== 2) {
      issues.push('⚠️ El array "users" está corrupto');
    }
  }

  if (user1BlockedUser2 || user2BlockedUser1) {
    issues.push('🚫 Hay bloqueos a nivel de usuario');
  }

  // Problemas de sincronización de contactos
  if (!user1.phoneHash) {
    issues.push(`📱 ${user1.name} no tiene phoneHash - no puede ser encontrado por sync`);
  }
  if (!user2.phoneHash) {
    issues.push(`📱 ${user2.name} no tiene phoneHash - no puede ser encontrado por sync`);
  }
  if (!user1.lastContactsSync) {
    issues.push(`🔄 ${user1.name} nunca ha sincronizado sus contactos del dispositivo`);
  }
  if (!user2.lastContactsSync) {
    issues.push(`🔄 ${user2.name} nunca ha sincronizado sus contactos del dispositivo`);
  }
  if (user1.phoneHash && user2.devicePhoneHashes.length > 0 && !user2HasUser1) {
    issues.push(`📇 ${user2.name} sincronizó contactos pero NO tiene el número de ${user1.name} en su agenda`);
  }
  if (user2.phoneHash && user1.devicePhoneHashes.length > 0 && !user1HasUser2) {
    issues.push(`📇 ${user1.name} sincronizó contactos pero NO tiene el número de ${user2.name} en su agenda`);
  }

  if (issues.length === 0 && contact.exists && contact.status === 'approved') {
    log('  ✅ No se encontraron problemas evidentes', 'green');
    log('  💡 El contacto debería aparecer correctamente', 'green');
    log('\n  Posibles causas adicionales a investigar:', 'cyan');
    log('    - Cache local de la app desactualizado', 'cyan');
    log('    - Problema con el query de Firestore en la app', 'cyan');
    log('    - Problema con las reglas de seguridad de Firestore', 'cyan');
  } else {
    console.log('\n  🔴 Problemas encontrados:');
    for (const issue of issues) {
      log(`    ${issue}`, 'yellow');
    }
  }

  console.log('\n' + '═'.repeat(60) + '\n');
}

// Obtener argumentos de la línea de comandos
const args = process.argv.slice(2);

if (args.length < 2) {
  console.log('Uso: node scripts/diagnose-contact.js <userId1> <userId2>');
  console.log('Ejemplo: node scripts/diagnose-contact.js 2kMTCgEn86OMOw791ZZH7lvEUro1 rra6nJfQ4cWBiL2ZrriLKfMpZzk1');
  process.exit(1);
}

const [userId1, userId2] = args;

diagnoseContact(userId1, userId2)
  .then(() => {
    process.exit(0);
  })
  .catch((error) => {
    console.error('Error ejecutando diagnóstico:', error);
    process.exit(1);
  });
