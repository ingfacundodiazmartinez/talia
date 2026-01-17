/// Unified response model for all services
/// Provides consistent error handling and data passing

class ServiceResponse<T> {
  final bool success;
  final T? data;
  final String? error;
  final String? errorCode;
  final Map<String, dynamic>? metadata;

  ServiceResponse._({
    required this.success,
    this.data,
    this.error,
    this.errorCode,
    this.metadata,
  });

  /// Create a successful response
  factory ServiceResponse.success(T data, {Map<String, dynamic>? metadata}) {
    return ServiceResponse._(
      success: true,
      data: data,
      metadata: metadata,
    );
  }

  /// Create an error response
  factory ServiceResponse.error(
    String error, {
    String? errorCode,
    Map<String, dynamic>? metadata,
  }) {
    return ServiceResponse._(
      success: false,
      error: error,
      errorCode: errorCode,
      metadata: metadata,
    );
  }

  /// Check if the response is successful and has data
  bool get hasData => success && data != null;

  /// Map the response data to another type
  ServiceResponse<R> map<R>(R Function(T data) mapper) {
    if (success && data != null) {
      try {
        return ServiceResponse.success(mapper(data!), metadata: metadata);
      } catch (e) {
        return ServiceResponse.error(
          'Error mapping data: $e',
          errorCode: 'MAPPING_ERROR',
          metadata: metadata,
        );
      }
    }
    return ServiceResponse.error(
      error ?? 'No data to map',
      errorCode: errorCode,
      metadata: metadata,
    );
  }

  /// Convert to a simple map representation
  Map<String, dynamic> toJson() {
    return {
      'success': success,
      if (data != null) 'data': data,
      if (error != null) 'error': error,
      if (errorCode != null) 'errorCode': errorCode,
      if (metadata != null) 'metadata': metadata,
    };
  }
}