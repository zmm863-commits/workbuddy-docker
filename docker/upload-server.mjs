#!/usr/bin/env node
/**
 * WorkBuddy 容器「收件箱」上传服务（零依赖）
 * ------------------------------------------------------------
 * 为什么需要它：VNC 协议（noVNC / x11vnc / KasmVNC 单机版）都没有文件通道，
 * 从宿主机把文件“拖进远程桌面窗口”在协议层就不存在。所以给一个网页：
 * 把文件拖到这个网页 → 落到容器内 /opt/wb/inbox → 在 WorkBuddy 的文件选择器里选它。
 *
 * 用法：INBOX=/opt/wb/inbox PORT=6082 node upload-server.mjs
 */

import http from 'node:http';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';

const PORT = Number(process.env.UPLOAD_PORT || process.env.PORT || 6082);
const HOST = process.env.UPLOAD_HOST || '0.0.0.0';
const INBOX = process.env.INBOX || '/opt/wb/inbox';
const MAX_BYTES = Number(process.env.MAX_UPLOAD_MB || 512) * 1024 * 1024;

fs.mkdirSync(INBOX, { recursive: true });

const log = (...a) => console.log(new Date().toISOString(), ...a);

/** 最小 multipart 解析：够用即可，不引依赖 */
function parseMultipart(buf, contentType) {
  const m = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType || '');
  const boundary = (m?.[1] || m?.[2] || '').trim();
  if (!boundary) return { fields: {}, files: [] };
  const delim = Buffer.from(`--${boundary}`);
  const parts = [];
  let idx = buf.indexOf(delim);
  while (idx !== -1) {
    const start = idx + delim.length;
    const next = buf.indexOf(delim, start);
    if (next === -1) break;
    let chunk = buf.subarray(start, next);
    if (chunk[0] === 0x0d && chunk[1] === 0x0a) chunk = chunk.subarray(2);
    if (chunk.length >= 2 && chunk[chunk.length - 2] === 0x0d && chunk[chunk.length - 1] === 0x0a) {
      chunk = chunk.subarray(0, chunk.length - 2);
    }
    parts.push(chunk);
    idx = next;
  }
  const fields = {};
  const files = [];
  for (const part of parts) {
    const sep = part.indexOf('\r\n\r\n');
    if (sep === -1) continue;
    const head = part.subarray(0, sep).toString('utf8');
    const data = part.subarray(sep + 4);
    const name = /name="([^"]*)"/i.exec(head)?.[1] || '';
    const filename = /filename="([^"]*)"/i.exec(head)?.[1];
    if (filename !== undefined) {
      files.push({ field: name, filename, data });
    } else {
      fields[name] = data.toString('utf8');
    }
  }
  return { fields, files };
}

const readBody = (req, limit = MAX_BYTES) =>
  new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        req.destroy();
        reject(Object.assign(new Error('文件过大'), { status: 413 }));
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });

const json = (res, status, obj) => {
  const b = Buffer.from(JSON.stringify(obj));
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': b.length,
    'Cache-Control': 'no-store',
  });
  res.end(b);
};

