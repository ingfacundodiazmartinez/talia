/**
 * Script para generar datos de demostración para screenshots
 *
 * Crea:
 * - Familias completas (padres e hijos)
 * - Conversaciones realistas
 * - Grupos familiares
 * - Historias/Stories
 * - Ubicaciones
 * - Reportes semanales
 *
 * Uso:
 *   node scripts/seed_demo_data.js
 */

const admin = require('firebase-admin');
const fs = require('fs');
const path = require('path');

// Inicializar Firebase Admin
const serviceAccount = require('../talia-chat-app-v2-firebase-adminsdk.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
  databaseURL: 'https://talia-chat-app-v2.firebaseio.com'
});

const db = admin.firestore();
const auth = admin.auth();

// Configuración de familias demo
// Números de teléfono argentinos válidos: +54 9 11 XXXX XXXX (11 dígitos después del +54)
// Avatares: Adultos usan pravatar (fotos reales PNG), niños usan DiceBear PNG (avatares ilustrados)
const DEMO_FAMILIES = [
  {
    parent: {
      name: 'María González',
      email: 'maria.demo@talia.app',
      phone: '+5491155510011',
      photoURL: 'https://i.pravatar.cc/300?img=47' // Mujer adulta
    },
    children: [
      {
        name: 'Sofía González',
        email: 'sofia.demo@talia.app',
        phone: '+5491155510022',
        age: 12,
        photoURL: 'https://api.dicebear.com/7.x/avataaars/png?seed=Sofia&backgroundColor=b6e3f4&size=200' // Avatar niña
      },
      {
        name: 'Lucas González',
        email: 'lucas.demo@talia.app',
        phone: '+5491155510033',
        age: 9,
        photoURL: 'https://api.dicebear.com/7.x/avataaars/png?seed=Lucas&backgroundColor=c0aede&size=200' // Avatar niño
      }
    ]
  },
  {
    parent: {
      name: 'Roberto Martínez',
      email: 'roberto.demo@talia.app',
      phone: '+5491155510044',
      photoURL: 'https://i.pravatar.cc/300?img=12' // Hombre adulto
    },
    children: [
      {
        name: 'Emma Martínez',
        email: 'emma.demo@talia.app',
        phone: '+5491155510055',
        age: 14,
        photoURL: 'https://api.dicebear.com/7.x/avataaars/png?seed=Emma&backgroundColor=ffdfbf&size=200' // Avatar adolescente
      }
    ]
  },
  {
    parent: {
      name: 'Laura Fernández',
      email: 'laura.demo@talia.app',
      phone: '+5491155510066',
      photoURL: 'https://i.pravatar.cc/300?img=48' // Mujer adulta
    },
    children: [
      {
        name: 'Mateo Fernández',
        email: 'mateo.demo@talia.app',
        phone: '+5491155510077',
        age: 10,
        photoURL: 'https://api.dicebear.com/7.x/avataaars/png?seed=Mateo&backgroundColor=ffd5dc&size=200' // Avatar niño
      },
      {
        name: 'Valentina Fernández',
        email: 'valentina.demo@talia.app',
        phone: '+5491155510088',
        age: 13,
        photoURL: 'https://api.dicebear.com/7.x/avataaars/png?seed=Valentina&backgroundColor=d1f4e0&size=200' // Avatar niña
      }
    ]
  }
];

// Contactos adicionales (amigos de los niños)
const FRIEND_CONTACTS = [
  {
    name: 'Camila Rodríguez',
    email: 'camila.demo@talia.app',
    phone: '+5491155510099',
    age: 12,
    photoURL: 'https://api.dicebear.com/7.x/avataaars/png?seed=Camila&backgroundColor=ffeaa7&size=200' // Avatar niña
  },
  {
    name: 'Benjamín López',
    email: 'benjamin.demo@talia.app',
    phone: '+5491155511100',
    age: 13,
    photoURL: 'https://api.dicebear.com/7.x/avataaars/png?seed=Benjamin&backgroundColor=dfe6e9&size=200' // Avatar niño
  },
  {
    name: 'Martina Silva',
    email: 'martina.demo@talia.app',
    phone: '+5491155511111',
    age: 11,
    photoURL: 'https://api.dicebear.com/7.x/avataaars/png?seed=Martina&backgroundColor=fab1a0&size=200' // Avatar niña
  }
];

