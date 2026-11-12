#!/usr/bin/env python3
# hook-auditor, H3 re-audit: new mutations aimed at the decision logic added by the fixes. Run in a COPY of hooks/.
import sys,subprocess,re,os
src={'H':'checker/src/HookChecker.sol','O':'checker/src/CheckerOps.sol','B':'checker/src/lib/BytecodeScan.sol'}
orig={k:open(v).read() for k,v in src.items()}
M=[
 ("N1 void: _void no longer resets the statuses",'H',"            rep.findings[i].status = Status.UNKNOWN;\n            rep.findings[i].summary = \"REPORT VOID","            rep.findings[i].summary = \"REPORT VOID"),
 ("N2 void: chain id no longer compared",'O',"        if (block.chainid != _chain0) {\n            return string.concat(\"the chain id changed","        if (false) {\n            return string.concat(\"the chain id changed"),
 ("N3 classify: a tooling failure on the CONTROL pool is not a probe failure",'H',"if (h.infra || ctl.infra) return 4;","if (h.infra) return 4;"),
 ("N4 d: probe failures no longer stop a PASS",'H',"        } else if (acc.dInfra > 0) {","        } else if (false) {"),
 ("N5 c: liquidity reference ops compared by ok/err only (router deltas ignored)",'H',"same = same && without.l0[c - 6] == with_.l0[c - 6] && without.l1[c - 6] == with_.l1[c - 6];","same = same && true;"),
 ("N6 c: revert selector of a reference op not compared",'H',"bool same = without.ok[c] == with_.ok[c] && without.err[c] == with_.err[c];","bool same = without.ok[c] == with_.ok[c];"),
 ("N7 g: DELEGATECALL decided on the trailer-cut sweep",'H',"        if (env.ops.delegatecall) {","        if (env.opsCode.delegatecall) {"),
 ("N8 taint: no environment check between scenarios",'H',"            if (_taintCheck(env)) return acc;","            if (false) return acc;"),
 ("N9 e: probe failures no longer stop a PASS",'H',"        } else if (acc.eInfra > 0) {","        } else if (false) {"),
 ("N10 c: tooling failure in the recorded flow ignored",'H',"        if (with_.infra) {","        if (false) {"),
 ("N11 c: small-add reference op (index 8) not compared",'H',"        for (uint256 c; c < REF_OPS; c++) {\n            bool same","        for (uint256 c; c < REF_OPS - 1; c++) {\n            bool same"),
 ("N12 d: a step that reverts on both pools counted as ok",'H',"                acc.dBoth++;\n                line = string.concat(line, \" | \", short[s], \" reverts (also without hook)\");","                acc.dOk++;\n                line = string.concat(line, \" | \", short[s], \" reverts (also without hook)\");"),
 ("N13 renderReport: a void report prints its details",'H',"        if (rep.voided) return out;","        if (false) return out;"),
 ("N14 runChecks: failed final rollback not reported",'H',"if (bytes(why).length == 0 && !rolled) why = \"the final state rollback failed\";",""),
]
extra=sys.argv[2] if len(sys.argv)>2 else '--no-match-path "checker/test/fork/*"'
sel=sys.argv[1].split(',') if len(sys.argv)>1 and sys.argv[1]!='all' else []
forge=os.path.expanduser('~/.foundry/bin/forge')
for name,f,a,b in M:
    tag=name.split()[0]
    if sel and tag not in sel: continue
    text=orig[f]
    assert text.count(a)==1,(name,text.count(a))
    open(src[f],'w').write(text.replace(a,b))
    try:
        r=subprocess.run('FOUNDRY_PROFILE=checker '+forge+' test '+extra+' 2>&1',shell=True,capture_output=True,text=True,timeout=1500)
        out=r.stdout
    except subprocess.TimeoutExpired:
        out='TIMEOUT'
    open(src[f],'w').write(orig[f])
    fails=sorted(set(re.findall(r'^\[FAIL.*\] (\w+)\(',out,re.M)))
    tot=re.findall(r'(\d+) tests passed, (\d+) failed',out)
    comp='Compiler run failed' in out
    res='TIMEOUT' if out=='TIMEOUT' else 'COMPILE ERROR' if comp else ('KILLED by '+str(len(fails))+' test(s): '+', '.join(fails[:8]) if fails else 'SURVIVED')
    print(f"{name}\n   -> {res}  {tot}",flush=True)
for k,v in src.items(): open(v,'w').write(orig[k])
print("RESTORED",flush=True)
