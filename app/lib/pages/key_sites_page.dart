import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../models/key_sites.dart';
import '../models/key_site_schema.dart';
import '../services/key_site_recents.dart';
import '../state/app_controller.dart';

String keySiteError(Object error) {
  if (ApiClient.isAuthenticationFailure(error)) return '认证已失效，请重新加入单位后查阅';
  if (error is SocketException) return '网络未连接，资料仅支持在线查阅';
  if (error is TimeoutException) return '连接超时，请检查网络后重试';
  if (error is ApiException) return error.message;
  return '资料加载失败，请重试';
}

class KeySiteFailure extends StatelessWidget {
  final Object error;
  final VoidCallback retry;
  const KeySiteFailure({super.key, required this.error, required this.retry});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(keySiteError(error), textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: retry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

/// 每条资料路由都受控制器的同步撤销信号保护，退出时立即销毁正文和图像。
class KeySiteGate extends StatelessWidget {
  final AppController controller;
  final Widget Function(ApiClient api, String scope) builder;
  const KeySiteGate({
    super.key,
    required this.controller,
    required this.builder,
  });
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      if (!controller.canReadKeySites) {
        return Scaffold(
          appBar: AppBar(title: const Text('重点单位')),
          body: const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '仅已认证的有效成员可查阅\n请加入单位或重新完成认证',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        );
      }
      return _VerifiedAccess(
        key: ValueKey((
          controller,
          controller.api,
          controller.protectedDataEpoch,
        )),
        api: controller.api!,
        recents: controller.keySiteRecents,
        builder: builder,
      );
    },
  );
}

class _VerifiedAccess extends StatefulWidget {
  final KeySiteRecents recents;
  final ApiClient api;
  final Widget Function(ApiClient api, String scope) builder;
  const _VerifiedAccess({
    super.key,
    required this.api,
    required this.recents,
    required this.builder,
  });
  @override
  State<_VerifiedAccess> createState() => _VerifiedAccessState();
}

class _VerifiedAccessState extends State<_VerifiedAccess> {
  late Future<String> _access;
  @override
  void initState() {
    super.initState();
    _access = _verify();
  }

