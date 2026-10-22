"""M7 reproducible independent injected measurements, schema faults and C loader tests."""
from pathlib import Path
import argparse,copy,ctypes,hashlib,json,struct,subprocess,zlib
import numpy as np
from pdm12_calibration import FS,envelope,validate,pack,fit_capture,calibration_luts,parse_json
from integrated_acoustics import array,direction
R=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);a=p.parse_args()
O=a.output.resolve();O.mkdir(parents=True,exist_ok=False)
production=R/'configs/production_array.json';protected=hashlib.sha256(production.read_bytes()).hexdigest()
acceptance={'scope':'TEST_ONLY','shots':8,'channels':12,'samples_per_shot':8192,
 'delay_error_samples_max':.01,'gain_relative_error_max':.02,'dc_error_lsb_max':2,
 'shape':'shots x channels x samples','hardware':'DEFERRED_HARDWARE'}
(O/'acceptance.json').write_text(json.dumps(acceptance,indent=2))
body={'schema':'pdm12-calibration-v1','role':'TEST_ONLY','calibration_version':1,
 'sample_rate_hz':FS,'coordinate_unit':'m','coordinate_frame':'RH_XYZ',
 'azimuth':'atan2(y,x)','elevation':'asin(z)','physical_mapping_confirmed':False,
 'angle_unit':'degrees','sound_speed_m_s':343.,
 'mic_xyz_m':array().tolist(),'channel_to_mic':list(range(12)),
 'delay_reference_channel':0,
 'fixed_delay_samples':[0.]*12,'gain_q14':[16384]*12,'dc_offset':[0]*12,'polarity':[1]*12,
 'provenance':'SYNTHETIC_TEST_ONLY seed=20261016; not measured microphone data'}
document=envelope(body);validate(document,True)
(O/'test_only_template.json').write_text(json.dumps(document,indent=2))
rejected=[]
try:parse_json('{"body":{},"body":{},"sha256":"x"}')
except ValueError as e:rejected.append({'case':'duplicate_json_key','reason':str(e)})
else:raise AssertionError('Duplicate JSON keys accepted')
def reject(name,doc,allow=True):
    try:validate(doc,allow)
    except (ValueError,TypeError,OverflowError) as e:rejected.append({'case':name,'reason':str(e)})
    else:raise AssertionError('Invalid calibration accepted: '+name)
reject('test_as_production',document,False)
mutations=[('unit','coordinate_unit','mm'),('left_handed','coordinate_frame','LH_XYZ'),
 ('angle','azimuth','atan2(x,y)'),('angle_unit','angle_unit','radians'),('sound_speed','sound_speed_m_s',340.),('rate','sample_rate_hz',48000),('version_zero','calibration_version',0),
 ('unconfirmed_production','role','PRODUCTION'),('duplicate_mapping','channel_to_mic',[0]*12),
 ('nan_coordinate','mic_xyz_m',[[float('nan'),0,0]]*12),
 ('bad_gain','gain_q14',[32768]*12),('zero_polarity','polarity',[0]*12),
 ('missing_corrections','dc_offset',[0]*11),('extra_delay','fixed_delay_samples',list(range(12))),
 ('planar','mic_xyz_m',[[i*.001,(i%3)*.002,0] for i in range(12)]),
 ('large_array','mic_xyz_m',(array()*100).tolist())]
for name,key,value in mutations:
    b=copy.deepcopy(body);b[key]=value
    try:doc=envelope(b)
    except ValueError as e:rejected.append({'case':name,'reason':str(e)});continue
    reject(name,doc)
tampered=copy.deepcopy(document);tampered['body']['calibration_version']=7;reject('digest_tamper',tampered)
b=copy.deepcopy(body);b['unknown']=True;reject('unknown_field',envelope(b))

# Independent frequency-domain source synthesis. Flat excitation spectrum makes
# phase estimation well-conditioned and avoids relying on the fitting routine.
rng=np.random.default_rng(20261016);n=8192;freq=np.fft.rfftfreq(n);mask=(freq*FS>=300)&(freq*FS<=8000)
directions=np.array([direction(az,el) for az,el in [(0,0),(70,35),(140,-30),(210,50),(280,-45),(330,20),(45,-60),(170,65)]])
delay=np.array([-.12,.0078125,.08,-.04,.11,.015,.06,-.09,.03,-.07,.09,-.02])
gain=np.linspace(.8,1.2,12);polarity=np.ones(12);polarity[3]=-1
dc=np.arange(12)*131-600
reference=[];pcm=[]
for u in directions:
    spectrum=np.zeros(len(freq),complex);spectrum[mask]=np.exp(1j*rng.uniform(-np.pi,np.pi,mask.sum()))
    source=np.fft.irfft(spectrum,n);source*=180000/np.std(source);spectrum=np.fft.rfft(source)
    shot=[]
    for ch in range(12):
        tau=-array()[ch]@u*FS/343+delay[ch]
        x=np.fft.irfft(spectrum*np.exp(-2j*np.pi*freq*tau),n)*gain[ch]*polarity[ch]
        x+=dc[ch]+rng.normal(0,180,n)
        shot.append(np.rint(x))
    reference.append(source);pcm.append(shot)
