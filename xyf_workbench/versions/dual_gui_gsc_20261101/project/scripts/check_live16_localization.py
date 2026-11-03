"""Localization regression; stage-1 capture/fixed-DAS checks use check_live16_stage1.py."""
from pathlib import Path
import argparse,subprocess
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'build/das16_loc'
def main():
    p=argparse.ArgumentParser();p.add_argument('--skip-soc',action='store_true');args=p.parse_args()
    OUT.mkdir(parents=True,exist_ok=True)
    rtl=[str(x.relative_to(ROOT)) for x in (ROOT/'rtl').rglob('*.v')]
    for top,marker in [('tb_srp_profiles','SRP_PROFILES_PASS'),('tb_live16_location','LIVE16_LOCATION_PASS'),('tb_live16_soc','LIVE16_SOC_PASS')]:
        if args.skip_soc and top=='tb_live16_soc':continue
        exe=OUT/(top+'.vvp')
        subprocess.run(['D:/iverilog/bin/iverilog.exe','-g2012','-Irtl','-s',top,'-o',str(exe),*rtl,'tb/'+top+'.v'],cwd=ROOT,check=True)
        result=subprocess.run(['D:/iverilog/bin/vvp.exe','-i',str(exe)],cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
        (OUT/(top+'.log')).write_text(result.stdout,encoding='utf-8')
        if result.returncode or marker not in result.stdout:raise RuntimeError(result.stdout)
        print(result.stdout)
    print('LIVE16_LOCALIZATION_CHECK_PASS'+(' (SoC skipped)' if args.skip_soc else ''))
if __name__=='__main__':main()