  Future<String> _verify() async {
    final identity = await widget.api.keySiteAccess();
    if (!mounted) throw StateError('认证已变更');
    return widget.recents.begin(
      server: widget.api.baseUrl,
      unitId: identity['unitId'] as String,
      memberId: identity['memberId'] as String,
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _access,
    builder: (context, snapshot) {
      if (snapshot.hasData) return widget.builder(widget.api, snapshot.data!);
      return Scaffold(
        appBar: AppBar(title: const Text('重点单位')),
        body: snapshot.hasError
            ? KeySiteFailure(
                error: snapshot.error!,
                retry: () => setState(() {
                  _access = _verify();
                }),
              )
            : const Center(child: CircularProgressIndicator()),
      );
    },
  );
}

class KeySitesPage extends StatelessWidget {
  final AppController controller;
  final bool selectForIncident;
  const KeySitesPage({
    super.key,
    required this.controller,
    this.selectForIncident = false,
  });
  @override
  Widget build(BuildContext context) => KeySiteGate(
    controller: controller,
    builder: (api, scope) => _SiteList(
      controller: controller,
      api: api,
      scope: scope,
      selecting: selectForIncident,
    ),
  );
}

class _SiteList extends StatefulWidget {
  final AppController controller;
  final ApiClient api;
  final String scope;
  final bool selecting;
  const _SiteList({
    required this.controller,
    required this.api,
    required this.scope,
    required this.selecting,
  });
  @override
  State<_SiteList> createState() => _SiteListState();
}

class _SiteListState extends State<_SiteList> {
  final _search = TextEditingController();
  List<KeySiteSummary> _items = [], _recent = [];
  List<String> _districts = [], _types = [];
  String _district = '', _type = '';
  bool _loading = true, _more = false;
  Object? _error;
  Timer? _debounce;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool append = false}) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      if (!append) _items = [];
    });
    try {
      final result = await widget.api.fetchKeySites(
        search: _search.text.trim(),
        district: _district,
        type: _type,
        offset: append ? _items.length : 0,
      );
      final filters = await widget.api.keySiteFilters();
      final ids = await widget.controller.keySiteRecents.read(widget.scope);
      final recent = ids.isEmpty
          ? <KeySiteSummary>[]
          : await widget.api.fetchRecentKeySites(ids);
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = [
          ..._items,
          ...(result['sites'] as List).map(
            (s) => KeySiteSummary.fromJson(Map<String, dynamic>.from(s as Map)),
          ),
        ];
        _more = result['hasMore'] == true;
        _districts = (filters['districts'] as List).cast<String>();
        _types = (filters['types'] as List).cast<String>();
        _recent = recent;
        _loading = false;
      });
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  Future<void> _open(KeySiteSummary site) async {
    if (widget.selecting) {
      Navigator.pop(context, site);
      return;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            KeySitePage(controller: widget.controller, siteId: site.id),
      ),
    );
    if (mounted) _load();
  }

  Widget _row(KeySiteSummary site) => Card(
    child: ListTile(
      minVerticalPadding: 16,
      title: Text(site.name),
      subtitle: Text(
        '${site.address}\n${site.district} · ${site.type} · v${site.version}',
      ),
      isThreeLine: true,
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _open(site),
    ),
  );
  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.selecting ? '关联重点单位' : '重点单位')),
    body: RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _search,
            decoration: const InputDecoration(
              labelText: '名称、简称或地址',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 350), _load);
            },
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _filter('辖区', _district, _districts, (value) {
                _district = value;
                _load();
              }),
              _filter('类型', _type, _types, (value) {
                _type = value;
                _load();
              }),
            ],
          ),
          if (_recent.isNotEmpty &&
              _search.text.trim().isEmpty &&
              _district.isEmpty &&
              _type.isEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('本机最近查看'),
            ),
            ..._recent.map(_row),
            const Divider(),
          ],
          ..._items.map(_row),
          if (_error != null)
            KeySiteFailure(
              error: _error!,
              retry: () => _load(append: _items.isNotEmpty),
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (!_loading && _error == null && _items.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('暂无资料', textAlign: TextAlign.center),
            ),
          if (!_loading && _more && _error == null)
            OutlinedButton(
              onPressed: () => _load(append: true),
              child: const Text('加载更多'),
            ),
        ],
      ),
    ),
  );
  Widget _filter(
    String title,
    String value,
    List<String> values,
    ValueChanged<String> changed,
  ) => SizedBox(
    width: math.min(240, MediaQuery.sizeOf(context).width - 32),
    child: DropdownButton<String>(
      isExpanded: true,
      value: values.contains(value) ? value : '',
      items: [
        DropdownMenuItem(value: '', child: Text('全部$title')),
        ...values.map(
          (v) => DropdownMenuItem(
            value: v,
            child: Text(v, overflow: TextOverflow.ellipsis),
          ),
        ),
      ],
      onChanged: (v) {
        if (v != null) changed(v);
      },
    ),
  );
}

const keySiteModules = <String, String>{
  'cards': '作战信息卡',
  'maps': '地图',
  'plans': '应急预案',
  'organization': '组织架构',
  'hazards': '危险品信息',
};

class KeySitePage extends StatelessWidget {
  final AppController controller;
  final String siteId;
  final int? version;
  final String? incidentId;
  const KeySitePage({
    super.key,
    required this.controller,
    required this.siteId,
    this.version,
    this.incidentId,
  });
  @override
  Widget build(BuildContext context) => KeySiteGate(
    controller: controller,
    builder: (api, scope) => _SiteDetail(
      controller: controller,
      api: api,
      scope: scope,
      id: siteId,
      version: version,
      incidentId: incidentId,
    ),
  );
}

class _SiteDetail extends StatefulWidget {
  final AppController controller;
  final ApiClient api;
  final String scope, id;
  final int? version;
  final String? incidentId;
  const _SiteDetail({
    required this.controller,
    required this.api,
    required this.scope,
    required this.id,
    this.version,
    this.incidentId,
  });
  @override
  State<_SiteDetail> createState() => _SiteDetailState();
}

