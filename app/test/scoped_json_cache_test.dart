import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:watchdog/services/scoped_json_cache.dart';
void main(){
  setUp(()=>SharedPreferences.setMockInitialValues({}));
  test('晚到的旧警情缓存不能覆盖新版本，单位及用户隔离',()async{
    await ScopedJsonCache.write('server|unit-a|user','details:i',{'version':3,'data':{'location':'新地点'}});
    await ScopedJsonCache.write('server|unit-a|user','details:i',{'version':2,'data':{'location':'旧地点'}});
    final result=await ScopedJsonCache.read('server|unit-a|user','details:i');
    expect(result['version'],3);
    expect(await ScopedJsonCache.read('server|unit-b|user','details:i'),isNull);
    expect(await ScopedJsonCache.read('server|unit-a|other','details:i'),isNull);
  });
}
