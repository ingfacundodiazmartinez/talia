import 'dart:async';
import '../models/models.dart';
import '../services/services.dart';
import '../../utils/release_logger.dart';

/// Controller for group approval management
///
/// Handles the parent approval flow for child group membership.
class GroupApprovalController {
  final GroupApprovalService _approvalService;

  // State
  List<GroupApprovalRequest> _pendingRequests = [];
  bool _isLoading = false;
  String? _processingRequestId; // Track which specific request is being processed
  String? _error;

  // Subscriptions
  StreamSubscription? _requestsSubscription;

  // Callbacks
  Function(List<GroupApprovalRequest>)? onRequestsChanged;
  Function(bool)? onLoadingChanged;
  Function(bool)? onProcessingChanged;
  Function(String)? onError;
  Function(String)? onSuccess;

  GroupApprovalController({
    GroupApprovalService? approvalService,
  }) : _approvalService = approvalService ?? GroupApprovalService();

  // Getters
  List<GroupApprovalRequest> get pendingRequests => _pendingRequests;
  int get pendingCount => _pendingRequests.length;
  bool get isLoading => _isLoading;
  bool get isProcessing => _processingRequestId != null;
  String? get processingRequestId => _processingRequestId;
  String? get error => _error;
  bool get hasRequests => _pendingRequests.isNotEmpty;

  /// Check if a specific request is being processed
  bool isRequestProcessing(String requestId) => _processingRequestId == requestId;

  /// Initialize controller and start watching requests
  Future<void> initialize() async {
    _setLoading(true);

    try {
      // Load initial data with timeout to prevent infinite loading
      _pendingRequests = await _approvalService.getPendingRequests()
        .timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            ReleaseLogger.warning(
              'Timeout loading requests, returning empty list',
              tag: 'GroupApprovalController',
            );
            return [];
          },
        );
      onRequestsChanged?.call(_pendingRequests);

      // Start watching for updates
      _requestsSubscription = _approvalService.watchPendingRequests().listen(
        (requests) {
          _pendingRequests = requests;
          onRequestsChanged?.call(_pendingRequests);
        },
        onError: (e) {
          _setError('Error cargando solicitudes: $e');
        },
      );
    } catch (e) {
      _setError('Error inicializando: $e');
    } finally {
      _setLoading(false);
    }
  }

  /// Approve a request
  Future<bool> approveRequest(String requestId) async {
    _setProcessingRequest(requestId);
    _clearError();

    try {
      final success = await _approvalService.approveRequest(requestId);

      if (success) {
        onSuccess?.call('Solicitud aprobada');
        ReleaseLogger.log(
          'Request approved: $requestId',
          tag: 'GroupApprovalController',
        );
      } else {
        _setError('No se pudo aprobar la solicitud');
      }

      return success;
    } catch (e) {
      _setError('Error aprobando solicitud: $e');
      return false;
    } finally {
      _clearProcessingRequest();
    }
  }

  /// Reject a request
  Future<bool> rejectRequest(String requestId) async {
    _setProcessingRequest(requestId);
    _clearError();

    try {
      final success = await _approvalService.rejectRequest(requestId);

      if (success) {
        onSuccess?.call('Solicitud rechazada');
        ReleaseLogger.log(
          'Request rejected: $requestId',
          tag: 'GroupApprovalController',
        );
      } else {
        _setError('No se pudo rechazar la solicitud');
      }

      return success;
    } catch (e) {
      _setError('Error rechazando solicitud: $e');
      return false;
    } finally {
      _clearProcessingRequest();
    }
  }

  /// Get a specific request by ID
  GroupApprovalRequest? getRequest(String requestId) {
    try {
      return _pendingRequests.firstWhere((r) => r.id == requestId);
    } catch (_) {
      return null;
    }
  }

  /// Refresh requests manually
  Future<void> refresh() async {
    _setLoading(true);

    try {
      _pendingRequests = await _approvalService.getPendingRequests();
      onRequestsChanged?.call(_pendingRequests);
    } catch (e) {
      _setError('Error actualizando: $e');
    } finally {
      _setLoading(false);
    }
  }

  // Private helpers
  void _setLoading(bool value) {
    _isLoading = value;
    onLoadingChanged?.call(value);
  }

  void _setProcessingRequest(String requestId) {
    _processingRequestId = requestId;
    onProcessingChanged?.call(true);
  }

  void _clearProcessingRequest() {
    _processingRequestId = null;
    onProcessingChanged?.call(false);
  }

  void _setError(String message) {
    _error = message;
    onError?.call(message);
    ReleaseLogger.error(message, tag: 'GroupApprovalController');
  }

  void _clearError() {
    _error = null;
  }

  /// Dispose resources
  void dispose() {
    _requestsSubscription?.cancel();
  }
}
