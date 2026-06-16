import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import 'edit_profile_screen.dart';
import '../../historias/mi_circulo_screen.dart';
import '../../historias/mis_historias_screen.dart';
import '../../../models/contact.dart';
import '../../../models/child.dart';
import 'widgets/per_child_setting_sheet.dart';
import '../../common/privacy_security_screen.dart';
import '../../common/help_support_screen.dart';
import '../../common/privacy_policy_screen.dart';
import '../../common/settings_screen.dart';
import '../../settings/subscription_screen.dart';
import '../wallet/wallet_screen.dart';
import '../../../controllers/profile_controller.dart';
import '../../../models/parent.dart';
import '../../../services/subscription_service.dart';
import '../../../services/app_config_service.dart';
import '../../../widgets/profile/profile_header_widget.dart';
import '../../../widgets/profile/children_list_widget.dart';
import '../../../utils/release_logger.dart';
import '../../../theme_service.dart';

class ParentProfileScreen extends StatefulWidget {
  const ParentProfileScreen({super.key});

  @override
  State<ParentProfileScreen> createState() => _ParentProfileScreenState();
}

class _ParentProfileScreenState extends State<ParentProfileScreen>
    with AutomaticKeepAliveClientMixin {
  late ProfileController _controller;
  Parent? _parent;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _controller = ProfileController();
    _controller.initialize().then((_) {
      if (_controller.isUserAuthenticated && mounted) {
        setState(() {
          _parent = Parent(id: _controller.currentUserId!, name: '');
        });
      }
    });
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
    if (!_controller.isUserAuthenticated) {
      return Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    final currentUser = _controller.currentUser!;

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

              // Suscripción Premium
              _buildPremiumCard(),
              SizedBox(height: 24),

              // Configuración
              _buildSectionTitle('Configuración'),
              SizedBox(height: 12),

              _buildProfileOption(
                icon: Icons.edit,
                title: 'Editar Perfil',
                onTap: () => _navigateToEditProfile(),
              ),

              // ✅ NUEVO: Mis historias subidas
              _buildProfileOption(
                icon: Icons.auto_stories,
                title: 'Mis historias',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MisHistoriasScreen()),
                ),
              ),

              // ✅ NUEVO: Mi círculo (con badge de invitaciones pendientes)
              Builder(
                builder: (context) {
                  final uid = FirebaseAuth.instance.currentUser?.uid;
                  if (uid == null) return const SizedBox.shrink();
                  return StreamBuilder<List<Contact>>(
                    stream: Contact.watchPendingFriendRequests(uid),
                    builder: (context, snap) {
                      final pending = snap.data?.length ?? 0;
                      return _buildProfileOption(
                        icon: Icons.favorite,
                        title: 'Mi círculo',
                        badge: pending,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const MiCirculoScreen()),
                        ),
                      );
                    },
                  );
                },
              ),

              _buildProfileOption(
                icon: Icons.auto_awesome,
                title: 'Mi billetera de créditos',
                onTap: () => _navigateToWallet(),
              ),
              _buildProfileOption(
                icon: Icons.security,
                title: 'Privacidad y Seguridad',
                onTap: () => _navigateToPrivacySecurity(),
              ),
              _buildAutoApprovalSetting(),
              _buildGroupAutoApprovalSetting(),
              _buildDarkModeSetting(),
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
    // Feature flag: si premium está desactivado, no mostrar tarjeta
    if (!AppConfigService().premiumEnabled) {
      return const SizedBox.shrink();
    }

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
                  : [Color(0xFF6A1B9A).withValues(alpha: 0.8), Color(0xFF8E24AA).withValues(alpha: 0.8)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Color(0xFF6A1B9A).withValues(alpha: 0.3),
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
                        color: Colors.white.withValues(alpha: 0.2),
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
                            isPremium ? 'Tália ${status.tier.displayName}' : 'Obtén Tália Premium',
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
                                : 'Más face-swaps, sin anuncios, personajes exclusivos',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.9),
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
    int? badge,
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (badge != null && badge > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  badge > 99 ? '99+' : badge.toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            if (badge != null && badge > 0) const SizedBox(width: 8),
            Icon(
              Icons.arrow_forward_ios,
              size: 16,
              color: colorScheme.onSurfaceVariant,
            ),
          ],
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        tileColor: colorScheme.surfaceContainerHighest,
      ),
    );
  }

  Widget _buildAutoApprovalSetting() {
    final colorScheme = Theme.of(context).colorScheme;

    // Return loading state if parent is not yet initialized
    if (_parent == null) {
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
            'Cargando configuración...',
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          trailing: Switch(
            value: false,
            onChanged: null, // Disabled while loading
            activeThumbColor: colorScheme.primary,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          tileColor: colorScheme.surfaceContainerHighest,
        ),
      );
    }

    return StreamBuilder<List<String>>(
      stream: Child.getLinkedChildrenIdsStream(_parent!.id),
      builder: (context, childSnap) {
        final childIds = childSnap.data ?? const <String>[];

        return StreamBuilder<DocumentSnapshot>(
          stream: _parent!.getParentSettingsStream(),
          builder: (context, snapshot) {
            final data = (snapshot.data?.data() as Map<String, dynamic>?) ?? {};
            final globalEnabled = data['autoApproveRequests'] == true;
            final perChild =
                (data['childAutoApproveRequests'] as Map<String, dynamic>?) ?? {};

            bool resolveFor(String id) =>
                perChild.containsKey(id) ? perChild[id] == true : globalEnabled;

            // Un solo hijo (o aún sin datos): switch clásico, comportamiento sin cambios.
            if (childIds.length <= 1) {
              return _buildSettingTile(
                icon: Icons.auto_awesome,
                title: 'Aceptar solicitudes por defecto',
                subtitle: globalEnabled
                    ? 'Las nuevas solicitudes se aprueban automáticamente'
                    : 'Requiere aprobación manual para cada solicitud',
                trailing: Switch(
                  value: globalEnabled,
                  onChanged: _toggleAutoApproval,
                  activeThumbColor: colorScheme.primary,
                ),
              );
            }

            // Más de un hijo: botón que abre el modal de config por hijo.
            final enabledCount = childIds.where(resolveFor).length;
            return _buildSettingTile(
              icon: Icons.auto_awesome,
              title: 'Aceptar solicitudes por defecto',
              subtitle: 'Configurado por hijo · $enabledCount de ${childIds.length} activados',
              trailing: Icon(Icons.arrow_forward_ios,
                  size: 16, color: colorScheme.onSurfaceVariant),
              onTap: () => _openContactPerChildModal(resolveFor),
            );
          },
        );
      },
    );
  }

  /// Tile genérico para los ajustes de aprobación (switch o botón).
  Widget _buildSettingTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget trailing,
    VoidCallback? onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: Icon(icon, color: colorScheme.primary),
        title: Text(
          title,
          style: TextStyle(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
        ),
        trailing: trailing,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        tileColor: colorScheme.surfaceContainerHighest,
      ),
    );
  }

  Future<void> _openContactPerChildModal(bool Function(String) resolveFor) async {
    if (_parent == null) return;
    final children = await Child.getLinkedChildren(_parent!.id);
    if (!mounted) return;
    await PerChildSettingSheet.show(
      context: context,
      title: 'Aceptar solicitudes por defecto',
      description: 'Aprobación automática de contactos, por hijo.',
      icon: Icons.auto_awesome,
      children: children,
      valueFor: resolveFor,
      onChanged: (childId, enabled) =>
          _controller.toggleChildAutoApproval(childId, enabled),
    );
  }

  Widget _buildGroupAutoApprovalSetting() {
    final colorScheme = Theme.of(context).colorScheme;

    if (_parent == null) return const SizedBox.shrink();

    return StreamBuilder<List<String>>(
      stream: Child.getLinkedChildrenIdsStream(_parent!.id),
      builder: (context, childSnap) {
        final childIds = childSnap.data ?? const <String>[];

        return StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('users')
              .doc(_parent!.id)
              .snapshots(),
          builder: (context, snapshot) {
            final data = (snapshot.data?.data() as Map<String, dynamic>?) ?? {};
            final groupSettings =
                (data['groupSettings'] as Map<String, dynamic>?) ?? {};
            // Default ON: solo se desactiva si está explícitamente en false.
            final globalEnabled = groupSettings['autoApproveGroups'] != false;
            final perChild =
                (groupSettings['childAutoApproveGroups'] as Map<String, dynamic>?) ?? {};

            bool resolveFor(String id) => perChild.containsKey(id)
                ? perChild[id] != false
                : globalEnabled;

            // Un solo hijo (o aún sin datos): switch clásico, comportamiento sin cambios.
            if (childIds.length <= 1) {
              return _buildSettingTile(
                icon: Icons.group_add,
                title: 'Aprobar grupos automáticamente',
                subtitle: globalEnabled
                    ? 'Tu hijo se une al grupo y te avisamos. Podés removerlo si querés.'
                    : 'Cada solicitud de grupo requiere tu aprobación manual.',
                trailing: Switch(
                  value: globalEnabled,
                  onChanged: _toggleGroupAutoApproval,
                  activeThumbColor: colorScheme.primary,
                ),
              );
            }

            // Más de un hijo: botón que abre el modal de config por hijo.
            final enabledCount = childIds.where(resolveFor).length;
            return _buildSettingTile(
              icon: Icons.group_add,
              title: 'Aprobar grupos automáticamente',
              subtitle: 'Configurado por hijo · $enabledCount de ${childIds.length} activados',
              trailing: Icon(Icons.arrow_forward_ios,
                  size: 16, color: colorScheme.onSurfaceVariant),
              onTap: () => _openGroupPerChildModal(resolveFor),
            );
          },
        );
      },
    );
  }

  Future<void> _openGroupPerChildModal(bool Function(String) resolveFor) async {
    if (_parent == null) return;
    final children = await Child.getLinkedChildren(_parent!.id);
    if (!mounted) return;
    await PerChildSettingSheet.show(
      context: context,
      title: 'Aprobar grupos automáticamente',
      description: 'Auto-aprobación de grupos, por hijo.',
      icon: Icons.group_add,
      children: children,
      valueFor: resolveFor,
      onChanged: _toggleChildGroupAutoApproval,
    );
  }

  Future<void> _toggleChildGroupAutoApproval(String childId, bool enabled) async {
    final uid = _parent?.id;
    if (uid == null) return;
    await FirebaseFirestore.instance.collection('users').doc(uid).set({
      'groupSettings': {
        'childAutoApproveGroups': {childId: enabled},
      },
    }, SetOptions(merge: true));
  }

  Widget _buildDarkModeSetting() {
    final colorScheme = Theme.of(context).colorScheme;
    final themeService = context.watch<ThemeService>();

    return Container(
      margin: EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          themeService.isDarkMode ? Icons.dark_mode : Icons.light_mode,
          color: colorScheme.primary,
        ),
        title: Text(
          'Modo oscuro',
          style: TextStyle(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w500,
          ),
        ),
        subtitle: Text(
          themeService.isDarkMode
              ? 'Tema oscuro activado'
              : 'Tema claro activado',
          style: TextStyle(
            fontSize: 12,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: Switch(
          value: themeService.isDarkMode,
          onChanged: (enabled) => themeService.toggleDarkMode(enabled),
          activeThumbColor: colorScheme.primary,
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
      MaterialPageRoute(builder: (context) => const SubscriptionScreen()),
    );
  }

  void _navigateToEditProfile() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => EditProfileScreen()),
    );
  }

  void _navigateToWallet() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const WalletScreen()),
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
      // UI updates automatically via StreamBuilder
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

  Future<void> _toggleGroupAutoApproval(bool enabled) async {
    try {
      // Persistir directamente el campo anidado groupSettings.autoApproveGroups
      final uid = _parent?.id;
      if (uid == null) return;
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'groupSettings': {'autoApproveGroups': enabled},
      }, SetOptions(merge: true));
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
        ReleaseLogger.log('Cerrando sesión...', tag: 'ParentProfile');
        await _controller.logout();
        ReleaseLogger.log('Sesión cerrada - AuthWrapper detectará el cambio automáticamente', tag: 'ParentProfile');

        // NO hacer navegación manual - AuthWrapper detectará el signOut
        // y mostrará AuthScreen automáticamente
      } catch (e) {
        ReleaseLogger.error('Error cerrando sesión: $e', tag: 'ParentProfile');
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