reference=np.array(reference);pcm=np.array(pcm)
np.savez(O/'synthetic_capture.npz',pcm=pcm,reference=reference,directions=directions)
fit=fit_capture(pcm,reference,directions,body);assert fit['status']=='FIT_PASS',fit['alerts']
cor=fit['corrections'];de=float(np.max(np.abs(np.array(cor['fixed_delay_samples'])-(delay-delay[0]))))
ge=float(np.max(abs(np.array(cor['gain_q14'])/16384*gain-1)))
dce=float(np.max(abs(np.array(cor['dc_offset'])-dc)))
assert de<=.01 and ge<=.02 and dce<=2,(de,ge,dce)
assert cor['polarity']==polarity.astype(int).tolist()
late=np.array([np.roll(pcm[i],37*(i+1),axis=-1) for i in range(len(pcm))])
late_fit=fit_capture(late,reference,directions,body);assert late_fit['status']=='FIT_PASS',late_fit['alerts']
assert np.max(abs(np.array(late_fit['corrections']['fixed_delay_samples'])-(delay-delay[0])))<=.01
fitted=copy.deepcopy(body);fitted.update(cor);fitted['calibration_version']=2
fitted['provenance']+='; capture_sha256='+hashlib.sha256((O/'synthetic_capture.npz').read_bytes()).hexdigest()
doc=envelope(fitted);blob=pack(doc,True)
(O/'test_only_fitted.json').write_text(json.dumps(doc,indent=2));(O/'test_only_calibration.bin').write_bytes(blob)
(O/'fit_report.json').write_text(json.dumps(fit,indent=2))
faults=[]
for name in ['swap','wrong_coordinates','dead','noise','reverb','nonlinear_phase']:
    y=pcm.copy();geometry=copy.deepcopy(body)
    if name=='swap':y[:,[0,8]]=y[:,[8,0]]
    elif name=='wrong_coordinates':geometry['mic_xyz_m'][0],geometry['mic_xyz_m'][8]=geometry['mic_xyz_m'][8],geometry['mic_xyz_m'][0]
    elif name=='dead':y[:,5]=0
    elif name=='noise':y[:,7]+=rng.normal(0,300000,y[:,7].shape)
    elif name=='reverb':y[:,2]+=.8*np.roll(y[:,2],17,axis=-1)
    else:
        sy=np.fft.rfft(y[:,4],axis=-1)
        y[:,4]=np.fft.irfft(sy*np.exp(1j*.9*np.sin(freq*FS/1000)),n,axis=-1)
    result=fit_capture(y,reference,directions,geometry)
    assert result['status']=='REJECTED',(name,result['alerts'])
    faults.append({'name':name,'status':'REJECTED','alerts':result['alerts']})
(O/'injected_faults.json').write_text(json.dumps(faults,indent=2))

class Channel(ctypes.Structure):
    _fields_=[('mic_id',ctypes.c_uint32),('xyz_um',ctypes.c_int32*3),('delay_q16',ctypes.c_int32),('gain_q14',ctypes.c_int32),('dc_offset',ctypes.c_int32),('polarity',ctypes.c_int32)]
class Calibration(ctypes.Structure):
    _fields_=[('version',ctypes.c_uint32),('flags',ctypes.c_uint32),('channel',Channel*12)]
cmd=['gcc','-shared','-fPIC','-O2','-Wall','-Wextra','-Werror','-fsanitize=undefined','-fno-sanitize-recover=all','sw/pdm12_calibration.c','-o',str(O/'calibration.so')]
q=subprocess.run(cmd,cwd=R,capture_output=True,text=True);(O/'host_compile.log').write_text(q.stdout+q.stderr);assert q.returncode==0,q.stderr
lib=ctypes.CDLL(str(O/'calibration.so'));load=lib.pdm12_calibration_load
load.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_int,ctypes.POINTER(Calibration)];load.restype=ctypes.c_int
out=Calibration();buf=ctypes.create_string_buffer(blob);assert load(buf,len(blob),1,ctypes.byref(out))==0
assert out.version==2 and out.flags==1
for ch in range(12):
    assert out.channel[ch].mic_id==ch and out.channel[ch].gain_q14==cor['gain_q14'][ch]
    assert out.channel[ch].polarity==cor['polarity'][ch]
