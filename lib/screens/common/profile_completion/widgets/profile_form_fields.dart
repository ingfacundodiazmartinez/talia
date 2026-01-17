import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

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
            fillColor: colorScheme.surfaceContainerHighest,
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
            final DateTime? picked = await _showPlatformDatePicker(
              context,
              initialDate: selectedBirthDate ?? DateTime(2000, 1, 1),
            );
            if (picked != null) {
              onBirthDateSelected(picked);
            }
          },
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
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

  /// Muestra el date picker nativo de cada plataforma
  Future<DateTime?> _showPlatformDatePicker(
    BuildContext context, {
    required DateTime initialDate,
  }) async {
    if (Platform.isIOS) {
      // iOS: Usar Cupertino date picker nativo
      DateTime selectedDate = initialDate;

      await showCupertinoModalPopup<void>(
        context: context,
        builder: (BuildContext context) {
          return Container(
            height: 300,
            color: CupertinoColors.systemBackground.resolveFrom(context),
            child: Column(
              children: [
                // Header con botón Done
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text('Cancelar'),
                      ),
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(
                          'Listo',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
                // Date picker
                Expanded(
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.date,
                    initialDateTime: initialDate,
                    minimumDate: DateTime(1924),
                    maximumDate: DateTime.now(),
                    onDateTimeChanged: (DateTime newDate) {
                      selectedDate = newDate;
                    },
                  ),
                ),
              ],
            ),
          );
        },
      );

      return selectedDate;
    } else {
      // Android: Usar Material date picker
      return await showDatePicker(
        context: context,
        initialDate: initialDate,
        firstDate: DateTime(1924),
        lastDate: DateTime.now(),
      );
    }
  }
}
