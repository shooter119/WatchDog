import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/services/local_asr_service.dart';

const _requiredFiles = [
  'encoder-epoch-20-avg-1.int8.onnx',
  'decoder-epoch-20-avg-1.onnx',
  'joiner-epoch-20-avg-1.int8.onnx',
  'tokens.txt',
  'bpe.vocab',
];

class _FakeClient extends http.BaseClient {
  final bool Function(Uri uri) shouldFail;
  final bool corrupt;
  final int manifestStatusCode;
  final String? manifestPayload;
  final requests = <http.BaseRequest>[];

  _FakeClient({
    this.shouldFail = _neverFail,
    this.corrupt = false,
    this.manifestStatusCode = 200,
    this.manifestPayload,
  });

  static bool _neverFail(Uri _) => false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (request.url.path.endsWith('/manifest.json')) {
      final body = utf8.encode(manifestPayload ?? _manifestBody());
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable(<List<int>>[body]),
        manifestStatusCode,
        contentLength: body.length,
        request: request,
      );
    }
    final name = request.url.pathSegments.last;
    if (shouldFail(request.url)) {
      return http.StreamedResponse(
        Stream<List<int>>.fromIterable(<List<int>>[
          <int>[1],
        ]),
        500,
        request: request,
      );
    }
    final bytes = <int>[
      name.codeUnitAt(0),
      corrupt && name == _requiredFiles.first ? 9 : 1,
      2,
    ];
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[bytes]),
      200,
      contentLength: bytes.length,
      request: request,
    );
  }

  @override
  void close() {}
}

