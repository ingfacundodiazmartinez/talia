import 'package:flutter/material.dart';

class ProfileFormFields extends StatelessWidget {
  final TextEditingController nameController;
  final DateTime? selectedBirthDate;
  final String phoneNumber;
  final Function(DateTime) onBirthDateSelected;
  final int Function(DateTime) calculateAge;

  const ProfileFormFields({
    super.key,
    required this.nameController,
    required this.selectedBirthDate,
    required this.phoneNumber,
    required this.onBirthDateSelected,
    required this.calculateAge,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        // Name Field
        TextFormField(
          controller: nameController,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: 'Nombre',
            prefixIcon: Icon(
              Icons.person_outline,
              color: colorScheme.primary,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            filled: true,
            fillColor: colorScheme.surfaceVariant,
          ),
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return 'Por favor ingresa tu nombre';
            }
            if (value.trim().length < 2) {
              return 'El nombre debe tener al menos 2 caracteres';
            }
            return null;
          },
        ),

        SizedBox(height: 16),

        // Birth Date Field
        InkWell(
          onTap: () async {
            final DateTime? picked = await showDatePicker(
              context: context,
              initialDate: selectedBirthDate ?? DateTime(2000, 1, 1),
              firstDate: DateTime(1924),
              lastDate: DateTime.now(),
            );
            if (picked != null) {
              onBirthDateSelected(picked);
            }
          },
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceVariant,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.cake_outlined,
                  color: colorScheme.primary,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    selectedBirthDate == null
                        ? 'Fecha de nacimiento'
                        : '${selectedBirthDate!.day}/${selectedBirthDate!.month}/${selectedBirthDate!.year}',
                    style: TextStyle(
                      fontSize: 16,
                      color: selectedBirthDate == null
                          ? colorScheme.onSurfaceVariant
                          : colorScheme.onSurface,
                    ),
                  ),
                ),
                if (selectedBirthDate != null)
                  Text(
                    '(${calculateAge(selectedBirthDate!)} años)',
                    style: TextStyle(
                      fontSize: 14,
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ),

        SizedBox(height: 16),

        // Phone Number Display (read-only)
        Container(
          padding: EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.green.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.green.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.check_circle,
                color: Colors.green[700],
                size: 20,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Teléfono verificado: $phoneNumber',
                  style: TextStyle(
                    color: Colors.green[700],
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
