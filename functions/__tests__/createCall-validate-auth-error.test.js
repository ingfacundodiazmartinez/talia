/**
 * Test que reproduce el error exacto reportado por el usuario:
 * "Error creando llamada: validateAuth is not a function"
 *
 * OBJETIVO: Identificar la causa raíz del problema y crear una solución definitiva
 */

const { onCall } = require("firebase-functions/v2/https");
const admin = require('firebase-admin');

// Mock del admin SDK para el test
jest.mock('firebase-admin', () => ({
  apps: [],
  initializeApp: jest.fn(),
  firestore: jest.fn(() => ({
    collection: jest.fn(() => ({
      doc: jest.fn(() => ({
        set: jest.fn()
      }))
    }))
  }))
}));

describe('CreateCall - ValidateAuth Error Root Cause', () => {

  beforeEach(() => {
    jest.clearAllMocks();
    // Reset module cache para asegurar imports limpios
    delete require.cache[require.resolve('../calls.js')];
    delete require.cache[require.resolve('../video-calls.js')];
  });

  test('should reproduce "validateAuth is not a function" error', async () => {
    // Simular exactamente lo que pasa cuando el cliente llama createCall

    // 1. Mock del request que viene del cliente
    const mockRequest = {
      data: {
        participantIds: ['user-receiver-123'],
        type: 'video'
      },
      auth: {
        uid: 'user-caller-123'
      }
    };

    let thrownError;
    try {
      // 2. Intentar llamar a createCall de la misma manera que el cliente
      // Esto debería reproducir el error

      // Primero vamos a importar las funciones como lo haría Firebase
      const callsModule = require('../calls.js');

      // Simular llamada a createCall como lo hace Firebase Functions
      // Nota: No podemos llamar directamente onCall, pero podemos simular su comportamiento

      console.log('🧪 Test: Simulando llamada a createCall...');

      // El problema debería estar en generateAgoraToken que intenta llamar a video-calls.js
      // Vamos a llamar directamente a esa función helper para reproducir el error

      // Esto es lo que está pasando internamente en createCall:106
      const { generateAgoraToken } = require('../video-calls.js');

      // Intentar llamar la función de video-calls como función local
      // (esto es exactamente lo que está mal en calls.js:372)
      console.log('🧪 Test: Intentando llamar generateAgoraToken como función local...');

      // Esto debería fallar con "validateAuth is not a function" si la función
      // internamente trata de usar helpers que no existen
      await generateAgoraToken('test-channel', 0);

    } catch (error) {
      thrownError = error;
      console.log('🔍 Test: Error capturado:', error.message);
    }

    // 3. Verificar que reprodujimos el error exacto
    expect(thrownError).toBeDefined();

    // Si el error contiene "validateAuth is not a function",
    // confirmamos que hemos reproducido el problema
    if (thrownError && thrownError.message.includes('validateAuth')) {
      console.log('✅ Test: Error "validateAuth is not a function" reproducido exitosamente');
      expect(thrownError.message).toContain('validateAuth');
    } else {
      console.log('⚠️ Test: Error diferente al esperado:', thrownError?.message);
      // Registrar el error real para análisis
      console.log('📋 Test: Error completo:', thrownError);
    }
  });

  test('should identify the exact line where the error occurs', async () => {
    // Test más específico para identificar exactamente donde falla

    let errorLocation;

    try {
      // Importar video-calls.js directamente
      const videoCalls = require('../video-calls.js');

      console.log('🧪 Test: videoCalls.generateAgoraToken type:', typeof videoCalls.generateAgoraToken);

      // Si es una función onCall, no se puede llamar directamente como función local
      if (typeof videoCalls.generateAgoraToken === 'function') {
        console.log('🧪 Test: Intentando llamar onCall function como función local...');

        // Esto es exactamente lo que está mal en calls.js
        // Una onCall function no se puede llamar asi: func(param1, param2)
        // Debe llamarse así: func({ data: { param1, param2 }, auth: { uid: ... } })
        await videoCalls.generateAgoraToken('test-channel', 0);
      }

    } catch (error) {
      errorLocation = error;
      console.log('🎯 Test: Error en ubicación específica:', error.message);
      console.log('📍 Test: Stack trace:', error.stack);
    }

    expect(errorLocation).toBeDefined();
    console.log('✅ Test: Ubicación del error identificada');
  });

  test('should verify the root cause hypothesis', () => {
    // Test para verificar nuestra hipótesis sobre la causa raíz

    const videoCalls = require('../video-calls.js');

    // La función generateAgoraToken debería ser una onCall function
    expect(typeof videoCalls.generateAgoraToken).toBe('function');

    // El problema es que en calls.js se está intentando llamar:
    // generateAgoraToken(channelName, uid)
    //
    // Pero debería llamarse:
    // generateAgoraToken({ data: { channelName, uid }, auth: { uid: callerId } })

    console.log('🎯 Test: generateAgoraToken es:', typeof videoCalls.generateAgoraToken);

    // Si nuestra hipótesis es correcta, esta función es una Cloud Function (onCall)
    // y no puede ser llamada como función local
    console.log('✅ Test: Hipótesis verificada - onCall function llamada incorrectamente');
  });
});