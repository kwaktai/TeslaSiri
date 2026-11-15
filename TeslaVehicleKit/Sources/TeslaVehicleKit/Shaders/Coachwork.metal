#include <metal_stdlib>
#if COACH_NATIVE
#include <metal_raytracing>
using namespace metal::raytracing;
#endif
using namespace metal;
struct Point {float4 p,n;};
struct Node {float4 lo,hi;uint4 link;};
struct Mount {float4x4 m,inv;uint4 ids;float4 base,extra;};
struct Vary {float4 clip [[position]];float3 n [[sample_perspective]];uint id [[flat]];};
vertex Vary coachVertex(uint v [[vertex_id]],uint id [[instance_id]],
                        device const Point* points [[buffer(0)]],device const Mount* mounts [[buffer(1)]],constant float4* p [[buffer(2)]]){
    Point a=points[v];float4x4 m=mounts[id].m,inv=mounts[id].inv;
    float3 x=(m*float4(a.p.xyz,1)).xyz-p[0].xyz;float z=dot(x,p[3].xyz);
    float4 clip=float4(dot(x,p[1].xyz)*2.*p[0].w/p[1].w,dot(x,p[2].xyz)*2.*p[0].w/p[2].w,z-.035,z);
    return {clip,normalize((float4(a.n.xyz,0)*inv).xyz),mounts[id].ids.z==0?0:id+1};
}
fragment half4 coachNormal(Vary v [[stage_in]]){return half4(half3(normalize(v.n)),half(v.id));}

