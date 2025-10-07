import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../notification_service.dart';
import '../../../services/auto_approval_service.dart';
import '../../../services/video_call_service.dart';
import '../../../models/child.dart';
import '../../../models/parent.dart';
import '../../../controllers/parent_dashboard_controller.dart';
import '../../../theme_service.dart';
import 'widgets/child_dashboard_card.dart';
import 'widgets/pending_stories_card.dart';
import 'widgets/no_children_card.dart';
import 'widgets/emergency_alert_widget.dart';
import 'widgets/weekly_report_widget.dart';

/// Dashboard Screen for Parent App
///
/// Responsabilidades:
/// - Mostrar información general del dashboard
/// - Mostrar emergencias activas
/// - Mostrar estadísticas de hijos vinculados
/// - Mostrar reportes y análisis con IA
///
/// NO contiene navegación de tabs (manejada por ParentMainShell)
class ParentDashboardScreen extends StatefulWidget {
  const ParentDashboardScreen({super.key});

  @override
  State<ParentDashboardScreen> createState() => _ParentDashboardScreenState();
}

class _ParentDashboardScreenState extends State<ParentDashboardScreen> {
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  late ParentDashboardController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ParentDashboardController(
      parentId: _auth.currentUser!.uid,
      context: context,
      notificationService: NotificationService(),
      videoCallService: VideoCallService(),
      autoApprovalService: AutoApprovalService(),
    );
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _buildDashboard();
  }

  Widget _buildDashboard() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            context.customColors.gradientStart,
            context.customColors.gradientEnd,
          ],
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
                    stream: Parent(
                      id: _auth.currentUser!.uid,
                      name: '',
                    ).getUserDataStream(),
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
                              color: Colors.white.withValues(alpha: 0.9),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  CircleAvatar(
                    radius: 25,
                    backgroundColor: Colors.white.withValues(alpha: 0.3),
                    child: Icon(Icons.shield, color: Colors.white),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(30),
                    topRight: Radius.circular(30),
                  ),
                ),
                child: ListView(
                  padding: EdgeInsets.all(20),
                  physics: ClampingScrollPhysics(),
                  children: [
                    EmergencyAlertWidget(parentId: _auth.currentUser!.uid),
                    _buildQuickStats(),
                    SizedBox(height: 20),
                    WeeklyReportWidget(),
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
    final currentUserId = _auth.currentUser?.uid;

    if (currentUserId == null) {
      return SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Mis Hijos',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        SizedBox(height: 16),
        StreamBuilder<List<String>>(
          stream: Child.getLinkedChildrenIdsStream(currentUserId),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Center(
                child: CircularProgressIndicator(
                  color: Theme.of(context).colorScheme.primary,
                ),
              );
            }

            final linkedChildren = snapshot.data ?? [];

            if (linkedChildren.isEmpty) {
              return NoChildrenCard();
            }

            return Column(
              children: [
                ...linkedChildren.map((childId) => ChildDashboardCard(childId: childId)),
                SizedBox(height: 12),
                PendingStoriesCard(),
              ],
            );
          },
        ),
      ],
    );
  }

}
