part of 'paged_datatable.dart';

class _PagedDataTableState<TKey extends Object, TResult extends Object>
    extends ChangeNotifier {
  int _pageSize = 100;
  SortBy? _sortBy;
  _TableState _state = _TableState.loading;
  Object? _currentError;
  List<_PagedDataTableRowState<TResult>> _rowsState = [];
  double _availableWidth = 0; // the available width for the table
  double _nullSizeFactorColumnsWidth =
      0; // the width applied to every column that has sizeFactor = null

  int _sortChange =
      0; // an int which changes when the sort column should update
  int _rowsChange = 0;
  StreamSubscription? _refreshListenerSubscription;

  final Stream? refreshListener;
  final ScrollController filterChipsScrollController = ScrollController();
  final ScrollController rowsScrollController = ScrollController();
  final PagedDataTableController<TKey, TResult> controller;
  final FetchCallback<TKey, TResult> fetchCallback;
  final List<BaseTableColumn<TResult>> columns;
  final Map<String, TableFilterState> filters;
  final GlobalKey<FormState> filtersFormKey = GlobalKey();
  final _TableCache<TKey, TResult> tableCache;
  final Map<int, bool> selectedRows =
      {}; // key is the index of the item in the current resultset, and the value is just a boolean indicating if its selected or not
  late final double columnsSizeFactor;
  late final int lengthColumnsWithoutSizeFactor;

  _TableState get tableState => _state;
  bool get isSorted => _sortBy != null;
  Object? get currentError => _currentError;

  set availableWidth(double newWidth) {
    _availableWidth = newWidth;

    // subtract all the columns that has a specific sizeFactor
    _availableWidth = _availableWidth - (_availableWidth * columnsSizeFactor);
    _nullSizeFactorColumnsWidth =
        _availableWidth / lengthColumnsWithoutSizeFactor; // equally distributed
  }

  _PagedDataTableState(
      {required this.fetchCallback,
      required TKey initialPage,
      required this.columns,
      required List<TableFilter>? filters,
      required PagedDataTableController<TKey, TResult>? controller,
      required bool rowsSelectable,
      required this.refreshListener})
      : controller = controller ?? PagedDataTableController(),
        tableCache = _TableCache(initialPage),
        filters = filters == null
            ? {}
            : {for (var v in filters) v.id: TableFilterState._internal(v)} {
    _init();
  }

  void setPageSize(int pageSize) {
    _pageSize = pageSize;
    tableCache.emptyCache(); // cache must be cleared before changing page size
    notifyListeners();
    _dispatchCallback();
  }

  void setSortBy(String columnId, bool descending) {
    if (_sortBy?.columnId == columnId && _sortBy?.descending == descending) {
      return;
    }

    _sortBy = SortBy._internal(columnId: columnId, descending: descending);
    tableCache.emptyCache(); // cache must be cleared before applying sorting
    _sortChange++;
    notifyListeners();
    _dispatchCallback();
  }

  void swapSortBy(String columnId) {
    if (_sortBy != null && _sortBy!.columnId == columnId) {
      _sortBy!._descending = !_sortBy!.descending;
    } else {
      _sortBy = SortBy._internal(columnId: columnId, descending: true);
    }
    tableCache.emptyCache(); // cache must be cleared before applying sorting
    _sortChange++;
    notifyListeners();
    _dispatchCallback();
  }

  void applyFilters() {
    if (filters.values.any((element) => element.hasValue)) {
      tableCache.emptyCache(); // cache must be cleared before applying filters
      notifyListeners();
      _dispatchCallback();
    }
  }

  void setFilters(Map<String, dynamic> filters) {
    for (var filter in filters.entries) {
      var filterState = this.filters[filter.key];
      if (filterState == null) {
        throw TableError("Filter ${filter.key} not found.");
      }

      filterState.value = filter.value;
    }
    _refresh(currentDataset: false);
  }

  void applyFilter(String filterId, dynamic value) {
    var filter = filters[filterId];
    if (filter == null) {
      throw TableError("Filter $filterId not found.");
    }

    filter.value = value;
    tableCache.emptyCache();
    notifyListeners();
    _dispatchCallback();
  }

  void removeFilters() {
    bool changed = false;
    for (var filterState in filters.values) {
      if (filterState.hasValue) {
        filterState.value = null;
        changed = true;
      }
    }

    if (changed) {
      tableCache.emptyCache(); // cache must be cleared before applying filters
      notifyListeners();
      _dispatchCallback();
    }
  }

  void removeFilter(String filterId) {
    filters[filterId]?.value = null;
    tableCache.emptyCache(); // cache must be cleared before applying filters
    notifyListeners();
    _dispatchCallback();
  }

  @override
  void dispose() {
    rowsScrollController.dispose();
    filterChipsScrollController.dispose();
    _refreshListenerSubscription?.cancel();
    super.dispose();
  }

  void navigate(int page) {
    _dispatchCallback(page: page);
  }

  Future<void> _dispatchCallback({int page = 1, bool goNext = true}) async {
    _state = _TableState.loading;
    _rowsChange++;
    _currentError = null;
    selectedRows.clear();
    notifyListeners();

    try {
      bool goOnline = true;

      // try to lookup key in cache
      var key = tableCache.getKey(page);

      // key found, lookup data in cache
      if (key != null && goNext) {
        var data = tableCache.cache[key];

        // data found, display it
        if (data != null) {
          tableCache.currentPageIndex = page;
          tableCache.currentKey = key;
          tableCache.nextKey = data.nextPageToken;
          goOnline = false;
          debugPrint("Page $page fetched from cache.");
        }
      }

      if (goOnline) {
        TKey lookupKey = goNext
            ? (tableCache.nextKey ?? tableCache.currentKey)
            : tableCache.currentKey;

        // fetch elements
        var pageIndicator = await fetchCallback(
            lookupKey, _pageSize, _sortBy, Filtering._internal(filters));

        // if has errors, throw it and let "catch" handle it
        if (pageIndicator.hasError) {
          throw pageIndicator.error;
        }

        // store page in cache
        tableCache.cache[lookupKey] = pageIndicator;
        tableCache.currentKey = goNext
            ? (tableCache.nextKey ?? tableCache.currentKey)
            : tableCache
                .currentKey; // now currentKey is the nextKey of the previous fetch
        if (goNext) {
          tableCache.keys.add(tableCache.currentKey);
        }
        tableCache.nextKey = pageIndicator.nextPageToken;
        tableCache.currentPageIndex++;
        debugPrint("Page $page fetched from source.");
      }

      // change state and notify listeners of update
      _state = _TableState.displaying;
      _rowsChange++;
      _rowsState = List.generate(
          tableCache.currentLength,
          (index) => _PagedDataTableRowState(
              tableCache.currentResultset[index], index));
      notifyListeners();

      if (rowsScrollController.hasClients) {
        rowsScrollController.animateTo(0,
            duration: const Duration(milliseconds: 200), curve: Curves.easeIn);
      }
    } catch (err, stack) {
      debugPrint(
          "An error ocurred trying to fetch elements from source. Error: $err");
      debugPrint(stack.toString());

      // store the error so the errorBuilder can display it
      _state = _TableState.error;
      _rowsChange++;
      _currentError = err;
      notifyListeners();
    }
  }

  Future<void> _refresh({required bool currentDataset}) {
    int page = 1;
    if (!currentDataset) {
      tableCache.emptyCache();
    } else {
      page = tableCache.currentPageIndex;
    }

    return _dispatchCallback(page: page, goNext: !currentDataset);
  }

  void _init() {
    _initSizes();
    _setDefaultFilters();
    _dispatchCallback();
    controller._state = this;

    if (refreshListener != null) {
      _refreshListenerSubscription = refreshListener!.listen((event) {
        _refresh(currentDataset: true);
      });
    }
  }

  void _setDefaultFilters() {
    for (var filter in filters.values) {
      if (filter._filter.defaultValue != null) {
        filter.value = filter._filter.defaultValue;
      }
    }
  }

  void _initSizes() {
    int withoutSizeFactor = 0;
    double sizeFactorSum = 0;
    for (var column in columns) {
      if (column.sizeFactor == null) {
        withoutSizeFactor++;
      } else {
        sizeFactorSum += column.sizeFactor!;
      }
    }

    columnsSizeFactor = sizeFactorSum;
    lengthColumnsWithoutSizeFactor = withoutSizeFactor;
    assert(columnsSizeFactor <= 1,
        "the sum of all sizeFactor must be less than or equals to 1, given $columnsSizeFactor");
  }
}