// Conversaciones de ejemplo
const SAMPLE_CONVERSATIONS = {
  parent_child: [
    { sender: 'parent', text: '¿Ya terminaste la tarea?', delay: 120000 },
    { sender: 'child', text: 'Casi, me falta matemáticas', delay: 30000 },
    { sender: 'parent', text: '¿Necesitas ayuda con algo?', delay: 45000 },
    { sender: 'child', text: 'No, ya casi termino 😊', delay: 60000 },
    { sender: 'parent', text: 'Muy bien! Avísame cuando termines', delay: 20000 },
    { sender: 'child', text: 'Dale!', delay: 5000 }
  ],
  child_friend: [
    { sender: 'friend', text: 'Hola! Qué haces?', delay: 180000 },
    { sender: 'child', text: 'Haciendo tarea 😴', delay: 40000 },
    { sender: 'friend', text: 'Yo también jaja', delay: 25000 },
    { sender: 'child', text: 'Vamos a jugar después?', delay: 50000 },
    { sender: 'friend', text: 'Dale! A las 5?', delay: 30000 },
    { sender: 'child', text: 'Perfecto! 🎮', delay: 15000 },
    { sender: 'friend', text: 'Genial! Nos vemos', delay: 10000 }
  ],
  family_group: [
    { sender: 'parent', text: 'Recuerden que el sábado vamos a la casa de los abuelos', delay: 300000 },
    { sender: 'child1', text: 'Siiii! 😍', delay: 60000 },
    { sender: 'child2', text: 'A qué hora?', delay: 45000 },
    { sender: 'parent', text: 'A las 12 del mediodía', delay: 30000 },
    { sender: 'child1', text: 'Voy a llevar mi juego nuevo!', delay: 90000 },
    { sender: 'parent', text: 'Perfecto! No se olviden de hacer la tarea antes', delay: 120000 }
  ]
};

// Historias de ejemplo
const SAMPLE_STORIES = [
  {
    type: 'text',
    content: '¡Qué lindo día! ☀️',
    backgroundColor: '#FF6B6B'
  },
  {
    type: 'text',
    content: 'Terminé la tarea! 📚✅',
    backgroundColor: '#4ECDC4'
  }
];

/**
 * Utilidades
 */
function getChatId(userId1, userId2) {
  return [userId1, userId2].sort().join('_');
}

function getRandomDelay(baseDelay = 60000) {
  return baseDelay + Math.random() * 30000;
}

/**
 * Crear usuario en Auth y Firestore
 */
async function createUser(userData, role) {
  try {
    console.log(`Creando usuario: ${userData.name} (${role})...`);

    // Crear en Firebase Auth (sin contraseña, solo teléfono para OTP)
    const userRecord = await auth.createUser({
      email: userData.email,
      phoneNumber: userData.phone,
      displayName: userData.name,
      photoURL: userData.photoURL,
      emailVerified: true // Para demos
    });

    // Crear en Firestore
    await db.collection('users').doc(userRecord.uid).set({
      name: userData.name,
      email: userData.email,
      phoneNumber: userData.phone,
      photoURL: userData.photoURL,
      role: role,
      age: userData.age || null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      isDemo: true // Marca para identificar datos de demo
    });

    console.log(`✓ Usuario creado: ${userData.name} (${userRecord.uid})`);
    return userRecord.uid;
  } catch (error) {
    if (error.code === 'auth/email-already-exists' || error.code === 'auth/phone-number-already-exists') {
      console.log(`Usuario ya existe: ${userData.email}, obteniendo UID...`);
      const user = await auth.getUserByEmail(userData.email);
      return user.uid;
    }
    throw error;
  }
}

/**
 * Vincular padre e hijo
 */
async function linkParentChild(parentId, childId) {
  console.log(`Vinculando padre-hijo: ${parentId} <-> ${childId}...`);

  const linkId = `${parentId}_${childId}`;

  await db.collection('parent_children').doc(linkId).set({
    parentId: parentId,
    childId: childId,
    status: 'approved',
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    approvedAt: admin.firestore.FieldValue.serverTimestamp()
  });

  console.log(`✓ Vínculo creado: ${linkId}`);
}

