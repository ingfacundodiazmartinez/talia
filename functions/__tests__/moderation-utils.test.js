/**
 * ═══════════════════════════════════════════════════════════════
 * MODERATION UTILS - Tests Unitarios
 * ═══════════════════════════════════════════════════════════════
 *
 * Tests para validar la función shouldBlockByModerationLevel
 * que centraliza la lógica de decisión de bloqueo por moderación.
 */

const { shouldBlockByModerationLevel, getParticipantsInfo } = require('../moderation-utils');

describe('Moderation Utils', () => {

  // ═══════════════════════════════════════════════════════════════
  // getParticipantsInfo - Batch fetch participant data
  // ═══════════════════════════════════════════════════════════════

  describe('getParticipantsInfo', () => {
    let mockDb;

    beforeEach(() => {
      mockDb = {
        collection: jest.fn(() => ({
          doc: jest.fn((id) => ({
            id,
            path: `users/${id}`
          }))
        })),
        getAll: jest.fn()
      };
    });

    test('should return empty arrays when no participants', async () => {
      const result = await getParticipantsInfo(mockDb, []);
      expect(result.ages).toEqual([]);
      expect(result.locations).toEqual([]);
      expect(mockDb.getAll).not.toHaveBeenCalled();
    });

    test('should fetch all participants in single batch call', async () => {
      const mockDocs = [
        {
          exists: true,
          id: 'user1',
          data: () => ({
            birthDate: { toDate: () => new Date('2000-01-01') },
            location: 'Argentina'
          })
        },
        {
          exists: true,
          id: 'user2',
          data: () => ({
            birthDate: { toDate: () => new Date('1990-06-15') },
            country: 'Mexico'
          })
        }
      ];
      mockDb.getAll.mockResolvedValue(mockDocs);

      const result = await getParticipantsInfo(mockDb, ['user1', 'user2']);

      // Should call getAll once with 2 refs
      expect(mockDb.getAll).toHaveBeenCalledTimes(1);
      expect(mockDb.collection).toHaveBeenCalledWith('users');

      // Should have extracted ages and locations
      expect(result.ages.length).toBe(2);
      expect(result.locations).toEqual(['Argentina', 'Mexico']);
    });

    test('should handle non-existent users gracefully', async () => {
      const mockDocs = [
        { exists: false, id: 'user1' },
        {
          exists: true,
          id: 'user2',
          data: () => ({
            birthDate: { toDate: () => new Date('1995-03-20') }
          })
        }
      ];
      mockDb.getAll.mockResolvedValue(mockDocs);

      const result = await getParticipantsInfo(mockDb, ['user1', 'user2']);

      expect(result.ages.length).toBe(1);
      expect(result.locations).toEqual([]);
    });

    test('should handle users without birthDate', async () => {
      const mockDocs = [
        {
          exists: true,
          id: 'user1',
          data: () => ({ location: 'Chile' })
        }
      ];
      mockDb.getAll.mockResolvedValue(mockDocs);

      const result = await getParticipantsInfo(mockDb, ['user1']);

      expect(result.ages).toEqual([]);
      expect(result.locations).toEqual(['Chile']);
    });

    test('should handle birthDate as string', async () => {
      const mockDocs = [
        {
          exists: true,
          id: 'user1',
          data: () => ({
            birthDate: '2000-01-01'
          })
        }
      ];
      mockDb.getAll.mockResolvedValue(mockDocs);

      const result = await getParticipantsInfo(mockDb, ['user1']);

      expect(result.ages.length).toBe(1);
      expect(result.ages[0]).toBeGreaterThan(20);
    });

    test('should handle errors gracefully', async () => {
      mockDb.getAll.mockRejectedValue(new Error('Firestore error'));

      const result = await getParticipantsInfo(mockDb, ['user1', 'user2']);

      expect(result.ages).toEqual([]);
      expect(result.locations).toEqual([]);
    });

    test('should prefer location over country', async () => {
      const mockDocs = [
        {
          exists: true,
          id: 'user1',
          data: () => ({
            location: 'Buenos Aires',
            country: 'Argentina'
          })
        }
      ];
      mockDb.getAll.mockResolvedValue(mockDocs);

      const result = await getParticipantsInfo(mockDb, ['user1']);

      expect(result.locations).toEqual(['Buenos Aires']);
    });
  });
  describe('shouldBlockByModerationLevel', () => {

    // ═══════════════════════════════════════════════════════════════
    // CASOS: Contenido NO inapropiado (nunca debe bloquear)
    // ═══════════════════════════════════════════════════════════════

    describe('When content is NOT inappropriate', () => {
      test('should NOT block with HIGH moderation level', () => {
        const analysis = { isInappropriate: false, severity: 'high' };
        expect(shouldBlockByModerationLevel(analysis, 'high')).toBe(false);
      });

      test('should NOT block with MEDIUM moderation level', () => {
        const analysis = { isInappropriate: false, severity: 'medium' };
        expect(shouldBlockByModerationLevel(analysis, 'medium')).toBe(false);
      });

      test('should NOT block with LOW moderation level', () => {
        const analysis = { isInappropriate: false, severity: 'low' };
        expect(shouldBlockByModerationLevel(analysis, 'low')).toBe(false);
      });

      test('should NOT block with null analysis', () => {
        expect(shouldBlockByModerationLevel(null, 'high')).toBe(false);
      });

      test('should NOT block with undefined analysis', () => {
        expect(shouldBlockByModerationLevel(undefined, 'high')).toBe(false);
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // CASOS: HIGH moderation level (bloquea low, medium, high)
    // ═══════════════════════════════════════════════════════════════

    describe('When moderation level is HIGH', () => {
      test('should block LOW severity inappropriate content', () => {
        const analysis = { isInappropriate: true, severity: 'low' };
        expect(shouldBlockByModerationLevel(analysis, 'high')).toBe(true);
      });

      test('should block MEDIUM severity inappropriate content', () => {
        const analysis = { isInappropriate: true, severity: 'medium' };
        expect(shouldBlockByModerationLevel(analysis, 'high')).toBe(true);
      });

      test('should block HIGH severity inappropriate content', () => {
        const analysis = { isInappropriate: true, severity: 'high' };
        expect(shouldBlockByModerationLevel(analysis, 'high')).toBe(true);
      });

      test('should NOT block NONE severity even if marked inappropriate', () => {
        const analysis = { isInappropriate: true, severity: 'none' };
        expect(shouldBlockByModerationLevel(analysis, 'high')).toBe(false);
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // CASOS: MEDIUM moderation level (bloquea medium, high)
    // ═══════════════════════════════════════════════════════════════

    describe('When moderation level is MEDIUM', () => {
      test('should NOT block LOW severity inappropriate content', () => {
        const analysis = { isInappropriate: true, severity: 'low' };
        expect(shouldBlockByModerationLevel(analysis, 'medium')).toBe(false);
      });

      test('should block MEDIUM severity inappropriate content', () => {
        const analysis = { isInappropriate: true, severity: 'medium' };
        expect(shouldBlockByModerationLevel(analysis, 'medium')).toBe(true);
      });

      test('should block HIGH severity inappropriate content', () => {
        const analysis = { isInappropriate: true, severity: 'high' };
        expect(shouldBlockByModerationLevel(analysis, 'medium')).toBe(true);
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // CASOS: LOW moderation level (solo bloquea high)
    // ═══════════════════════════════════════════════════════════════

    describe('When moderation level is LOW', () => {
      test('should NOT block LOW severity inappropriate content', () => {
        const analysis = { isInappropriate: true, severity: 'low' };
        expect(shouldBlockByModerationLevel(analysis, 'low')).toBe(false);
      });

      test('should NOT block MEDIUM severity inappropriate content', () => {
        const analysis = { isInappropriate: true, severity: 'medium' };
        expect(shouldBlockByModerationLevel(analysis, 'low')).toBe(false);
      });

      test('should block HIGH severity inappropriate content', () => {
        const analysis = { isInappropriate: true, severity: 'high' };
        expect(shouldBlockByModerationLevel(analysis, 'low')).toBe(true);
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // CASOS: Default behavior (sin nivel especificado)
    // ═══════════════════════════════════════════════════════════════

    describe('When moderation level is not specified or invalid', () => {
      test('should default to HIGH behavior with null level', () => {
        const analysis = { isInappropriate: true, severity: 'low' };
        expect(shouldBlockByModerationLevel(analysis, null)).toBe(true);
      });

      test('should default to HIGH behavior with undefined level', () => {
        const analysis = { isInappropriate: true, severity: 'low' };
        expect(shouldBlockByModerationLevel(analysis, undefined)).toBe(true);
      });

      test('should default to HIGH behavior with invalid level', () => {
        const analysis = { isInappropriate: true, severity: 'low' };
        expect(shouldBlockByModerationLevel(analysis, 'invalid')).toBe(true);
      });
    });

    // ═══════════════════════════════════════════════════════════════
    // CASOS: Edge cases
    // ═══════════════════════════════════════════════════════════════

    describe('Edge cases', () => {
      test('should handle missing severity field', () => {
        const analysis = { isInappropriate: true };
        expect(shouldBlockByModerationLevel(analysis, 'high')).toBe(false);
      });

      test('should handle empty analysis object', () => {
        expect(shouldBlockByModerationLevel({}, 'high')).toBe(false);
      });

      test('should be case-sensitive for severity', () => {
        const analysis = { isInappropriate: true, severity: 'HIGH' };
        // Should NOT block because 'HIGH' !== 'high'
        expect(shouldBlockByModerationLevel(analysis, 'high')).toBe(false);
      });
    });
  });
});
