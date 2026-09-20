from pathlib import Path
from html import escape
out=Path(__file__).resolve().parent
out.mkdir(exist_ok=True)
D='#11141c'; W='#ffffff'; M='#cbd1df'; B='#1266df'; A='#ffca66'; INK='#171b26'
def rect(x,y,w,h,fill,r=0,stroke=None,sw=2):
 return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}"'+(f' stroke="{stroke}" stroke-width="{sw}"' if stroke else '')+'/>'
def text(x,y,s,size=30,fill=W,weight=400,anchor='start'):
 return f'<text x="{x}" y="{y}" font-size="{size}" fill="{fill}" font-weight="{weight}" text-anchor="{anchor}">{escape(s)}</text>'
def arrow(points,c=A,sw=4):
 return f'<path d="{points}" fill="none" stroke="{c}" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round" marker-end="url(#arrow)"/>'
def button(x,y,w,label,fill=B,ink=W,h=64):
 return rect(x,y,w,h,fill,12)+text(x+w/2,y+h/2+11,label,32,ink,500,'middle')
def badge(x,y,n):
 return f'<circle cx="{x}" cy="{y}" r="23" fill="{A}"/>'+text(x,y+10,str(n),29,INK,500,'middle')
def qr(x,y,size=200):
 # Illustrative pattern, not a QR payload. DEMO band makes its role explicit.
 n=25;u=size/(n+2);s=rect(x,y,size,size,W,6)
 def finder(a,b):
  nonlocal s
  s+=rect(x+(a+1)*u,y+(b+1)*u,7*u,7*u,INK)
  s+=rect(x+(a+2)*u,y+(b+2)*u,5*u,5*u,W)
  s+=rect(x+(a+3)*u,y+(b+3)*u,3*u,3*u,INK)
 for r in range(n):
  for c in range(n):
   if (r<8 and c<8) or (r<8 and c>16) or (r>16 and c<8):continue
   if (r*13+c*7+r*c*3)%11<5:s+=rect(x+(c+1)*u,y+(r+1)*u,u,u,INK)
 for pos in [(0,0),(18,0),(0,18)]:finder(*pos)
 s+=rect(x,y+size*.4,size,size*.23,W)+text(x+size/2,y+size*.56,'SAMPLE',size*.14,INK,500,'middle')
 return s
def wrap(title,body,height=680):
 return f'''<svg xmlns="http://www.w3.org/2000/svg" width="900" height="{height}" viewBox="0 0 900 {height}" role="img" aria-labelledby="title"><title id="title">{escape(title)} — illustrated reference with sample details</title><defs><marker id="arrow" viewBox="0 0 12 12" refX="10" refY="6" markerWidth="9" markerHeight="9" orient="auto-start-reverse"><path d="M2 2 L10 6 L2 10" fill="none" stroke="{A}" stroke-width="2" stroke-linejoin="round"/></marker></defs><g font-family="-apple-system, BlinkMacSystemFont, Arial, sans-serif">{body}</g></svg>'''
