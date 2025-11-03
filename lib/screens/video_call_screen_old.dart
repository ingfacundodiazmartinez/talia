import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import '../controllers/video_call_controller.dart';

class VideoCallScreen extends StatefulWidget {
  final String callId;
  final String? channelName;  // Opcional para lógica optimista
  final String? token;  // Opcional para lógica optimista
  final int? uid;  // Opcional para lógica optimista
  final bool isCaller;
  final String remoteName;
  final String receiverId;  // Para iniciar llamada en background
  final bool isVideo;  // Para saber si es video o audio

  const VideoCallScreen({
    super.key,
    required this.callId,
    this.channelName,
    this.token,
    this.uid,
    required this.isCaller,
    required this.remoteName,
    required this.receiverId,
    required this.isVideo,
  });

  @override
  State<VideoCallScreen> createState() => _VideoCallScreenState();
}

class _VideoCallScreenState extends State<VideoCallScreen> {
  // ✅ CORRECTO: Solo controller y estado UI local
  late VideoCallController _controller;

  // Estado UI únicamente (ninguno actualmente necesario)

  @override
  void initState() {
    super.initState();

    // ✅ CORRECTO: Solo inicializar controller y configurar callbacks
    _controller = VideoCallController(
      callId: widget.callId,
      channelName: widget.channelName,
      token: widget.token,
      uid: widget.uid,
      isCaller: widget.isCaller,
      remoteName: widget.remoteName,
      receiverId: widget.receiverId,
      isVideo: widget.isVideo,
    );

    // Configurar callbacks para comunicación controller → screen
    _setupControllerCallbacks();

    // Inicializar controller
    _controller.initialize();
  }

  /// Configurar callbacks del controller para actualizar UI
  void _setupControllerCallbacks() {
    _controller.onConnectionStatusChanged = (status) {
      if (mounted) {
        setState(() {
          // Trigger rebuild para estado de conexión
        });
      }
    };

    _controller.onCallEnded = () {
      if (mounted) {
        Navigator.pop(context);
      }
    };

    _controller.onError = (message) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    };

    _controller.onRemoteUserJoined = (uid) {
      if (mounted) {
        setState(() {
          // Trigger rebuild para usuario remoto
        });
      }
    };

