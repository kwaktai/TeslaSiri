/// The car and floor share one studio. The reflected floor field is computed
/// in metres, independent of the camera, and contains no vehicle reflection.
let northlightSetSource = """
float3 printFilm(float3 rgb){
 float3 x=max(0.,rgb);
 // Meter luminance, not the darkest or brightest RGB channel. Preserve
 // chromaticity until the display genuinely runs out of gamut.
 float Y=dot(x,float3(.2126,.7152,.0722));if(Y<=0.)return 0.;
 const float knee=.35;
 float outY=Y<=knee?Y:knee+(1.-knee)*(Y-knee)/(1.+Y-2.*knee);
 float3 c=x*(outY/Y);float peak=max(c.r,max(c.g,c.b));
 return peak<=1.?c:outY+(c-outY)*((1.-outY)/max(.000001,peak-outY));
}
constant float2 taps[]={{0,0},{.527,.085},{-.382,.412},{.082,-.625},{.336,.665},{-.675,-.22},
 {.72,-.415},{-.161,.879},{-.897,.292},{-.482,-.735},{.41,-.86},{.91,.365},{-.024,-.365}};
float3 floorBase(float2 xz){
 // One roll of neutral paper. Pools, highlights and falloff come from
 // illumination, not a second camera-facing pool baked into its albedo.
 // Light gray (approximately N7) provides a readable receiver even through
 // both the windshield and the far side pane, without weakening either tint.
 return float3(.412,.421,.429);
}
// The projected solid-angle measure for Lambertian paper is uniform in
// sin²(elevation). Integrate the actual room radiance once per angular bin.
fragment float4 integrateGroundSky(V v [[stage_in]],texture2d_array<float> room [[texture(0)]]){
 constexpr sampler s(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear);
 uint row=uint(v.pos.y);
 float3 sum=0.;
 for(uint j=0;j<row;j++){
  float y=sqrt((float(j)+.5)/64.);
  sum+=room.sample(s,float2(v.pos.x/32.,acos(y)/3.141592654),0,level(0.)).rgb;
 }
 return float4(sum/64.,1.);
}
float3 groundSkyVisibility(float2 xz,texture2d<float> atlas,texture2d<float> skyIntegral,constant float4* p){
 constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
 float3 total=0.,blocked=0.;
 float texel=p[8].z/256.;
 for(uint i=0;i<32;i++){
  float u=(float(i)+.5)/32.,phi=u*6.283185307;
  float2 dir=float2(sin(phi),cos(phi));
  float3 flux=skyIntegral.sample(s,float2(u,64.5/65.)).rgb;
  total+=flux;
  float2 t0=(p[7].xy-xz)/dir,t1=(p[7].zw-xz)/dir;
  float2 near=min(t0,t1),far=max(t0,t1);
  float enter=max(0.,max(near.x,near.y)-texel),exit=min(far.x,far.y)+texel;
  if(exit<=enter)continue;
  float low=1.,high=0.;
  for(uint j=0;j<28;j++){
   // Short steps near the receiver resolve the contact patches, while the
   // far end of a ray only subtends a small part of the hemisphere.
   float t=float(j)/27.,r=mix(enter,exit,t*(.30+.70*t));
   float2 local=(xz+r*dir-p[8].xy)/(2.*p[8].z)+.5;
   if(any(local<=.001)||any(local>=.999))continue;
   float2 span=atlas.sample(s,(float2(0,2)+local)*.25,level(0.)).rg;
   float2 h=p[8].z*float2(1.-span.g,span.r);
   if(h.y<h.x)continue;
   float2 a=h*h/(h*h+max(r*r,.000001));
   low=min(low,a.x);high=max(high,a.y);
  }
  if(high>low){
   float3 lo=skyIntegral.sample(s,float2(u,(.5+64.*low)/65.)).rgb;
   float3 hi=skyIntegral.sample(s,float2(u,(.5+64.*high)/65.)).rgb;
   blocked+=hi-lo;
  }
 }
 return saturate(1.-blocked/max(total,.00001));
}
// Filter one measured 4x4 radiance cell inside its paired shadow projection.
float groundCellBlock(uint index,float2 samplePosition,float2 projectedU,float2 projectedV,
                      float2 centroid,float2 tile,float2 uv,float region,texture2d<float> atlas){
 constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::linear);
 float2 middle=float2(.5*float(index%4)-.75,.75-.5*float(index/4));
 // A monotone power density on a half-unit interval has its measured centroid
 // at fractional distance m from the bright end and variance m²(1-m)/(1+m).
 // When the cell is uniform the two nodes are the usual Gauss points.
 float2 m=clamp(.5-2.*abs(samplePosition-middle),0.,.5);
 float2 sigma=.5*m*sqrt((1.-m)/(1.+m));
 float spacing=2.*min(length(projectedU)*sigma.x,length(projectedV)*sigma.y);
 float lod=min(4.,log2(max(1.,spacing*256./region)));
 float inset=(.5*exp2(ceil(lod))+.5)/512.;
 float2 low=(tile+inset)*.25,high=(tile+1.-inset)*.25;
 float sum=0.;
 for(uint j=0;j<4;j++){
  float2 node=samplePosition+(2.*float2(j%2,j/2)-1.)*sigma;
  float2 d=node-centroid;
  float2 offset=(d.x*projectedU+d.y*projectedV)/(8.*region);
  sum+=atlas.sample(s,clamp(uv+offset,low,high),level(lod)).r;
 }
 return .25*sum;
}
float4 softGround(float2 xz,texture2d<float> atlas,texture2d<float> skyIntegral,constant float4* p,constant float4* samples){
 constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::linear);
 float2 local=(xz-p[8].xy)/p[8].z*.5+.5;
 float keyBlock[16]={};float3 ambient=1.;
 if(all(local>.012)&&all(local<.988)){
  float boundary=smoothstep(.012,.045,min(min(local.x,1.-local.x),min(local.y,1.-local.y)));
  float3 luma=p[12].rgb*float3(.2126,.7152,.0722);
  for(uint i=0;i<8;i++){
   uint first=(i/4)*8+i%4,second=first+4;
   float2 tile=float2(i%4,i/4),uv=(tile+local)*.25;
   float2 moments=atlas.sample(s,uv,level(2.5)).rg;
   if(moments.x<.008)moments=atlas.sample(s,uv,level(5.)).rg;
   float h=moments.x>.003 ? -log(clamp(moments.y/moments.x,.002,1.))/1.65 : 0.;
   if(h<=0.){
    keyBlock[first]=keyBlock[second]=boundary*atlas.sample(s,uv,level(0.)).r;
    continue;
   }
   // Recover the same radiance-weighted source position used by projectCaster.
   float4 a=samples[first*2],b=samples[second*2];
   float wa=dot(float3(a.zw,samples[first*2+1].x),luma),wb=dot(float3(b.zw,samples[second*2+1].x),luma);
   float2 centroid=mix(a.xy,b.xy,wa+wb>0.?wb/(wa+wb):.5);
   float3 lamp=p[9].xyz+p[9].w*centroid.x*p[10].xyz+p[10].w*centroid.y*p[11].xyz;
   // Differentiate the ground intersection of a source-to-blocker ray along
   // the two fabric axes. At grazing incidence the linearization is bounded.
   float sourceY=max(.001,lamp.y),scale=h/max(.28*sourceY,sourceY-h);
   float2 slope=(lamp.xz-xz)/sourceY;
   float2 projectedU=scale*p[9].w*(p[10].xz-slope*p[10].y);
   float2 projectedV=scale*p[10].w*(p[11].xz-slope*p[11].y);
   keyBlock[first]=boundary*groundCellBlock(first,a.xy,projectedU,projectedV,centroid,tile,uv,p[8].z,atlas);
   keyBlock[second]=boundary*groundCellBlock(second,b.xy,projectedU,projectedV,centroid,tile,uv,p[8].z,atlas);
  }
  ambient=mix(float3(1.),groundSkyVisibility(xz,atlas,skyIntegral,p),boundary);
 }
 float3 incident=0.,unblocked=0.,axis=cross(p[10].xyz,p[11].xyz);
 for(uint i=0;i<16;i++){
  float4 sample=samples[i*2];float3 rgb=float3(sample.zw,samples[i*2+1].x);
  float3 d=p[9].xyz-float3(xz.x,0,xz.y)+p[10].xyz*(p[9].w*sample.x)+p[11].xyz*(p[10].w*sample.y);
  float r2=max(.0001,dot(d,d));float3 energy=rgb*(max(0.,d.y)*max(0.,dot(axis,d))/(r2*r2));
  incident+=energy;unblocked+=energy*(1.-keyBlock[i]);
 }
 float3 gain=p[12].rgb*(4.*p[9].w*p[10].w*p[11].w/(16.*3.14159265)),sky=p[4].yzw;
 // A raised undertray returns some light from the surrounding paper.
 // At a tire touching the paper there is no exposed underside to bounce
 // that light back. Estimate one diffuse bounce with a dark 8% chassis.
 float rebound=0.;
 if(all(local>.001)&&all(local<.999)){
  float2 span=atlas.sample(s,(float2(0,2)+local)*.25,level(0.)).rg;
  float clearance=p[8].z*(1.-span.g);
  rebound=.08*smoothstep(0.,.06,clearance);
 }
 float3 fill=sky*ambient+unblocked*gain+floorBase(xz)*rebound*(1.-ambient)*(sky+incident*gain);
 // Store the *relative* light reaching this point as well as its absolute
 // radiance. A grazing reflection should inherit the shadow, not acquire
 // the boundary of a differently exposed, finite texture.
 float visibility=dot(fill,float3(.2126,.7152,.0722))/dot(sky+incident*gain,float3(.2126,.7152,.0722));
 return float4(floorBase(xz)*fill,saturate(visibility));
}
fragment float4 groundLightField(V v [[stage_in]],texture2d<float> atlas [[texture(0)]],texture2d<float> skyIntegral [[texture(1)]],constant float4* p [[buffer(0)]],constant float4* samples [[buffer(1)]]){
 return softGround((v.pos.xy/1024.-.5)*24.,atlas,skyIntegral,p,samples);
}
float3 coveIrradiance(float3 pos,float3 normal,constant float4* p,constant float4* lamps,texture2d_array<float> sky){
 constexpr sampler skySampler(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear);
 float2 uv=float2(atan2(normal.x,normal.z)/6.283185307,acos(clamp(normal.y,-1.,1.))/3.141592654);
 float3 E=sky.sample(skySampler,uv,5,level(0.)).rgb,axis=cross(p[10].xyz,p[11].xyz),sum=0.;
 for(uint i=0;i<16;i++){
    float4 q=lamps[i*2];float3 d=p[9].xyz-pos+q.x*p[10].xyz*p[9].w+q.y*p[11].xyz*p[10].w;
    float r2=max(.001,dot(d,d));sum+=float3(q.zw,lamps[2*i+1].x)*max(0.,dot(d,normal))*max(0.,dot(d,axis))/(r2*r2);
 }
 return E+sum*p[12].rgb*(4.*p[9].w*p[10].w*p[11].w/(16.*3.14159265));
}
float4 photograph(float2 uv,float3 ray,float4 obj,texture2d<float> mirror,texture2d<float> passMap,texture2d<float> field,sampler s,constant float4* p,float3 reflection,float3 transmission,texture2d_array<float> sky,constant float4* lamps){
 float exposure=p[4].x;
 if(obj.a>=.9999)return float4(enc(printFilm(exposure*(reflection+transmission*obj.rgb))),1.);
 float3 eye=p[0].xyz,rd=normalize(ray);
 float t=rd.y<-.00001 && eye.y>=0. ? -eye.y/rd.y:INFINITY;
 float a=dot(rd.xz,rd.xz),b=dot(eye.xz,rd.xz);
 float radius=max(14.,p[8].z*2.5),roll=radius*.26,start=radius-roll;
 float disc=b*b+a*(radius*radius-dot(eye.xz,eye.xz));
 float edge=a>1e-7 && disc>=0. ? (-b+sqrt(disc))/a:INFINITY;
 if(edge<.001)edge=INFINITY;
 float3 pos=eye+rd*(isfinite(t)?t:0.);
 float3 wallPos=isfinite(edge)?eye+rd*edge:rd*radius;
 float3 room;
 if(isfinite(t) && t<=edge && length(pos.xz)<start){
    float2 xz=pos.xz;
    float3 base=floorBase(xz)*p[4].yzw;
    float2 fuv=xz/24.+.5;
    float feather=saturate(12.-max(abs(xz.x),abs(xz.y)));
    base=mix(base,field.sample(s,fuv).rgb,feather);
    float2 m=float2(uv.x,1.-uv.y);
    float3 bounce=reflect(rd,float3(0,1,0));
    float3 inv=1./select(bounce,float3(.00001),abs(bounce)<.00001);
    float3 lo=(p[13].xyz-pos)*inv,hi=(p[14].xyz-pos)*inv;
    float3 n=min(lo,hi),f=max(lo,hi);
    float nearHit=max(0.,max(n.x,max(n.y,n.z))),farHit=min(f.x,min(f.y,f.z));
    float travel=clamp(nearHit+.32*max(0.,farHit-nearHit),.025,5.);
    float cone=.118*p[0].w*travel/max(.25,length(eye-pos)+travel);
    float2 footprint=max(.58,cone)/float2(p[1].w,p[2].w);
    constexpr sampler satin(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::linear);
    float lod=log2(max(1.,.43*footprint.x*float(mirror.get_width())));
    float4 sum=0.;float3 through=0.;float mw=0.;
    for(uint i=0;i<13;i++){float q=1.-.60*dot(taps[i],taps[i]);float2 st=m+taps[i]*footprint;
     sum+=mirror.sample(satin,st,level(lod))*q;if(p[8].w>.5)through+=passMap.sample(satin,st,level(lod)).rgb*q;mw+=q;}
    sum/=mw;through=p[8].w>.5?through/mw:float3(1.-sum.a);float gloss=.057+.30*pow(1.-saturate(-rd.y),5.);
    base=base*(1.-gloss*(1.-through))+gloss*sum.rgb;
    // Beyond the finite shadow field the same paper still receives the lamp.
    float3 farPaper=floorBase(xz)*coveIrradiance(pos,float3(0,1,0),p,lamps,sky);
    room=mix(farPaper,base,feather);
 }else{
    float3 wPos=wallPos,n;
    if(isfinite(edge) && wallPos.y<roll){
       float innerDisc=b*b+a*(start*start-dot(eye.xz,eye.xz));
       float l=innerDisc>=0.?max(0.f,(-b+sqrt(innerDisc))/a):max(0.f,-b/a),h=edge;
       for(uint i=0;i<12;i++){
          float mid=(l+h)*.5;float3 q=eye+rd*mid;
          float radial=clamp(length(q.xz)-start,0.,roll);
          float surface=roll-sqrt(max(0.,roll*roll-radial*radial));
          if(q.y>surface)l=mid;else h=mid;
       }
       wPos=eye+rd*((l+h)*.5);float sn=saturate((length(wPos.xz)-start)/roll);
       float2 inward=-normalize(wPos.xz+float2(1.e-7));
       n=float3(inward.x*sn,sqrt(max(0.,1.-sn*sn)),inward.y*sn);
    }else{float2 inward=-normalize(wPos.xz+float2(1.e-7));n=float3(inward.x,0,inward.y);}
    room=floorBase(wPos.xz)*coveIrradiance(wPos,n,p,lamps,sky);
 }
 return float4(enc(printFilm(exposure*(reflection+transmission*(obj.rgb+(1.-saturate(obj.a))*room)))),1.);
}
"""
