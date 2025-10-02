import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class HelpSupportScreen extends StatelessWidget {
  const HelpSupportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Ayuda y Soporte'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: ListView(
        padding: EdgeInsets.all(20),
        children: [
          // Sección de Contacto Rápido
          Container(
            padding: EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF9D7FE8), Color(0xFFB39DDB)],
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                Icon(Icons.headset_mic, size: 48, color: Colors.white),
                SizedBox(height: 16),
                Text(
                  '¿Necesitas ayuda inmediata?',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 8),
                Text(
                  'Nuestro equipo está disponible 24/7',
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withOpacity(0.9),
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildQuickContactButton(
                      icon: Icons.email,
                      label: 'Email',
                      onTap: () => _launchEmail(),
                    ),
                    _buildQuickContactButton(
                      icon: Icons.phone,
                      label: 'Llamar',
                      onTap: () => _launchPhone(),
                    ),
                    _buildQuickContactButton(
                      icon: Icons.chat_bubble,
                      label: 'Chat',
                      onTap: () => _openLiveChat(context),
                    ),
                  ],
                ),
              ],
            ),
          ),

          SizedBox(height: 32),

          // Preguntas Frecuentes
          Text(
            'Preguntas Frecuentes',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2D3142),
            ),
          ),
          SizedBox(height: 16),

          _buildFAQItem(
            question: '¿Cómo vinculo a mi hijo?',
            answer:
                'Ve a la sección "Hijos" y presiona "Vincular Hijo". Se generará un código que tu hijo debe ingresar en su aplicación.',
          ),

          _buildFAQItem(
            question: '¿Cómo apruebo contactos?',
            answer:
                'Cuando tu hijo solicite agregar un contacto, recibirás una notificación. Ve a "Lista Blanca" para aprobar o rechazar la solicitud.',
          ),

          _buildFAQItem(
            question: '¿Qué significan los reportes de IA?',
            answer:
                'Los reportes analizan el tono emocional de las conversaciones sin mostrar contenido específico. Te alertan sobre cambios en el estado de ánimo o posibles situaciones de riesgo.',
          ),

          _buildFAQItem(
            question: '¿Cómo funciona la detección de bullying?',
            answer:
                'Nuestra IA analiza patrones de lenguaje y contexto para detectar posibles casos de acoso. Recibirás alertas si se detecta algo preocupante.',
          ),

          _buildFAQItem(
            question: '¿Puedo ver los mensajes de mi hijo?',
            answer:
                'No. SmartConvo respeta la privacidad de tu hijo. Solo recibes reportes abstractos sobre su bienestar emocional, no el contenido de sus conversaciones.',
          ),

          _buildFAQItem(
            question: '¿Cómo desvinculo a un hijo?',
            answer:
                'Ve a la sección "Hijos", selecciona al hijo que deseas desvincular y presiona "Desvincular". Esta acción es reversible.',
          ),

          SizedBox(height: 32),

          // Recursos Adicionales
          Text(
            'Recursos Adicionales',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Color(0xFF2D3142),
            ),
          ),
          SizedBox(height: 16),

          _buildResourceOption(
            icon: Icons.video_library,
            title: 'Video Tutoriales',
            subtitle: 'Aprende a usar todas las funciones',
            onTap: () => _launchURL('https://smartconvo.com/tutoriales'),
          ),

          _buildResourceOption(
            icon: Icons.description,
            title: 'Guía de Usuario',
            subtitle: 'Manual completo de la aplicación',
            onTap: () => _launchURL('https://smartconvo.com/guia'),
          ),

          _buildResourceOption(
            icon: Icons.forum,
            title: 'Comunidad',
            subtitle: 'Únete a nuestro foro de padres',
            onTap: () => _launchURL('https://smartconvo.com/comunidad'),
          ),

          _buildResourceOption(
            icon: Icons.bug_report,
            title: 'Reportar un Problema',
            subtitle: 'Ayúdanos a mejorar',
            onTap: () => _showReportDialog(context),
          ),

          SizedBox(height: 32),

          // Información de la App
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                Text(
                  'SmartConvo v1.0.0',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2D3142),
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  '© 2024 SmartConvo. Todos los derechos reservados.',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),

          SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildQuickContactButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, color: Colors.white, size: 28),
            SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFAQItem({required String question, required String answer}) {
    return ExpansionTile(
      tilePadding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      backgroundColor: Colors.grey[50],
      collapsedBackgroundColor: Colors.grey[50],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      collapsedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      title: Text(
        question,
        style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF2D3142)),
      ),
      iconColor: Color(0xFF9D7FE8),
      collapsedIconColor: Colors.grey[600],
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Text(
            answer,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[700],
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResourceOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      child: ListTile(
        onTap: onTap,
        leading: Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Color(0xFF9D7FE8).withOpacity(0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Color(0xFF9D7FE8)),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: Color(0xFF2D3142),
          ),
        ),
        subtitle: Text(subtitle, style: TextStyle(fontSize: 12)),
        trailing: Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        tileColor: Colors.grey[50],
      ),
    );
  }

  Future<void> _launchEmail() async {
    final Uri emailUri = Uri(
      scheme: 'mailto',
      path: 'soporte@smartconvo.com',
      query: 'subject=Solicitud de Ayuda',
    );
    if (await canLaunchUrl(emailUri)) {
      await launchUrl(emailUri);
    }
  }

  Future<void> _launchPhone() async {
    final Uri phoneUri = Uri(scheme: 'tel', path: '+5493875551234');
    if (await canLaunchUrl(phoneUri)) {
      await launchUrl(phoneUri);
    }
  }

  Future<void> _launchURL(String url) async {
    final Uri uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _openLiveChat(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: EdgeInsets.all(20),
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            SizedBox(height: 20),
            Text(
              'Chat en Vivo',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 20),
            Expanded(
              child: Center(
                child: Text(
                  'Función de chat en vivo próximamente',
                  style: TextStyle(color: Colors.grey[600]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showReportDialog(BuildContext context) {
    final problemController = TextEditingController();
    final titleController = TextEditingController();
    String selectedCategory = 'Error técnico';
    bool isLoading = false;

    final categories = [
      'Error técnico',
      'Problema de conexión',
      'Error en la interfaz',
      'Sugerencia de mejora',
      'Problema de seguridad',
      'Otro',
    ];

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: Row(
            children: [
              Icon(Icons.bug_report, color: Color(0xFF9D7FE8)),
              SizedBox(width: 8),
              Text('Reportar un Problema'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Categoría',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: selectedCategory,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  items: categories.map((category) {
                    return DropdownMenuItem(
                      value: category,
                      child: Text(category),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setState(() {
                      selectedCategory = value!;
                    });
                  },
                ),
                SizedBox(height: 16),
                Text(
                  'Título del problema',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 8),
                TextField(
                  controller: titleController,
                  decoration: InputDecoration(
                    hintText: 'Resumen breve del problema',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  'Descripción detallada',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 8),
                TextField(
                  controller: problemController,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText:
                        'Describe el problema que encontraste, pasos para reproducirlo, etc.',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding: EdgeInsets.all(12),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isLoading ? null : () => Navigator.pop(context),
              child: Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: isLoading
                  ? null
                  : () async {
                      if (titleController.text.trim().isEmpty ||
                          problemController.text.trim().isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Por favor completa todos los campos',
                            ),
                            backgroundColor: Colors.orange,
                          ),
                        );
                        return;
                      }

                      setState(() {
                        isLoading = true;
                      });

                      try {
                        await _submitReport(
                          category: selectedCategory,
                          title: titleController.text.trim(),
                          description: problemController.text.trim(),
                        );

                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Reporte enviado exitosamente. Gracias por tu feedback.',
                            ),
                            backgroundColor: Colors.green,
                          ),
                        );
                      } catch (e) {
                        setState(() {
                          isLoading = false;
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Error al enviar reporte: $e'),
                            backgroundColor: Colors.red,
                          ),
                        );
                      }
                    },
              style: ElevatedButton.styleFrom(
                backgroundColor: Color(0xFF9D7FE8),
                foregroundColor: Colors.white,
              ),
              child: isLoading
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : Text('Enviar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submitReport({
    required String category,
    required String title,
    required String description,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception('Usuario no autenticado');
    }

    await FirebaseFirestore.instance.collection('support_reports').add({
      'userId': user.uid,
      'userEmail': user.email,
      'category': category,
      'title': title,
      'description': description,
      'status': 'pending',
      'priority': _getPriorityFromCategory(category),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'deviceInfo': {'platform': 'mobile', 'appVersion': '1.0.0'},
    });
  }

  String _getPriorityFromCategory(String category) {
    switch (category) {
      case 'Problema de seguridad':
        return 'high';
      case 'Error técnico':
      case 'Problema de conexión':
        return 'medium';
      case 'Error en la interfaz':
      case 'Sugerencia de mejora':
      case 'Otro':
      default:
        return 'low';
    }
  }
}
