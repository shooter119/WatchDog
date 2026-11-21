import '../../../../core/models/amap_location.dart';

class WeatherInfo {
  final String? address;
  final String? city;
  final String? weatherText;
  final String? temperature;
  final String? humidity;
  final String? line;
  final AmapLocation? amapLocation;
  final bool coordinateDegraded;
  final bool degraded;

  const WeatherInfo({
    this.address,
    this.city,
    this.weatherText,
    this.temperature,
    this.humidity,
    this.line,
    this.amapLocation,
    this.coordinateDegraded = false,
    this.degraded = false,
  });

  static const WeatherInfo empty = WeatherInfo(degraded: true);

  factory WeatherInfo.fromJson(Map<String, dynamic> json) {
    final weather = json['weather'];
    final map = weather is Map ? weather : const <String, dynamic>{};
    return WeatherInfo(
      address: (json['address'] as String?)?.trim(),
      city: (json['city'] as String?)?.trim(),
      weatherText: (map['text'] as String?)?.trim(),
      temperature: map['temperature']?.toString(),
      humidity: map['humidity']?.toString(),
      line: (json['line'] as String?)?.trim(),
      amapLocation: AmapLocation.fromJson(json['amapLocation']),
      coordinateDegraded: json['coordinateDegraded'] == true,
      degraded: json['degraded'] == true,
    );
  }
}
