import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'link_parent_child.dart';
import 'parent_approval_requests_screen.dart';
import 'parental_control_panel.dart';
import 'reports_screen.dart';
import 'notification_screen.dart';
import 'parent_profile_screen.dart';
import 'screens/story_approval_screen.dart';
import 'screens/child_location_screen.dart';
import 'services/story_service.dart';
import 'services/auto_approval_service.dart';
import 'services/user_role_service.dart';
import 'services/group_chat_service.dart';
import 'models/story.dart';
import 'child_home_screen.dart';
import 'screens/add_contact_screen.dart';
import 'screens/my_code_screen.dart';
import 'widgets/create_group_widget.dart';
import 'widgets/stories_section.dart';

class ParentHomeScreen extends StatefulWidget {
  const ParentHomeScreen({super.key});

  @override
  State<ParentHomeScreen> createState() => _ParentHomeScreenState();
}

class _ParentHomeScreenState extends State<ParentHomeScreen> {
  int _selectedIndex = 0;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final AutoApprovalService _autoApprovalService = AutoApprovalService();

  @override
  void initState() {
    super.initState();
    _initializeAutoApproval();
  }

  /// Inicializar el servicio de aprobación automática
  Future<void> _initializeAutoApproval() async {
    final parentId = _auth.currentUser?.uid;
    if (parentId != null) {
      await _autoApprovalService.startAutoApprovalForParent(parentId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      _buildDashboard(),
      _buildParentChatScreen(),
      _buildChildrenList(),
      _buildWhitelistManagement(),
      ParentProfileScreen(),
    ];

    return Scaffold(
      body: screens[_selectedIndex],
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 10,
              offset: Offset(0, -5),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _selectedIndex,
          onTap: (index) => setState(() => _selectedIndex = index),
          type: BottomNavigationBarType.fixed,
          selectedItemColor: Color(0xFF9D7FE8),
          unselectedItemColor: Colors.grey,
          items: [
            BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_outlined),
              activeIcon: Icon(Icons.dashboard),
              label: 'Dashboard',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.chat_bubble_outline),
              activeIcon: Icon(Icons.chat_bubble),
              label: 'Chats',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.people_outline),
              activeIcon: Icon(Icons.people),
              label: 'Contactos',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.shield_outlined),
              activeIcon: Icon(Icons.shield),
              label: 'Lista Blanca',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: 'Perfil',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDashboard() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF9D7FE8), Color(0xFFB39DDB)],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(20.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  StreamBuilder<DocumentSnapshot>(
                    stream: _firestore
                        .collection('users')
                        .doc(_auth.currentUser!.uid)
                        .snapshots(),
                    builder: (context, snapshot) {
                      final userData =
                          snapshot.data?.data() as Map<String, dynamic>?;
                      final userName =
                          userData?['name'] ??
                          _auth.currentUser?.displayName ??
                          "Padre";

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Hola, $userName',
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Panel de control parental',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.white.withOpacity(0.9),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  NotificationBadge(
                    userId: _auth.currentUser!.uid,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => NotificationsScreen(),
                        ),
                      );
                    },
                  ),
                  CircleAvatar(
                    radius: 25,
                    backgroundColor: Colors.white.withOpacity(0.3),
                    child: Icon(Icons.shield, color: Colors.white),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(30),
                    topRight: Radius.circular(30),
                  ),
                ),
                child: ListView(
                  padding: EdgeInsets.all(20),
                  children: [
                    _buildQuickStats(),
                    SizedBox(height: 20),
                    _buildRecentActivity(),
                    SizedBox(height: 20),
                    _buildWeeklyReport(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickStats() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Resumen Rápido',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Color(0xFF2D3142),
          ),
        ),
        SizedBox(height: 16),

        // Fila 1: Hijos y Mensajes
        Row(
          children: [
            Expanded(child: _buildChildrenCountCard()),
            SizedBox(width: 12),
            Expanded(child: _buildMessagesTodayCard()),
          ],
        ),
        SizedBox(height: 12),

        // Fila 2: Contactos y Alertas
        Row(
          children: [
            Expanded(child: _buildContactsCountCard()),
            SizedBox(width: 12),
            Expanded(child: _buildAlertsCountCard()),
          ],
        ),
        SizedBox(height: 12),
        _buildPendingStoriesCard(),
        SizedBox(height: 12),
        _buildChildrenLocationCard(),
      ],
    );
  }

  // Tarjeta de conteo de hijos vinculados
  Widget _buildChildrenCountCard() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('parent_children')
          .where('parentId', isEqualTo: _auth.currentUser?.uid)
          .snapshots(),
      builder: (context, snapshot) {
        final childrenCount = snapshot.data?.docs.length ?? 0;
        return _buildStatCard(
          icon: Icons.people,
          title: 'Hijos',
          value: childrenCount.toString(),
          color: Color(0xFF9D7FE8),
        );
      },
    );
  }

  // Tarjeta de mensajes de hoy
  Widget _buildMessagesTodayCard() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('messages')
          .where('date', isGreaterThanOrEqualTo: _getStartOfToday())
          .where('date', isLessThan: _getStartOfTomorrow())
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _buildStatCard(
            icon: Icons.message,
            title: 'Mensajes Hoy',
            value: '0',
            color: Color(0xFF4CAF50),
          );
        }

        // Filtrar mensajes relacionados con los hijos del padre
        final messages = snapshot.data?.docs ?? [];
        int todayMessagesCount = 0;

        // Para un conteo más preciso, necesitaríamos relacionar mensajes con hijos
        // Por ahora mostramos el total de mensajes de hoy
        todayMessagesCount = messages.length;

        return _buildStatCard(
          icon: Icons.message,
          title: 'Mensajes Hoy',
          value: todayMessagesCount.toString(),
          color: Color(0xFF4CAF50),
        );
      },
    );
  }

  // Tarjeta de contactos aprobados
  Widget _buildContactsCountCard() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('contacts')
          .where('parentId', isEqualTo: _auth.currentUser?.uid)
          .where('status', isEqualTo: 'approved')
          .snapshots(),
      builder: (context, snapshot) {
        final contactsCount = snapshot.data?.docs.length ?? 0;
        return _buildStatCard(
          icon: Icons.contact_phone,
          title: 'Contactos',
          value: contactsCount.toString(),
          color: Color(0xFF2196F3),
        );
      },
    );
  }

  // Tarjeta de alertas activas
  Widget _buildAlertsCountCard() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('alerts')
          .where('parentId', isEqualTo: _auth.currentUser?.uid)
          .where('status', isEqualTo: 'active')
          .snapshots(),
      builder: (context, snapshot) {
        final alertsCount = snapshot.data?.docs.length ?? 0;
        return _buildStatCard(
          icon: Icons.warning,
          title: 'Alertas',
          value: alertsCount.toString(),
          color: alertsCount > 0 ? Color(0xFFFF5722) : Color(0xFF4CAF50),
        );
      },
    );
  }

  // Métodos auxiliares para fechas
  DateTime _getStartOfToday() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  DateTime _getStartOfTomorrow() {
    final tomorrow = DateTime.now().add(Duration(days: 1));
    return DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
  }

  Widget _buildStatCard({
    required IconData icon,
    required String title,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 28),
          SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          SizedBox(height: 4),
          Text(title, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        ],
      ),
    );
  }

  Widget _buildPendingStoriesCard() {
    final StoryService storyService = StoryService();

    return StreamBuilder<List<Story>>(
      stream: storyService.getPendingStoriesForParent(),
      builder: (context, snapshot) {
        final pendingCount = snapshot.data?.length ?? 0;

        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => StoryApprovalScreen()),
            );
          },
          child: Container(
            padding: EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF9D7FE8), Color(0xFFB39DDB)],
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Color(0xFF9D7FE8).withOpacity(0.3),
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.auto_awesome,
                    color: Colors.white,
                    size: 28,
                  ),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Historias Pendientes',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        pendingCount == 0
                            ? 'No hay historias pendientes'
                            : '$pendingCount ${pendingCount == 1 ? 'historia' : 'historias'} ${pendingCount == 1 ? 'esperando' : 'esperando'} aprobación',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      ),
                    ],
                  ),
                ),
                if (pendingCount > 0)
                  Container(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$pendingCount',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF9D7FE8),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildChildrenLocationCard() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore
          .collection('users')
          .where('parentId', isEqualTo: _auth.currentUser!.uid)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return SizedBox.shrink();
        }

        final children = snapshot.data!.docs;
        if (children.isEmpty) {
          return SizedBox.shrink();
        }

        return Container(
          padding: EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF4CAF50), Color(0xFF66BB6A)],
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Color(0xFF4CAF50).withValues(alpha: 0.3),
                blurRadius: 10,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.location_on,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Ubicación de tus Hijos',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Ve dónde están en tiempo real',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.white.withValues(alpha: 0.9),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.arrow_forward_ios, color: Colors.white, size: 20),
                ],
              ),
              SizedBox(height: 16),
              ...children.map((childDoc) {
                final childData = childDoc.data() as Map<String, dynamic>;
                final childName = childData['name'] ?? 'Hijo';
                final childId = childDoc.id;

                return Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ChildLocationScreen(
                            childId: childId,
                            childName: childName,
                          ),
                        ),
                      );
                    },
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 20,
                            backgroundColor: Colors.white.withValues(
                              alpha: 0.3,
                            ),
                            backgroundImage: childData['photoURL'] != null
                                ? NetworkImage(childData['photoURL'])
                                : null,
                            child: childData['photoURL'] == null
                                ? Text(
                                    childName[0].toUpperCase(),
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  )
                                : null,
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              childName,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.location_on,
                            color: Colors.white,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Widget _buildRecentActivity() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Actividad Reciente',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Color(0xFF2D3142),
          ),
        ),
        SizedBox(height: 16),
        StreamBuilder<QuerySnapshot>(
          stream: _firestore
              .collection('activities')
              .where('parentId', isEqualTo: _auth.currentUser?.uid)
              .orderBy('timestamp', descending: true)
              .limit(5)
              .snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              print('⚠️ Error leyendo actividades: ${snapshot.error}');
              return _buildNoActivitiesMessage();
            }

            if (snapshot.connectionState == ConnectionState.waiting) {
              return _buildActivityLoadingIndicator();
            }

            final activities = snapshot.data?.docs ?? [];

            if (activities.isEmpty) {
              return _buildNoActivitiesMessage();
            }

            return Column(
              children: activities.map((doc) {
                final data = doc.data() as Map<String, dynamic>;
                return _buildActivityItemFromData(data);
              }).toList(),
            );
          },
        ),
      ],
    );
  }

  Widget _buildActivityItemFromData(Map<String, dynamic> data) {
    final String type = data['type'] ?? 'unknown';
    final String childName = data['childName'] ?? 'Usuario';
    final String details = data['details'] ?? '';
    final Timestamp? timestamp = data['timestamp'];

    IconData icon;
    Color color;
    String title;
    String subtitle;

    // Determinar ícono, color y textos basado en el tipo de actividad
    switch (type) {
      case 'contact_approved':
        icon = Icons.check_circle;
        color = Colors.green;
        title = 'Contacto aprobado';
        subtitle = '$childName añadió contacto: $details';
        break;
      case 'contact_request':
        icon = Icons.pending;
        color = Colors.orange;
        title = 'Solicitud pendiente';
        subtitle = '$childName quiere agregar: $details';
        break;
      case 'message_flagged':
        icon = Icons.flag;
        color = Colors.red;
        title = 'Mensaje marcado';
        subtitle = 'Actividad sospechosa de $childName';
        break;
      case 'location_update':
        icon = Icons.location_on;
        color = Colors.blue;
        title = 'Ubicación actualizada';
        subtitle = '$childName cambió de ubicación';
        break;
      case 'app_usage':
        icon = Icons.phone_android;
        color = Colors.purple;
        title = 'Uso de aplicación';
        subtitle = '$childName usó $details';
        break;
      default:
        icon = Icons.info;
        color = Colors.grey;
        title = 'Actividad';
        subtitle = details.isNotEmpty ? details : 'Actividad de $childName';
    }

    final String timeAgo = timestamp != null
        ? _getTimeAgo(timestamp.toDate())
        : 'Hace un momento';

    return _buildActivityItem(
      icon: icon,
      title: title,
      subtitle: subtitle,
      time: timeAgo,
      color: color,
    );
  }

  Widget _buildNoActivitiesMessage() {
    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(Icons.timeline, size: 48, color: Colors.grey[400]),
          SizedBox(height: 12),
          Text(
            'Sin actividad reciente',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          SizedBox(height: 4),
          Text(
            'Las actividades de tus hijos aparecerán aquí',
            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildActivityLoadingIndicator() {
    return Container(
      padding: EdgeInsets.all(20),
      child: Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF9D7FE8)),
        ),
      ),
    );
  }

  String _getTimeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays > 0) {
      return difference.inDays == 1
          ? 'Hace 1 día'
          : 'Hace ${difference.inDays} días';
    } else if (difference.inHours > 0) {
      return difference.inHours == 1
          ? 'Hace 1 hora'
          : 'Hace ${difference.inHours} horas';
    } else if (difference.inMinutes > 0) {
      return difference.inMinutes == 1
          ? 'Hace 1 minuto'
          : 'Hace ${difference.inMinutes} minutos';
    } else {
      return 'Hace un momento';
    }
  }

  Widget _buildActivityItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required String time,
    required Color color,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: 12),
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2D3142),
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
          Text(time, style: TextStyle(fontSize: 11, color: Colors.grey[500])),
        ],
      ),
    );
  }

  Widget _buildWeeklyReport() {
    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF9D7FE8), Color(0xFFB39DDB)],
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.analytics, color: Colors.white),
              SizedBox(width: 8),
              Text(
                'Reportes con IA',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          Text(
            'Análisis de sentimientos, detección de bullying y reportes semanales automáticos.',
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withOpacity(0.9),
            ),
          ),
          SizedBox(height: 16),
          ElevatedButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => ReportsScreen()),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Color(0xFF9D7FE8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text('Ver Reportes y Alertas'),
          ),
        ],
      ),
    );
  }

  Future<List<DocumentSnapshot>> _loadAllContacts(String currentUserId) async {
    final query = await _firestore
        .collection('contacts')
        .where('users', arrayContains: currentUserId)
        .get();

    return query.docs;
  }

  Widget _buildChildrenList() {
    final userRoleService = UserRoleService();
    final currentUserId = _auth.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(
        title: Text('Mis Contactos'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
        actions: [
          // Badge con contador de solicitudes pendientes
          StreamBuilder<QuerySnapshot>(
            stream: _firestore
                .collection('parent_approval_requests')
                .where('existingParentId', isEqualTo: _auth.currentUser?.uid)
                .where('status', isEqualTo: 'pending')
                .snapshots(),
            builder: (context, snapshot) {
              // Manejar error de permisos gracefully
              if (snapshot.hasError) {
                print('⚠️ Error leyendo solicitudes de aprobación: ${snapshot.error}');
              }
              final pendingCount = snapshot.hasData ? snapshot.data!.docs.length : 0;

              return Stack(
                children: [
                  IconButton(
                    icon: Icon(Icons.notification_important),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ParentApprovalRequestsScreen(),
                        ),
                      );
                    },
                  ),
                  if (pendingCount > 0)
                    Positioned(
                      right: 8,
                      top: 8,
                      child: Container(
                        padding: EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                        constraints: BoxConstraints(
                          minWidth: 16,
                          minHeight: 16,
                        ),
                        child: Text(
                          '$pendingCount',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          IconButton(
            icon: Icon(Icons.person_add),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => AddContactScreen()),
              );
            },
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF9D7FE8),
              Color(0xFF7C5FCC),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Header con título
              Padding(
                padding: EdgeInsets.all(20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Mis Contactos',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Gestiona tus contactos',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.8),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Contenido en blanco
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(30),
                      topRight: Radius.circular(30),
                    ),
                  ),
                  child: FutureBuilder<List<String>>(
                    future: userRoleService.getLinkedChildren(currentUserId!),
                    builder: (context, childrenSnapshot) {
                      if (childrenSnapshot.connectionState == ConnectionState.waiting) {
                        return Center(child: CircularProgressIndicator());
                      }

                      final linkedChildren = childrenSnapshot.data ?? [];

                      // Load contacts with users array format
                      return FutureBuilder<List<DocumentSnapshot>>(
                        future: _loadAllContacts(currentUserId),
                        builder: (context, contactsSnapshot) {
                          if (contactsSnapshot.hasError) {
                            return Center(child: Text('Error: ${contactsSnapshot.error}'));
                          }

                          if (contactsSnapshot.connectionState == ConnectionState.waiting) {
                            return Center(child: CircularProgressIndicator());
                          }

                          final allContactDocs = contactsSnapshot.data ?? [];

              // Separar hijos y otros contactos
              final childrenContacts = <Widget>[];
              final otherContacts = <Widget>[];
              final processedUserIds = <String>{};

              for (var doc in allContactDocs) {
                final data = doc.data() as Map<String, dynamic>;

                // Extraer el otro usuario del array users
                final users = List<String>.from(data['users'] ?? []);
                final otherUserId = users.firstWhere((id) => id != currentUserId, orElse: () => '');

                if (otherUserId.isEmpty || processedUserIds.contains(otherUserId)) {
                  continue;
                }

                processedUserIds.add(otherUserId);
                final isChild = linkedChildren.contains(otherUserId);

                final widget = FutureBuilder<DocumentSnapshot>(
                  future: _firestore.collection('users').doc(otherUserId).get(),
                  builder: (context, userSnapshot) {
                    if (!userSnapshot.hasData) return SizedBox();

                    final userData = userSnapshot.data!.data() as Map<String, dynamic>?;
                    final name = userData?['name'] ?? 'Usuario';
                    final isOnline = userData?['isOnline'] ?? false;
                    final age = userData?['age'] ?? 0;

                    return _buildChildCard(
                      childId: otherUserId!,
                      name: name,
                      age: age,
                      status: isOnline ? 'En línea' : 'Desconectado',
                      statusColor: isOnline ? Colors.green : Colors.grey,
                      isChild: isChild,
                    );
                  },
                );

                if (isChild) {
                  childrenContacts.add(widget);
                } else {
                  otherContacts.add(widget);
                }
              }

              // Also add any linked children that don't have contact documents yet
              for (var childId in linkedChildren) {
                if (!processedUserIds.contains(childId)) {
                  processedUserIds.add(childId);

                  final widget = FutureBuilder<DocumentSnapshot>(
                    future: _firestore.collection('users').doc(childId).get(),
                    builder: (context, userSnapshot) {
                      if (!userSnapshot.hasData) return SizedBox();

                      final userData = userSnapshot.data!.data() as Map<String, dynamic>?;
                      final name = userData?['name'] ?? 'Usuario';
                      final isOnline = userData?['isOnline'] ?? false;
                      final age = userData?['age'] ?? 0;

                      return _buildChildCard(
                        childId: childId,
                        name: name,
                        age: age,
                        status: isOnline ? 'En línea' : 'Desconectado',
                        statusColor: isOnline ? Colors.green : Colors.grey,
                        isChild: true,
                      );
                    },
                  );

                  childrenContacts.add(widget);
                }
              }

              if (childrenContacts.isEmpty && otherContacts.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.people_outline,
                        size: 64,
                        color: Colors.grey[300],
                      ),
                      SizedBox(height: 16),
                      Text(
                        'No tienes contactos aún',
                        style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'Agrega contactos o vincula un hijo',
                        style: TextStyle(fontSize: 14, color: Colors.grey[500]),
                      ),
                    ],
                  ),
                );
              }

              return ListView(
                            padding: EdgeInsets.all(20),
                            children: [
                              if (childrenContacts.isNotEmpty) ...[
                                Padding(
                                  padding: EdgeInsets.only(bottom: 12, left: 4),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: Colors.green.withOpacity(0.1),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Icon(Icons.family_restroom, size: 16, color: Colors.green),
                                      ),
                                      SizedBox(width: 8),
                                      Text(
                                        'Hijos',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF2D3142),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                ...childrenContacts,
                                if (otherContacts.isNotEmpty) SizedBox(height: 24),
                              ],
                              if (otherContacts.isNotEmpty) ...[
                                Padding(
                                  padding: EdgeInsets.only(bottom: 12, left: 4),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: Colors.blue.withOpacity(0.1),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Icon(Icons.people, size: 16, color: Colors.blue),
                                      ),
                                      SizedBox(width: 8),
                                      Text(
                                        'Otros Contactos',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF2D3142),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                ...otherContacts,
                              ],
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => GenerateLinkCodeScreen()),
          );
        },
        backgroundColor: Color(0xFF9D7FE8),
        icon: Icon(Icons.link),
        label: Text('Vincular Hijo'),
      ),
    );
  }

  Widget _buildChildCard({
    required String childId,
    required String name,
    required int age,
    required String status,
    required Color statusColor,
    bool isChild = true,
  }) {
    return GestureDetector(
      onTap: () {
        final currentUserId = _auth.currentUser?.uid;
        if (currentUserId != null) {
          final chatId = _getChatId(currentUserId, childId);
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ChatDetailScreen(
                chatId: chatId,
                contactId: childId,
                contactName: name,
              ),
            ),
          );
        }
      },
      child: Container(
        padding: EdgeInsets.all(16),
        margin: EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
        children: [
          CircleAvatar(
            radius: 30,
            backgroundColor: Color(0xFF9D7FE8).withOpacity(0.2),
            child: Text(
              name[0],
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF9D7FE8),
              ),
            ),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  '$age años',
                  style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                ),
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: statusColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                SizedBox(width: 6),
                Text(
                  status,
                  style: TextStyle(
                    fontSize: 12,
                    color: statusColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (isChild)
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'unlink') {
                  _showUnlinkChildDialog(childId, name);
                } else if (value == 'location') {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          ChildLocationScreen(childId: childId, childName: name),
                    ),
                  );
                }
              },
              itemBuilder: (BuildContext context) => [
                PopupMenuItem<String>(
                  value: 'location',
                  child: Row(
                    children: [
                      Icon(Icons.location_on, size: 20, color: Colors.blue),
                      SizedBox(width: 8),
                      Text('Ver Ubicación'),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'unlink',
                  child: Row(
                    children: [
                      Icon(Icons.link_off, size: 20, color: Colors.red),
                    SizedBox(width: 8),
                    Text('Desvincular'),
                  ],
                ),
              ),
            ],
            icon: Icon(Icons.more_vert, color: Colors.grey[600]),
          ),
        ],
        ),
      ),
    );
  }

  Widget _buildWhitelistManagement() {
    return ParentalControlPanel();
  }

  Widget _buildProfile() {
    return Scaffold(
      appBar: AppBar(
        title: Text('Mi Perfil'),
        backgroundColor: Color(0xFF9D7FE8),
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .doc(_auth.currentUser!.uid)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }

          final userData = snapshot.data?.data() as Map<String, dynamic>?;
          final photoURL = userData?['photoURL'];
          final name =
              userData?['name'] ?? _auth.currentUser?.displayName ?? 'Usuario';
          final phone = userData?['phone'] ?? 'Sin teléfono';

          return ListView(
            padding: EdgeInsets.all(20),
            children: [
              Center(
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: () => _showImagePickerOptions(),
                      child: Stack(
                        children: [
                          CircleAvatar(
                            radius: 50,
                            backgroundColor: Color(0xFF9D7FE8),
                            backgroundImage:
                                photoURL != null && photoURL.isNotEmpty
                                ? NetworkImage(photoURL)
                                : null,
                            child: photoURL == null || photoURL.isEmpty
                                ? Icon(
                                    Icons.person,
                                    size: 50,
                                    color: Colors.white,
                                  )
                                : null,
                          ),
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: Container(
                              padding: EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: Color(0xFF9D7FE8),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2,
                                ),
                              ),
                              child: Icon(
                                Icons.camera_alt,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: 16),
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      phone,
                      style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
              SizedBox(height: 32),
              _buildProfileOption(
                icon: Icons.qr_code,
                title: 'Mi Código QR',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => MyCodeScreen()),
                  );
                },
              ),
              _buildProfileOption(
                icon: Icons.settings,
                title: 'Configuración',
                onTap: () {},
              ),
              _buildProfileOption(
                icon: Icons.notifications,
                title: 'Notificaciones',
                onTap: () {},
              ),
              _buildProfileOption(
                icon: Icons.help,
                title: 'Ayuda y Soporte',
                onTap: () {},
              ),
              _buildProfileOption(
                icon: Icons.privacy_tip,
                title: 'Privacidad',
                onTap: () {},
              ),
              SizedBox(height: 16),
              _buildProfileOption(
                icon: Icons.logout,
                title: 'Cerrar Sesión',
                onTap: () async {
                  await _auth.signOut();
                },
                isDestructive: true,
              ),
            ],
          );
        },
      ),
    );
  }

  // Métodos para actualizar foto de perfil
  Future<void> _pickImage(ImageSource source) async {
    try {
      final pickedFile = await ImagePicker().pickImage(
        source: source,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 80,
      );

      if (pickedFile != null) {
        await _uploadAndUpdateProfileImage(File(pickedFile.path));
      }
    } catch (e) {
      print('❌ Error seleccionando imagen: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error seleccionando imagen: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _showImagePickerOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  margin: EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Text(
                        'Actualizar foto de perfil',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF2D3142),
                        ),
                      ),
                      SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildImageOption(
                            icon: Icons.camera_alt,
                            title: 'Cámara',
                            onTap: () {
                              Navigator.pop(context);
                              _pickImage(ImageSource.camera);
                            },
                          ),
                          _buildImageOption(
                            icon: Icons.photo_library,
                            title: 'Galería',
                            onTap: () {
                              Navigator.pop(context);
                              _pickImage(ImageSource.gallery);
                            },
                          ),
                        ],
                      ),
                      SizedBox(height: 16),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildImageOption({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 100,
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Color(0xFF9D7FE8).withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Color(0xFF9D7FE8).withOpacity(0.3)),
        ),
        child: Column(
          children: [
            Icon(icon, size: 32, color: Color(0xFF9D7FE8)),
            SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                color: Color(0xFF2D3142),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _uploadAndUpdateProfileImage(File imageFile) async {
    try {
      // Mostrar loading
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Text('Actualizando foto...'),
            ],
          ),
        ),
      );

      final user = _auth.currentUser;
      if (user == null) throw Exception('Usuario no autenticado');

      // Subir imagen a Firebase Storage
      final storageRef = FirebaseStorage.instance
          .ref()
          .child('profile_images')
          .child('${user.uid}.jpg');

      final uploadTask = storageRef.putFile(imageFile);
      final snapshot = await uploadTask;
      final downloadUrl = await snapshot.ref.getDownloadURL();

      // Actualizar Firestore
      await _firestore.collection('users').doc(user.uid).update({
        'photoURL': downloadUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      Navigator.pop(context); // Cerrar loading

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Foto de perfil actualizada'),
          backgroundColor: Colors.green,
        ),
      );

      print('✅ Foto de perfil actualizada: $downloadUrl');
    } catch (e) {
      Navigator.pop(context); // Cerrar loading
      print('❌ Error actualizando foto: $e');

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error actualizando foto: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _buildProfileOption({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    return Container(
      margin: EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: Icon(
          icon,
          color: isDestructive ? Colors.red : Color(0xFF9D7FE8),
        ),
        title: Text(
          title,
          style: TextStyle(
            color: isDestructive ? Colors.red : Color(0xFF2D3142),
            fontWeight: FontWeight.w500,
          ),
        ),
        trailing: Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
      ),
    );
  }

  Widget _buildParentChatScreen() {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF9D7FE8), Color(0xFFB39DDB)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Chats 💬',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Conversaciones con tus contactos',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.white.withOpacity(0.9),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        IconButton(
                          icon: Icon(Icons.group_add, color: Colors.white, size: 26),
                          onPressed: () {
                            showModalBottomSheet(
                              context: context,
                              isScrollControlled: true,
                              backgroundColor: Colors.transparent,
                              builder: (context) => CreateGroupWidget(
                                onGroupCreated: () {
                                  setState(() {});
                                },
                              ),
                            );
                          },
                          padding: EdgeInsets.all(8),
                        ),
                        IconButton(
                          icon: Icon(Icons.qr_code, color: Colors.white, size: 26),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (context) => MyCodeScreen()),
                            );
                          },
                          padding: EdgeInsets.all(8),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(30),
                      topRight: Radius.circular(30),
                    ),
                  ),
                  child: StreamBuilder<QuerySnapshot>(
                    stream: _firestore
                        .collection('chats')
                        .where(
                          'participants',
                          arrayContains: _auth.currentUser?.uid,
                        )
                        .snapshots(),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.error_outline,
                                size: 48,
                                color: Colors.red,
                              ),
                              SizedBox(height: 16),
                              Text('Error: ${snapshot.error}'),
                            ],
                          ),
                        );
                      }

                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return Center(child: CircularProgressIndicator());
                      }

                      // Siempre llamar a _buildParentChatList, incluso si no hay chats existentes
                      return FutureBuilder<List<Widget>>(
                        future: _buildParentChatList(snapshot.data?.docs ?? []),
                        builder: (context, chatListSnapshot) {
                          if (chatListSnapshot.connectionState ==
                              ConnectionState.waiting) {
                            return Center(child: CircularProgressIndicator());
                          }

                          if (!chatListSnapshot.hasData ||
                              chatListSnapshot.data!.isEmpty) {
                            return _buildEmptyChatsView();
                          }

                          return ListView(
                            padding: EdgeInsets.all(16),
                            children: chatListSnapshot.data!,
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => AddContactScreen()),
          );
        },
        backgroundColor: Color(0xFF9D7FE8),
        child: Icon(Icons.person_add, color: Colors.white),
      ),
    );
  }

  Widget _buildEmptyChatsView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey[300]),
          SizedBox(height: 16),
          Text(
            'No tienes conversaciones aún',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Las conversaciones con tus hijos aparecerán aquí',
            style: TextStyle(fontSize: 14, color: Colors.grey[500]),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Future<List<Widget>> _buildParentChatList(
    List<QueryDocumentSnapshot> chatDocs,
  ) async {
    final List<Widget> widgets = [];
    final List<Map<String, dynamic>> allChildrenChats = [];

    // Obtener lista de hijos del padre actual
    final parentId = _auth.currentUser?.uid;
    if (parentId == null) {
      print('🚫 ParentId es null');
      return widgets;
    }

    print('👨‍💼 Buscando hijos para padre: $parentId');

    // Buscar hijos vinculados al padre (usar la misma colección que la pestaña "Hijos")
    final childrenQuery = await _firestore
        .collection('parent_children')
        .where('parentId', isEqualTo: parentId)
        .get();

    print('👶 Hijos encontrados: ${childrenQuery.docs.length}');

    if (childrenQuery.docs.isEmpty) {
      // No hay hijos vinculados
      print('❌ No se encontraron hijos vinculados');
      return widgets;
    }

    // Agregar sección de historias primero
    widgets.add(StoriesHeader());
    widgets.add(StoriesSection());
    widgets.add(SizedBox(height: 16));

    // Agregar header siempre que haya hijos
    widgets.add(_buildParentChatHeader());

    // Para cada hijo, crear un item de chat (con o sin mensajes)
    for (final parentChildDoc in childrenQuery.docs) {
      final parentChildData = parentChildDoc.data() as Map<String, dynamic>;
      final childId = parentChildData['childId'];

      print('👶 Procesando hijo: $childId');

      // Obtener datos del usuario hijo
      final childDoc = await _firestore.collection('users').doc(childId).get();
      if (!childDoc.exists) {
        print('❌ Usuario hijo $childId no existe');
        continue;
      }
      final childData = childDoc.data() as Map<String, dynamic>;
      print('✅ Datos del hijo obtenidos: ${childData['name']}');
      print('🔍 Iniciando búsqueda de chat existente...');

      // Buscar si existe un chat con este hijo
      QueryDocumentSnapshot? existingChatDoc;
      try {
        existingChatDoc = chatDocs.firstWhere(
          (chatDoc) {
            final chatData = chatDoc.data() as Map<String, dynamic>;
            final participants = List<String>.from(chatData['participants'] ?? []);
            return participants.contains(childId) && participants.contains(parentId);
          },
        );
      } catch (e) {
        // No se encontró chat existente
        existingChatDoc = null;
        print('📋 No se encontró chat existente: $e');
      }

      print('🔍 Chat existente encontrado: ${existingChatDoc != null}');

      if (existingChatDoc != null) {
        // Hay chat existente con mensajes
        final chatData = existingChatDoc.data() as Map<String, dynamic>;

        allChildrenChats.add({
          'chatDoc': existingChatDoc,
          'chatData': chatData,
          'childId': childId,
          'childData': childData,
          'hasMessages': true,
          'lastMessageTime': chatData['lastMessageTime'],
        });
      } else {
        // No hay chat, crear placeholder
        allChildrenChats.add({
          'chatDoc': null,
          'chatData': null,
          'childId': childId,
          'childData': childData,
          'hasMessages': false,
          'lastMessageTime': null,
        });
      }
    }

    // Ordenar: chats con mensajes primero (por tiempo), luego chats vacíos (por nombre)
    allChildrenChats.sort((a, b) {
      final aHasMessages = a['hasMessages'] as bool;
      final bHasMessages = b['hasMessages'] as bool;

      if (aHasMessages && bHasMessages) {
        // Ambos tienen mensajes, ordenar por tiempo
        final aTime = a['lastMessageTime'] as Timestamp?;
        final bTime = b['lastMessageTime'] as Timestamp?;

        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;

        return bTime.compareTo(aTime);
      } else if (aHasMessages && !bHasMessages) {
        // A tiene mensajes, B no - A va primero
        return -1;
      } else if (!aHasMessages && bHasMessages) {
        // B tiene mensajes, A no - B va primero
        return 1;
      } else {
        // Ninguno tiene mensajes, ordenar por nombre
        final aName = (a['childData'] as Map<String, dynamic>)['name'] ?? 'Hijo/a';
        final bName = (b['childData'] as Map<String, dynamic>)['name'] ?? 'Hijo/a';
        return aName.compareTo(bName);
      }
    });

    // Crear widgets para todos los hijos
    for (final childChat in allChildrenChats) {
      final childId = childChat['childId'] as String;
      final childData = childChat['childData'] as Map<String, dynamic>;
      final hasMessages = childChat['hasMessages'] as bool;

      final name = childData['name'] ?? 'Hijo/a';
      final isOnline = childData['isOnline'] ?? false;
      final photoURL = childData['photoURL'];

      if (hasMessages) {
        // Chat con mensajes existentes
        final chatDoc = childChat['chatDoc'] as QueryDocumentSnapshot;
        final chatData = childChat['chatData'] as Map<String, dynamic>;

        print('💬 Agregando chat con mensajes para: $name');
        widgets.add(
          _buildParentChatItem(
            chatId: chatDoc.id,
            userId: childId,
            name: name,
            lastMessage: chatData['lastMessage'] ?? '',
            time: _formatChatTime(chatData['lastMessageTime']),
            unreadCount: 0,
            isOnline: isOnline,
            photoURL: photoURL,
            isEmpty: false,
          ),
        );
      } else {
        // Chat vacío (placeholder)
        print('📝 Agregando chat placeholder para: $name');
        widgets.add(
          _buildParentChatItem(
            chatId: _getChatId(parentId, childId),
            userId: childId,
            name: name,
            lastMessage: 'Toca para iniciar conversación',
            time: '',
            unreadCount: 0,
            isOnline: isOnline,
            photoURL: photoURL,
            isEmpty: true,
          ),
        );
      }
    }

    print('📝 Total widgets creados: ${widgets.length}');
    print('👨‍👩‍👧‍👦 Total hijos procesados: ${allChildrenChats.length}');

    // Combinar otros chats y grupos en una sola lista
    List<Map<String, dynamic>> allOtherItems = [];
    final childrenIds = childrenQuery.docs
        .map((doc) => doc.data()['childId'] as String)
        .toSet();

    // Procesar chats con otros usuarios (no hijos)
    for (final chatDoc in chatDocs) {
      final chatData = chatDoc.data() as Map<String, dynamic>;
      final participants = List<String>.from(chatData['participants'] ?? []);

      // Encontrar el otro participante
      final otherUserId = participants.firstWhere(
        (id) => id != parentId,
        orElse: () => '',
      );

      // Si el otro usuario NO es un hijo vinculado, agregarlo
      if (otherUserId.isNotEmpty && !childrenIds.contains(otherUserId)) {
        try {
          final otherUserDoc = await _firestore.collection('users').doc(otherUserId).get();
          if (otherUserDoc.exists) {
            final otherUserData = otherUserDoc.data() as Map<String, dynamic>;
            allOtherItems.add({
              'type': 'chat',
              'chatDoc': chatDoc,
              'chatData': chatData,
              'userId': otherUserId,
              'userData': otherUserData,
              'lastMessageTime': chatData['lastMessageTime'],
            });
          }
        } catch (e) {
          print('❌ Error obteniendo usuario $otherUserId: $e');
        }
      }
    }

    // Procesar grupos del padre
    try {
      final groupsSnapshot = await _firestore
          .collection('groups')
          .where('members', arrayContains: parentId)
          .where('isActive', isEqualTo: true)
          .get();

      for (final groupDoc in groupsSnapshot.docs) {
        final groupData = groupDoc.data();
        allOtherItems.add({
          'type': 'group',
          'groupDoc': groupDoc,
          'groupData': groupData,
          'lastMessageTime': groupData['lastActivity'] as Timestamp?,
        });
      }

      print('✅ Agregados ${groupsSnapshot.docs.length} grupos a la lista');
    } catch (e) {
      print('❌ Error obteniendo grupos: $e');
    }

    // Ordenar todos los items (chats + grupos) por tiempo
    allOtherItems.sort((a, b) {
      final aTime = a['lastMessageTime'] as Timestamp?;
      final bTime = b['lastMessageTime'] as Timestamp?;

      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;

      return bTime.compareTo(aTime);
    });

    // Agregar widgets para todos los otros items (con header "Chats")
    if (allOtherItems.isNotEmpty) {
      widgets.add(SizedBox(height: 16));
      widgets.add(
        Padding(
          padding: EdgeInsets.only(bottom: 12, left: 4),
          child: Row(
            children: [
              Container(
                padding: EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.chat_bubble, size: 16, color: Colors.blue),
              ),
              SizedBox(width: 8),
              Text(
                'Chats',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2D3142),
                ),
              ),
            ],
          ),
        ),
      );

      for (final item in allOtherItems) {
        if (item['type'] == 'chat') {
          // Chat con otro usuario
          final chatDoc = item['chatDoc'] as QueryDocumentSnapshot;
          final chatData = item['chatData'] as Map<String, dynamic>;
          final userData = item['userData'] as Map<String, dynamic>;
          final userId = item['userId'] as String;

          widgets.add(
            _buildParentChatItem(
              chatId: chatDoc.id,
              userId: userId,
              name: userData['name'] ?? 'Usuario',
              lastMessage: chatData['lastMessage'] ?? '',
              time: _formatChatTime(chatData['lastMessageTime']),
              unreadCount: 0,
              isOnline: userData['isOnline'] ?? false,
              photoURL: userData['photoURL'],
              isEmpty: false,
            ),
          );
        } else if (item['type'] == 'group') {
          // Grupo
          final groupDoc = item['groupDoc'] as QueryDocumentSnapshot;
          final groupData = item['groupData'] as Map<String, dynamic>;

          widgets.add(_buildGroupChatItem(
            groupId: groupDoc.id,
            groupName: groupData['name'] ?? 'Grupo',
            memberCount: (groupData['members'] as List?)?.length ?? 0,
            lastMessage: groupData['lastMessage'] ?? 'Toca para abrir',
            messageCount: groupData['messageCount'] ?? 0,
          ));
        }
      }
    }

    print('📝 Total otros items (chats + grupos): ${allOtherItems.length}');
    return widgets;
  }

  Widget _buildParentChatHeader() {
    return Padding(
      padding: EdgeInsets.only(bottom: 12, left: 4),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.family_restroom, size: 16, color: Colors.green),
          ),
          SizedBox(width: 8),
          Text(
            'Mis Hijos',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Color(0xFF2D3142),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildParentChatItem({
    required String chatId,
    required String userId,
    required String name,
    required String lastMessage,
    required String time,
    required int unreadCount,
    required bool isOnline,
    String? photoURL,
    bool isEmpty = false,
  }) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ChatDetailScreen(
              chatId: chatId,
              contactId: userId,
              contactName: name,
            ),
          ),
        );
      },
      child: Container(
        margin: EdgeInsets.only(bottom: 8),
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: unreadCount > 0
              ? Color(0xFF9D7FE8).withOpacity(0.05)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: Color(0xFF9D7FE8).withOpacity(0.2),
                  backgroundImage: photoURL != null && photoURL.isNotEmpty
                      ? NetworkImage(photoURL)
                      : null,
                  child: photoURL == null || photoURL.isEmpty
                      ? Text(
                          name.isNotEmpty ? name[0].toUpperCase() : 'H',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF9D7FE8),
                          ),
                        )
                      : null,
                ),
                if (isOnline)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF2D3142),
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    lastMessage,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                      fontStyle: isEmpty ? FontStyle.italic : FontStyle.normal,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Column(
              children: [
                Text(
                  time,
                  style: TextStyle(
                    fontSize: 12,
                    color: unreadCount > 0
                        ? Color(0xFF9D7FE8)
                        : Colors.grey[500],
                  ),
                ),
                if (unreadCount > 0) SizedBox(height: 4),
                if (unreadCount > 0)
                  Container(
                    padding: EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Color(0xFF9D7FE8),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      unreadCount.toString(),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _getChatId(String user1, String user2) {
    final users = [user1, user2]..sort();
    return '${users[0]}_${users[1]}';
  }

  String _formatChatTime(dynamic timestamp) {
    if (timestamp == null) return '';

    final DateTime dateTime = (timestamp as Timestamp).toDate();
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays > 0) {
      if (difference.inDays == 1) return 'Ayer';
      return '${difference.inDays}d';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m';
    } else {
      return 'Ahora';
    }
  }

  void _showUnlinkChildDialog(String childId, String childName) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.warning, color: Colors.orange),
            SizedBox(width: 8),
            Text('Desvincular Hijo'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '¿Estás seguro de que quieres desvincular a $childName?',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            SizedBox(height: 16),
            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange[200]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Esta acción:',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.orange[800],
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '• Eliminará el vínculo padre-hijo',
                    style: TextStyle(fontSize: 14, color: Colors.orange[700]),
                  ),
                  Text(
                    '• Eliminará todas las conversaciones',
                    style: TextStyle(fontSize: 14, color: Colors.orange[700]),
                  ),
                  Text(
                    '• Eliminará el historial de ubicaciones',
                    style: TextStyle(fontSize: 14, color: Colors.orange[700]),
                  ),
                  Text(
                    '• No se puede deshacer',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.red[700],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              await _unlinkChild(childId, childName);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text('Desvincular'),
          ),
        ],
      ),
    );
  }

  Future<void> _unlinkChild(String childId, String childName) async {
    try {
      print('🔗 Iniciando desvinculación de $childName ($childId)');

      // Mostrar loading
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('Desvinculando...'),
            ],
          ),
        ),
      );

      final parentId = _auth.currentUser?.uid;
      if (parentId == null) {
        throw Exception('No hay usuario padre autenticado');
      }

      // 1. Eliminar vínculo de la colección parent_children
      final linkQuery = await _firestore
          .collection('parent_children')
          .where('parentId', isEqualTo: parentId)
          .where('childId', isEqualTo: childId)
          .get();

      for (var doc in linkQuery.docs) {
        await doc.reference.delete();
      }
      print('✅ Vínculo eliminado de parent_children');

      // 2. Eliminar de parent_child_links
      final linkQuery2 = await _firestore
          .collection('parent_child_links')
          .where('parentId', isEqualTo: parentId)
          .where('childId', isEqualTo: childId)
          .get();

      for (var doc in linkQuery2.docs) {
        await doc.reference.delete();
      }
      print('✅ Vínculo eliminado de parent_child_links');

      // 3. Eliminar chats entre padre e hijo
      final chatId = _getChatId(parentId, childId);
      final chatRef = _firestore.collection('chats').doc(chatId);

      // Eliminar mensajes del chat
      final messagesQuery = await chatRef.collection('messages').get();
      for (var messageDoc in messagesQuery.docs) {
        await messageDoc.reference.delete();
      }

      // Eliminar el chat
      await chatRef.delete();
      print('✅ Chat eliminado');

      // 4. Eliminar ubicaciones del hijo
      final locationQuery = await _firestore
          .collection('locations')
          .where('childId', isEqualTo: childId)
          .get();

      for (var doc in locationQuery.docs) {
        await doc.reference.delete();
      }
      print('✅ Ubicaciones eliminadas');

      // 5. Eliminar permisos y aprobaciones relacionados
      final permissionsQuery = await _firestore
          .collection('chat_permissions')
          .where('childId', isEqualTo: childId)
          .get();

      for (var doc in permissionsQuery.docs) {
        await doc.reference.delete();
      }
      print('✅ Permisos de chat eliminados');

      // 6. Eliminar notificaciones relacionadas
      final notificationsQuery = await _firestore
          .collection('notifications')
          .where('userId', isEqualTo: parentId)
          .where('childId', isEqualTo: childId)
          .get();

      for (var doc in notificationsQuery.docs) {
        await doc.reference.delete();
      }
      print('✅ Notificaciones eliminadas');

      // Cerrar loading
      Navigator.pop(context);

      // Mostrar éxito
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ $childName ha sido desvinculado exitosamente'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 3),
        ),
      );

      print('🎉 Desvinculación completada exitosamente');
    } catch (e) {
      // Cerrar loading si está abierto
      Navigator.of(context, rootNavigator: true).pop();

      print('❌ Error desvinculando hijo: $e');

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Error: No se pudo desvincular. $e'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  Widget _buildGroupChatItem({
    required String groupId,
    required String groupName,
    required int memberCount,
    required String lastMessage,
    required int messageCount,
  }) {
    return GestureDetector(
      onTap: () {
        // TODO: Navegar a pantalla de chat de grupo
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Abriendo grupo: $groupName')),
        );
      },
      child: Container(
        margin: EdgeInsets.only(bottom: 8),
        padding: EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: Color(0xFF4CAF50).withOpacity(0.2),
              child: Icon(
                Icons.group,
                color: Color(0xFF4CAF50),
                size: 28,
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          groupName,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF2D3142),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Color(0xFF4CAF50).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '$memberCount miembros',
                          style: TextStyle(
                            fontSize: 12,
                            color: Color(0xFF4CAF50),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text(
                    lastMessage,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'leave') {
                  _confirmLeaveGroup(groupId, groupName);
                }
              },
              itemBuilder: (BuildContext context) => [
                PopupMenuItem<String>(
                  value: 'leave',
                  child: Row(
                    children: [
                      Icon(Icons.exit_to_app, size: 20, color: Colors.red),
                      SizedBox(width: 8),
                      Text('Salir del grupo', style: TextStyle(color: Colors.red)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmLeaveGroup(String groupId, String groupName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('¿Salir del grupo?'),
        content: Text(
          '¿Estás seguro de que quieres salir de "$groupName"?\n\n'
          'Los demás miembros podrán seguir usando el grupo. Si eres el último miembro, el grupo será eliminado.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text('Salir'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      _leaveGroup(groupId, groupName);
    }
  }

  Future<void> _leaveGroup(String groupId, String groupName) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return;

    // Mostrar loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(child: CircularProgressIndicator()),
    );

    try {
      final groupChatService = GroupChatService();
      await groupChatService.leaveGroup(groupId, userId);

      Navigator.pop(context); // Cerrar loading

      // Refrescar la UI
      setState(() {});

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Has salido de "$groupName"'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      Navigator.pop(context); // Cerrar loading

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al salir del grupo: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}
