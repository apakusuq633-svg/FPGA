"""Record exact reviewed artifacts; never programs a board or changes production firmware."""
from pathlib import Path
import hashlib,json,subprocess

R=Path(__file__).resolve().parents[1]
I=R/'build/localizer12_final/implementation'
S=R/'build/localizer12/final256'
subprocess.run(['python3','scripts/summarize_localizer12.py',str(S),'--implementation',str(I)],cwd=R,check=True)
summary=json.loads((S/'strict_summary.json').read_text())
assert summary['status']=='PASS' and summary['processed_windows']==256
paths=dict(bit=R/'build/localizer12_final/zynq/rv32_zynq.runs/impl_1/ps_pl_wrapper.bit',
           xsa=I/'das_fir.xsa',routed_dcp=I/'das_fir_routed.dcp',
           elf=S/'fw/fw_live12.elf',itcm=S/'fw/itcm.hex',
           timing=I/'timing_zynq.rpt',utilization=I/'util_zynq.rpt',
           bram_locations=I/'localizer_bram_locations.csv',
           strict_summary=S/'strict_summary.json',simulation=S/'simulation.log',
           simulation_manifest=S/'build_manifest.json',rtl_manifest=I/'source_manifest.json')
paths.update(floorplan_comparison_timing=I.parent/'unconstrained/timing_zynq.rpt',
             floorplan_comparison_bram_paths=I.parent/'unconstrained/localizer_bram_paths.rpt')
artifacts={key:dict(path=str(path.relative_to(R)),bytes=path.stat().st_size,
                   sha256=hashlib.sha256(path.read_bytes()).hexdigest()) for key,path in paths.items()}
result=dict(status='STRICT_SOC_RTL_AND_ROUTED_IMPLEMENTATION_PASS_TEST_GEOMETRY_ONLY',
            head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=R,text=True).strip(),
            working_tree='UNCOMMITTED_CHANGES',clock_hz=40000000,channels=12,pairs=66,
            grid=1024,window=1024,hop=512,firmware_stops_after_windows=256,
            board_validation='NOT_RUN',physical_geometry_accuracy='NOT_VALIDATED',
            production_geometry_enabled=False,artifacts=artifacts)
out=I.parent/'release_manifest.json'
out.write_text(json.dumps(result,indent=2)+'\n')
print('LOCALIZER12_PACKAGE_PASS '+str(out))
