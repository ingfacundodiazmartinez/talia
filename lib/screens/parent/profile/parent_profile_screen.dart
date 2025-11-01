import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'edit_profile_screen.dart';
import '../../common/privacy_security_screen.dart';
import '../../common/help_support_screen.dart';
import '../../common/privacy_policy_screen.dart';
import '../../common/settings_screen.dart';
import '../../premium/premium_screen.dart';
import '../../../theme_service.dart';
import '../../../controllers/profile_controller.dart';
import '../../../models/parent.dart';
import '../../../services/subscription_service.dart';
import '../../../widgets/profile/profile_header_widget.dart';
import '../../../widgets/profile/children_list_widget.dart';
import '../../../widgets/profile/profile_statistics_widget.dart';

class ParentProfileScreen extends StatefulWidget {
  const ParentProfileScreen({super.key});

  @override
  State<ParentProfileScreen> createState() => _ParentProfileScreenState();
}

class _ParentProfileScreenState extends State<ParentProfileScreen>
    with AutomaticKeepAliveClientMixin {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  late ProfileController _controller;
  late Parent _parent;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final userId = _auth.currentUser!.uid;
    _parent = Parent(id: userId, name: '');
    _controller = ProfileController(parentId: userId);
    _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // Necesario para AutomaticKeepAliveClientMixin

    // Verificar si el usuario sigue autenticado
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      return Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Mi Perfil'),
      ),
      body: SingleChildScrollView(
        physics: ClampingScrollPhysics(),
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header de perfil
              ProfileHeaderWidget(
                parentId: currentUser.uid,
                email: currentUser.email,
                controller: _controller,
                onImageChanged: () => setState(() {}),
              ),
              SizedBox(height: 32),

              // Sección de Hijos
              _buildSectionTitle('Mis Hijos'),
              SizedBox(height: 12),
              ChildrenListWidget(parentId: currentUser.uid),
              SizedBox(height: 32),

              // Estadísticas
              _buildSectionTitle('Estadísticas'),
              SizedBox(height: 12),
              ProfileStatisticsWidget(parentId: currentUser.uid),
              SizedBox(height: 32),

              // Configuración
              _buildSectionTitle('Configuración'),
              SizedBox(height: 12),

              _buildProfileOption(
                icon: Icons.edit,
                title: 'Editar Perfil',
                onTap: () => _navigateToEditProfile(),
              ),
              _buildThemeSetting(),
              _buildProfileOption(
                icon: Icons.security,
                title: 'Privacidad y Seguridad',
                onTap: () => _navigateToPrivacySecurity(),
              ),
              _buildAutoApprovalSetting(),
              _buildProfileOption(
                icon: Icons.notifications,
                title: 'Notificaciones',
                onTap: () => _navigateToSettings(),
              ),
              _buildProfileOption(
                icon: Icons.help,
                title: 'Ayuda y Soporte',
                onTap: () => _navigateToHelpSupport(),
              ),
              _buildProfileOption(
                icon: Icons.privacy_tip,
                title: 'Política de Privacidad',
                onTap: () => _navigateToPrivacyPolicy(),
              ),
              SizedBox(height: 16),

              _buildProfileOption(
                icon: Icons.logout,
                title: 'Cerrar Sesión',
                onTap: _handleLogout,
                isDestructive: true,
              ),
              SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPremiumCard() {
    final colorScheme = Theme.of(context).colorScheme;
    final subscriptionService = SubscriptionService();

    return StreamBuilder<PremiumStatus>(
      stream: subscriptionService.premiumStatusStream(),
      builder: (context, snapshot) {
        final status = snapshot.data ?? PremiumStatus.free();
        final isPremium = status.isPremium;

        return Container(
          margin: EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: isPremium
                  ? [Color(0xFF6A1B9A), Color(0xFF8E24AA)]
                  : [Color(0xFF6A1B9A).withOpacity(0.8), Color(0xFF8E24AA).withOpacity(0.8)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Color(0xFF6A1B9A).withOpacity(0.3),
                blurRadius: 8,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _navigateToPremium(),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isPremium ? Icons.workspace_premium : Icons.star,
                        color: isPremium ? Colors.amber : Colors.white,
                        size: 28,
                      ),
                    ),
                    SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isPremium ? 'Talia ${status.tier.displayName}' : 'Obtén Talia Premium',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            isPremium
                                ? 'Gestiona tu suscripción'
                                : '7 días GRATIS - Filtros HD y efectos especiales',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.9),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.arrow_forward_ios,
                      color: Colors.white,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.bold,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }

  Widget _buildProfileOption({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: Icon(
          icon,
          color: isDestructive ? Colors.red : colorScheme.primary,
        ),
        title: Text(
          title,
          style: TextStyle(
            color: isDestructive ? Colors.red : colorScheme.onSurface,
            fontWeight: FontWeight.w500,
          ),
        ),
        trailing: Icon(
          Icons.arrow_forward_ios,
          size: 16,
          color: colorScheme.onSurfaceVariant,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        tileColor: colorScheme.surfaceContainerHighest,
      ),
    );
  }

  Widget _buildAutoApprovalSetting() {
    final colorScheme = Theme.of(context).colorScheme;

    return StreamBuilder<DocumentSnapshot>(
      stream: _parent.getParentSettingsStream(),
      builder: (context, snapshot) {
        bool autoApprovalEnabled = false;

        if (snapshot.hasData && snapshot.data!.exists) {
          final data = snapshot.data!.data() as Map<String, dynamic>?;
          autoApprovalEnabled = data?['autoApproveRequests'] ?? false;
        }

        return Container(
          margin: EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: Icon(
              Icons.auto_awesome,
              color: colorScheme.primary,
            ),
            title: Text(
              'Aceptar solicitudes por defecto',
              style: TextStyle(
                color: colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              autoApprovalEnabled
                  ? 'Las nuevas solicitudes se aprueban automáticamente'
                  : 'Requiere aprobación manual para cada solicitud',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            trailing: Switch(
              value: autoApprovalEnabled,
              onChanged: _toggleAutoApproval,
              activeColor: colorScheme.primary,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            tileColor: colorScheme.surfaceContainerHighest,
          ),
        );
      },
    );
  }

  Widget _buildThemeSetting() {
    final themeService = ThemeService();
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      margin: EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          themeService.isDarkMode ? Icons.dark_mode : Icons.light_mode,
          color: colorScheme.primary,
        ),
        title: Text(
          'Tema de la Aplicación',
          style: TextStyle(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          themeService.isDarkMode
              ? 'Modo oscuro activado'
              : 'Modo claro activado',
          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
        ),
        trailing: Switch(
          value: themeService.isDarkMode,
          onChanged: _toggleTheme,
          activeColor: colorScheme.primary,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        tileColor: colorScheme.surfaceContainerHighest,
      ),
    );
  }

  // Navigation methods
  void _navigateToPremium() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => PremiumScreen()),
    );
  }

  void _navigateToEditProfile() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => EditProfileScreen()),
    );
  }

  void _navigateToPrivacySecurity() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => PrivacySecurityScreen()),
    );
  }

  void _navigateToSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => SettingsScreen()),
    );
  }

  void _navigateToHelpSupport() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => HelpSupportScreen()),
    );
  }

  void _navigateToPrivacyPolicy() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => PrivacyPolicyScreen()),
    );
  }

  // Event handlers
  Future<void> _toggleAutoApproval(bool enabled) async {
    try {
      await _controller.toggleAutoApproval(enabled);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              enabled
                  ? 'Aprobación automática activada'
                  : 'Aprobación automática desactivada',
            ),
            backgroundColor: enabled ? Colors.green : Colors.orange,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al actualizar configuración: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _toggleTheme(bool value) async {
    final themeService = ThemeService();
    await themeService.toggleTheme();
    setState(() {});

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            themeService.isDarkMode
                ? 'Modo oscuro activado'
                : 'Modo claro activado',
          ),
          backgroundColor: Theme.of(context).colorScheme.primary,
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  Future<void> _handleLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Cerrar Sesión'),
        content: Text('¿Estás seguro que deseas salir?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: Text('Salir'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        print('🚪 Cerrando sesión...');
        await _controller.logout();
        print('✅ Sesión cerrada - AuthWrapper detectará el cambio automáticamente');

        // NO hacer navegación manual - AuthWrapper detectará el signOut
        // y mostrará AuthScreen automáticamente
      } catch (e) {
        print('❌ Error cerrando sesión: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error al cerrar sesión: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }
}