class _TableCache<TKey extends Object, TResult extends Object> {
  final TKey initialPageKey;

  Map<TKey, PaginationResult<TKey, TResult>> cache =
      {}; // caches the elements and their keys
  List<TKey> keys =
      []; // store the list of keys so when a previous page is requested, the page index looks up here, then in cache
  TKey currentKey; // the page token that represents the current resultset
  TKey? nextKey; // the next page token
  int currentPageIndex = 0; // the current page index, being 1-offset

  bool get hasResultset => cache[currentKey] != null;
  List<TResult> get currentResultset => cache[currentKey]?.elements ?? const [];
  int get currentLength => currentResultset.length;

  bool get canGoBack => currentPageIndex > 1;
  bool get canGoNext => nextKey != null;

  _TableCache(this.initialPageKey)
      : currentKey = initialPageKey,
        nextKey = initialPageKey;

  void emptyCache() {
    // its faster to create a new map instead of clearing
    cache = {};
    keys = [];
    currentPageIndex = 0;
    currentKey = initialPageKey;
    nextKey = initialPageKey;
    debugPrint("TableCache cleared.");
  }

  TKey? getKey(int pageIndex) {
    try {
      return keys[pageIndex - 1];
    } catch (_) {
      return null;
    }
  }

  void deleteFromCurrentDataset(TResult element) {
    cache[currentKey]?._elements?.remove(element);
  }
}

/// Represents the current state of the rows itself
enum _TableState {
  loading, // for loading elements
  error, // when the table broke due to an error
  displaying // when showing elements
}

class TableFilterState<TValue> {
  final TableFilter<TValue> _filter;
  dynamic value;

  bool get hasValue => value != null;

  TableFilterState._internal(this._filter);
}
