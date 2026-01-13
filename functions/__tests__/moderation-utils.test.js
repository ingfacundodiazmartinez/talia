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

  // ═══════════════════════════════════════════════════════════════
  // getMessagePreview - Create preview string for notifications
  // ═══════════════════════════════════════════════════════════════

  describe('getMessagePreview', () => {
    const { getMessagePreview } = require('../moderation-utils');

    test('should return text for text-only messages', () => {
      const messageData = { text: 'Hello world' };
      expect(getMessagePreview(messageData)).toBe('Hello world');
    });

    test('should truncate long text to 100 characters', () => {
      const longText = 'A'.repeat(150);
      const messageData = { text: longText };
      expect(getMessagePreview(messageData)).toBe('A'.repeat(100) + '...');
    });

    test('should return audio emoji for audio messages', () => {
      const messageData = { audioUrl: 'https://example.com/audio.mp3' };
      expect(getMessagePreview(messageData)).toBe('🎤 Audio');
    });

    test('should return image emoji for image messages', () => {
      const messageData = { imageUrl: 'https://example.com/image.png' };
      expect(getMessagePreview(messageData)).toBe('📷 Imagen');
    });

    test('should return video emoji for video messages', () => {
      const messageData = { videoUrl: 'https://example.com/video.mp4' };
      expect(getMessagePreview(messageData)).toBe('🎥 Video');
    });

    test('should prioritize audio over image and video', () => {
      const messageData = {
        text: 'Some text',
        audioUrl: 'https://example.com/audio.mp3',
        imageUrl: 'https://example.com/image.png',
      };
      expect(getMessagePreview(messageData)).toBe('🎤 Audio');
    });

    test('should prioritize image over video', () => {
      const messageData = {
        text: 'Some text',
        imageUrl: 'https://example.com/image.png',
        videoUrl: 'https://example.com/video.mp4',
      };
      expect(getMessagePreview(messageData)).toBe('📷 Imagen');
    });

    test('should return empty string for empty message', () => {
      expect(getMessagePreview({})).toBe('');
    });

    test('should handle null text gracefully', () => {
      const messageData = { text: null };
      expect(getMessagePreview(messageData)).toBe('');
    });
  });

  // ═══════════════════════════════════════════════════════════════
  // getModerationSettings - Get moderation config from chat or contact
  // ═══════════════════════════════════════════════════════════════

  describe('getModerationSettings', () => {
    const { getModerationSettings } = require('../moderation-utils');

    test('should return chat-level moderation when enabled', () => {
      const chatData = {
        moderationEnabled: true,
        moderationLevel: 'medium',
      };
      const contactData = null;
      const receiverId = 'receiver123';

      const result = getModerationSettings(chatData, contactData, receiverId);

      expect(result.enabled).toBe(true);
      expect(result.level).toBe('medium');
      expect(result.type).toBe('parent_chat');
    });

    test('should default to high level when chat moderation has no level', () => {
      const chatData = {
        moderationEnabled: true,
      };
      const contactData = null;
      const receiverId = 'receiver123';

      const result = getModerationSettings(chatData, contactData, receiverId);

      expect(result.enabled).toBe(true);
      expect(result.level).toBe('high');
      expect(result.type).toBe('parent_chat');
    });

    test('should return contact-level moderation when chat moderation disabled', () => {
      const chatData = {
        moderationEnabled: false,
      };
      const contactData = {
        moderationSettings: {
          'receiver123': {
            enabled: true,
            level: 'low',
          },
        },
      };
      const receiverId = 'receiver123';

      const result = getModerationSettings(chatData, contactData, receiverId);

      expect(result.enabled).toBe(true);
      expect(result.level).toBe('low');
      expect(result.type).toBe('user_contact');
    });

    test('should return disabled when both chat and contact moderation off', () => {
      const chatData = {
        moderationEnabled: false,
      };
      const contactData = {
        moderationSettings: {
          'receiver123': {
            enabled: false,
          },
        },
      };
      const receiverId = 'receiver123';

      const result = getModerationSettings(chatData, contactData, receiverId);

      expect(result.enabled).toBe(false);
      expect(result.type).toBe('none');
    });

    test('should return disabled when no contact data', () => {
      const chatData = {};
      const contactData = null;
      const receiverId = 'receiver123';

      const result = getModerationSettings(chatData, contactData, receiverId);

      expect(result.enabled).toBe(false);
      expect(result.type).toBe('none');
    });

    test('should return disabled when contact has no settings for receiver', () => {
      const chatData = {};
      const contactData = {
        moderationSettings: {
          'other_user': {
            enabled: true,
            level: 'high',
          },
        },
      };
      const receiverId = 'receiver123';

      const result = getModerationSettings(chatData, contactData, receiverId);

      expect(result.enabled).toBe(false);
      expect(result.type).toBe('none');
    });
  });
});
