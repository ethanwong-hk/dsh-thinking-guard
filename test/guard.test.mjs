// 相对本文件解析，避免写死安装位置（否则随包分发会泄露维护者的本机目录）
const mod = await import(new URL('../lib/index.js', import.meta.url).href);
function h(config) {
  const handlers = new Map();
  mod.apply({ on: (e, f) => handlers.set(e, f), effect: (f) => f() }, config);
  const events = []; let rev = 0, idx = 0;
  const agent = { session: { id: 's' }, cancel: (c) => events.push({ type: 'cancel', cause: c }), followup: () => {} };
  return {
    start: () => handlers.get('agent/assistant-stream')({ agent, frame: { type:'start', attemptId:'a', revision:++rev, turn:1, step:1 } }),
    chunk: (c) => handlers.get('agent/assistant-stream')({ agent, frame: { type:'chunk', attemptId:'a', revision:++rev, index:idx++, time:Date.now(), chunk:c } }),
    tripped: () => events.find((e) => e.type === 'cancel'),
  };
}
let pass=0, fail=0;
const check=(l,g,w)=>{const ok=g===w; ok?pass++:fail++; console.log(`[${ok?'PASS':'FAIL'}] ${l}  熔断=${g} 期望=${w}`);};

// 1 纯思考超时
{ const t=h({thinkingOnlyMs:60,checkEveryChars:1e9,notify:false}); t.start();
  await new Promise(r=>setTimeout(r,80));
  for(let i=0;i<5;i++) t.chunk({type:'reasoning-delta',index:0,text:`思考片段 ${i}，仍未形成结论。`});
  check('场景1 纯思考超时',!!t.tripped(),true); }

// 2 YG 样本复读
{ const t=h({thinkingOnlyMs:1e9,checkEveryChars:1,notify:false}); t.start();
  const s='好。执行。好。（输出工具调用）'.repeat(12);
  for(let i=0;i<s.length;i+=20) t.chunk({type:'reasoning-delta',index:0,text:s.slice(i,i+20)});
  check('场景2 退化循环复读',!!t.tripped(),true); }

// 3 容量上限
{ const t=h({thinkingOnlyMs:1e9,maxThinkingChars:300,checkEveryChars:1e9,notify:false}); t.start();
  for(let i=0;i<20;i++) t.chunk({type:'reasoning-delta',index:0,text:'一段没有结论的思考内容，持续消耗资源而无任何产出。'});
  check('场景3 思考容量上限',!!t.tripped(),true); }

// 4 正常回合（每轮内容不同，逼近真实）
{ const t=h({thinkingOnlyMs:60,maxThinkingChars:300,checkEveryChars:1,notify:false}); t.start();
  for(let i=0;i<12;i++){
    t.chunk({type:'reasoning-delta',index:0,text:`第 ${i} 步需要先确认目标服务的版本信息。`});
    t.chunk({type:'text-delta',index:1,text:`正在处理第 ${i} 项检查，结果已记录到证据文件。`});
  }
  check('场景4 正常回合放行',!!t.tripped(),false); }

// 5 工具调用
{ const t=h({thinkingOnlyMs:60,maxThinkingChars:300,checkEveryChars:1,notify:false}); t.start();
  for(let i=0;i<12;i++){ t.chunk({type:'reasoning-delta',index:0,text:'准备调用工具。'}); t.chunk({type:'tool-call-delta',index:1,id:'c',name:'bash',argumentsDelta:'{"command":' }); }
  check('场景5 工具调用放行',!!t.tripped(),false); }

// 6 有产出后短思考
{ const t=h({thinkingOnlyMs:1e9,maxThinkingChars:1e9,checkEveryChars:1,notify:false}); t.start();
  t.chunk({type:'text-delta',index:1,text:'已输出一段正式回复。'});
  await new Promise(r=>setTimeout(r,80));
  for(let i=0;i<5;i++) t.chunk({type:'reasoning-delta',index:0,text:'继续思考但没有新产出。'});
  check('场景6 有产出后短思考放行',!!t.tripped(),false); }

// 7 正常结束（各句实质不同）
{ const t=h({thinkingOnlyMs:1e9,maxThinkingChars:1e9,checkEveryChars:1,notify:false}); t.start();
  const lines=['先确认服务端口与协议。','检查证书链的颁发者字段。','比对中国件响应头顺序。','核对错误页模板哈希。','记录归属判定依据。','标注仍需复核的条目。','换一条路径扩展侦察。','汇总证据链后收束。','整理未完成事项清单。','输出最终结论与建议。'];
  for(const line of lines) t.chunk({type:'text-delta',index:1,text:line});
  t.chunk({type:'finish',reason:{kind:'stop'}});
  check('场景7 正常结束放行',!!t.tripped(),false); }

// 8 有产出仍限容量
{ const t=h({thinkingOnlyMs:1e9,maxThinkingChars:400,checkEveryChars:1e9,notify:false}); t.start();
  t.chunk({type:'text-delta',index:1,text:'先输出一小段文本。'});
  for(let i=0;i<20;i++) t.chunk({type:'reasoning-delta',index:0,text:'随后陷入无限思考，继续消耗而不产出结论。'});
  check('场景8 有产出仍限容量',!!t.tripped(),true); }

// 9 文本复读
{ const t=h({thinkingOnlyMs:1e9,maxThinkingChars:1e9,checkEveryChars:1,notify:false}); t.start();
  const s='正在重新整理思路，稍后输出。'.repeat(20);
  for(let i=0;i<s.length;i+=25) t.chunk({type:'text-delta',index:1,text:s.slice(i,i+25)});
  check('场景9 文本复读熔断',!!t.tripped(),true); }

// 10 长正常技术文本
{ const t=h({thinkingOnlyMs:1e9,maxThinkingChars:1e9,checkEveryChars:1,notify:false}); t.start();
  const para=['先确认目标服务的监听端口与证书链。','再比对中国件指纹，包括响应头顺序与错误页哈希。','随后核对静态资源路径的命名习惯，判断归属。','综合以上证据后记录确认方法，并标注待复核项。','如果证据不足则扩展侦察角度，换一条路径重新验证。'];
  for(let r=0;r<4;r++) for(const p of para) t.chunk({type:'text-delta',index:1,text:p});
  check('场景10 长正常文本放行',!!t.tripped(),false); }

// 11 稀疏复读（跨大窗口短句高次重复，前三档在 600 字窗口内密度不足会漏检）
// 回归用例：此档曾因 formatNotice 引用模块级 cfg 抛 ReferenceError，
// 导致 cancel 永不执行、熔断静默失效（线上日志累计 500+ 次）。
{ const t=h({thinkingOnlyMs:1e9,maxThinkingChars:1e9,checkEveryChars:1,notify:false}); t.start();
  const parts=[]; for(let i=0;i<12;i++) parts.push('好。执行。', `第 ${i} 段实质不同的分析内容，用于拉开窗口距离。`);
  const s=parts.join('');
  let threw=null;
  for(let i=0;i<s.length;i+=40){ try{ t.chunk({type:'reasoning-delta',index:0,text:s.slice(i,i+40)}); }catch(e){ threw=e; break; } }
  check('场景11 稀疏复读熔断且不抛异常', threw===null && !!t.tripped(), true); }

console.log(`\n合计：${pass} 通过 / ${fail} 失败`);
process.exit(fail===0?0:1);
