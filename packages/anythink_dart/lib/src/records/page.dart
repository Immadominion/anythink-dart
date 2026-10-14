import '../errors.dart';
import '../json.dart';

/// Converts an entity's JSON response to the application's record model.
typedef RecordDecoder<T> = T Function(JsonObject json);

/// An immutable page with the server's pagination metadata.
final class Page<T> {
  Page._({
    required List<T> items,
    required this.page,
    required this.pageSize,
    required this.totalItems,
    required this.totalPages,
    required this.hasNextPage,
    required this.hasPreviousPage,
    required this.retrievalTime,
  }) : items = List.unmodifiable(items);

  factory Page.fromJson(Object? value, RecordDecoder<T> decode) {
    final json = objectFromJson(value, 'record page');
    final page = intFromJson(json['page'], 'page');
    final pageSize = intFromJson(json['page_size'], 'page_size');
    final totalItems = intFromJson(json['total_items'], 'total_items');
    final totalPages = intFromJson(json['total_pages'], 'total_pages');
    if (page < 1 ||
        pageSize < 1 ||
        pageSize > 1000 ||
        totalItems < 0 ||
        totalPages < 0) {
      throw const ProtocolException('Invalid record pagination metadata.');
    }
    final timing = json['retrieval_time'];
    const maxTimingMilliseconds = 365 * 24 * 60 * 60 * 1000;
    if (timing != null &&
        (timing is! num ||
            !timing.isFinite ||
            timing < 0 ||
            timing > maxTimingMilliseconds)) {
      throw const ProtocolException('Invalid record retrieval time.');
    }
    return Page._(
      items: listFromJson(json['items'], 'record page items')
          .map((item) => decode(objectFromJson(item, 'record')))
          .toList(growable: false),
      page: page,
      pageSize: pageSize,
      totalItems: totalItems,
      totalPages: totalPages,
      hasNextPage: boolFromJson(json['has_next_page'], 'has_next_page'),
      hasPreviousPage: boolFromJson(
        json['has_previous_page'],
        'has_previous_page',
      ),
      retrievalTime: timing is num
          ? Duration(microseconds: (timing * 1000).round())
          : null,
    );
  }

  final List<T> items;
  final int page;
  final int pageSize;
  final int totalItems;
  final int totalPages;
  final bool hasNextPage;
  final bool hasPreviousPage;
  final Duration? retrievalTime;
}
