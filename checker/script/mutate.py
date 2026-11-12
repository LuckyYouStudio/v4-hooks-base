#!/usr/bin/env python3
# Mutation check of the checker's own test suite. NOT part of the checker; nothing here is compiled.
#
# RUN IT IN A COPY OF hooks/ ONLY: it rewrites files under checker/src and checker/test in place while it
# runs (and restores them at the end; an interrupted run leaves a mutated file behind).
#
#   cp -R hooks /tmp/hooks-mut && cd /tmp/hooks-mut
#   python3 checker/script/mutate.py all                        # every M and R mutation, offline tests
#   python3 checker/script/mutate.py M7,R10                     # a selection
#   BASE_RPC_URL=https://mainnet.base.org python3 checker/script/mutate.py R1,R2 '--match-contract ForkReentryTest'
#
# M1..M12: the 12 mutations of the first H3 audit (audits/audit-hooks-h3/mutate.py), same semantics,
#          pattern strings rewritten where the code changed. M5 now returns class 3 ("reverted on both
#          pools") instead of the old class 0, which is what "the control pool masks the hook's revert"
#          means in the current classification.
# R1..R14: each undoes ONE fix made after that audit; the regression test of that fix has to fail.
#          R1 and R2 (re-entrancy guard, fork check) only show on a fork: run them with the third form.
# Q1..Q12: each undoes ONE fix made after the re-audit. Q8 (the clock) is also worth running on a fork:
#          BASE_RPC_URL=... python3 checker/script/mutate.py Q8 '--match-contract ForkReaudit2RegressionTest'
# The re-audit's own 14 mutations (N1..N14) are in audits/audit-hooks-h3/reaudit/mutate2.py.
import sys,subprocess,re,os,shutil
FORGE=shutil.which('forge') or os.path.expanduser('~/.foundry/bin/forge')
src={'H':'checker/src/HookChecker.sol','O':'checker/src/CheckerOps.sol','B':'checker/src/lib/BytecodeScan.sol','R':'checker/src/lib/RevertInfo.sol','E':'checker/test/CheckHook.t.sol'}
orig={k:open(v).read() for k,v in src.items()}
M=[
 ("M1 _classify: Panic no longer 'unexpected'",'H',"if (h.err.kind == RevertInfo.Kind.EMPTY || h.err.kind == RevertInfo.Kind.PANIC) return 2;","if (h.err.kind == RevertInfo.Kind.EMPTY) return 2;"),
 ("M2 b: stranger never probed inside an unlock",'H',"Probe memory p = _probe(ATTACKER, ins[i].origin, data, u == 1);","Probe memory p = _probe(ATTACKER, ins[i].origin, data, false);"),
 ("M3 b: effect = hook's own storage writes only (no events, no ETH, no other contracts)",'H',"bool effect = p.writes > 0 || p.valueMoved || p.logs > 0;","bool effect = p.hookWrites > 0;"),
 ("M4 c: shared changed slot no longer UNKNOWN",'H',"        } else if (shared > 0) {","        } else if (shared > 1000) {"),
 ("M5 _classify: control-pool revert masks a revert that came out of the hook",'H',"        if (_fromHook(h)) {\n            if (h.oog) return 2;","        if (_fromHook(h) && ctl.ok) {\n            if (h.oog) return 2;"),
 ("M6 h: ERC-6909 claims ignored",'H',"        for (uint256 i; i < 4; i++) {\n            if (now_[4] & (1 << i) == 0","        for (uint256 i; i < 2; i++) {\n            if (now_[4] & (1 << i) == 0"),
 ("M7 f: same-block test ignores the swap after the large opposite swap",'H',"diff = s1.out.fee != s2.out.fee || s1.out.fee != s3.out.fee;","diff = s1.out.fee != s2.out.fee;"),
 ("M8 i: ratio spread no longer a hint (only take/no-take)",'H',"(withTake < measured || maxPpm > minPpm + minPpm / 4 + 2)","(withTake < measured)"),
 ("M9 e: no 1-wei and no 100x swaps",'H',"        if (sc == SC_BASELINE) {\n            // sizes at both ends","        if (false) {\n            // sizes at both ends"),
 ("M10 c: reference swaps compared without fee and pool amounts",'H',"same = same && x.c0 == y.c0 && x.c1 == y.c1 && x.p0 == y.p0 && x.p1 == y.p1 && x.fee == y.fee;","same = same && x.c0 == y.c0 && x.c1 == y.c1;"),
 ("M11 d: fee-collection step (liquidityDelta 0) and last-LP step not run",'H',"if (s == 3 && (sc == SC_SINGLE_LP || !env.hasB)) continue;","if (s == 0 || s == 3) continue;"),
 ("M12 b: 'indistinct' comparison disabled",'H',"if (m.infraOk && !m.ok && m.retSize == p.retSize && keccak256(m.ret) == keccak256(p.ret)) {","if (false && m.infraOk) {"),
 # ---- each undoes one fix
 ("R1 H-1 undone: no re-entrancy guard",'H',"    modifier notWhileChecking() {\n        if (_busy) revert CheckerBusy();","    modifier notWhileChecking() {\n        if (false) revert CheckerBusy();"),
 ("R2 H-1 undone: active fork / chain no longer compared",'O',"        uint256 f = _forkTag();\n        if (f != _fork0) {","        uint256 f = _forkTag();\n        if (false) {"),
 ("R3 H-1 undone: tooling failures not recognised",'O',"res.infra = _toolingBroken();","res.infra = false;"),
 ("R4 H-2 undone: 'reverted on both pools' is PASS again (d and e)",'H',None,None),
 ("R5 M-1 undone: c compares the 6 swaps only",'H',"        for (uint256 c; c < REF_OPS; c++) {\n            bool same","        for (uint256 c; c < 6; c++) {\n            bool same"),
 ("R6 M-2 undone: only the two original probe inputs",'H',"            bytes memory data = _cbData(env, k, ins[i].sender, ins[i].hookData);\n","            if (i != 0 && i != 6) continue;\n            bytes memory data = _cbData(env, k, ins[i].sender, ins[i].hookData);\n"),
 ("R7 M-3 undone: scan cuts the metadata-shaped trailer",'B',"        return _sweep(code, code.length);","        return _sweep(code, _codeEnd(code));"),
 ("R8 M-4 undone: unknown chain does not stop the entry",'E',"        revert PoolManagerRequired(chainId);","        return address(0);"),
 ("R9 L-1 undone: old character filter",'R',"            out[i] = fine ? c : bytes1(\"?\");","            fine = uint8(c) >= 0x20 && uint8(c) < 0x7f && c != \"|\" && c != \"`\" && c != \"\\\"\" && c != \"<\";\n            out[i] = fine ? c : bytes1(\"?\");"),
 ("R10 L-2 undone: all-zero fees pass",'H',"        } else if (acc.feeMax == 0) {","        } else if (false) {"),
 ("R11 L-3 undone: a rejected stranger pool is PASS whether or not the checker has a pool",'H',"            if (env.poolReady) {\n                f.status = Status.PASS;","            if (true) {\n                f.status = Status.PASS;"),
 ("R12 L-3 undone: no stranger pool that shares a currency",'H',"        if (!a.shareCurrency) return;","        if (true) return;"),
 ("R13 L-6 undone: slots beyond the cap dropped silently",'H',"                        truncated = true;\n                        continue;","                        continue;"),
 ("R14 H-2 undone: no exactOut 100x swaps (was a listed false negative)",'H',None,None),
 # ---- Q1..Q12: each undoes ONE fix made after the re-audit (audits/audit-hooks-h3-reaudit.md)
 ("Q1 N-1 undone: a failed withdrawal during scenario set-up is not counted against the hook",'H',"            acc.dFail++;\n            tag = \"REVERT\";","            tag = \"REVERT\";"),
 ("Q2 N-1 undone: d is PASS although scenarios were NOT TESTED",'H',"        } else if (acc.dSkip > 0) {","        } else if (false) {"),
 ("Q3 N-2 undone: CheatcodeError-shaped revert data counts as a tooling failure",'O',"res.infra = _toolingBroken();","res.infra = res.err.cheatcode || _toolingBroken();"),
 ("Q4 N-2 undone: tooling state is looked at before hook attribution",'H',"        if (_fromHook(h)) {\n            if (h.oog) return 2;","        if (h.infra || ctl.infra) return 4;\n        if (_fromHook(h)) {\n            if (h.oog) return 2;"),
 ("Q5 N-2 undone (c): a probe failure hides a difference attributed to the hook",'H',"        if (hookDiffs > 0) {","        if (hookDiffs > 0 && !with_.infra) {"),
 ("Q6 N-3 undone: a void report keeps its setup lines",'H',"        rep.setup = new string[](0);\n",""),
 ("Q7 N-3 undone: a void report renders its Setup section",'H',"        if (rep.voided) return out;\n        out = string.concat(out, \"\\n## Setup\\n\\n\");","        out = string.concat(out, \"\\n## Setup\\n\\n\");"),
 ("Q8 N-4 undone: the checker's clock is not checked",'O',"        if (_clockOff()) {\n            return string.concat(","        if (false) {\n            return string.concat("),
 ("Q11 N-4 undone: no environment check before a per-swap snapshot is rolled back",'H',"        _taintCheck(env); // before the rollback, see _runScenarios\n        _rollback(snap);\n\n        _evidence(env, 3, h.op);","        _rollback(snap);\n\n        _evidence(env, 3, h.op);"),
 ("Q12 the stranger's shared-currency pool takes whatever token order its new token's address gives",'H',"                if (i != 0) vm.setNonce(address(this), nonce + i);\n",""),
 ("Q9 N-4 undone: c passes on a reference flow in which nothing works",'H',"        } else if (okOps == 0 || okSwaps == 0) {","        } else if (false) {"),
 ("Q10 N-5 undone: no stranger pools with extreme parameters",'H',"        _strangerExtremes(a, o);\n",""),
]
R4=[("        } else if (acc.dBoth > 0) {","        } else if (false) {"),("        } else if (acc.eBoth > 0) {","        } else if (false) {")]
R14=[('            line = string.concat(line, " | 100x 0->1 exactOut ", _oneSwap(env, acc, sc, 1, int256(env.amt1 * 100), false));\n',''),('            line = string.concat(line, " | 100x 1->0 exactOut ", _oneSwap(env, acc, sc, 3, int256(env.amt0 * 100), false));\n','')]
extra=sys.argv[2] if len(sys.argv)>2 else '--no-match-path "checker/test/fork/*"'
sel=sys.argv[1].split(',') if len(sys.argv)>1 and sys.argv[1]!='all' else []
for name,f,a,b in M:
    tag=name.split()[0]
    if sel and tag not in sel: continue
    pairs=[(a,b)] if a is not None else (R4 if tag=='R4' else R14)
    text=orig[f]
    for a,b in pairs:
        assert text.count(a)==1,(name,text.count(a))
        text=text.replace(a,b)
    open(src[f],'w').write(text)
    try:
        r=subprocess.run('FOUNDRY_PROFILE=checker '+FORGE+' test '+extra+' 2>&1',shell=True,capture_output=True,text=True,timeout=1500)
        out=r.stdout
    except subprocess.TimeoutExpired:
        out='TIMEOUT'
    open(src[f],'w').write(orig[f])
    fails=sorted(set(re.findall(r'^\[FAIL.*\] (\w+)\(',out,re.M)))  # greedy: failure messages may contain ']'
    tot=re.findall(r'(\d+) tests passed, (\d+) failed',out)
    comp='Compiler run failed' in out
    res='TIMEOUT' if out=='TIMEOUT' else 'COMPILE ERROR' if comp else ('KILLED by '+str(len(fails))+' test(s): '+', '.join(fails[:8]) if fails else 'SURVIVED')
    print(f"{name}\n   -> {res}  {tot}",flush=True)
for k,v in src.items(): open(v,'w').write(orig[k])
print("RESTORED",flush=True)
