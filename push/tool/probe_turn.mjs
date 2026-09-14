import {createHash,createHmac,randomBytes} from 'node:crypto';
import {createSocket} from 'node:dgram';
import {connect} from 'node:net';
import {schnorr} from '@noble/curves/secp256k1';
const key=randomBytes(32),event={pubkey:Buffer.from(schnorr.getPublicKey(key)).toString('hex'),created_at:Math.floor(Date.now()/1000),kind:24242,tags:[['action','turn']],content:''};
event.id=createHash('sha256').update(JSON.stringify([0,event.pubkey,event.created_at,event.kind,event.tags,event.content])).digest('hex');
event.sig=Buffer.from(schnorr.sign(event.id,key)).toString('hex');
const response=await fetch('https://push.cubechat.tech/turn',{method:'POST',body:JSON.stringify(event),headers:{'content-type':'application/json'},signal:AbortSignal.timeout(6000)});
const access=await response.json();
if(!response.ok)throw Error('TURN HTTP '+response.status);
console.log('TURN listeners:',access.urls);
function attr(t,d){const h=Buffer.alloc(4);h.writeUInt16BE(t);h.writeUInt16BE(d.length,2);return Buffer.concat([h,d,Buffer.alloc((4-d.length%4)%4)]);}
function request(attrs,key){const b=Buffer.concat(attrs),h=Buffer.alloc(20);h.writeUInt16BE(3);h.writeUInt16BE(b.length+(key?24:0),2);h.writeUInt32BE(0x2112a442,4);randomBytes(12).copy(h,8);const m=Buffer.concat([h,b]);return key?Buffer.concat([m,attr(8,createHmac('sha1',key).update(m).digest())]):m;}
function attrs(m){const result=new Map();for(let i=20;i+4<=m.length;){const t=m.readUInt16BE(i),n=m.readUInt16BE(i+2);result.set(t,m.subarray(i+4,i+4+n));i+=4+Math.ceil(n/4)*4;}return result;}
for(const url of access.urls){
 const u=new URL(url.replace(/^turn:/,'http://')),tcp=u.searchParams.get('transport')==='tcp',port=Number(u.port||3478),s=tcp?connect(port,u.hostname):createSocket('udp4');
 const exchange=m=>new Promise((resolve,reject)=>{let b=Buffer.alloc(0);const finish=(err,data)=>{clearTimeout(timer);s.off(tcp?'data':'message',read);s.off('error',fail);err?reject(err):resolve(data);},fail=e=>finish(e),read=d=>{b=Buffer.concat([b,d]);if(b.length>=20&&b.length>=20+b.readUInt16BE(2))finish(null,b);};const timer=setTimeout(()=>finish(Error('timeout')),5000);s.on(tcp?'data':'message',read);s.once('error',fail);tcp?s.write(m):s.send(m,port,u.hostname);});
 try{const c=attrs(await exchange(request([attr(25,Buffer.from([17,0,0,0]))]))),r=c.get(20),n=c.get(21);if(!r||!n)throw Error('no challenge');const k=createHash('md5').update(access.username+':'+r.toString()+':'+access.password).digest(),reply=await exchange(request([attr(25,Buffer.from([17,0,0,0])),attr(6,Buffer.from(access.username)),attr(20,r),attr(21,n)],k));console.log(tcp?'TCP':'UDP','response',reply.readUInt16BE(0).toString(16),'relay',attrs(reply).has(22));if(!attrs(reply).has(22))process.exitCode=1;}
 catch(e){console.log(tcp?'TCP':'UDP',String(e));process.exitCode=1;}
 finally{tcp?s.destroy():s.close();}
}

