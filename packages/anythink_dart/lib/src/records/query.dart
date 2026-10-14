/// Sort direction accepted by the Anythink records endpoint.
enum SortDirection { ascending, descending }

/// A scalar filter value with an explicit wire representation.
///
/// Anythink does not document escaping commas or operator-looking literal
/// prefixes. Such text is rejected rather than being sent with changed meaning.
sealed class FilterValue {
  const FilterValue._(this._wire);

  factory FilterValue.text(String value) {
    if (value.isEmpty ||
        value.contains(',') ||
        _operatorPrefix.hasMatch(value)) {
      throw ArgumentError(
        'Filter text must be nonempty and cannot contain commas or begin '
        'with a filter operator; the API does not document literal escaping.',
      );
    }
    return _ScalarFilterValue(value);
  }

  factory FilterValue.number(num value) {
    if (!value.isFinite) {
      throw ArgumentError('A numeric filter must be finite.');
    }
    return _ScalarFilterValue(value.toString());
  }

  /// Preserves decimal precision without converting through a binary double.
  factory FilterValue.decimal(String value) {
    if (!RegExp(r'^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?$').hasMatch(value)) {
      throw ArgumentError('A decimal filter must be a plain decimal number.');
    }
    return _ScalarFilterValue(value);
  }

  factory FilterValue.boolean(bool value) =>
      _ScalarFilterValue(value.toString());

  /// Encodes a timestamp in UTC, without relying on the machine's time zone.
  factory FilterValue.timestamp(DateTime value) =>
      _ScalarFilterValue(value.toUtc().toIso8601String());

  /// Encodes a calendar date, rejecting normalization such as 31 February.
  factory FilterValue.date(int year, int month, int day) {
    if (year < 1 || year > 9999) {
      throw ArgumentError('A date filter year must be between 1 and 9999.');
    }
    final date = DateTime.utc(year, month, day);
    if (date.year != year || date.month != month || date.day != day) {
      throw ArgumentError('A date filter must be a valid calendar date.');
    }
    return _ScalarFilterValue(
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}',
    );
  }

  final String _wire;
}

final class _ScalarFilterValue extends FilterValue {
  const _ScalarFilterValue(super.wire) : super._();
}

final _operatorPrefix = RegExp(
  r'^(?:!|GT:|GTE:|LT:|LTE:|C:|NC:|SW:|EW:|IN:)',
  caseSensitive: false,
);

enum _Operator {
  equal(''),
  notEqual('!'),
  greaterThan('GT:'),
  greaterThanOrEqual('GTE:'),
  lessThan('LT:'),
  lessThanOrEqual('LTE:'),
  contains('C:'),
  notContains('NC:'),
  startsWith('SW:'),
  endsWith('EW:'),
  oneOf('IN:');

  const _Operator(this.prefix);
  final String prefix;
}

/// An immutable predicate on one entity field.
///
/// Different fields combine with AND. Use [RecordFilter.allOf] for multiple
/// conditions on the same field. Cross-field OR and null predicates are not
/// part of the documented record-list protocol.
final class RecordFilter {
  RecordFilter._(this.field, this._wire, this._canCombine) {
    _validateField(field);
    if (_reservedQueryNames.contains(field.toLowerCase())) {
      throw ArgumentError('The filter field conflicts with a query option.');
    }
  }

  factory RecordFilter.equal(String field, FilterValue value) =>
      _scalar(field, _Operator.equal, value);
  factory RecordFilter.notEqual(String field, FilterValue value) =>
      _scalar(field, _Operator.notEqual, value);
  factory RecordFilter.greaterThan(String field, FilterValue value) =>
      _scalar(field, _Operator.greaterThan, value);
  factory RecordFilter.greaterThanOrEqual(String field, FilterValue value) =>
      _scalar(field, _Operator.greaterThanOrEqual, value);
  factory RecordFilter.lessThan(String field, FilterValue value) =>
      _scalar(field, _Operator.lessThan, value);
  factory RecordFilter.lessThanOrEqual(String field, FilterValue value) =>
      _scalar(field, _Operator.lessThanOrEqual, value);
  factory RecordFilter.contains(String field, String value) =>
      _scalar(field, _Operator.contains, FilterValue.text(value));
  factory RecordFilter.notContains(String field, String value) =>
      _scalar(field, _Operator.notContains, FilterValue.text(value));
  factory RecordFilter.startsWith(String field, String value) =>
      _scalar(field, _Operator.startsWith, FilterValue.text(value));
  factory RecordFilter.endsWith(String field, String value) =>
      _scalar(field, _Operator.endsWith, FilterValue.text(value));

