"""Verify and record 12-mic configuration evidence; this is not a bitstream release."""
from pathlib import Path
import hashlib,json,re
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/das12'
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    cfg=json.loads((ROOT/'configs/production_array.json').read_text())
    assert (cfg['channels'],cfg['pairs'],cfg['data_lines'],cfg['capture_words_per_frame'])==(12,66,6,6)
    assert cfg['geometry_status']=='awaiting_drawing' and cfg['channel_positions_m'] is None
    header=(ROOT/'sw/acoustic_live12_image.h').read_text()
    for mem in ('ITCM','DTCM'):
        expected=re.search('ACOUSTIC_'+mem+'_SHA256 "([0-9a-f]{64})"',header)[1]
        assert expected==sha(OUT/'fw'/(mem.lower()+'.hex')),'firmware/header mismatch'
    assert '#define ACOUSTIC_ARRAY_CHANNELS 12u' in header
    assert '#define ACOUSTIC_ARRAY_PAIRS 66u' in header
    assert '#define ACOUSTIC_SRP_LUT_WORDS 67584u' in header
    assert '#define ACOUSTIC_STEER_LUT_WORDS 12288u' in header
    for name,count in (('srp',67584),('steer',12288)):
        values=(OUT/(name+'_lut.hex')).read_text().splitlines()
        assert len(values)==count and all(v=='0000' for v in values),'pending LUT must not contain invented coordinates'
    logs=[(OUT/'tb_srp_profiles.log','default12=66x1024'),
          (OUT/'tb_pdm_array_rx.log','PASS:'),(OUT/'tb_pdm_capture.log','all 39 checks passed'),
          (OUT/'tb_das_stream.log','DAS_STREAM_PASS'),(OUT/'tb_live12_soc.log','LIVE12_SOC_PASS'),
          (OUT/'synth_console.log','LIVE12_SYNTH_PASS'),(OUT/'bd_console.log','PDM wrapper ports OK: pdm_clk_o (out) + 6 DINs'),
          (ROOT/'build/live12_arm_build.log','ACOUSTIC_ARM_BUILD_PASS'),
          (ROOT/'build/live12_ui_checks.log','LIVE12_UI_PASS'),
          (ROOT/'build/live12_ps_checks.log','PASS: A9#0 compile checks'),
          (OUT/'xsim/simulation.log','LIVE12_SOC_PASS channels=12 lines=6 pairs=66 snapshots=2 audio_samples=4412'),
          (OUT/'xsim_console.log','LIVE12_XSIM_PASS')]
    for path,marker in logs:
        raw=path.read_bytes();text=raw.decode('utf-16' if raw.startswith(b'\xff\xfe') else 'utf-8',errors='replace')
        assert marker in text,(str(path),marker)
        if path.name.startswith('tb_'):assert 'FAIL:' not in text
    wrapper=ROOT/'build/das12_zynq/rv32_zynq.gen/sources_1/bd/ps_pl/hdl/ps_pl_wrapper.v'
    assert re.search(r'input\s+\[5:0\]\s*pdm_din_i',wrapper.read_text())
    bd=ROOT/'build/das12_zynq/rv32_zynq.srcs/sources_1/bd/ps_pl/ps_pl.bd'
    text=bd.read_text()
    for key,value in (('DAS_ACTIVE_CHANNELS','12'),('PDM_CHANNELS','12'),('PDM_MICS_PER_LINE','2')):
        assert re.search('"'+key+'":\\s*\\{\\s*"value":\\s*"'+value+'"',text),key
    sources=list((ROOT/'rtl').rglob('*.v'))+[ROOT/'sw/fw'/p for p in ('fw_live16.c','fw_fft.c','fw_gcc.c','fw_tables.c','start.S','link_live16.ld')]
    sources += [ROOT/'configs/production_array.json',ROOT/'tb/tb_live12_soc.v',ROOT/'sw/acoustic_live12_image.h']
    sources += [ROOT/'scripts'/p for p in ('build_live12.py','check_live12.py','check_live12_synth.tcl','check_live16_xsim.ps1','create_zynq_project.tcl')]
    artifacts=[OUT/'fw/fw_live12.elf',OUT/'ps_top_synth.dcp',ROOT/'build/acoustic_arm/live_das12.elf',wrapper,bd]
    manifest={'stage':'12-mic configuration and synthesis; geometry pending',
              'configuration':cfg,'full_implementation_verified':False,'board_tested':False,
              'three_dimensional_localization_enabled':False,
              'simulation_engines':['Icarus','Vivado XSim'],
              'sources':[{'path':str(p.relative_to(ROOT)),'sha256':sha(p)} for p in sources],
              'artifacts':[{'path':str(p.relative_to(ROOT)),'sha256':sha(p)} for p in artifacts],
              'logs':[{'path':str(p.relative_to(ROOT)),'sha256':sha(p)} for p,_ in logs]}
    (OUT/'configuration_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('LIVE12_CONFIGURATION_PACKAGE_PASS; bitstream/board/3D geometry not yet verified')
if __name__=='__main__':main()
