import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../notification_service.dart';
import '../../../services/auto_approval_service.dart';
import '../../../services/video_call_service.dart';
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

class _ParentDashboardScreenState extends State<ParentDashboardScreen>
    with AutomaticKeepAliveClientMixin {
  late ParentDashboardController _controller;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // Initialize controller without dependencies first
    _controller = ParentDashboardController(
      parentId: '', // Will be set after initialization
      context: context,
      notificationService: NotificationService(),
      videoCallService: VideoCallService(),
      autoApprovalService: AutoApprovalService(),
    );
    _initializeController();
  }

  Future<void> _initializeController() async {
    final currentUserId = _controller.currentUserId;
    if (currentUserId != null) {
      // Re-create controller with correct parentId
      _controller = ParentDashboardController(
        parentId: currentUserId,
        context: context,
        notificationService: NotificationService(),
        videoCallService: VideoCallService(),
        autoApprovalService: AutoApprovalService(),
      );
      await _controller.initialize();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Necesario para AutomaticKeepAliveClientMixin
    print('🏠 ParentDashboardScreen - REBUILDING (esto debería aparecer raramente)');
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
                    stream: _controller.getUserDataStream(),
                    builder: (context, snapshot) {
                      print('🏠 Dashboard StreamBuilder - getUserDataStream rebuilding');
                      final userData =
                          snapshot.data?.data() as Map<String, dynamic>?;
                      final userName =
                          userData?['name'] ??
                          _controller.currentUserDisplayName ??
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
                    EmergencyAlertWidget(parentId: _controller.currentUserId ?? ''),
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
    final currentUserId = _controller.currentUserId;

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
          stream: _controller.getLinkedChildrenIdsStream(),
          builder: (context, snapshot) {
            print('🏠 [ParentDashboard] StreamBuilder Children - connectionState: ${snapshot.connectionState}, hasData: ${snapshot.hasData}');

            if (snapshot.connectionState == ConnectionState.waiting) {
              print('🏠 [ParentDashboard] Mostrando CircularProgressIndicator');
              return Center(
                child: CircularProgressIndicator(
                  color: Theme.of(context).colorScheme.primary,
                ),
              );
            }

            final linkedChildren = snapshot.data ?? [];
            print('🏠 [ParentDashboard] linkedChildren: ${linkedChildren.length} hijos: $linkedChildren');

            if (linkedChildren.isEmpty) {
              print('🏠 [ParentDashboard] No hay hijos vinculados - mostrando NoChildrenCard');
              return NoChildrenCard();
            }

            print('🏠 [ParentDashboard] Construyendo Column con ${linkedChildren.length} ChildDashboardCard(s) y PendingStoriesCard');
            return Column(
              children: [
                ...linkedChildren.map((childId) {
                  print('🏠 [ParentDashboard] Creando ChildDashboardCard para: $childId');
                  return ChildDashboardCard(childId: childId);
                }),
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
