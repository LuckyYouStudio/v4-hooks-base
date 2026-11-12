import sys, random, time
from decimal import Decimal, getcontext
getcontext().prec = 90
MIN_TICK=-887272; MAX_TICK=887272
MIN_SP=4295128739; MAX_SP=1461446703485210103287273052203988822378723970342
C=[0xfffcb933bd6fad37aa2d162d1a594001,0xfff97272373d413259a46990580e213a,0xfff2e50f5f656932ef12357cf3c7fdcc,0xffe5caca7e10e4e61c3624eaa0941cd0,0xffcb9843d60f6159c9db58835c926644,0xff973b41fa98c081472e6896dfb254c0,0xff2ea16466c96a3843ec78b326b52861,0xfe5dee046a99a2a811c461f1969c3053,0xfcbe86c7900a88aedcffc83b479aa3a4,0xf987a7253ac413176f2b074cf7815e54,0xf3392b0822b70005940c7a398e4b70f3,0xe7159475a2c29b7443b29c7fa6e889d9,0xd097f3bdfd2022b8845ad8f792aa5825,0xa9f746462d870fdf8a65dc1f90e061e5,0x70d869a156d2a1b890bb3df62baf32f7,0x31be135f97d08fd981231505542fcfa6,0x9aa508b5b7a84e1c677de54f3e99bc9,0x5d6af8dedb81196699c329225ee604,0x2216e584f5fa1ea926041bedfe98,0x48a170391f7dc42444e8fa2]
M256=(1<<256)-1
def sp(tick):
    a=abs(tick); assert a<=MAX_TICK
    price=C[0] if a&1 else 1<<128
    for i in range(1,20):
        if a&(1<<i): price=(price*C[i])>>128
    if tick>0: price=M256//price
    return (price+0xffffffff)>>32
def tk(p):
    assert MIN_SP<=p<MAX_SP
    price=p<<32; msb=price.bit_length()-1
    r = price>>(msb-127) if msb>=128 else price<<(127-msb)
    log2=(msb-128)<<64
    for i in range(63,49,-1):
        r=(r*r)>>127; f=r>>128; log2|=f<<i; r>>=f
    ls=log2*255738958999603826347141
    lo=(ls-3402992956809132418596140100660247210)>>128
    hi=(ls+291339464771989622907027621153398088495)>>128
    return lo if lo==hi else (hi if sp(hi)<=p else lo)
def logPrice(p):
    t=tk(p); lo=sp(t); hi=sp(t+1)
    assert lo<=p<hi, (p,t,lo,hi)
    frac=(p-lo)*1000//(hi-lo)
    assert 0<=frac<=999
    return t*1000+frac
LN=Decimal('1.0001').ln()
def true(p):
    return (Decimal(p)/Decimal(2**96)).ln()*2/LN*1000
if __name__=='__main__':
    mode=sys.argv[1]
    if mode=='bound':
        # every tick boundary: logPrice(sp(t)) == 1000 t ; logPrice(sp(t)-1) == 1000t-1 ; width >= 1000
        t0=time.time(); minw=None; bad=0; maxerr=Decimal(0)
        prev=sp(MIN_TICK)
        assert prev==MIN_SP and sp(MAX_TICK)==MAX_SP
        for t in range(MIN_TICK+1, MAX_TICK+1):
            cur=sp(t); w=cur-prev
            if minw is None or w<minw: minw=(w)
            assert cur>prev
            if t<MAX_TICK:
                a=logPrice(cur)
                if a!=1000*t: bad+=1; print('bad at',t,a)
            b=logPrice(cur-1)
            if b!=1000*t-1: bad+=1; print('bad below',t,b)
            prev=cur
        print('boundaries checked', MAX_TICK-MIN_TICK, 'bad',bad,'min tick width(sqrt units)',minw, 'secs',time.time()-t0)
    if mode=='rand':
        random.seed(int(sys.argv[2])); n=int(sys.argv[3]); mx=Decimal(0); mxat=None; cnt=[0,0,0]
        import math
        for i in range(n):
            k=i%4
            if k==0:
                e=random.uniform(math.log(MIN_SP),math.log(MAX_SP)); p=min(MAX_SP-1,max(MIN_SP,int(math.exp(e))))
            elif k==1:
                t=random.randint(MIN_TICK,MAX_TICK-1); p=sp(t)+random.randint(0,3)
            elif k==2:
                t=random.randint(MIN_TICK+1,MAX_TICK); p=sp(t)-random.randint(1,3)
            else:
                t=random.choice([MIN_TICK,MIN_TICK+1,MAX_TICK-1,MAX_TICK-2, -1,0,1]); lo=sp(t); hi=sp(t+1); p=random.randint(lo,hi-1)
            x=logPrice(p); tr=true(p); err=Decimal(x)-tr  # x should be ~floor(tr)
            fl=int(tr.to_integral_value(rounding='ROUND_FLOOR'))
            d=x-fl
            cnt[d+1 if -1<=d<=1 else 0]+=1
            assert -1<=d<=1,(p,x,tr)
            if abs(err)>mx: mx=abs(err); mxat=p
            # one-unit step
            if p+1<MAX_SP:
                s=logPrice(p+1)-x; assert s in (0,1),(p,s)
        print('n',n,'max |logPrice-true| (mtick)',mx,'at',mxat,'floor diff counts [-1,0,+1]',cnt)
    if mode=='ends':
        for p in [MIN_SP,MIN_SP+1,MAX_SP-1,MAX_SP-2]:
            print(p,logPrice(p),true(p))
        print('tick width at MIN', sp(MIN_TICK+1)-sp(MIN_TICK))
