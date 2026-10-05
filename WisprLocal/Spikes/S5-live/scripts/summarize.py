import sys, os
sys.path.insert(0, os.path.dirname(__file__)); from rows import rows
os.chdir(os.path.join(os.path.dirname(__file__), '..'))
print('| mode | model | cadence | clip s | updates | lat p50/p95/max ms | duty | CPU s / audio s | energy J | upd. w/ rewrite raw/norm | words rewritten raw/norm | max depth | preview WER vs full |')
print('|'+'---|'*13)
for f in ['results/full.jsonl', 'results/tail.jsonl']:
    for d in rows(f):
        if d['mode']=='tail' and (d['holdSec']!=1.5 or d['ctxSec']!=2): continue
        pw = d.get('previewWERvsFull')
        print(f"| {d['mode']} | {d['model']} | {d['cadenceMs']} | {d['audioSec']:.1f} | {d['updates']} | {d['latP50']:.0f}/{d['latP95']:.0f}/{d['latMax']:.0f} | {d['dutyCycle']*100:.0f}% | {d['cpuPerAudioSec']:.3f} | {d['energyJ']:.1f} | {d['rewriteUpdates']}/{d['rewriteUpdatesNorm']} | {d['wordsRewritten']}/{d['wordsRewrittenNorm']} | {d['maxDepthWords']} | {'—' if pw is None else f'{pw*100:.1f}%'} |")
