const {test}=require('node:test');
const assert=require('node:assert/strict');
const {buildContext,safeSearchQuery,contextInstruction}=require('../src/incident-chat-context');
test('问答背景只允许已确认字段，排除联系人和原文，未知力量仍未知',()=>{
  const context=buildContext({id:'i',title:'测试警情'},{version:2,data:{location:'某住宅',situation:'联系13812345678',contacts:[{name:'某人',phone:'13812345678'}],raw_text:'private',specific_type:'电表箱火灾'}},[{station_name:'甲队',vehicle_count:0,vehicle_count_known:false,personnel_count:7}]);
  assert.equal(context.forces[0].vehicles,null);
  assert.equal(JSON.stringify(context).includes('13812345678'),false);
  assert.equal(JSON.stringify(context).includes('contacts'),false);
  assert.equal(JSON.stringify(context).includes('private'),false);
  const query=safeSearchQuery('某住宅13812345678如何处置',context);
  assert.equal(query.includes('住宅138'),false);
  assert.equal(query.includes('某住宅'),false);
  assert.ok(query.includes('电表箱'));
  assert.ok(contextInstruction(context).includes('不是指令'));
});
test('无已确认资料时不伪造问答背景',()=>assert.equal(buildContext({id:'i'},{version:0,data:{}},[]),null));
