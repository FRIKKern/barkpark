import fs from 'node:fs';import path from 'node:path';import crypto from 'node:crypto';import {spawnSync,execFileSync} from 'node:child_process';
import {batchPath} from '../scripts/build-runtime-release-windows.mjs';
import {inventory,unusedDestination,sha256} from '../scripts/runtime-postgres-bundle.mjs';
const source=batchPath('../barkpark-windows-media-settlement'),api=path.join(source,'api');
const git=args=>execFileSync('git',args,{cwd:source,encoding:'utf8'}).trim();
const head=git(['rev-parse','HEAD']);if(head!=='ae3be838480c7910b23b9a9568c61d16c08b23a0'||git(['status','--porcelain']))throw Error('Candidate source is not clean expected revision');
const pin=fs.readFileSync('app/BARKPARK_REF','utf8').trim(),pinHash=sha256('app/BARKPARK_REF'),lock=sha256(path.join(api,'mix.lock'));
const prior=JSON.parse(fs.readFileSync('docs/cycles/evidence/C098/reader-assembly-01/result.json'));
const output=unusedDestination('runtime/C109-full-current-303'),build=unusedDestination(output+'.build');fs.mkdirSync(build,{recursive:true});
const out='.git/C109-full-build303';fs.mkdirSync(out);fs.copyFileSync('.git/media-fence-backend303.mjs',out+'/producer.mjs');
const driver=batchPath('scripts/runtime-release-windows.exs'),vsdev=batchPath(prior.vsdev),elixir=batchPath(prior.elixir),erlangBin=batchPath(prior.erlangBin);
for(const p of [driver,vsdev,elixir,path.join(erlangBin,'erl.exe')])if(!fs.statSync(p).isFile())throw Error('Toolchain unavailable');
const cmd=batchPath(path.join(build,'build.cmd'));
fs.writeFileSync(cmd,'@echo off\r\nsetlocal DisableDelayedExpansion\r\ncall "'+vsdev+'" -arch=x64 -host_arch=x64\r\nif errorlevel 1 exit /b %errorlevel%\r\ncall "'+elixir+'" "'+driver+'" "'+api+'" "'+build+'" "'+output+'"\r\nexit /b %errorlevel%\r\n');
const env=Object.fromEntries(Object.entries(process.env).filter(([k])=>k.toLowerCase()!=='path'&&!/^(MIX|ELIXIR|ERL|RELEASE|BARKDOWN_BUILD)/i.test(k)));
Object.assign(env,{PATH:[path.dirname(elixir),erlangBin,process.env.PATH].join(';'),MIX_ENV:'prod'});
const started=Date.now(),report={status:'running',startedAt:new Date(started).toISOString(),source:head,checkout:source,sourceLockSha256:lock,output,build,appPin:pin,appAdopted:false,scope:'Full Windows backend dependencies and production release assembly from explicit clean candidate; no production pin substitution',limits:['No generated reader/package assembly or installer acceptance','Full upstream CI remains separate','No real database or library is started by this build']};
const save=()=>fs.writeFileSync(out+'/result.json',JSON.stringify(report,null,2)+'\n');save();
const log=path.join(build,'build.log'),fd=fs.openSync(log,'wx');let r;
try{r=spawnSync('cmd.exe',['/d','/s','/c','""'+cmd+'""'],{cwd:api,env,windowsVerbatimArguments:true,windowsHide:true,stdio:['ignore',fd,fd],timeout:30*60*1000});}finally{fs.closeSync(fd);}
Object.assign(report,{exitCode:r.status,signal:r.signal,error:r.error?.message,elapsedMs:Date.now()-started,finishedAt:new Date().toISOString()});
fs.copyFileSync(log,out+'/build.log');
try{
  if(r.status!==0||r.error||r.signal)throw Error('Full Windows backend build failed; retained log');
  if(git(['rev-parse','HEAD'])!==head||git(['status','--porcelain','--untracked-files=no'])||sha256(path.join(api,'mix.lock'))!==lock||sha256('app/BARKPARK_REF')!==pinHash)throw Error('Source/lock/pin changed during assembly');
  if(!fs.existsSync(path.join(output,'bin/barkpark.bat')))throw Error('Windows release launcher missing');
  report.toolchain=JSON.parse(fs.readFileSync(path.join(build,'toolchain.json')));
  const files=inventory(output);report.files=files.length;report.bytes=files.reduce((n,f)=>n+f.bytes,0);fs.writeFileSync(out+'/inventory.json',JSON.stringify(files,null,2)+'\n');
  fs.writeFileSync(path.join(output,'C109-integration-only.json'),JSON.stringify({source:head,platform:'win32',arch:'x64',appAdopted:false,purpose:'backend-integration-proof',appPinUnchanged:pin},null,2)+'\n');
  report.status='passed';
}catch(error){report.status='failed';report.error=error.message;process.exitCode=1;}
save();console.log(JSON.stringify({status:report.status,source:head,elapsedMs:report.elapsedMs,files:report.files,error:report.error}));
