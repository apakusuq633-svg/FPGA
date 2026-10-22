"""M7 strict geometry/calibration envelope, offline fit, and portable firmware blob.

No command writes configs/production_array.json. Measurements are supplied by the
operator; synthetic fixtures must retain role=TEST_ONLY and explicit provenance.
"""
from pathlib import Path
import argparse,hashlib,itertools,json,math,struct,zlib
import numpy as np

FS=39062.5
FIELDS={'schema','role','calibration_version','sample_rate_hz','coordinate_unit',
 'coordinate_frame','azimuth','elevation','angle_unit','sound_speed_m_s','physical_mapping_confirmed','mic_xyz_m',
 'channel_to_mic','delay_reference_channel','fixed_delay_samples','gain_q14','dc_offset','polarity','provenance'}

def require(test,message):
    if not test:raise ValueError(message)

def canonical(body):return json.dumps(body,sort_keys=True,separators=(',',':'),allow_nan=False).encode()

def envelope(body):return {'body':body,'sha256':hashlib.sha256(canonical(body)).hexdigest()}

def parse_json(text):
    def unique(pairs):
        result={}
        for k,v in pairs:
            require(k not in result,'duplicate JSON key: '+k);result[k]=v
        return result
    return json.loads(text,object_pairs_hook=unique)

def validate(document,allow_test=False):
    require(set(document)=={'body','sha256'},'unknown/missing envelope fields')
    b=document['body'];require(isinstance(b,dict) and set(b)==FIELDS,'unknown/missing calibration fields')
    require(document['sha256']==hashlib.sha256(canonical(b)).hexdigest(),'SHA256 mismatch')
    require(b['schema']=='pdm12-calibration-v1','unsupported schema')
    require(b['role'] in ('PRODUCTION','TEST_ONLY'),'unsupported role')
    require(b['role']!='TEST_ONLY' or allow_test,'TEST_ONLY cannot load into production')
    require(type(b['physical_mapping_confirmed']) is bool,'mapping confirmation must be boolean')
    require(b['role']!='PRODUCTION' or b['physical_mapping_confirmed'],'physical mapping unconfirmed')
    require(type(b['calibration_version']) is int and 0<b['calibration_version']<=0xffffffff,'invalid version')
    require(b['sample_rate_hz']==FS and type(b['sample_rate_hz']) in (int,float),'sample-rate mismatch')
    require(b['coordinate_unit']=='m' and b['coordinate_frame']=='RH_XYZ','units/right-handed frame required')
    require(b['azimuth']=='atan2(y,x)' and b['elevation']=='asin(z)','angle convention mismatch')
    require(b['angle_unit']=='degrees','angle units must be explicit degrees')
    require(type(b['sound_speed_m_s']) in (int,float) and b['sound_speed_m_s']==343.,'current LUT/firmware sound-speed profile is 343m/s')
    require(type(b['provenance']) is str and len(b['provenance'].strip())>0,'measurement provenance required')
    mapping=b['channel_to_mic']
    require(type(mapping) is list and len(mapping)==12 and all(type(v) is int for v in mapping)
            and sorted(mapping)==list(range(12)),'mapping must be a 12-mic permutation')
    xyz=b['mic_xyz_m'];require(type(xyz) is list and len(xyz)==12,'12 XYZ triples required')
    require(all(type(v) is list and len(v)==3 and all(type(x) in (int,float) and math.isfinite(x) and abs(x)<=1 for x in v) for v in xyz),'invalid XYZ; centre array within +/-1 metre')
    xyz_um=np.rint(np.array(xyz)*1e6).astype(np.int64)[mapping]
    require(np.linalg.matrix_rank(xyz_um-xyz_um.mean(axis=0))==3,'3D rank required; planar array has mirror ambiguity')
    arrays=['fixed_delay_samples','gain_q14','dc_offset','polarity']
    require(all(type(b[k]) is list and len(b[k])==12 for k in arrays),'12 channel corrections required')
    require(all(type(x) in (int,float) and math.isfinite(x) and abs(x)<=32 for x in b['fixed_delay_samples']),'invalid sampling delay')
    require(type(b['delay_reference_channel']) is int and b['delay_reference_channel']==0 and b['fixed_delay_samples'][0]==0,'sampling delays must be relative to channel 0')
    for field,lo,hi in [('gain_q14',1,32767),('dc_offset',-8388608,8388607),('polarity',-1,1)]:
        require(all(type(x) is int and lo<=x<=hi and (field!='polarity' or x!=0) for x in b[field]),'invalid '+field)
    delays=np.rint(np.array(b['fixed_delay_samples'])*65536).astype(np.int64)
    for i,j in itertools.combinations(range(12),2):
        d2=int(np.sum((xyz_um[i]-xyz_um[j])**2));require(d2>0,'coincident microphones')
        lag=next((n for n in range(15) if d2*625<=(219520*n)**2),15)
        extra=(abs(int(delays[i]-delays[j]))+65535)//65536
        require(lag+extra<=14,f'32-lag ring capacity exceeded pair {i},{j}')
    return {'body':b,'xyz_um':xyz_um,'delay_q16':delays,'spatial_rank':3,'pairs':66,
            'hardware':'UNVERIFIED_HARDWARE' if b['role']=='TEST_ONLY' else 'OPERATOR_ATTESTED_NOT_BOARD_TESTED'}

