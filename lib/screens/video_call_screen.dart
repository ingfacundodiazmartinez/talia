import 'package:flutter/material.dart';
import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../services/video_call_service.dart';
import '../services/voip_service.dart';
import '../services/callkit_service.dart';

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
  final VideoCallService _videoCallService = VideoCallService();

  bool _isMuted = false;
  bool _isCameraOff = false;
  bool _isJoined = false;
  int? _localUid;
  Set<int> _remoteUids = {}; // Múltiples UIDs remotos para llamadas grupales
  String _connectionStatus = 'Conectando...'; // 'Conectando...', 'Llamando...', 'Conectado'
  bool _isEnding = false;

  // Datos de llamada (se llenan en background si es optimista)
  String? _channelName;
  String? _token;
  int? _uid;

  @override
  void initState() {
    super.initState();
    // Inicializar datos locales con los proporcionados
    _channelName = widget.channelName;
    _token = widget.token;
    _uid = widget.uid;

    // Si es llamada de audio, deshabilitar cámara automáticamente
    if (!widget.isVideo) {
      _isCameraOff = true;
    }

    _initializeCall();
    _listenToCallStatus();
  }

  /// Inicializar la llamada con lógica optimista
  Future<void> _initializeCall() async {
    try {
      // Paso 1: Si es caller y no hay token/uid, obtener credenciales
      if (widget.isCaller && (_token == null || _uid == null)) {
        print('📱 [Optimistic] Iniciando llamada en background...');
        setState(() {
          _connectionStatus = 'Conectando...';
        });

        // Si ya tenemos channelName (ej: emergencia), solo generar token
        if (_channelName != null) {
          print('📱 [Emergency] Channel ya existe: $_channelName, generando token...');

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

          print('✅ [Emergency] Token generado: uid=$_uid');
        } else {
          // Caso normal: iniciar llamada completa
          final result = await _videoCallService.initiateCall(
            receiverId: widget.receiverId,
            receiverName: widget.remoteName,
            isVideo: widget.isVideo,
          );

          if (result['success'] != true) {
            throw Exception(result['error'] ?? 'Error iniciando llamada');
          }

          // Actualizar datos de llamada
          setState(() {
            _channelName = result['channelName'];
            _token = result['token'];
            _uid = result['uid'];
            _connectionStatus = 'Llamando...';
          });

          print('✅ [Optimistic] Datos de llamada obtenidos: channel=$_channelName, uid=$_uid');
        }
      }

      // Paso 2: Inicializar Agora
      await _videoCallService.initializeAgora();

      // Paso 3: Configurar event handlers
      _videoCallService.engine?.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
            print('✅ Unido al canal: ${connection.channelId}');
            print('✅ UID local asignado: ${connection.localUid}');
            setState(() {
              _isJoined = true;
              _localUid = connection.localUid;
              if (widget.isCaller) {
                _connectionStatus = 'Llamando...';
              } else {
                _connectionStatus = 'Conectado';
              }
            });
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
            setState(() {
              _remoteUids.remove(remoteUid);
            });

            if (_remoteUids.isEmpty) {
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

      // Paso 4: Unirse al canal (esperar a tener todos los datos)
      if (_channelName != null && _token != null && _uid != null) {
        await _videoCallService.joinChannel(
          channelName: _channelName!,
          token: _token!,
          uid: _uid!,
        );
        print('🚀 Llamada inicializada exitosamente');
      } else {
        throw Exception('Faltan datos de llamada (channel, token, o uid)');
      }
    } catch (e) {
      print('❌ Error inicializando llamada: $e');
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
    _videoCallService.watchCallStatus(widget.callId).listen((snapshot) {
      print('🔍 [VideoCallScreen] Snapshot recibido para callId: ${widget.callId}');
      print('🔍 [VideoCallScreen] Snapshot existe: ${snapshot.exists}');

      if (!snapshot.exists) {
        print('⚠️ [VideoCallScreen] Snapshot no existe, ignorando');
        return;
      }

      final data = snapshot.data() as Map<String, dynamic>;
      final status = data['status'];

      print('🔍 [VideoCallScreen] Status detectado: $status');
      print('🔍 [VideoCallScreen] Datos completos: $data');

      if ((status == 'ended' || status == 'rejected') && !_isEnding) {
        // La llamada terminó o fue rechazada
        print('⚠️ [VideoCallScreen] Status es ended/rejected, llamando a _endCall()');
        _endCall();
      }
    });
  }

  /// Toggle micrófono
  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
    });
    _videoCallService.toggleMute();
  }

  /// Toggle cámara
  void _toggleCamera() {
    setState(() {
      _isCameraOff = !_isCameraOff;
    });
    _videoCallService.toggleCamera();
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

      // Obtener contactos del usuario
      final contactsSnapshot = await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUserId)
          .collection('contacts')
          .get();

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
                  child: contactsSnapshot.docs.isEmpty
                      ? const Center(
                          child: Text(
                            'No tienes contactos disponibles',
                            style: TextStyle(color: Colors.white70),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: contactsSnapshot.docs.length,
                          itemBuilder: (context, index) {
                            final contactData = contactsSnapshot.docs[index].data();
                            final contactId = contactsSnapshot.docs[index].id;
                            final contactName = contactData['name'] ?? 'Usuario';
                            final contactPhotoURL = contactData['photoURL'];

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
          const SnackBar(
            content: Text('Error al cargar contactos'),
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
        callId: widget.callId,
        channelName: _channelName ?? widget.callId, // Usar state local o fallback a callId
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

  /// Terminar la llamada
  Future<void> _endCall() async {
    if (_isEnding) return; // Evitar múltiples llamadas
    _isEnding = true;

    try {
      // Cerrar CallKit UI en ambas plataformas
      if (Platform.isIOS) {
        // En iOS usamos VoIPService para notificar a CallKit nativo
        await VoIPService().notifyCallEnded(widget.callId);
      } else if (Platform.isAndroid) {
        // En Android usamos flutter_callkit_incoming
        await CallKitService().endCall(widget.callId);
      }

      await _videoCallService.endCall(widget.callId);
      await _videoCallService.leaveChannel();

      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      print('❌ Error terminando llamada: $e');
      if (mounted) {
        Navigator.pop(context);
      }
    }
  }

  @override
  void dispose() {
    _videoCallService.leaveChannel();
    super.dispose();
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
                if (uid != null)
                  isLocal
                      ? (_isCameraOff
                          ? const Center(
                              child: Icon(Icons.videocam_off,
                                  color: Colors.white, size: 40),
                            )
                          : AgoraVideoView(
                              controller: VideoViewController(
                                rtcEngine: _videoCallService.engine!,
                                canvas: const VideoCanvas(uid: 0),
                              ),
                            ))
                      : AgoraVideoView(
                          controller: VideoViewController.remote(
                            rtcEngine: _videoCallService.engine!,
                            canvas: VideoCanvas(uid: uid),
                            connection:
                                RtcConnection(channelId: widget.channelName),
                          ),
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

    return AgoraVideoView(
      controller: VideoViewController.remote(
        rtcEngine: _videoCallService.engine!,
        canvas: VideoCanvas(uid: remoteUid),
        connection: RtcConnection(channelId: widget.channelName),
      ),
    );
  }

  /// Widget de preview de video local
  Widget _localVideoPreview() {
    if (_isCameraOff) {
      return Container(
        width: 120,
        height: 160,
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white, width: 2),
        ),
        child: const Center(
          child: Icon(
            Icons.videocam_off,
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
