/**
 * Servicio para sincronizar stickers desde Tenor API a Firebase Storage
 *
 * Este script:
 * 1. Descarga stickers desde Tenor API con filtro 'high' (solo contenido G)
 * 2. Los sube a Firebase Storage
 * 3. Actualiza Firestore con la metadata
 * 4. Organiza por categorías aptas para niños
 */

const axios = require('axios');
const admin = require('firebase-admin');

// Categorías de stickers aptas para niños
const STICKER_CATEGORIES = {
  emotions: {
    name: 'Emociones',
    queries: ['happy kid', 'sad kid', 'excited kid', 'surprised kid', 'love kid', 'laugh kid'],
    order: 1,
  },
  animals: {
    name: 'Animales',
    queries: ['cute cat', 'cute dog', 'cute rabbit', 'cute bear', 'cute panda', 'cute penguin'],
    order: 2,
  },
  celebrations: {
    name: 'Celebraciones',
    queries: ['birthday kid', 'party kid', 'celebration kid', 'confetti', 'balloons', 'cake'],
    order: 3,
  },
  activities: {
    name: 'Actividades',
    queries: ['reading kid', 'playing kid', 'sports kid', 'music kid', 'dancing kid', 'art kid'],
    order: 4,
  },
  food: {
    name: 'Comida',
    queries: ['pizza cute', 'ice cream cute', 'fruit cute', 'burger cute', 'donut cute', 'cookie cute'],
    order: 5,
  },
  nature: {
    name: 'Naturaleza',
    queries: ['flower cute', 'rainbow', 'sun cute', 'star cute', 'cloud cute', 'moon cute'],
    order: 6,
  },
  transport: {
    name: 'Transporte',
    queries: ['car cute', 'train cute', 'plane cute', 'rocket cute', 'boat cute', 'bike cute'],
    order: 7,
  },
  greetings: {
    name: 'Saludos',
    queries: ['hello kid', 'goodbye kid', 'hi five kid', 'wave kid', 'thank you kid', 'good morning kid'],
    order: 8,
  },
};

class StickerSyncService {
  constructor(tenorApiKey) {
    this.tenorApiKey = tenorApiKey;
    this.baseUrl = 'https://tenor.googleapis.com/v2';
    this.db = admin.firestore();
    this.storage = admin.storage();
  }

  /**
   * Buscar stickers en Tenor API con filtro de contenido alto (G-rated)
   */
  async searchStickers(query, limit = 20) {
    try {
      const url = `${this.baseUrl}/search`;
      const params = {
        q: query,
        key: this.tenorApiKey,
        contentfilter: 'high', // Solo contenido G (apto para todos)
        media_filter: 'png_transparent,gif', // Formatos con transparencia
        limit: limit,
        locale: 'es_ES', // Español
      };

      console.log(`🔍 Buscando stickers: "${query}" con filtro 'high'`);
      const response = await axios.get(url, { params });

      if (response.data && response.data.results) {
        console.log(`✅ Encontrados ${response.data.results.length} stickers para "${query}"`);
        return response.data.results;
      }

      return [];
    } catch (error) {
      console.error(`❌ Error buscando stickers para "${query}":`, error.message);
      return [];
    }
  }

  /**
   * Descargar imagen de sticker desde URL
   */
  async downloadSticker(url) {
    try {
      const response = await axios.get(url, {
        responseType: 'arraybuffer',
        timeout: 30000, // 30 segundos
      });
      return Buffer.from(response.data);
    } catch (error) {
      console.error(`❌ Error descargando sticker de ${url}:`, error.message);
      throw error;
    }
  }