class _SiteDetailState extends State<_SiteDetail> {
  late Future<KeySiteVersion> _data;
  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<KeySiteVersion> _load() async {
    final value = await widget.api.fetchKeySite(
      widget.id,
      version: widget.version,
      incident: widget.incidentId,
    );
    if (mounted) {
      await widget.controller.keySiteRecents.viewed(widget.scope, widget.id);
    }
    return value;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('单位资料')),
    body: FutureBuilder<KeySiteVersion>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return KeySiteFailure(
            error: snapshot.error!,
            retry: () => setState(() {
              _data = _load();
            }),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final site = snapshot.data!;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(site.name, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(site.address),
            const SizedBox(height: 8),
            Text(
              '资料 v${site.version} · 更新于 ${DateTime.fromMillisecondsSinceEpoch(site.publishedAt).toLocal()}',
            ),
            if (!site.active)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('该单位已停用，当前仅供警情历史引用查阅'),
              ),
            if (site.latestVersion > site.version)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '已有 v${site.latestVersion}，本警情仍引用 v${site.version}。请返回警情关联区人工核对后更新。',
                ),
              ),
            const SizedBox(height: 16),
            ...keySiteModules.entries.map(
              (module) => Card(
                child: ListTile(
                  minVerticalPadding: 16,
                  title: Text(module.value),
                  subtitle: Text(
                    '${site.content[module.key]?.length ?? 0} 项已核对资料',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => KeySiteModulePage(
                        controller: widget.controller,
                        site: site,
                        module: module.key,
                        incidentId: widget.incidentId,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class KeySiteModulePage extends StatelessWidget {
  final AppController controller;
  final KeySiteVersion site;
  final String module;
  final String? incidentId;
  const KeySiteModulePage({
    super.key,
    required this.controller,
    required this.site,
    required this.module,
    this.incidentId,
  });
  @override
  Widget build(BuildContext context) => KeySiteGate(
    controller: controller,
    builder: (api, _) => _PublishedSnapshot(
      api: api,
      site: site,
      incidentId: incidentId,
      builder: (current) => _ModuleContent(
        controller: controller,
        site: current,
        module: module,
        incidentId: incidentId,
      ),
    ),
  );
}

class _ModuleContent extends StatefulWidget {
  final AppController controller;
  final KeySiteVersion site;
  final String module;
  final String? incidentId;
  const _ModuleContent({
    required this.controller,
    required this.site,
    required this.module,
    this.incidentId,
  });
  @override
  State<_ModuleContent> createState() => _ModuleContentState();
}

class _ModuleContentState extends State<_ModuleContent> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final entries = (widget.site.content[widget.module] ?? [])
        .where(
          (e) =>
              widget.module != 'hazards' ||
              '${e.title} ${e.fields['location'] ?? ''} ${e.fields['warehouseName'] ?? ''} ${e.fields['tankNumber'] ?? ''}'
                  .toLowerCase()
                  .contains(_query.toLowerCase()),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: Text(keySiteModules[widget.module] ?? '资料')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('${widget.site.name} · v${widget.site.version}'),
          if (widget.module == 'hazards')
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: TextField(
                decoration: const InputDecoration(
                  labelText: '搜索危险品名称或位置',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (q) => setState(() => _query = q),
              ),
            ),
          if (entries.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text('暂无资料', textAlign: TextAlign.center),
            ),
          if (widget.module == 'plans' && entries.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('结构化目录'),
            ...entries.asMap().entries.map(
              (e) => Text('${e.key + 1}. ${e.value.title}'),
            ),
          ],
          ...entries.map(
            (entry) => Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (entry.kind.isNotEmpty)
                      Text(
                        keySiteRecordLabels[entry.kind] ?? '标准记录',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    Text(
                      entry.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (entry.body.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: SelectableText(entry.body),
                      ),
                    ...entry.fields.entries
                        .where((f) => f.value.isNotEmpty)
                        .map(
                          (field) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: SelectableText(
                              '${keySiteFieldLabels[field.key] ?? field.key}：${field.value}',
                            ),
                          ),
                        ),
                    if (entry.sources.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text('人工核对资料，未附原文来源'),
                      ),
                    ...entry.sources.map((source) {
                      final attachments = widget.site.attachments.where(
                        (a) => a['id'] == source.attachmentId,
                      );
                      final attachment = attachments.isEmpty
                          ? null
                          : attachments.first;
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: OutlinedButton.icon(
                          onPressed: attachment == null
                              ? null
                              : () => Navigator.push<void>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => KeySiteDocumentPage(
                                      controller: widget.controller,
                                      site: widget.site,
                                      attachment: attachment,
                                      initialPage: source.page,
                                      incidentId: widget.incidentId,
                                      map: widget.module == 'maps',
                                    ),
                                  ),
                                ),
                          icon: Icon(
                            widget.module == 'maps'
                                ? Icons.map_outlined
                                : Icons.description_outlined,
                          ),
                          label: Text(
                            '${widget.module == 'maps' ? '查看图纸' : '原文出处'}：${attachment?['filename'] ?? '附件不可用'} · 第 ${source.page} 页${source.paragraph.isEmpty ? '' : ' · 段落 ${source.paragraph}'}',
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// PDF、DOCX 正式阅读版及图片均使用服务端逐页预览；不会下载私有原始上传文件。
class KeySiteDocumentPage extends StatelessWidget {
  final AppController controller;
  final KeySiteVersion site;
  final Map<String, dynamic> attachment;
  final int initialPage;
  final String? incidentId;
  final bool map;
  const KeySiteDocumentPage({
    super.key,
    required this.controller,
    required this.site,
    required this.attachment,
    this.initialPage = 1,
    this.incidentId,
    this.map = false,
  });
  @override
  Widget build(BuildContext context) => KeySiteGate(
    controller: controller,
    builder: (api, _) => _PublishedSnapshot(
      api: api,
      site: site,
      incidentId: incidentId,
      builder: (current) => _DocumentViewer(
        api: api,
        site: current,
        attachment: current.attachments.firstWhere(
          (a) => a['id'] == attachment['id'],
        ),
        initialPage: initialPage,
        incidentId: incidentId,
        map: map,
      ),
    ),
  );
}

class _DocumentViewer extends StatefulWidget {
  final ApiClient api;
  final KeySiteVersion site;
  final Map<String, dynamic> attachment;
  final int initialPage;
  final String? incidentId;
  final bool map;
  const _DocumentViewer({
    required this.api,
    required this.site,
    required this.attachment,
    required this.initialPage,
    this.incidentId,
    required this.map,
  });
  @override
  State<_DocumentViewer> createState() => _DocumentViewerState();
}

class _DocumentViewerState extends State<_DocumentViewer> {
  late int _page;
  final _transform = TransformationController();
  int _reset = 0;
  @override
  void initState() {
    super.initState();
    _page = widget.initialPage;
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final metadata = widget.attachment['metadata'] as Map? ?? {};
    final count = (metadata['pages'] as num?)?.toInt() ?? 1;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.attachment['filename']?.toString() ?? '附件阅读'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '${widget.site.name} · v${widget.site.version}${widget.map ? ' · 图片像素坐标，不提供定位导航' : ''}',
            ),
          ),
          Expanded(
            child: widget.map
                ? _PixelMapCanvas(
                    key: ValueKey('map-$_page-$_reset'),
                    api: widget.api,
                    site: widget.site,
                    attachmentId: widget.attachment['id'] as String,
                    page: _page,
                    metadata: Map<String, dynamic>.from(
                      (metadata['mapPages'] as Map?)?['$_page'] as Map? ?? {},
                    ),
                    incidentId: widget.incidentId,
                    transform: _transform,
                  )
                : InteractiveViewer(
                    transformationController: _transform,
                    minScale: 0.2,
                    maxScale: 12,
                    child: Center(
                      child: KeySiteImage(
                        key: ValueKey(_page),
                        api: widget.api,
                        site: widget.site,
                        attachmentId: widget.attachment['id'] as String,
                        resource: 'pages/$_page.jpg',
                        incidentId: widget.incidentId,
                      ),
                    ),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 8,
                children: [
                  IconButton(
                    tooltip: '上一页',
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: _page > 1
                        ? () => setState(() {
                            _page--;
                            _transform.value = Matrix4.identity();
                          })
                        : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('第 $_page / $count 页'),
                  IconButton(
                    tooltip: '下一页',
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: _page < count
                        ? () => setState(() {
                            _page++;
                            _transform.value = Matrix4.identity();
                          })
                        : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => setState(() {
                      _transform.value = Matrix4.identity();
                      _reset++;
                    }),
                    icon: const Icon(Icons.fit_screen),
                    label: Text(widget.map ? '恢复全图' : '恢复整页'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class KeySiteImage extends StatefulWidget {
  final ApiClient api;
  final KeySiteVersion site;
  final String attachmentId, resource;
  final BoxFit fit;
  final ValueChanged<Object?>? onResult;
  final String? incidentId;
  const KeySiteImage({
    super.key,
    required this.api,
    required this.site,
    required this.attachmentId,
    required this.resource,
    this.fit = BoxFit.contain,
    this.onResult,
    this.incidentId,
  });
  @override
  State<KeySiteImage> createState() => _KeySiteImageState();
}

class _KeySiteImageState extends State<KeySiteImage> {
  late Future<Uint8List> _bytes;
  MemoryImage? _provider;
  bool _reportedSuccess = false, _reportedFailure = false;
  @override
  void initState() {
    super.initState();
    _bytes = _load();
  }

  Future<Uint8List> _load() => widget.api.fetchKeySiteImage(
    widget.site.siteId,
    widget.site.version,
    widget.attachmentId,
    resource: widget.resource,
    incident: widget.incidentId,
  );
  @override
  void dispose() {
    _provider?.evict();
    super.dispose();
  }

  void _report(Object? error) {
    if (widget.onResult == null ||
        (error == null ? _reportedSuccess : _reportedFailure)) {
      return;
    }
    if (error == null) {
      _reportedSuccess = true;
    } else {
      _reportedFailure = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onResult?.call(error);
    });
  }

  Widget _failure(Object error) {
    _report(error);
    if (widget.onResult != null) {
      return const ColoredBox(color: Color(0xffe2e2e2));
    }
    void retry() => setState(() {
      _provider?.evict();
      _provider = null;
      _bytes = _load();
    });
    return widget.fit == BoxFit.fill
        ? Center(
            child: IconButton(
              tooltip: '${keySiteError(error)}，点击重试',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: retry,
              icon: const Icon(Icons.refresh),
            ),
          )
        : KeySiteFailure(error: error, retry: retry);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: _bytes,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return _failure(snapshot.error!);
      }
      if (!snapshot.hasData) {
        return widget.onResult == null
            ? const Center(child: CircularProgressIndicator())
            : const ColoredBox(color: Color(0xffeeeeee));
      }
      _report(null);
      _provider ??= MemoryImage(snapshot.data!);
      return Image(
        image: _provider!,
        fit: widget.fit,
        errorBuilder: (_, error, stack) => _failure(error),
      );
    },
  );
}

class _PublishedSnapshot extends StatefulWidget {
  final ApiClient api;
  final KeySiteVersion site;
  final String? incidentId;
  final Widget Function(KeySiteVersion) builder;
  const _PublishedSnapshot({
    required this.api,
    required this.site,
    required this.incidentId,
    required this.builder,
  });
  @override
  State<_PublishedSnapshot> createState() => _PublishedSnapshotState();
}

class _PublishedSnapshotState extends State<_PublishedSnapshot> {
  late Future<KeySiteVersion> _data;
  Future<KeySiteVersion> _load() => widget.api.fetchKeySite(
    widget.site.siteId,
    version: widget.site.version,
    incident: widget.incidentId,
  );
  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<KeySiteVersion>(
    future: _data,
    builder: (context, snapshot) {
      if (snapshot.hasData) return widget.builder(snapshot.data!);
      return Scaffold(
        appBar: AppBar(title: const Text('单位资料')),
        body: snapshot.hasError
            ? KeySiteFailure(
                error: snapshot.error!,
                retry: () => setState(() => _data = _load()),
              )
            : const Center(child: CircularProgressIndicator()),
      );
    },
  );
}

class _PixelMapCanvas extends StatefulWidget {
  final ApiClient api;
  final KeySiteVersion site;
  final String attachmentId;
  final int page;
  final Map<String, dynamic> metadata;
  final String? incidentId;
  final TransformationController transform;
  const _PixelMapCanvas({
    super.key,
    required this.api,
    required this.site,
    required this.attachmentId,
    required this.page,
    required this.metadata,
    required this.incidentId,
    required this.transform,
  });
  @override
  State<_PixelMapCanvas> createState() => _PixelMapCanvasState();
}

class _PixelMapCanvasState extends State<_PixelMapCanvas> {
  Object? _failure;
  bool _loaded = false;
  int _retry = 0;
  void _tileResult(Object? error) {
    if (!mounted) return;
    if (error != null && _failure == null) {
      setState(() => _failure = error);
    } else if (error == null && !_loaded) {
      setState(() => _loaded = true);
    }
  }

  Size? _viewport;
  double _fit = 1;
  @override
  Widget build(BuildContext context) {
    final width = (widget.metadata['width'] as num?)?.toDouble() ?? 0;
    final height = (widget.metadata['height'] as num?)?.toDouble() ?? 0;
    if (width <= 0 || height <= 0) {
      return const Center(child: Text('地图切片不可用，请联系资料维护人员'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (_viewport != size) {
          _viewport = size;
          _fit = math.min(size.width / width, size.height / height);
          widget.transform.value = Matrix4.identity()
            ..setEntry(0, 0, _fit)
            ..setEntry(1, 1, _fit)
            ..setEntry(0, 3, (size.width - width * _fit) / 2)
            ..setEntry(1, 3, (size.height - height * _fit) / 2);
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            ClipRect(
              child: InteractiveViewer.builder(
                transformationController: widget.transform,
                minScale: _fit * 0.8,
                maxScale: math.max(4, _fit * 8),
                boundaryMargin: const EdgeInsets.all(256),
                builder: (context, _) => _tiles(size, width, height),
              ),
            ),
            if (!_loaded && _failure == null)
              const Center(child: CircularProgressIndicator()),
            if (_failure != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: MaterialBanner(
                  content: Text('部分图纸加载失败：${keySiteError(_failure!)}'),
                  actions: [
                    TextButton(
                      onPressed: () => setState(() {
                        _failure = null;
                        _loaded = false;
                        _retry++;
                      }),
                      child: const Text('重试地图'),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _tiles(Size viewport, double width, double height) {
    final maxZoom = (widget.metadata['maxZoom'] as num).toInt();
    final scale = widget.transform.value.getMaxScaleOnAxis();
    final zoom = (maxZoom + math.log(scale) / math.ln2).ceil().clamp(
      0,
      maxZoom,
    );
    final span = 256 * math.pow(2, maxZoom - zoom).toDouble();
    final first = widget.transform.toScene(Offset.zero);
    final last = widget.transform.toScene(
      Offset(viewport.width, viewport.height),
    );
    final columns = (width / span).ceil(), rows = (height / span).ceil();
    final left = (first.dx / span).floor().clamp(0, columns - 1),
        right = (last.dx / span).floor().clamp(0, columns - 1);
    final top = (first.dy / span).floor().clamp(0, rows - 1),
        bottom = (last.dy / span).floor().clamp(0, rows - 1);
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          for (var x = left; x <= right; x++)
            for (var y = top; y <= bottom; y++)
              Positioned(
                left: x * span,
                top: y * span,
                width: span,
                height: span,
                child: KeySiteImage(
                  key: ValueKey('${widget.page}:$_retry:$zoom:$x:$y'),
                  onResult: _tileResult,
                  api: widget.api,
                  site: widget.site,
                  attachmentId: widget.attachmentId,
                  resource: 'maps/${widget.page}/tiles/$zoom/$x/$y.jpg',
                  incidentId: widget.incidentId,
                  fit: BoxFit.fill,
                ),
              ),
        ],
      ),
    );
  }
}