def pack(document,allow_test=False):
    v=validate(document,allow_test);b=v['body']
    flags=int(b['role']=='TEST_ONLY')|int(b['physical_mapping_confirmed'])<<1
    data=struct.pack('<8s5I',b'PDM12C1\0',1,b['calibration_version'],flags,390625,0x58595a52)
    for ch in range(12):
        data+=struct.pack('<I7i',b['channel_to_mic'][ch],*map(int,v['xyz_um'][ch]),int(v['delay_q16'][ch]),
                          b['gain_q14'][ch],b['dc_offset'][ch],b['polarity'][ch])
    return data+struct.pack('<I',zlib.crc32(data))

def calibration_luts(document,allow_test=False):
    """Generate all 66x1024 SRP lag entries, including calibrated arrival offsets.
    Steering tables are NOT activated or installed by this helper.
    """
    from integrated_acoustics import GRID
    v=validate(document,allow_test);xyz=v['xyz_um']/1e6
    pairs=np.array(list(itertools.combinations(range(12),2)))
    arrival=-(xyz@GRID.T)*FS/343+v['delay_q16'][:,None]/65536
    q=np.floor((arrival[pairs[:,0]]-arrival[pairs[:,1]])*16).astype(np.int64)
    require(np.all(q//16>=-16) and np.all(q//16<=14),'calibrated lag outside extracted ring')
    lut=(q//16)%32*16+q%16
    steer=np.floor((arrival[0]-arrival)*16).astype(np.int64)
    return lut,(((steer//16)&1023)*16+(steer%16))

def fit_capture(pcm,reference,directions,geometry,noise_limit=.3):
    """Known-source multi-direction calibration. No recorded capture is synthesized.

    pcm: shots x 12 x N signed-24-bit levels; reference: shots x N known excitation;
    directions: shots x 3 unit vectors in the declared RH frame. At least four
    directions spanning 3D are needed to distinguish mapping from fixed skew.
    """
    require(pcm.ndim==3 and pcm.shape[1]==12 and pcm.shape[0]>=4,'need >=4 shots x 12 channels')
    require(reference.shape==(pcm.shape[0],pcm.shape[2]) and directions.shape==(pcm.shape[0],3),'capture shape mismatch')
    require(pcm.shape[2]>=4096 and np.all(np.isfinite(pcm)) and np.all(np.isfinite(reference)),'invalid capture samples')
    require(np.all(np.isfinite(directions)) and np.allclose(np.linalg.norm(directions,axis=1),1,atol=1e-6),'directions must be unit vectors')
    require(np.linalg.matrix_rank(directions-directions.mean(axis=0))==3,'calibration directions must span 3D')
    xyz=np.array(geometry['mic_xyz_m'],dtype=float)[geometry['channel_to_mic']]
    n=pcm.shape[2];freq=np.fft.rfftfreq(n);bins=(freq*FS>=300)&(freq*FS<=8000)
    delays=[];gains=[];dcs=[];residuals=[];responses=[];alerts=[]
    for shot in range(pcm.shape[0]):
        x=reference[shot]-reference[shot].mean();sx=np.fft.rfft(x)
        require(np.std(x)>1,'reference is silent or incorrectly scaled')
        ds=[];gs=[];dc=[];rs=[];hr=[]
        for ch in range(12):
            raw=pcm[shot,ch];y=raw-raw.mean();sy=np.fft.rfft(y)
            if np.std(y)<1:
                alerts.append({'shot':shot,'channel':ch,'kind':'DEAD_OR_SILENT_CHANNEL'})
                ds.append(0.);gs.append(0.);dc.append(float(raw.mean()));rs.append(1.);hr.append([]);continue
            require(np.max(np.abs(raw))<8388607,'clipped input; recapture at lower level')
            valid=bins&(np.abs(sx)>np.max(np.abs(sx))*1e-4)
            require(valid.sum()>100,'excitation does not cover required frequency band')
            cross=sy*np.conj(sx)
            corr=np.fft.irfft(cross,n);peak=int(np.argmax(abs(corr)));coarse=peak if peak<=n//2 else peak-n
            polarity=1 if corr[peak]>=0 else -1
            phase=np.unwrap(np.angle(cross[valid]*polarity*np.exp(2j*np.pi*freq[valid]*coarse)))
            # Fit residual phase only after removing the integer lag.
            slope,intercept=np.polyfit(freq[valid],phase,1)
            measured=coarse-slope/(2*np.pi)
            aligned=np.fft.irfft(sx*np.exp(-2j*np.pi*freq*measured),n)
            gain=float(np.dot(y,aligned)/np.dot(aligned,aligned))
            residual=float(np.linalg.norm(y-gain*aligned)/np.linalg.norm(y))
            if residual>noise_limit:alerts.append({'shot':shot,'channel':ch,'kind':'NOISE_REVERB_OR_PHASE_RESPONSE','residual':residual})
            ds.append(float(measured+xyz[ch]@directions[shot]*FS/343));gs.append(gain)
            dc.append(float(raw.mean()-gain*reference[shot].mean()));rs.append(residual)
            h=sy[valid]/sx[valid]
            hr.append({'median_gain_db':float(20*np.log10(np.median(abs(h)))),
                       'phase_fit_intercept_rad':float(intercept),'phase_fit_residual_rms_rad':float(np.sqrt(np.mean((phase-slope*freq[valid]-intercept)**2)))})
        delays.append(ds);gains.append(gs);dcs.append(dc);residuals.append(rs);responses.append(hr)
    delays=np.array(delays);gains=np.array(gains)
    common_delays=delays[:,0].copy()
    delays-=delays[:,0:1] # excitation trigger/acoustic flight time is not channel skew
    for ch in range(12):
        if np.std(delays[:,ch])>.05:alerts.append({'channel':ch,'kind':'MAPPING_COORDINATE_OR_TIME_VARIATION','delay_std_samples':float(np.std(delays[:,ch]))})
        if np.any(np.sign(gains[:,ch])!=np.sign(gains[0,ch])):alerts.append({'channel':ch,'kind':'UNSTABLE_POLARITY'})
        if np.mean(gains[:,ch])<0:alerts.append({'channel':ch,'kind':'POLARITY_INVERSION','correctable':True})
    blocking=[a for a in alerts if not a.get('correctable',False)]
    corrections=None
    if not blocking:
        gain=np.mean(gains,axis=0)
        corrections={'fixed_delay_samples':delays.mean(axis=0).tolist(),
          'gain_q14':np.rint(16384/abs(gain)).astype(int).tolist(),
          'dc_offset':np.rint(np.mean(dcs,axis=0)).astype(int).tolist(),
          'polarity':np.sign(gain).astype(int).tolist()}
    return {'status':'REJECTED' if blocking else 'FIT_PASS','hardware':'DATA_PROVENANCE_NOT_VERIFIED',
            'alerts':alerts,'corrections':corrections,'shot_delays_samples':delays.tolist(),
            'shot_common_delay_samples':common_delays.tolist(),'delay_reference_channel':0,
            'shot_gain':gains.tolist(),'residuals':residuals,'frequency_response_summary':responses}

def main():
    p=argparse.ArgumentParser();p.add_argument('operation',choices=['validate','pack','fit'])
    p.add_argument('--config',type=Path,required=True);p.add_argument('--allow-test',action='store_true')
    p.add_argument('--capture',type=Path);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    document=parse_json(a.config.read_text(encoding='utf-8-sig'));v=validate(document,a.allow_test)
    a.output.mkdir(parents=True,exist_ok=False)
    if a.operation=='fit':
        require(a.capture is not None,'--capture required');data=np.load(a.capture,allow_pickle=False)
        result=fit_capture(data['pcm'],data['reference'],data['directions'],v['body'])
        result['input_sha256']=hashlib.sha256(a.capture.read_bytes()).hexdigest()
        (a.output/'fit_report.json').write_text(json.dumps(result,indent=2))
        require(result['status']=='FIT_PASS','capture rejected; inspect fit_report.json')
        body=dict(v['body']);body.update(result['corrections']);body['calibration_version']+=1
        body['provenance']+='; capture_sha256='+result['input_sha256']
        document=envelope(body);validate(document,a.allow_test)
        (a.output/'calibration.json').write_text(json.dumps(document,indent=2))
    if a.operation in ('fit','pack'):
        blob=pack(document,a.allow_test);(a.output/'calibration.bin').write_bytes(blob)
        lut,steer=calibration_luts(document,a.allow_test)
        np.savetxt(a.output/'srp_lut.hex',lut.reshape(-1),fmt='%08x')
        np.savetxt(a.output/'steer_lut.hex',steer.reshape(-1),fmt='%08x')
        (a.output/'manifest.json').write_text(json.dumps({'role':document['body']['role'],'version':document['body']['calibration_version'],
          'blob_sha256':hashlib.sha256(blob).hexdigest(),'config_sha256':document['sha256'],'production_installed':False},indent=2))
    print('CALIBRATION_'+a.operation.upper()+'_PASS role='+document['body']['role']+' production_installed=0')
if __name__=='__main__':main()
