import 'package:flutter_test/flutter_test.dart';
import 'package:hiide_flutter/core/backend/mock_backend_service.dart';

void main() {
  test('mock editor supports undo and redo for offline editing', () async {
    final backend = MockBackendService();
    addTearDown(backend.dispose);

    final handle = await backend.editorLoad('abc');

    await backend.editorInsert(handle, 3, 'd');
    expect(await backend.editorGetText(handle), 'abcd');

    await backend.editorUndo(handle);
    expect(await backend.editorGetText(handle), 'abc');

    await backend.editorRedo(handle);
    expect(await backend.editorGetText(handle), 'abcd');

    await backend.editorDelete(handle, 1, 1);
    expect(await backend.editorGetText(handle), 'acd');

    await backend.editorUndo(handle);
    expect(await backend.editorGetText(handle), 'abcd');
  });
}
