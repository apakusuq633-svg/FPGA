"""12-mic RTL regression. Firmware runs in tb_live12_soc; no physical board access."""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/das12';OUT.mkdir(parents=True,exist_ok=True)
def main():
    sources=[str(p.relative_to(ROOT)) for p in (ROOT/'rtl').rglob('*.v')]
    cases=[('tb_srp_profiles',[],'SRP_PROFILES_PASS'),
           ('tb_pdm_array_rx',[],'PASS:'),('tb_pdm_capture',[],'PASS:'),
           ('tb_das_stream',['-Ptb_das_stream.ACTIVE_CHANNELS=12'],'DAS_STREAM_PASS'),
           ('tb_live12_soc',[],'LIVE12_SOC_PASS')]
    for top,parameters,marker in cases:
        exe=OUT/(top+'.vvp')
        compile_result=subprocess.run(['iverilog','-g2012','-Irtl','-s',top,*parameters,'-o',str(exe),*sources,'tb/'+top+'.v'],
                                      cwd=ROOT,capture_output=True,text=True)
        (OUT/(top+'_compile.log')).write_text(compile_result.stdout+compile_result.stderr)
        if compile_result.returncode:raise RuntimeError(compile_result.stderr)
        with (OUT/(top+'.log')).open('w') as log:
            result=subprocess.run(['vvp',str(exe)],cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
        text=(OUT/(top+'.log')).read_text()
        if result.returncode or marker not in text or 'FAIL:' in text:raise RuntimeError(text)
        print('\n'.join(text.strip().splitlines()[-3:]),flush=True)
    print('LIVE12_CHECK_PASS')
if __name__=='__main__':main()
