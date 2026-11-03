from pathlib import Path
import xml.etree.ElementTree as ET
import html, math
from PIL import Image, ImageDraw, ImageFont

OUT = Path(__file__).resolve().parent
FONT = 'C:/Windows/Fonts/msyh.ttc'
BOLD = 'C:/Windows/Fonts/msyhbd.ttc'
W = 1600

class Drawing:
    def __init__(self, title, height):
        self.title, self.height = title, height
        self.nodes, self.lines, self.texts, self.panels = [], [], [], []
        self.text(40, 22, title, 30, True)
    def text(self,x,y,t,size=19,bold=False): self.texts.append((x,y,t,size,bold))
    def panel(self,y,h,title,color):
        self.panels.append((25,y,1550,h,color))
        self.text(45,y+15,title,25,True)
    def node(self,id,x,y,label,color='#eaf2fb',w=320,h=90):
        self.nodes.append((id,x,y,w,h,label,color))
        return id
    def edge(self,a,b,label='',control=False,side='right',route=None):
        na=next(n for n in self.nodes if n[0]==a); nb=next(n for n in self.nodes if n[0]==b)
        _,x,y,w,h,*_=na; _,xx,yy,ww,hh,*_=nb
        if route: points=route
        elif side=='down': points=[(x+w/2,y+h),(xx+ww/2,yy)]
        elif side=='up': points=[(x+w/2,y),(xx+ww/2,yy+hh)]
        else: points=[(x+w,y+h/2),(xx,yy+hh/2)]
        self.lines.append((a,b,points,label,control))
    def save(self,name):
        graph=ET.Element('mxGraphModel',adaptiveColors='auto',page='1',pageWidth=str(W),pageHeight=str(self.height))
        root=ET.SubElement(graph,'root'); ET.SubElement(root,'mxCell',id='0'); ET.SubElement(root,'mxCell',id='1',parent='0')
        svg=[f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{self.height}" viewBox="0 0 {W} {self.height}"><rect width="100%" height="100%" fill="white"/>']
        im=Image.new('RGB',(W,self.height),'white'); d=ImageDraw.Draw(im)
        def cell(id,x,y,w,h,label,style):
            c=ET.SubElement(root,'mxCell',id=id,value=label,style=style,vertex='1',parent='1')
            ET.SubElement(c,'mxGeometry',x=str(x),y=str(y),width=str(w),height=str(h),attrib={'as':'geometry'})
        def txt(x,y,t,size,bold=False,center=False):
            f=ImageFont.truetype(BOLD if bold else FONT,size)
            for j,line in enumerate(t.split('\n')):
                ty=y+j*(size+8); tw=d.textlength(line,font=f); tx=x-tw/2 if center else x
                d.text((tx,ty),line,font=f,fill='#20334a')
                svg.append(f'<text x="{x}" y="{ty+size}" text-anchor="{"middle" if center else "start"}" font-family="Microsoft YaHei" font-size="{size}" font-weight="{"bold" if bold else "normal"}" fill="#20334a">{html.escape(line)}</text>')
        for i,(x,y,w,h,color) in enumerate(self.panels):
            d.rounded_rectangle((x,y,x+w,y+h),radius=14,fill=color,outline='#bdcbd9',width=2)
            svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="14" fill="{color}" stroke="#bdcbd9"/>')
            cell('panel'+str(i),x,y,w,h,'',f'rounded=1;html=1;fillColor={color};strokeColor=#bdcbd9;')
        for i,(a,b,pts,label,control) in enumerate(self.lines):
            color='#ba6a18' if control else '#426581'
            for p,q in zip(pts,pts[1:]):
                if control:
                    length=math.dist(p,q)
                    for st in range(0,int(length),14):
                        en=min(st+8,length)
                        d.line((p[0]+(q[0]-p[0])*st/length,p[1]+(q[1]-p[1])*st/length,p[0]+(q[0]-p[0])*en/length,p[1]+(q[1]-p[1])*en/length),fill=color,width=2)
                else: d.line([p,q],fill=color,width=2)
            p,q=pts[-2:]; ang=math.atan2(q[1]-p[1],q[0]-p[0]); arrow=[q,(q[0]-12*math.cos(ang-.4),q[1]-12*math.sin(ang-.4)),(q[0]-12*math.cos(ang+.4),q[1]-12*math.sin(ang+.4))]
            d.polygon(arrow,fill=color)
            svg.append(f'<polyline points="{" ".join(f"{x},{y}" for x,y in pts)}" fill="none" stroke="{color}" stroke-width="2" {"stroke-dasharray=\"8 6\"" if control else ""}/><polygon points="{" ".join(f"{x},{y}" for x,y in arrow)}" fill="{color}"/>')
            # Explicit ports and bends preserve the reviewed orthogonal routes.
            na=next(n for n in self.nodes if n[0]==a); nb=next(n for n in self.nodes if n[0]==b)
            ex=(pts[0][0]-na[1])/na[3]; ey=(pts[0][1]-na[2])/na[4]
            ix=(pts[-1][0]-nb[1])/nb[3]; iy=(pts[-1][1]-nb[2])/nb[4]
            style=f'edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;strokeColor={color};strokeWidth=2;endArrow=block;exitX={ex};exitY={ey};entryX={ix};entryY={iy};'+('dashed=1;' if control else '')
            c=ET.SubElement(root,'mxCell',id='edge'+str(i),style=style,edge='1',parent='1',source=a,target=b)
            geo=ET.SubElement(c,'mxGeometry',relative='1',attrib={'as':'geometry'})
            if len(pts)>2:
                arr=ET.SubElement(geo,'Array',attrib={'as':'points'})
                for x,y in pts[1:-1]: ET.SubElement(arr,'mxPoint',x=str(x),y=str(y))
            if label:
                p,q=pts[0:2]; lx=(p[0]+q[0])/2; ly=(p[1]+q[1])/2-27
                self.texts.append((lx,ly,label,16,False))
        for id,x,y,w,h,label,color in self.nodes:
            d.rounded_rectangle((x,y,x+w,y+h),radius=8,fill=color,outline='#7591aa',width=2)
            svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8" fill="{color}" stroke="#7591aa" stroke-width="2"/>')
            txt(x+w/2,y+(h-len(label.split('\n'))*28)/2-2,label,20,center=True)
            cell(id,x,y,w,h,html.escape(label).replace('\n','<br>'),'rounded=1;whiteSpace=wrap;html=1;fontFamily=Microsoft YaHei;fontSize=20;fillColor='+color+';strokeColor=#7591aa;spacing=8;')
        for i,(x,y,t,size,bold) in enumerate(self.texts):
            txt(x,y,t,size,bold)
            cell('text'+str(i),x,y,1500 if i==0 else min(1500,W-x-35),size+15,t,'text;html=1;align=left;verticalAlign=top;whiteSpace=wrap;fontFamily=Microsoft YaHei;fontSize='+str(size)+';fontStyle='+('1' if bold else '0')+';')
        xml=ET.tostring(graph,encoding='unicode')
        # Repair / validate: generated XML is escaped by ElementTree; enforce root and unique IDs.
        parsed=ET.fromstring(xml); ids=[c.get('id') for c in parsed.iter('mxCell')]
        assert len(ids)==len(set(ids)) and parsed.find("./root/mxCell[@id='1']").get('parent')=='0'
        (OUT/(name+'.drawio')).write_text(xml,encoding='utf-8')
        svg.append('</svg>'); (OUT/(name+'.drawio.svg')).write_text(''.join(svg),encoding='utf-8')
        im.save(OUT/(name+'.drawio.png'))

def pl(g,o=0):
    g.panel(o+90,540,'① PL 整体电路框图｜同步采集、声学定位与连续拾音','#f4f8fd')
    def n(id,x,y,t,c='#eaf2fb'): return g.node('pl'+id,x,o+y,t,c)
    n('in',65,160,'九麦阵列接口\n5 根 DATA／公共 PDM_CLK')
    n('rx',450,160,'PDM 接收与抽取\n双相采样 → CIC → 九路 PCM')
    n('pre',835,160,'通道预处理与同步分流\n去直流、增益校正｜156250 Hz')
    n('time',1220,160,'时钟、复位与测速\nPL 40 MHz／测速同步滤波')
    n('win',65,325,'重叠窗口与搬运状态机\n1024 点窗／512 点步长')
    n('core',450,325,'自研五级 RISC-V 声学处理器\n共享 FFT/IFFT、四路复数单元')
    n('srp',835,325,'相关环存储与四麦对 SRP\n36 麦对 → 1024 格方向评分')
    n('reg',1220,325,'控制与状态寄存器\n定位结果、采集代次、测速状态')
    n('das',65,490,'连续 DAS 定向拾音\n九路延迟补偿与求和','#e9f5ee')
    n('fir',450,490,'连续 FIR 与共享 SIMD\n32 抽头／八路实数乘加','#e9f5ee')
    n('pack',835,490,'采样打包与非阻塞 DMA\n九路原始 PCM＋DAS/FIR＋状态','#e9f5ee')
    n('steer',1220,490,'九路延迟原子提交\n影子向量 → 同版生效与平滑','#fff1df')
    for a,b in [('in','rx'),('rx','pre'),('win','core'),('core','srp'),('srp','reg'),('das','fir'),('fir','pack')]:g.edge('pl'+a,'pl'+b)
    g.edge('plpre','plwin',route=[(995,o+250),(995,o+300),(225,o+300),(225,o+325)])
    g.edge('plpre','pldas',route=[(995,o+250),(995,o+300),(45,o+300),(45,o+465),(225,o+465),(225,o+490)])
    g.edge('plpre','plpack',route=[(1155,o+205),(1185,o+205),(1185,o+535),(1155,o+535)])
    g.edge('plsteer','pldas',control=True,route=[(1380,o+580),(1380,o+605),(225,o+605),(225,o+580)])
    g.text(65,o+265,'公共时钟由 PDM 时钟发生器送往阵列；预处理后的九路 PCM 同时供窗口、DAS 与采样打包。',17)
    g.text(450,o+430,'软核发射声学指令；搬运状态机等待指令退休，再组织频谱、互谱、PHAT、IFFT 和 SRP 数据。',17)
    g.text(65,o+640,'PL → PS：DMA 样本流＋寄存器定位结果；PS → PL：参数、恢复和九路延迟提交。',18)

def transport(g,o=0):
    g.panel(o+90,500,'② PL → PS 传输框图｜数据写入、所有权交接与控制返回','#f4faf8')
    ns=[('p',65,165,'采样打包\n九路 PCM＋DAS/FIR＋采样身份'),('q',450,165,'内部同步 FIFO\n缓冲记录；拥塞时记录丢失'),('dma',835,165,'自研非阻塞 DMA\n128 字节槽／16 拍 × 64 位'),('hp',1220,165,'AXI 互连 → PS HP0\n64 位写入 PS DDR')]
    ns += [('hist',65,350,'九路历史缓存\n0x0A000000／预留 32 MiB'),('cpu',450,350,'CPU0 读取与校验\n缓存失效、屏障、序号与 CRC'),('ring',835,350,'DDR 所有权环\n0x08000000／实际环槽 512 KiB'),('cfg',1220,350,'PS GP0 → AXI4-Lite\n主控 0x43C00000\nDMA 0x43C10000')]
    for id,x,y,t in ns:g.node('tx'+id,x,o+y,t,'#e9f5ee' if id!='cfg' else '#fff1df',h=100)
    for a,b in [('p','q'),('q','dma'),('dma','hp')]:g.edge('tx'+a,'tx'+b)
    g.edge('txhp','txring',route=[(1380,o+265),(1380,o+300),(995,o+300),(995,o+350)])
    g.edge('txring','txcpu',route=[(835,o+400),(770,o+400)])
    g.edge('txcpu','txhist',route=[(450,o+400),(385,o+400)])
    g.edge('txcpu','txdma',control=True,route=[(610,o+350),(610,o+315),(900,o+315),(900,o+265)])
    g.text(640,o+285,'消费完成后释放环槽',16)
    g.text(65,o+485,'写入成功且 AXI 写响应无故障后，DMA 才发布生产位置；CPU0 仅消费已发布槽，再更新消费位置。',19)
    g.text(65,o+525,'GP0 控制参数与所有权；HP0 承载采样记录。下游拥塞不暂停 PL 采集，缺口通过计数与采样序号报告。',18)
    g.text(65,o+610,'实线：数据／处理结果；橙色虚线：控制／反馈。寄存器窗口各 4 KiB；DMA 区预留 1 MiB。',18)

def ps(g,o=0):
    g.panel(o+90,550,'③ PS 整体框图｜双核 Cortex-A9、DDR 共享数据与网络接口','#f8f6fc')
    for id,x,y,t,c in [
        ('in',65,160,'PS 硬件接口\nHP0 数据入口／GP0 控制出口','#eaf2fb'),
        ('c0',450,160,'Cortex-A9 CPU0\n接收校验、历史与轨迹维护','#eaf2fb'),
        ('mem',835,160,'DDR 共享历史与任务区\n历史 32 MiB／任务 1 MiB','#f0eafa'),
        ('c1',1220,160,'Cortex-A9 CPU1\n搜索、同窗分离与故障分析','#eaf2fb'),
        ('ctl',65,335,'PL 控制与方向提交\n九路延迟写入、提交及读回','#fff1df'),
        ('review',450,335,'CPU0 诊断复核与目标选择\n检查唯一故障、时效与有效性','#fff1df'),
        ('task',835,335,'固定快照与任务／结果交接\n采样区间、轨迹、采集代次绑定','#f0eafa'),
        ('algo',1220,335,'CPU1 软件处理链\n多频带搜索 → 同窗分离\n包络与 18 维阶次 → 模型拒识','#f0eafa'),
        ('web',65,510,'以太网控制器与网络服务\n浏览器双层界面、事件与录音','#e9f5ee'),
        ('gsc',450,510,'CPU0 固定目标 GSC 试听\n手动方向／DAS 与 GSC 成对音频','#e9f5ee'),
        ('cache',835,510,'双核共享内存一致性\nSCU／各核缓存、MMU 与屏障','#f0eafa'),
        ('work',1220,510,'CPU1 独占 DDR 工作区\n频谱、协方差与整窗音频','#f0eafa')]: g.node('ps'+id,x,o+y,t,c,h=100)
    for a,b in [('in','c0'),('c0','mem'),('mem','c1'),('task','review'),('review','ctl'),('gsc','web')]:
        if (a,b) in [('task','review'),('review','ctl'),('gsc','web')]:
            na=next(n for n in g.nodes if n[0]=='ps'+a); nb=next(n for n in g.nodes if n[0]=='ps'+b);g.edge('ps'+a,'ps'+b,route=[(na[1],na[2]+50),(nb[1]+nb[3],nb[2]+50)],control=(b=='ctl'))
        else:g.edge('ps'+a,'ps'+b)
    g.edge('psc1','psalgo',side='down');g.edge('psmem','pstask',side='down')
    g.edge('psalgo','pstask',route=[(1220,o+385),(1155,o+385)])
    g.edge('psalgo','pswork',side='down')
    g.edge('psc0','psgsc',route=[(610,o+260),(800,o+260),(800,o+485),(610,o+485),(610,o+510)])
    g.edge('psctl','psin',side='up',control=True)
    g.text(65,o+455,'正式定向：诊断复核通过后提交 PL。',17)
    g.text(835,o+455,'手动 GSC 方向由网页独立设置。',17)
    g.text(65,o+655,'说明：CPU0／CPU1 框内为运行于 PS 的软件职责；DDR、SCU、缓存及接口为硬件资源。',18)

if __name__=='__main__':
    specs=[('pl-complete-circuit','PL 整体电路框图',700,pl),('pl-to-ps-transfer','PL 向 PS 数据传输框图',660,transport),('ps-complete-circuit','PS 整体硬件与软件任务框图',710,ps)]
    for name,title,h,fn in specs:
        g=Drawing(title,h);fn(g);g.save(name)
    g=Drawing('九麦声学定位引导故障诊断系统｜PL—传输—PS 完整电路框图',2070)
    pl(g,0);transport(g,680);ps(g,1350);g.save('pl-ps-complete-circuit')
    print('Created four editable draw.io files and matching SVG / PNG previews.')


