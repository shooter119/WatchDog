import 'models/entry.dart';

/// 同名人员已在火场内（409）：携带已有在场记录，供确认页二选一处理
class EntryConflictException implements Exception {
  final String message;
  final Entry existing;
  EntryConflictException(this.message, this.existing);
  @override
  String toString() => message;
}
