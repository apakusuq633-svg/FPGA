"""PDM9 UDP verifier. Explicit local bind; captures remain in memory by default."""
import argparse,collections,json,socket,struct,time,zlib
HEADER=struct.Struct('<IHHIIIHHIHHIIII')
assert HEADER.size==48
MAGIC=0x394d4450
def decode(data):
    if len(data)<52:raise ValueError('short datagram')
    fields=HEADER.unpack_from(data)
    magic,version,hbytes,stream,packet,first,count,channels,fs,bits,flags,cal,pbytes,drops,clock=fields
    if (magic,version,hbytes,channels,fs,bits,clock)!=(MAGIC,1,48,12,390625,16,40000000):raise ValueError('header/profile mismatch')
    if not 1<=count<=8 or pbytes!=132*count or len(data)!=48+pbytes+4:raise ValueError('length mismatch')
    if flags&~31 or not flags&2 or not cal and not flags&4:raise ValueError('flags/verification mismatch')
    if zlib.crc32(data[:-4])!=struct.unpack_from('<I',data,len(data)-4)[0]:raise ValueError('UDP CRC')
    frames=[]
    for i in range(count):
        chunk=data[48+132*i:48+132*(i+1)];slot=chunk[:128];w=struct.unpack('<32I',slot)
        if w[0]!=0x47534301 or w[20]!=MAGIC or w[21]!=128 or w[22]!=cal or w[23]!=0x0010000c:raise ValueError('slot format')
        if w[31]!=(~w[18]&0xffffffff) or w[30]!=zlib.crc32(slot[:120]) or any(slot[96:120]):raise ValueError('slot ownership/CRC')
        gsc,reason=struct.unpack_from('<hH',chunk,128);das,fir=struct.unpack_from('<hh',slot,28)
        if reason>9 or not flags&1 and reason==0 or reason and gsc!=fir:raise ValueError('GSC bypass contract')
        frames.append({'sample_seq':w[1],'timestamp_cycles':w[16]|w[17]<<32,'direction_version':w[2],
          'effective_sample_seq':w[3],'window_id':w[4],'group_delay_q16':w[5],'direction_flags':w[6],
          'recovery_epoch':w[14],'tap_overflow':w[15],'owner_sequence':w[18],'dma_drops_at_start':w[19],
          'pcm':struct.unpack_from('<12h',slot,32),'das':das,'fir':fir,'gsc':gsc,'gsc_reason':reason})
    if first!=frames[0]['sample_seq']:raise ValueError('first sample mismatch')
    return {'stream_id':stream,'packet_sequence':packet,'first_sample_seq':first,'flags':flags,
            'calibration_version':cal,'dma_drops':drops,'frames':frames}

class Statistics:
    def __init__(self):
        self.counts=collections.Counter();self.active=None;self.seen=set();self.last_packet=None
        self.last_sample=None;self.last_timestamp=None;self.last_dma_drops=None
    def ingest(self,data):
        self.counts['datagrams_received']+=1
        try:p=decode(data)
        except (ValueError,struct.error):self.counts['invalid_datagrams']+=1;return []
        stream=p['stream_id']
        if stream!=self.active:
            if stream in self.seen:self.counts['stale_session_datagrams']+=1;return []
            if self.active is not None:self.counts['source_sessions_changed']+=1
            self.active=stream;self.seen.add(stream)
            # Bounded history of at most 64 session IDs. After it is cleared an
            # older ID can be treated as a new source; this is not replay
            # protection across arbitrary sessions. Sequence/time checks are
            # scoped to the active session and reset on a new source ID.
            if len(self.seen)>64:self.seen={stream}
            self.last_packet=self.last_sample=self.last_timestamp=self.last_dma_drops=None
        seq=p['packet_sequence']
        if self.last_packet is not None:
            delta=(seq-self.last_packet)&0xffffffff
            if delta==0:self.counts['duplicate_datagrams']+=1;return []
            if delta>=0x80000000:self.counts['out_of_order_datagrams_discarded']+=1;return []
            self.counts['datagram_sequence_holes']+=delta-1
        self.last_packet=seq
        if self.last_dma_drops is not None and p['dma_drops']<self.last_dma_drops:self.counts['dma_counter_restarts']+=1
        self.last_dma_drops=p['dma_drops'];self.counts['dma_drops_reported']=p['dma_drops']
        accepted=[]
        for f in p['frames']:
            if self.last_sample is not None:
                delta=(f['sample_seq']-self.last_sample)&0xffffffff
                if delta==0:self.counts['duplicate_samples']+=1;continue
                if delta>=0x80000000:self.counts['out_of_order_samples']+=1;continue
                dt=f['timestamp_cycles']-self.last_timestamp
                if dt!=delta*1024:self.counts['timestamp_rate_errors']+=1;continue
                self.counts['sample_sequence_holes']+=delta-1
            self.last_sample=f['sample_seq'];self.last_timestamp=f['timestamp_cycles']
            self.counts['frames_accepted']+=1
            self.counts['gsc_active_frames' if f['gsc_reason']==0 else 'gsc_bypass_frames']+=1
            accepted.append(f)
        return accepted

def main():
    p=argparse.ArgumentParser();p.add_argument('--bind',required=True,help='Specific local wired IPv4 address; 127.0.0.1 for tests')
    p.add_argument('--port',type=int,default=1234);p.add_argument('--seconds',type=float,default=60)
    p.add_argument('--peer',help='Optional expected board IPv4 address');a=p.parse_args()
    stat=Statistics();start=time.monotonic()
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
        s.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4*1024*1024);s.bind((a.bind,a.port));s.settimeout(.5)
        try:
            while time.monotonic()-start<a.seconds:
                try:data,peer=s.recvfrom(2048)
                except socket.timeout:continue
                if a.peer and peer[0]!=a.peer:stat.counts['unexpected_peer']+=1;continue
                stat.ingest(data)
        except KeyboardInterrupt:pass
    print(json.dumps({'status':'RECEIVER_FINISHED','elapsed_seconds':time.monotonic()-start,
                      'counts':dict(stat.counts),'captures_saved':False},indent=2))
if __name__=='__main__':main()
