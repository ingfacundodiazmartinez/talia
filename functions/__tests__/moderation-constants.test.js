/**
 * ═══════════════════════════════════════════════════════════════
 * MODERATION CONSTANTS - Tests
 * ═══════════════════════════════════════════════════════════════
 *
 * Verifica que las constantes están exportadas correctamente
 * y tienen valores razonables.
 */

const {
  CONTEXT_CACHE_TTL_MS,
  CONTEXT_CACHE_MAX_SIZE,
  CONTEXT_MESSAGE_LIMIT,
  REPORTED_MESSAGES_LIMIT,
  MESSAGE_TTL_DAYS,
  VALID_MODERATION_LEVELS,
} = require('../moderation-constants');

describe('Moderation Constants', () => {

  describe('Cache constants', () => {
    test('CONTEXT_CACHE_TTL_MS should be 60 seconds', () => {
      expect(CONTEXT_CACHE_TTL_MS).toBe(60000);
    });

    test('CONTEXT_CACHE_MAX_SIZE should be 100', () => {
      expect(CONTEXT_CACHE_MAX_SIZE).toBe(100);
    });
  });

  describe('Limit constants', () => {
    test('CONTEXT_MESSAGE_LIMIT should be 20', () => {
      expect(CONTEXT_MESSAGE_LIMIT).toBe(20);
    });

    test('REPORTED_MESSAGES_LIMIT should be 10', () => {
      expect(REPORTED_MESSAGES_LIMIT).toBe(10);
    });
  });

  describe('TTL constants', () => {
    test('MESSAGE_TTL_DAYS should be 7', () => {
      expect(MESSAGE_TTL_DAYS).toBe(7);
    });
  });

  describe('Moderation levels', () => {
    test('VALID_MODERATION_LEVELS should contain all levels', () => {
      expect(VALID_MODERATION_LEVELS).toContain('none');
      expect(VALID_MODERATION_LEVELS).toContain('low');
      expect(VALID_MODERATION_LEVELS).toContain('medium');
      expect(VALID_MODERATION_LEVELS).toContain('high');
    });

    test('VALID_MODERATION_LEVELS should have exactly 4 levels', () => {
      expect(VALID_MODERATION_LEVELS).toHaveLength(4);
    });

    test('VALID_MODERATION_LEVELS should be ordered by restrictiveness', () => {
      // none is least restrictive, high is most restrictive
      expect(VALID_MODERATION_LEVELS[0]).toBe('none');
      expect(VALID_MODERATION_LEVELS[3]).toBe('high');
    });
  });
});
