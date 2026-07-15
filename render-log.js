#!/usr/bin/env node
// render-log.js — le stream-json (claude -p --output-format stream-json --verbose)
// da stdin e escreve texto legivel na stdout: pensamento, texto e chamadas de
// ferramenta. Linhas que nao sao JSON valido (erros de CLI, rate-limit) passam
// direto, sem trava.
const readline = require('readline');
const rl = readline.createInterface({ input: process.stdin, terminal: false });

const brief = (v) => {
  const s = typeof v === 'string' ? v : JSON.stringify(v);
  return s.length > 200 ? s.slice(0, 200) + '…' : s;
};

rl.on('line', (line) => {
  if (!line.trim()) return;
  let msg;
  try { msg = JSON.parse(line); } catch { console.log(line); return; }

  const blocks = msg.message && msg.message.content;
  if (msg.type === 'assistant' && Array.isArray(blocks)) {
    for (const b of blocks) {
      if (b.type === 'thinking') console.log('\n🧠 [thinking] ' + b.thinking);
      else if (b.type === 'text') console.log('\n' + b.text);
      else if (b.type === 'tool_use') console.log('\n🔧 [tool] ' + b.name + '(' + brief(b.input) + ')');
    }
  } else if (msg.type === 'user' && Array.isArray(blocks)) {
    for (const b of blocks) {
      if (b.type === 'tool_result') {
        const content = Array.isArray(b.content) ? b.content.map((c) => (c.text !== undefined ? c.text : brief(c))).join(' ') : brief(b.content);
        console.log('↳ ' + brief(content));
      }
    }
  } else if (msg.type === 'result') {
    const subtype = msg.subtype !== undefined ? msg.subtype : (msg.result !== undefined ? msg.result : '');
    const dur = msg.duration_ms !== undefined ? msg.duration_ms : '?';
    const cost = msg.total_cost_usd !== undefined ? msg.total_cost_usd : '?';
    console.log('\n=== resultado: ' + subtype + ' (' + dur + 'ms, $' + cost + ') ===');
    if (msg.result) console.log(msg.result);
  }
  // outros tipos (system/init etc.) sao ruido de inicializacao — ignorados
});