  factory RecordFilter.oneOf(String field, Iterable<FilterValue> values) {
    final snapshot = values.toList(growable: false);
    if (snapshot.isEmpty) {
      throw ArgumentError('A membership filter needs at least one value.');
    }
    return RecordFilter._(
      field,
      '${_Operator.oneOf.prefix}${snapshot.map((value) => value._wire).join(',')}',
      false,
    );
  }

  /// Combines operator-prefixed predicates on the same field with AND.
  ///
  /// Equality and membership cannot be nested here: their comma representation
  /// is ambiguous in the documented protocol. Express them as single filters.
  factory RecordFilter.allOf(Iterable<RecordFilter> filters) {
    final snapshot = filters.toList(growable: false);
    if (snapshot.length < 2) {
      throw ArgumentError('A combined filter needs at least two conditions.');
    }
    final field = snapshot.first.field;
    if (snapshot.any(
      (filter) => filter.field != field || !filter._canCombine,
    )) {
      throw ArgumentError(
        'Combined filters must target one field and use explicit operators '
        'other than membership.',
      );
    }
    return RecordFilter._(
      field,
      snapshot.map((filter) => filter._wire).join(','),
      true,
    );
  }

  static RecordFilter _scalar(
    String field,
    _Operator operator,
    FilterValue value,
  ) => RecordFilter._(
    field,
    '${operator.prefix}${value._wire}',
    operator != _Operator.equal,
  );

  final String field;
  final String _wire;
  final bool _canCombine;
}

/// Fields returned by a read, including dotted relationship paths.
final class FieldSelection {
  FieldSelection(Iterable<String> fields) : fields = List.unmodifiable(fields) {
    if (this.fields.isEmpty) {
      throw ArgumentError('Select at least one field, or omit the selection.');
    }
    if (this.fields.contains('*') && this.fields.length != 1) {
      throw ArgumentError('The all-fields wildcard must be used alone.');
    }
    for (final field in this.fields) {
      if (field != '*') _validateField(field, allowRelationship: true);
    }
    if (this.fields.toSet().length != this.fields.length) {
      throw ArgumentError('A field selection cannot contain duplicates.');
    }
  }

  final List<String> fields;
  String get encoded => fields.join(',');
}

/// Immutable records paging, sorting, projection and filter options.
///
/// Field names cannot be validated against a project's schema locally. The
/// server may ignore unknown fields or values of the wrong entity-field type.
/// Filters must never be used as an authorization boundary.
final class RecordQuery {
  RecordQuery({
    this.page = 1,
    this.pageSize = 25,
    this.sortBy = 'id',
    this.sortDirection = SortDirection.ascending,
    this.fields,
    this.groupScope,
    Iterable<RecordFilter> filters = const [],
  }) : filters = List.unmodifiable(filters) {
    if (page < 1) throw ArgumentError('Page must be at least one.');
    if (pageSize < 1 || pageSize > 1000) {
      throw ArgumentError('Page size must be between 1 and 1000.');
    }
    _validateField(sortBy);
    if (groupScope != null && groupScope! < 1) {
      throw ArgumentError('Group scope must be a positive group ID.');
    }
    final names = <String>{};
    for (final filter in this.filters) {
      if (!names.add(filter.field.toLowerCase())) {
        throw ArgumentError(
          'Duplicate filter fields must be combined explicitly with allOf.',
        );
      }
    }
  }

  final int page;
  final int pageSize;
  final String sortBy;
  final SortDirection sortDirection;
  final FieldSelection? fields;
  final int? groupScope;
  final List<RecordFilter> filters;

  Map<String, String> toQueryParameters() => Map.unmodifiable({
    'page': '$page',
    'pageSize': '$pageSize',
    'sortBy': sortBy,
    'sortDirection': sortDirection == SortDirection.ascending ? 'asc' : 'desc',
    if (fields != null) 'fields': fields!.encoded,
    if (groupScope != null) 'group_scope': '$groupScope',
    for (final filter in filters) filter.field: filter._wire,
  });
}

const _reservedQueryNames = {
  'page',
  'pagesize',
  'sortby',
  'sortdirection',
  'fields',
  'group_scope',
};

void _validateField(String field, {bool allowRelationship = false}) {
  final pattern = allowRelationship
      ? r'^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$'
      : r'^[A-Za-z_][A-Za-z0-9_]*$';
  if (!RegExp(pattern).hasMatch(field)) {
    throw ArgumentError('Use an entity field name, not a query expression.');
  }
}
