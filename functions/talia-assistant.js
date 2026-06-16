/**
 * ═══════════════════════════════════════════════════════════════
 * TALIA ASSISTANT - Amiga virtual con IA
 * ═══════════════════════════════════════════════════════════════
 *
 * Talia es una amiga virtual que:
 * 1. Chatea naturalmente con los usuarios
 * 2. Recuerda lo que le cuentan (memoria persistente)
 * 3. Reacciona a stories (con delay aleatorio)
 * 4. Envía mensajes proactivos si no le escriben
 *
 * SEGURIDAD:
 * - Solo ve metadata de chats (con quién, cuándo) - NO contenido
 * - Solo accede a chats donde el usuario participa Y no están bloqueados
 * - La memoria es solo lo que el usuario le cuenta directamente
 *
 * ═══════════════════════════════════════════════════════════════
 */

const { onDocumentCreated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { getFirestore, FieldValue, Timestamp } = require("firebase-admin/firestore");
const { GoogleGenerativeAI } = require("@google/generative-ai");

// ═══════════════════════════════════════════════════════════════
// CONFIGURACIÓN
// ═══════════════════════════════════════════════════════════════

const TALIA_ID = "talia-assistant";
const TALIA_NAME = "Tália";
const TALIA_PHOTO_URL = "https://firebasestorage.googleapis.com/v0/b/talia-chat-app-v2.firebasestorage.app/o/system%2Flogo.png?alt=media";

// Rate limits
const RATE_LIMIT = {
  maxMessagesPerDay: 100,
  maxMemoryItems: 50, // Máximo de cosas que recuerda por usuario
  profileUpdateInterval: 10, // Actualizar perfil cada N mensajes
};

// Story reaction config
const STORY_REACTION = {
  minDelayMinutes: 5,
  maxDelayMinutes: 30,
  reactionProbability: 0.35, // 35% de probabilidad de reaccionar
};

// Horarios permitidos para mensajes proactivos (hora local del usuario)
const ALLOWED_HOURS = {
  start: 9,  // 9 AM
  end: 21,   // 9 PM
};

// Timezone por defecto si el usuario no lo tiene configurado
const DEFAULT_TIMEZONE = "America/Argentina/Buenos_Aires";

// Gemini config
const GEMINI_API_KEY = process.env.GEMINI_API_KEY;
const genAI = GEMINI_API_KEY ? new GoogleGenerativeAI(GEMINI_API_KEY) : null;

if (!genAI) {
  console.warn("⚠️ [Talia] GEMINI_API_KEY no configurado");
}

// ═══════════════════════════════════════════════════════════════
// SYSTEM PROMPT - MODO AMIGA (Base corto - siempre incluido)
// ═══════════════════════════════════════════════════════════════

const TALIA_SYSTEM_PROMPT_BASE = `Sos Tália, una amiga virtual. NO sos asistente ni bot de ayuda.

## Personalidad
- Curiosa, te interesa la vida del usuario
- Hablás como joven argentina natural (sin exagerar modismos)
- Empática, celebrás logros, acompañás en lo malo

## Cómo hablás
- Natural, como WhatsApp con amigo
- Mensajes cortos (1-3 oraciones)
- Emojis con moderación (1-2 max)
- Usás "jaja", "re", "mal", "posta" naturalmente
- NUNCA abuses del "che"
- Tuteo argentino: "vos", "tenés", "querés"

## REGLA MÁS IMPORTANTE: NUNCA MENTIR NI INVENTAR
- Si NO sabés algo, decí "no sé" o "no tengo idea"
- Si te preguntan sobre algo que NO podés ver (fotos, videos, stories, audios), decí honestamente que NO podés verlo
- NUNCA inventes contenido de fotos, videos o stories - NO PODÉS VERLOS
- NUNCA digas que "viste" una historia si no sabés qué contenía
- Si el usuario pregunta "¿viste mi story?", respondé honestamente: "Sé que subiste una pero no puedo ver qué es, contame!"
- Si te muestran una foto y preguntan qué te parece, decí que no podés ver imágenes
- NUNCA alucines ni inventes información que no tenés
- Es mejor decir "no sé" que inventar algo falso

## REGLAS DE PRIVACIDAD
- NUNCA menciones otros contactos del usuario a menos que ÉL los mencione primero
- NUNCA preguntes "¿hablaste con X?" o "¿cómo está X?"
- NUNCA menciones información personal que sabés del usuario a menos que sea relevante a lo que pregunta
- Si el usuario pregunta sobre algo que sabés de él, ahí sí podés usar esa info
- Actuá como si no supieras nada hasta que el usuario comparta

## NO hacés
- NO digas "soy asistente" o "¿en qué te ayudo?"
- NO seas formal
- NO respuestas largas tipo tutorial o listas numeradas
- NO digas que podés recibir audios/fotos/videos (no podés)
- NO reveles que sos IA salvo que pregunten directo
- NO inventes pasos de navegación en la app (ej: "tocá el icono de X")
- Si preguntan CÓMO hacer algo, explicá brevemente qué es la función pero decí "fijate en la app, debe estar en [sección general]" - NO inventes iconos ni ubicaciones exactas
- NO menciones contactos, chats o información personal sin que te pregunten`;

// ═══════════════════════════════════════════════════════════════
// CONOCIMIENTO DE LA APP (Solo se incluye cuando preguntan)
// ═══════════════════════════════════════════════════════════════

const TALIA_APP_KNOWLEDGE = `
## CONOCIMIENTO DE TALIA CHAT

### Qué es
App de mensajería familiar con control parental. Los menores chatean con supervisión de padres.

### Navegación principal
**Niños (2 pestañas abajo):** Chats | Perfil
**Padres (4 pestañas abajo):** Dashboard | Chats | Familia | Perfil
- Para iniciar un chat nuevo: en la pestaña Chats hay un botón flotante con un lápiz ✏️ abajo a la derecha.
- "Mi círculo" y "Mis historias" viven dentro de la pestaña Perfil.

---

### CÓMO CREAR UNA STORY
1. Abrí la cámara de stories (botón de cámara en la pantalla principal)
2. Sacá foto (botón central) o grabá video (mantené presionado)
3. También podés elegir de la galería (icono abajo a la izquierda)
4. Editá: agregá texto, stickers, dibujá
5. Tocá "Guardar" para publicar
6. Si sos menor, tu padre tiene que aprobarla primero

### CÓMO USAR FACE SWAP
1. Abrí la cámara de stories
2. Buscá el icono de carita/máscara (arriba a la derecha, cerca de los filtros)
3. Elegí un personaje de la lista
4. Te muestra cuántas transformaciones te quedan
5. Sacá la foto con el personaje seleccionado
6. Mirá un video o usá premium para transformar
7. La foto transformada va al editor de stories

**Límites:** Gratis 10/día | Premium 50/mes | Premium+ 100/mes

### CÓMO CREAR UNA TRIVIA
1. Entrá desde el editor de stories o la sección de trivias
2. Ponele un título y elegí una imagen de fondo
3. Agregá preguntas: escribí la pregunta, 4 opciones, y marcá la correcta
4. Podés agregar varias preguntas
5. Tocá "Publicar" - dura 24 horas
6. Tus contactos pueden responder y al final ves los resultados

### CÓMO HACER UNA LLAMADA
1. Abrí el chat con la persona
2. Arriba del chat hay dos iconos:
   - Teléfono = llamada de audio
   - Cámara = videollamada
3. Tocá el que quieras y esperá que atienda
4. Durante la llamada: podés silenciar, apagar cámara, poner altavoz

### CÓMO AGREGAR UN CONTACTO
Punto de entrada: en la pestaña **Chats**, tocá el botón flotante con un lápiz ✏️ (abajo a la derecha). Se abre la lista de contactos; arriba hay un botón con el ícono de persona+ para agregar uno nuevo. Te aparecen 3 pestañas:

**Opción 1 - Mi Código:** Mostrá tu QR o copiá tu código y compartilo por WhatsApp.
**Opción 2 - Escanear:** Apuntá al QR de la otra persona.
**Opción 3 - Ingresar:** Escribí o pegá el código del contacto.

Si sos menor, tu padre tiene que aprobar el contacto (lo verá en su pestaña **Familia → Pendientes**).

### CÓMO CREAR UN GRUPO
1. En Chats, tocá el botón + o mantené presionado
2. Elegí "Crear Grupo"
3. Ponele nombre y seleccioná los miembros
4. Opcionalmente subí una foto de grupo
5. Tocá "Crear"

### NUDGES (Empujoncitos)
Son formas de llamar la atención sin mensaje. En la lista de chats, mantené presionado un contacto y elegí el tipo de nudge.

### EMERGENCIAS (Solo menores)
El botón SOS activa una emergencia: llama automáticamente a los padres y comparte tu ubicación en tiempo real.

### PREMIUM
- **Gratis:** Chat, llamadas, stories, trivia, 10 face swaps/día
- **Premium:** 50 face swaps/mes, sin publicidad, personajes exclusivos
- **Premium+:** 100 face swaps/mes, todos los personajes, vincular hasta 3 hijos

### MI CÍRCULO (historias)
Tu "círculo" son las personas con las que comparten historias en ambos sentidos. Tener a alguien como contacto NO alcanza para ver sus historias — hay que invitarlo al círculo.

**Cómo ver tu círculo:** Pestaña Perfil → "Mi círculo".

**Cómo invitar a alguien:** Entrá al perfil del contacto → tocá "Invitar a mi círculo". Cuando acepte, se ven las historias mutuamente.

**Invitaciones pendientes:** Aparecen en "Mi círculo" arriba de la lista, con botones Aceptar/Rechazar.

**Quitar a alguien del círculo:** Perfil del contacto → menú (⋮) → "Quitar de mi círculo". Dejan de verse las historias.

### MIS HISTORIAS
Pestaña Perfil → "Mis historias". Es un grid con las historias que subiste: activas, pendientes de aprobación, rechazadas. Las activas duran 24h.

### FAVORITOS
Para marcar un mensaje como favorito: mantené presionado el mensaje → "Marcar como favorito".

Para ver los favoritos de un chat: tocá el header del chat (foto/nombre del contacto) → tab "Favoritos" en el perfil.

Los favoritos son privados — solo los ves vos.

### FAMILIA (solo padres)
La pestaña **Familia** es donde los padres aprueban o rechazan los contactos de sus hijos. Tiene 4 sub-pestañas:
- **Pendientes:** Solicitudes esperando tu decisión.
- **Aprobados:** Contactos ya autorizados.
- **Rechazados:** Contactos que rechazaste.
- **Revocados:** Aprobados que después diste de baja.

### PROBLEMAS COMUNES
- **No llegan mensajes:** Revisá internet y permisos de notificaciones
- **No puedo agregar contacto:** El otro debe tener Talia, y si sos menor tu padre aprueba
- **Face swap no funciona:** Verificá el límite, buena luz, cara de frente
- **No veo stories:** Tienen que estar en tu círculo (no alcanza con tenerlo como contacto), y las stories duran 24h
- **No aparecen mis favoritos:** Son locales al dispositivo, no se sincronizan entre celulares`;

// Keywords que activan el conocimiento de la app
const APP_KNOWLEDGE_KEYWORDS = [
  'app', 'aplicación', 'aplicacion', 'talia chat', 'funciona', 'función', 'funcion',
  'cómo', 'como', 'qué es', 'que es', 'para qué', 'para que', 'sirve',
  'premium', 'gratis', 'pago', 'suscripción', 'suscripcion',
  'face swap', 'faceswap', 'transformar', 'personaje', 'cara',
  'historia', 'historias', 'story', 'stories', 'publicar',
  'mis historias',
  'llamada', 'videollamada', 'llamar', 'video',
  'grupo', 'grupos', 'crear grupo',
  'contacto', 'contactos', 'agregar', 'añadir', 'bloquear', 'desbloquear',
  'círculo', 'circulo', 'mi círculo', 'mi circulo',
  'invitación', 'invitacion', 'invitar', 'invitaciones',
  'amigo', 'amigos', 'amistad',
  'favorito', 'favoritos', 'marcar mensaje',
  'familia', 'lista blanca', 'whitelist', 'aprobar contacto', 'pendientes',
  'trivia', 'preguntas', 'juego',
  'emergencia', 'sos', 'ayuda urgente', 'ubicación', 'ubicacion',
  'nudge', 'latido', 'zumbido', 'saludo', 'psst',
  'padre', 'madre', 'hijo', 'hija', 'niño', 'niña', 'control parental', 'supervisar',
  'notificación', 'notificacion', 'no me llega', 'no funciona', 'error', 'problema',
  'mensaje', 'audio', 'foto', 'video', 'imagen',
  'privacidad', 'seguridad', 'eliminar cuenta', 'borrar',
  'perfil'
];

/**
 * Detecta si el mensaje pregunta sobre la app
 */
function needsAppKnowledge(message) {
  const lowerMessage = message.toLowerCase();
  return APP_KNOWLEDGE_KEYWORDS.some(keyword => lowerMessage.includes(keyword));
}

/**
 * Construye el system prompt según el contexto
 */
function buildSystemPrompt(userMessage, contextInfo) {
  let prompt = TALIA_SYSTEM_PROMPT_BASE;

  // Agregar conocimiento de la app solo si es relevante
  if (needsAppKnowledge(userMessage)) {
    prompt += "\n" + TALIA_APP_KNOWLEDGE;
  }

  // Agregar contexto del usuario (memoria, chats recientes)
  if (contextInfo) {
    prompt += contextInfo;
  }

  return prompt;
}

// ═══════════════════════════════════════════════════════════════
// MEMORIA DE TALIA - Lo que el usuario le cuenta
// ═══════════════════════════════════════════════════════════════

/**
 * Obtiene la memoria de Talia sobre un usuario
 * @param {string} userId
 * @returns {Promise<Object>}
 */
async function getTaliaMemory(userId) {
  const db = getFirestore();
  const memoryDoc = await db.collection("talia_memory").doc(userId).get();

  if (!memoryDoc.exists) {
    return {
      userName: null,
      facts: [], // Cosas que sabe del usuario
      lastInteraction: null,
      lastProactiveMessage: null,
    };
  }

  return memoryDoc.data();
}

/**
 * Actualiza la memoria de Talia con nueva información
 * @param {string} userId
 * @param {Object} updates
 */
async function updateTaliaMemory(userId, updates) {
  const db = getFirestore();
  await db.collection("talia_memory").doc(userId).set({
    ...updates,
    updatedAt: Timestamp.now(),
  }, { merge: true });
}

/**
 * Extrae información memorable de la conversación usando IA
 * @param {string} userMessage
 * @param {string} taliaResponse
 * @returns {Promise<string[]>} Lista de facts para recordar
 */
async function extractMemorableFacts(userMessage, taliaResponse) {
  if (!genAI) return [];

  try {
    const model = genAI.getGenerativeModel({ model: "gemini-2.5-flash-lite" });

    const prompt = `Analiza este mensaje del usuario y extrae información importante para recordar sobre su vida.
Solo extrae hechos concretos y personales (nombres de amigos, eventos, gustos, problemas).
NO extraigas saludos, respuestas cortas o información trivial.

Mensaje del usuario: "${userMessage}"

Responde SOLO con un JSON array de strings con los hechos importantes.
Si no hay nada importante, responde con un array vacío: []

Ejemplos:
- "Mañana tengo examen de matemáticas" → ["tiene examen de matemáticas"]
- "Mi amigo Juan me invitó a su cumple" → ["tiene un amigo llamado Juan", "Juan lo invitó a su cumpleaños"]
- "Hola qué tal" → []
- "Bien y vos?" → []`;

    const result = await model.generateContent(prompt);
    const text = result.response.text().trim();

    // Extraer JSON
    const jsonMatch = text.match(/\[[\s\S]*\]/);
    if (!jsonMatch) return [];

    const facts = JSON.parse(jsonMatch[0]);
    return Array.isArray(facts) ? facts.slice(0, 3) : []; // Máximo 3 facts por mensaje
  } catch (error) {
    console.error("Error extrayendo facts:", error);
    return [];
  }
}

/**
 * Agrega nuevos facts a la memoria del usuario
 * @param {string} userId
 * @param {string[]} newFacts
 */
async function addFactsToMemory(userId, newFacts) {
  if (!newFacts || newFacts.length === 0) return;

  const db = getFirestore();
  const memory = await getTaliaMemory(userId);

  // Agregar nuevos facts sin duplicados
  const existingFacts = memory.facts || [];
  const allFacts = [...new Set([...existingFacts, ...newFacts])];

  // Limitar a los últimos N facts
  const limitedFacts = allFacts.slice(-RATE_LIMIT.maxMemoryItems);

  // Incrementar contador de interacciones
  const interactionCount = (memory.interactionCount || 0) + 1;

  await db.collection("talia_memory").doc(userId).set({
    facts: limitedFacts,
    interactionCount,
    updatedAt: Timestamp.now(),
  }, { merge: true });

  console.log(`📝 [Talia] Memoria actualizada para ${userId}: +${newFacts.length} facts`);

  // Actualizar perfil resumido cada N interacciones
  if (interactionCount % RATE_LIMIT.profileUpdateInterval === 0) {
    generateUserProfileSummary(userId, limitedFacts)
      .catch(err => console.error("Error generando perfil:", err));
  }
}

// ═══════════════════════════════════════════════════════════════
// PERFIL DE USUARIO - Resumen estructurado
// ═══════════════════════════════════════════════════════════════

/**
 * Genera un perfil resumido del usuario basado en los facts acumulados
 * Este perfil se usa solo cuando es necesario (no se incluye automáticamente)
 * @param {string} userId
 * @param {string[]} facts
 */
async function generateUserProfileSummary(userId, facts) {
  if (!genAI || !facts || facts.length < 3) return;

  console.log(`📊 [Talia] Generando perfil resumido para ${userId}...`);

  try {
    const model = genAI.getGenerativeModel({ model: "gemini-2.5-flash-lite" });

    const prompt = `Analiza estos datos sobre un usuario y genera un perfil estructurado.

Datos conocidos:
${facts.map(f => `- ${f}`).join('\n')}

Responde SOLO con JSON válido en este formato exacto:
{
  "resumen": "Una oración que describe al usuario",
  "datosPersonales": {
    "nombre": "string o null",
    "edad": "string o null",
    "ubicacion": "string o null"
  },
  "familia": ["lista de miembros mencionados"],
  "intereses": ["lista de intereses/gustos"],
  "fechasImportantes": ["cumpleaños, eventos, etc"],
  "temasRecurrentes": ["temas que menciona seguido"],
  "tonoPreferido": "formal/informal/muy informal"
}

Si no hay info para algún campo, usa null o array vacío.`;

    const result = await model.generateContent(prompt);
    const text = result.response.text().trim();

    // Extraer JSON
    const jsonMatch = text.match(/\{[\s\S]*\}/);
    if (!jsonMatch) {
      console.error("No se pudo extraer JSON del perfil");
      return;
    }

    const profile = JSON.parse(jsonMatch[0]);

    // Guardar perfil
    const db = getFirestore();
    await db.collection("talia_user_profiles").doc(userId).set({
      ...profile,
      factsCount: facts.length,
      generatedAt: Timestamp.now(),
      version: 1,
    });

    console.log(`✅ [Talia] Perfil generado para ${userId}`);
  } catch (error) {
    console.error("Error generando perfil:", error);
  }
}

/**
 * Obtiene el perfil resumido de un usuario
 * @param {string} userId
 * @returns {Promise<Object|null>}
 */
async function getUserProfile(userId) {
  const db = getFirestore();
  const profileDoc = await db.collection("talia_user_profiles").doc(userId).get();

  if (!profileDoc.exists) {
    return null;
  }

  return profileDoc.data();
}

/**
 * Verifica si el mensaje del usuario requiere contexto del perfil
 * Solo carga el perfil si el usuario pregunta algo que lo necesite
 * @param {string} message
 * @returns {boolean}
 */
function messageNeedsProfileContext(message) {
  const lowerMessage = message.toLowerCase();

  // Patrones que indican que el usuario quiere que Talia use info que le contó
  const contextTriggers = [
    'te acordás', 'te acordas', 'recuerdas', 'recordás', 'recordas',
    'te conté', 'te conte', 'te dije', 'ya sabés', 'ya sabes',
    'como te dije', 'lo que te conté', 'lo que te conte',
    'mi cumple', 'mi cumpleaños',
    'mi hijo', 'mi hija', 'mis hijos', 'mi familia',
    'mi amigo', 'mi amiga', 'mis amigos',
    'qué sabés de mí', 'que sabes de mi', 'qué te conté', 'que te conte',
  ];

  return contextTriggers.some(trigger => lowerMessage.includes(trigger));
}

// ═══════════════════════════════════════════════════════════════
// CONTEXTO SEGURO - Metadata de chats (NO contenido)
// ═══════════════════════════════════════════════════════════════

/**
 * Obtiene contexto seguro de las conversaciones del usuario
 * SOLO metadata: con quién habló y cuándo (NO contenido de mensajes)
 *
 * @param {string} userId
 * @returns {Promise<Object>}
 */
async function getUserChatContext(userId) {
  const db = getFirestore();

  try {
    // Query seguro: solo chats donde participa
    const chatsSnapshot = await db.collection("chats")
      .where("participants", "array-contains", userId)
      .orderBy("lastMessageTime", "desc")
      .limit(10)
      .get();

    const recentContacts = [];

    for (const chatDoc of chatsSnapshot.docs) {
      const data = chatDoc.data();

      // SEGURIDAD: Doble verificación de participante
      if (!data.participants || !data.participants.includes(userId)) {
        continue;
      }

      // Excluir chats bloqueados
      if (data.isBlocked === true) {
        continue;
      }

      // Excluir chat con Talia
      if (chatDoc.id.includes(TALIA_ID)) {
        continue;
      }

      // Obtener el otro participante
      const otherUserId = data.participants.find(p => p !== userId);
      if (!otherUserId) continue;

      // Obtener nombre del contacto
      const userDoc = await db.collection("users").doc(otherUserId).get();
      const contactName = userDoc.exists ? userDoc.data().name : "alguien";

      // Calcular tiempo relativo
      const lastTime = data.lastMessageTime?.toDate?.() || data.lastMessageTime;
      const timeAgo = getTimeAgo(lastTime);

      recentContacts.push({
        name: contactName,
        timeAgo: timeAgo,
        // NO incluimos lastMessage por privacidad
      });
    }

    return {
      recentContacts,
      hasActivity: recentContacts.length > 0,
    };
  } catch (error) {
    console.error("Error obteniendo contexto:", error);
    return { recentContacts: [], hasActivity: false };
  }
}

/**
 * Formatea tiempo relativo
 */
function getTimeAgo(date) {
  if (!date) return "hace tiempo";

  const now = new Date();
  const then = date instanceof Date ? date : new Date(date);
  const diffMs = now - then;
  const diffMins = Math.floor(diffMs / 60000);
  const diffHours = Math.floor(diffMins / 60);
  const diffDays = Math.floor(diffHours / 24);

  if (diffMins < 5) return "recién";
  if (diffMins < 60) return `hace ${diffMins} minutos`;
  if (diffHours < 24) return `hace ${diffHours} hora${diffHours > 1 ? 's' : ''}`;
  if (diffDays === 1) return "ayer";
  if (diffDays < 7) return `hace ${diffDays} días`;
  return "hace más de una semana";
}

// ═══════════════════════════════════════════════════════════════
// TIMEZONE Y HORARIOS
// ═══════════════════════════════════════════════════════════════

/**
 * Obtiene el timezone del usuario
 * @param {string} userId
 * @returns {Promise<string>} Timezone string (ej: "America/Argentina/Buenos_Aires")
 */
async function getUserTimezone(userId) {
  const db = getFirestore();

  try {
    const userDoc = await db.collection("users").doc(userId).get();
    if (userDoc.exists && userDoc.data().timezone) {
      return userDoc.data().timezone;
    }
  } catch (error) {
    console.error("Error obteniendo timezone:", error);
  }

  return DEFAULT_TIMEZONE;
}

/**
 * Obtiene la hora actual en el timezone del usuario
 * @param {string} timezone
 * @returns {number} Hora actual (0-23)
 */
function getCurrentHourInTimezone(timezone) {
  try {
    const now = new Date();
    const options = { timeZone: timezone, hour: 'numeric', hour12: false };
    const hourString = now.toLocaleString('en-US', options);
    return parseInt(hourString, 10);
  } catch (error) {
    console.error(`Error con timezone ${timezone}:`, error);
    // Fallback a hora UTC
    return new Date().getUTCHours();
  }
}

/**
 * Verifica si es un horario apropiado para enviar mensajes al usuario
 * @param {string} userId
 * @returns {Promise<{allowed: boolean, currentHour: number, timezone: string}>}
 */
async function isAppropriateTimeForUser(userId) {
  const timezone = await getUserTimezone(userId);
  const currentHour = getCurrentHourInTimezone(timezone);

  const allowed = currentHour >= ALLOWED_HOURS.start && currentHour < ALLOWED_HOURS.end;

  return {
    allowed,
    currentHour,
    timezone,
    reason: allowed ? null : `Hora local: ${currentHour}:00 (permitido: ${ALLOWED_HOURS.start}:00 - ${ALLOWED_HOURS.end}:00)`
  };
}

// ═══════════════════════════════════════════════════════════════
// RATE LIMITING
// ═══════════════════════════════════════════════════════════════

async function checkRateLimit(userId) {
  const db = getFirestore();
  const today = new Date().toISOString().split('T')[0];
  const key = `talia_${userId}_${today}`;

  try {
    const doc = await db.collection("talia_rate_limits").doc(key).get();
    const count = doc.exists ? doc.data().count : 0;

    if (count >= RATE_LIMIT.maxMessagesPerDay) {
      return { allowed: false, remaining: 0 };
    }

    const deleteAt = Timestamp.fromMillis(Date.now() + 2 * 24 * 60 * 60 * 1000);
    await db.collection("talia_rate_limits").doc(key).set({
      count: count + 1,
      userId,
      date: today,
      updatedAt: Timestamp.now(),
      deleteAt,
    }, { merge: true });

    return { allowed: true, remaining: RATE_LIMIT.maxMessagesPerDay - count - 1 };
  } catch (error) {
    console.error("Error en rate limit:", error);
    return { allowed: true, remaining: RATE_LIMIT.maxMessagesPerDay };
  }
}

// ═══════════════════════════════════════════════════════════════
// GENERACIÓN DE RESPUESTAS
// ═══════════════════════════════════════════════════════════════

/**
 * Obtiene contexto de la conversación con Talia
 */
async function getConversationHistory(chatId, limit = 10) {
  const db = getFirestore();

  try {
    const messagesSnapshot = await db
      .collection("chats")
      .doc(chatId)
      .collection("messages")
      .orderBy("timestamp", "desc")
      .limit(limit + 1)
      .get();

    const messages = messagesSnapshot.docs
      .map(doc => doc.data())
      .reverse()
      .slice(0, -1);

    return messages;
  } catch (error) {
    console.error("Error obteniendo historial:", error);
    return [];
  }
}

/**
 * Genera respuesta de Talia
 */
async function generateResponse(userMessage, chatId, userId) {
  if (!genAI) {
    return "Uy, estoy teniendo problemas técnicos 😅 Escribime en un ratito";
  }

  try {
    // Obtener contexto básico (sin incluir info personal automáticamente)
    const [memory, conversationHistory] = await Promise.all([
      getTaliaMemory(userId),
      getConversationHistory(chatId, 8),
    ]);

    // El perfil del usuario está disponible pero NO se incluye automáticamente
    let contextInfo = "";

    // Solo incluir el nombre si lo sabemos (es lo mínimo necesario)
    if (memory.userName) {
      contextInfo += `\n\n## Info básica:\n- Nombre del usuario: ${memory.userName}`;
    }

    // SOLO cargar el perfil y facts si el usuario lo solicita explícitamente
    if (messageNeedsProfileContext(userMessage)) {
      console.log(`🔍 [Talia] Usuario solicita contexto, cargando perfil...`);

      const [profile] = await Promise.all([
        getUserProfile(userId),
      ]);

      // Agregar facts que sabemos del usuario
      if (memory.facts && memory.facts.length > 0) {
        contextInfo += `\n\n## Lo que el usuario te contó antes:\n- ${memory.facts.slice(-15).join("\n- ")}`;
      }

      // Agregar perfil resumido si existe
      if (profile) {
        contextInfo += `\n\n## Perfil del usuario:`;
        if (profile.resumen) contextInfo += `\n- Resumen: ${profile.resumen}`;
        if (profile.familia?.length > 0) contextInfo += `\n- Familia: ${profile.familia.join(", ")}`;
        if (profile.intereses?.length > 0) contextInfo += `\n- Intereses: ${profile.intereses.join(", ")}`;
        if (profile.fechasImportantes?.length > 0) contextInfo += `\n- Fechas importantes: ${profile.fechasImportantes.join(", ")}`;
      }

      contextInfo += `\n\n## IMPORTANTE: El usuario está preguntando por algo que te contó antes. Usá esta información para responder.`;
    }

    // Construir prompt optimizado (incluye conocimiento de app solo si es relevante)
    const systemPrompt = buildSystemPrompt(userMessage, contextInfo);

    const model = genAI.getGenerativeModel({
      model: "gemini-2.5-flash-lite",
      systemInstruction: systemPrompt,
    });

    // Construir historial
    let history = conversationHistory.map(msg => ({
      role: msg.senderId === TALIA_ID ? "model" : "user",
      parts: [{ text: msg.text || "[foto/audio]" }],
    }));

    // Limpiar historial para Gemini
    while (history.length > 0 && history[0].role === "model") {
      history.shift();
    }

    const cleanHistory = [];
    for (const msg of history) {
      if (cleanHistory.length === 0 || cleanHistory[cleanHistory.length - 1].role !== msg.role) {
        cleanHistory.push(msg);
      } else {
        cleanHistory[cleanHistory.length - 1] = msg;
      }
    }

    const chat = model.startChat({ history: cleanHistory });
    const result = await chat.sendMessage(userMessage);
    let response = result.response.text();

    // Limitar longitud
    if (response.length > 400) {
      response = response.substring(0, 397) + "...";
    }

    return response;
  } catch (error) {
    console.error("Error generando respuesta:", error);

    if (error.message?.includes("SAFETY")) {
      return "Mmm mejor hablemos de otra cosa 😅";
    }

    return "Perdón, se me fue el wifi 😅 ¿Qué me decías?";
  }
}

/**
 * Envía mensaje de Talia
 */
async function sendTaliaMessage(chatId, text) {
  const db = getFirestore();
  const now = Timestamp.now();

  const messageRef = await db
    .collection("chats")
    .doc(chatId)
    .collection("messages")
    .add({
      senderId: TALIA_ID,
      text: text,
      timestamp: now,
      type: "text",
      isRead: false,
      moderationStatus: "approved",
      status: "sent",
    });

  await db.collection("chats").doc(chatId).update({
    lastMessage: text,
    lastMessageTime: now,
    lastMessageAt: now,
    lastMessageSenderId: TALIA_ID,
    lastMessageSender: TALIA_ID,
    lastMessageType: "text",
    visible: true,
  });

  return messageRef.id;
}

// ═══════════════════════════════════════════════════════════════
// CLOUD FUNCTIONS
// ═══════════════════════════════════════════════════════════════

/**
 * Crear chat con Talia cuando se registra un usuario
 */
exports.onUserCreatedCreateTaliaChat = onDocumentCreated(
  {
    document: "users/{userId}",
    region: "us-central1",
    memory: "256MiB",
    timeoutSeconds: 60,
  },
  async (event) => {
    const userId = event.params.userId;
    const userData = event.data?.data();

    if (userId === TALIA_ID || userData?.isSystemUser || userData?.isBotUser) {
      return null;
    }

    const userName = userData?.name || "Usuario";
    const firstName = userName.split(' ')[0];

    console.log(`🤖 [Talia] Creando chat para ${userName} (${userId})`);

    try {
      const db = getFirestore();

      // Asegurar que Talia existe
      const taliaRef = db.collection("users").doc(TALIA_ID);
      const taliaDoc = await taliaRef.get();
      if (!taliaDoc.exists) {
        await taliaRef.set({
          uid: TALIA_ID,
          name: TALIA_NAME,
          email: "talia@talia.app",
          role: "adult",
          photoURL: TALIA_PHOTO_URL,
          isSystemUser: true,
          isBotUser: true,
          isOnline: true,
          createdAt: Timestamp.now(),
        });
      }

      const participants = [userId, TALIA_ID].sort();
      const chatId = participants.join("_");

      const chatRef = db.collection("chats").doc(chatId);
      const chatDoc = await chatRef.get();

      if (chatDoc.exists) {
        return null;
      }

      const now = Timestamp.now();
      const welcomeMessage = `Holaaa${firstName ? ` ${firstName}` : ''}! 👋 Soy Tália, qué onda? Contame qué andás haciendo`;

      await chatRef.set({
        participants,
        users: participants,
        type: "individual",
        isValidChat: true,
        visible: true,
        createdAt: now,
        lastMessageTime: now,
        lastMessageAt: now,
        lastMessage: welcomeMessage,
        lastMessageSenderId: TALIA_ID,
        lastMessageSender: TALIA_ID,
        lastMessageType: "text",
        isTaliaChat: true,
        deletedBy: [],
      });

      await db.collection("chats").doc(chatId).collection("messages").add({
        senderId: TALIA_ID,
        text: welcomeMessage,
        timestamp: now,
        type: "text",
        isRead: false,
        moderationStatus: "approved",
        status: "sent",
      });

      // Guardar nombre en memoria
      await updateTaliaMemory(userId, {
        userName: firstName,
        facts: [],
        lastInteraction: now,
      });

      console.log(`✅ [Talia] Chat creado: ${chatId}`);
      return { success: true };
    } catch (error) {
      console.error("❌ [Talia] Error:", error);
      return null;
    }
  }
);

/**
 * Responder a mensajes enviados a Talia
 */
exports.onMessageToTalia = onDocumentCreated(
  {
    document: "chats/{chatId}/messages/{messageId}",
    region: "us-central1",
    memory: "512MiB",
    timeoutSeconds: 120,
  },
  async (event) => {
    const chatId = event.params.chatId;
    const messageData = event.data?.data();

    if (!chatId.includes(TALIA_ID)) return null;

    const senderId = messageData?.senderId;
    const messageText = messageData?.text;
    const messageType = messageData?.type;

    if (senderId === TALIA_ID) return null;
    if (messageData?.moderationStatus === "blocked") return null;

    // 🔄 El usuario respondió: resetear el contador de mensajes proactivos sin
    // contestar (circuit breaker de "no insistir tras 5 sin respuesta").
    try {
      await updateTaliaMemory(senderId, { unansweredProactiveCount: 0 });
    } catch (_) {}

    // Detectar mensajes multimedia (audio, imagen, video)
    const isAudio = messageType === "audio" || messageData?.audioUrl;
    const isImage = messageType === "image" || messageData?.imageUrl;
    const isVideo = messageType === "video" || messageData?.videoUrl;

    if (isAudio || isImage || isVideo) {
      console.log(`📎 [Talia] Mensaje multimedia de ${senderId} (${messageType})`);
      const mediaResponse = isAudio
        ? "Uy perdón, no puedo escuchar audios 😅 ¿Me lo escribís?"
        : isVideo
        ? "No puedo ver videos todavía 😅 Contame qué es!"
        : "Vi que me mandaste una foto! No la puedo ver bien, ¿qué es?";
      await sendTaliaMessage(chatId, mediaResponse);
      return { multimedia: true };
    }

    // Si no hay texto, ignorar
    if (!messageText || messageText.trim().length === 0) return null;

    console.log(`💬 [Talia] Mensaje de ${senderId}: "${messageText.substring(0, 50)}..."`);

    try {
      const rateLimit = await checkRateLimit(senderId);
      if (!rateLimit.allowed) {
        await sendTaliaMessage(chatId, "Ey, hablamos un montón hoy! 😄 Mañana seguimos, dale?");
        return { rateLimited: true };
      }

      // Generar respuesta
      const response = await generateResponse(messageText, chatId, senderId);
      await sendTaliaMessage(chatId, response);

      // Actualizar última interacción
      await updateTaliaMemory(senderId, {
        lastInteraction: Timestamp.now(),
      });

      // Extraer y guardar facts en background (no bloquea la respuesta)
      extractMemorableFacts(messageText, response)
        .then(facts => addFactsToMemory(senderId, facts))
        .catch(err => console.error("Error guardando facts:", err));

      console.log(`✅ [Talia] Respuesta enviada`);
      return { success: true };
    } catch (error) {
      console.error("❌ [Talia] Error:", error);
      await sendTaliaMessage(chatId, "Uy perdón, se me bugueó algo 😅 ¿Qué me decías?");
      return null;
    }
  }
);

/**
 * Reaccionar a stories del usuario (con delay aleatorio)
 */
exports.onStoryCreatedTaliaReaction = onDocumentCreated(
  {
    document: "stories/{storyId}",
    region: "us-central1",
    memory: "256MiB",
    timeoutSeconds: 300,
  },
  async (event) => {
    const storyData = event.data?.data();
    const storyId = event.params.storyId;
    const userId = storyData?.userId;

    if (!userId || userId === TALIA_ID) return null;

    // Solo reaccionar si está aprobada (o no requiere aprobación)
    if (storyData?.status && storyData.status !== "approved") return null;

    // Probabilidad aleatoria de reaccionar (no a todas)
    const shouldReact = Math.random() < STORY_REACTION.reactionProbability;
    if (!shouldReact) {
      console.log(`⏭️ [Talia] No reacciona a story ${storyId} (random skip)`);
      return null;
    }

    // Calcular delay aleatorio
    const delayMinutes = Math.floor(
      Math.random() * (STORY_REACTION.maxDelayMinutes - STORY_REACTION.minDelayMinutes + 1)
    ) + STORY_REACTION.minDelayMinutes;

    console.log(`⏰ [Talia] Reacción a story ${storyId} programada en ${delayMinutes} minutos`);

    // Guardar tarea pendiente para ejecutar después
    const db = getFirestore();
    await db.collection("talia_pending_reactions").add({
      storyId,
      userId,
      storyType: storyData?.type || "image",
      executeAt: Timestamp.fromMillis(Date.now() + delayMinutes * 60 * 1000),
      createdAt: Timestamp.now(),
      processed: false,
    });

    return { scheduled: true, delayMinutes };
  }
);

/**
 * Procesar reacciones pendientes a stories (cada 5 minutos)
 * Respeta el horario del usuario (9 AM - 9 PM hora local)
 */
exports.processTaliaPendingReactions = onSchedule(
  {
    schedule: "every 5 minutes",
    region: "us-central1",
    memory: "512MiB",
    timeoutSeconds: 120,
  },
  async (event) => {
    const db = getFirestore();
    const now = Timestamp.now();

    // Una reacción "sana" se dispara 5–30 min después de publicarse la story
    // (ver STORY_REACTION). Si executeAt quedó vencido hace MÁS de este umbral,
    // es backlog de una caída del scheduler (ej: índice faltante): enviarla ahora
    // sería comentar una historia vieja y, en bloque, spamear al usuario. Esas se
    // descartan en silencio (processed: true, skipped: "stale") sin enviar nada.
    // NOTA: las reacciones postergadas por horario refrescan executeAt hacia
    // adelante, así que nunca caen en esta ventana por error.
    const STALE_REACTION_THRESHOLD_MS = 2 * 60 * 60 * 1000; // 2 horas

    // Obtener reacciones pendientes que ya deben ejecutarse
    // limit alto para drenar rápido cualquier backlog (las stale no envían msg).
    const pendingSnapshot = await db.collection("talia_pending_reactions")
      .where("processed", "==", false)
      .where("executeAt", "<=", now)
      .limit(50)
      .get();

    if (pendingSnapshot.empty) {
      return null;
    }

    console.log(`🔄 [Talia] Procesando ${pendingSnapshot.size} reacciones pendientes`);

    let processed = 0;
    let postponed = 0;
    let discarded = 0;

    // Usuarios a los que YA les comentamos una historia en este run, para no
    // mandar varias cuando se procesan varias reacciones del mismo user juntas
    // (ej: subió 5 historias seguidas).
    const commentedUsersThisRun = new Set();

    for (const doc of pendingSnapshot.docs) {
      const reaction = doc.data();

      try {
        // 🗑️ Descartar reacciones vencidas hace rato (backlog de una caída).
        const executeAtMs = reaction.executeAt?.toMillis?.() ?? 0;
        if (Date.now() - executeAtMs > STALE_REACTION_THRESHOLD_MS) {
          await doc.ref.update({ processed: true, skipped: "stale" });
          discarded++;
          continue;
        }

        // ⏰ VERIFICAR HORARIO DEL USUARIO (9 AM - 9 PM hora local)
        const timeCheck = await isAppropriateTimeForUser(reaction.userId);
        if (!timeCheck.allowed) {
          // Postponer la reacción para más tarde (agregar 1 hora)
          const newExecuteAt = Timestamp.fromMillis(Date.now() + 60 * 60 * 1000);
          await doc.ref.update({
            executeAt: newExecuteAt,
            postponedReason: timeCheck.reason,
            postponedCount: (reaction.postponedCount || 0) + 1,
          });
          postponed++;
          console.log(`⏰ [Talia] Reacción postponida para ${reaction.userId}: ${timeCheck.reason}`);
          continue;
        }

        // Verificar que la story aún existe
        const storyDoc = await db.collection("stories").doc(reaction.storyId).get();
        if (!storyDoc.exists) {
          await doc.ref.update({ processed: true, skipped: "story_deleted" });
          continue;
        }

        // 🔢 Límite: MÁXIMO 1 comentario de historia por día por usuario, y
        // circuit breaker (no insistir si ignoró 5 mensajes proactivos).
        const memory = await getTaliaMemory(reaction.userId);
        const unanswered = memory.unansweredProactiveCount || 0;
        if (unanswered >= 5) {
          await doc.ref.update({ processed: true, skipped: "unanswered_limit" });
          discarded++;
          continue;
        }
        if (commentedUsersThisRun.has(reaction.userId)) {
          await doc.ref.update({ processed: true, skipped: "daily_story_limit" });
          discarded++;
          continue;
        }
        const lastStoryReactionAt =
          memory.lastStoryReactionAt?.toMillis?.() ?? 0;
        if (Date.now() - lastStoryReactionAt < 24 * 60 * 60 * 1000) {
          await doc.ref.update({ processed: true, skipped: "daily_story_limit" });
          discarded++;
          continue;
        }

        // Obtener chat con el usuario
        const participants = [reaction.userId, TALIA_ID].sort();
        const chatId = participants.join("_");

        // Verificar que el chat existe
        const chatDoc = await db.collection("chats").doc(chatId).get();
        if (!chatDoc.exists) {
          await doc.ref.update({ processed: true, skipped: "no_chat" });
          continue;
        }

        // Generar comentario sobre la story
        const storyComment = await generateStoryComment(reaction.storyType, reaction.userId);
        await sendTaliaMessage(chatId, storyComment);

        // Marcar: comentario de historia enviado hoy + 1 proactivo sin responder.
        commentedUsersThisRun.add(reaction.userId);
        await updateTaliaMemory(reaction.userId, {
          lastStoryReactionAt: Timestamp.now(),
          unansweredProactiveCount: FieldValue.increment(1),
        });

        await doc.ref.update({ processed: true, processedAt: Timestamp.now() });
        processed++;
        console.log(`✅ [Talia] Reacción enviada a ${reaction.userId} (hora local: ${timeCheck.currentHour}:00)`);
      } catch (error) {
        console.error(`❌ [Talia] Error procesando reacción:`, error);
        await doc.ref.update({ processed: true, error: error.message });
      }
    }

    if (discarded > 0) {
      console.log(`🗑️ [Talia] ${discarded} reacciones descartadas por vencidas (backlog)`);
    }

    return { processed, postponed, discarded };
  }
);

/**
 * Genera un comentario natural sobre una story
 * NOTA: Tália NO puede ver el contenido de las stories, solo sabe que se publicó una
 */
async function generateStoryComment(storyType, userId) {
  const memory = await getTaliaMemory(userId);
  const userName = memory.userName || "";

  // Comentarios honestos - Tália sabe que subieron una story pero NO puede ver el contenido
  const comments = [
    "Ey subiste una historia! 📸 Qué es? Contame!",
    "Vi que subiste algo a tu historia, qué onda? 😊",
    "Opa, nueva historia! De qué se trata?",
    "Ey! Me di cuenta que publicaste una historia, qué es?",
    "Subiste una story! No la puedo ver bien, contame qué es 👀",
    "Nueva historia! Qué andás haciendo? Contame!",
  ];

  const randomComment = comments[Math.floor(Math.random() * comments.length)];

  return randomComment;
}

/**
 * Mensajes proactivos diarios (si no le escriben)
 * Ahora corre cada hora para verificar timezone de cada usuario
 */
exports.taliaDailyProactiveMessages = onSchedule(
  {
    schedule: "0 * * * *", // Cada hora en punto
    region: "us-central1",
    memory: "512MiB",
    timeoutSeconds: 300,
  },
  async (event) => {
    const db = getFirestore();
    const now = new Date();
    const oneDayAgo = new Date(now.getTime() - 24 * 60 * 60 * 1000);

    console.log("🔄 [Talia] Buscando usuarios inactivos para mensaje proactivo...");

    // Buscar usuarios que no interactuaron en 24+ horas
    const memorySnapshot = await db.collection("talia_memory")
      .where("lastInteraction", "<", Timestamp.fromDate(oneDayAgo))
      .limit(30)
      .get();

    if (memorySnapshot.empty) {
      console.log("✅ [Talia] Todos los usuarios activos");
      return null;
    }

    const proactiveMessages = [
      "Ey! Qué tal tu día? 😊",
      "Hola! Todo bien? Hace rato no hablamos",
      "Qué onda? Cómo andás?",
      "Ey! Qué contás de nuevo?",
      "Holaa, qué tal todo por ahí? 👋",
    ];

    let sent = 0;
    let skippedTimezone = 0;

    for (const memoryDoc of memorySnapshot.docs) {
      const userId = memoryDoc.id;
      const memory = memoryDoc.data();

      // 🛑 Circuit breaker: si ignoró 5 mensajes proactivos seguidos, no insistir.
      if ((memory.unansweredProactiveCount || 0) >= 5) {
        continue;
      }

      // No enviar si ya mandamos proactivo hoy
      if (memory.lastProactiveMessage) {
        const lastProactive = memory.lastProactiveMessage.toDate?.() || memory.lastProactiveMessage;
        if (now - lastProactive < 24 * 60 * 60 * 1000) {
          continue;
        }
      }

      // ⏰ VERIFICAR HORARIO DEL USUARIO (9 AM - 9 PM hora local)
      const timeCheck = await isAppropriateTimeForUser(userId);
      if (!timeCheck.allowed) {
        skippedTimezone++;
        console.log(`⏰ [Talia] Saltando ${userId}: ${timeCheck.reason}`);
        continue;
      }

      // Obtener chat
      const participants = [userId, TALIA_ID].sort();
      const chatId = participants.join("_");

      const chatDoc = await db.collection("chats").doc(chatId).get();
      if (!chatDoc.exists) continue;

      // Probabilidad del 50% de enviar mensaje proactivo
      if (Math.random() > 0.5) continue;

      // Enviar mensaje
      const message = proactiveMessages[Math.floor(Math.random() * proactiveMessages.length)];
      await sendTaliaMessage(chatId, message);

      // Actualizar memoria: proactivo enviado + 1 sin responder (se resetea
      // cuando el usuario le escribe a Talia).
      await db.collection("talia_memory").doc(userId).update({
        lastProactiveMessage: Timestamp.now(),
        unansweredProactiveCount: FieldValue.increment(1),
      });

      sent++;
      console.log(`📤 [Talia] Mensaje proactivo enviado a ${userId} (hora local: ${timeCheck.currentHour}:00)`);
    }

    console.log(`✅ [Talia] ${sent} mensajes proactivos enviados, ${skippedTimezone} saltados por horario`);
    return { sent, skippedTimezone };
  }
);

// ═══════════════════════════════════════════════════════════════
// EXPORTS
// ═══════════════════════════════════════════════════════════════

module.exports = {
  onUserCreatedCreateTaliaChat: exports.onUserCreatedCreateTaliaChat,
  onMessageToTalia: exports.onMessageToTalia,
  onStoryCreatedTaliaReaction: exports.onStoryCreatedTaliaReaction,
  processTaliaPendingReactions: exports.processTaliaPendingReactions,
  taliaDailyProactiveMessages: exports.taliaDailyProactiveMessages,
  // Helpers
  TALIA_ID,
  TALIA_NAME,
};