/**
 * Crear contacto entre dos usuarios
 */
async function createContact(userId1, userId2) {
  console.log(`Creando contacto: ${userId1} <-> ${userId2}...`);

  const contactId = getChatId(userId1, userId2);

  await db.collection('contacts').doc(contactId).set({
    users: [userId1, userId2],
    status: 'approved',
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    approvedAt: admin.firestore.FieldValue.serverTimestamp()
  });

  console.log(`✓ Contacto creado: ${contactId}`);
}

/**
 * Crear chat con mensajes
 */
async function createChat(user1Id, user2Id, conversation, senderMap) {
  console.log(`Creando chat: ${user1Id} <-> ${user2Id}...`);

  const chatId = getChatId(user1Id, user2Id);
  const now = Date.now();

  // Crear documento de chat
  let lastMessage = null;
  let lastMessageTime = null;

  // Crear mensajes
  let cumulativeDelay = 0;
  for (const msg of conversation) {
    cumulativeDelay += msg.delay;
    const messageTime = new Date(now - (conversation.length * 180000) + cumulativeDelay);

    const senderId = senderMap[msg.sender];
    const receiverId = senderId === user1Id ? user2Id : user1Id;

    const messageData = {
      senderId: senderId,
      receiverId: receiverId,
      text: msg.text,
      timestamp: admin.firestore.Timestamp.fromDate(messageTime),
      read: true,
      type: 'text'
    };

    await db.collection('chats').doc(chatId).collection('messages').add(messageData);

    lastMessage = msg.text;
    lastMessageTime = messageTime;
  }

  // Crear/actualizar documento de chat
  await db.collection('chats').doc(chatId).set({
    participants: [user1Id, user2Id],
    lastMessage: lastMessage,
    lastMessageTime: admin.firestore.Timestamp.fromDate(lastMessageTime),
    createdAt: admin.firestore.Timestamp.fromDate(new Date(now - (conversation.length * 180000))),
    updatedAt: admin.firestore.Timestamp.fromDate(lastMessageTime),
    [`unreadCount_${user1Id}`]: 0,
    [`unreadCount_${user2Id}`]: 0
  });

  console.log(`✓ Chat creado con ${conversation.length} mensajes`);
}

/**
 * Crear grupo familiar
 */
async function createFamilyGroup(parentId, childrenIds, familyName) {
  console.log(`Creando grupo familiar: ${familyName}...`);

  const members = [parentId, ...childrenIds];
  const groupRef = await db.collection('groups').add({
    name: `Familia ${familyName}`,
    members: members,
    admins: [parentId],
    createdBy: parentId,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    photoURL: 'https://i.pravatar.cc/300?img=1',
    isDemo: true
  });

  const groupId = groupRef.id;

  // Crear mensajes del grupo
  const now = Date.now();
  let delay = 0;

  for (const msg of SAMPLE_CONVERSATIONS.family_group) {
    delay += msg.delay;
    const messageTime = new Date(now - (SAMPLE_CONVERSATIONS.family_group.length * 180000) + delay);

    let senderId;
    if (msg.sender === 'parent') {
      senderId = parentId;
    } else if (msg.sender === 'child1') {
      senderId = childrenIds[0];
    } else if (msg.sender === 'child2') {
      senderId = childrenIds[1] || childrenIds[0];
    }

    await db.collection('groups').doc(groupId).collection('messages').add({
      senderId: senderId,
      text: msg.text,
      timestamp: admin.firestore.Timestamp.fromDate(messageTime),
      type: 'text',
      readBy: members
    });
  }

  console.log(`✓ Grupo familiar creado: ${groupId}`);
  return groupId;
}

/**
 * Crear historia/story
 */
async function createStory(userId, storyData) {
  console.log(`Creando historia para: ${userId}...`);

  const now = new Date();
  const expiresAt = new Date(now.getTime() + 24 * 60 * 60 * 1000); // 24 horas

  await db.collection('stories').add({
    userId: userId,
    type: storyData.type,
    content: storyData.content,
    backgroundColor: storyData.backgroundColor,
    createdAt: admin.firestore.Timestamp.fromDate(now),
    expiresAt: admin.firestore.Timestamp.fromDate(expiresAt),
    views: [],
    isDemo: true
  });

  console.log(`✓ Historia creada`);
}

