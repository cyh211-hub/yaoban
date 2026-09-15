// In-process contract test. Does not install a driver or touch system audio.
#include <CoreAudio/AudioServerPlugIn.h>
#include <dlfcn.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static OSStatus storage(AudioServerPlugInHostRef host, CFStringRef key, CFPropertyListRef *out) { *out = NULL; return 0; }
static void get(AudioServerPlugInDriverRef d, AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope, UInt32 size, void *value) {
    AudioObjectPropertyAddress p = {selector,scope,kAudioObjectPropertyElementMain};
    UInt32 written=0;
    assert((*d)->GetPropertyData(d,object,0,&p,0,NULL,size,&written,value)==0);
    assert(written==size);
}
int main(int argc, char **argv) {
    assert(argc==2);
    void *library=dlopen(argv[1],RTLD_NOW|RTLD_LOCAL);
    if(!library) { fprintf(stderr,"%s\n",dlerror()); return 1; }
    void *(*factory)(CFAllocatorRef, CFUUIDRef)=dlsym(library,"BlackHole_Create");
    assert(factory);
    AudioServerPlugInDriverRef d=factory(NULL,kAudioServerPlugInTypeUUID);
    assert(d);
    AudioServerPlugInHostInterface host={0}; host.CopyFromStorage=storage;
    assert((*d)->Initialize(d,&host)==0);
    UInt32 value;
    get(d,3,kAudioDevicePropertyTransportType,kAudioObjectPropertyScopeGlobal,4,&value);
    assert(value==kAudioDeviceTransportTypeUSB);
    get(d,3,kAudioDevicePropertyIsHidden,kAudioObjectPropertyScopeGlobal,4,&value); assert(value==0);
    get(d,12,kAudioDevicePropertyIsHidden,kAudioObjectPropertyScopeGlobal,4,&value); assert(value==1);
    CFStringRef text;
    get(d,3,kAudioObjectPropertyName,kAudioObjectPropertyScopeGlobal,sizeof(text),&text);
    assert(CFEqual(text,CFSTR("小米遥控器麦克风"))); CFRelease(text);
    get(d,12,kAudioDevicePropertyDeviceUID,kAudioObjectPropertyScopeGlobal,sizeof(text),&text);
    assert(CFEqual(text,CFSTR("MiRemoteLabMic_2_UID"))); CFRelease(text);
    Float64 rate;
    get(d,3,kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,sizeof(rate),&rate); assert(rate==48000);
    assert((*d)->StartIO(d,3,1)==0 && (*d)->StartIO(d,12,2)==0);
    float sent[512],received[512];
    for(int i=0;i<512;++i) sent[i]=(float)(i-256)/1024;
    AudioServerPlugInIOCycleInfo cycle={0};
    cycle.mOutputTime.mSampleTime=10000; cycle.mInputTime.mSampleTime=10000;
    assert((*d)->DoIOOperation(d,12,7,2,kAudioServerPlugInIOOperationWriteMix,256,&cycle,sent,NULL)==0);
    assert((*d)->DoIOOperation(d,3,4,1,kAudioServerPlugInIOOperationReadInput,256,&cycle,received,NULL)==0);
    assert(memcmp(sent,received,sizeof(sent))==0);
    cycle.mInputTime.mSampleTime=11000;
    assert((*d)->DoIOOperation(d,3,4,1,kAudioServerPlugInIOOperationReadInput,256,&cycle,received,NULL)==0);
    for(int i=0;i<512;++i) assert(received[i]==0);
    assert((*d)->StopIO(d,12,2)==0 && (*d)->StopIO(d,3,1)==0);
    puts("PASS: actual HAL bundle loads, USB input name/UID, hidden output, 48 kHz, exact audio loopback and idle silence (in process only)");
}
