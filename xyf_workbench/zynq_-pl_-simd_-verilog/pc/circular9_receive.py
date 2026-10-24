"""Receive C9C2: retain original rational-rate PCM and all provenance packets.

python pc/circular9_receive.py --seconds 30 --output recordings/run01
Use a new directory. Discontinuities start new PCM files; no silent concatenation.
"""
import argparse
import json
from pathlib import Path
import socket
import struct
import time
import zlib

def decode(data):
    if len(data)<200:raise ValueError('short packet')
    h=struct.unpack_from('<16I',data)
    if h[:3]!=(0x32433943,2,64) or not 1<=h[5]<=8 or h[6:11]!=(0x000a0009,511,156250,1,40000000):
        raise ValueError('unsupported profile/rate')
    if h[15]&~3 or (not h[12] and not h[15]&2):raise ValueError('unmarked calibration')
    if len(data)!=68+h[5]*132 or zlib.crc32(data[:-4])!=struct.unpack_from('<I',data,len(data)-4)[0]:
        raise ValueError('packet length/CRC')
    rows=[]
    for i in range(h[5]):
        slot=data[64+132*i:64+132*i+128];w=struct.unpack('<32I',slot)
        output,reason=struct.unpack_from('<hH',data,64+132*i+128)
        if w[0]!=0x47534302 or w[13]!=0x000a0009 or w[12]>>16 or w[20:24]!=(0x394d4450,128,h[12],0x00100009):
            raise ValueError('slot profile')
        if w[31]!=(~w[18]&0xffffffff) or any(w[24:30]) or zlib.crc32(slot[:120])!=w[30]:raise ValueError('slot CRC/ownership')
        if w[6]&~0x3ff03 or reason>9 or (reason==0 and not h[15]&1):raise ValueError('GSC state')
        das,beam=struct.unpack_from('<hh',slot,28)
        if reason and output!=beam:raise ValueError('invalid bypass output')
        row={'sample':w[1],'direction_version':w[2],'effective_sample':w[3],'window':w[4],
             'group_delay_q16':w[5],'grid':(w[6]>>8)&1023,'trusted':bool(w[6]&1),
             'transition':bool(w[6]&2),'raw':struct.unpack_from('<9h',slot,32),
             'das':das,'fir':beam,'output':output,'reason':reason,'epoch':w[14],
             'tap_drops':w[15],'timestamp':w[16]|w[17]<<32,'dma_drops':w[19]}
        if rows:
            delta=(row['sample']-rows[-1]['sample'])&0xffffffff
            if not 0<delta<0x80000000 or row['timestamp']<=rows[-1]['timestamp']:raise ValueError('nonmonotonic batch')
        rows.append(row)
    return {'session':h[3],'packet':h[4],'geometry_version':h[11],'calibration_version':h[12],
            'dma_drops':h[13],'software_drops':h[14],'unverified':bool(h[15]&2)},rows

def main():
    p=argparse.ArgumentParser();p.add_argument('--bind',default='0.0.0.0');p.add_argument('--port',type=int,default=1234)
    p.add_argument('--seconds',type=float,default=30);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args()
    if a.seconds<=0:raise ValueError('seconds must be positive')
    a.output.mkdir(parents=True,exist_ok=False)
    stats={'packets':0,'invalid_packets':0,'samples':0,'segments':0,'sample_rate_num':156250,'sample_rate_den':1,
           'raw_channels':9,'slot_count':10,'pcm_format':'signed little-endian int16','board_acceptance':False}
    prior=None;files=[];start=time.monotonic()
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock,(a.output/'packets.c9').open('wb') as capture,(a.output/'frames.jsonl').open('w') as meta:
        sock.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4*1024*1024);sock.bind((a.bind,a.port));sock.settimeout(.25)
        print(f'Listening {a.bind}:{a.port}, output={a.output}',flush=True)
        try:
            while time.monotonic()-start<a.seconds:
                try:data,_=sock.recvfrom(2048)
                except socket.timeout:continue
                capture.write(struct.pack('<I',len(data))+data)
                try:h,rows=decode(data)
                except ValueError:stats['invalid_packets']+=1;continue
                stats['packets']+=1
                for row in rows:
                    continuous=prior and prior[0]==h['session'] and ((row['sample']-prior[1])&0xffffffff)==1 and row['timestamp']>prior[2]
                    if not continuous:
                        for f in files:f.close()
                        k=stats['segments'];stats['segments']+=1
                        files=[(a.output/f'segment{k:04d}_{kind}.pcm').open('wb') for kind in ['raw9','fir','gsc']]
                    files[0].write(struct.pack('<9h',*row['raw']));files[1].write(struct.pack('<h',row['fir']));files[2].write(struct.pack('<h',row['output']))
                    meta.write(json.dumps(dict(h,**{k:v for k,v in row.items() if k!='raw'},segment=stats['segments']-1))+'\n')
                    stats['samples']+=1;prior=(h['session'],row['sample'],row['timestamp'])
        except KeyboardInterrupt:pass
        finally:
            for f in files:f.close()
    stats['elapsed_seconds']=time.monotonic()-start
    (a.output/'manifest.json').write_text(json.dumps(stats,indent=2)+'\n')
    print(json.dumps(stats,indent=2))

if __name__=='__main__':main()
