"""Download/inspect synchronous pre-DAS PCM; geometry-free measurements are not calibration offsets."""
from pathlib import Path
import argparse
import hashlib
import json
import struct
import time
import urllib.request
import numpy as np

MAGIC=0x52415701

def decode(data):
    if len(data)<64:raise ValueError('Truncated raw header')
    header=struct.unpack('<16I',data[:64])
    magic,size,request,channels,frames,num,den,first,sequence,bits=header[:10]
    if magic!=MAGIC or size!=64 or channels not in (8,12,16) or frames!=1024 or bits!=16 or (num,den)!=(78125,2):
        raise ValueError('Unsupported raw format or sample rate')
    if len(data)!=64+channels*frames*2:raise ValueError('Raw payload length mismatch')
    pcm=np.frombuffer(data[64:],dtype='<i2').reshape(frames,channels).copy()
    return {'request_id':request,'channels':channels,'frames':frames,'sample_rate_hz':num/den,
            'first_sample_u32':first,'bank_sequence_u32':sequence,
            'layout':'frame-major signed little-endian int16','sha256':hashlib.sha256(data).hexdigest()},pcm

def measure(meta,pcm,positions=None,source=None,max_lag=32):
    x=pcm.astype(np.float64);dc=x.mean(axis=0);ac=x-dc
    rms=np.sqrt((ac*ac).mean(axis=0));peaks=np.abs(x).max(axis=0)
    clips=((pcm==-32768)|(pcm==32767)).sum(axis=0)
    fs=meta['sample_rate_hz'];n=len(pcm)
    spectra=np.fft.rfft(ac*np.hanning(n)[:,None],axis=0)
    frequency=np.fft.rfftfreq(n,1/fs);band=(frequency>=200)&(frequency<=8000)
    records=[]
    for ch in range(meta['channels']):
        delay=None
        if rms[0]>=1 and rms[ch]>=1:
            cross=spectra[:,ch]*spectra[:,0].conj()
            magnitude=np.abs(cross);valid=band&(magnitude>max(magnitude.max()*1e-9,1e-12))
            white=np.zeros_like(cross);white[valid]=cross[valid]/magnitude[valid]
            corr=np.fft.irfft(white,n);lags=np.arange(-max_lag,max_lag+1)
            scores=np.abs(corr[lags%n]);at=int(np.argmax(scores));delay=float(lags[at])
            if 0<at<len(scores)-1:
                left,center,right=scores[at-1:at+2];curve=left-2*center+right
                if curve<0:delay+=float(np.clip(.5*(left-right)/curve,-.5,.5))
        record={'channel':ch,'dc_lsb':float(dc[ch]),'ac_rms_lsb':float(rms[ch]),
                'peak_lsb':float(peaks[ch]),'clipped_samples':int(clips[ch]),
                'rms_ratio_to_ch0':float(rms[ch]/rms[0]) if rms[0] else None,
                'measured_delay_to_ch0_samples':delay,
                'calibration_offset_samples':None}
        if positions is not None and source is not None and delay is not None:
            distance=np.linalg.norm(np.asarray(positions)-source,axis=1)
            expected=(distance[ch]-distance[0])*fs/343.0
            record['geometry_delay_to_ch0_samples']=float(expected)
            record['calibration_offset_samples']=float(delay-expected)
        records.append(record)
    return {'metadata':meta,'channels':records,
            'interpretation':'Delays contain propagation, electronics and estimation error. Offsets require known XYZ and source position; no coefficients are applied.',
            'snapshot_duration_ms':1000*n/fs,'frequency_band_hz':[200,8000]}

def acquire(url):
    url=url.rstrip('/')
    with urllib.request.urlopen(url+'/api/raw/start',timeout=3) as response:
        if response.status!=202:raise RuntimeError('Snapshot request not accepted')
        requested=json.loads(response.read())['id']
    for _ in range(40):
        time.sleep(.1)
        with urllib.request.urlopen(url+'/api/raw',timeout=3) as response:
            if response.status==200:
                data=response.read();meta,_=decode(data)
                if meta['request_id']!=requested:raise RuntimeError('Snapshot replaced by another client')
                return data
            status=json.loads(response.read())
            if status.get('id')!=requested:raise RuntimeError('Snapshot request changed')
    raise TimeoutError('Raw snapshot not ready')

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--input',type=Path)
    parser.add_argument('--url',default='http://192.168.2.10')
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--geometry',type=Path)
    parser.add_argument('--source',type=float,nargs=3,metavar=('X','Y','Z'))
    parser.add_argument('--max-lag',type=int,default=32)
    args=parser.parse_args()
    if not 1<=args.max_lag<512:parser.error('max-lag must be 1..511')
    data=args.input.read_bytes() if args.input else acquire(args.url)
    meta,pcm=decode(data);positions=None
    if args.geometry:
        cfg=json.loads(args.geometry.read_text(encoding='utf-8-sig'));positions=cfg.get('channel_positions_m')
        if positions is not None:
            positions=np.asarray(positions,dtype=float)
            if positions.shape==(meta['channels'],2):positions=np.c_[positions,np.zeros(meta['channels'])]
            if positions.shape!=(meta['channels'],3) or not np.isfinite(positions).all():raise ValueError('Invalid XYZ/channel count')
    if args.source and positions is None:parser.error('Source position requires real microphone XYZ')
    result=measure(meta,pcm,positions,args.source,args.max_lag)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.with_suffix('.raw').write_bytes(data)
    args.output.with_suffix('.json').write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    np.savez(args.output.with_suffix('.npz'),pcm=pcm,sample_rate_hz=meta['sample_rate_hz'],
             sample_indices=(meta['first_sample_u32']+np.arange(1024,dtype=np.uint64))%2**32)
    print('RAW_CAPTURE_ANALYSIS_PASS',json.dumps(meta))

if __name__=='__main__':main()
