"""Certify matching localization artifacts and simulations; no real-array claim."""
from pathlib import Path
import hashlib,json,re,zipfile
from build_live16 import geometry,fft_rom
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):
    raw=p.read_bytes();return raw.decode('utf-16' if raw.startswith(b'\xff\xfe') else 'utf-8',errors='replace')
def main():
    names=['build/ui_pipeline_live16_loc/ui.elf','build/das16_loc/fw/fw_live16.elf',
     'build/das16_loc/das_fir.xsa','build/das16_loc/das_fir_routed.dcp',
     'build/das16_loc_zynq/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit',
     'build/das16_loc_zynq/rv32_zynq.gen/sources_1/bd/ps_pl/ip/ps_pl_u_ps7_0/ps7_init.tcl',
     'build/das16_loc/timing_zynq.rpt','build/das16_loc/util_zynq.rpt','build/das16_loc/io_zynq.rpt']
    for name in names:
        if not (ROOT/name).is_file():raise RuntimeError('Missing artifact: '+name)
    assert 'FLOW_PASS:' in read(ROOT/'build/das16_loc_console.log')
    rpt=read(ROOT/names[6]);m=re.search(r'^\s*(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)\s+(\d+)\s+(\d+)\s',rpt,re.M)
    assert m and float(m[1])>=0 and float(m[5])>=0 and not int(m[3]) and not int(m[7]),'Timing failed'
    with zipfile.ZipFile(ROOT/names[2]) as z:
        bits=[p for p in z.namelist() if p.endswith('.bit')]
        assert len(bits)==1 and hashlib.sha256(z.read(bits[0])).hexdigest()==sha(ROOT/names[4])
    wrapper=read(ROOT/'build/das16_loc_zynq/rv32_zynq.gen/sources_1/bd/ps_pl/ip/ps_pl_u_rv32_ps_0/synth/ps_pl_u_rv32_ps_0.v')
    for bind in ('.DAS_ACTIVE_CHANNELS(16)','.PDM_CHANNELS(16)','.PDM_MICS_PER_LINE(2)'):assert bind in wrapper,bind
    # Vivado emits the new derived Boolean default as 1'B1 rather than integer 1.
    assert re.search(r"\.LIVE16_LOCALIZATION\(\s*(?:1|1'[bB]1)\s*\)",wrapper),'Localization disabled in implemented wrapper'
    config=json.loads((ROOT/'configs/live16_geometry.json').read_text())
    pins=json.loads((ROOT/'configs/live16_fixed.json').read_text())['din_pins'];io=read(ROOT/names[8])
    for ch,pin in enumerate(pins):assert re.search(r'\|\s*'+pin+r'\s*\|\s*pdm_din_i\['+str(ch)+r'\]\s*\|',io),pin
    sources=['ps_ui.c','ps_ui_page.h','ps_mic_levels.h','ps_pl_live.h','ps_das_fifo.h',
     'ps_das_audio.h','ps_das_plots.h','ps_das_report.h','ps_features.h','ps_http_tx.h','acoustic_live16_image.h']
    assert all((ROOT/'sw'/p).stat().st_mtime<=(ROOT/names[0]).stat().st_mtime for p in sources),'Stale PS app'
    assert all(p.stat().st_mtime<=(ROOT/names[3]).stat().st_mtime for p in (ROOT/'rtl').rglob('*.v')),'Stale bitstream'
    twiddle=fft_rom()
    assert twiddle.stat().st_mtime<=(ROOT/names[3]).stat().st_mtime,'FFT ROM newer than bitstream'
    image=read(ROOT/'sw/acoustic_live16_image.h')
    mics,_,_,lut,steer,_=geometry()
    assert config['channel_positions_m']==[list(p) for p in mics],'Geometry mismatch'
    for array,values in [('acoustic_srp_lut',lut),('acoustic_steer_lut',steer)]:
        body=re.search(r'static const uint32_t '+array+r'\[\d+\]=\{(.*?)\};',image,re.S)[1]
        assert [int(v,16) for v in re.findall(r'0x([0-9a-f]+)u',body)]==values,'LUT image mismatch: '+array
    for memory in ('ITCM','DTCM'):
        expected=re.search('ACOUSTIC_'+memory+'_SHA256 "([0-9a-f]{64})"',image)[1]
        assert expected==sha(ROOT/f'build/das16_loc/fw/{memory.lower()}.hex')
    for top,marker in [('tb_srp_profiles','SRP_PROFILES_PASS'),('tb_live16_location','LIVE16_LOCATION_PASS')]:
        log=ROOT/f'build/das16_loc/{top}.log'
        assert marker in read(log),'Missing simulation acceptance: '+top
        kernel=ROOT/f'build/das16_loc/{top}.vvp'
        dependencies=list((ROOT/'rtl').rglob('*.v'))+[ROOT/f'tb/{top}.v']
        if top=='tb_live16_location':dependencies += list((ROOT/'build/das16_loc').glob('scene*.hex'))
        assert all(p.stat().st_mtime_ns<=kernel.stat().st_mtime_ns for p in dependencies),'Stale module simulation: '+top
    xsim=ROOT/'build/das16_loc/xsim_spectra/simulation.log'
    natural=ROOT/'build/das16_loc/xsim_natural/simulation.log'
    assert 'LIVE16_SPECTRA_PASS words=8208' in read(xsim),'Missing capture/FFT acceptance'
    fw_sources=[ROOT/'sw/fw'/p for p in ('start.S','fw_live16.c','fw_fft.c','fw_gcc.c','fw_tables.c','link_live16.ld')]+list((ROOT/'sw/fw').glob('*.h'))
    assert all(p.stat().st_mtime_ns<=(ROOT/names[1]).stat().st_mtime_ns for p in fw_sources),'Stale RV32 firmware'
    dependencies=list((ROOT/'rtl').rglob('*.v'))+[ROOT/'tb/tb_live16_soc.v',ROOT/'scripts/check_live16_xsim.ps1']
    dependencies += list((ROOT/'build/das16_loc/fw').glob('*.hex'))+list((ROOT/'build/das16_loc').glob('scene*.hex'))
    dependencies += [ROOT/'build/das16_loc/srp_lut.hex',ROOT/'build/das16_loc/steer_lut.hex',twiddle]
    for log in (xsim,natural):
        kernel=log.parent/'xsim.dir/live16_soc/xsimk.exe'
        assert all(p.stat().st_mtime_ns<=kernel.stat().st_mtime_ns for p in dependencies),'Stale SoC simulation: '+str(log)
    natural_text=read(natural)
    assert 'LIVE16_SOC_LOCATION_PASS grid=773' in natural_text,'Missing current full-firmware 1024-score acceptance'
    result=re.search(r'LIVE16_NATURAL_PASS frames=(\d+) samples=(\d+) steered_samples=(\d+) settled_samples=(\d+) drops=0',natural_text)
    assert result and int(result[1])>=7 and int(result[4])>=256,'Missing natural firmware steering acceptance'
    frames=[{'frame':int(f),'samples':int(s),'compute_cycles':int(c),'total_cycles':int(t),'locked':bool(int(l))}
      for f,s,c,t,l in re.findall(r'LIVE16_NATURAL_FRAME frame=(\d+) samples=(\d+) compute_cycles=(\d+) total_cycles=(\d+) locked=(\d+)',natural_text)]
    assert len(frames)>=7,'Missing per-frame cycle measurements'
    mean_cycles=sum(p['total_cycles'] for p in frames[1:])/len(frames[1:])
    robustness=ROOT/'build/location_robustness/comparison.json'
    rows=json.loads(read(robustness))
    assert len(rows)==150,'Missing noise/low-level localization validation'
    for channels in (4,16):
        invalid=[p for p in rows if p['channels']==channels and p['kind']=='invalid']
        source=[p for p in rows if p['channels']==channels and p['kind']=='source']
        assert len(invalid)==59 and not any(p['new_valid'] for p in invalid),'Invalid input was published'
        assert len(source)==16 and all(p['new_valid'] and p['new_error_mm']<=30 for p in source),'Source validation failed'
    quality_sources=[ROOT/'sw/fw/fw_location_quality.h',ROOT/'scripts/check_location_robustness.py',ROOT/'scripts/golden/location_quality_host.c',ROOT/'configs/debug4_geometry.json']
    quality_sources += [ROOT/'sw/fw'/p for p in ('fw_fft.c','fw_gcc.c','fw_tables.c')]
    assert all(p.stat().st_mtime_ns<=robustness.stat().st_mtime_ns for p in quality_sources),'Stale localization noise validation'
    manifest={'stage':'16 microphones / 120 pairs / 32x32 SRP / automatic DAS / PS display',
      'board_tested':False,'audio_location_synchronized':False,'config':config,
      'setup_ns':float(m[1]),'hold_ns':float(m[5]),
      'simulation':{'sample_rate_hz':39062.5,'clock_hz':40000000,
       'pcm_injected_after_pdm':True,'natural_frames':frames,'natural_samples':int(result[2]),
       'natural_steered_samples':int(result[3]),'natural_settled_samples':int(result[4]),'audio_drops':0,
       'steady_mean_total_cycles':mean_cycles,'steady_mean_ms_at_40mhz':mean_cycles/40000,
       'computed_update_rate_hz_at_40mhz':40000000/mean_cycles,'real_array_rate_measured':False,
       'log_artifacts':[{'path':str(p.relative_to(ROOT)).replace('\\','/'),'sha256':sha(p)} for p in (xsim,natural,ROOT/'build/das16_loc/tb_srp_profiles.log',ROOT/'build/das16_loc/tb_live16_location.log')]},
      'firmware_sources':[{'path':str(p.relative_to(ROOT)).replace('\\','/'),'sha256':sha(p)} for p in fw_sources],
      'quality_validation':{'path':str(robustness.relative_to(ROOT)).replace('\\','/'),'sha256':sha(robustness),
        'cases':150,'source_cases_per_profile':16,'invalid_cases_per_profile':59,'invalid_false_publications_after':0,
        'sources':[{'path':str(p.relative_to(ROOT)).replace('\\','/'),'sha256':sha(p)} for p in quality_sources]},
      'artifacts':[{'path':p,'sha256':sha(ROOT/p)} for p in names],
      'lut_artifacts':[{'path':'build/das16_loc/'+p+'.hex','sha256':sha(ROOT/('build/das16_loc/'+p+'.hex'))} for p in ('srp_lut','steer_lut')],
      'fft_rom':{'path':'build/fft_tw.hex','words':512,'sha256':sha(twiddle)},
      'ui_sources':[{'path':'sw/'+p,'sha256':sha(ROOT/'sw'/p)} for p in sources]}
    (ROOT/'build/das16_loc/live16_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('LIVE16_PACKAGE_PASS')
if __name__=='__main__':main()