/**
 * Crear ubicación actual
 */
async function createLocation(userId, userName) {
  console.log(`Creando ubicación para: ${userName}...`);

  // Ubicaciones de ejemplo en Buenos Aires
  const locations = [
    { lat: -34.6037, lng: -58.3816, name: 'Obelisco' },
    { lat: -34.5841, lng: -58.3972, name: 'Palermo' },
    { lat: -34.6158, lng: -58.4333, name: 'Caballito' },
  ];

  const location = locations[Math.floor(Math.random() * locations.length)];

  await db.collection('user_locations').doc(userId).set({
    latitude: location.lat,
    longitude: location.lng,
    timestamp: admin.firestore.FieldValue.serverTimestamp(),
    address: location.name + ', Buenos Aires, Argentina',
    approvedParents: []
  });

  console.log(`✓ Ubicación creada: ${location.name}`);
}

/**
 * Crear reporte semanal
 */
async function createWeeklyReport(parentId, childId, childName) {
  console.log(`Creando reporte semanal: ${childName}...`);

  const now = new Date();
  const weekStart = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000);

  await db.collection('weekly_reports').add({
    parentId: parentId,
    childId: childId,
    weekStart: admin.firestore.Timestamp.fromDate(weekStart),
    weekEnd: admin.firestore.Timestamp.fromDate(now),
    summary: {
      totalMessages: 47,
      contactsInteracted: 5,
      averageMessagesPerDay: 6.7,
      mostActiveTime: '16:00-18:00',
      sentiment: 'positive'
    },
    insights: [
      {
        type: 'positive',
        message: `${childName} mantiene conversaciones saludables con sus amigos`
      },
      {
        type: 'info',
        message: 'El tiempo de pantalla está dentro de límites recomendados'
      },
      {
        type: 'success',
        message: 'No se detectaron comportamientos de riesgo'
      }
    ],
    riskLevel: 'low',
    recommendations: [
      'Continuar monitoreando las interacciones',
      'Conversar sobre el contenido compartido en redes'
    ],
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
    isDemo: true
  });

  console.log(`✓ Reporte semanal creado`);
}

/**
 * Script principal
 */
