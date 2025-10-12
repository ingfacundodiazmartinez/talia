# 🐛 Proceso de Reporte de Bugs

## 📋 Cómo Reportar un Bug

### Antes de Reportar

1. **Verifica que sea un bug**
   - ¿El comportamiento es diferente a lo esperado?
   - ¿Es reproducible?
   - ¿Ya fue reportado?

2. **Busca en Issues existentes**
   - [GitHub Issues](https://github.com/tuusuario/talia/issues)
   - Busca palabras clave relacionadas
   - Si existe, comenta en el issue existente

3. **Asegúrate de tener**
   - Versión de la app
   - Versión del OS
   - Modelo del dispositivo
   - Pasos para reproducir

---

## 🎯 Template de Reporte

### Información Básica

```markdown
**Versión de la App:** 1.0.8 (Build 22)
**Plataforma:** iOS 17.2 / Android 14
**Dispositivo:** iPhone 14 Pro / Samsung Galaxy S23
**Fecha:** 2025-01-15

**Descripción Breve:**
[Descripción en una línea del problema]
```

### Descripción Detallada

```markdown
**¿Qué esperabas que pasara?**
[Comportamiento esperado]

**¿Qué pasó en realidad?**
[Comportamiento actual]

**Pasos para Reproducir:**
1. Ir a ...
2. Tocar en ...
3. Hacer ...
4. Ver error

**Frecuencia:**
- [ ] Siempre
- [ ] A veces (especifica frecuencia: __%)
- [ ] Solo una vez

**Severidad:**
- [ ] Crítico (app no funciona)
- [ ] Alto (función principal no funciona)
- [ ] Medio (función menor no funciona)
- [ ] Bajo (cosm ético o menor)
```

### Contexto Adicional

```markdown
**Screenshots/Videos:**
[Adjuntar capturas o videos]

**Logs/Errores:**
```
[Pegar logs relevantes si están disponibles]
```

**¿Intentaste alguna solución?**
[Qué ya probaste]

**Impacto:**
[Cuántos usuarios afecta, qué tan crítico es]
```

---

## 📱 Cómo Obtener Logs

### iOS

```bash
# Desde Mac con dispositivo conectado

1. Abrir Console.app
2. Seleccionar dispositivo
3. Filtrar por "Talia"
4. Reproducir bug
5. Copiar logs relevantes
```

### Android

```bash
# Desde Android Studio o terminal

1. Conectar dispositivo por USB
2. Ejecutar: adb logcat | grep Talia
3. Reproducir bug
4. Copiar output relevante

# O en dispositivo:
Configuración → Acerca del teléfono → Registros
```

---

## 🏷️ Clasificación de Bugs

### Severidad

**🔴 Crítico**
- App crashea al iniciar
- Pérdida de datos
- Vulnerabilidad de seguridad
- Función core completamente rota

**🟠 Alto**
- Función principal no funciona
- Afecta a mayoría de usuarios
- No hay workaround
- Bloquea flujos importantes

**🟡 Medio**
- Función menor no funciona
- Afecta a algunos usuarios
- Hay workaround
- Molestia menor

**🟢 Bajo**
- Problema cosmético
- Afecta a pocos usuarios
- Fácil de evitar
- Mejora nice-to-have

### Tipos

- **Bug**: Comportamiento incorrecto
- **Crash**: App se cierra inesperadamente
- **Performance**: Lentitud o lag
- **UI**: Problema de interfaz
- **Network**: Problemas de conexión
- **Data**: Problemas con datos o almacenamiento

---

## 🔄 Ciclo de Vida de un Bug

### 1. Nuevo (New)
- Bug reportado
- Pendiente de triaje
- No asignado

### 2. Confirmado (Confirmed)
- Bug verificado
- Reproducible
- Asignado a desarrollador

### 3. En Progreso (In Progress)
- Desarrollador trabajando
- Fix en desarrollo

### 4. Resuelto (Fixed)
- Fix completado
- Pendiente de deploy

### 5. Testing (Testing)
- En testing/QA
- Verificando fix

### 6. Cerrado (Closed)
- Fix desplegado
- Verificado funciona
- Issue cerrado

### Estados Especiales

- **Duplicado (Duplicate)**: Ya existe issue
- **No Reproducible (Cannot Reproduce)**: No se puede replicar
- **Por Diseño (As Designed)**: Comportamiento intencional
- **No se Arreglará (Won't Fix)**: Fuera de scope o prioridad

---

## 🚨 Bugs Críticos

### Proceso Expedito

Para bugs críticos (crashes, seguridad, pérdida de datos):

1. **Reportar inmediatamente**
   - Email: security@talia-app.com (seguridad)
   - Email: support@talia-app.com (otros críticos)
   - GitHub Issue con label [CRITICAL]

2. **Información mínima requerida**
   - Pasos para reproducir
   - Stack trace si está disponible
   - Versión exacta

3. **Timeline esperado**
   - Acknowledgment: 2 horas
   - Triaje: 4 horas
   - Fix: 24-48 horas
   - Deploy: Tan pronto como posible

---

## 📊 Reportes de Crashlytics

### Cómo Interpretar

En Firebase Console → Crashlytics:

```
Crash #1234
iPhone 14 Pro, iOS 17.2
Version 1.0.8 (22)

Fatal Exception: NSInvalidArgumentException
...

Usuarios afectados: 50
Ocurrencias: 125
```

**Información clave:**
- Número de usuarios afectados
- Frecuencia
- Stack trace
- Versión y OS

### Priorización

1. Usuarios afectados > 10%: Crítico
2. Usuarios afectados 5-10%: Alto
3. Usuarios afectados 1-5%: Medio
4. Usuarios afectados < 1%: Bajo

---

## 🧪 Testing de Fixes

### Checklist de Verificación

- [ ] Bug ya no ocurre
- [ ] Pasos originales no reproducen el problema
- [ ] No hay regresiones (bugs nuevos)
- [ ] Tests automatizados pasan
- [ ] Probado en múltiples dispositivos/OS
- [ ] Probado en diferentes condiciones de red

### Testing Adicional

- **Edge cases**: Probar escenarios extremos
- **Performance**: Verificar que el fix no afecta rendimiento
- **UX**: Asegurar buena experiencia de usuario

---

## 📝 Template Completo de Issue

```markdown
## Bug Report

### Información del Sistema
- **App Version:** 1.0.8 (Build 22)
- **OS:** iOS 17.2
- **Device:** iPhone 14 Pro
- **Network:** WiFi / 4G / 5G
- **Date:** 2025-01-15 14:30 UTC

### Descripción
[Descripción clara y concisa del bug]

### Comportamiento Esperado
[Qué debería pasar]

### Comportamiento Actual
[Qué está pasando]

### Pasos para Reproducir
1. Abrir la app
2. Ir a ...
3. Tocar ...
4. Observar ...

### Frecuencia
- [ ] Siempre (100%)
- [x] Frecuente (>50%)
- [ ] Ocasional (<50%)
- [ ] Raro (ocurrió una vez)

### Severidad
- [ ] 🔴 Crítico - App inutilizable
- [x] 🟠 Alto - Función principal afectada
- [ ] 🟡 Medio - Función menor afectada
- [ ] 🟢 Bajo - Cosmético o menor

### Categoría
- [x] Crash
- [ ] Bug funcional
- [ ] UI/UX
- [ ] Performance
- [ ] Network
- [ ] Data

### Screenshots/Videos
[Drag and drop aquí]

### Logs
```
[Pegar logs relevantes]
```

### Context Adicional
- ¿Comenzó después de una actualización? [Sí/No]
- ¿Pasa en otras cuentas? [Sí/No/No probado]
- ¿Workaround disponible? [Descripción]

### Impacto Estimado
- **Usuarios afectados:** [Número o porcentaje]
- **Bloqueante:** [Sí/No]
- **Datos en riesgo:** [Sí/No]

### Intentos de Solución
- Reiniciar app: [Funciona/No funciona]
- Reinstalar app: [Funciona/No funciona]
- Limpiar cache: [Funciona/No funciona]
- Otro: [Descripción]
```

---

## 🎯 Mejores Prácticas

### Para Reportar

✅ **SÍ:**
- Se específico y descriptivo
- Incluye pasos detallados
- Adjunta screenshots/videos
- Menciona workarounds si existen
- Usa el template
- Busca duplicados primero

❌ **NO:**
- Reportes vagos ("no funciona")
- Sin información de sistema
- Múltiples bugs en un issue
- Lenguaje ofensivo
- Demandas o ultimátums

### Para Desarrolladores

✅ **SÍ:**
- Responde rápido (< 24h)
- Pide clarificaciones si necesario
- Actualiza estado del issue
- Explica el problema y la solución
- Cierra issues cuando se resuelvan

❌ **NO:**
- Ignorar reports
- Cerrar sin explicación
- Ser defensivo
- Culpar al usuario

---

## 📧 Contacto

### Bugs Generales
- **GitHub Issues**: Método preferido
- **Email**: support@talia-app.com
- **Response time**: 24-48 horas

### Bugs de Seguridad
- **Email**: security@talia-app.com
- **Response time**: 2-4 horas
- **No publicar** en GitHub hasta que se resuelva

### Bugs Críticos
- **Email**: support@talia-app.com
- **Subject**: [CRITICAL] Descripción breve
- **Response time**: 2-8 horas

---

## 🏆 Reconocimientos

Agradecemos a quienes reportan bugs con información detallada y útil. Los mejores reporters pueden ser mencionados en release notes (con su consentimiento).

---

## 📚 Recursos

- [Crashlytics Dashboard](https://console.firebase.google.com/project/talia/crashlytics)
- [GitHub Issues](https://github.com/tuusuario/talia/issues)
- [Testing Guide](./TESTING.md)
- [Contributing Guide](./CONTRIBUTING.md)

---

**Última actualización:** Enero 2025

**¿Preguntas?** Contacta support@talia-app.com
