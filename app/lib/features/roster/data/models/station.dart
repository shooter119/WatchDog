class Station {
  final String id;
  final String name;
  const Station({required this.id, required this.name});
  factory Station.fromJson(Map<String, dynamic> json) => Station(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
  );
}
