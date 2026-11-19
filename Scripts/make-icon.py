# Draws the YTA app icon (Scripts/AppIcon.png) and is kept so it can be redrawn: python3 Scripts/make-icon.py, then build AppIcon.icns from the PNG.
import sys
from PIL import Image, ImageDraw, ImageFilter
S=4; N=1024*S
def c(h): return tuple(int(h[i:i+2],16) for i in (1,3,5))
img=Image.new("RGBA",(N,N),(0,0,0,0))
# shadow
inset=100*S; size=N-2*inset; r=185*S
shadow=Image.new("RGBA",(N,N),(0,0,0,0))
ImageDraw.Draw(shadow).rounded_rectangle([inset,inset+12*S,inset+size,inset+size+12*S],r,fill=(0,0,0,70))
shadow=shadow.filter(ImageFilter.GaussianBlur(18*S))
img.alpha_composite(shadow)
# gradient squircle
top,bot=c("#5A7299"),c("#3B4C69")
grad=Image.new("RGBA",(N,N))
gd=ImageDraw.Draw(grad)
for y in range(N):
    t=y/N; gd.line([(0,y),(N,y)],fill=tuple(int(top[i]+(bot[i]-top[i])*t) for i in range(3))+(255,))
mask=Image.new("L",(N,N),0); ImageDraw.Draw(mask).rounded_rectangle([inset,inset,inset+size,inset+size],r,fill=255)
img.paste(grad,(0,0),mask)
d=ImageDraw.Draw(img)
# workflow play triangle: three nodes joined by edges
cx,cy=512*S,512*S
A=(cx-150*S,cy-190*S); B=(cx-150*S,cy+190*S); C=(cx+215*S,cy)
w=34*S
edge=(255,255,255,235)
for p,q in ((A,B),(B,C),(C,A)):
    d.line([p,q],fill=edge,width=w)
for p in (A,B,C):
    d.ellipse([p[0]-w/2,p[1]-w/2,p[0]+w/2,p[1]+w/2],fill=edge)
for p,col in ((A,"#F6F6F4"),(B,"#F6F6F4"),(C,"#E9C98B")):
    R=62*S
    d.ellipse([p[0]-R,p[1]-R,p[0]+R,p[1]+R],fill=c(col)+(255,))
    R2=26*S
    d.ellipse([p[0]-R2,p[1]-R2,p[0]+R2,p[1]+R2],fill=c("#4A5F82")+(255,))
out=img.resize((1024,1024),Image.LANCZOS)
out.save("icon-1024.png")