String _manifestBody() {
  final files = <String, Object>{};
  for (final name in _requiredFiles) {
    final bytes = <int>[name.codeUnitAt(0), 1, 2];
    files['${LocalAsrService.modelName}/$name'] = <String, Object>{
      'sizeBytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    };
  }
  const denoiserName = 'denoiser';
  const denoiserFile = 'dpdfnet2.onnx';
  final denoiserBytes = <int>[denoiserFile.codeUnitAt(0), 1, 2];
  files['$denoiserName/$denoiserFile'] = <String, Object>{
    'sizeBytes': denoiserBytes.length,
    'sha256': sha256.convert(denoiserBytes).toString(),
  };
  return jsonEncode(<String, Object>{
    'schemaVersion': 1,
    'modelVersion': LocalAsrService.modelName,
    'files': files,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory supportDirectory;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    supportDirectory = await Directory.systemTemp.createTemp(
      'watchdog-local-asr-',
    );
  });

  tearDown(() async {
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
  });

  LocalAsrService serviceFor(
    _FakeClient client, {
    Future<int?> Function()? availableStorageBytesProvider,
  }) {
    return LocalAsrService(
      supportDirectoryProvider: () async => supportDirectory,
      httpClientFactory: () => client,
      availableStorageBytesProvider: availableStorageBytesProvider,
    );
  }

  Directory modelRoot() => Directory(
    '${supportDirectory.path}/asr_models/${LocalAsrService.modelName}',
  );

  test('安装检查拒绝旧目录、混合集合和未完成 staging 集合', () async {
    final root = modelRoot();
    await root.create(recursive: true);
    for (final name in _requiredFiles) {
      await File('${root.path}/$name').writeAsString('legacy');
    }

    final service = serviceFor(_FakeClient());
    expect(await service.isModelInstalled(), isFalse);

    final generations = Directory('${root.path}/.generations');
    final incomplete = Directory('${generations.path}/g-1');
    await incomplete.create(recursive: true);
    for (final name in _requiredFiles.take(4)) {
      await File('${incomplete.path}/$name').writeAsString('new');
    }
    await File(
      '${incomplete.path}/.complete',
    ).writeAsString('watchdog-asr-collection-v1');
    await File('${root.path}/.active').writeAsString('g-1\n');
    expect(await service.isModelInstalled(), isFalse);

    final staging = Directory('${generations.path}/.g-2.staging');
    await staging.create(recursive: true);
    for (final name in _requiredFiles) {
      await File('${staging.path}/$name').writeAsString('staged');
    }
    await File(
      '${staging.path}/.complete',
    ).writeAsString('watchdog-asr-collection-v1');
    expect(await service.isModelInstalled(), isFalse);
  });

  test('完整集合写入 staging 后以完成标记切换 active', () async {
    final service = serviceFor(_FakeClient());
    await service.downloadModel();

    expect(await service.isModelInstalled(), isTrue);
    expect(await service.isDenoiserInstalled(), isTrue);

    final root = modelRoot();
    final active = (await File('${root.path}/.active').readAsString()).trim();
    expect(active, matches(RegExp(r'^g-[0-9]+$')));
    final generation = Directory('${root.path}/.generations/$active');
    expect(
      await File('${generation.path}/.complete').readAsString(),
      'watchdog-asr-collection-v1',
    );
    for (final name in _requiredFiles) {
      expect(await File('${generation.path}/$name').length(), greaterThan(0));
    }
    expect(
      await Directory('${root.path}/.generations/.$active.staging').exists(),
      isFalse,
    );
    expect(
      await File('${root.path}/${_requiredFiles.first}').exists(),
      isFalse,
    );
  });

  test('新集合激活后清理未被识别器使用的旧 generation', () async {
    final service = serviceFor(_FakeClient());
    await service.downloadModel();
    final root = modelRoot();
    final oldActive = (await File(
      '${root.path}/.active',
    ).readAsString()).trim();

    await service.downloadModel();
    final newActive = (await File(
      '${root.path}/.active',
    ).readAsString()).trim();

    expect(newActive, isNot(oldActive));
    expect(
      await Directory('${root.path}/.generations/$oldActive').exists(),
      isFalse,
    );
    expect(
      await Directory('${root.path}/.generations/$newActive').exists(),
      isTrue,
    );
  });

  test('新集合下载失败时保留旧 active 和旧完整文件', () async {
    final initialService = serviceFor(_FakeClient());
    await initialService.downloadModel();

    final root = modelRoot();
    final oldActive = (await File(
      '${root.path}/.active',
    ).readAsString()).trim();
    final oldFile = File(
      '${root.path}/.generations/$oldActive/${_requiredFiles.first}',
    );
    final oldBytes = await oldFile.readAsBytes();

    final failingService = serviceFor(
      _FakeClient(shouldFail: (uri) => uri.path.endsWith(_requiredFiles[1])),
    );
    await expectLater(
      failingService.downloadModel(),
      throwsA(isA<StateError>()),
    );

    expect(await failingService.isModelInstalled(), isTrue);
    expect(
      (await File('${root.path}/.active').readAsString()).trim(),
      oldActive,
    );
    expect(await oldFile.readAsBytes(), orderedEquals(oldBytes));
    final entries = await Directory(
      '${root.path}/.generations',
    ).list().toList();
    expect(
      entries.where(
        (entry) => entry is Directory && entry.path.endsWith('.staging'),
      ),
      isEmpty,
    );
  });

  test('低存储预检拒绝新下载并保留已有 active 模型', () async {
    final enough = serviceFor(
      _FakeClient(),
      availableStorageBytesProvider: () async => 1024 * 1024 * 1024,
    );
    await enough.downloadModel();

    final root = modelRoot();
    final oldActive = (await File(
      '${root.path}/.active',
    ).readAsString()).trim();
    final lowClient = _FakeClient();
    final low = serviceFor(
      lowClient,
      availableStorageBytesProvider: () async => 1,
    );

    await expectLater(
      low.downloadModel(),
      throwsA(isA<InsufficientStorageException>()),
    );
    expect(lowClient.requests, hasLength(1));
    expect(
      (await File('${root.path}/.active').readAsString()).trim(),
      oldActive,
    );
    expect(await low.isModelInstalled(), isTrue);
  });

  test('并发下载共享同一 staging 提交任务', () async {
    final service = serviceFor(_FakeClient());
    await Future.wait(<Future<void>>[
      service.downloadModel(),
      service.downloadModel(),
    ]);

    expect(await service.isModelInstalled(), isTrue);
    final generations = Directory('${modelRoot().path}/.generations');
    final committed = await generations
        .list()
        .where(
          (entry) => entry is Directory && !entry.path.endsWith('.staging'),
        )
        .toList();
    expect(committed, hasLength(1));
  });

  test('下载前清理崩溃遗留 staging 和 active 指针临时文件', () async {
    final root = modelRoot();
    final generations = Directory('${root.path}/.generations');
    final staging = Directory('${generations.path}/.g-old.staging');
    await staging.create(recursive: true);
    await File('${staging.path}/partial.bin').writeAsString('partial');
    final pointerPart = File('${root.path}/.active.g-old.part');
    await pointerPart.writeAsString('g-old');

    final service = serviceFor(_FakeClient());
    await service.downloadModel();

    expect(await staging.exists(), isFalse);
    expect(await pointerPart.exists(), isFalse);
    expect(await service.isModelInstalled(), isTrue);
  });

  test('模型文件 SHA-256 不匹配时拒绝激活并保留旧 active', () async {
    final initialService = serviceFor(_FakeClient());
    await initialService.downloadModel();
    final root = modelRoot();
    final oldActive = (await File(
      '${root.path}/.active',
    ).readAsString()).trim();

    final corruptedService = serviceFor(_FakeClient(corrupt: true));
    await expectLater(
      corruptedService.downloadModel(),
      throwsA(isA<StateError>()),
    );

    expect(
      (await File('${root.path}/.active').readAsString()).trim(),
      oldActive,
    );
    expect(await corruptedService.isModelInstalled(), isTrue);
  });

  test('模型清单格式错误、不安全路径或重定向时拒绝下载', () async {
    final invalidPayload = jsonEncode(<String, Object>{
      'schemaVersion': 1,
      'modelVersion': LocalAsrService.modelName,
      'files': <String, Object>{
        '../escape.onnx': <String, Object>{'sizeBytes': 1, 'sha256': '0' * 64},
      },
    });
    final invalidService = serviceFor(
      _FakeClient(manifestPayload: invalidPayload),
    );
    await expectLater(
      invalidService.downloadModel(),
      throwsA(isA<StateError>()),
    );
    expect(await invalidService.isModelInstalled(), isFalse);

    final redirectClient = _FakeClient(manifestStatusCode: 302);
    final redirectService = serviceFor(redirectClient);
    await expectLater(
      redirectService.downloadModel(),
      throwsA(isA<StateError>()),
    );
    expect(redirectClient.requests, hasLength(1));
  });

  test('缓存文件被替换后安装检查拒绝使用损坏集合', () async {
    final service = serviceFor(_FakeClient());
    await service.downloadModel();
    final root = modelRoot();
    final active = (await File('${root.path}/.active').readAsString()).trim();
    final file = File(
      '${root.path}/.generations/$active/${_requiredFiles.first}',
    );
    await file.writeAsBytes(<int>[9, 9, 9], flush: true);

    expect(await service.isModelInstalled(), isFalse);
  });

  test('模型下载不携带业务 API Token', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'api_token': 'must-not-leave-device',
    });
    final client = _FakeClient();
    final service = serviceFor(client);

    await service.downloadModel();

    expect(client.requests, isNotEmpty);
    expect(
      client.requests.any(
        (request) => request.headers.keys.any(
          (key) => key.toLowerCase() == 'x-api-token',
        ),
      ),
      isFalse,
    );
  });
}
