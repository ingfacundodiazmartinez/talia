/**
 * Tests de Firestore Security Rules
 *
 * Ejecutar: npm test
 *
 * Estos tests validan que las reglas de seguridad funcionen correctamente
 * y prevengan accesos no autorizados.
 */

const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require("@firebase/rules-unit-testing");
const fs = require("fs");
const path = require("path");

// Cargar las reglas de Firestore
const rulesPath = path.join(__dirname, "../../firestore.rules");
const rules = fs.readFileSync(rulesPath, "utf8");

let testEnv;

describe("Firestore Security Rules", () => {
  // Inicializar ambiente de testing antes de todas las pruebas
  beforeAll(async () => {
    testEnv = await initializeTestEnvironment({
      projectId: "talia-test",
      firestore: {
        rules: rules,
        host: "localhost",
        port: 8080,
      },
    });
  });

  // Limpiar datos después de cada test
  afterEach(async () => {
    await testEnv.clearFirestore();
  });

  // Limpiar ambiente al final
  afterAll(async () => {
    await testEnv.cleanup();
  });

  // ═══════════════════════════════════════════════════════════════
  // TESTS: Colección users
  // ═══════════════════════════════════════════════════════════════

  describe("users collection", () => {
    test("Usuario puede leer su propio documento", async () => {
      const alice = testEnv.authenticatedContext("alice");
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context.firestore().collection("users").doc("alice").set({
          name: "Alice",
          email: "alice@test.com",
          role: "parent",
          createdAt: new Date(),
        });
      });

      await assertSucceeds(
        alice.firestore().collection("users").doc("alice").get()
      );
    });

    test("Usuario NO puede modificar su rol", async () => {
      const alice = testEnv.authenticatedContext("alice");
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context.firestore().collection("users").doc("alice").set({
          name: "Alice",
          email: "alice@test.com",
          role: "parent",
          createdAt: new Date(),
        });
      });

      await assertFails(
        alice.firestore().collection("users").doc("alice").update({
          role: "admin", // ❌ Intentar cambiar rol
        })
      );
    });

    test("Usuario puede actualizar campos permitidos", async () => {
      const alice = testEnv.authenticatedContext("alice");
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context.firestore().collection("users").doc("alice").set({
          name: "Alice",
          email: "alice@test.com",
          role: "parent",
          createdAt: new Date(),
        });
      });

      await assertSucceeds(
        alice.firestore().collection("users").doc("alice").update({
          name: "Alice Updated", // ✅ Permitido
        })
      );
    });

    test("Usuario NO puede leer documento de otro usuario sin estar autenticado", async () => {
      const unauthenticated = testEnv.unauthenticatedContext();
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context.firestore().collection("users").doc("alice").set({
          name: "Alice",
          email: "alice@test.com",
          role: "parent",
          createdAt: new Date(),
        });
      });

      await assertFails(
        unauthenticated.firestore().collection("users").doc("alice").get()
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // TESTS: Colección notifications
  // ═══════════════════════════════════════════════════════════════

  describe("notifications collection", () => {
    test("Usuario puede leer sus propias notificaciones", async () => {
      const alice = testEnv.authenticatedContext("alice");
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context.firestore().collection("notifications").doc("notif1").set({
          userId: "alice",
          title: "Test",
          body: "Test notification",
          read: false,
          createdAt: new Date(),
        });
      });

      await assertSucceeds(
        alice.firestore().collection("notifications").doc("notif1").get()
      );
    });

    test("Usuario NO puede crear notificaciones (solo Cloud Functions)", async () => {
      const alice = testEnv.authenticatedContext("alice");

      await assertFails(
        alice.firestore().collection("notifications").add({
          userId: "alice",
          title: "Spam",
          body: "This should fail",
          read: false,
          createdAt: new Date(),
        })
      );
    });

    test("Usuario puede marcar notificación como leída", async () => {
      const alice = testEnv.authenticatedContext("alice");
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context.firestore().collection("notifications").doc("notif1").set({
          userId: "alice",
          title: "Test",
          body: "Test notification",
          read: false,
          createdAt: new Date(),
        });
      });

      await assertSucceeds(
        alice.firestore().collection("notifications").doc("notif1").update({
          read: true, // ✅ Permitido
        })
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // TESTS: Colección parent_child_links
  // ═══════════════════════════════════════════════════════════════

  describe("parent_child_links collection", () => {
    test("Padre puede leer vínculo con su hijo", async () => {
      const parent = testEnv.authenticatedContext("parent1");
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context
          .firestore()
          .collection("parent_child_links")
          .doc("parent1_child1")
          .set({
            parentId: "parent1",
            childId: "child1",
            status: "approved",
            linkedAt: new Date(),
          });
      });

      await assertSucceeds(
        parent
          .firestore()
          .collection("parent_child_links")
          .doc("parent1_child1")
          .get()
      );
    });

    test("Usuario NO puede crear vínculos padre-hijo desde cliente", async () => {
      const parent = testEnv.authenticatedContext("parent1");

      await assertFails(
        parent
          .firestore()
          .collection("parent_child_links")
          .doc("parent1_child2")
          .set({
            parentId: "parent1",
            childId: "child2",
            status: "approved",
            linkedAt: new Date(),
          })
      );
    });

    test("Usuario NO puede leer vínculo de otros usuarios", async () => {
      const attacker = testEnv.authenticatedContext("attacker");
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context
          .firestore()
          .collection("parent_child_links")
          .doc("parent1_child1")
          .set({
            parentId: "parent1",
            childId: "child1",
            status: "approved",
            linkedAt: new Date(),
          });
      });

      await assertFails(
        attacker
          .firestore()
          .collection("parent_child_links")
          .doc("parent1_child1")
          .get()
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // TESTS: Colección chats/messages
  // ═══════════════════════════════════════════════════════════════

  describe("chats and messages", () => {
    test("Participante puede leer mensajes del chat", async () => {
      const alice = testEnv.authenticatedContext("alice");
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context.firestore().collection("chats").doc("chat1").set({
          participants: ["alice", "bob"],
          createdAt: new Date(),
        });

        await context
          .firestore()
          .collection("chats")
          .doc("chat1")
          .collection("messages")
          .doc("msg1")
          .set({
            senderId: "bob",
            text: "Hello",
            timestamp: new Date(),
          });
      });

      await assertSucceeds(
        alice
          .firestore()
          .collection("chats")
          .doc("chat1")
          .collection("messages")
          .doc("msg1")
          .get()
      );
    });

    test("No participante NO puede leer mensajes", async () => {
      const eve = testEnv.authenticatedContext("eve");
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context.firestore().collection("chats").doc("chat1").set({
          participants: ["alice", "bob"],
          createdAt: new Date(),
        });

        await context
          .firestore()
          .collection("chats")
          .doc("chat1")
          .collection("messages")
          .doc("msg1")
          .set({
            senderId: "bob",
            text: "Secret message",
            timestamp: new Date(),
          });
      });

      await assertFails(
        eve
          .firestore()
          .collection("chats")
          .doc("chat1")
          .collection("messages")
          .doc("msg1")
          .get()
      );
    });

    test("Mensaje NO puede exceder 5000 caracteres", async () => {
      const alice = testEnv.authenticatedContext("alice");
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context.firestore().collection("chats").doc("chat1").set({
          participants: ["alice", "bob"],
          createdAt: new Date(),
        });
      });

      const longText = "a".repeat(5001); // 5001 caracteres

      await assertFails(
        alice
          .firestore()
          .collection("chats")
          .doc("chat1")
          .collection("messages")
          .add({
            senderId: "alice",
            text: longText, // ❌ Demasiado largo
            timestamp: new Date(),
          })
      );
    });

    test("Usuario puede crear mensaje válido", async () => {
      const alice = testEnv.authenticatedContext("alice");
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context.firestore().collection("chats").doc("chat1").set({
          participants: ["alice", "bob"],
          createdAt: new Date(),
        });
      });

      await assertSucceeds(
        alice
          .firestore()
          .collection("chats")
          .doc("chat1")
          .collection("messages")
          .add({
            senderId: "alice",
            text: "Hello Bob!", // ✅ Válido
            timestamp: new Date(),
          })
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // TESTS: Colección rate_limits
  // ═══════════════════════════════════════════════════════════════

  describe("rate_limits collection", () => {
    test("Usuario puede leer sus propios rate limits", async () => {
      const alice = testEnv.authenticatedContext("alice");
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context.firestore().collection("rate_limits").doc("alice_generateToken").set({
          userId: "alice",
          action: "generateToken",
          requests: [{timestamp: Date.now()}],
          lastRequest: Date.now(),
        });
      });

      await assertSucceeds(
        alice.firestore().collection("rate_limits").doc("alice_generateToken").get()
      );
    });

    test("Usuario NO puede crear rate limits (solo Cloud Functions)", async () => {
      const alice = testEnv.authenticatedContext("alice");

      await assertFails(
        alice.firestore().collection("rate_limits").doc("alice_generateToken").set({
          userId: "alice",
          action: "generateToken",
          requests: [{timestamp: Date.now()}],
          lastRequest: Date.now(),
        })
      );
    });

    test("Usuario NO puede modificar rate limits", async () => {
      const alice = testEnv.authenticatedContext("alice");
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await context.firestore().collection("rate_limits").doc("alice_generateToken").set({
          userId: "alice",
          action: "generateToken",
          requests: [{timestamp: Date.now()}],
          lastRequest: Date.now(),
        });
      });

      await assertFails(
        alice.firestore().collection("rate_limits").doc("alice_generateToken").update({
          requests: [], // ❌ Intentar borrar historial
        })
      );
    });
  });
});