const PAGE = `<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>WorkBuddy 收件箱</title>
<style>
  :root{color-scheme:light dark}
  *{box-sizing:border-box}
  body{margin:0;font:15px/1.6 system-ui,-apple-system,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;
       background:#0f1115;color:#e8eaed;display:flex;flex-direction:column;min-height:100vh}
  header{padding:22px 24px 6px}
  h1{margin:0;font-size:19px;font-weight:650}
  p.sub{margin:6px 0 0;color:#9aa0a6;font-size:13px}
  main{flex:1;padding:18px 24px 28px;display:flex;flex-direction:column;gap:16px}
  #drop{border:2px dashed #3c4043;border-radius:14px;padding:44px 20px;text-align:center;
        transition:.15s;background:#15181d;cursor:pointer}
  #drop.hot{border-color:#8ab4f8;background:#1b2430}
  #drop b{font-size:16px;display:block;margin-bottom:6px}
  #drop span{color:#9aa0a6;font-size:13px}
  ul{list-style:none;margin:0;padding:0;display:grid;gap:8px}
  li{display:flex;justify-content:space-between;gap:12px;background:#15181d;border:1px solid #232830;
     border-radius:10px;padding:10px 14px;font-size:13px}
  li small{color:#8f9399;white-space:nowrap}
  .bar{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
  a{color:#8ab4f8;text-decoration:none}
  code{background:#1b1f26;padding:2px 6px;border-radius:5px;font-size:12px}
  #msg{font-size:13px;color:#8ab4f8;min-height:20px}
</style></head>
<body>
<header>
  <h1>WorkBuddy 收件箱</h1>
  <p class="sub">把文件拖进下面的框，或点击选择。文件会出现在容器内的
     <code>${INBOX}</code>，然后在 WorkBuddy 的文件选择器里选它（家目录里有 <code>收件箱</code> 快捷方式）。</p>
</header>
<main>
  <div id="drop">
    <b>拖文件到这里</b>
    <span>或点击选择（可多选，单次上限 ${Math.round(MAX_BYTES / 1024 / 1024)}MB）</span>
    <input id="file" type="file" multiple hidden>
  </div>
  <div id="msg"></div>
  <div class="bar"><strong style="font-size:13px">已收到的文件</strong>
    <a href="/" onclick="load()">刷新</a>
    <a href="#" id="toDesktop">去 WorkBuddy 桌面</a>
  </div>
  <ul id="list"></ul>
</main>
<script>
const drop=document.getElementById('drop'), input=document.getElementById('file'), list=document.getElementById('list'), msg=document.getElementById('msg');
document.getElementById('toDesktop').onclick=(e)=>{e.preventDefault();window.open('http://'+location.hostname+':8444/','_blank')};
drop.onclick=()=>input.click();
input.onchange=()=>send([...input.files]);
['dragenter','dragover'].forEach(t=>drop.addEventListener(t,e=>{e.preventDefault();drop.classList.add('hot')}));
['dragleave','drop'].forEach(t=>drop.addEventListener(t,e=>{e.preventDefault();drop.classList.remove('hot')}));
drop.addEventListener('drop',e=>{ if(e.dataTransfer.files.length) send([...e.dataTransfer.files]) });
async function send(files){
  if(!files.length)return;
  const fd=new FormData();
  files.forEach(f=>fd.append('files',f,f.name));
  msg.textContent='正在上传 '+files.length+' 个文件…';
  try{
    const r=await fetch('/upload',{method:'POST',body:fd});
    const j=await r.json();
    if(!j.ok) throw new Error(j.error||('HTTP '+r.status));
    msg.textContent='已收到 '+j.files.map(f=>f.name).join('、')+'，去 WorkBuddy 里选文件吧';
    load();
  }catch(err){ msg.textContent='上传失败：'+err.message }
  input.value='';
}
async function load(){
  try{
    const j=await (await fetch('/files')).json();
    list.innerHTML=(j.files||[]).map(f=>'<li><span>'+f.name.replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))+
      '</span><small>'+f.size_h+' · '+f.mtime+'</small></li>').join('')||'<li><span>还没有文件</span><small></small></li>';
  }catch{}
}
load();
</script>
</body></html>`;

function humanSize(n) {
  const u = ['B', 'KB', 'MB', 'GB'];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(n < 10 && i > 0 ? 1 : 0)}${u[i]}`;
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  try {
    if (url.pathname === '/' && req.method === 'GET') {
      const b = Buffer.from(PAGE);
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Content-Length': b.length });
      return res.end(b);
    }

    if (url.pathname === '/healthz') return json(res, 200, { ok: true, inbox: INBOX });

    if (url.pathname === '/files' && req.method === 'GET') {
      const names = await fsp.readdir(INBOX).catch(() => []);
      const out = [];
      for (const n of names) {
        if (n.startsWith('.')) continue;
        const st = await fsp.stat(path.join(INBOX, n)).catch(() => null);
        if (!st?.isFile()) continue;
        out.push({ name: n, size: st.size, size_h: humanSize(st.size), mtime: st.mtime.toISOString().slice(0, 16).replace('T', ' ') });
      }
      out.sort((a, b) => (a.mtime < b.mtime ? 1 : -1));
      return json(res, 200, { ok: true, inbox: INBOX, files: out });
    }

    if (url.pathname === '/upload' && req.method === 'POST') {
      const ct = req.headers['content-type'] || '';
      if (!ct.startsWith('multipart/form-data')) return json(res, 400, { ok: false, error: '需要 multipart/form-data' });
      const buf = await readBody(req);
      const { files } = parseMultipart(buf, ct);
      if (!files.length) return json(res, 400, { ok: false, error: '没有收到文件' });
      const saved = [];
      for (const f of files) {
        const base = path.basename(f.filename || 'file').replace(/[\\/:*?"<>|]/g, '_').slice(0, 120);
        let name = base;
        let i = 1;
        const ext = path.extname(base);
        const stem = path.basename(base, ext);
        while (fs.existsSync(path.join(INBOX, name))) name = `${stem}-${++i}${ext}`;
        await fsp.writeFile(path.join(INBOX, name), f.data);
        saved.push({ name, size: f.data.length });
        log(`收到文件 ${name} (${humanSize(f.data.length)})`);
      }
      return json(res, 200, { ok: true, files: saved, inbox: INBOX });
    }

    return json(res, 404, { ok: false, error: 'not_found' });
  } catch (e) {
    log('请求失败', e.message);
    return json(res, e.status || 500, { ok: false, error: e.message });
  }
});

server.listen(PORT, HOST, () => {
  log(`收件箱服务已启动：http://${HOST}:${PORT}/  →  ${INBOX}`);
});
