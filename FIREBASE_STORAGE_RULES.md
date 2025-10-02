# Firebase Storage Rules

Para que la funcionalidad de fotos de perfil funcione correctamente, necesitas configurar las siguientes reglas en Firebase Storage:

## Acceso a Firebase Console

1. Ve a [Firebase Console](https://console.firebase.google.com/)
2. Selecciona tu proyecto "Talia"
3. En el menú lateral, ve a "Storage"
4. Pestaña "Rules"

## Reglas Recomendadas

Reemplaza las reglas actuales con las siguientes:

```javascript
rules_version = '2';

service firebase.storage {
  match /b/{bucket}/o {
    // Permitir lectura y escritura de imágenes de perfil para usuarios autenticados
    match /profile_images/{imageId} {
      allow read, write: if request.auth != null;
    }

    // Permitir lectura y escritura en la carpeta test para diagnósticos
    match /test/{testId} {
      allow read, write: if request.auth != null;
    }

    // Denegar todo lo demás por defecto
    match /{allPaths=**} {
      allow read, write: if false;
    }
  }
}
```

## Reglas Más Permisivas (Solo para desarrollo)

Si las reglas anteriores no funcionan, usa estas para empezar (MUY PERMISIVAS - solo para testing):

```javascript
rules_version = '2';

service firebase.storage {
  match /b/{bucket}/o {
    match /{allPaths=**} {
      allow read, write: if true;
    }
  }
}
```

## Reglas de Producción Recomendadas

Una vez que funcione, cambia a estas reglas más seguras:

```javascript
rules_version = '2';

service firebase.storage {
  match /b/{bucket}/o {
    match /profile_images/{imageId} {
      allow read, write: if request.auth != null;
    }

    match /test/{testId} {
      allow read, write: if request.auth != null;
    }

    match /{allPaths=**} {
      allow read, write: if false;
    }
  }
}
```

## Pasos para Aplicar las Reglas

### Opción 1: Empezar con reglas permisivas (para testing)

1. **Copia estas reglas EXACTAMENTE**:
```javascript
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /{allPaths=**} {
      allow read, write: if true;
    }
  }
}
```

2. Ve a Firebase Console > Storage > Rules
3. **BORRA TODO** el contenido actual
4. **PEGA** las reglas de arriba
5. Haz clic en **"Publicar"**

### Opción 2: Si quieres reglas más seguras desde el inicio

1. **Copia estas reglas EXACTAMENTE**:
```javascript
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /profile_images/{imageId} {
      allow read, write: if request.auth != null;
    }
    match /test/{testId} {
      allow read, write: if request.auth != null;
    }
    match /{allPaths=**} {
      allow read, write: if false;
    }
  }
}
```

## Verificación

Después de aplicar las reglas:

1. Guarda las reglas en Firebase Console
2. Espera 2-3 minutos para que se propaguen
3. Prueba subir una imagen de perfil desde la app
4. Verifica en la consola de debug que no hay errores de permisos

## ⚠️ IMPORTANTE

Si usas las reglas permisivas (Opción 1), **CÁMBIALAS** a las reglas seguras (Opción 2) una vez que confirmes que todo funciona.

## Estructura de Archivos

Las imágenes se guardan con la siguiente estructura:
```
profile_images/
  ├── profile_{userId}_{timestamp}.jpg
  ├── profile_{userId}_{timestamp}.jpg
  └── ...
```

## Troubleshooting

Si sigues teniendo errores:

1. Verifica que el proyecto de Firebase esté correctamente configurado
2. Asegúrate de que Storage esté habilitado en tu proyecto
3. Verifica las reglas de Firestore también (pueden interferir)
4. Revisa los logs de Firebase Console para más detalles