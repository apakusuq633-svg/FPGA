"""Icarus and XSim gates for weak-bin rounding and all reciprocal magnitudes."""
from pathlib import Path
import argparse,json,os,subprocess
from golden.fw_acou_model import LUT
ROOT=Path(__file__).resolve().parents[1]

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--rtl',type=Path,default=ROOT/'rtl/acoustic/rv32_acoustic_ext.v');a=ap.parse_args()
    out=ROOT/'build/system_optimization/simd_numerics';out.mkdir(parents=True,exist_ok=True)
    values=[]
    for mag in range(65536):
        e=max(0,mag.bit_length()-1);mant=mag>>(e-14) if e>=14 else mag<<(14-e)
        values.append(16384 if not mag else LUT[(mant>>10)&15])
    (ROOT/'build/phat_reciprocal.hex').write_text(''.join(f'{v:04x}\n' for v in values))
    temp=ROOT/'build/xilinx_temp';temp.mkdir(parents=True,exist_ok=True)
    env=os.environ.copy();env['TEMP']=env['TMP']=str(temp)
    tool=Path('E:/Vivado2020.2/Vivado/2020.2/bin');entries=[]
    for top,marker in [('tb_phat_weak_bins','PHAT_WEAK_BIN_PASS'),('tb_phat_reciprocal','PHAT_RECIPROCAL_PASS')]:
        exe=out/(top+'.vvp');bench=ROOT/'tb'/(top+'.v')
        subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-s',top,'-o',str(exe),str(a.rtl),str(bench)],cwd=ROOT,check=True)
        r=subprocess.run(['D:/iverilog/bin/vvp.exe',str(exe)],cwd=ROOT,capture_output=True,text=True)
        (out/(top+'_icarus.log')).write_text(r.stdout+r.stderr);assert r.returncode==0 and marker in r.stdout,r.stdout
        adapted=out/bench.name;adapted.write_text(bench.read_text().replace('"build/','"'+ROOT.as_posix()+'/build/'))
        (out/(top+'.prj')).write_text('verilog work "'+a.rtl.resolve().as_posix()+'"\nverilog work "'+adapted.as_posix()+'"\n')
        commands=[['xelab.bat','-relax','-prj',top+'.prj','work.'+top,'-s',top,'-debug','off'],['xsim.bat',top,'-runall']]
        for cmd in commands:
            r=subprocess.run([str(tool/cmd[0]),*cmd[1:]],cwd=out,env=env,capture_output=True,text=True)
            (out/(top+'_'+cmd[0]+'.log')).write_text(r.stdout+r.stderr);assert r.returncode==0,r.stdout+r.stderr
        assert marker in r.stdout,r.stdout;entries.append({'top':top,'icarus':True,'xsim':True});print(top,'BOTH_SIMULATORS_PASS',flush=True)
    (out/'results.json').write_text(json.dumps(entries,indent=2)+'\n')

if __name__=='__main__':main()
