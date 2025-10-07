import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../../../models/child.dart';
import 'metric_item.dart';

class ChildMetricsRow extends StatelessWidget {
  final String childId;

  const ChildMetricsRow({
    super.key,
    required this.childId,
  });

  @override
  Widget build(BuildContext context) {
    final auth = FirebaseAuth.instance;
    final child = Child(id: childId, name: ''); // Instancia mínima para usar métodos

    return StreamBuilder<int>(
      stream: child.getUnreadAlertsCountStream(auth.currentUser!.uid),
      builder: (context, alertsSnapshot) {
        final alertsCount = alertsSnapshot.data ?? 0;

        return StreamBuilder<int>(
          stream: child.getContactsCountStream(),
          builder: (context, contactsSnapshot) {
            final contactsCount = contactsSnapshot.data ?? 0;

            return StreamBuilder<int>(
              stream: child.getMessagesCountTodayStream(),
              builder: (context, messagesSnapshot) {
                final messagesTodayCount = messagesSnapshot.data ?? 0;

                return Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      MetricItem(
                        icon: Icons.people,
                        label: 'Contactos',
                        value: contactsCount.toString(),
                      ),
                      MetricItem(
                        icon: Icons.message,
                        label: 'Mensajes Hoy',
                        value: messagesTodayCount.toString(),
                      ),
                      MetricItem(
                        icon: Icons.warning,
                        label: 'Alertas',
                        value: alertsCount.toString(),
                        isAlert: alertsCount > 0,
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}
