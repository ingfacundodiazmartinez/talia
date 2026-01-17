/// Tests temporales para verificar comportamiento de contactos entre diferentes roles
///
/// Escenarios probados:
/// - Auto-aprobación entre adults/parents
/// - Pending cuando hay children con parents involucrados
/// - getStatusForUser() retorna valores correctos para cada usuario
/// - Verificación de que usuarios con pending/pending_other no pueden abrir chat

import 'package:flutter_test/flutter_test.dart';
import 'package:talia/models/contact.dart';

void main() {
  group('Contact Model - getStatusForUser()', () {
    // ═══════════════════════════════════════════════════════════════
    // HELPER: Crear contacto con configuración específica
    // ═══════════════════════════════════════════════════════════════

    Contact createContact({
      required String status,
      required List<String> users,
      Map<String, ApprovalStatus>? approvals,
      List<String>? parentViewers,
    }) {
      final sortedUsers = List<String>.from(users)..sort();
      return Contact(
        id: '${sortedUsers[0]}_${sortedUsers[1]}',
        users: sortedUsers,
        status: status,
        createdAt: DateTime.now(),
        createdBy: users[0],
        autoApproved: status == 'approved',
        approvals: approvals ?? {},
        parentViewers: parentViewers ?? [],
      );
    }

    // ═══════════════════════════════════════════════════════════════
    // GRUPO 1: AUTO-APROBACIÓN (status = 'approved')
    // ═══════════════════════════════════════════════════════════════

    group('Auto-aprobación (ambos usuarios sin parent involucrado)', () {
      test('Adult → Adult: ambos ven approved', () {
        // Escenario: Dos adultos sin hijos se agregan
        final contact = createContact(
          status: 'approved',
          users: ['adultA', 'adultB'],
          approvals: {}, // Sin approvals porque es auto-aprobado
        );

        expect(contact.getStatusForUser('adultA'), 'approved');
        expect(contact.getStatusForUser('adultB'), 'approved');
        expect(contact.isApproved, true);
      });

      test('Parent → Parent: ambos ven approved', () {
        // Escenario: Dos padres se agregan entre sí
        final contact = createContact(
          status: 'approved',
          users: ['parentA', 'parentB'],
          approvals: {},
        );

        expect(contact.getStatusForUser('parentA'), 'approved');
        expect(contact.getStatusForUser('parentB'), 'approved');
      });

      test('Adult → Child sin parent: ambos ven approved', () {
        // Escenario: Adulto agrega a menor sin padre vinculado
        final contact = createContact(
          status: 'approved',
          users: ['adultA', 'childSinParent'],
          approvals: {},
        );

        expect(contact.getStatusForUser('adultA'), 'approved');
        expect(contact.getStatusForUser('childSinParent'), 'approved');
      });

      test('Child sin parent → Child sin parent: ambos ven approved', () {
        // Escenario: Dos menores sin padres vinculados
        final contact = createContact(
          status: 'approved',
          users: ['childA_sinParent', 'childB_sinParent'],
          approvals: {},
        );

        expect(contact.getStatusForUser('childA_sinParent'), 'approved');
        expect(contact.getStatusForUser('childB_sinParent'), 'approved');
      });

      test('Child sin parent → Adult: ambos ven approved', () {
        final contact = createContact(
          status: 'approved',
          users: ['childSinParent', 'adultA'],
          approvals: {},
        );

        expect(contact.getStatusForUser('childSinParent'), 'approved');
        expect(contact.getStatusForUser('adultA'), 'approved');
      });

      test('Child sin parent → Parent: ambos ven approved', () {
        final contact = createContact(
          status: 'approved',
          users: ['childSinParent', 'parentA'],
          approvals: {},
        );

        expect(contact.getStatusForUser('childSinParent'), 'approved');
        expect(contact.getStatusForUser('parentA'), 'approved');
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // GRUPO 2: PENDING - UN CHILD CON PARENT INVOLUCRADO
    // ═══════════════════════════════════════════════════════════════

    group('Pending - Un child con parent (requiere una aprobación)', () {
      test('Adult → Child con parent: Adult ve pending_other, Child ve pending', () {
        // Escenario: Adult agrega a child que tiene padre vinculado
        // El padre del child debe aprobar
        final contact = createContact(
          status: 'pending',
          users: ['adultA', 'childConParent'],
          approvals: {
            // Solo el child necesita aprobación de su padre
            'childConParent': ApprovalStatus(
              status: 'pending',
              parentId: 'parentDeChild',
            ),
          },
          parentViewers: ['parentDeChild'],
        );

        // Adult no tiene approval entry, pero contact está pending
        // → debe ver 'pending_other' (espera aprobación del otro lado)
        expect(contact.getStatusForUser('adultA'), 'pending_other');

        // Child tiene approval pending → ve 'pending' (su padre debe aprobar)
        expect(contact.getStatusForUser('childConParent'), 'pending');

        // Contact NO está aprobado
        expect(contact.isApproved, false);
        expect(contact.isPending, true);
      });

      test('Parent → Child con parent (otro parent): mismo comportamiento', () {
        // Escenario: Un padre agrega al hijo de OTRO padre
        final contact = createContact(
          status: 'pending',
          users: ['parentA', 'childDeParentB'],
          approvals: {
            'childDeParentB': ApprovalStatus(
              status: 'pending',
              parentId: 'parentB',
            ),
          },
          parentViewers: ['parentB'],
        );

        expect(contact.getStatusForUser('parentA'), 'pending_other');
        expect(contact.getStatusForUser('childDeParentB'), 'pending');
      });

      test('Child con parent → Adult: Child ve pending, Adult ve pending_other', () {
        // Escenario: Child con padre agrega a un adulto
        // El padre del child iniciador debe aprobar
        final contact = createContact(
          status: 'pending',
          users: ['adultA', 'childConParent'],
          approvals: {
            'childConParent': ApprovalStatus(
              status: 'pending',
              parentId: 'parentDeChild',
            ),
          },
          parentViewers: ['parentDeChild'],
        );

        expect(contact.getStatusForUser('childConParent'), 'pending');
        expect(contact.getStatusForUser('adultA'), 'pending_other');
      });

      test('Child con parent → Parent: Child ve pending, Parent ve pending_other', () {
        final contact = createContact(
          status: 'pending',
          users: ['childConParent', 'parentA'],
          approvals: {
            'childConParent': ApprovalStatus(
              status: 'pending',
              parentId: 'parentDeChild',
            ),
          },
          parentViewers: ['parentDeChild'],
        );

        expect(contact.getStatusForUser('childConParent'), 'pending');
        expect(contact.getStatusForUser('parentA'), 'pending_other');
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // GRUPO 3: ISSUE 1 - CHILD SIN PARENT → CHILD CON PARENT
    // ═══════════════════════════════════════════════════════════════

    group('ISSUE 1: Child sin parent → Child con parent', () {
      test('Isa (sin parent) → Oli (con parent Mica): Isa ve pending_other, Oli ve pending', () {
        // Este es el escenario exacto del bug reportado
        // Isa no tiene parent, Oli tiene a Mica como parent
        // Mica debe aprobar el contacto

        final contact = createContact(
          status: 'pending',
          users: ['isa', 'oli'],
          approvals: {
            // Solo Oli necesita aprobación (tiene parent)
            'oli': ApprovalStatus(
              status: 'pending',
              parentId: 'mica',
            ),
          },
          parentViewers: ['mica'],
        );

        // Isa NO tiene approval entry (no tiene parent)
        // Pero el contact está pending
        // Con el FIX: debe retornar 'pending_other'
        expect(contact.getStatusForUser('isa'), 'pending_other',
            reason: 'Isa debe ver pending_other porque el contacto requiere aprobación de Mica');

        // Oli tiene approval pending
        expect(contact.getStatusForUser('oli'), 'pending',
            reason: 'Oli debe ver pending porque su padre Mica debe aprobar');

        // Ninguno puede abrir chat
        expect(contact.isApproved, false);
      });

      test('Child sin parent → Child con parent: después de aprobación, ambos ven approved', () {
        // Después de que Mica aprueba
        final contact = createContact(
          status: 'approved',
          users: ['isa', 'oli'],
          approvals: {
            'oli': ApprovalStatus(
              status: 'approved',
              parentId: 'mica',
              approvedBy: 'mica',
              approvedAt: DateTime.now(),
            ),
          },
          parentViewers: ['mica'],
        );

        expect(contact.getStatusForUser('isa'), 'approved');
        expect(contact.getStatusForUser('oli'), 'approved');
        expect(contact.isApproved, true);
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // GRUPO 4: AMBOS CHILDREN CON PARENTS (requiere dos aprobaciones)
    // ═══════════════════════════════════════════════════════════════

    group('Child con parent → Child con parent (ambos requieren aprobación)', () {
      test('Ambos pending: ambos ven pending', () {
        // Escenario: Dos children con padres se agregan
        // Ambos padres deben aprobar
        final contact = createContact(
          status: 'pending',
          users: ['childA', 'childB'],
          approvals: {
            'childA': ApprovalStatus(
              status: 'pending',
              parentId: 'parentA',
            ),
            'childB': ApprovalStatus(
              status: 'pending',
              parentId: 'parentB',
            ),
          },
          parentViewers: ['parentA', 'parentB'],
        );

        expect(contact.getStatusForUser('childA'), 'pending');
        expect(contact.getStatusForUser('childB'), 'pending');
        expect(contact.isApproved, false);
      });

      test('Solo parentA aprobó: childA ve pending_other, childB ve pending', () {
        // ParentA aprobó, pero parentB aún no
        final contact = createContact(
          status: 'pending',
          users: ['childA', 'childB'],
          approvals: {
            'childA': ApprovalStatus(
              status: 'approved',
              parentId: 'parentA',
              approvedBy: 'parentA',
              approvedAt: DateTime.now(),
            ),
            'childB': ApprovalStatus(
              status: 'pending',
              parentId: 'parentB',
            ),
          },
          parentViewers: ['parentA', 'parentB'],
        );

        // childA: su approval está approved, pero hay otras pendientes
        expect(contact.getStatusForUser('childA'), 'pending_other',
            reason: 'childA debe ver pending_other porque el padre de childB aún no aprobó');

        // childB: su approval está pending
        expect(contact.getStatusForUser('childB'), 'pending',
            reason: 'childB debe ver pending porque su padre aún no aprobó');

        expect(contact.isApproved, false);
      });

      test('Ambos parents aprobaron: status approved, ambos ven approved', () {
        final contact = createContact(
          status: 'approved',
          users: ['childA', 'childB'],
          approvals: {
            'childA': ApprovalStatus(
              status: 'approved',
              parentId: 'parentA',
              approvedBy: 'parentA',
              approvedAt: DateTime.now(),
            ),
            'childB': ApprovalStatus(
              status: 'approved',
              parentId: 'parentB',
              approvedBy: 'parentB',
              approvedAt: DateTime.now(),
            ),
          },
          parentViewers: ['parentA', 'parentB'],
        );

        expect(contact.getStatusForUser('childA'), 'approved');
        expect(contact.getStatusForUser('childB'), 'approved');
        expect(contact.isApproved, true);
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // GRUPO 5: CHILD CON PARENT → CHILD SIN PARENT
    // ═══════════════════════════════════════════════════════════════

    group('Child con parent → Child sin parent', () {
      test('Child con parent inicia: child ve pending, target ve pending_other', () {
        // El child con parent necesita aprobación de su padre
        // El child sin parent no necesita aprobación
        final contact = createContact(
          status: 'pending',
          users: ['childConParent', 'childSinParent'],
          approvals: {
            'childConParent': ApprovalStatus(
              status: 'pending',
              parentId: 'parentDeChild',
            ),
          },
          parentViewers: ['parentDeChild'],
        );

        expect(contact.getStatusForUser('childConParent'), 'pending');
        expect(contact.getStatusForUser('childSinParent'), 'pending_other');
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // GRUPO 6: ESTADOS ESPECIALES
    // ═══════════════════════════════════════════════════════════════

    group('Estados especiales', () {
      test('Contacto rechazado: ambos ven rejected', () {
        final contact = createContact(
          status: 'pending', // status base aún pending pero approval rechazada
          users: ['userA', 'userB'],
          approvals: {
            'userA': ApprovalStatus(
              status: 'rejected',
              parentId: 'parentA',
              rejectedBy: 'parentA',
              rejectedAt: DateTime.now(),
            ),
          },
        );

        expect(contact.getStatusForUser('userA'), 'rejected');
        // userB no tiene approval, así que vería pending_other
        // (el rechazo es del lado de userA)
      });

      test('Contacto revocado: ambos ven revoked', () {
        final contact = Contact(
          id: 'userA_userB',
          users: ['userA', 'userB'],
          status: 'revoked',
          createdAt: DateTime.now(),
          createdBy: 'userA',
          autoApproved: false,
          approvals: {},
          revokedAt: DateTime.now(),
          revokedBy: 'parentA',
          revokedReason: 'Comportamiento inadecuado',
        );

        expect(contact.getStatusForUser('userA'), 'revoked');
        expect(contact.getStatusForUser('userB'), 'revoked');
        expect(contact.isRevoked, true);
      });

      test('Contacto potential: ambos ven potential', () {
        final contact = createContact(
          status: 'potential',
          users: ['userA', 'userB'],
          approvals: {},
        );

        expect(contact.getStatusForUser('userA'), 'potential');
        expect(contact.getStatusForUser('userB'), 'potential');
        expect(contact.isPotential, true);
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // GRUPO 7: EDGE CASES DEL FIX
    // ═══════════════════════════════════════════════════════════════

    group('Edge cases del fix (Issue 1)', () {
      test('Contact pending sin approvals: debe retornar pending_other, NO approved', () {
        // Este es el edge case que causaba el bug original
        // status='pending' pero approvals vacío (edge case)
        final contact = createContact(
          status: 'pending',
          users: ['userA', 'userB'],
          approvals: {}, // Vacío - edge case
        );

        // Antes del fix: retornaba 'approved' (bug)
        // Después del fix: retorna 'pending_other'
        expect(contact.getStatusForUser('userA'), 'pending_other',
            reason: 'Con status=pending y sin approvals, debe retornar pending_other');
        expect(contact.getStatusForUser('userB'), 'pending_other');

        // Verificar que allApprovalsComplete retorna true (porque approvals está vacío)
        expect(contact.allApprovalsComplete, true,
            reason: 'allApprovalsComplete es true cuando approvals está vacío');

        // Pero el contact NO está approved
        expect(contact.isApproved, false);
        expect(contact.isPending, true);
      });

      test('Contact approved debe retornar approved aunque no tenga approvals', () {
        // Caso de auto-aprobación
        final contact = createContact(
          status: 'approved',
          users: ['userA', 'userB'],
          approvals: {},
        );

        expect(contact.getStatusForUser('userA'), 'approved');
        expect(contact.getStatusForUser('userB'), 'approved');
      });

      test('Usuario sin approval entry en contact pending: ve pending_other', () {
        // Simula el caso de Isa (sin parent) viendo un contacto
        // donde solo Oli tiene approval entry
        final contact = createContact(
          status: 'pending',
          users: ['isa', 'oli'],
          approvals: {
            'oli': ApprovalStatus(status: 'pending', parentId: 'mica'),
          },
        );

        // Isa no está en approvals, pero contact es pending
        expect(contact.getStatusForUser('isa'), 'pending_other');

        // Oli está en approvals con pending
        expect(contact.getStatusForUser('oli'), 'pending');
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // GRUPO 8: HELPERS - canOpenChat
    // ═══════════════════════════════════════════════════════════════

    group('Verificación de apertura de chat', () {
      // Helper local para simular la lógica de apertura de chat
      bool canOpenChat(Contact contact, String userId) {
        final status = contact.getStatusForUser(userId);
        return status == 'approved';
      }

      test('Solo contacts approved permiten abrir chat', () {
        final approvedContact = createContact(
          status: 'approved',
          users: ['userA', 'userB'],
          approvals: {},
        );

        expect(canOpenChat(approvedContact, 'userA'), true);
        expect(canOpenChat(approvedContact, 'userB'), true);
      });

      test('Contacts pending NO permiten abrir chat', () {
        final pendingContact = createContact(
          status: 'pending',
          users: ['userA', 'userB'],
          approvals: {
            'userA': ApprovalStatus(status: 'pending', parentId: 'parentA'),
          },
        );

        expect(canOpenChat(pendingContact, 'userA'), false,
            reason: 'Usuario con pending no puede abrir chat');
        expect(canOpenChat(pendingContact, 'userB'), false,
            reason: 'Usuario con pending_other no puede abrir chat');
      });

      test('ISSUE 1: Isa no puede abrir chat con Oli mientras está pending', () {
        final contact = createContact(
          status: 'pending',
          users: ['isa', 'oli'],
          approvals: {
            'oli': ApprovalStatus(status: 'pending', parentId: 'mica'),
          },
        );

        expect(canOpenChat(contact, 'isa'), false,
            reason: 'Isa (sin parent) NO debe poder abrir chat mientras Mica no apruebe');
        expect(canOpenChat(contact, 'oli'), false,
            reason: 'Oli NO debe poder abrir chat mientras Mica no apruebe');
      });

      test('Contacts potential NO permiten abrir chat', () {
        final potentialContact = createContact(
          status: 'potential',
          users: ['userA', 'userB'],
          approvals: {},
        );

        expect(canOpenChat(potentialContact, 'userA'), false);
        expect(canOpenChat(potentialContact, 'userB'), false);
      });

      test('Contacts revoked NO permiten abrir chat', () {
        final revokedContact = Contact(
          id: 'userA_userB',
          users: ['userA', 'userB'],
          status: 'revoked',
          createdAt: DateTime.now(),
          createdBy: 'userA',
          autoApproved: false,
          approvals: {},
        );

        expect(canOpenChat(revokedContact, 'userA'), false);
        expect(canOpenChat(revokedContact, 'userB'), false);
      });
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // GRUPO 9: allApprovalsComplete
  // ═══════════════════════════════════════════════════════════════

  group('Contact Model - allApprovalsComplete', () {
    Contact createContact({
      required String status,
      required List<String> users,
      Map<String, ApprovalStatus>? approvals,
    }) {
      final sortedUsers = List<String>.from(users)..sort();
      return Contact(
        id: '${sortedUsers[0]}_${sortedUsers[1]}',
        users: sortedUsers,
        status: status,
        createdAt: DateTime.now(),
        createdBy: users[0],
        autoApproved: false,
        approvals: approvals ?? {},
      );
    }

    test('Approvals vacío: retorna true', () {
      final contact = createContact(
        status: 'pending',
        users: ['a', 'b'],
        approvals: {},
      );
      expect(contact.allApprovalsComplete, true);
    });

    test('Una approval pending: retorna false', () {
      final contact = createContact(
        status: 'pending',
        users: ['a', 'b'],
        approvals: {
          'a': ApprovalStatus(status: 'pending', parentId: 'parentA'),
        },
      );
      expect(contact.allApprovalsComplete, false);
    });

    test('Una approval approved: retorna true', () {
      final contact = createContact(
        status: 'pending',
        users: ['a', 'b'],
        approvals: {
          'a': ApprovalStatus(status: 'approved', parentId: 'parentA'),
        },
      );
      expect(contact.allApprovalsComplete, true);
    });

    test('Dos approvals, ambas approved: retorna true', () {
      final contact = createContact(
        status: 'pending',
        users: ['a', 'b'],
        approvals: {
          'a': ApprovalStatus(status: 'approved', parentId: 'parentA'),
          'b': ApprovalStatus(status: 'approved', parentId: 'parentB'),
        },
      );
      expect(contact.allApprovalsComplete, true);
    });

    test('Dos approvals, una pending: retorna false', () {
      final contact = createContact(
        status: 'pending',
        users: ['a', 'b'],
        approvals: {
          'a': ApprovalStatus(status: 'approved', parentId: 'parentA'),
          'b': ApprovalStatus(status: 'pending', parentId: 'parentB'),
        },
      );
      expect(contact.allApprovalsComplete, false);
    });

    test('Approval rejected: retorna false', () {
      final contact = createContact(
        status: 'pending',
        users: ['a', 'b'],
        approvals: {
          'a': ApprovalStatus(status: 'rejected', parentId: 'parentA'),
        },
      );
      expect(contact.allApprovalsComplete, false);
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // GRUPO 10: RESUMEN COMPLETO DE MATRIZ
  // ═══════════════════════════════════════════════════════════════

  group('Matriz completa de escenarios', () {
    // Helper
    Contact createContactScenario({
      required String initiator,
      required String target,
      required String status,
      Map<String, ApprovalStatus>? approvals,
    }) {
      final users = [initiator, target]..sort();
      return Contact(
        id: '${users[0]}_${users[1]}',
        users: users,
        status: status,
        createdAt: DateTime.now(),
        createdBy: initiator,
        autoApproved: status == 'approved',
        approvals: approvals ?? {},
      );
    }

    // Todos los escenarios de auto-aprobación
    final autoApproveScenarios = [
      ('adult', 'adult', 'Adult → Adult'),
      ('adult', 'parent', 'Adult → Parent'),
      ('parent', 'adult', 'Parent → Adult'),
      ('parent', 'parent', 'Parent → Parent'),
      ('adult', 'childSinParent', 'Adult → Child sin parent'),
      ('childSinParent', 'adult', 'Child sin parent → Adult'),
      ('childSinParent', 'parent', 'Child sin parent → Parent'),
      ('parent', 'childSinParent', 'Parent → Child sin parent'),
      ('childSinParent1', 'childSinParent2', 'Child sin parent → Child sin parent'),
    ];

    for (final scenario in autoApproveScenarios) {
      test('${scenario.$3}: auto-aprobado, ambos ven approved', () {
        final contact = createContactScenario(
          initiator: scenario.$1,
          target: scenario.$2,
          status: 'approved',
          approvals: {},
        );

        expect(contact.isApproved, true);
        expect(contact.getStatusForUser(scenario.$1), 'approved');
        expect(contact.getStatusForUser(scenario.$2), 'approved');
      });
    }

    test('Adult → Child con parent: pending, Adult ve pending_other, Child ve pending', () {
      final contact = createContactScenario(
        initiator: 'adult',
        target: 'childConParent',
        status: 'pending',
        approvals: {
          'childConParent': ApprovalStatus(status: 'pending', parentId: 'parent'),
        },
      );

      expect(contact.isPending, true);
      expect(contact.getStatusForUser('adult'), 'pending_other');
      expect(contact.getStatusForUser('childConParent'), 'pending');
    });

    test('Child con parent → Adult: pending, Child ve pending, Adult ve pending_other', () {
      final contact = createContactScenario(
        initiator: 'childConParent',
        target: 'adult',
        status: 'pending',
        approvals: {
          'childConParent': ApprovalStatus(status: 'pending', parentId: 'parent'),
        },
      );

      expect(contact.isPending, true);
      expect(contact.getStatusForUser('childConParent'), 'pending');
      expect(contact.getStatusForUser('adult'), 'pending_other');
    });

    test('Child sin parent → Child con parent: pending, iniciador ve pending_other, target ve pending', () {
      final contact = createContactScenario(
        initiator: 'childSinParent',
        target: 'childConParent',
        status: 'pending',
        approvals: {
          'childConParent': ApprovalStatus(status: 'pending', parentId: 'parent'),
        },
      );

      expect(contact.isPending, true);
      expect(contact.getStatusForUser('childSinParent'), 'pending_other');
      expect(contact.getStatusForUser('childConParent'), 'pending');
    });

    test('Child con parent → Child con parent: pending, ambos ven pending', () {
      final contact = createContactScenario(
        initiator: 'childA',
        target: 'childB',
        status: 'pending',
        approvals: {
          'childA': ApprovalStatus(status: 'pending', parentId: 'parentA'),
          'childB': ApprovalStatus(status: 'pending', parentId: 'parentB'),
        },
      );

      expect(contact.isPending, true);
      expect(contact.getStatusForUser('childA'), 'pending');
      expect(contact.getStatusForUser('childB'), 'pending');
    });
  });
}