  /**
   * Subir sticker a Firebase Storage
   */
  async uploadToStorage(buffer, filename, contentType) {
    try {
      const bucket = this.storage.bucket();
      const file = bucket.file(`stickers/${filename}`);

      await file.save(buffer, {
        metadata: {
          contentType: contentType,
          cacheControl: 'public, max-age=31536000', // Cache por 1 año
        },
      });

      // Hacer el archivo público
      await file.makePublic();

      // Obtener URL pública
      const publicUrl = `https://storage.googleapis.com/${bucket.name}/${file.name}`;
      console.log(`✅ Sticker subido: ${filename}`);

      return publicUrl;
    } catch (error) {
      console.error(`❌ Error subiendo sticker ${filename}:`, error.message);
      throw error;
    }
  }

  /**
   * Guardar metadata del sticker en Firestore
   */
  async saveStickerMetadata(stickerData) {
    try {
      const stickerRef = this.db.collection('stickers').doc();
      await stickerRef.set({
        ...stickerData,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        active: true, // Por defecto activo
      });
      console.log(`✅ Metadata guardada para sticker: ${stickerData.id}`);
      return stickerRef.id;
    } catch (error) {
      console.error(`❌ Error guardando metadata:`, error.message);
      throw error;
    }
  }

  /**
   * Verificar si un sticker ya existe en Firestore
   */
  async stickerExists(tenorId) {
    try {
      const snapshot = await this.db
        .collection('stickers')
        .where('tenorId', '==', tenorId)
        .limit(1)
        .get();
      return !snapshot.empty;
    } catch (error) {
      console.error(`❌ Error verificando sticker existente:`, error.message);
      return false;
    }
  }

  /**
   * Procesar un sticker: descargar, subir y guardar metadata
   */
  async processSticker(result, categoryKey, query) {
    try {
      const tenorId = result.id;

      // Verificar si ya existe
      const exists = await this.stickerExists(tenorId);
      if (exists) {
        console.log(`⏭️  Sticker ${tenorId} ya existe, saltando...`);
        return null;
      }

      // Obtener la mejor versión del sticker (GIF o PNG transparente)
      let mediaUrl, contentType, extension;

      if (result.media_formats?.gif_transparent) {
        mediaUrl = result.media_formats.gif_transparent.url;
        contentType = 'image/gif';
        extension = 'gif';
      } else if (result.media_formats?.png_transparent) {
        mediaUrl = result.media_formats.png_transparent.url;
        contentType = 'image/png';
        extension = 'png';
      } else if (result.media_formats?.gif) {
        mediaUrl = result.media_formats.gif.url;
        contentType = 'image/gif';
        extension = 'gif';
      } else {
        console.log(`⚠️  No hay formato adecuado para sticker ${tenorId}`);
        return null;
      }

      // Descargar sticker
      console.log(`⬇️  Descargando sticker ${tenorId}...`);
      const buffer = await this.downloadSticker(mediaUrl);

      // Generar nombre de archivo único
      const filename = `${categoryKey}_${tenorId}_${Date.now()}.${extension}`;

      // Subir a Storage
      const publicUrl = await this.uploadToStorage(buffer, filename, contentType);

      // Preparar metadata
      const stickerData = {
        id: tenorId,
        tenorId: tenorId,
        url: publicUrl,
        category: categoryKey,
        categoryName: STICKER_CATEGORIES[categoryKey].name,
        searchQuery: query,
        contentRating: 'G', // Tenor API con filtro 'high' = G rating
        tags: result.tags || [],
        order: STICKER_CATEGORIES[categoryKey].order * 1000 + Math.floor(Math.random() * 1000),
        contentType: contentType,
        source: 'tenor',
      };

      // Guardar en Firestore
      await this.saveStickerMetadata(stickerData);

      console.log(`✅ Sticker procesado exitosamente: ${tenorId}`);
      return stickerData;
    } catch (error) {
      console.error(`❌ Error procesando sticker ${result.id}:`, error.message);
      return null;
    }
  }