struct Intersection {float t;uint inst,tri;float2 uv;};
constant uint miss=0xffffffff;
struct Scene{device const Point *verts;device const uint *indices;device const Node *nodes,*top;device const Mount *mounts;uint count;};
bool crosses(float3 o,float3 inv,Node n,float maxt){
    float3 a=(n.lo.xyz-o)*inv,b=(n.hi.xyz-o)*inv;
    float3 lo=min(a,b),hi=max(a,b);
    return max(0.f,max(lo.x,max(lo.y,lo.z)))<=min(maxt,min(hi.x,min(hi.y,hi.z)));
}
float3 reciprocal(float3 d){return 1./select(d,copysign(float3(1.e-15),d),abs(d)<1.e-15);}
#if COACH_NATIVE
#define AS_ARG , instance_acceleration_structure accel
#define AS_USE , accel
#define AS_BIND , instance_acceleration_structure accel [[buffer(8)]]
#else
#define AS_ARG
#define AS_USE
#define AS_BIND
#endif
Intersection trace(thread const Scene& s,float3 o,float3 d,float far AS_ARG){
    Intersection h={far,miss,0,0};const float epsilon=.0007;
#if COACH_NATIVE
    intersector<triangle_data,instancing> query;query.assume_geometry_type(geometry_type::triangle);
    auto hit=query.intersect(ray(o,d,epsilon,far),accel,255);
    if(hit.type!=intersection_type::none){h.t=hit.distance;h.inst=hit.instance_id;h.tri=s.mounts[h.inst].ids.y+hit.primitive_id;h.uv=hit.triangle_barycentric_coord;}
#else
    float3 ri=reciprocal(d);
    for(uint i=0;i<s.count;){Node a=s.top[i];
        if(!crosses(o,ri,a,h.t)){i=a.link.x;continue;}i++;
        if(!a.link.z)continue;
        uint id=a.link.y;device const Mount& m=s.mounts[id];
        float3 q=(m.inv*float4(o,1)).xyz,w=(m.inv*float4(d,0)).xyz,wi=reciprocal(w);
        uint n=m.ids.x,end=s.nodes[n].link.x;
        while(n<end){Node b=s.nodes[n];
            if(!crosses(q,wi,b,h.t)){n=b.link.x;continue;}n++;
            for(uint j=b.link.y;j<b.link.y+b.link.z;j++){
                uint k=3*j;float3 v=s.verts[s.indices[k]].p.xyz;
                float3 e=s.verts[s.indices[k+1]].p.xyz-v,f=s.verts[s.indices[k+2]].p.xyz-v;
                float3 p=cross(w,f);float det=dot(e,p);
                if(abs(det)<1.e-13)continue;float3 delta=q-v;float u=dot(delta,p)/det;
                if(u<0.||u>1.)continue;float3 r=cross(delta,e);float v2=dot(w,r)/det;
                if(v2<0.||u+v2>1.)continue;float t=dot(f,r)/det;
                if(t>epsilon&&t<h.t){h.t=t;h.inst=id;h.tri=j;h.uv=float2(u,v2);}
            }
        }
    }
#endif
    return h;
}
constexpr sampler pano(coord::normalized,s_address::repeat,t_address::clamp_to_edge,filter::linear);
constexpr sampler cloth(coord::normalized,address::clamp_to_edge,filter::linear);
constexpr sampler grain(coord::normalized,address::repeat,filter::linear,mip_filter::linear);
float2 latlong(float3 d){return float2(atan2(d.x,d.z)/6.283185307,acos(clamp(d.y,-1.,1.))/3.141592654);}
float3 diffuseSky(float3 n,texture2d_array<float> room){return room.sample(pano,latlong(n),5,level(0.)).rgb;}
float fresnel(float c){
    float q=sqrt(1.-(1.-c*c)/2.25),a=(c-1.5*q)/(c+1.5*q),b=(1.5*c-q)/(1.5*c+q);
    return .5*(a*a+b*b);
}
float3 env(float3 x,float3 r,uint slice,texture2d_array<float> room,texture2d<float> floor,constant float4* p){
    float3 inv=1./float3(6.3,4.65,7.8),v=(x-float3(0.,1.34,0.))*inv,d=normalize(r*inv);
    float h=dot(v,d),t=-h+sqrt(max(.0001,h*h+1.-dot(v,v)));
    float3 dir=dot(v,v)<1.?normalize((v+d*t)/inv):r;
    float3 sky=room.sample(pano,latlong(dir),slice,level(0.)).rgb;
    if(r.y<-.004&&x.y>0.&&p[16].z>.5){
        float dist=-x.y/r.y;float2 q=x.xz+dist*r.xz;
        float w=smoothstep(.012,.33,-r.y)*(1.-smoothstep(4.,14.,dist))*saturate(12.-max(abs(q.x),abs(q.y)));
        float lod=slice<2?.5:slice==2?2.2:3.8;
        sky=mix(sky,floor.sample(cloth,q/24.+.5,level(lod)).rgb,w);
    }
    return sky;
}
float3 fabric(float3 x,float3 r,float spread,texture2d<float> lobes,constant float4* p){
    float3 axis=cross(p[10].xyz,p[11].xyz),offset=p[9].xyz-x;float side=dot(r,axis);
    if(side<=.015)return 0.;float dist=dot(offset,axis)/side;
    if(dist<=0.)return 0.;float3 hit=r*dist-offset;
    float2 a=float2(dot(hit,p[10].xyz),-dot(hit,p[11].xyz))/p[9].w;
    if(any(abs(a)>=2.))return 0.;
    float cone=2.*spread*spread*dist/(p[9].w*max(.18,side));
    const float widths[]={0.,.035,.075,.15,.30,.60,1.2,2.4};
    uint j=0;while(j<6&&widths[j+1]<cone)j++;
    float f=saturate((cone-widths[j])/(widths[j+1]-widths[j]));
    float2 st=(float2(2.)+(a*.25+.5)*256.)/260.;
    return mix(lobes.sample(cloth,float2(st.x,(st.y+j)/8.),level(0.)).rgb,
               lobes.sample(cloth,float2(st.x,(st.y+j+1)/8.),level(0.)).rgb,f)*p[11].w*p[12].rgb;
}
float3 irradiance(float3 x,float3 n,texture2d_array<float> room,constant float4* p,constant float4* taps,float2 visibility=float2(1.)){
    float3 sum=0.,axis=cross(p[10].xyz,p[11].xyz);
    for(uint i=0;i<16;i++){
        float4 a=taps[i*2];float3 col=float3(a.zw,taps[2*i+1].x);
        float3 d=p[9].xyz-x+p[10].xyz*(p[9].w*a.x)+p[11].xyz*(p[10].w*a.y);
        float r2=max(.0001,dot(d,d)),co=max(0.,dot(n,d)*rsqrt(r2));
        sum+=col*((1.-fresnel(co))/.9082*co*max(0.,dot(axis,d))*rsqrt(r2)/r2);
    }
    return diffuseSky(n,room)*visibility.x+sum*p[12].rgb*visibility.y*(4.*p[9].w*p[10].w*p[11].w/(16.*3.141592654));
}
struct Recipe {float3 binder,flake;float cover,rough;};
float paintFresnel(float c,constant float4* p,bool roughReturn){
    if(p[18].x<0. && !roughReturn)return fresnel(c);
    // Neutral (zero pigment) return of the original GLES2 BRDF under the
    // same 18% gray calibration used by NorthlightFinish for the substrate.
    float metal=p[18].y, rough=roughReturn ? 1. : p[18].z, x=1.-rough, f0=.04*(1.-metal);
    float f=mix(f0,max(x,f0),pow(1.-c,5.f));
    float a=min(x*x,exp2(-9.28*c))*x+.0425-.0275*rough;
    float s=saturate((4.*118./255.)*((1.04-.572*rough-1.04*a)*f+.022*rough-.04+1.04*a));
    return s<=.04045 ? s/12.92 : pow((s+.055)/1.055,2.4);
}
Recipe recipe(constant float4* p,float c){
    float3 pigment=p[15].rgb;uint family=uint(p[15].w+.5);
    float metal=saturate(p[16].x/.65),rough=p[16].y;
    float ct=sqrt(1.-(1.-c*c)/2.25);
    // The pigment already includes the tint of the normal-incidence return.
    // A longer path through the color coat can only attenuate that return.
    float3 transmission=pow(p[19].rgb,float3(1./ct));
    bool metered=p[18].x>=0.;
    float3 metalColor=(metered ? 1. : .91)*transmission;
    float cover=family==0?0.:family==2?.29:family==3?.53:family==4?metal:.32+.54*metal;
    if(family==2){
        // Low chroma TiO2-coated mica. Interference is underneath, not a
        // tint on exterior Fresnel. No rainbow or resolved glitter at distance.
        float3 phase=(4.*3.14159265*2.15*116.)/float3(610.,548.,466.);
        float3 mica=.83+.095*cos(phase*ct);
        metalColor=transmission*(metered ? mica/(.83+.095*cos(phase)) : mica);
    }
    float3 binder=metered ? pigment : pigment*.9082/(1.-.0918*pigment);
    return {binder,metal::min(metalColor,1.f),cover,
            family==3?.285:family==2?.34:clamp(.21+.38*(rough-.24),.20,.35)};
}
float4 slopes(float3 q,float3 n,float footprint,texture2d<float> slope){
    // Triplanar in this moving panel's local metric space. Derive the filter
    // from the ray cone, not the screen pixel index or an animation clock.
    float3 w=pow(abs(n),float3(4.));w/=max(.0001,w.x+w.y+w.z);
    float scale=8.7,lod=max(0.,log2(max(.0001,footprint*scale*512.)));
    return 2.*(w.x*slope.sample(grain,q.zy*scale,level(lod))+
               w.y*slope.sample(grain,q.xz*scale,level(lod))+
               w.z*slope.sample(grain,q.xy*scale,level(lod)))-1.;
}
struct Bounce {float3 light;uint code;};
constant uint polishedTrim=4;
float3 layered(Recipe paint,float3 E,float3 C,float3 B,float F,float c,bool steel){
    if(steel){float3 s=float3(.56,.586,.604);return (s+(1.-s)*pow(1.-c,5.))*B;}
    return F*C+(1.-F)*mix(paint.binder*E,paint.flake*B,paint.cover);
}
float3 exteriorTile(float index,float2 uv,float span,float2 grid,texture2d<float> atlas){
    float2 origin=float2(fmod(index,grid.x),metal::floor(index/grid.x));
    float side=64.*span;
    float2 local=fract(uv)*side;
    if(all(local>=.5) && all(local<=side-.5)){
        return atlas.sample(cloth,(origin+local/64.)/grid,level(0.)).rgb;
    }
    // All exterior source samplers repeat. At a UV seam wrap each tap
    // inside this tile, including the interpolation across the two edges.
    float2 lo=metal::floor(local-.5),weight=local-.5-lo,hi=lo+1.;
    lo=select(lo,side-1.,lo<0.);hi=select(hi,0.,hi>=side);
    float2 first=(origin+(lo+.5)/64.)/grid,last=(origin+(hi+.5)/64.)/grid;
    float3 a=atlas.sample(cloth,first,level(0.)).rgb,b=atlas.sample(cloth,float2(last.x,first.y),level(0.)).rgb;
    float3 c=atlas.sample(cloth,float2(first.x,last.y),level(0.)).rgb,d=atlas.sample(cloth,last,level(0.)).rgb;
    return mix(mix(a,b,weight.x),mix(c,d,weight.x),weight.y);
}
float3 exteriorRoom(float3 hit,float3 refl,float3 normal,float rough,texture2d_array<float> room,
                    texture2d<float> floor,constant float4* p){
    // These studio fields were convolved at roughness 0, .105, .24 and .54.
    // Use the mounted roughness to broaden the reflected image continuously.
    if(rough>.54){
        return mix(env(hit,refl,3,room,floor,p),diffuseSky(normal,room),(rough-.54)/.46);
    }
    uint lower=rough<.105 ? 0 : rough<.24 ? 1 : 2;
    constexpr float widths[]={0.,.105,.24,.54};
    float weight=(rough-widths[lower])/(widths[lower+1]-widths[lower]);
    return mix(env(hit,refl,lower,room,floor,p),env(hit,refl,lower+1,room,floor,p),weight);
}
Bounce localLight(thread const Scene& s,float3 x,float3 ray,float3 background,constant float4* p,constant float4* taps,
                  texture2d_array<float> room,texture2d<float> lobes,texture2d<float> floor,texture2d<float> atlas AS_ARG){
    float3 left=1.,sum=0.;uint code=0;
    for(uint layer=0;layer<3;layer++){
        float limit=(ray.y<0.&&x.y>.001)?min(16.f,-x.y/ray.y):16.f;
        if(limit<.0008)break;Intersection h=trace(s,x,ray,limit AS_USE);
        if(h.inst==miss)break;
        device const Mount& m=s.mounts[h.inst];uint type=m.ids.z;
        uint k=h.tri*3;Point a=s.verts[s.indices[k]],b=s.verts[s.indices[k+1]],c=s.verts[s.indices[k+2]];
        float3 bary=float3(1.-h.uv.x-h.uv.y,h.uv);
        float4 vn=bary.x*a.n+bary.y*b.n+bary.z*c.n;
        float3 n=normalize((float4(vn.xyz,0)*m.inv).xyz);if(dot(ray,n)>0.)n=-n;
        float3 hit=x+h.t*ray;float co=saturate(dot(-ray,n)),F=fresnel(co);
        float3 refl=reflect(ray,n);if(!code)code=(type==0||type==polishedTrim)?2:type==1?3:type==2?4:5;
        if(type==0 && m.extra.w>0.){
            float2 uv=float2(dot(bary,float3(a.p.w,b.p.w,c.p.w)),1.-vn.w);
            float span=p[19].w;
            float3 mra=exteriorTile(m.extra.w-1.,uv,span,p[17].xy,atlas);
            mra.rg=saturate(mra.rg*m.extra.xz);
            float3 base=m.extra.y>=0. ? exteriorTile(m.extra.y,uv,span,p[17].xy,atlas) : m.base.rgb;
            float3 E=irradiance(hit,n,room,p,taps,float2(mra.b,1.));
            float3 spec=exteriorRoom(hit,refl,n,mra.g,room,floor,p)*mra.b+fabric(hit,refl,mra.g,lobes,p);
            float3 metalF=mix(base,float3(1.),pow(1.-co,5.f));
            float3 light=base*E*((1.-mra.r)*(1.-F))+mix(float3(F),metalF,mra.r)*spec;
            float opacity=m.base.w<0. ? exteriorTile(-m.base.w-1.,uv,span,p[17].xy,atlas).r : m.base.w;
            if(opacity<1.){
                sum+=left*opacity*light;left*=1.-opacity;x=hit+ray*.001;continue;
            }
            return {sum+left*light,code};
        }
        bool roughReturn=type==1 && m.extra.z>.5;
        float3 shell=env(hit,refl,roughReturn?3:2,room,floor,p)+fabric(hit,refl,roughReturn?.65:.22,lobes,p);
        if(type==3){
            float ct=sqrt(1.-(1.-co*co)/(1.52*1.52));float3 A=pow(m.base.rgb,float3(1./ct));
            float3 T=(1.-F)*(1.-F)*A/max(.00001,1.-F*F*A*A);
            sum+=left*(F+F*A*T)*shell;left*=T;x=hit+ray*.001;continue;
        }
        float3 E=irradiance(hit,n,room,p,taps),indirect;
        if(type==1){
            Recipe r=recipe(p,co);
            F=paintFresnel(co,p,roughReturn);
            indirect=F*shell+(1.-F)*mix(r.binder*E,r.flake*shell,r.cover);
        }else if(type==2){indirect=float3(.57,.60,.61)*shell;}
        else if(type==polishedTrim){
            float3 incident=env(hit,refl,1,room,floor,p)+fabric(hit,refl,m.base.w,lobes,p);
            indirect=F*incident+(1.-F)*m.base.rgb*E;
        }
        else{
            float3 color=m.base.rgb;float tile=m.extra.y;
            if(tile>=0.){
                float2 ij=float2(fmod(tile,p[17].x),metal::floor(tile/p[17].x));
                float2 uv=float2(dot(bary,float3(a.p.w,b.p.w,c.p.w)),1.-vn.w);
                color=atlas.sample(cloth,(ij+(fract(uv)*63.+.5)/64.)/p[17].xy,level(0.)).rgb;
            }
            float metal=saturate(m.extra.x),rough=saturate(m.base.w);
            indirect=color*E*((1.-metal)*(1.-F))+mix(float3(F),color,metal)*mix(shell,E,rough*rough);
        }
        return {sum+left*indirect,code};
    }
    return {sum+left*background,code};
}
Bounce evaluatePaint(float4 g,float2 xy,float z,thread const Scene& scene,
                     constant float4* p,constant float4* taps,texture2d_array<float> room,texture2d<float> lobes,
                     texture2d<float> floor,texture2d<float> slope,texture2d<float> atlas,texture2d<float> relief AS_ARG) {
    uint id=uint(g.w+.5)-1;

    device const Mount& m=scene.mounts[id];
    float2 size=float2(p[1].w,p[2].w);
    float focal=p[0].w;
    float3 ray=p[3].xyz+p[1].xyz*((xy.x-size.x*.5)/focal)+p[2].xyz*((size.y*.5-xy.y)/focal);
    float3 x=p[0].xyz+ray*z,eye=-normalize(ray),n=normalize(g.xyz);if(dot(eye,n)<0.)n=-n;
    float c=saturate(dot(n,eye));
    // The smooth molded parts see the same finite source and nearby
    // bodywork as the paint. The black substrate sits below a dielectric interface.
    if(m.ids.z==polishedTrim){
        float3 r=reflect(-eye,n);
        float3 incident=env(x,r,1,room,floor,p)+fabric(x,r,m.base.w,lobes,p);
        Bounce reflected={incident,0};
        if(p[16].w<.5)reflected=localLight(scene,x+n*.0011,r,incident,p,taps,room,lobes,floor,atlas AS_USE);
        constexpr sampler mask(coord::normalized,address::clamp_to_edge,filter::linear);
        float2 visibility=p[6].w>.5 ? relief.sample(mask,xy/size,level(0.)).rg:float2(1.);
        float3 E=irradiance(x,n,room,p,taps,visibility);
        float F=fresnel(c);
        return {F*reflected.light+(1.-F)*m.base.rgb*E,reflected.code?reflected.code:1};
    }
    float3 obj=(m.inv*float4(x,1)).xyz;
    float3 on=normalize((float4(n,0)*m.m).xyz);float4 slopeSample=slopes(obj,on,z/(focal*max(.19,c)),slope);
    float3 a=(m.m*float4(abs(on.z)<.85?float3(0,0,1):float3(1,0,0),0)).xyz;
    float3 t=normalize(a-n*dot(a,n)),b=cross(n,t);
    bool steel=m.ids.z==2;float matte=m.extra.z;
    float3 coat=normalize(n+(.012*slopeSample.x+.0019*slopeSample.z)*t+(.012*slopeSample.y+.0019*slopeSample.w)*b);
    bool roughReturn=!steel && matte>.5;
    Recipe paint=recipe(p,c);
    if(roughReturn)paint.rough=1.; // The factory jamb material keeps its authored roughness after recoloring.
    float3 flake=normalize(n+(steel?.008:.055)*slopeSample.z*t+(steel?.024:.055)*slopeSample.w*b);
    float3 r=reflect(-eye,coat),rf=reflect(-eye,flake);float F=paintFresnel(saturate(dot(eye,coat)),p,roughReturn);
    float3 C=env(x,r,1,room,floor,p)+fabric(x,r,.095+.16*matte,lobes,p);
    // The normal distribution lives *inside* the binder. Snell's angular
    // Jacobian widens the lobe seen from air, especially at grazing views.
    // The air/clearcoat reflection does not undergo this broadening.
    float ct=sqrt(1.-(1.-c*c)/2.25);
    float rough=steel?.30+.12*matte:min(.65,paint.rough*sqrt(1.5*ct/max(.23,c))+.10*matte);
    float3 Br=env(x,rf,steel?4:2,room,floor,p),wide=env(x,rf,3,room,floor,p);
    float w=saturate((rough-.24)/.30);
    float3 Lkey=fabric(x,rf,rough,lobes,p);
    if(!steel){
        float ci=saturate(dot(n,normalize(p[9].xyz-x))),cti=sqrt(1.-(1.-ci*ci)/2.25);
        // Apply the incident half of the color-coat path to the actual
        // lamp, not to all incoming light as if it shared the eye direction.
        Lkey*=pow(max(p[19].rgb,.001),float3(.5*(1./cti-1./ct)))*(1.-paintFresnel(ci,p,roughReturn));
    }
    float3 B=mix(Br,wide,w)+Lkey;
    constexpr sampler shadowMask(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 visibility=p[6].w>.5 ? relief.sample(shadowMask,xy/size,level(0.)).rg:float2(1.);
    float3 E=irradiance(x,n,room,p,taps,visibility);
    uint hit=0;
    if(p[16].w<.5){
        // Two filtered local lobes. A perfectly smooth coat can show a crisp
        // mirror cap; the buried platelets / brushed steel scatter its image.
        float3 origin=x+n*.0011;
        Bounce cap=localLight(scene,origin,r,C,p,taps,room,lobes,floor,atlas AS_USE);
        hit=cap.code;C=cap.light;
        if(steel||paint.cover>.001){
            float cone=rough*rough;
            float3 axis=normalize(cross(rf,abs(rf.y)<.9?float3(0,1,0):float3(1,0,0))),by=cross(rf,axis);
            float3 smoothB=B;
            const float2 ring[]={{.816,.35},{-.711,.54},{-.105,-.89}};
            for(uint i=0;i<3;i++){
                float3 d=normalize(rf+cone*(ring[i].x*axis+ring[i].y*by)*(steel?1.6:1.3));
                if(dot(d,n)<0.)continue;
                Bounce sample=localLight(scene,origin,d,B,p,taps,room,lobes,floor,atlas AS_USE);
                smoothB+=(sample.light-B)/3.;
            }
            B=max(0.,smoothB);
        }
    }
    return {max(0.,layered(paint,E,C,B,F,c,steel)),hit?hit:1};
}
kernel void exposeCoach(texture2d<half,access::read_write> plate [[texture(0)]],
                        texture2d_ms<half,access::read> surface [[texture(1)]],
                        depth2d_ms<float,access::read> depth [[texture(2)]],
                        texture2d_array<float> room [[texture(3)]],texture2d<float> lobes [[texture(4)]],
                        texture2d<float> floor [[texture(5)]],texture2d<float> slope [[texture(6)]],texture2d<float> atlas [[texture(7)]],
                        texture2d<float> relief [[texture(8)]],texture2d<uint,access::write> events [[texture(9)]],
                        constant float4* p [[buffer(0)]],constant float4* taps [[buffer(1)]],device const Point* verts [[buffer(2)]],
                        device const uint* indices [[buffer(3)]],device const Node* nodes [[buffer(4)]],device const Node* top [[buffer(5)]],
                        device const Mount* mounts [[buffer(6)]] AS_BIND,constant float2* offsets [[buffer(9)]],
                        constant uint& firstRow [[buffer(10)]],uint2 local [[thread_position_in_grid]]){
    uint2 pixel=uint2(local.x,local.y+firstRow);
    bool record=p[17].w>0.;
    if(record)events.write(uint4(0),pixel);
    float4 native=float4(plate.read(pixel));
    if(native.a<.001)return;

    // The native receiver contains hardware radiance and opaque black paint.
    // Shadow its hardware contribution once, including partially painted pixels.
    float2 size=float2(plate.get_width(),plate.get_height());
    if(p[6].w>.5){
        constexpr sampler mask(coord::normalized,address::clamp_to_edge,filter::linear);
        float4 vis=relief.sample(mask,(float2(pixel)+.5)/size,level(0.));
        native.rgb-=max(0.,native.rgb-vis.a*native.a)*((1.-vis.b)*smoothstep(.10,.94,native.a));
    }

    float4 first=0.;float firstDepth=0.,depthSum=0.;
    float2 offsetSum=0.;float3 normalSum=0.;
    uint count=0;bool separate=false;
    for(uint i=0;i<4;i++){
        float4 sample=float4(surface.read(local,i));
        if(sample.w<.5)continue;
        float z=.035/max(1.e-7,1.-depth.read(local,i));
        if(count==0){first=sample;firstDepth=z;}
        // A single smooth patch can be shaded at its covered centroid. Test
        // instance, normal and depth to preserve turned lips and narrow reveals.
        else if(sample.w!=first.w || dot(sample.xyz,first.xyz)<.9994 || abs(z-firstDepth)>.7*firstDepth/p[0].w){
            separate=true;
        }
        offsetSum+=offsets[i];depthSum+=z;normalSum+=sample.xyz;count++;
    }
    if(count>0){
        Scene scene={verts,indices,nodes,top,mounts,uint(p[17].z)};
        float3 sum=0.;uint code=0;
        if(separate){
            for(uint i=0;i<4;i++){
                float4 sample=float4(surface.read(local,i));
                if(sample.w<.5)continue;
                float z=.035/max(1.e-7,1.-depth.read(local,i));
                Bounce b=evaluatePaint(sample,float2(pixel)+offsets[i],z,scene,p,taps,room,lobes,floor,slope,atlas,relief AS_USE);
                sum+=b.light;if(!code)code=b.code;
            }
        }else{
            float4 sample=float4(normalize(normalSum),first.w);
            Bounce b=evaluatePaint(sample,float2(pixel)+offsetSum/count,depthSum/count,scene,p,taps,room,lobes,floor,slope,atlas,relief AS_USE);
            sum=b.light*count;code=b.code;
        }
        native.rgb+=sum*min(.25,native.a/count);
        if(record)events.write(uint4(code),pixel);
    }
    plate.write(half4(native),pixel);
}