async function main() {
  console.log('=================================');
  console.log('   SEED DATA PARA DEMO/SCREENSHOTS');
  console.log('=================================\n');

  try {
    const createdUsers = [];

    // 1. Crear familias
    console.log('\n📌 PASO 1: Creando familias...\n');
    for (const family of DEMO_FAMILIES) {
      const parentId = await createUser(family.parent, 'parent');
      const childrenIds = [];

      for (const child of family.children) {
        const childId = await createUser(child, 'child');
        childrenIds.push(childId);
        await linkParentChild(parentId, childId);

        createdUsers.push({
          id: childId,
          name: child.name,
          role: 'child',
          parentId: parentId
        });
      }

      createdUsers.push({
        id: parentId,
        name: family.parent.name,
        role: 'parent',
        childrenIds: childrenIds
      });

      // Crear grupo familiar si hay múltiples hijos
      if (childrenIds.length > 1) {
        const lastName = family.parent.name.split(' ').pop();
        await createFamilyGroup(parentId, childrenIds, lastName);
      }
    }

    // 2. Crear amigos
    console.log('\n📌 PASO 2: Creando contactos amigos...\n');
    const friendIds = [];
    for (const friend of FRIEND_CONTACTS) {
      const friendId = await createUser(friend, 'child');
      friendIds.push({ id: friendId, name: friend.name, age: friend.age });
    }

    // 3. Crear contactos entre niños y amigos
    console.log('\n📌 PASO 3: Creando relaciones de amistad...\n');
    const children = createdUsers.filter(u => u.role === 'child');

    // Sofía (primer hijo) con Camila (primer amigo)
    if (children[0] && friendIds[0]) {
      await createContact(children[0].id, friendIds[0].id);
    }

    // Emma (tercer hijo) con Benjamín (segundo amigo)
    if (children[2] && friendIds[1]) {
      await createContact(children[2].id, friendIds[1].id);
    }

    // 4. Crear chats entre padres e hijos
    console.log('\n📌 PASO 4: Creando conversaciones padre-hijo...\n');
    for (const child of children.slice(0, 3)) {
      await createChat(
        child.parentId,
        child.id,
        SAMPLE_CONVERSATIONS.parent_child,
        {
          'parent': child.parentId,
          'child': child.id
        }
      );
    }

    // 5. Crear chats entre amigos
    console.log('\n📌 PASO 5: Creando conversaciones entre amigos...\n');
    if (children[0] && friendIds[0]) {
      await createChat(
        children[0].id,
        friendIds[0].id,
        SAMPLE_CONVERSATIONS.child_friend,
        {
          'child': children[0].id,
          'friend': friendIds[0].id
        }
      );
    }

    // 6. Crear historias
    console.log('\n📌 PASO 6: Creando historias...\n');
    for (let i = 0; i < Math.min(children.length, 2); i++) {
      await createStory(children[i].id, SAMPLE_STORIES[i]);
    }

    // 7. Crear ubicaciones
    console.log('\n📌 PASO 7: Creando ubicaciones...\n');
    for (const child of children) {
      await createLocation(child.id, child.name);
    }

    // 8. Crear reportes semanales
    console.log('\n📌 PASO 8: Creando reportes semanales...\n');
    for (const child of children.slice(0, 2)) {
      await createWeeklyReport(child.parentId, child.id, child.name);
    }

    console.log('\n✅ SEED DATA COMPLETADO\n');
    console.log('=================================');
    console.log('   NÚMEROS PARA INICIAR SESIÓN');
    console.log('=================================\n');
    console.log('⚠️  IMPORTANTE: Estos números usan OTP (códigos por SMS)\n');
    console.log('Para testing/screenshots, configura estos números como');
    console.log('"Test phone numbers" en Firebase Console:\n');
    console.log('Firebase Console → Authentication → Sign-in method → ');
    console.log('Phone → Phone numbers for testing\n');
    console.log('Configura cada número con el código: 123456\n');

    console.log('👨‍👩‍👧‍👦 CUENTAS DE PADRES:\n');
    DEMO_FAMILIES.forEach(family => {
      console.log(`  • ${family.parent.name}`);
      console.log(`    Teléfono: ${family.parent.phone}`);
      console.log(`    Código OTP para testing: 123456\n`);
    });

    console.log('👧👦 CUENTAS DE HIJOS:\n');
    DEMO_FAMILIES.forEach(family => {
      family.children.forEach(child => {
        console.log(`  • ${child.name} (${child.age} años)`);
        console.log(`    Teléfono: ${child.phone}`);
        console.log(`    Código OTP para testing: 123456\n`);
      });
    });

    console.log('👥 CUENTAS DE AMIGOS:\n');
    FRIEND_CONTACTS.forEach(friend => {
      console.log(`  • ${friend.name} (${friend.age} años)`);
      console.log(`    Teléfono: ${friend.phone}`);
      console.log(`    Código OTP para testing: 123456\n`);
    });

    console.log('=================================');
    console.log('   CONFIGURACIÓN EN FIREBASE');
    console.log('=================================\n');
    console.log('1. Ve a Firebase Console:');
    console.log('   https://console.firebase.google.com/project/talia-chat-app-v2/authentication/providers\n');
    console.log('2. Click en "Phone" → "Phone numbers for testing"\n');
    console.log('3. Agrega cada número con el código 123456:\n');

    const allPhones = [
      ...DEMO_FAMILIES.map(f => f.parent.phone),
      ...DEMO_FAMILIES.flatMap(f => f.children.map(c => c.phone)),
      ...FRIEND_CONTACTS.map(f => f.phone)
    ];

    allPhones.forEach(phone => {
      console.log(`   ${phone} → 123456`);
    });

    console.log('\n=================================\n');

  } catch (error) {
    console.error('❌ Error:', error);
    process.exit(1);
  }

  process.exit(0);
}

// Ejecutar
main();
