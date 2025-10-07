import 'package:flutter/material.dart';
import '../../../../models/child.dart';
import '../../../../theme_service.dart';
import '../../../child_location_screen.dart';
import 'child_metrics_row.dart';

class ChildDashboardCard extends StatelessWidget {
  final String childId;

  const ChildDashboardCard({
    super.key,
    required this.childId,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Child?>(
      future: Child.getById(childId),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data == null) {
          return SizedBox.shrink();
        }

        final child = snapshot.data!;

        return Container(
          margin: EdgeInsets.only(bottom: 16),
          padding: EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                context.customColors.gradientStart,
                context.customColors.gradientEnd,
              ],
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                blurRadius: 12,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: Colors.white.withValues(alpha: 0.3),
                    backgroundImage:
                        child.photoURL != null ? NetworkImage(child.photoURL!) : null,
                    child: child.photoURL == null
                        ? Text(
                            child.initials,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                            ),
                          )
                        : null,
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          child.name,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '${child.age} años',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.white.withValues(alpha: 0.9),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.location_on, color: Colors.white),
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ChildLocationScreen(
                            childId: child.id,
                            childName: child.name,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
              SizedBox(height: 20),
              Divider(color: Colors.white.withValues(alpha: 0.3), thickness: 1),
              SizedBox(height: 16),
              ChildMetricsRow(childId: child.id),
            ],
          ),
        );
      },
    );
  }
}