  /**
   * Sincronizar stickers para una categoría
   */
  async syncCategory(categoryKey, limit = 10) {
    const category = STICKER_CATEGORIES[categoryKey];
    if (!category) {
      console.error(`❌ Categoría no encontrada: ${categoryKey}`);
      return { success: 0, failed: 0, skipped: 0 };
    }

    console.log(`\n📦 Sincronizando categoría: ${category.name}`);
    console.log(`   Queries: ${category.queries.join(', ')}`);

    let totalSuccess = 0;
    let totalFailed = 0;
    let totalSkipped = 0;

    // Procesar cada query de la categoría
    for (const query of category.queries) {
      console.log(`\n🔍 Procesando query: "${query}"`);

      // Buscar stickers
      const results = await this.searchStickers(query, limit);

      // Procesar cada resultado
      for (const result of results) {
        const processed = await this.processSticker(result, categoryKey, query);

        if (processed === null && await this.stickerExists(result.id)) {
          totalSkipped++;
        } else if (processed) {
          totalSuccess++;
        } else {
          totalFailed++;
        }

        // Delay para no saturar la API
        await new Promise(resolve => setTimeout(resolve, 500));
      }
    }

    console.log(`\n✅ Categoría ${category.name} completada:`);
    console.log(`   ✓ Exitosos: ${totalSuccess}`);
    console.log(`   ⏭️  Saltados: ${totalSkipped}`);
    console.log(`   ✗ Fallidos: ${totalFailed}`);

    return {
      success: totalSuccess,
      failed: totalFailed,
      skipped: totalSkipped,
    };
  }

  /**
   * Sincronizar todas las categorías
   */
  async syncAllCategories(limitPerQuery = 10) {
    console.log('\n🚀 Iniciando sincronización de stickers desde Tenor API');
    console.log(`   Filtro de contenido: HIGH (solo G-rated)`);
    console.log(`   Límite por query: ${limitPerQuery}`);
    console.log(`   Total categorías: ${Object.keys(STICKER_CATEGORIES).length}`);

    const startTime = Date.now();
    const results = {
      totalSuccess: 0,
      totalFailed: 0,
      totalSkipped: 0,
      categories: {},
    };

    // Sincronizar cada categoría
    for (const [key, category] of Object.entries(STICKER_CATEGORIES)) {
      const categoryResult = await this.syncCategory(key, limitPerQuery);
      results.categories[key] = categoryResult;
      results.totalSuccess += categoryResult.success;
      results.totalFailed += categoryResult.failed;
      results.totalSkipped += categoryResult.skipped;
    }

    const duration = ((Date.now() - startTime) / 1000 / 60).toFixed(2);

    console.log('\n🎉 Sincronización completada!');
    console.log(`   ⏱️  Duración: ${duration} minutos`);
    console.log(`   ✅ Total exitosos: ${results.totalSuccess}`);
    console.log(`   ⏭️  Total saltados: ${results.totalSkipped}`);
    console.log(`   ❌ Total fallidos: ${results.totalFailed}`);

    return results;
  }

  /**
   * Limpiar stickers inactivos antiguos (opcional)
   */
  async cleanupOldStickers(daysOld = 90) {
    console.log(`\n🧹 Limpiando stickers inactivos de más de ${daysOld} días...`);

    const cutoffDate = new Date();
    cutoffDate.setDate(cutoffDate.getDate() - daysOld);

    try {
      const snapshot = await this.db
        .collection('stickers')
        .where('active', '==', false)
        .where('updatedAt', '<', cutoffDate)
        .get();

      let deleted = 0;

      for (const doc of snapshot.docs) {
        const data = doc.data();

        // Eliminar archivo de Storage
        if (data.url) {
          try {
            const filename = data.url.split('/').pop();
            const file = this.storage.bucket().file(`stickers/${filename}`);
            await file.delete();
          } catch (error) {
            console.error(`⚠️  Error eliminando archivo: ${error.message}`);
          }
        }

        // Eliminar documento de Firestore
        await doc.ref.delete();
        deleted++;
      }

      console.log(`✅ Limpiados ${deleted} stickers antiguos`);
      return deleted;
    } catch (error) {
      console.error(`❌ Error limpiando stickers:`, error.message);
      return 0;
    }
  }
}

module.exports = StickerSyncService;
