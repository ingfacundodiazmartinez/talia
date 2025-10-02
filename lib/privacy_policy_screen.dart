import 'package:flutter/material.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Política de Privacidad'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: ListView(
        padding: EdgeInsets.all(20),
        children: [
          // Header
          Container(
            padding: EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Color(0xFF9D7FE8).withOpacity(0.1),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(Icons.privacy_tip, size: 48, color: Color(0xFF9D7FE8)),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Tu privacidad es importante',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2D3142),
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Última actualización: Septiembre 2024',
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          SizedBox(height: 24),

          _buildSection(
            title: '1. Información que Recopilamos',
            content: '''
SmartConvo recopila la siguiente información:

• Información de cuenta: nombre, correo electrónico, número de teléfono
• Información de uso: interacciones dentro de la aplicación, preferencias de configuración
• Análisis de mensajes: análisis automático de sentimientos (sin almacenar contenido específico)
• Datos de dispositivo: tipo de dispositivo, sistema operativo, identificadores únicos

No almacenamos el contenido completo de los mensajes de los menores. Solo generamos reportes abstractos basados en análisis de sentimientos.
            ''',
          ),

          _buildSection(
            title: '2. Cómo Usamos tu Información',
            content: '''
Utilizamos la información recopilada para:

• Proporcionar y mejorar nuestros servicios
• Generar reportes de bienestar emocional
• Detectar posibles situaciones de riesgo (bullying, lenguaje inapropiado)
• Enviar notificaciones importantes sobre la actividad de tus hijos
• Mejorar la seguridad y funcionalidad de la aplicación
• Cumplir con obligaciones legales

Nunca vendemos ni compartimos tus datos personales con terceros para fines comerciales.
            ''',
          ),

          _buildSection(
            title: '3. Protección de Datos de Menores',
            content: '''
SmartConvo está diseñado específicamente para proteger la privacidad de los menores:

• Los padres tienen control total sobre los contactos aprobados
• No mostramos contenido específico de conversaciones a los padres
• Los reportes son abstractos y se enfocan en bienestar emocional
• Cumplimos con las leyes de protección de datos infantiles (COPPA, GDPR)
• Los datos de los menores están encriptados y protegidos

Los padres pueden solicitar la eliminación de todos los datos de sus hijos en cualquier momento.
            ''',
          ),

          _buildSection(
            title: '4. Análisis con Inteligencia Artificial',
            content: '''
Nuestra IA realiza:

• Análisis de sentimientos: identifica patrones emocionales sin leer mensajes completos
• Detección de riesgo: busca señales de bullying o contenido inapropiado
• Generación de reportes: crea resúmenes abstractos del estado emocional

Los algoritmos operan de forma automática y no involucran revisión humana. Los datos procesados no se comparten con terceros.
            ''',
          ),

          _buildSection(
            title: '5. Seguridad de la Información',
            content: '''
Implementamos medidas de seguridad robustas:

• Encriptación end-to-end para mensajes
• Almacenamiento seguro en servidores certificados
• Autenticación de dos factores disponible
• Monitoreo continuo de seguridad
• Auditorías regulares de seguridad

En caso de brecha de seguridad, notificaremos a los usuarios afectados inmediatamente.
            ''',
          ),

          _buildSection(
            title: '6. Tus Derechos',
            content: '''
Como usuario, tienes derecho a:

• Acceder a tus datos personales
• Solicitar corrección de información incorrecta
• Eliminar tu cuenta y todos tus datos
• Exportar tus datos en formato legible
• Retirar el consentimiento en cualquier momento
• Presentar una queja ante autoridades de protección de datos

Puedes ejercer estos derechos desde la configuración de tu cuenta o contactando a soporte@smartconvo.com
            ''',
          ),

          _buildSection(
            title: '7. Cookies y Tecnologías Similares',
            content: '''
Utilizamos cookies y tecnologías similares para:

• Mantener tu sesión activa
• Recordar tus preferencias
• Analizar el uso de la aplicación
• Mejorar el rendimiento

Puedes gestionar las preferencias de cookies en la configuración de tu dispositivo.
            ''',
          ),

          _buildSection(
            title: '8. Cambios en la Política',
            content: '''
Podemos actualizar esta política ocasionalmente. Te notificaremos sobre cambios importantes mediante:

• Notificación en la aplicación
• Correo electrónico
• Mensaje en el inicio de sesión

El uso continuado de SmartConvo después de los cambios constituye la aceptación de la nueva política.
            ''',
          ),

          _buildSection(
            title: '9. Contacto',
            content: '''
Para preguntas sobre esta política o el manejo de tus datos:

📧 Email: privacidad@smartconvo.com
📱 Teléfono: +54 9 387 555-1234
📍 Dirección: Av. Ejemplo 123, Salta, Argentina

Nuestro equipo de privacidad responderá en un plazo máximo de 48 horas.
            ''',
          ),

          SizedBox(height: 32),

          // Botones de acción
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    // TODO: Descargar PDF
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Descargando PDF...')),
                    );
                  },
                  icon: Icon(Icons.download),
                  label: Text('Descargar PDF'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Color(0xFF9D7FE8),
                    side: BorderSide(color: Color(0xFF9D7FE8)),
                    padding: EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () {
                    // TODO: Enviar por email
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Enviando por email...')),
                    );
                  },
                  icon: Icon(Icons.email),
                  label: Text('Enviar Email'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Color(0xFF9D7FE8),
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),

          SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildSection({required String title, required String content}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Color(0xFF2D3142),
          ),
        ),
        SizedBox(height: 12),
        Container(
          padding: EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey[50],
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            content.trim(),
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[700],
              height: 1.6,
            ),
          ),
        ),
        SizedBox(height: 24),
      ],
    );
  }
}