before=bytes(out)
assert load(buf,len(blob),0,ctypes.byref(out))!=0 and bytes(out)==before
c_rejects=1
for length in range(len(blob)):
    assert load(buf,length,1,ctypes.byref(out))!=0 and bytes(out)==before;c_rejects+=1
for byte in range(len(blob)):
    bad=bytearray(blob);bad[byte]^=1;b=ctypes.create_string_buffer(bytes(bad))
    assert load(b,len(bad),1,ctypes.byref(out))!=0 and bytes(out)==before;c_rejects+=1
# Recompute CRC to exercise validation rather than checksum rejection alone.
for offset,value in [(8,2),(12,0),(16,4),(20,480000),(24,0),(28,12),(60,0),(44,2097153),(48,32768),(52,8388608),(56,0)]:
    bad=bytearray(blob);struct.pack_into('<I',bad,offset,value);struct.pack_into('<I',bad,len(bad)-4,zlib.crc32(bad[:-4]))
    b=ctypes.create_string_buffer(bytes(bad));assert load(b,len(bad),1,ctypes.byref(out))!=0 and bytes(out)==before;c_rejects+=1
for name in ['planar','coincident','ring_capacity']:
    bad=bytearray(blob)
    for ch in range(12):
        if name=='planar':struct.pack_into('<3i',bad,32+32*ch,ch*1000,0,0)
        elif name=='coincident' and ch==1:bad[64:76]=bad[32:44]
        elif name=='ring_capacity' and ch==0:struct.pack_into('<i',bad,44,20*65536)
    struct.pack_into('<I',bad,len(bad)-4,zlib.crc32(bad[:-4]))
    b=ctypes.create_string_buffer(bytes(bad));assert load(b,len(bad),1,ctypes.byref(out))!=0 and bytes(out)==before;c_rejects+=1
assert load(None,0,1,ctypes.byref(out))!=0 and load(buf,len(blob),1,None)!=0
c_rejects+=2
lib.pdm12_calibration_correct.argtypes=[ctypes.POINTER(Calibration),ctypes.c_uint,ctypes.c_int32]
lib.pdm12_calibration_correct.restype=ctypes.c_int32
samples=0
for ch in range(12):
    for x in [-2147483648,-8388608,-100001,0,100001,8388607,2147483647]:
        product=(x-cor['dc_offset'][ch])*cor['gain_q14'][ch]*cor['polarity'][ch]
        wanted=max(-8388608,min(8388607,abs(product)//16384*(1 if product>=0 else -1)))
        assert lib.pdm12_calibration_correct(ctypes.byref(out),ch,x)==wanted;samples+=1
words=(ctypes.c_uint32*6)();assert lib.pdm12_calibration_gain_words(ctypes.byref(out),words)==0
for k,w in enumerate(words):
    assert w==((cor['gain_q14'][2*k]*cor['polarity'][2*k])&65535)|(((cor['gain_q14'][2*k+1]*cor['polarity'][2*k+1])&65535)<<16)

lut,steer=calibration_luts(doc,True);assert lut.shape==(66,1024) and steer.shape==(12,1024)
np.savetxt(O/'test_only_srp_lut.hex',lut.reshape(-1),fmt='%08x')
np.savetxt(O/'test_only_steer_lut.hex',steer.reshape(-1),fmt='%08x')
for compiler,flags,name in [('riscv64-unknown-elf-gcc',['-march=rv32im','-mabi=ilp32'],'rv32')]:
    command=[compiler,*flags,'-O2','-ffreestanding','-Wall','-Wextra','-Werror','-c','sw/pdm12_calibration.c','-o',str(O/(name+'.o'))]
    q=subprocess.run(command,cwd=R,capture_output=True,text=True);(O/(name+'_compile.log')).write_text(q.stdout+q.stderr);assert q.returncode==0,q.stderr
assert hashlib.sha256(production.read_bytes()).hexdigest()==protected
result={'status':'PASS_SOFTWARE','hardware':'DEFERRED_HARDWARE','schema_rejections':rejected,'capture_faults':faults,
 'delay_max_error_samples':de,'gain_max_relative_error':ge,'dc_max_error_lsb':dce,
 'c_loader_rejections':c_rejects,'c_correction_samples':samples,'lut_entries':int(lut.size),
 'production_configuration_unchanged':True,'source_hashes':{str(f.relative_to(R)):hashlib.sha256(f.read_bytes()).hexdigest() for f in [R/'sw/pdm12_calibration.c',R/'sw/pdm12_calibration.h',R/'scripts/pdm12_calibration.py',Path(__file__)]}}
(O/'metrics.json').write_text(json.dumps(result,indent=2));print('M7_CALIBRATION_PASS',json.dumps({k:v for k,v in result.items() if k not in ('schema_rejections','capture_faults','source_hashes')}))
