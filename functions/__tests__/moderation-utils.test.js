/**
 * ═══════════════════════════════════════════════════════════════
 * MODERATION UTILS - Tests Unitarios
 * ═══════════════════════════════════════════════════════════════
 *
 * Tests para validar la función shouldBlockByModerationLevel
 * que centraliza la lógica de decisión de bloqueo por moderación.
 */

const { shouldBlockByModerationLevel } = require('../moderation-utils');

describe('Moderation Utils', () => {
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
