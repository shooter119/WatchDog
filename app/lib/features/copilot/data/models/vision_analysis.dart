class VisionAnalysis {
  final String relevance;
  final String category;
  final double confidence;
  final List<String> facts;
  final List<String> risks;
  final List<String> toConfirm;
  final List<String> suggestions;
  final String disclaimer;

  const VisionAnalysis({
    required this.relevance,
    required this.category,
    required this.confidence,
    required this.facts,
    required this.risks,
    required this.toConfirm,
    required this.suggestions,
    required this.disclaimer,
  });

  factory VisionAnalysis.fromJson(Map<String, dynamic> json) {
    List<String> list(String key) => (json[key] as List? ?? const [])
        .map((e) => e.toString())
        .where((e) => e.trim().isNotEmpty)
        .toList(growable: false);
    final rawConfidence = (json['confidence'] as num?)?.toDouble() ?? 0;
    return VisionAnalysis(
      relevance: json['relevance']?.toString() ?? 'uncertain',
      category: json['category']?.toString() ?? 'unknown',
      confidence: rawConfidence.clamp(0, 1).toDouble(),
      facts: list('facts'),
      risks: list('risks'),
      toConfirm: list('to_confirm'),
      suggestions: list('suggestions'),
      disclaimer: json['disclaimer']?.toString() ?? '以上为图片辅助分析，不替代现场专业判断',
    );
  }
}
