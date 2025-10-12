import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../controllers/chat_controller_optimistic.dart';
import '../models/chat_message.dart';
import '../widgets/message_status_icon.dart';

/// EJEMPLO de cómo usar ChatControllerOptimistic en chat_detail_screen.dart
///
/// Pasos para migrar:
/// 1. Cambiar ChatController por ChatControllerOptimistic
/// 2. Usar Provider/ChangeNotifierProvider en lugar de StreamBuilder
/// 3. Acceder a controller.messages en vez de stream
/// 4. Agregar MessageStatusIcon a los mensajes enviados
/// 5. Agregar botón retry para mensajes con error

class ChatDetailScreenOptimisticExample extends StatefulWidget {
  final String contactId;
  final String contactName;
  final String chatId;

  const ChatDetailScreenOptimisticExample({
    super.key,
    required this.contactId,
    required this.contactName,
    required this.chatId,
  });

  @override
  State<ChatDetailScreenOptimisticExample> createState() =>
      _ChatDetailScreenOptimisticExampleState();
}

class _ChatDetailScreenOptimisticExampleState
    extends State<ChatDetailScreenOptimisticExample> {
  late ChatControllerOptimistic _controller;
  final TextEditingController _messageController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = ChatControllerOptimistic(
      chatId: widget.chatId,
      contactId: widget.contactId,
      contactName: widget.contactName,
    );
    _controller.initialize();

    // Escuchar cambios del controller
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.contactName),
      ),
      body: Column(
        children: [
          // Lista de mensajes
          Expanded(
            child: _controller.isLoading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    reverse: true,
                    itemCount: _controller.messages.length,
                    itemBuilder: (context, index) {
                      final message = _controller.messages[index];
                      return _buildMessageBubble(message);
                    },
                  ),
          ),

          // Input de mensaje
          _buildMessageInput(),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    final isMe = message.senderId == _controller.currentUserId;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isMe ? Colors.blue : Colors.grey[300],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Contenido del mensaje
            if (message.text != null) Text(message.text!),
            if (message.imageUrl != null)
              Image.network(message.imageUrl!, width: 200),

            // Espacio
            const SizedBox(height: 4),

            // Estado del mensaje (solo para mensajes propios)
            if (isMe)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    message.formattedTime,
                    style: const TextStyle(fontSize: 10),
                  ),
                  const SizedBox(width: 4),

                  // ✅ NUEVO: Ícono de estado
                  MessageStatusIcon(
                    message: message,
                    onRetry: message.hasError
                        ? () => _controller.retryMessage(message.id)
                        : null,
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageInput() {
    return Container(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          // Campo de texto
          Expanded(
            child: TextField(
              controller: _messageController,
              decoration: const InputDecoration(
                hintText: 'Escribe un mensaje...',
                border: OutlineInputBorder(),
              ),
              onChanged: (text) {
                _controller.setTyping(text.isNotEmpty);
              },
            ),
          ),

          // Botón enviar
          IconButton(
            icon: const Icon(Icons.send),
            onPressed: () async {
              final text = _messageController.text.trim();
              if (text.isNotEmpty) {
                _messageController.clear();
                _controller.stopTyping();

                // ✅ NUEVO: Envío optimista
                await _controller.sendTextMessage(text: text);
              }
            },
          ),

          // Botón adjuntar imagen
          IconButton(
            icon: const Icon(Icons.image),
            onPressed: () async {
              // ✅ NUEVO: Envío optimista de imagen
              await _controller.sendImage(source: ImageSource.gallery);
            },
          ),
        ],
      ),
    );
  }
}
