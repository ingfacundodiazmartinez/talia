/**
 * Jest setup file for Firebase Cloud Functions testing
 * Configures mocks and test environment
 */

// Mock Firebase Admin SDK
jest.mock('firebase-admin/app', () => ({
  initializeApp: jest.fn(),
  getApps: jest.fn(() => [{ name: 'test-app' }])
}));

jest.mock('firebase-admin/firestore', () => ({
  getFirestore: jest.fn(() => ({
    collection: jest.fn(() => ({
      doc: jest.fn(() => ({
        get: jest.fn(),
        set: jest.fn(),
        update: jest.fn(),
        delete: jest.fn()
      })),
      add: jest.fn(),
      where: jest.fn(() => ({
        limit: jest.fn(() => ({
          get: jest.fn()
        }))
      }))
    })),
    runTransaction: jest.fn()
  })),
  FieldValue: {
    serverTimestamp: jest.fn(() => 'MOCK_TIMESTAMP'),
    increment: jest.fn((value) => `MOCK_INCREMENT_${value}`)
  },
  Timestamp: {
    now: jest.fn(() => ({ seconds: Date.now() / 1000, toDate: () => new Date() })),
    fromDate: jest.fn((date) => ({ seconds: date.getTime() / 1000, toDate: () => date }))
  }
}));

jest.mock('firebase-functions/v2/https', () => ({
  onCall: jest.fn((options, handler) => {
    return { handler, options };
  }),
  HttpsError: class MockHttpsError extends Error {
    constructor(code, message) {
      super(message);
      this.code = code;
    }
  }
}));

jest.mock('firebase-functions/v2/firestore', () => ({
  onDocumentCreated: jest.fn((options, handler) => {
    return { handler, options };
  }),
  onDocumentUpdated: jest.fn((options, handler) => {
    return { handler, options };
  })
}));

// Mock console to reduce noise in tests
global.console = {
  ...console,
  log: jest.fn(),
  error: jest.fn(),
  warn: jest.fn(),
  info: jest.fn()
};

// Set test environment variables
process.env.NODE_ENV = 'test';
process.env.GCLOUD_PROJECT = 'test-project';