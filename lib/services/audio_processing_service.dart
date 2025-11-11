import 'dart:io';
import 'package:audio_waveforms/audio_waveforms.dart';

/// Servicio para procesar audio y extraer waveform antes de subir
class AudioProcessingService {
  /// Extrae el waveform de un archivo de audio
  ///
  /// Returns una lista de valores normalizados entre 0 y 1
  Future<List<double>> extractWaveform(File audioFile) async {
    try {

      // Crear controller para extraer waveform
      final controller = PlayerController();

      try {
        // Extraer waveform con 35 muestras
        final waveData = await controller.extractWaveformData(
          path: audioFile.path,
          noOfSamples: 35, // 35 barras para buena visualización
        );


        if (waveData.isEmpty) {
          return _generateDefaultWaveform();
        }

        // Convertir a valores absolutos y asegurar que sean double
        final absValues = waveData.map((v) => v.abs().toDouble()).toList();

        // Encontrar min y max para normalización
        final maxVal = absValues.reduce((a, b) => a > b ? a : b);
        final minVal = absValues.reduce((a, b) => a < b ? a : b);
        final range = (maxVal - minVal).toDouble();

        if (range == 0) {
          return _generateDefaultWaveform();
        }

        // Normalizar entre 0 y 1 usando min-max
        final normalized = absValues.map((v) {
          return ((v - minVal) / range).clamp(0.0, 1.0);
        }).toList();

        // Amplificar diferencias con curva exponencial
        final amplified = normalized.map((v) {
          // Usar curva cúbica para más contraste
          final powered = v * v * v;
          // Garantizar mínimo visible (20%) y máximo
          return (powered * 0.8 + 0.2).clamp(0.2, 1.0);
        }).toList();

        return amplified;
      } finally {
        // Siempre limpiar el controller
        controller.dispose();
      }
    } catch (e) {
      // En caso de error, retornar waveform por defecto
      return _generateDefaultWaveform();
    }
  }

  /// Genera un waveform por defecto con valores aleatorios
  List<double> _generateDefaultWaveform() {
    return List.generate(35, (index) => 0.3 + (index % 3) * 0.2);
  }

  /// Obtiene la duración de un archivo de audio
  Future<Duration?> getAudioDuration(File audioFile) async {
    try {
      final controller = PlayerController();

      try {
        await controller.preparePlayer(
          path: audioFile.path,
          shouldExtractWaveform: false, // No necesitamos waveform aquí
        );

        final durationMs = controller.maxDuration;
        if (durationMs > 0) {
          return Duration(milliseconds: durationMs);
        }
        return null;
      } finally {
        controller.dispose();
      }
    } catch (e) {
      return null;
    }
  }
}
