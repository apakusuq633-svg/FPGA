"""G9A1 compact audio receiver; no raw9 payload, never changes board controls."""
import argparse,json,socket,struct,time,zlib
from pathlib import Path
def decode(d):
 if len(d)<52 or d[:4]!=b'G9A1' or zlib.crc32(d[:-4])!=struct.unpack('<I',d[-4:])[0]:raise ValueError('magic/CRC')
 h=struct.unpack('<12I',d[:48]);n=h[6]
 if h[1]!=1 or not 1<=n<=128 or len(d)!=52+n*10 or h[4]!=156250 or h[5] not in (1,4,8):raise ValueError('format/length/rate')
 return h,[struct.unpack_from('<IhhH',d,48+10*i) for i in range(n)]
def main():
 p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--seconds',type=float,default=30);p.add_argument('--bind',default='0.0.0.0');a=p.parse_args()
 if a.out.exists() or not 0<a.seconds<=600:p.error('New directory and 0..600 seconds required')
 a.out.mkdir(parents=True);stats={'packets':0,'frames':0,'bad_packets':0,'source_gaps':0,'packet_gaps':0,'reason_counts':{},'complete':False,'format':'s16le','channels_per_file':1,'input_raw9_recorded':False};prev=None;seq=None;era=None;started=time.monotonic()
 try:
  with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s,(a.out/'das.pcm').open('wb') as f,(a.out/'gsc.pcm').open('wb') as g,(a.out/'packets.jsonl').open('w') as log:
   s.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4*1024*1024);s.bind((a.bind,1234));s.settimeout(.25);print('Listening UDP1234; now enable GUI output',flush=True)
   while time.monotonic()-started<a.seconds:
    try:d,peer=s.recvfrom(4096)
    except socket.timeout:continue
    if peer[0]!='192.168.2.10':continue
    try:h,rows=decode(d)
    except ValueError:stats['bad_packets']+=1;continue
    ident=(h[2],h[4],h[5],h[7],h[8])
    if era is not None and ident!=era:raise ValueError('Session/rate/config changed; separate recording required')
    era=ident;stats['rate_num']=h[4];stats['rate_den']=h[5]
    if seq is not None and h[3]!=(seq+1)&0xffffffff:stats['packet_gaps']+=1
    seq=h[3];stats['packets']+=1
    for sample,das,gsc,reason in rows:
     if prev is not None and sample!=(prev+h[5])&0xffffffff:stats['source_gaps']+=1
     prev=sample;f.write(struct.pack('<h',das));g.write(struct.pack('<h',gsc));stats['frames']+=1;stats['reason_counts'][reason]=stats['reason_counts'].get(reason,0)+1
    log.write(json.dumps({'pc_receive_time':time.time(),'session':h[2],'packet_sequence':h[3],'sample_first':rows[0][0],'sample_last':rows[-1][0],'frames':h[6],'geometry':h[7],'calibration':h[8],'dma_drops':h[9],'software_drops':h[10],'flags':h[11]})+'\n')
   stats['complete']=True
 except KeyboardInterrupt:stats['error']='operator stopped'
 except Exception as e:stats['error']=str(e)
 finally:
  stats['elapsed_pc_s']=time.monotonic()-started;stats['integrity_pass']=stats['complete'] and stats['frames']>0 and not(stats['bad_packets'] or stats['source_gaps'] or stats['packet_gaps']);(a.out/'metadata.json').write_text(json.dumps(stats,indent=2));print(json.dumps(stats,indent=2))
if __name__=='__main__':main()
