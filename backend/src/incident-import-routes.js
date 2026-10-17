const multer = require('multer');
const path = require('node:path');
const repo = require('./incident-import-repository');
const tasks = require('./incident-import-tasks');
const store = require('./postgres-store');
const { forceError } = require('./force-fields');

function registerIncidentImportRoutes(app, { db, config, actorName, deviceKey, requireManagementRole, hasManagementAccess, logger }) {
  const wrap = (handler) => async (req,res) => {
    try { await handler(req,res); }
    catch(error) {
      const safe = /^(IMPORT_|STATION_|FORCE_|INVALID_FORCE|VERSION_CONFLICT|CLIENT_OP_ID_CONFLICT|OPERATION_IN_PROGRESS|INCIDENT_ARCHIVED)/.test(error.code || '');
      const status = safe ? error.status || 400 : error.code === '23505' ? 409 : 500;
      logger.warn(`incident_import code=${safe ? error.code : 'INTERNAL_ERROR'} status=${status} request_id=${req.requestId || '-'}`);
      if(res.headersSent) return;
      res.status(status).json({ error: safe ? error.message : status===409 ? '名称或操作冲突，请刷新后重试' : '警情导入服务暂不可用', code: safe ? error.code : 'IMPORT_INTERNAL_ERROR' });
    }
  };
  const scope = async (req,incidentId=req.params.id) => {
    if(!req.unit?.id) throw forceError('请先完成单位认证','IMPORT_AUTH_REQUIRED',401);
    const actorId=req.auth?.memberId || req.auth?.deviceId || deviceKey(req);
    if(!actorId) throw forceError('缺少用户身份','IMPORT_AUTH_REQUIRED',401);
    const incident=await repo.incidentInUnit(req.unit.id,incidentId);
    return {unitId:req.unit.id,incidentId,actorId,actorName:await actorName(req),incident,id:req.params.importId};
  };
  const upload=multer({storage:multer.memoryStorage(),limits:{files:9,fileSize:5*1024*1024,fields:3,fieldSize:80000}}).array('images',9);
  const uploadMiddleware=(req,res,next)=>upload(req,res,(err)=>{
    if(err) return res.status(err.code?.startsWith('LIMIT_')?413:400).json({error:'图片上传失败：最多9张，单张不超过5MB',code:'IMPORT_UPLOAD_INVALID'});
    next();
  });
  // Authenticate and check availability before buffering uploads.
  const beforeUpload=wrap(async(req,res)=>{
    req.importScope=await scope(req);
    if(!req.importScope.actorName) throw forceError('请先填写真实姓名','IMPORT_AUTH_REQUIRED',403);
    if(req.importScope.incident.status!=='active') throw forceError('警情已归档，不能导入','INCIDENT_ARCHIVED',409);
    if(!config.apiKey) throw forceError('警情识别服务尚未配置','IMPORT_AI_UNAVAILABLE',503);
    req.importAuthorized=true;
  });
  app.post('/api/incidents/:id/imports',async(req,res,next)=>{
    await beforeUpload(req,res);
    if(req.importAuthorized && !res.headersSent) next();
  },uploadMiddleware,wrap(async(req,res)=>{
    const result=await tasks.createTask({...req.importScope,text:req.body?.text,files:req.files||[]});
    res.status(202).json(result);
  }));
  app.get('/api/incidents/:id/imports',wrap(async(req,res)=>{
    const s=await scope(req);
    const {rows}=await store.query('SELECT * FROM incident_imports WHERE unit_id=$1 AND incident_id=$2 AND actor_id=$3 AND expires_at>$4 ORDER BY created_at DESC LIMIT 20',[s.unitId,s.incidentId,s.actorId,Date.now()]);
    res.json(rows.map(repo.publicImport));
  }));
  app.get('/api/incidents/:id/imports/:importId',wrap(async(req,res)=>{
    const s=await scope(req);
    const row=await repo.readImport(s.unitId,s.incidentId,s.actorId,s.id);
    const prior=await store.query("SELECT id FROM incident_imports WHERE unit_id=$1 AND incident_id=$2 AND input_hash=$3 AND status='applied' AND id<>$4 ORDER BY applied_at DESC LIMIT 1",[s.unitId,s.incidentId,row.input_hash,row.id]);
    res.json({...repo.publicImport(row),previously_applied_id:prior.rows[0]?.id||null});
  }));
  app.get('/api/incidents/:id/imports/:importId/images/:page',wrap(async(req,res)=>{
    const s=await scope(req);
    const task=await repo.readImport(s.unitId,s.incidentId,s.actorId,s.id);
    if(['applied','cancelled','expired'].includes(task.status) || Number(task.expires_at)<=Date.now()) throw forceError('临时图片已清理','IMPORT_NOT_FOUND',404);
    const page=task.pages.find((p)=>p.index===Number(req.params.page));
    if(!page?.file_path || path.dirname(page.file_path)!==tasks.TEMP_DIR) throw forceError('图片不存在','IMPORT_NOT_FOUND',404);
    res.set('Cache-Control','no-store');
    res.type(page.mime);
    await new Promise((resolve,reject)=>res.sendFile(page.file_path,(err)=>err?reject(Object.assign(new Error('图片已清理'),{code:'IMPORT_NOT_FOUND',status:404})):resolve()));
  }));
  app.post('/api/incidents/:id/imports/:importId/retry',wrap(async(req,res)=>{
    const s=await scope(req);
    if(s.incident.status!=='active') throw forceError('警情已归档','INCIDENT_ARCHIVED',409);
    res.json(await tasks.retryTask(s,req.body?.pages));
  }));
  app.post('/api/incidents/:id/imports/:importId/cancel',wrap(async(req,res)=>res.json(await tasks.cancelTask(await scope(req)))));
  app.post('/api/incidents/:id/imports/:importId/apply',wrap(async(req,res)=>{
    const s=await scope(req);
    const result=await repo.applyImport({...s,importId:s.id,opId:req.headers['x-op-id'],body:req.body||{}});
    res.json(result);
    const task=await repo.readImport(s.unitId,s.incidentId,s.actorId,s.id);
    await tasks.deleteImages(task.pages);
  }));
  app.get('/api/incidents/:id/details',wrap(async(req,res)=>{
    const s=await scope(req);
    const detail=await repo.details(s.unitId,s.incidentId);
    const {rows}=await store.query("SELECT id,source,pages,applied_at,actor_name FROM incident_imports WHERE unit_id=$1 AND incident_id=$2 AND status='applied' ORDER BY applied_at DESC LIMIT 50",[s.unitId,s.incidentId]);
    res.json({...detail,imports:rows.map((row)=>({...row,pages:row.pages.map((p)=>({index:p.index,raw_text:p.result?.raw_text||p.text||'',status:p.status}))}))});
  }));
  app.patch('/api/incidents/:id/details',wrap(async(req,res)=>{
    const s=await scope(req);
    res.json(await repo.updateDetails({...s,opId:req.headers['x-op-id'],body:req.body||{}}));
  }));
  app.post('/api/incidents/:id/forces/merge',wrap(async(req,res)=>{
    const s=await scope(req);
    res.json(await repo.mergeForces({...s,opId:req.headers['x-op-id'],body:req.body||{}}));
  }));
  app.get('/api/unit-stations/access',wrap(async(req,res)=>{
    if(!req.unit?.id) throw forceError('请先完成单位认证','IMPORT_AUTH_REQUIRED',401);
    res.json({can_manage:hasManagementAccess(req)});
  }));
  app.get('/api/unit-stations',wrap(async(req,res)=>{
    if(!req.unit?.id) throw forceError('请先完成单位认证','IMPORT_AUTH_REQUIRED',401);
    res.json(await repo.listStations(req.unit.id,req.query.include_inactive==='1'));
  }));
  app.post('/api/unit-stations',wrap(async(req,res)=>{
    if(!req.unit?.id) throw forceError('请先完成单位认证','IMPORT_AUTH_REQUIRED',401);
    const name=await actorName(req);
    if(!name) throw forceError('请先填写真实姓名','IMPORT_AUTH_REQUIRED',403);
    res.status(201).json(await repo.addStation(req.unit.id,req.body?.name,req.auth?.memberId||deviceKey(req)));
  }));
  app.patch('/api/unit-stations/:stationId',wrap(async(req,res)=>{
    if(!req.unit?.id) throw forceError('请先完成单位认证','IMPORT_AUTH_REQUIRED',401);
    if(!requireManagementRole(req,res)) return;
    res.json(await repo.updateStation(req.unit.id,req.params.stationId,req.body||{},req.auth?.memberId||deviceKey(req)));
  }));
  if(process.env.NODE_ENV!=='test') db.ready.then(()=>tasks.startWorker(config,(error)=>logger.warn(`incident_import_worker code=${error.code||'INTERNAL_ERROR'}`))).catch(()=>{});
}
module.exports={registerIncidentImportRoutes};
