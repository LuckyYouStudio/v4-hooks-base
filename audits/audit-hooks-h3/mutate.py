import sys,subprocess,os,re
src='checker/src/HookChecker.sol'
orig=open('HookChecker.pristine').read()
M=[
 ("M1 _classify: Panic no longer 'unexpected'","if (h.err.kind == RevertInfo.Kind.EMPTY || h.err.kind == RevertInfo.Kind.PANIC) return 2;","if (h.err.kind == RevertInfo.Kind.EMPTY) return 2;"),
 ("M2 b: stranger never probed inside an unlock","Probe memory p = _probe(ATTACKER, data, v & 1 != 0);","Probe memory p = _probe(ATTACKER, data, false);"),
 ("M3 b: effect = hook's own storage writes only (no events, no ETH, no other contracts)","bool effect = p.writes > 0 || p.valueMoved || p.logs > 0;","bool effect = p.hookWrites > 0;"),
 ("M4 c: shared changed slot no longer UNKNOWN","} else if (shared > 0) {\n            f.status = Status.UNKNOWN;\n            f.summary = \"stranger pool accepted; it changes","} else if (shared > 1000) {\n            f.status = Status.UNKNOWN;\n            f.summary = \"stranger pool accepted; it changes"),
 ("M5 _classify: control-pool revert masks a revert that came out of the hook","        if (h.oog) return 2;\n","        if (h.oog) return 2;\n        if (!ctl.ok) return 0;\n"),
 ("M6 h: ERC-6909 claims ignored","        for (uint256 i; i < 4; i++) {\n            if (now_[4] & (1 << i) == 0","        for (uint256 i; i < 2; i++) {\n            if (now_[4] & (1 << i) == 0"),
 ("M7 f: same-block test ignores the swap after the large opposite swap","acc.sameBlockDiff = s1.out.fee != s2.out.fee || s1.out.fee != s3.out.fee;","acc.sameBlockDiff = s1.out.fee != s2.out.fee;"),
 ("M8 i: ratio spread no longer a hint (only take/no-take)","(withTake < measured || maxPpm > minPpm + minPpm / 4 + 2)","(withTake < measured)"),
 ("M9 e: no 1-wei and no 100x swaps","        if (sc == SC_BASELINE) {\n            // sizes at both ends","        if (false) {\n            // sizes at both ends"),
 ("M10 c: reference swaps compared without fee and pool amounts","&& x.p0 == y.p0 && x.p1 == y.p1 && x.fee == y.fee;",";"),
 ("M11 d: fee-collection step (liquidityDelta 0) and last-LP step not run","if (s == 3 && (sc == SC_SINGLE_LP || !env.hasB)) continue;","if (s == 0 || s == 3) continue;"),
 ("M12 b: 'indistinct' comparison disabled","if (m.infraOk && !m.ok && m.retSize == p.retSize && keccak256(m.ret) == keccak256(p.ret)) {","if (false && m.infraOk) {"),
]
sel=sys.argv[1:] 
for name,a,b in M:
    if sel and name.split()[0] not in sel: continue
    assert orig.count(a)==1,(name,orig.count(a))
    open(src,'w').write(orig.replace(a,b))
    r=subprocess.run('FOUNDRY_PROFILE=checker forge test --no-match-path "checker/test/*/*" 2>&1',shell=True,capture_output=True,text=True)
    out=r.stdout
    fails=re.findall(r'\[FAIL[^\]]*\] (\w+)\(',out)
    tot=re.findall(r'(\d+) tests passed, (\d+) failed',out)
    comp='Compiler run failed' in out
    print(f"{name}\n   -> {'COMPILE ERROR' if comp else ('KILLED by '+str(len(set(fails)))+' test(s): '+', '.join(sorted(set(fails))[:6]) if fails else 'SURVIVED')}  {tot}")
open(src,'w').write(orig)