def save(name,title,s,height=680): (out/(name+'.svg')).write_text(wrap(title,s,height))
# 1: only the field and actions; no brand banners or repeated sign-in title.
s=rect(24,16,852,264,D,22)+text(84,74,'Sign-In ID (Email Address)',30,M)
s+=rect(84,96,732,68,'#1b202b',9,'#98a2b6')+text(108,142,'player@example.com',32)
s+=button(84,190,732,'Next',W,INK)
s+=rect(24,310,852,118,'#1d2638',18)+text(79,353,'Then choose',26,M)
s+=button(330,338,498,'Sign In with Passkey')+arrow('M265 381 L310 381')
save('01-sign-in','Enter your email and sign in',s,450)
# 2: retain Sign In, QR/code, and both instructional callouts.
s=rect(24,16,852,588,D,22)+'<g transform="translate(0,-60)">'
s+=text(450,127,'Sign In',34,W,400,'middle')+qr(121,161,218)+text(230,413,'EXAMPLE CODE',24,M,500,'middle')
s+=rect(119,429,225,67,'#302817',14,A,4)+text(231,477,'482913',44,A,500,'middle')
s+=badge(411,222,1)+text(449,216,'Keep this number',32,W,500)+text(449,257,'You’ll need it in step 5.',27,M)
s+=arrow('M453 283 L370 283 L370 462 L357 462')
s+=badge(411,368,2)+text(449,362,'Send the email',32,W,500)+text(449,403,'Keep this window open.',27,M)
s+=arrow('M615 427 L615 509')+button(93,528,714,'Send Sign-In Email',W,INK)
s+=rect(88,523,724,74,'none',16,A,3)+text(450,637,'Use your own code. This number is an example.',25,M,400,'middle')+'</g>'
save('02-qr-and-email','Keep the code and send the sign-in email',s,620)
# 3: email subject, sample address and highlighted action.
s=rect(24,16,852,418,'#f9fafc',22)
s+=text(450,91,'Request to Sign In with Passkey',36,INK,500,'middle')
s+=text(450,151,'player@example.com',30,'#4b5569',400,'middle')
s+=text(450,214,'Select Sign In to continue.',29,INK,400,'middle')
s+=button(280,260,340,'Sign In')+rect(274,254,352,76,'none',18,'#a56800',3)
s+=text(450,400,'Tap Sign In',31,INK,500,'middle')+arrow('M450 366 L450 334',A)
save('03-open-email','Open Sony’s email and tap Sign In',s,450)
# 4: all necessary confirmation actions, minimal descriptive labels.
s=badge(57,78,1)+rect(103,16,773,178,'#f7f9fc',19)
s+=text(130,60,'Confirm your email in Safari',29,INK,500)
s+=rect(132,90,473,68,W,9,'#ccd3e0')+text(152,134,'player@example.com',29,INK)
s+=button(625,92,219,'Next')+arrow('M484 202 L484 229')
s+=badge(57,311,2)+rect(103,240,773,144,'#f7f9fc',19)
s+=text(130,284,'Continue signing in',28,INK,500)+button(211,303,557,'Sign In with Passkey')
s+=arrow('M484 395 L484 425')
s+=badge(57,548,3)+rect(103,435,773,229,'#454c5a',20)
s+=text(140,484,'Sign In',34,W,500)+text(140,529,'Confirm with your passkey.',29,W)
s+=button(139,560,702,'Use Passkey')
save('04-confirm-passkey','Finish signing in with your passkey',s)
# 5: identify windows by role; preserve the matching code and connecting arrow.
s=text(222,46,'Original window',30,W,500,'middle')+text(678,46,'Safari',30,W,500,'middle')
s+=rect(24,71,394,505,D,21)+qr(130,105,184)
s+=text(222,331,'EXAMPLE CODE',23,M,500,'middle')+rect(92,350,260,77,'#302817',13,A,4)+text(222,406,'482913',47,A,500,'middle')
s+=text(222,482,'Find your number',27,W,400,'middle')+text(222,520,'below the QR code.',27,W,400,'middle')
s+=rect(482,71,394,505,'#f9fafc',21)
s+=text(679,161,'Enter the number',30,INK,500,'middle')+text(679,201,'from your device.',30,INK,400,'middle')
s+=rect(524,256,310,77,W,10,'#9a680e',4)+text(679,311,'482913',45,INK,500,'middle')
s+=button(524,370,310,'OK')+text(679,490,'Then tap OK.',29,INK,500,'middle')
s+=arrow('M365 387 L449 387 L449 294 L510 294')
s+=text(450,614,'Use your own code. Then return to Farframe to finish pairing.',25,M,400,'middle')
save('05-enter-code','Enter your code and tap OK',s,634)
print('Updated five illustrations; decorative brand headings removed.')