    _controller.onRemoteUserLeft = (uid) {
      if (mounted) {
        setState(() {
          // Trigger rebuild para usuario remoto
        });
      }
    };
  }

  /// Inicializar la llamada con lógica optimista
  Future<void> _initializeCall() async {
    try {
      ReleaseLogger.log('▶️ Iniciando _initializeCall - isCaller: ${widget.isCaller}, hasToken: ${_token != null}, hasChannelName: ${_channelName != null}', tag: 'VideoCall');

      // Paso 0: Solo solicitar permisos si somos el CALLER y estamos en Android
      // En iOS, Agora pedirá los permisos automáticamente al acceder a la cámara/micrófono
      // El receiver (que viene de background/CallKit) ya tiene permisos o los pedirá al aceptar
      if (widget.isCaller && Platform.isAndroid) {
        ReleaseLogger.log('📱 Solicitando permisos de cámara/micrófono...', tag: 'VideoCall');
        await _requestPermissions();
      } else {
        print('📱 [iOS/Receiver] Saltando verificación manual de permisos');
      }

      // Paso 1: Si es caller y no hay token/uid, obtener credenciales
      if (widget.isCaller && (_token == null || _uid == null)) {
        ReleaseLogger.log('📱 [Optimistic] Iniciando llamada en background...', tag: 'VideoCall');
        setState(() {
          _connectionStatus = 'Conectando...';
        });

        // Si ya tenemos channelName (ej: emergencia), solo generar token
        if (_channelName != null) {
          ReleaseLogger.log('📱 [Emergency] Channel ya existe: $_channelName, generando token...', tag: 'VideoCall');

          final functions = FirebaseFunctions.instance;
          final result = await functions.httpsCallable('generateAgoraToken').call({
            'channelName': _channelName,
            'uid': 0,
          });

          setState(() {
            _token = result.data['token'] as String;
            _uid = result.data['uid'] as int;
            _connectionStatus = 'Llamando...';
          });

          ReleaseLogger.success('[Emergency] Token generado: uid=$_uid', tag: 'VideoCall');

          // ✅ Para emergencias, el callId ya está establecido, iniciar listener
          _listenToCallStatus();
        } else {
          // Caso normal: iniciar llamada completa
          ReleaseLogger.log('📞 Llamando a initiateCall...', tag: 'VideoCall');
          final result = await _videoCallService.initiateCall(
            receiverId: widget.receiverId,
            receiverName: widget.remoteName,
            isVideo: widget.isVideo,
          );

          ReleaseLogger.log('📞 initiateCall result: ${result.toString()}', tag: 'VideoCall');

          if (result['success'] != true) {
            ReleaseLogger.error('❌ initiateCall falló: ${result['error']}', tag: 'VideoCall');
            throw Exception(result['error'] ?? 'Error iniciando llamada');
          }

          // Actualizar datos de llamada
          if (mounted) {
            setState(() {
              _realCallId = result['callId']; // ✅ Actualizar con el callId real de Firestore
              _channelName = result['channelName'];
              _token = result['token'];
              _uid = result['uid'];
              _connectionStatus = 'Llamando...';
            });
          }

          ReleaseLogger.success('[Optimistic] Datos de llamada obtenidos: callId=$_realCallId, channel=$_channelName, uid=$_uid', tag: 'VideoCall');

          // Verificar si se terminó la llamada durante initiateCall
          if (_isEnding || !mounted) {
            print('⏭️ [VideoCallScreen] Llamada terminada durante initiateCall - cancelando documento en Firestore');

            // IMPORTANTE: Si el usuario canceló antes de que termine initiateCall,
            // ahora tenemos el callId real y debemos cancelarlo en Firestore
            if (_realCallId != null) {
              print('📵 [VideoCallScreen] Cancelando documento real: $_realCallId');
              await _videoCallService.endCall(_realCallId!).catchError((e) {
                print('⚠️ [VideoCallScreen] Error cancelando documento: $e');
              });
            }
            return;
          }

          // ✅ Ahora que tenemos el callId real, iniciar el listener
          _listenToCallStatus();
        }
      } else {
        // Si NO somos caller, el callId ya es correcto, iniciar listener
        ReleaseLogger.log('📱 [Receiver] Usando callId del constructor: $_realCallId', tag: 'VideoCall');
        _listenToCallStatus();
      }

      // Paso 2: Inicializar Agora con el tipo correcto de llamada
      await _videoCallService.initializeAgora(isVideo: widget.isVideo);

      // Verificar si se terminó la llamada durante la inicialización de Agora
      if (_isEnding || !mounted) {
        print('⏭️ [VideoCallScreen] Llamada terminada durante inicialización de Agora - cancelando');
        return;
      }

      // Paso 3: Configurar event handlers
      _videoCallService.engine?.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (RtcConnection connection, int elapsed) async {
            print('✅ Unido al canal: ${connection.channelId}');
            print('✅ UID local asignado: ${connection.localUid}');
            if (mounted) {
              setState(() {
                _isJoined = true;
                _localUid = connection.localUid;

                // Detectar si es llamada grupal basándose en el documento
                _checkIfGroupCall().then((isGroupCall) {
                  if (mounted) {
                    setState(() {
                      // Para llamadas grupales, siempre mostrar "Conectado" cuando nos unimos exitosamente
                      // Para llamadas 1:1, el caller muestra "Llamando..." hasta que el receptor se una
                      if (isGroupCall || !widget.isCaller) {
                        _connectionStatus = 'Conectado';
                      } else {
                        _connectionStatus = 'Llamando...';
                      }
                    });
                  }
                });
              });
            }

            // ✅ Iniciar preview y forzar rebuild del widget de video local
            if (widget.isVideo) {
              try {
                await _videoCallService.engine?.startPreview();
                print('✅ Preview iniciado después de joinChannel');

                // Pequeño delay para asegurar que la cámara esté capturando
                await Future.delayed(const Duration(milliseconds: 100));

                // Forzar setState para reconstruir el widget de video local
                if (mounted) {
                  setState(() {
                    // Este setState fuerza al AgoraVideoView a re-montarse
                    // después de que el preview ya está corriendo
                  });
                  print('✅ Widget de video local reconstruido');
                }
              } catch (e) {
                print('⚠️ Error iniciando preview: $e');
              }
            }
          },
          onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
            print('👤 Usuario remoto unido: $remoteUid');
            setState(() {
              _remoteUids.add(remoteUid);
              _connectionStatus = 'Conectado';
            });
          },
          onUserOffline: (RtcConnection connection, int remoteUid, UserOfflineReasonType reason) {
            print('👋 Usuario remoto desconectado: $remoteUid');
            print('   Razón: $reason');

            if (!mounted) {
              print('⚠️ [VideoCallScreen] Widget ya disposed - ignorando onUserOffline');
              return;
            }

            setState(() {
              _remoteUids.remove(remoteUid);
            });

            if (_remoteUids.isEmpty && !_isEnding) {
              print('📵 [VideoCallScreen] Usuario remoto desconectado y lista vacía - terminando llamada');
              _endCall();
            }
          },
          onError: (ErrorCodeType err, String msg) {
            print('❌ Error de Agora: $err - $msg');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Error en la llamada: $msg'),
                  backgroundColor: Colors.red,
                ),
              );
            }
          },
        ),
      );

      // Paso 4: Salir del canal anterior si existe (evitar error -17)
      await _videoCallService.leaveChannel();

      // Paso 5: Unirse al canal (esperar a tener todos los datos)
      // ⚠️ IMPORTANTE: Verificar que no se haya terminado la llamada mientras se inicializaba
      // Este check es CRÍTICO porque ocurre después de todas las operaciones async
      if (_isEnding || !mounted) {
        print('⏭️ [VideoCallScreen] Llamada terminada durante inicialización - cancelando joinChannel');
        return;
      }

      if (_channelName != null && _token != null && _uid != null) {
        await _videoCallService.joinChannel(
          channelName: _channelName!,
          token: _token!,
          uid: _uid!,
          isVideo: widget.isVideo, // ✅ Pasar tipo de llamada (video o audio)
        );
        print('🚀 Llamada inicializada exitosamente');
      } else {
        throw Exception('Faltan datos de llamada (channel, token, o uid)');
      }
    } catch (e, stackTrace) {
      print('❌ Error inicializando llamada: $e');
      ReleaseLogger.error('❌ Error en _initializeCall', error: e, stackTrace: stackTrace, tag: 'VideoCall');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al iniciar la llamada: $e'),
            backgroundColor: Colors.red,
          ),
        );
        Navigator.pop(context);
      }
    }
  }

  /// Escuchar cambios en el estado de la llamada
  void _listenToCallStatus() {
    if (_realCallId == null) {
      print('⚠️ [VideoCallScreen] No hay callId para escuchar');
      return;
    }

    print('🔍 [VideoCallScreen] Iniciando listener para callId: $_realCallId');
    _callStatusSubscription = _videoCallService.watchCallStatus(_realCallId!).listen((snapshot) {
      if (!mounted) return; // No procesar si el widget ya fue disposed

      print('🔍 [VideoCallScreen] Snapshot recibido para callId: $_realCallId');
      print('🔍 [VideoCallScreen] Snapshot existe: ${snapshot.exists}');

      // Si el documento fue eliminado, cerrar la pantalla
      if (!snapshot.exists) {
        print('📵 [VideoCallScreen] Documento eliminado - cerrando pantalla');
        if (!_isEnding && mounted) {
          _isEnding = true;
          Navigator.of(context).pop();
        }
        return;
      }

      final data = snapshot.data() as Map<String, dynamic>;
      final status = data['status'];

      print('🔍 [VideoCallScreen] Status detectado: $status');

      // Si la llamada terminó, fue rechazada o cancelada → cerrar la pantalla
      // dispose() se encargará del cleanup
      if ((status == 'ended' || status == 'rejected' || status == 'cancelled') && !_isEnding) {
        print('⚠️ [VideoCallScreen] Status es $status - cerrando pantalla');
        print('   mounted: $mounted');
        print('   _isEnding antes: $_isEnding');
        _isEnding = true;
        if (mounted) {
          print('🚪 [VideoCallScreen] Ejecutando Navigator.pop() desde listener');
          Navigator.of(context).pop();
        } else {
          print('❌ [VideoCallScreen] Widget no mounted - no se puede hacer pop()');
        }
      } else if ((status == 'ended' || status == 'rejected' || status == 'cancelled')) {
        print('⏭️ [VideoCallScreen] Status es $status pero _isEnding ya es true - omitiendo');
      }
    });
  }

  /// Solicitar permisos de cámara y micrófono
  Future<void> _requestPermissions() async {
    try {
      print('🔐 Solicitando permisos de cámara y micrófono...');

      // Verificar estado actual de los permisos
      final cameraStatus = await Permission.camera.status;
      final micStatus = await Permission.microphone.status;

      print('📷 Estado inicial cámara: $cameraStatus');
      print('🎤 Estado inicial micrófono: $micStatus');

      // Si ya están concedidos, no hacer nada
      if (cameraStatus.isGranted && micStatus.isGranted) {
        print('✅ Permisos ya concedidos');
        return;
      }

      // Si están denegados permanentemente, mostrar diálogo para ir a configuración
      if (cameraStatus.isPermanentlyDenied || micStatus.isPermanentlyDenied) {
        await _showPermissionSettingsDialog();
        throw Exception('Permisos denegados permanentemente');
      }

      // Solicitar permisos al sistema operativo
      print('📱 Solicitando permisos al sistema...');
      final statuses = await [
        Permission.camera,
        Permission.microphone,
      ].request();

      final newCameraStatus = statuses[Permission.camera]!;
      final newMicStatus = statuses[Permission.microphone]!;

      print('📷 Permiso de cámara después de solicitar: $newCameraStatus');
      print('🎤 Permiso de micrófono después de solicitar: $newMicStatus');

      // Verificar si se concedieron los permisos
      if (!newCameraStatus.isGranted || !newMicStatus.isGranted) {
        if (newCameraStatus.isPermanentlyDenied || newMicStatus.isPermanentlyDenied) {
          await _showPermissionSettingsDialog();
          throw Exception('Permisos denegados permanentemente');
        }

        // Usuario rechazó el diálogo de permisos
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Se requieren permisos de cámara y micrófono para videollamadas'),
              backgroundColor: Colors.red,
            ),
          );
          Navigator.pop(context);
        }
        throw Exception('Permisos no concedidos');
      }

      print('✅ Permisos concedidos correctamente');
    } catch (e) {
      print('❌ Error solicitando permisos: $e');
      rethrow;
    }
  }

  /// Mostrar diálogo para abrir configuración de permisos
  Future<void> _showPermissionSettingsDialog() async {
    if (!mounted) return;

    final shouldOpenSettings = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Permisos Requeridos'),
        content: const Text(
          'Esta app necesita acceso a la cámara y micrófono para realizar videollamadas. '
          'Por favor, habilita los permisos en la configuración del dispositivo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Abrir Configuración'),
          ),
        ],
      ),
    );

    if (shouldOpenSettings == true) {
      await openAppSettings();
    }

    if (mounted) {
      Navigator.pop(context);
    }
  }

  /// Toggle micrófono
  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
    });
    _videoCallService.toggleMute();
  }

  /// Toggle cámara
  Future<void> _toggleCamera() async {
    // Actualizar estado local primero para respuesta inmediata en UI
    setState(() {
      _isCameraOff = !_isCameraOff;
    });

    try {
      // Ejecutar toggle en el servicio
      await _videoCallService.toggleCamera();

      // Forzar reconstrucción del widget después de un pequeño delay
      // para asegurar que Agora ha actualizado el estado interno
      await Future.delayed(const Duration(milliseconds: 100));

      if (mounted) {
        setState(() {
          // Sincronizar con el estado real del servicio
          _isCameraOff = _videoCallService.isCameraOff;
        });
        print('🔄 Estado de cámara sincronizado: $_isCameraOff');
      }
    } catch (e) {
      print('❌ Error en toggle camera: $e');
      // Revertir estado local si hay error
      if (mounted) {
        setState(() {
          _isCameraOff = !_isCameraOff;
        });
      }
    }
  }

  /// Cambiar cámara (frontal/trasera)
  void _switchCamera() {
    _videoCallService.switchCamera();
  }

  /// Mostrar diálogo para invitar a más personas
  Future<void> _showInviteDialog() async {
    try {
      final currentUserId = FirebaseAuth.instance.currentUser?.uid;
      if (currentUserId == null) return;

      // ✅ Obtener contactos aprobados desde la colección contacts
      final contactsSnapshot = await FirebaseFirestore.instance
          .collection('contacts')
          .where('users', arrayContains: currentUserId)
          .where('status', isEqualTo: 'approved')
          .get();

      if (!mounted) return;

      // Procesar contactos para obtener los datos de usuario
      final List<Map<String, dynamic>> contactsList = [];

      for (final doc in contactsSnapshot.docs) {
        final data = doc.data();
        final users = List<String>.from(data['users'] ?? []);

        // Obtener el ID del otro usuario (no el actual)
        final contactId = users.firstWhere(
          (id) => id != currentUserId,
          orElse: () => '',
        );

        if (contactId.isEmpty) continue;

        // Excluir al usuario con el que ya estamos en llamada
        if (contactId == widget.receiverId) continue;

        // Obtener datos del contacto
        try {
          final userDoc = await FirebaseFirestore.instance
              .collection('users')
              .doc(contactId)
              .get();

          if (userDoc.exists) {
            final userData = userDoc.data()!;
            contactsList.add({
              'id': contactId,
              'name': userData['name'] ?? 'Usuario',
              'photoURL': userData['photoURL'],
            });
          }
        } catch (e) {
          print('⚠️ Error obteniendo datos del contacto $contactId: $e');
        }
      }

      if (!mounted) return;

      // Mostrar diálogo con lista de contactos
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.grey[900],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Container(
            constraints: const BoxConstraints(maxHeight: 500),
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Título
                Row(
                  children: [
                    const Icon(Icons.person_add, color: Colors.white),
                    const SizedBox(width: 8),
                    const Text(
                      'Invitar a la llamada',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const Divider(color: Colors.white24),
                const SizedBox(height: 8),

                // Lista de contactos
                Flexible(
                  child: contactsList.isEmpty
                      ? const Center(
                          child: Text(
                            'No tienes contactos disponibles',
                            style: TextStyle(color: Colors.white70),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: contactsList.length,
                          itemBuilder: (context, index) {
                            final contact = contactsList[index];
                            final contactId = contact['id'] as String;
                            final contactName = contact['name'] as String;
                            final contactPhotoURL = contact['photoURL'] as String?;

                            return ListTile(
                              leading: CircleAvatar(
                                backgroundImage: contactPhotoURL != null
                                    ? NetworkImage(contactPhotoURL)
                                    : null,
                                child: contactPhotoURL == null
                                    ? Text(
                                        contactName[0].toUpperCase(),
                                        style: const TextStyle(color: Colors.white),
                                      )
                                    : null,
                              ),
                              title: Text(
                                contactName,
                                style: const TextStyle(color: Colors.white),
                              ),
                              trailing: const Icon(
                                Icons.add_circle_outline,
                                color: Colors.green,
                              ),
                              onTap: () async {
                                Navigator.pop(context); // Cerrar diálogo
                                await _inviteUserToCall(contactId, contactName);
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      print('❌ Error mostrando diálogo de invitación: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al cargar contactos: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Invitar a un usuario a la llamada actual
  Future<void> _inviteUserToCall(String userId, String userName) async {
    try {
      print('📞 Invitando a $userName a la llamada...');

      // Mostrar loading
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invitando a $userName...'),
            duration: const Duration(seconds: 2),
          ),
        );
      }

      // Usar VideoCallService para enviar la invitación
      final result = await _videoCallService.inviteToOngoingCall(
        callId: _realCallId ?? widget.callId, // Usar callId real o fallback
        channelName: _channelName ?? _realCallId ?? widget.callId, // Usar state local o fallback
        invitedUserId: userId,
        invitedUserName: userName,
      );

      if (mounted) {
        if (result['success'] != true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result['error'] ?? 'Error al invitar'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      print('❌ Error invitando a usuario: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error al enviar invitación'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Verificar si la llamada actual es una llamada grupal
  Future<bool> _checkIfGroupCall() async {
    try {
      if (_realCallId == null) return false;

      final callDoc = await FirebaseFirestore.instance
          .collection('video_calls')
          .doc(_realCallId!)
          .get();

      if (callDoc.exists) {
        final data = callDoc.data() as Map<String, dynamic>;
        return data['isGroupCall'] == true;
      }
    } catch (e) {
      print('❌ Error verificando si es llamada grupal: $e');
    }

    return false;
  }

  /// Terminar la llamada
  /// PATRÓN SIMPLIFICADO (siguiendo ejemplo oficial de Agora):
  /// - Actualiza Firestore para notificar al otro usuario
  /// - Cierra la pantalla con Navigator.pop()
  /// - El cleanup se hace automáticamente en dispose()
  Future<void> _endCall() async {
    if (_isEnding) return; // Evitar múltiples llamadas
    _isEnding = true;

    try {
      final callIdToEnd = _realCallId ?? widget.callId;
      print('📵 [VideoCallScreen] Terminando llamada: $callIdToEnd');

      // IMPORTANTE: Solo actualizar Firestore si tenemos el callId real
      // Si aún tenemos el callId temporal (timestamp), significa que la llamada
      // nunca se creó en Firestore y no hay nada que cancelar
      final isTemporaryCallId = callIdToEnd == widget.callId && widget.isCaller && _realCallId == null;

      if (isTemporaryCallId) {
        print('⏭️ [VideoCallScreen] CallId temporal - la llamada no se creó en Firestore aún');
        print('⏭️ [VideoCallScreen] No hay nada que cancelar, solo cerrar pantalla');
      } else {
        // 1. Actualizar Firestore para notificar al otro usuario
        await _videoCallService.endCall(callIdToEnd);
        print('✅ [VideoCallScreen] Firestore actualizado');
      }

      // 2. Cerrar pantalla - el cleanup se hará en dispose()
      if (mounted) {
        print('🚪 [VideoCallScreen] Cerrando pantalla - dispose() hará el cleanup');
        Navigator.of(context).pop();
      }
    } catch (e) {
      print('❌ [VideoCallScreen] Error terminando llamada: $e');
      // Intentar cerrar pantalla de todos modos
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  void dispose() {
    print('🗑️ [VideoCallScreen] Disposing - iniciando cleanup');

    // Siguiendo el patrón oficial de Agora:
    // 1. Cancelar listeners
    _callStatusSubscription?.cancel();
    print('✅ [VideoCallScreen] Listeners cancelados');

    // 2. Cerrar CallKit
    final callIdToEnd = _realCallId ?? widget.callId;
    if (Platform.isIOS) {
      VoIPService().notifyCallEnded(callIdToEnd).catchError((e) {
        print('⚠️ [VideoCallScreen] Error cerrando VoIP: $e');
      });
    } else if (Platform.isAndroid) {
      CallKitService().endCall(callIdToEnd).catchError((e) {
        print('⚠️ [VideoCallScreen] Error cerrando CallKit: $e');
      });
    }
    print('✅ [VideoCallScreen] CallKit cerrado');

    // 3. Salir del canal de Agora (sin await en dispose)
    _videoCallService.leaveChannel().catchError((e) {
      print('⚠️ [VideoCallScreen] Error en leaveChannel: $e');
    });
    print('✅ [VideoCallScreen] leaveChannel ejecutado');

    super.dispose();
    print('✅ [VideoCallScreen] Dispose completado');
  }

  @override
  Widget build(BuildContext context) {
    // Determinar si es llamada grupal (más de 1 participante remoto)
    bool isGroupCall = _remoteUids.length > 1;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Mostrar layout según tipo de llamada
          if (isGroupCall)
            _groupCallLayout()
          else
            _oneToOneCallLayout(),

          // Indicador de conexión optimista
          if (_connectionStatus != 'Conectado')
            Center(
              child: Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _connectionStatus, // 'Conectando...' o 'Llamando...'
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Nombre del contacto (solo para llamadas 1:1)
          if (!isGroupCall)
            Positioned(
              top: 50,
              left: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  widget.remoteName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

          // Contador de participantes (solo para llamadas grupales)
          if (isGroupCall)
            Positioned(
              top: 50,
              left: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.people, color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      '${_remoteUids.length + 1} participantes',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // Controles de llamada
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: _callControls(),
          ),
        ],
      ),
    );
  }

  /// Layout para llamadas 1:1
  Widget _oneToOneCallLayout() {
    return Stack(
      children: [
        // Video remoto (pantalla completa)
        _remoteVideo(),

        // Video local (esquina superior derecha)
        Positioned(
          top: 50,
          right: 16,
          child: _localVideoPreview(),
        ),
      ],
    );
  }

  /// Layout para llamadas grupales (grid)
  Widget _groupCallLayout() {
    // Incluir UID local en la lista de participantes
    List<int?> allParticipants = [_localUid, ..._remoteUids];

    // Calcular número de columnas según cantidad de participantes
    int participantCount = allParticipants.length;
    int columns = participantCount <= 2 ? 1 : 2;

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        childAspectRatio: 0.75,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: participantCount,
      itemBuilder: (context, index) {
        final uid = allParticipants[index];
        bool isLocal = uid == _localUid;

        return Container(
          decoration: BoxDecoration(
            color: Colors.grey[900],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isLocal ? Colors.blue : Colors.white.withOpacity(0.3),
              width: 2,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              children: [
                // Video del participante
                if (uid != null && _videoCallService.engine != null)
                  isLocal
                      ? (_isCameraOff
                          ? const Center(
                              child: Icon(Icons.videocam_off,
                                  color: Colors.white, size: 40),
                            )
                          : AgoraVideoView(
                              key: ValueKey('local_video_group_${!_isCameraOff}'),
                              controller: VideoViewController(
                                rtcEngine: _videoCallService.engine!,
                                canvas: const VideoCanvas(uid: 0),
                              ),
                            ))
                      : (_channelName == null || _channelName!.isEmpty
                          ? const Center(
                              child: Icon(Icons.videocam_off,
                                  color: Colors.white, size: 40),
                            )
                          : AgoraVideoView(
                              controller: VideoViewController.remote(
                                rtcEngine: _videoCallService.engine!,
                                canvas: VideoCanvas(uid: uid),
                                connection:
                                    RtcConnection(channelId: _channelName),
                              ),
                            ))
                else
                  const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),

                // Etiqueta
                Positioned(
                  bottom: 8,
                  left: 8,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      isLocal ? 'Tú' : 'Participante',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Widget de video remoto (para llamadas 1:1)
  Widget _remoteVideo() {
    if (_remoteUids.isEmpty) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.person,
                size: 100,
                color: Colors.white.withOpacity(0.3),
              ),
              const SizedBox(height: 16),
              Text(
                'Esperando a ${widget.remoteName}...',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.7),
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Para llamadas 1:1, mostrar el primer (y único) UID remoto
    final remoteUid = _remoteUids.first;

    // Validar que channelName esté disponible antes de crear el video view
    if (_channelName == null || _channelName!.isEmpty) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: Icon(
            Icons.videocam_off,
            size: 100,
            color: Colors.white,
          ),
        ),
      );
    }

    // Verificar que el engine esté inicializado
    if (_videoCallService.engine == null) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    return AgoraVideoView(
      controller: VideoViewController.remote(
        rtcEngine: _videoCallService.engine!,
        canvas: VideoCanvas(uid: remoteUid),
        connection: RtcConnection(channelId: _channelName),
      ),
    );
  }

  /// Widget de preview de video local
  Widget _localVideoPreview() {
    if (_isCameraOff || _videoCallService.engine == null) {
      return Container(
        width: 120,
        height: 160,
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: Center(
          child: Icon(
            _isCameraOff ? Icons.videocam_off : Icons.person,
            color: Colors.white,
            size: 40,
          ),
        ),
      );
    }

    return Container(
      width: 120,
      height: 160,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AgoraVideoView(
          key: ValueKey('local_video_preview_${!_isCameraOff}'),
          controller: VideoViewController(
            rtcEngine: _videoCallService.engine!,
            canvas: const VideoCanvas(uid: 0), // 0 = video local
          ),
        ),
      ),
    );
  }

  /// Controles de la llamada
  Widget _callControls() {
    // Determinar si es llamada 1:1 (mostrar botón invitar)
    bool isOneToOne = _remoteUids.length == 1;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // Botón cambiar cámara
          _controlButton(
            icon: Icons.flip_camera_ios,
            onPressed: _switchCamera,
            backgroundColor: Colors.white.withOpacity(0.2),
          ),

          // Botón toggle micrófono
          _controlButton(
            icon: _isMuted ? Icons.mic_off : Icons.mic,
            onPressed: _toggleMute,
            backgroundColor: _isMuted
                ? Colors.white.withOpacity(0.2)
                : Colors.white.withOpacity(0.2),
            iconColor: _isMuted ? Colors.red : Colors.white,
          ),

          // Botón terminar llamada
          _controlButton(
            icon: Icons.call_end,
            onPressed: _endCall,
            backgroundColor: Colors.red,
            size: 70,
            iconSize: 35,
          ),

          // Botón toggle cámara
          _controlButton(
            icon: _isCameraOff ? Icons.videocam_off : Icons.videocam,
            onPressed: _toggleCamera,
            backgroundColor: _isCameraOff
                ? Colors.white.withOpacity(0.2)
                : Colors.white.withOpacity(0.2),
            iconColor: _isCameraOff ? Colors.red : Colors.white,
          ),

          // Botón invitar a más personas (solo en llamadas 1:1)
          if (isOneToOne)
            _controlButton(
              icon: Icons.person_add,
              onPressed: _showInviteDialog,
              backgroundColor: Colors.white.withOpacity(0.2),
            )
          else
            const SizedBox(width: 56), // Placeholder para simetría
        ],
      ),
    );
  }

  /// Widget de botón de control
  Widget _controlButton({
    required IconData icon,
    required VoidCallback onPressed,
    required Color backgroundColor,
    Color iconColor = Colors.white,
    double size = 56,
    double iconSize = 28,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: backgroundColor,
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(icon, color: iconColor, size: iconSize),
        onPressed: onPressed,
      ),
    );
  }
}
