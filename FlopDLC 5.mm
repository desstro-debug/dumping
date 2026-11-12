// =========================================================================================
// FlopDLC.mm — v136.3 (Key System UI Fixed & Mobile Adjusted)
// =========================================================================================
// Сборка: clang++ -arch arm64 -miphoneos-version-min=15.0 -isysroot $(xcrun --sdk iphoneos --show-sdk-path) -std=c++17 -fobjc-arc -O2 -fvisibility=hidden -dynamiclib -install_name @rpath/FlopDLC.dylib -Wl,-undefined,dynamic_lookup -framework Foundation -framework UIKit -framework CoreGraphics -framework CoreFoundation -framework QuartzCore -framework AVFoundation FlopDLC.mm -o FlopDLC.dylib
// =========================================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>

#include <dlfcn.h>
#include <signal.h>
#include <unistd.h>
#include <fcntl.h>
#include <execinfo.h>
#include <stdint.h>
#include <string.h>
#include <atomic>
#include <cmath>
#include <vector>
#include <unordered_map>
#include <string>
#include <algorithm>
#include <mach/mach_time.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <mach/vm_param.h>
#include <dispatch/dispatch.h>
#include <CoreFoundation/CoreFoundation.h>

static constexpr const char* kEspVersion = "136.3";

#define SANE_PTR(p) ((uintptr_t)(p) > 0x100000000 && (uintptr_t)(p) < 0x00007FFFFFFFFFFF)

struct __attribute__((aligned(4))) Vec3 {
    float x;
    float y;
    float z;
    
    Vec3() : x(0), y(0), z(0) {}
    
    Vec3(float x, float y, float z) : x(x), y(y), z(z) {}
    
    Vec3 operator+(const Vec3& v) const {
        return Vec3(x + v.x, y + v.y, z + v.z);
    }
    
    Vec3 operator-(const Vec3& v) const {
        return Vec3(x - v.x, y - v.y, z - v.z);
    }
    
    Vec3 operator*(float s) const {
        return Vec3(x * s, y * s, z * s);
    }
    
    float Length() const {
        return std::sqrt(x * x + y * y + z * z);
    }
};

struct __attribute__((aligned(4))) Vec2 {
    float x;
    float y;
    
    Vec2() : x(0), y(0) {}
    
    Vec2(float x, float y) : x(x), y(y) {}
};

struct __attribute__((aligned(4))) Quat {
    float x;
    float y;
    float z;
    float w;
    
    Quat() : x(0), y(0), z(0), w(1) {}
};

struct __attribute__((aligned(4))) UnityColor {
    float r;
    float g;
    float b;
    float a;
    
    UnityColor() : r(0), g(0), b(0), a(1) {}
    
    UnityColor(float r, float g, float b, float a) : r(r), g(g), b(b), a(a) {}
};

namespace Math {
    static constexpr float DEG2RAD = 3.14159265358979323846f / 180.0f;
    
    inline float Clamp(float v, float lo, float hi) {
        if (v < lo) {
            return lo;
        }
        if (v > hi) {
            return hi;
        }
        return v;
    }
    
    inline bool Finite(float v) {
        return std::isfinite(v);
    }
    
    inline bool Finite(const Vec3& v) {
        bool fx = std::isfinite(v.x);
        bool fy = std::isfinite(v.y);
        bool fz = std::isfinite(v.z);
        return fx && fy && fz;
    }
}

static NSString* gLogDocPath = nil;
static NSLock* gLogLock = nil;

static void LOG(NSString* format, ...) {
    @try {
        va_list args;
        va_start(args, format);
        NSString* s = [[NSString alloc] initWithFormat:format arguments:args];
        va_end(args);
        
        if (!s) {
            return;
        }
        
        NSLog(@"[FlopDLC] %@", s);
        
        if (!gLogLock) {
            return;
        }
        if (!gLogDocPath) {
            return;
        }
        
        [gLogLock lock];
        
        NSFileHandle* fh = [NSFileHandle fileHandleForWritingAtPath:gLogDocPath];
        if (fh) {
            @try {
                [fh seekToEndOfFile];
                NSString* line = [s stringByAppendingString:@"\n"];
                NSData* data = [line dataUsingEncoding:NSUTF8StringEncoding];
                [fh writeData:data];
                [fh closeFile];
            } @catch (NSException* e) {
                [fh closeFile];
            }
        }
        
        [gLogLock unlock];
    } @catch (NSException* e) {
    }
}

static NSString* SafeFmt(NSString* fmt, ...) {
    @try {
        va_list args;
        va_start(args, fmt);
        NSString* s = [[NSString alloc] initWithFormat:fmt arguments:args];
        va_end(args);
        
        if (s) {
            return s;
        }
        return @"";
    } @catch (NSException* e) {
        return @"";
    }
}

static NSString* SafeStr(NSString* s) {
    if (s) {
        return s;
    }
    return @"";
}

static int gCrashFd = -1;

static void CrashSignalHandler(int sig, siginfo_t* info, void* ctx) {
    char buf[256];
    void* addr = NULL;
    if (info) {
        addr = info->si_addr;
    }
    
    int n = snprintf(buf, sizeof(buf), "\n=== CRASH signal=%d addr=%p ===\n", sig, addr);
    
    if (n > 0) {
        if (gCrashFd >= 0) {
            write(gCrashFd, buf, n);
        }
    }
    
    void* frames[64];
    int fc = backtrace(frames, 64);
    
    if (gCrashFd >= 0) {
        backtrace_symbols_fd(frames, fc, gCrashFd);
    }
    
    signal(sig, SIG_DFL);
    raise(sig);
}

static void InstallCrashHandler(void) {
    @try {
        NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString* docs = nil;
        if (paths.count > 0) {
            docs = paths.firstObject;
        }
        
        if (!docs) {
            return;
        }
        
        gLogDocPath = [docs stringByAppendingPathComponent:@"flop_log.txt"];
        
        NSFileManager* fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:gLogDocPath error:nil];
        
        [@"" writeToFile:gLogDocPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        
        gLogLock = [NSLock new];
        
        NSString* crashPath = [docs stringByAppendingPathComponent:@"flop_crash.txt"];
        gCrashFd = open([crashPath UTF8String], O_WRONLY | O_CREAT | O_APPEND, 0644);
        
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = CrashSignalHandler;
        sa.sa_flags = SA_SIGINFO;
        sigemptyset(&sa.sa_mask);
        
        sigaction(SIGSEGV, &sa, NULL);
        sigaction(SIGBUS, &sa, NULL);
        sigaction(SIGABRT, &sa, NULL);
    } @catch (NSException* e) {
    }
}

static inline uint64_t NowMs(void) {
    uint64_t abs_time = mach_absolute_time();
    uint64_t ms_time = abs_time / 1000000ULL;
    return ms_time;
}

// AUDIO
static AVAudioPlayer* gKillPlayer = nil;
static AVAudioPlayer* gHitPlayer = nil;

static AVAudioPlayer* MakeTonePlayer(float freq, float dur, float amp) {
    @try {
        NSMutableData* wav = [NSMutableData data];
        int rate = 44100;
        int n = (int)(rate * dur);
        
        [wav appendBytes:"RIFF" length:4];
        uint32_t chunk = 36 + n * 2;
        [wav appendBytes:&chunk length:4];
        [wav appendBytes:"WAVEfmt " length:8];
        uint32_t sub1 = 16;
        [wav appendBytes:&sub1 length:4];
        uint16_t fmt = 1;
        [wav appendBytes:&fmt length:2];
        uint16_t ch = 1;
        [wav appendBytes:&ch length:2];
        uint32_t sr = rate;
        [wav appendBytes:&sr length:4];
        uint32_t br = rate * 2;
        [wav appendBytes:&br length:4];
        uint16_t ba = 2;
        [wav appendBytes:&ba length:2];
        uint16_t bps = 16;
        [wav appendBytes:&bps length:2];
        [wav appendBytes:"data" length:4];
        uint32_t sub2 = n * 2;
        [wav appendBytes:&sub2 length:4];
        
        for (int i = 0; i < n; i++) {
            double t = (double)i / rate;
            double env = 1.0 - (t / dur);
            if (env < 0) {
                env = 0;
            }
            double sin_val = sin(2.0 * M_PI * (double)freq * t) * 0.7 + sin(2.0 * M_PI * (double)(freq * 1.5) * t) * 0.3;
            int16_t s = (int16_t)(sin_val * 32767.0 * env * amp);
            [wav appendBytes:&s length:2];
        }
        
        AVAudioPlayer* p = [[AVAudioPlayer alloc] initWithData:wav error:nil];
        [p prepareToPlay];
        return p;
    } @catch (NSException* e) {
        return nil;
    }
}

static void PlayKillSound(void) {
    if (!gKillPlayer) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        gKillPlayer.currentTime = 0;
        [gKillPlayer play];
    });
}

static void PlayHitSound(void) {
    if (!gHitPlayer) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        gHitPlayer.currentTime = 0;
        [gHitPlayer play];
    });
}

// OFFSETS
namespace off {
    constexpr uint64_t kObjCachedPtr = 0x10;
    constexpr uint64_t kPlayerIsDead = 0xB8;
    constexpr uint64_t kPlayerTeam = 0xBC;
    constexpr uint64_t kPlayerNickName = 0xC0;
    constexpr uint64_t kPlayerCharacter = 0xF0;
    constexpr uint64_t kCharModelContainer = 0x120;
    constexpr uint64_t kCharController = 0x130;
    constexpr uint64_t kCharHealth = 0x13C;
    constexpr uint64_t kCharArmor = 0x140;
    constexpr uint64_t kCharIsDead = 0x150;
    
    constexpr uint64_t kCtrlCC = 0x48;
    constexpr uint64_t kCtrlEquip = 0x50;
    
    constexpr uint64_t kLocalCamera = 0x90;
    constexpr uint64_t kOtherRemoteVis = 0xC8;
    constexpr uint64_t kRvModel = 0x48;
    constexpr uint64_t kRvItemView = 0xB0;
    constexpr uint64_t kModelAnimator = 0x20;
    constexpr uint64_t kModelWeaponTf = 0x40;
    constexpr uint64_t kModelHead = 0x58;
    constexpr uint64_t kCamComponent = 0x48;
    constexpr uint64_t kCamIsBusy = 0x60;
    constexpr uint64_t kCamIsDisable = 0x61;
    constexpr uint64_t kCamHands = 0x40;
    
    constexpr uint64_t kEquipData = 0x178;
    constexpr uint64_t kEquipCoolTime = 0x180;
    constexpr uint64_t kWepAmmoTotal = 0x1BC;
    constexpr uint64_t kWepAmmo = 0x1C0;
    constexpr uint64_t kWepIsReload = 0x1C4;
    constexpr uint64_t kWepLastShotTime = 0x228;
    constexpr uint64_t kWepSpread = 0x1F0; // Vector2 <Spread>k__BackingField
    constexpr uint64_t kWepRecoil = 0x1F8; // Vector3 <Recoil>k__BackingField
    constexpr uint64_t kWepRangeData = 0x1B0; // WeaponDataRange <RangeData>k__BackingField
    constexpr uint64_t kWepOffset = 0x1D8; // Vector3 Offset
    constexpr uint64_t kWepJyw = 0x1E4; // Vector3 jyw
    constexpr uint64_t kWepJzc = 0x204; // Vector3 jzc
    constexpr uint64_t kWepIsAiming = 0x1A1; // bool IsAiming
    constexpr uint64_t kDataAmmo = 0xA8;
    constexpr uint64_t kDataRecoilPattern = 0xA0; // List<Vector2> RecoilPattern
    constexpr uint64_t kDataFireBackOffset = 0x90; // Vector3 _fireBackOffset
    constexpr uint64_t kDataFireBackTime = 0x9C; // float _fireBackOffsetTime
    constexpr uint64_t kRangeShootOffset = 0xF8; // Vector2 ShootOffset
    constexpr uint64_t kRangeSpreadMove = 0x100; // Vector2 SpreadMove
    constexpr uint64_t kRangeOffsetCool = 0x108; // float OffsetCool
    constexpr uint64_t kRangeStandingBallisticMul = 0x10C; // float StandingBallisticMul
    constexpr uint64_t kRangeRecoilPatternScale = 0x110; // float RecoilPatternScale
    constexpr uint64_t kRangeUnscopedRecoilMul = 0x114; // float UnscopedRecoilMul
    constexpr uint64_t kCamRot = 0x30; // Vector2 rot
    constexpr uint64_t kCamAdditionalRot = 0x38; // Vector2 additionalRot
    constexpr uint64_t kCamStateBegin = 0x30; // SceneLevelCamera::rot
    constexpr uint64_t kCamStateSize = 0x10; // rot + additionalRot only (safe to restore)
    
    constexpr uint64_t kMoveIsGrounded = 0x28;
    constexpr uint64_t kMoveSpeed = 0x3C;
    constexpr uint64_t kMoveGravity = 0x40;
    constexpr uint64_t kMoveJumpH = 0x4C;
    constexpr uint64_t kMoveVelocity = 0x5C;
    
    constexpr uint64_t kVolumeWeight = 0x2C;
}

// IL2CPP TYPES
typedef void* (*fn_domain_get)();
typedef void** (*fn_domain_get_assemblies)(void*, size_t*);
typedef void* (*fn_assembly_get_image)(void*);
typedef void* (*fn_class_from_name)(void*, const char*, const char*);
typedef void* (*fn_class_get_method_from_name)(void*, const char*, int);
typedef void* (*fn_class_get_methods)(void*, void**);
typedef const char* (*fn_method_get_name)(void*);
typedef uint32_t (*fn_method_get_param_count)(void*);
typedef void* (*fn_method_get_param)(void*, uint32_t);
typedef char* (*fn_type_get_name)(void*);
typedef void* (*fn_class_get_type)(void*);
typedef void* (*fn_type_get_object)(void*);
typedef void* (*fn_runtime_invoke)(void*, void*, void**, void**);
typedef void* (*fn_thread_attach)(void*);
typedef uint32_t (*fn_gchandle_new)(void*, bool);
typedef void (*fn_gchandle_free)(uint32_t);
typedef void* (*fn_gchandle_get_target)(uint32_t);
typedef void* (*fn_string_new)(const char*);
typedef void* (*fn_object_new)(void*);
typedef void* (*fn_array_new)(void*, size_t);

typedef Vec3 (*fn_camW2S)(void*, Vec3, void*);
typedef int (*fn_camGetPixelWidth)(void*, void*);
typedef int (*fn_camGetPixelHeight)(void*, void*);
typedef float (*fn_camGetFov)(void*, void*);
typedef void (*fn_camSetAspect)(void*, float, void*);
typedef void (*fn_camSetFov)(void*, float, void*);
typedef void (*fn_sceneSetFov)(void*, float, void*);
typedef Vec3 (*fn_tfGetPos)(void*, void*);
typedef void (*fn_tfSetPos)(void*, Vec3, void*);
typedef Vec3 (*fn_tfGetLocalScale)(void*, void*);
typedef void (*fn_tfSetLocalScale)(void*, Vec3, void*);
typedef Vec3 (*fn_tfGetEuler)(void*, void*);
typedef void* (*fn_getBoneTransform)(void*, int, void*);
typedef void* (*fn_getTransform)(void*, void*);
typedef void* (*fn_getSkybox)(void* mi);
typedef void (*fn_matSetColor)(void* self, void* name, UnityColor value, void* mi);
typedef void* (*fn_rendGetSharedMats)(void*, void*);
typedef void (*fn_rendSetSharedMats)(void*, void*, void*);
typedef void (*fn_matSetFloat)(void*, void*, float, void*);
typedef void (*fn_matSetTexture)(void*, void*, void*, void*);
typedef void (*fn_matSetInt)(void*, void*, int, void*);
typedef void (*fn_matEnableKeyword)(void*, void*, void*);
typedef void (*fn_matSetRenderQueue)(void*, int, void*);
typedef void (*fn_LookAtTarget)(void* self, Vec3 target, void* mi);
typedef bool (*fn_CheckSeen)(void* self, Vec3 target, void* mi);
typedef void* (*fn_getGameObject)(void*, void*);
typedef UnityColor (*fn_renderGetAmbientLight)(void*);
typedef void (*fn_renderSetAmbientLight)(void*, UnityColor, void*);
typedef float (*fn_lightGetIntensity)(void*, void*);
typedef void (*fn_lightSetIntensity)(void*, float, void*);
typedef UnityColor (*fn_lightGetColor)(void*, void*);
typedef void (*fn_lightSetColor)(void*, UnityColor, void*);
typedef void (*fn_setFog)(bool, void*);
typedef bool (*fn_getFog)(void*);

static fn_domain_get p_domain_get = nullptr;
static fn_domain_get_assemblies p_domain_get_assemblies = nullptr;
static fn_assembly_get_image p_assembly_get_image = nullptr;
static fn_class_from_name p_class_from_name = nullptr;
static fn_class_get_method_from_name p_class_get_method_from_name = nullptr;
static fn_class_get_methods p_class_get_methods = nullptr;
static fn_method_get_name p_method_get_name = nullptr;
static fn_method_get_param_count p_method_get_param_count = nullptr;
static fn_method_get_param p_method_get_param = nullptr;
static fn_type_get_name p_type_get_name = nullptr;
static fn_class_get_type p_class_get_type = nullptr;
static fn_type_get_object p_type_get_object = nullptr;
static fn_runtime_invoke p_runtime_invoke = nullptr;
static fn_thread_attach p_thread_attach = nullptr;
static fn_gchandle_new p_gchandle_new = nullptr;
static fn_gchandle_free p_gchandle_free = nullptr;
static fn_gchandle_get_target p_gchandle_get_target = nullptr;
static fn_string_new p_string_new = nullptr;
static fn_object_new p_object_new = nullptr;
static fn_array_new p_array_new = nullptr;

static void* gDomain = nullptr;
static void* gObjCls = nullptr;
static void* gGOCls = nullptr;
static void* gTransformCls = nullptr;
static void* gAnimatorCls = nullptr;
static void* gCharCls = nullptr;
static void* gVolumeCls = nullptr;
static void* gMatCls = nullptr;
static void* gSkyboxCls = nullptr;
static void* gRendererCls = nullptr;
static void* gLightCls = nullptr;
static void* gColorAdjCls = nullptr;
static void* gBloomCls = nullptr;
static void* gClampedFCls = nullptr;
static void* gMinFCls = nullptr;
static void* gFloatPCls = nullptr;
static void* gCamDataCls = nullptr;

static uint32_t gPlayerTypeHandle = 0;
static uint32_t gVolumeTypeHandle = 0;
static uint32_t gLightTypeHandle = 0;
static uint32_t gCamDataTypeHandle = 0;

static void* p_findPlayerMI = nullptr;
static void* p_findVolumeMI = nullptr;
static void* p_getBoneTransformMI = nullptr;
static void* p_camW2SMI = nullptr;
static void* p_camGetPixelWidthMI = nullptr;
static void* p_camGetPixelHeightMI = nullptr;
static void* p_camGetFovMI = nullptr;
static void* p_camSetAspectMI = nullptr;
static void* p_camSetFovMI = nullptr;
static void* p_sceneSetFovMI = nullptr;
static void* p_tfGetPosMI = nullptr;
static void* p_tfSetPosMI = nullptr;
static void* p_tfGetLocalScaleMI = nullptr;
static void* p_tfSetLocalScaleMI = nullptr;
static void* p_tfGetEulerMI = nullptr;
static void* p_getTransformMI = nullptr;
static void* p_getSkyboxMI = nullptr;
static void* p_matSetColorMI = nullptr;
static void* p_matCopyCtorMI = nullptr;
static void* p_matSetFloatMI = nullptr;
static void* p_matSetTextureMI = nullptr;
static void* p_matSetIntMI = nullptr;
static void* p_matEnableKeywordMI = nullptr;
static void* p_matSetRQMI = nullptr;
static void* p_lightGetIntensityMI = nullptr;
static void* p_lightSetIntensityMI = nullptr;
static void* p_lightGetColorMI = nullptr;
static void* p_lightSetColorMI = nullptr;
static void* p_setFogMI = nullptr;
static void* p_getFogMI = nullptr;
static void* p_cfaValMI = nullptr;
static void* p_mfaValMI = nullptr;
static void* p_fpaValMI = nullptr;
static void* p_rendGetSharedMatsMI = nullptr;
static void* p_rendSetSharedMatsMI = nullptr;
static void* p_getCompsInChildrenMI = nullptr;
static void* p_getGameObjectMI = nullptr;
static void* p_lookAtTargetMI = nullptr;
static void* p_checkSeenMI = nullptr;

static fn_camW2S p_camW2S = nullptr;
static fn_camGetPixelWidth p_camGetPixelWidth = nullptr;
static fn_camGetPixelHeight p_camGetPixelHeight = nullptr;
static fn_camGetFov p_camGetFov = nullptr;
static fn_camSetAspect p_camSetAspect = nullptr;
static fn_camSetFov p_camSetFov = nullptr;
static fn_sceneSetFov p_sceneSetFov = nullptr;
static fn_tfGetPos p_tfGetPos = nullptr;
static fn_tfSetPos p_tfSetPos = nullptr;
static fn_tfGetLocalScale p_tfGetLocalScale = nullptr;
static fn_tfSetLocalScale p_tfSetLocalScale = nullptr;
static fn_tfGetEuler p_tfGetEuler = nullptr;
static fn_getBoneTransform p_getBoneTransform = nullptr;
static fn_getTransform p_getTransform = nullptr;
static fn_getSkybox p_getSkybox = nullptr;
static fn_matSetColor p_matSetColor = nullptr;
static fn_rendGetSharedMats p_rendGetSharedMats = nullptr;
static fn_rendSetSharedMats p_rendSetSharedMats = nullptr;
static fn_matSetFloat p_matSetFloat = nullptr;
static fn_matSetTexture p_matSetTexture = nullptr;
static fn_matSetInt p_matSetInt = nullptr;
static fn_matEnableKeyword p_matEnableKeyword = nullptr;
static fn_matSetRenderQueue p_matSetRQ = nullptr;
static fn_lightGetIntensity p_lightGetIntensity = nullptr;
static fn_lightSetIntensity p_lightSetIntensity = nullptr;
static fn_lightGetColor p_lightGetColor = nullptr;
static fn_lightSetColor p_lightSetColor = nullptr;
static fn_setFog p_setFog = nullptr;
static fn_getFog p_getFog = nullptr;
static fn_getGameObject p_getGameObject = nullptr;
static fn_LookAtTarget p_lookAtTarget = nullptr;
static fn_CheckSeen p_CheckSeen = nullptr;

// GLOBALS
static std::atomic<bool> gEspEnabled{false};
static std::atomic<bool> gSkeletonEnabled{false};
static std::atomic<bool> gHealthBarEnabled{false};
static std::atomic<bool> gNameEnabled{false};
static std::atomic<bool> gTracersEnabled{false};
static std::atomic<bool> gOofEnabled{false};

static std::atomic<bool> gAimbotEnabled{false};
static std::atomic<bool> gAimOnFireEnabled{false};
static std::atomic<bool> gSilentAimEnabled{false};
static std::atomic<bool> gHotAimbotEnabled{false};
static std::atomic<bool> gHotAimOnFireEnabled{false};
static std::atomic<bool> gHotEspEnabled{false};
static std::atomic<bool> gInvertPitch{false};
static std::atomic<bool> gInvertYaw{false};
static std::atomic<int> gAimBone{10};
static std::atomic<int> gAimbotFovPx{300};
static std::atomic<bool> gPredictionEnabled{false};
static std::atomic<float> gAimbotSmooth{0.0f};
static std::atomic<float> gAimOnFireSmooth{0.0f};
static std::atomic<bool> gAimbotVisibleOnly{false};
static std::atomic<bool> gAimbotNoTeam{true};

static std::atomic<bool> gSpeedHackEnabled{false};
static std::atomic<float> gSpeedHackVal{1.0f};
static std::atomic<bool> gJumpHackEnabled{false};
static std::atomic<float> gJumpHackVal{1.0f};

static std::atomic<bool> gRapidFireEnabled{false};
static std::atomic<bool> gInstantReloadEnabled{false};
static std::atomic<bool> gUnlimAmmoEnabled{false};
static std::atomic<bool> gNoSpreadEnabled{false};
static std::atomic<bool> gNoRecoilEnabled{false};

// BALLISTICS
static std::atomic<bool> gAutoNoSpread{true};
static std::atomic<bool> gAutoNoRecoil{true};
static std::atomic<bool> gBallisticsDebug{false};
static std::atomic<bool> gSpreadFloorEnabled{false};
static std::atomic<float> gSpreadFloor{0.0f};

// HUD / VISUALS
static std::atomic<bool> gHeadDotEnabled{true};
static std::atomic<bool> gDistanceEnabled{true};
static std::atomic<bool> gHealthTextEnabled{false};
static std::atomic<bool> gHitMarkerEnabled{true};
static std::atomic<bool> gDamageNumbersEnabled{true};
static std::atomic<bool> gRadarEnabled{false};
static std::atomic<bool> gCrosshairEnabled{false};
static std::atomic<bool> gScopeOverlayEnabled{false};
static std::atomic<bool> gAimLineEnabled{false};
static std::atomic<bool> gTeamColorEnabled{false};
static std::atomic<bool> gVisibleColorEnabled{false};
static std::atomic<bool> gSnapBottomEnabled{false};
static std::atomic<bool> gKillFeedEnabled{true};
static std::atomic<int> gBoxStyle{0};
static std::atomic<float> gSkelThickness{1.5f};
static std::atomic<int> gRadarRange{60};
static std::atomic<float> gRadarSize{120.0f};
static std::atomic<bool> gRadarRotate{true};

static UIColor* gTeamColor = [UIColor cyanColor];
static UIColor* gVisibleColor = [UIColor greenColor];
static UIColor* gHiddenColor = [UIColor redColor];
static UIColor* gHitMarkerColor = [UIColor whiteColor];
static UIColor* gRadarColor = [UIColor greenColor];
static UIColor* gCrosshairColor = [UIColor whiteColor];

struct HudPlayerInfo {
    CGRect box;
    CGPoint head;
    CGPoint feet;
    int health;
    int armor;
    int team;
    bool visible;
    float distance;
};

struct HudDamageInfo {
    CGPoint pos;
    int amount;
    uint64_t until;
};

struct HudKillInfo {
    char name[40];
    uint64_t until;
};

struct HudRadarBlip {
    float x;
    float y;
    int team;
    bool dead;
};

static std::vector<HudPlayerInfo> gHudPlayers;
static std::vector<HudDamageInfo> gHudDamage;
static std::vector<HudKillInfo> gHudKills;
static std::vector<HudRadarBlip> gHudRadar;
static CGPoint gHudAimLineTarget = CGPointMake(0, 0);
static bool gHudAimLineActive = false;
static float gHudCrosshairGap = 6.0f;
static bool gHudCrosshairVisible = false;
static bool gHudScopeActive = false;
static uint64_t gHudHitMarkerUntil = 0;
static int gHudHitMarkerDamage = 0;

// FPS / FRAME-TIME GRAPH
static std::atomic<bool> gFpsEnabled{true};
static std::atomic<int> gFpsValue{0};
static std::atomic<float> gFrameMs{0.0f};
static std::vector<float> gFpsHistory;
static uint64_t gFpsLastSample = 0;
static int gFpsFrames = 0;

// BALLISTICS / HUD FORWARD DECLS
static bool NoSpreadActive(void);
static bool NoRecoilActive(void);
static bool IsRangeWeapon(void* weapon);
static void BallisticsTick(void);
static void BallisticsWeaponTick(void* weapon);
static void BallisticsCameraPre(void* camera);
static void BallisticsCameraPost(void* camera);
static void BallisticsFirePre(void);
static void BallisticsFirePost(void);
static void InstallBallisticsHooks(void);
static void SetupHudView(void);
static void HudTick(void);
static void HudBeginFrame(void);
static void HudAddPlayer(const HudPlayerInfo& info);
static void HudAddDamage(CGPoint pos, int amount, uint64_t until);
static void HudAddKill(const char* name, uint64_t until);
static void HudAddRadar(float x, float y, int team, bool dead);
static void HudSetAimLine(bool active, CGPoint target);
static void HudSetCrosshair(float gap, bool visible);
static void HudSetScope(bool active);
static void HudSampleFrame(void);

static std::atomic<bool> gCamFovEnabled{false};
static std::atomic<bool> gAspectEnabled{false};
static std::atomic<float> gCamFovVal{80.0f};
static std::atomic<float> gAspectVal{1.777f};

static std::atomic<bool> gViewmodelFovEnabled{false};
static std::atomic<float> gViewmodelFovVal{70.0f};

static std::atomic<bool> gNightModeEnabled{false};
static std::atomic<bool> gKillSoundEnabled{true};
static std::atomic<bool> gHitSoundEnabled{true};
static std::atomic<bool> gStreamMode{false};
static std::atomic<bool> gMenuOpen{false};
static std::atomic<bool> gAttached{false};

static std::atomic<bool> gSkyboxEnabled{false};
static std::atomic<uint32_t> gSkyboxColorHex{0xFFFFFFFF};
static std::atomic<bool> gSkyboxDirty{true};

// WORLD VIEW
static std::atomic<bool> gFullbrightEnabled{false};
static std::atomic<float> gFullbrightMul{3.0f};
static std::atomic<bool> gNoFogEnabled{false};
static std::atomic<bool> gAmbientTintEnabled{false};
static std::atomic<uint32_t> gAmbientColorHex{0xFFFFFFFF};
static std::atomic<bool> gWeaponEspEnabled{false};
static UIColor* gWeaponColor = [UIColor yellowColor];
static std::atomic<bool> gGradingDirty{true};
static std::atomic<float> gSaturationVal{0.0f};
static std::atomic<float> gContrastVal{0.0f};
static std::atomic<float> gGammaVal{0.0f};
static std::atomic<float> gBloomVal{0.0f};
static std::atomic<float> gSharpenVal{0.0f};

struct SavedLight {
    float i;
    UnityColor c;
};
static std::unordered_map<void*, SavedLight> gLightOrig;
static bool s_fogOrigInit = false;
static bool s_fogOrig = false;
static bool s_fbWas = false;
static bool s_ambWas = false;
static bool s_nfWas = false;

static void* p_renderSetAmbientLightMI = nullptr;
static void* p_renderGetAmbientLightMI = nullptr;
static UnityColor s_origAmbient{0.5f, 0.5f, 0.5f, 1.0f};
static bool s_origAmbientInit = false;

static std::atomic<bool> gChamsPlayerEnabled{false};
static std::atomic<bool> gChamsWeaponEnabled{false};
static std::atomic<uint32_t> gChamsPlayerColor{0xFF0000FF};
static std::atomic<uint32_t> gChamsWeaponColor{0xFF0000FF};
static std::atomic<int> gChamsPlayerMatType{0};
static std::atomic<int> gChamsWeaponMatType{0};
static std::atomic<bool> gChamsPlayerColorDirty{false};
static std::atomic<bool> gChamsWeaponColorDirty{false};

static std::atomic<uint64_t> g_lastLocalShotMs{0};
static int gLastLocalAmmo = -1;
static uint64_t g_lastHitSoundTime = 0;

static UIColor* gBoxColor = [UIColor redColor];
static UIColor* gSkelColor = [UIColor greenColor];
static UIColor* gNameColor = [UIColor whiteColor];
static UIColor* gTracerColor = [UIColor whiteColor];

static Vec3 g_localEye;
static Vec3 g_targetHead;
static Vec3 g_smoothTarget{};
static Vec3 g_silentAimTarget;
static std::atomic<bool> g_haveTarget{false};
static std::atomic<bool> g_silentAimActive{false};

static void* g_localCC = nullptr;
static void* g_localTransform = nullptr;
static void* g_localSceneChar = nullptr;
static void* g_localChar = nullptr;
static void* g_localCamera = nullptr;
static void* g_localCamTransform = nullptr;
static void* g_localWeapon = nullptr;
static void* g_prevLocalWeapon = nullptr;

static CGSize gScreenPts;
static CGFloat gScreenScale = 1.0;
static float gCurrentFps = 60.0f;

static float g_origMoveSpeed = -1.0f;
static float g_origJumpHeight = -1.0f;
static uint64_t gLastFrameTime = 0;

static void* gSampleMat = nullptr;
static uint32_t gSampleMatHandle = 0;
static void* gChamsMatsPlayer[4] = {nullptr, nullptr, nullptr, nullptr};
static void* gChamsMatsWeapon[4] = {nullptr, nullptr, nullptr, nullptr};

struct SavedMat {
    void* array;
    uint32_t handle;
};

static std::unordered_map<void*, SavedMat> gOrigMats;
static std::unordered_map<void*, SavedMat> gAppliedMats;
static std::unordered_map<void*, int> gLastEnemyHealth;
static std::unordered_map<void*, void*> gWeaponRenderersCache;

static bool gHandsBaseCaptured = false;
static Vec3 gHandsBaseScale(1,1,1);

static uint64_t gLastP = 0;
static uint64_t gLastNight = 0;
static uint64_t gLastWorld = 0;
static std::vector<void*> gCached;
static void* gLocal = nullptr;
static int gTeam = 0;

static inline void* methodPtr(void* mi) {
    return *(void**)(uintptr_t)mi;
}

static void* findClass(const char* ns, const char* name) {
    if (!p_domain_get || !p_domain_get_assemblies || !p_assembly_get_image || !p_class_from_name) {
        return nullptr;
    }
    size_t count = 0;
    void** assemblies = p_domain_get_assemblies(p_domain_get(), &count);
    if (!assemblies) {
        return nullptr;
    }
    
    for (size_t i = 0; i < count; ++i) {
        void* image = p_assembly_get_image(assemblies[i]);
        if (image) {
            void* k = p_class_from_name(image, ns, name);
            if (k) {
                return k;
            }
        }
    }
    return nullptr;
}

static inline bool alive(void* obj) {
    if (!obj || !SANE_PTR(obj)) {
        return false;
    }
    return *(void**)((uintptr_t)obj + off::kObjCachedPtr) != nullptr;
}

static bool getPosFast(void* transform, Vec3& out) {
    if (!alive(transform) || !p_tfGetPos) {
        return false;
    }
    out = p_tfGetPos(transform, p_tfGetPosMI);
    if (!Math::Finite(out)) {
        return false;
    }
    if (out.x == 0 && out.y == 0 && out.z == 0) {
        return false;
    }
    return true;
}

static bool w2sFast(void* camera, Vec3 worldPos, Vec3& out) {
    if (!alive(camera) || !p_camW2S) {
        return false;
    }
    out = p_camW2S(camera, worldPos, p_camW2SMI);
    return Math::Finite(out);
}

static NSString* getIL2CPPString(void* strObj) {
    @try {
        if (!SANE_PTR(strObj)) {
            return nil;
        }
        int len = *(int*)((uintptr_t)strObj + 0x10);
        if (len <= 0 || len > 128) {
            return nil;
        }
        return [[NSString alloc] initWithCharacters:(const unichar*)((uintptr_t)strObj + 0x14) length:len];
    } @catch (NSException* e) {
        return nil;
    }
}

// CONFIG
@interface ConfigManager : NSObject
@end

@implementation ConfigManager

+ (UIColor*)loadColorForKey:(NSString*)key defaultColor:(UIColor*)def {
    NSString* hex = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    if (!hex || hex.length == 0) {
        return def ?: [UIColor whiteColor];
    }
    if ([hex hasPrefix:@"#"]) {
        hex = [hex substringFromIndex:1];
    }
    
    unsigned int r = 255, g = 255, b = 255, a = 255;
    if (hex.length == 8) {
        sscanf([hex UTF8String], "%02x%02x%02x%02x", &r, &g, &b, &a);
    } else if (hex.length == 6) {
        sscanf([hex UTF8String], "%02x%02x%02x", &r, &g, &b);
    } else {
        return def ?: [UIColor whiteColor];
    }
    
    return [UIColor colorWithRed:(r/255.0) green:(g/255.0) blue:(b/255.0) alpha:(a/255.0)];
}

+ (void)saveColor:(UIColor*)color forKey:(NSString*)key {
    if (!color || !key) {
        return;
    }
    CGFloat r, g, b, a;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) {
        NSString* hex = SafeFmt(@"#%02x%02x%02x%02x", (int)(r*255), (int)(g*255), (int)(b*255), (int)(a*255));
        [[NSUserDefaults standardUserDefaults] setObject:hex forKey:key];
    }
}

+ (void)save {
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    [d setBool:gEspEnabled forKey:@"e_e"];
    [d setBool:gSkeletonEnabled forKey:@"e_s"];
    [d setBool:gHealthBarEnabled forKey:@"e_h"];
    [d setBool:gNameEnabled forKey:@"e_n"];
    [d setBool:gTracersEnabled forKey:@"e_t"];
    [d setBool:gOofEnabled forKey:@"e_oof"];
    [d setBool:gAimbotEnabled forKey:@"a_e"];
    [d setBool:gAimOnFireEnabled forKey:@"a_of"];
    [d setInteger:gAimBone forKey:@"a_b"];
    [d setBool:gSilentAimEnabled forKey:@"a_s"];
    [d setBool:gHotAimbotEnabled forKey:@"h_ab"];
    [d setBool:gHotAimOnFireEnabled forKey:@"h_af"];
    [d setBool:gHotEspEnabled forKey:@"h_es"];
    [d setInteger:gAimbotFovPx forKey:@"a_f"];
    [d setBool:gPredictionEnabled forKey:@"a_p"];
    [d setFloat:gAimbotSmooth forKey:@"a_sm"];
    [d setFloat:gAimOnFireSmooth forKey:@"a_of_sm"];
    [d setBool:gAimbotVisibleOnly forKey:@"a_vo"];
    [d setBool:gAimbotNoTeam forKey:@"a_nt"];
    [d setBool:gSpeedHackEnabled forKey:@"m_sh"];
    [d setFloat:gSpeedHackVal forKey:@"m_shv"];
    [d setBool:gJumpHackEnabled forKey:@"m_jh"];
    [d setFloat:gJumpHackVal forKey:@"m_jhv"];
    [d setBool:gKillSoundEnabled forKey:@"s_k"];
    [d setBool:gHitSoundEnabled forKey:@"s_hit"];
    [d setBool:gCamFovEnabled forKey:@"c_f_e"];
    [d setFloat:gCamFovVal forKey:@"c_f_v"];
    [d setBool:gViewmodelFovEnabled forKey:@"c_vm_e"];
    [d setFloat:gViewmodelFovVal forKey:@"c_vm_v"];
    [d setBool:gAspectEnabled forKey:@"c_a_e"];
    [d setFloat:gAspectVal forKey:@"c_a_v"];
    [d setBool:gRapidFireEnabled forKey:@"w_rf"];
    [d setBool:gInstantReloadEnabled forKey:@"w_ir"];
    [d setBool:gUnlimAmmoEnabled forKey:@"w_ua"];
    [d setBool:gNoSpreadEnabled forKey:@"w_ns"];
    [d setBool:gNoRecoilEnabled forKey:@"w_nr"];
    [d setBool:gAutoNoSpread forKey:@"b_ans"];
    [d setBool:gAutoNoRecoil forKey:@"b_anr"];
    [d setBool:gBallisticsDebug forKey:@"b_dbg"];
    [d setBool:gSpreadFloorEnabled forKey:@"b_sfe"];
    [d setFloat:gSpreadFloor forKey:@"b_sf"];
    [d setBool:gHeadDotEnabled forKey:@"h_hd"];
    [d setBool:gDistanceEnabled forKey:@"h_dst"];
    [d setBool:gHealthTextEnabled forKey:@"h_hp"];
    [d setBool:gHitMarkerEnabled forKey:@"h_hm"];
    [d setBool:gDamageNumbersEnabled forKey:@"h_dn"];
    [d setBool:gRadarEnabled forKey:@"h_rad"];
    [d setBool:gCrosshairEnabled forKey:@"h_ch"];
    [d setBool:gScopeOverlayEnabled forKey:@"h_scope"];
    [d setBool:gAimLineEnabled forKey:@"h_al"];
    [d setBool:gTeamColorEnabled forKey:@"h_tc"];
    [d setBool:gVisibleColorEnabled forKey:@"h_vc"];
    [d setBool:gSnapBottomEnabled forKey:@"h_sb"];
    [d setBool:gKillFeedEnabled forKey:@"h_kf"];
    [d setInteger:gBoxStyle forKey:@"h_bs"];
    [d setFloat:gSkelThickness forKey:@"h_st"];
    [d setInteger:gRadarRange forKey:@"h_rr"];
    [d setFloat:gRadarSize forKey:@"h_rs"];
    [d setBool:gRadarRotate forKey:@"h_rrot"];
    [d setBool:gFpsEnabled forKey:@"h_fps"];
    [d setBool:gNightModeEnabled forKey:@"v_nm"];
    [d setBool:gSkyboxEnabled forKey:@"v_sky_e"];
    [d setInteger:(NSInteger)gSkyboxColorHex.load() forKey:@"v_sky_c"];
    [d setBool:gFullbrightEnabled forKey:@"wv_fb"];
    [d setFloat:gFullbrightMul forKey:@"wv_fbm"];
    [d setBool:gNoFogEnabled forKey:@"wv_nf"];
    [d setBool:gAmbientTintEnabled forKey:@"wv_amb_e"];
    [d setInteger:(NSInteger)gAmbientColorHex.load() forKey:@"wv_amb_c"];
    [d setBool:gWeaponEspEnabled forKey:@"wv_we"];
    [d setFloat:gSaturationVal forKey:@"wv_sat"];
    [d setFloat:gContrastVal forKey:@"wv_con"];
    [d setFloat:gGammaVal forKey:@"wv_gam"];
    [d setFloat:gBloomVal forKey:@"wv_bloom"];
    [d setFloat:gSharpenVal forKey:@"wv_sharp"];
    [d setBool:gChamsPlayerEnabled forKey:@"v_chams_pl_e"];
    [d setBool:gChamsWeaponEnabled forKey:@"v_chams_wep_e"];
    [d setInteger:(NSInteger)gChamsPlayerColor.load() forKey:@"v_chams_pl_c"];
    [d setInteger:(NSInteger)gChamsWeaponColor.load() forKey:@"v_chams_wep_c"];
    [d setInteger:gChamsPlayerMatType forKey:@"v_chams_pl_m"];
    [d setInteger:gChamsWeaponMatType forKey:@"v_chams_wep_m"];
    [ConfigManager saveColor:gBoxColor forKey:@"c_b"];
    [ConfigManager saveColor:gSkelColor forKey:@"c_s"];
    [ConfigManager saveColor:gNameColor forKey:@"c_n"];
    [ConfigManager saveColor:gTracerColor forKey:@"c_t"];
    [ConfigManager saveColor:gTeamColor forKey:@"c_team"];
    [ConfigManager saveColor:gVisibleColor forKey:@"c_vis"];
    [ConfigManager saveColor:gHiddenColor forKey:@"c_hid"];
    [ConfigManager saveColor:gHitMarkerColor forKey:@"c_hm"];
    [ConfigManager saveColor:gRadarColor forKey:@"c_radar"];
    [ConfigManager saveColor:gCrosshairColor forKey:@"c_cross"];
    [d synchronize];
}

+ (void)load {
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    gEspEnabled = [d boolForKey:@"e_e"];
    gSkeletonEnabled = [d boolForKey:@"e_s"];
    gHealthBarEnabled = [d boolForKey:@"e_h"];
    gNameEnabled = [d boolForKey:@"e_n"];
    gTracersEnabled = [d boolForKey:@"e_t"];
    gOofEnabled = [d boolForKey:@"e_oof"];
    
    gAimbotEnabled = [d boolForKey:@"a_e"];
    gAimOnFireEnabled = [d boolForKey:@"a_of"];
    gAimBone = (int)[d integerForKey:@"a_b"];
    if (gAimBone != 10 && gAimBone != 8 && gAimBone != 0) {
        gAimBone = 10;
    }
    
    gSilentAimEnabled = false; // Hardcoded disabled
    gHotAimbotEnabled = [d boolForKey:@"h_ab"];
    gHotAimOnFireEnabled = [d boolForKey:@"h_af"];
    gHotEspEnabled = [d boolForKey:@"h_es"];
    gAimbotFovPx = (int)[d integerForKey:@"a_f"];
    if (gAimbotFovPx < 50) {
        gAimbotFovPx = 300;
    }
    
    gPredictionEnabled = [d boolForKey:@"a_p"];
    gAimbotSmooth = [d floatForKey:@"a_sm"];
    gAimOnFireSmooth = Math::Clamp([d floatForKey:@"a_of_sm"], 0.0f, 1.0f);
    gAimbotVisibleOnly = [d boolForKey:@"a_vo"];
    gAimbotNoTeam = [d boolForKey:@"a_nt"];
    
    gSpeedHackEnabled = [d boolForKey:@"m_sh"];
    gSpeedHackVal = [d floatForKey:@"m_shv"];
    if (gSpeedHackVal <= 0) {
        gSpeedHackVal = 1.0f;
    }
    
    gJumpHackEnabled = [d boolForKey:@"m_jh"];
    gJumpHackVal = [d floatForKey:@"m_jhv"];
    if (gJumpHackVal <= 0) {
        gJumpHackVal = 1.0f;
    }
    
    if ([d objectForKey:@"s_k"]) {
        gKillSoundEnabled = [d boolForKey:@"s_k"];
    }
    if ([d objectForKey:@"s_hit"]) {
        gHitSoundEnabled = [d boolForKey:@"s_hit"];
    }
    
    gCamFovEnabled = [d boolForKey:@"c_f_e"];
    gCamFovVal = [d floatForKey:@"c_f_v"];
    if (!std::isfinite(gCamFovVal) || gCamFovVal <= 0) {
        gCamFovVal = 80.0f;
    }
    
    gViewmodelFovEnabled = [d boolForKey:@"c_vm_e"];
    gViewmodelFovVal = [d floatForKey:@"c_vm_v"];
    if (!std::isfinite(gViewmodelFovVal) || gViewmodelFovVal <= 0) {
        gViewmodelFovVal = 70.0f;
    }
    
    gAspectEnabled = [d boolForKey:@"c_a_e"];
    gAspectVal = [d floatForKey:@"c_a_v"];
    if (!std::isfinite(gAspectVal) || gAspectVal <= 0) {
        gAspectVal = 1.777f;
    }
    
    gRapidFireEnabled = [d boolForKey:@"w_rf"];
    gInstantReloadEnabled = [d boolForKey:@"w_ir"];
    gUnlimAmmoEnabled = [d boolForKey:@"w_ua"];
    gNoSpreadEnabled = [d boolForKey:@"w_ns"];
    gNoRecoilEnabled = [d boolForKey:@"w_nr"];
    gAutoNoSpread = [d objectForKey:@"b_ans"] ? [d boolForKey:@"b_ans"] : true;
    gAutoNoRecoil = [d objectForKey:@"b_anr"] ? [d boolForKey:@"b_anr"] : true;
    gBallisticsDebug = [d boolForKey:@"b_dbg"];
    gSpreadFloorEnabled = [d boolForKey:@"b_sfe"];
    gSpreadFloor = Math::Clamp([d floatForKey:@"b_sf"], 0.0f, 0.05f);
    gHeadDotEnabled = [d objectForKey:@"h_hd"] ? [d boolForKey:@"h_hd"] : true;
    gDistanceEnabled = [d objectForKey:@"h_dst"] ? [d boolForKey:@"h_dst"] : true;
    gHealthTextEnabled = [d boolForKey:@"h_hp"];
    gHitMarkerEnabled = [d objectForKey:@"h_hm"] ? [d boolForKey:@"h_hm"] : true;
    gDamageNumbersEnabled = [d objectForKey:@"h_dn"] ? [d boolForKey:@"h_dn"] : true;
    gRadarEnabled = [d boolForKey:@"h_rad"];
    gCrosshairEnabled = [d boolForKey:@"h_ch"];
    gScopeOverlayEnabled = [d boolForKey:@"h_scope"];
    gAimLineEnabled = [d boolForKey:@"h_al"];
    gTeamColorEnabled = [d objectForKey:@"h_tc"] ? [d boolForKey:@"h_tc"] : false;
    gVisibleColorEnabled = [d objectForKey:@"h_vc"] ? [d boolForKey:@"h_vc"] : false;
    gSnapBottomEnabled = [d boolForKey:@"h_sb"];
    gKillFeedEnabled = [d objectForKey:@"h_kf"] ? [d boolForKey:@"h_kf"] : true;
    gBoxStyle = (int)[d integerForKey:@"h_bs"];
    gSkelThickness = Math::Clamp([d floatForKey:@"h_st"], 0.5f, 4.0f);
    gRadarRange = (int)[d integerForKey:@"h_rr"];
    if (gRadarRange < 20) {
        gRadarRange = 60;
    }
    gRadarSize = Math::Clamp([d floatForKey:@"h_rs"], 70.0f, 220.0f);
    gRadarRotate = [d objectForKey:@"h_rrot"] ? [d boolForKey:@"h_rrot"] : true;
    gFpsEnabled = [d objectForKey:@"h_fps"] ? [d boolForKey:@"h_fps"] : true;
    
    gNightModeEnabled = [d boolForKey:@"v_nm"];
    gSkyboxEnabled = [d boolForKey:@"v_sky_e"];
    gSkyboxColorHex = (uint32_t)[d integerForKey:@"v_sky_c"];
    if (gSkyboxColorHex == 0) {
        gSkyboxColorHex = 0xFFFFFFFF;
    }
    gSkyboxDirty = true;
    
    gFullbrightEnabled = [d boolForKey:@"wv_fb"];
    gFullbrightMul = [d floatForKey:@"wv_fbm"];
    if (gFullbrightMul < 1.0f) {
        gFullbrightMul = 3.0f;
    }
    gNoFogEnabled = [d boolForKey:@"wv_nf"];
    gAmbientTintEnabled = [d boolForKey:@"wv_amb_e"];
    gAmbientColorHex = (uint32_t)[d integerForKey:@"wv_amb_c"];
    if (gAmbientColorHex == 0) {
        gAmbientColorHex = 0xFFFFFFFF;
    }
    gWeaponEspEnabled = [d boolForKey:@"wv_we"];
    gSaturationVal = [d floatForKey:@"wv_sat"];
    gContrastVal = [d floatForKey:@"wv_con"];
    gGammaVal = [d floatForKey:@"wv_gam"];
    gBloomVal = [d floatForKey:@"wv_bloom"];
    gSharpenVal = [d floatForKey:@"wv_sharp"];
    gGradingDirty = true;
    
    gChamsPlayerEnabled = [d boolForKey:@"v_chams_pl_e"];
    gChamsWeaponEnabled = [d boolForKey:@"v_chams_wep_e"];
    gChamsPlayerColor = (uint32_t)[d integerForKey:@"v_chams_pl_c"];
    gChamsWeaponColor = (uint32_t)[d integerForKey:@"v_chams_wep_c"];
    
    if (gChamsPlayerColor == 0) {
        gChamsPlayerColor = 0xFF0000FF;
    }
    if (gChamsWeaponColor == 0) {
        gChamsWeaponColor = 0xFF0000FF;
    }
    
    gChamsPlayerMatType = (int)[d integerForKey:@"v_chams_pl_m"];
    gChamsWeaponMatType = (int)[d integerForKey:@"v_chams_wep_m"];
    if (gChamsPlayerMatType < 0 || gChamsPlayerMatType > 3) {
        gChamsPlayerMatType = 0;
    }
    if (gChamsWeaponMatType < 0 || gChamsWeaponMatType > 3) {
        gChamsWeaponMatType = 0;
    }
    
    gBoxColor = [ConfigManager loadColorForKey:@"c_b" defaultColor:[UIColor redColor]];
    gSkelColor = [ConfigManager loadColorForKey:@"c_s" defaultColor:[UIColor greenColor]];
    gNameColor = [ConfigManager loadColorForKey:@"c_n" defaultColor:[UIColor whiteColor]];
    gTracerColor = [ConfigManager loadColorForKey:@"c_t" defaultColor:[UIColor whiteColor]];
    gTeamColor = [ConfigManager loadColorForKey:@"c_team" defaultColor:[UIColor cyanColor]];
    gVisibleColor = [ConfigManager loadColorForKey:@"c_vis" defaultColor:[UIColor greenColor]];
    gHiddenColor = [ConfigManager loadColorForKey:@"c_hid" defaultColor:[UIColor redColor]];
    gHitMarkerColor = [ConfigManager loadColorForKey:@"c_hm" defaultColor:[UIColor whiteColor]];
    gRadarColor = [ConfigManager loadColorForKey:@"c_radar" defaultColor:[UIColor greenColor]];
    gCrosshairColor = [ConfigManager loadColorForKey:@"c_cross" defaultColor:[UIColor whiteColor]];
}

@end

// HOOKS
static bool hook_install(void* mi, void* hook, void** orig) {
    if (!mi || !hook) {
        return false;
    }
    
    void** slot = (void**)((uintptr_t)mi + 0x0);
    void* old = *slot;
    if (!old) {
        return false;
    }
    
    long ps = sysconf(_SC_PAGESIZE);
    vm_address_t start = (vm_address_t)slot & ~((vm_address_t)ps - 1);
    vm_address_t end = ((vm_address_t)slot + sizeof(void*) + ps - 1) & ~((vm_address_t)ps - 1);
    
    if (vm_protect(mach_task_self(), start, end - start, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
        return false;
    }
    
    *slot = hook;
    if (orig) {
        *orig = old;
    }
    
    return true;
}

typedef void (*fn_CamLateUpdate)(void* self, void* mi);
static fn_CamLateUpdate orig_CamLateUpdate = nullptr;

typedef void (*fn_UiOnClickFireDown)(void* self, void* mi);
static fn_UiOnClickFireDown orig_UiOnClickFireDown = nullptr;

static void ApplyAimOnFire(void) {
    if (!gAimOnFireEnabled && !gHotAimOnFireEnabled || !g_haveTarget || !p_lookAtTarget) {
        return;
    }

    void* sceneCamera = g_localSceneChar;
    if (!alive(sceneCamera)) {
        return;
    }

    if (*(bool*)((uintptr_t)sceneCamera + off::kCamIsDisable)) {
        return;
    }

    if (*(bool*)((uintptr_t)sceneCamera + off::kCamIsBusy)) {
        return;
    }

    if (gAimOnFireSmooth.load() <= 0.0f) {
        p_lookAtTarget(sceneCamera, g_targetHead, p_lookAtTargetMI);
    }
}

static void ApplyCameraOverrides(void* self) {
    if (!alive(self) || self != g_localSceneChar) {
        return;
    }

    void* camera = *(void**)((uintptr_t)self + off::kCamComponent);
    if (!alive(camera)) {
        return;
    }

    g_localCamera = camera;

    if (gStreamMode) {
        if (p_camSetAspect && gScreenPts.height > 0.0f) {
            float defaultAspect = gScreenPts.width / gScreenPts.height;
            if (std::isfinite(defaultAspect) && defaultAspect > 0.0f) {
                p_camSetAspect(camera, defaultAspect, p_camSetAspectMI);
            }
        }
    } else if (gAspectEnabled && p_camSetAspect) {
        float aspect = gAspectVal.load();
        if (std::isfinite(aspect) && aspect >= 0.5f && aspect <= 2.5f) {
            p_camSetAspect(camera, aspect, p_camSetAspectMI);
        }
    }

    if (gCamFovEnabled) {
        float fieldOfView = gCamFovVal.load();
        if (!std::isfinite(fieldOfView)) {
            return;
        }

        fieldOfView = Math::Clamp(fieldOfView, 30.0f, 140.0f);
        if (p_sceneSetFov) {
            p_sceneSetFov(self, fieldOfView, p_sceneSetFovMI);
        } else if (p_camSetFov) {
            p_camSetFov(camera, fieldOfView, p_camSetFovMI);
        }
    }
}

static void ApplyViewmodelFov(void* self) {
    if (!alive(self)) {
        return;
    }
    
    void* hands = *(void**)((uintptr_t)self + off::kCamHands);
    if (!alive(hands) || !p_getTransform) {
        return;
    }
    
    void* ht = p_getTransform(hands, p_getTransformMI);
    if (!alive(ht)) {
        return;
    }
    
    if (gViewmodelFovEnabled && p_tfSetLocalScale && p_tfGetLocalScale && p_camGetFov && g_localCamera) {
        if (!gHandsBaseCaptured) {
            gHandsBaseScale = p_tfGetLocalScale(ht, p_tfGetLocalScaleMI);
            if (!Math::Finite(gHandsBaseScale)) {
                gHandsBaseScale = Vec3(1, 1, 1);
            }
            gHandsBaseCaptured = true;
        }
        
        float camFov = p_camGetFov(g_localCamera, p_camGetFovMI);
        float vmFov = gViewmodelFovVal.load();
        
        if (!std::isfinite(camFov) || camFov < 5.0f) {
            camFov = 70.0f;
        }
        if (!std::isfinite(vmFov) || vmFov < 5.0f) {
            vmFov = 70.0f;
        }
        if (camFov > 170.0f) {
            camFov = 170.0f;
        }
        if (vmFov > 170.0f) {
            vmFov = 170.0f;
        }
        
        float factor = tanf(vmFov * Math::DEG2RAD * 0.5f) / tanf(camFov * Math::DEG2RAD * 0.5f);
        if (!std::isfinite(factor)) {
            factor = 1.0f;
        }
        factor = Math::Clamp(factor, 0.15f, 6.0f);
        
        Vec3 ns(gHandsBaseScale.x * factor, gHandsBaseScale.y * factor, gHandsBaseScale.z * factor);
        p_tfSetLocalScale(ht, ns, p_tfSetLocalScaleMI);
    }
}

static void hook_CamLateUpdate(void* self, void* mi) {
    if (SANE_PTR(self) && self == g_localSceneChar) {
        BallisticsCameraPre(self);
    }
    
    if (orig_CamLateUpdate) {
        orig_CamLateUpdate(self, mi);
    }
    
    if (!SANE_PTR(self) || self != g_localSceneChar) {
        return;
    }
    
    // LateUpdate runs after weapon Update — keep spread/recoil at 0 for the next shot
    if (g_localWeapon && SANE_PTR(g_localWeapon)) {
        BallisticsWeaponTick(g_localWeapon);
    }
    BallisticsTick();
    BallisticsCameraPost(self);
    
    ApplyCameraOverrides(self);
    
    ApplyViewmodelFov(self);
    
    if (*(bool*)((uintptr_t)self + off::kCamIsDisable) || *(bool*)((uintptr_t)self + off::kCamIsBusy)) {
        return;
    }
    
    const bool aimbotActive = gAimbotEnabled || gHotAimbotEnabled;
    const bool aimOnFireActive = gAimOnFireEnabled || gHotAimOnFireEnabled;
    if ((!aimbotActive && !aimOnFireActive) || gSilentAimEnabled || !g_haveTarget) {
        return;
    }
    
    if (p_lookAtTarget) {
        Vec3 aimPoint = g_targetHead;
        const float s = aimbotActive ? gAimbotSmooth.load() : gAimOnFireSmooth.load();
        if (s > 0.0f) {
            Vec3 diff = aimPoint - g_smoothTarget;
            g_smoothTarget = g_smoothTarget + diff * s;
            aimPoint = g_smoothTarget;
        }
        p_lookAtTarget(self, aimPoint, p_lookAtTargetMI);
    }
}

static void hook_UiOnClickFireDown(void* self, void* mi) {
    ApplyAimOnFire();
    BallisticsFirePre();

    if (orig_UiOnClickFireDown) {
        orig_UiOnClickFireDown(self, mi);
    }
    
    BallisticsFirePost();
}

typedef void (*fn_UiOnClickFire)(void* self, void* mi);
static fn_UiOnClickFire orig_UiOnClickFire = nullptr;

static void hook_UiOnClickFire(void* self, void* mi) {
    ApplyAimOnFire();
    BallisticsFirePre();

    if (orig_UiOnClickFire) {
        orig_UiOnClickFire(self, mi);
    }
    
    BallisticsFirePost();
}

typedef void (*fn_WepUpdate)(void* self, void* mi);
static fn_WepUpdate orig_WepUpdate = nullptr;
static fn_WepUpdate orig_WepUpdateShotgun = nullptr;

static void hook_WepUpdateShotgun(void* self, void* mi) {
    if (orig_WepUpdateShotgun) {
        orig_WepUpdateShotgun(self, mi);
    }
    if (!SANE_PTR(self)) {
        return;
    }
    BallisticsWeaponTick(self);
}

static void hook_WepUpdate(void* self, void* mi) {
    if (orig_WepUpdate) {
        orig_WepUpdate(self, mi);
    }
    if (!SANE_PTR(self)) {
        return;
    }
    
    if (gRapidFireEnabled) {
        *(float*)((uintptr_t)self + off::kWepLastShotTime) = 0.0f;
        *(float*)((uintptr_t)self + off::kEquipCoolTime) = 0.0f;
    }
    
    if (gInstantReloadEnabled) {
        bool* isReload = (bool*)((uintptr_t)self + off::kWepIsReload);
        if (*isReload) {
            *isReload = false;
            void* equipData = *(void**)((uintptr_t)self + off::kEquipData);
            int magCap = 30;
            if (SANE_PTR(equipData)) {
                int cap = *(int*)((uintptr_t)equipData + off::kDataAmmo);
                if (cap > 0 && cap < 1000) {
                    magCap = cap;
                }
            }
            *(int*)((uintptr_t)self + off::kWepAmmo) = magCap;
        }
    }
    
    if (gUnlimAmmoEnabled) {
        *(int*)((uintptr_t)self + off::kWepAmmoTotal) = 9999;
    }
    
    BallisticsWeaponTick(self);
}

typedef void (*fn_MoveUpdate)(void* self, void* mi);
static fn_MoveUpdate orig_MoveUpdate = nullptr;

static void hook_MoveUpdate(void* self, void* mi) {
    if (orig_MoveUpdate) {
        orig_MoveUpdate(self, mi);
    }
    if (!SANE_PTR(self)) {
        return;
    }
    
    if (g_origMoveSpeed < 0) {
        g_origMoveSpeed = *(float*)((uintptr_t)self + off::kMoveSpeed);
    }
    if (g_origJumpHeight < 0) {
        g_origJumpHeight = *(float*)((uintptr_t)self + off::kMoveJumpH);
    }
    
    if (gSpeedHackEnabled) {
        *(float*)((uintptr_t)self + off::kMoveSpeed) = g_origMoveSpeed * gSpeedHackVal;
    } else {
        *(float*)((uintptr_t)self + off::kMoveSpeed) = g_origMoveSpeed;
    }
    
    if (gJumpHackEnabled) {
        *(float*)((uintptr_t)self + off::kMoveJumpH) = g_origJumpHeight * gJumpHackVal;
    } else {
        *(float*)((uintptr_t)self + off::kMoveJumpH) = g_origJumpHeight;
    }
}

static void InstallAllHooks(void) {
    @try {
        void* wepCls = findClass("", "ItemEquipWeaponRange");
        void* moveCls = findClass("", "SceneLevelCharacterMovementLocal");
        void* sceneCamCls = findClass("", "SceneLevelCamera");
        void* mobileInputsCls = findClass("", "SceneLevelUiMobileInputs");
        
        if (sceneCamCls) {
            void* mi = p_class_get_method_from_name(sceneCamCls, "LateUpdate", 0);
            if (mi) {
                hook_install(mi, (void*)hook_CamLateUpdate, (void**)&orig_CamLateUpdate);
            }
        }
        
        if (mobileInputsCls) {
            void* mi = p_class_get_method_from_name(mobileInputsCls, "OnClickFireDown", 0);
            if (mi) {
                hook_install(mi, (void*)hook_UiOnClickFireDown, (void**)&orig_UiOnClickFireDown);
            }
            void* miFire = p_class_get_method_from_name(mobileInputsCls, "OnClickFire", 0);
            if (miFire) {
                hook_install(miFire, (void*)hook_UiOnClickFire, (void**)&orig_UiOnClickFire);
            }
        }

        if (wepCls) {
            void* mi = p_class_get_method_from_name(wepCls, "Update", 0);
            if (mi) {
                hook_install(mi, (void*)hook_WepUpdate, (void**)&orig_WepUpdate);
            }
        }
        
        void* shotgunCls = findClass("", "ItemEquipWeaponRangeShotgun");
        if (shotgunCls) {
            void* mi = p_class_get_method_from_name(shotgunCls, "Update", 0);
            if (mi) {
                hook_install(mi, (void*)hook_WepUpdateShotgun, (void**)&orig_WepUpdateShotgun);
            }
        }
        
        InstallBallisticsHooks();
        
        if (moveCls) {
            void* mi = p_class_get_method_from_name(moveCls, "Update", 0);
            if (mi) {
                hook_install(mi, (void*)hook_MoveUpdate, (void**)&orig_MoveUpdate);
            }
        }
    } @catch (NSException* e) {
        LOG(@"Hooks: %@", SafeStr([e reason]));
    }
}

// CHAMS
static void EnsureMaterialCtorMI(void) {
    if (p_matCopyCtorMI || !gMatCls || !p_class_get_methods) {
        return;
    }
    
    void* iter = nullptr;
    while (void* mi = p_class_get_methods(gMatCls, &iter)) {
        if (!p_method_get_name) {
            continue;
        }
        const char* name = p_method_get_name(mi);
        if (!name || strcmp(name, ".ctor") != 0) {
            continue;
        }
        if (p_method_get_param_count && p_method_get_param_count(mi) != 1) {
            continue;
        }
        if (p_method_get_param && p_type_get_name) {
            void* t = p_method_get_param(mi, 0);
            if (!t) {
                continue;
            }
            char* tn = p_type_get_name(t);
            if (tn && strstr(tn, "Material")) {
                p_matCopyCtorMI = mi;
                return;
            }
        }
    }
}

static void* CreateChamsMaterial(void* source, int type, uint32_t hexColor) {
    if (!p_object_new || !gMatCls || !p_runtime_invoke) {
        return nullptr;
    }
    
    EnsureMaterialCtorMI();
    if (!p_matCopyCtorMI) {
        return nullptr;
    }
    
    void* newMat = p_object_new(gMatCls);
    if (!newMat) {
        return nullptr;
    }
    
    void* args[1] = { source };
    void* exc = nullptr;
    p_runtime_invoke(p_matCopyCtorMI, newMat, args, &exc);
    
    if (exc) {
        return nullptr;
    }
    
    float r = ((hexColor >> 24) & 0xFF) / 255.0f;
    float g = ((hexColor >> 16) & 0xFF) / 255.0f;
    float b = ((hexColor >> 8) & 0xFF) / 255.0f;
    float a = (hexColor & 0xFF) / 255.0f;
    
    void* strColor = p_string_new("_Color");
    void* strBaseColor = p_string_new("_BaseColor");
    
    if (p_matSetColor) {
        UnityColor col(r, g, b, (type == 1 || type == 3) ? a : 1.0f);
        if (strColor) {
            p_matSetColor(newMat, strColor, col, p_matSetColorMI);
        }
        if (strBaseColor) {
            p_matSetColor(newMat, strBaseColor, col, p_matSetColorMI);
        }
        
        void* strEmission = p_string_new("_EmissionColor");
        if (type == 2) {
            UnityColor emis(r * 1.5f, g * 1.5f, b * 1.5f, 1.0f);
            if (strEmission) {
                p_matSetColor(newMat, strEmission, emis, p_matSetColorMI);
            }
        } else {
            UnityColor zero(0, 0, 0, 0);
            if (strEmission) {
                p_matSetColor(newMat, strEmission, zero, p_matSetColorMI);
            }
        }
    }
    
    if (p_matSetTexture) {
        void* strMainTex = p_string_new("_MainTex");
        if (strMainTex) {
            p_matSetTexture(newMat, strMainTex, nullptr, p_matSetTextureMI);
        }
        void* strBaseMap = p_string_new("_BaseMap");
        if (strBaseMap) {
            p_matSetTexture(newMat, strBaseMap, nullptr, p_matSetTextureMI);
        }
    }
    
    // per-type render state
    if (p_matSetFloat) {
        void* strZWrite = p_string_new("_ZWrite");
        if (strZWrite && (type == 1 || type == 3)) {
            p_matSetFloat(newMat, strZWrite, 0.0f, p_matSetFloatMI);
        }
    }
    
    if (p_matEnableKeyword) {
        void* strEmis = p_string_new("_EMISSION");
        if (strEmis && type == 2) {
            p_matEnableKeyword(newMat, strEmis, p_matEnableKeywordMI);
        }
    }
    
    if (p_matSetInt) {
        // X-Ray: try to force ZTest Always (8) — works on shaders exposing _ZTest,
        // no-op SetFloat/SetInt on missing props, safe to attempt
        void* strZTest = p_string_new("_ZTest");
        void* strStencilComp = p_string_new("_StencilComp");
        if (type == 3) {
            if (strZTest) {
                p_matSetInt(newMat, strZTest, 8, p_matSetIntMI);
            }
            if (strStencilComp) {
                p_matSetInt(newMat, strStencilComp, 8, p_matSetIntMI);
            }
        }
    }
    
    if (p_matSetRQ) {
        // Glass/X-Ray -> transparent+overlay range so they draw after opaque geometry
        if (type == 1) {
            p_matSetRQ(newMat, 3000, p_matSetRQMI);
        } else if (type == 2 || type == 3) {
            p_matSetRQ(newMat, 4000, p_matSetRQMI);
        }
    }
    
    return newMat;
}

static void* GetSampleMaterial(void) {
    if (gSampleMat) {
        return gSampleMat;
    }
    
    for (void* p : gCached) {
        if (!alive(p) || p == gLocal) {
            continue;
        }
        
        void* c = *(void**)((uintptr_t)p + off::kPlayerCharacter);
        if (!alive(c)) {
            continue;
        }
        
        void* ct = *(void**)((uintptr_t)c + off::kCharController);
        if (!alive(ct)) {
            continue;
        }
        
        void* rv = *(void**)((uintptr_t)ct + off::kOtherRemoteVis);
        if (!alive(rv)) {
            continue;
        }
        
        void* renderArrays[3] = {
            *(void**)((uintptr_t)rv + 0x60),
            *(void**)((uintptr_t)rv + 0x78),
            *(void**)((uintptr_t)rv + 0x98)
        };
        
        for (int ai = 0; ai < 3; ai++) {
            void* arr = renderArrays[ai];
            if (!SANE_PTR(arr)) {
                continue;
            }
            
            int len = *(int*)((uintptr_t)arr + 0x18);
            if (len <= 0) {
                continue;
            }
            
            for (int i = 0; i < len && i < 32; i++) {
                void* rend = *(void**)((uintptr_t)arr + 0x20 + i * 8);
                if (!alive(rend)) {
                    continue;
                }
                
                void* mats = p_rendGetSharedMats(rend, p_rendGetSharedMatsMI);
                if (!SANE_PTR(mats)) {
                    continue;
                }
                
                int mlen = *(int*)((uintptr_t)mats + 0x18);
                if (mlen <= 0) {
                    continue;
                }
                
                void* mat = *(void**)((uintptr_t)mats + 0x20);
                if (alive(mat)) {
                    gSampleMat = mat;
                    if (p_gchandle_new) {
                        gSampleMatHandle = p_gchandle_new(mat, true);
                    }
                    return mat;
                }
            }
        }
    }
    return nullptr;
}

static void EnsureChamsMaterials(void) {
    if (!gMatCls) {
        return;
    }
    
    EnsureMaterialCtorMI();
    if (!p_matCopyCtorMI) {
        return;
    }
    
    bool needP = !gChamsMatsPlayer[0] || !gChamsMatsPlayer[1] || !gChamsMatsPlayer[2] || !gChamsMatsPlayer[3];
    bool needW = !gChamsMatsWeapon[0] || !gChamsMatsWeapon[1] || !gChamsMatsWeapon[2] || !gChamsMatsWeapon[3];
    
    if (!needP && !needW) {
        return;
    }
    
    void* sample = GetSampleMaterial();
    if (!sample) {
        return;
    }
    
    uint32_t pc = gChamsPlayerColor.load();
    uint32_t wc = gChamsWeaponColor.load();
    
    for (int i = 0; i < 4; i++) {
        if (!gChamsMatsPlayer[i]) {
            gChamsMatsPlayer[i] = CreateChamsMaterial(sample, i, pc);
        }
        if (!gChamsMatsWeapon[i]) {
            gChamsMatsWeapon[i] = CreateChamsMaterial(sample, i, wc);
        }
    }
}

static void ApplyChamsToRenderer(void* rend, void* chamsMat) {
    if (!alive(rend) || !chamsMat || !p_rendGetSharedMats || !p_rendSetSharedMats) {
        return;
    }
    
    void* orig = p_rendGetSharedMats(rend, p_rendGetSharedMatsMI);
    if (SANE_PTR(orig)) {
        int n = *(int*)((uintptr_t)orig + 0x18);
        if (n > 0 && *(void**)((uintptr_t)orig + 0x20) == chamsMat) {
            return;
        }
    }
    
    if (gOrigMats.find(rend) == gOrigMats.end()) {
        if (SANE_PTR(orig) && p_gchandle_new) {
            uint32_t h = p_gchandle_new(orig, true);
            SavedMat saved;
            saved.array = orig;
            saved.handle = h;
            gOrigMats[rend] = saved;
        }
    }
    
    int n = SANE_PTR(orig) ? *(int*)((uintptr_t)orig + 0x18) : 1;
    if (n <= 0) {
        n = 1;
    }
    if (n > 32) {
        n = 32;
    }
    
    void* arr = nullptr;
    auto it = gAppliedMats.find(rend);
    if (it != gAppliedMats.end()) {
        arr = it->second.array;
    }
    
    if (!arr) {
        arr = p_array_new(gMatCls, (size_t)n);
        if (!arr) {
            return;
        }
        
        SavedMat saved;
        saved.array = arr;
        saved.handle = p_gchandle_new ? p_gchandle_new(arr, true) : 0;
        gAppliedMats[rend] = saved;
    }
    
    for (int i = 0; i < n; i++) {
        *(void**)((uintptr_t)arr + 0x20 + i * 8) = chamsMat;
    }
    
    p_rendSetSharedMats(rend, arr, p_rendSetSharedMatsMI);
}

static void* GetWeaponRenderersCached(void* obj) {
    if (!alive(obj)) {
        return nullptr;
    }
    
    auto it = gWeaponRenderersCache.find(obj);
    if (it != gWeaponRenderersCache.end()) {
        return it->second;
    }
    
    if (!p_getCompsInChildrenMI || !gRendererCls) {
        return nullptr;
    }
    
    void* rendTypeObj = p_type_get_object(p_class_get_type(gRendererCls));
    void* exc = nullptr;
    void* rArr = nullptr;
    
    if (p_method_get_param_count && p_method_get_param_count(p_getCompsInChildrenMI) == 2) {
        bool includeInactive = true;
        void* args[2] = { rendTypeObj, &includeInactive };
        rArr = p_runtime_invoke(p_getCompsInChildrenMI, obj, args, &exc);
    } else {
        void* args[1] = { rendTypeObj };
        rArr = p_runtime_invoke(p_getCompsInChildrenMI, obj, args, &exc);
    }
    
    if (rArr && !exc) {
        if (p_gchandle_new) {
            p_gchandle_new(rArr, true);
        }
        gWeaponRenderersCache[obj] = rArr;
        return rArr;
    }
    
    return nullptr;
}

static void UpdateChamsForPlayer(void* player, void* charCtrl) {
    void* rv = *(void**)((uintptr_t)charCtrl + off::kOtherRemoteVis);
    if (!alive(rv)) {
        return;
    }
    
    int playerType = gChamsPlayerMatType.load();
    int weaponType = gChamsWeaponMatType.load();
    bool pEnabled = gChamsPlayerEnabled.load();
    bool wEnabled = gChamsWeaponEnabled.load();
    
    if (!pEnabled && !wEnabled) {
        return;
    }
    
    if (pEnabled && gChamsMatsPlayer[playerType]) {
        void* renderArrays[3] = {
            *(void**)((uintptr_t)rv + 0x60),
            *(void**)((uintptr_t)rv + 0x78),
            *(void**)((uintptr_t)rv + 0x98)
        };
        
        for (int ai = 0; ai < 3; ai++) {
            void* arr = renderArrays[ai];
            if (!SANE_PTR(arr)) {
                continue;
            }
            
            int len = *(int*)((uintptr_t)arr + 0x18);
            if (len <= 0 || len > 32) {
                continue;
            }
            
            for (int i = 0; i < len; i++) {
                void* rend = *(void**)((uintptr_t)arr + 0x20 + i * 8);
                if (alive(rend)) {
                    ApplyChamsToRenderer(rend, gChamsMatsPlayer[playerType]);
                }
            }
        }
    }
    
    if (wEnabled && gChamsMatsWeapon[weaponType]) {
        void* itemView = *(void**)((uintptr_t)rv + off::kRvItemView);
        if (alive(itemView)) {
            void* itemModel = *(void**)((uintptr_t)itemView + 0x38);
            if (alive(itemModel)) {
                void* weaponGO = *(void**)((uintptr_t)itemModel + 0x28);
                if (alive(weaponGO)) {
                    void* rArr = GetWeaponRenderersCached(weaponGO);
                    if (rArr) {
                        int rLen = *(int*)((uintptr_t)rArr + 0x18);
                        for (int ri = 0; ri < rLen; ri++) {
                            void* rend = *(void**)((uintptr_t)rArr + 0x20 + ri * 8);
                            if (alive(rend)) {
                                ApplyChamsToRenderer(rend, gChamsMatsWeapon[weaponType]);
                            }
                        }
                    }
                }
            }
        }
    }
}

static void UpdateLocalChams() {
    if (!gChamsWeaponEnabled) {
        return;
    }
    
    if (gStreamMode) {
        return;
    }
    
    int weaponType = gChamsWeaponMatType.load();
    if (!gChamsMatsWeapon[weaponType]) {
        return;
    }
    
    if (alive(g_localWeapon) && p_getGameObject && p_getGameObjectMI) {
        void* go = p_getGameObject(g_localWeapon, p_getGameObjectMI);
        if (alive(go)) {
            void* rArr = GetWeaponRenderersCached(go);
            if (rArr) {
                int rLen = *(int*)((uintptr_t)rArr + 0x18);
                for (int ri = 0; ri < rLen; ri++) {
                    void* rend = *(void**)((uintptr_t)rArr + 0x20 + ri * 8);
                    if (alive(rend)) {
                        ApplyChamsToRenderer(rend, gChamsMatsWeapon[weaponType]);
                    }
                }
            }
        }
    }
    
    if (alive(g_localSceneChar)) {
        void* hands = *(void**)((uintptr_t)g_localSceneChar + off::kCamHands);
        if (alive(hands) && p_getTransform && p_getGameObject) {
            void* ht = p_getTransform(hands, p_getTransformMI);
            if (alive(ht)) {
                void* hgo = p_getGameObject(ht, p_getGameObjectMI);
                if (alive(hgo)) {
                    void* rArr = GetWeaponRenderersCached(hgo);
                    if (rArr) {
                        int rLen = *(int*)((uintptr_t)rArr + 0x18);
                        for (int ri = 0; ri < rLen; ri++) {
                            void* rend = *(void**)((uintptr_t)rArr + 0x20 + ri * 8);
                            if (alive(rend)) {
                                ApplyChamsToRenderer(rend, gChamsMatsWeapon[weaponType]);
                            }
                        }
                    }
                }
            }
        }
    }
}

static void RestoreAllChams() {
    for (auto& pair : gOrigMats) {
        void* rend = pair.first;
        SavedMat& saved = pair.second;
        
        if (alive(rend) && alive(saved.array) && p_rendSetSharedMats) {
            p_rendSetSharedMats(rend, saved.array, p_rendSetSharedMatsMI);
        }
        if (saved.handle && p_gchandle_free) {
            p_gchandle_free(saved.handle);
        }
    }
    
    gOrigMats.clear();
    gWeaponRenderersCache.clear();
    
    for (auto& pair : gAppliedMats) {
        if (pair.second.handle && p_gchandle_free) {
            p_gchandle_free(pair.second.handle);
        }
    }
    gAppliedMats.clear();
}

static void CleanupDeadRenderers() {
    for (auto it = gOrigMats.begin(); it != gOrigMats.end(); ) {
        if (!alive(it->first)) {
            if (it->second.handle && p_gchandle_free) {
                p_gchandle_free(it->second.handle);
            }
            it = gOrigMats.erase(it);
        } else {
            ++it;
        }
    }
    
    for (auto it = gWeaponRenderersCache.begin(); it != gWeaponRenderersCache.end(); ) {
        if (!alive(it->first)) {
            it = gWeaponRenderersCache.erase(it);
        } else {
            ++it;
        }
    }
    
    for (auto it = gAppliedMats.begin(); it != gAppliedMats.end(); ) {
        if (!alive(it->first)) {
            if (it->second.handle && p_gchandle_free) {
                p_gchandle_free(it->second.handle);
            }
            it = gAppliedMats.erase(it);
        } else {
            ++it;
        }
    }
}

static dispatch_source_t gChamsTimer = nullptr;

static void ChamsTick() {
    @autoreleasepool {
        if (!gAttached) {
            return;
        }
        
        if (gChamsPlayerColorDirty) {
            for (int i = 0; i < 4; i++) {
                gChamsMatsPlayer[i] = nullptr;
            }
            gChamsPlayerColorDirty = false;
        }
        
        if (gChamsWeaponColorDirty) {
            for (int i = 0; i < 4; i++) {
                gChamsMatsWeapon[i] = nullptr;
            }
            gChamsWeaponColorDirty = false;
        }
        
        if (g_prevLocalWeapon != g_localWeapon) {
            g_prevLocalWeapon = g_localWeapon;
            gWeaponRenderersCache.clear();
        }
        
        if (!gChamsPlayerEnabled && !gChamsWeaponEnabled) {
            if (!gOrigMats.empty()) {
                RestoreAllChams();
            }
            return;
        }
        
        EnsureChamsMaterials();
        if (!gChamsMatsPlayer[0] && !gChamsMatsWeapon[0]) {
            return;
        }
        
        for (void* p : gCached) {
            if (!alive(p) || p == gLocal) {
                continue;
            }
            if (*(bool*)((uintptr_t)p + off::kPlayerIsDead)) {
                continue;
            }
            
            int tm = *(int*)((uintptr_t)p + off::kPlayerTeam);
            if (gAimbotNoTeam && tm == gTeam && gTeam >= 0) {
                continue;
            }
            
            void* c = *(void**)((uintptr_t)p + off::kPlayerCharacter);
            if (!alive(c) || *(bool*)((uintptr_t)c + off::kCharIsDead)) {
                continue;
            }
            
            void* ct = *(void**)((uintptr_t)c + off::kCharController);
            if (!alive(ct)) {
                continue;
            }
            
            UpdateChamsForPlayer(p, ct);
        }
        
        UpdateLocalChams();
        
        uint64_t tMs = NowMs();
        static uint64_t lastCleanup = 0;
        if (tMs - lastCleanup > 3000) {
            lastCleanup = tMs;
            CleanupDeadRenderers();
        }
    }
}

// =========================================================================================
// UI
// =========================================================================================
static UIImage* CreateFlopDLCFLogo(CGSize size) {
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextClearRect(c, CGRectMake(0, 0, size.width, size.height));
        CGFloat w = size.width;
        CGFloat h = size.height;
        
        // Draw F
        CGContextSetFillColorWithColor(c, [UIColor whiteColor].CGColor);
        CGContextFillRect(c, CGRectMake(w * 0.25, h * 0.15, w * 0.2, h * 0.7));
        CGContextFillRect(c, CGRectMake(w * 0.25, h * 0.15, w * 0.45, h * 0.2));
        CGContextFillRect(c, CGRectMake(w * 0.25, h * 0.45, w * 0.35, h * 0.15));
        
        // Draw Slash
        CGContextSetBlendMode(c, kCGBlendModeClear);
        CGContextSetLineWidth(c, w * 0.08);
        CGContextSetLineCap(c, kCGLineCapRound);
        CGContextMoveToPoint(c, w * 0.05, h * 0.95);
        CGContextAddLineToPoint(c, w * 0.85, h * 0.05);
        CGContextStrokePath(c);
        CGContextSetBlendMode(c, kCGBlendModeNormal);
    }];
}

static UIImage* CreateKeyIcon(CGSize size, UIColor *color) {
    UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* ctx) {
        CGContextRef c = ctx.CGContext;
        CGContextSetStrokeColorWithColor(c, color.CGColor);
        CGContextSetLineWidth(c, 2.0);
        CGContextSetLineCap(c, kCGLineCapRound);
        
        // Circle part
        CGContextStrokeEllipseInRect(c, CGRectMake(size.width * 0.2, size.height * 0.2, size.width * 0.4, size.height * 0.4));
        
        // Shaft
        CGContextMoveToPoint(c, size.width * 0.55, size.height * 0.55);
        CGContextAddLineToPoint(c, size.width * 0.85, size.height * 0.85);
        CGContextStrokePath(c);
        
        // Teeth
        CGContextMoveToPoint(c, size.width * 0.75, size.height * 0.85);
        CGContextAddLineToPoint(c, size.width * 0.85, size.height * 0.75);
        CGContextStrokePath(c);
    }];
}

@interface WatermarkView : UIView
@property (nonatomic, strong) UILabel* timeLabel;
@property (nonatomic, strong) UILabel* fpsLabel;
@property (nonatomic, strong) UILabel* ramLabel;
- (void)updateFps:(float)fps;
@end

@implementation WatermarkView {
    NSTimer* _timer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.95];
        self.layer.cornerRadius = 8.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        
        UIStackView* stack = [[UIStackView alloc] initWithFrame:self.bounds];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.distribution = UIStackViewDistributionEqualSpacing;
        stack.spacing = 10;
        stack.layoutMargins = UIEdgeInsetsMake(0, 15, 0, 15);
        stack.layoutMarginsRelativeArrangement = YES;
        stack.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:stack];
        
        UIImageView* logo = [[UIImageView alloc] initWithImage:CreateFlopDLCFLogo(CGSizeMake(40, 40))];
        logo.contentMode = UIViewContentModeScaleAspectFit;
        [logo.widthAnchor constraintEqualToConstant:20].active = YES;
        [logo.heightAnchor constraintEqualToConstant:20].active = YES;
        [stack addArrangedSubview:logo];
        
        UILabel* name = [[UILabel alloc] init];
        name.text = @"FlopDLC";
        name.textColor = [UIColor whiteColor];
        name.font = [UIFont boldSystemFontOfSize:15];
        [stack addArrangedSubview:name];
        
        UIView *sep1 = [[UIView alloc] init];
        sep1.backgroundColor = [UIColor grayColor];
        [sep1.widthAnchor constraintEqualToConstant:1].active = YES;
        [sep1.heightAnchor constraintEqualToConstant:16].active = YES;
        [stack addArrangedSubview:sep1];
        
        UIImageView* globe = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"globe"]];
        globe.tintColor = [UIColor colorWithRed:0.4 green:0.7 blue:1.0 alpha:1.0];
        [globe.widthAnchor constraintEqualToConstant:16].active = YES;
        [globe.heightAnchor constraintEqualToConstant:16].active = YES;
        [stack addArrangedSubview:globe];
        
        UILabel* url = [[UILabel alloc] init];
        url.text = @"FlopDLC.cc";
        url.textColor = [UIColor whiteColor];
        url.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        [stack addArrangedSubview:url];
        
        UIView *sep2 = [[UIView alloc] init];
        sep2.backgroundColor = [UIColor grayColor];
        [sep2.widthAnchor constraintEqualToConstant:1].active = YES;
        [sep2.heightAnchor constraintEqualToConstant:16].active = YES;
        [stack addArrangedSubview:sep2];
        
        UIImageView* clock = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"clock"]];
        clock.tintColor = [UIColor colorWithRed:0.9 green:0.8 blue:0.4 alpha:1.0];
        [clock.widthAnchor constraintEqualToConstant:16].active = YES;
        [clock.heightAnchor constraintEqualToConstant:16].active = YES;
        [stack addArrangedSubview:clock];
        
        _timeLabel = [[UILabel alloc] init];
        _timeLabel.text = @"00:00";
        _timeLabel.textColor = [UIColor whiteColor];
        _timeLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        [stack addArrangedSubview:_timeLabel];
        
        UIView *sep3 = [[UIView alloc] init];
        sep3.backgroundColor = [UIColor grayColor];
        [sep3.widthAnchor constraintEqualToConstant:1].active = YES;
        [sep3.heightAnchor constraintEqualToConstant:16].active = YES;
        [stack addArrangedSubview:sep3];
        
        UIImageView* speed = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"speedometer"]];
        speed.tintColor = [UIColor colorWithRed:0.6 green:0.4 blue:1.0 alpha:1.0];
        [speed.widthAnchor constraintEqualToConstant:16].active = YES;
        [speed.heightAnchor constraintEqualToConstant:16].active = YES;
        [stack addArrangedSubview:speed];
        
        _fpsLabel = [[UILabel alloc] init];
        _fpsLabel.text = @"60 FPS";
        _fpsLabel.textColor = [UIColor whiteColor];
        _fpsLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        [stack addArrangedSubview:_fpsLabel];
        
        UIView *sep4 = [[UIView alloc] init];
        sep4.backgroundColor = [UIColor grayColor];
        [sep4.widthAnchor constraintEqualToConstant:1].active = YES;
        [sep4.heightAnchor constraintEqualToConstant:16].active = YES;
        [stack addArrangedSubview:sep4];
        
        UIImageView* memIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"memorychip"]];
        memIcon.tintColor = [UIColor colorWithRed:0.4 green:0.8 blue:0.6 alpha:1.0];
        [memIcon.widthAnchor constraintEqualToConstant:16].active = YES;
        [memIcon.heightAnchor constraintEqualToConstant:16].active = YES;
        [stack addArrangedSubview:memIcon];
        
        _ramLabel = [[UILabel alloc] init];
        _ramLabel.text = @"0 MB / 0 MB";
        _ramLabel.textColor = [UIColor whiteColor];
        _ramLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        [stack addArrangedSubview:_ramLabel];
        
        _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(updateTime) userInfo:nil repeats:YES];
        [self updateTime];
    }
    return self;
}

- (void)updateTime {
    NSDateFormatter* fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm";
    _timeLabel.text = [fmt stringFromDate:[NSDate date]];
    
    struct mach_task_basic_info info;
    mach_msg_type_number_t size = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kerr = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &size);
    
    uint64_t used_mb = 0;
    if (kerr == KERN_SUCCESS) {
        used_mb = info.resident_size / (1024 * 1024);
    }
    
    uint64_t max_mb = 0;
    typedef uint64_t (*fn_os_proc_available_memory)();
    fn_os_proc_available_memory p_avail = (fn_os_proc_available_memory)dlsym(RTLD_DEFAULT, "os_proc_available_memory");
    
    if (p_avail) {
        uint64_t available = p_avail();
        max_mb = (info.resident_size + available) / (1024 * 1024);
    } else {
        max_mb = [NSProcessInfo processInfo].physicalMemory / (1024 * 1024);
    }
    
    _ramLabel.text = SafeFmt(@"%llu MB / %llu MB", used_mb, max_mb);
}

- (void)updateFps:(float)fps {
    if (!std::isfinite(fps)) {
        fps = 60;
    }
    _fpsLabel.text = SafeFmt(@"%.0f FPS", fps);
}

- (void)dealloc {
    [_timer invalidate];
}

@end

// =========================================================================================
// KEY SYSTEM (Neverlose Style Mobile Adjusted)
// =========================================================================================
@interface SnowView : UIView
@end

@implementation SnowView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        
        CAEmitterLayer *emitter = [CAEmitterLayer layer];
        emitter.emitterPosition = CGPointMake(frame.size.width / 2, -50);
        emitter.emitterSize = CGSizeMake(frame.size.width * 2, 1);
        emitter.emitterShape = kCAEmitterLayerLine;
        emitter.emitterMode = kCAEmitterLayerSurface;
        
        CAEmitterCell *snowflake = [CAEmitterCell emitterCell];
        snowflake.birthRate = 20.0;
        snowflake.lifetime = 10.0;
        snowflake.velocity = 40;
        snowflake.velocityRange = 20;
        snowflake.yAcceleration = 20;
        snowflake.emissionRange = 0.5 * M_PI;
        snowflake.spinRange = 0.25 * M_PI;
        
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(4, 4), NO, 0.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(0, 0, 4, 4));
        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        snowflake.contents = (id)img.CGImage;
        snowflake.scale = 0.5;
        snowflake.scaleRange = 0.5;
        snowflake.alphaSpeed = -0.05;
        
        emitter.emitterCells = @[snowflake];
        [self.layer addSublayer:emitter];
    }
    return self;
}

@end

@interface KeySystemView : UIView <UITextFieldDelegate>
@property (nonatomic, copy) void (^onSuccess)(void);
- (instancetype)initWithFrame:(CGRect)frame;
@end

@implementation KeySystemView {
    UITextField *_keyField;
    UILabel *_errorLabel;
    UIView *_mainContainer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.02 alpha:1.0];
        
        // Background Logo (Stretched & Angled)
        UIImageView *bgLogo = [[UIImageView alloc] initWithImage:CreateFlopDLCFLogo(CGSizeMake(800, 800))];
        bgLogo.contentMode = UIViewContentModeScaleAspectFit;
        bgLogo.frame = CGRectMake(-200, -100, frame.size.width + 400, frame.size.height + 200);
        bgLogo.transform = CGAffineTransformMakeRotation(M_PI / 8);
        bgLogo.alpha = 0.05;
        [self addSubview:bgLogo];
        
        // Glow Effects
        UIView *glow1 = [[UIView alloc] initWithFrame:CGRectMake(-100, -100, 400, 400)];
        glow1.backgroundColor = [UIColor colorWithRed:0.4 green:0.1 blue:0.8 alpha:0.3];
        glow1.layer.cornerRadius = 200;
        glow1.layer.masksToBounds = YES;
        [self addSubview:glow1];
        
        UIView *glow2 = [[UIView alloc] initWithFrame:CGRectMake(frame.size.width - 200, frame.size.height - 200, 400, 400)];
        glow2.backgroundColor = [UIColor colorWithRed:0.4 green:0.1 blue:0.8 alpha:0.3];
        glow2.layer.cornerRadius = 200;
        glow2.layer.masksToBounds = YES;
        [self addSubview:glow2];
        
        // Snow
        SnowView *snow = [[SnowView alloc] initWithFrame:frame];
        [self addSubview:snow];
        
        // Main Container (Mobile Friendly)
        CGFloat cw = MIN(frame.size.width - 40, 340);
        CGFloat ch = 400;
        
        _mainContainer = [[UIView alloc] initWithFrame:CGRectMake((frame.size.width - cw)/2, (frame.size.height - ch)/2, cw, ch)];
        _mainContainer.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.95];
        _mainContainer.layer.cornerRadius = 16;
        _mainContainer.layer.borderWidth = 1;
        _mainContainer.layer.borderColor = [UIColor colorWithRed:0.4 green:0.2 blue:0.8 alpha:1.0].CGColor;
        _mainContainer.clipsToBounds = YES;
        [self addSubview:_mainContainer];
        
        // Logo
        UIImageView *logo = [[UIImageView alloc] initWithImage:CreateFlopDLCFLogo(CGSizeMake(80, 80))];
        logo.center = CGPointMake(cw / 2, 60);
        logo.layer.shadowColor = [UIColor colorWithRed:0.5 green:0.2 blue:1.0 alpha:1.0].CGColor;
        logo.layer.shadowRadius = 15;
        logo.layer.shadowOpacity = 0.8;
        logo.layer.shadowOffset = CGSizeZero;
        [_mainContainer addSubview:logo];
        
        // Title
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 110, cw, 30)];
        title.text = @"Key System";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:22];
        title.textAlignment = NSTextAlignmentCenter;
        [_mainContainer addSubview:title];
        
        // Subtitle
        UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(0, 145, cw, 40)];
        subtitle.text = @"Enter your key to activate FlopDLC.\n(Free Key in @FlopDLC)";
        subtitle.textColor = [UIColor lightGrayColor];
        subtitle.font = [UIFont systemFontOfSize:12];
        subtitle.numberOfLines = 2;
        subtitle.textAlignment = NSTextAlignmentCenter;
        [_mainContainer addSubview:subtitle];
        
        // Input Field
        UIView *inputBg = [[UIView alloc] initWithFrame:CGRectMake(20, 200, cw - 40, 50)];
        inputBg.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];
        inputBg.layer.cornerRadius = 8;
        inputBg.layer.borderWidth = 1;
        inputBg.layer.borderColor = [UIColor colorWithWhite:0.2 alpha:1.0].CGColor;
        [_mainContainer addSubview:inputBg];
        
        UIImageView *inputIcon = [[UIImageView alloc] initWithImage:CreateKeyIcon(CGSizeMake(20, 20), [UIColor colorWithWhite:0.4 alpha:1.0])];
        inputIcon.frame = CGRectMake(15, 15, 20, 20);
        [inputBg addSubview:inputIcon];
        
        _keyField = [[UITextField alloc] initWithFrame:CGRectMake(45, 0, cw - 90, 50)];
        _keyField.textColor = [UIColor whiteColor];
        _keyField.font = [UIFont systemFontOfSize:14];
        _keyField.placeholder = @"Enter your key...";
        _keyField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Enter your key..." attributes:@{NSForegroundColorAttributeName: [UIColor grayColor]}];
        _keyField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _keyField.autocorrectionType = UITextAutocorrectionTypeNo;
        _keyField.delegate = self;
        [inputBg addSubview:_keyField];
        
        // Activate Button
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(20, 270, cw - 40, 50);
        [btn setTitle:@"Activate Key" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor colorWithRed:0.4 green:0.2 blue:0.8 alpha:1.0];
        btn.layer.cornerRadius = 8;
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        [btn setImage:[UIImage systemImageNamed:@"bolt.fill"] forState:UIControlStateNormal];
        btn.tintColor = [UIColor whiteColor];
        btn.imageEdgeInsets = UIEdgeInsetsMake(0, -10, 0, 0);
        [btn addTarget:self action:@selector(activate) forControlEvents:UIControlEventTouchUpInside];
        [_mainContainer addSubview:btn];
        
        _errorLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 330, cw - 40, 20)];
        _errorLabel.textColor = [UIColor redColor];
        _errorLabel.font = [UIFont systemFontOfSize:12];
        _errorLabel.textAlignment = NSTextAlignmentCenter;
        [_mainContainer addSubview:_errorLabel];
        
        // Bottom Bar
        UIView *bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, ch - 40, cw, 40)];
        bottomBar.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.5];
        [_mainContainer addSubview:bottomBar];
        
        UIView *topBorder = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cw, 1)];
        topBorder.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.5];
        [bottomBar addSubview:topBorder];
        
        UIView *statusView = [[UIView alloc] initWithFrame:CGRectMake((cw - 120)/2, 10, 120, 20)];
        statusView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
        statusView.layer.cornerRadius = 10;
        statusView.layer.borderWidth = 1;
        statusView.layer.borderColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.2 alpha:1.0].CGColor;
        [bottomBar addSubview:statusView];
        
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(10, 6, 8, 8)];
        dot.backgroundColor = [UIColor greenColor];
        dot.layer.cornerRadius = 4;
        [statusView addSubview:dot];
        
        UILabel *statusText = [[UILabel alloc] initWithFrame:CGRectMake(25, 0, 90, 20)];
        statusText.text = @"Ready";
        statusText.textColor = [UIColor whiteColor];
        statusText.font = [UIFont systemFontOfSize:11];
        [statusView addSubview:statusText];
    }
    return self;
}

- (void)activate {
    NSString *entered = _keyField.text;
    if ([entered isEqualToString:@"FlopDLC1122"]) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"flop_authed"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        if (self.onSuccess) {
            self.onSuccess();
        }
        [self removeFromSuperview];
    } else {
        _errorLabel.text = @"Неверный ключ!";
        
        CAKeyframeAnimation *anim = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
        anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        anim.duration = 0.4;
        anim.values = @[@(-10), @(10), @(-10), @(10), @(-5), @(5), @(0)];
        [_mainContainer.layer addAnimation:anim forKey:@"shake"];
    }
}

@end

// =========================================================================================
// UI COMPONENTS
// =========================================================================================
@interface NLGroupBox : UIView
@end

@implementation NLGroupBox

- (instancetype)initWithTitle:(NSString*)title frame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:0.8].CGColor;
        self.layer.borderWidth = 1.0;
        self.layer.cornerRadius = 6.0;
        self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.3];
        
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 200, 16)];
        lbl.text = SafeStr(title);
        lbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        lbl.textColor = [UIColor lightGrayColor];
        [self addSubview:lbl];
    }
    return self;
}

@end

@interface NLCheckbox : UIView
@property (nonatomic, assign) BOOL isOn;
@property (nonatomic, assign) BOOL isDisabled;
@property (nonatomic, copy) void (^onToggle)(BOOL);
@end

@implementation NLCheckbox {
    UIView *_inner;
    UILabel *_xMark;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 4;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:0.4 alpha:1.0].CGColor;
        self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
        self.userInteractionEnabled = YES;
        
        _inner = [[UIView alloc] init];
        _inner.layer.cornerRadius = 2;
        _inner.backgroundColor = [UIColor whiteColor];
        _inner.hidden = YES;
        _inner.userInteractionEnabled = NO;
        [self addSubview:_inner];
        
        _xMark = [[UILabel alloc] initWithFrame:self.bounds];
        _xMark.text = @"✖";
        _xMark.textColor = [UIColor redColor];
        _xMark.textAlignment = NSTextAlignmentCenter;
        _xMark.font = [UIFont boldSystemFontOfSize:12];
        _xMark.hidden = YES;
        [self addSubview:_xMark];
        
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggle)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _inner.frame = CGRectInset(self.bounds, 4, 4);
    _xMark.frame = self.bounds;
}

- (void)toggle {
    if (self.isDisabled) {
        return;
    }
    
    self.isOn = !self.isOn;
    _inner.hidden = !self.isOn;
    if (self.onToggle) {
        self.onToggle(self.isOn);
    }
}

- (void)setIsOn:(BOOL)isOn {
    _isOn = isOn;
    _inner.hidden = !isOn;
}

- (void)setIsDisabled:(BOOL)isDisabled {
    _isDisabled = isDisabled;
    if (isDisabled) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];
        self.layer.borderColor = [UIColor colorWithWhite:0.2 alpha:1.0].CGColor;
        _inner.hidden = YES;
        _xMark.hidden = NO;
    } else {
        self.userInteractionEnabled = YES;
        self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
        self.layer.borderColor = [UIColor colorWithWhite:0.4 alpha:1.0].CGColor;
        _xMark.hidden = YES;
        _inner.hidden = !_isOn;
    }
}

@end

@interface NLColorSwatch : UIView
@property (nonatomic, strong) UIColor *color;
@property (nonatomic, copy) void (^onTap)(void);
@end

@implementation NLColorSwatch

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 3;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor whiteColor].CGColor;
        
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapAction)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)setColor:(UIColor *)color {
    _color = color;
    self.backgroundColor = color ?: [UIColor whiteColor];
}

- (void)tapAction {
    if (self.onTap) {
        self.onTap();
    }
}

@end

@interface NLSlider : UIView
@property (nonatomic, assign) float value;
@property (nonatomic, assign) float min;
@property (nonatomic, assign) float max;
@property (nonatomic, copy) void (^onChange)(float);
@property (nonatomic, copy) void (^onRelease)(float);
@property (nonatomic, strong) UILabel *valLabel;
@end

@implementation NLSlider {
    UIView *_track;
    UIView *_fill;
    UIView *_knob;
    NSString *_suffix;
    float _w;
}

- (instancetype)initWithFrame:(CGRect)frame suffix:(NSString*)suffix {
    self = [super initWithFrame:frame];
    if (self) {
        _suffix = SafeStr(suffix);
        _w = frame.size.width - 35;
        self.userInteractionEnabled = YES;
        
        _track = [[UIView alloc] initWithFrame:CGRectMake(0, frame.size.height/2 - 1.5, _w, 3)];
        _track.backgroundColor = [UIColor darkGrayColor];
        _track.layer.cornerRadius = 1.5;
        [self addSubview:_track];
        
        _fill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _w, 3)];
        _fill.backgroundColor = [UIColor whiteColor];
        _fill.layer.cornerRadius = 1.5;
        [_track addSubview:_fill];
        
        _knob = [[UIView alloc] initWithFrame:CGRectMake(0, frame.size.height/2 - 5, 10, 10)];
        _knob.backgroundColor = [UIColor whiteColor];
        _knob.layer.cornerRadius = 5;
        [self addSubview:_knob];
        
        _valLabel = [[UILabel alloc] initWithFrame:CGRectMake(_w + 5, 0, 30, frame.size.height)];
        _valLabel.textColor = [UIColor whiteColor];
        _valLabel.font = [UIFont systemFontOfSize:10];
        _valLabel.textAlignment = NSTextAlignmentRight;
        [self addSubview:_valLabel];
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panAction:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)setValue:(float)value {
    if (!std::isfinite(value)) {
        return;
    }
    
    _value = MAX(self.min, MIN(self.max, value));
    float pct = (_value - self.min) / (self.max - self.min);
    
    _fill.frame = CGRectMake(0, 0, pct * _w, 3);
    _knob.center = CGPointMake(pct * _w, _track.center.y);
    
    if (_suffix.length > 0) {
        _valLabel.text = SafeFmt(@"%.1f%@", _value, _suffix);
    } else {
        _valLabel.text = SafeFmt(@"%.2f", _value);
    }
    
    if (self.onChange) {
        self.onChange(_value);
    }
}

- (void)panAction:(UIPanGestureRecognizer*)p {
    CGPoint pt = [p locationInView:self];
    float pct = MAX(0, MIN(1, pt.x / _w));
    float v = self.min + pct * (self.max - self.min);
    self.value = roundf(v * 10) / 10.0f;
    
    if (p.state == UIGestureRecognizerStateEnded && self.onRelease) {
        self.onRelease(self.value);
    }
}

@end

@interface NLButton : UIView
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation NLButton

- (instancetype)initWithTitle:(NSString*)title {
    self = [super initWithFrame:CGRectMake(0, 0, 80, 16)];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1.0];
        self.layer.cornerRadius = 3;
        self.userInteractionEnabled = YES;
        
        _titleLabel = [[UILabel alloc] initWithFrame:self.bounds];
        _titleLabel.text = SafeStr(title);
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_titleLabel];
        
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapAction)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)tapAction {
    if (self.onTap) {
        self.onTap();
    }
}

@end

@interface NLRow : UIView
@end

@implementation NLRow

- (instancetype)initWithTitle:(NSString*)title y:(CGFloat)y control:(UIView*)control swatch:(NLColorSwatch*)swatch {
    self = [super initWithFrame:CGRectMake(15, y, 210, 22)]; 
    if (self) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 100, 22)];
        l.text = SafeStr(title);
        l.textColor = [UIColor whiteColor];
        l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        [self addSubview:l];
        
        if (swatch) {
            swatch.frame = CGRectMake(105, 3, 16, 16);
            [self addSubview:swatch];
        }
        
        if (control) {
            CGRect f = control.frame;
            f.origin.x = 210 - f.size.width;
            f.origin.y = (22 - f.size.height) / 2;
            control.frame = f;
            [self addSubview:control];
        }
    }
    return self;
}

@end

@interface ColorPickerView : UIView
@property (nonatomic, copy) void (^onColorSelected)(UIColor *color);
- (instancetype)initWithFrame:(CGRect)frame currentColor:(UIColor*)color;
@end

@implementation ColorPickerView {
    UIImageView *_wheelView;
    UIView *_brightnessSlider;
    UIView *_knob;
    UIView *_preview;
    CAGradientLayer *_gradientLayer;
    CGFloat _hue;
    CGFloat _sat;
    CGFloat _brightness;
    CGPoint _center;
    CGFloat _radius;
}

- (instancetype)initWithFrame:(CGRect)frame currentColor:(UIColor*)color {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.95];
        self.layer.cornerRadius = 12;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:0.8].CGColor;
        
        CGFloat alpha = 1.0;
        if (![color getHue:&_hue saturation:&_sat brightness:&_brightness alpha:&alpha]) {
            _hue = 0;
            _sat = 1;
            _brightness = 1;
        }
        if (_sat == 0) {
            _hue = 0;
            _sat = 1;
        }
        
        _center = CGPointMake(frame.size.width / 2, 150);
        _radius = 100;
        
        _wheelView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, _radius*2, _radius*2)];
        _wheelView.center = _center;
        _wheelView.image = [self generateColorWheel:_radius];
        _wheelView.userInteractionEnabled = YES;
        [self addSubview:_wheelView];
        
        _brightnessSlider = [[UIView alloc] initWithFrame:CGRectMake(40, 280, frame.size.width - 80, 20)];
        _brightnessSlider.backgroundColor = [UIColor darkGrayColor];
        _brightnessSlider.layer.cornerRadius = 10;
        _brightnessSlider.layer.masksToBounds = YES;
        [self addSubview:_brightnessSlider];
        
        _gradientLayer = [CAGradientLayer layer];
        _gradientLayer.frame = _brightnessSlider.bounds;
        _gradientLayer.startPoint = CGPointMake(0, 0.5);
        _gradientLayer.endPoint = CGPointMake(1, 0.5);
        [_brightnessSlider.layer addSublayer:_gradientLayer];
        
        _knob = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
        _knob.backgroundColor = [UIColor whiteColor];
        _knob.layer.cornerRadius = 12;
        _knob.layer.borderWidth = 2;
        _knob.layer.borderColor = [UIColor blackColor].CGColor;
        [_brightnessSlider addSubview:_knob];
        
        _preview = [[UIView alloc] initWithFrame:CGRectMake((frame.size.width - 60) / 2, 320, 60, 60)];
        _preview.layer.cornerRadius = 30;
        _preview.layer.borderWidth = 2;
        _preview.layer.borderColor = [UIColor whiteColor].CGColor;
        [self addSubview:_preview];
        
        [self updateUI];
    }
    return self;
}

- (UIImage*)generateColorWheel:(CGFloat)radius {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(radius*2, radius*2)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        CGContextRef ctx = context.CGContext;
        int numSegments = 360;
        
        for (int i = 0; i < numSegments; i++) {
            CGFloat startAngle = (i * M_PI / 180.0) - M_PI_2;
            CGFloat endAngle = ((i + 1) * M_PI / 180.0) - M_PI_2;
            
            CGContextMoveToPoint(ctx, radius, radius);
            CGContextAddArc(ctx, radius, radius, radius, startAngle, endAngle, 0);
            CGContextClosePath(ctx);
            
            UIColor *c = [UIColor colorWithHue:(CGFloat)i/numSegments saturation:1.0 brightness:1.0 alpha:1.0];
            CGContextSetFillColorWithColor(ctx, c.CGColor);
            CGContextFillPath(ctx);
        }
        
        CGGradientRef gradient;
        CGColorSpaceRef colorspace;
        size_t num_locations = 2;
        CGFloat locations[2] = { 0.0, 1.0 };
        CGFloat components[8] = { 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.0 };
        
        colorspace = CGColorSpaceCreateDeviceRGB();
        gradient = CGGradientCreateWithColorComponents(colorspace, components, locations, num_locations);
        CGContextDrawRadialGradient(ctx, gradient, CGPointMake(radius, radius), 0, CGPointMake(radius, radius), radius, 0);
        
        CGGradientRelease(gradient);
        CGColorSpaceRelease(colorspace);
    }];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch* t = [touches anyObject];
    if (t) {
        [self handleTouch:t];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch* t = [touches anyObject];
    if (t) {
        [self handleTouch:t];
    }
}

- (void)handleTouch:(UITouch*)touch {
    CGPoint pt = [touch locationInView:self];
    CGFloat dx = pt.x - _center.x;
    CGFloat dy = pt.y - _center.y;
    CGFloat dist = sqrt(dx*dx + dy*dy);
    
    if (dist <= _radius + 20 && pt.y < 250) {
        _hue = (atan2(dy, dx) + M_PI_2) / (2*M_PI);
        if (_hue < 0) {
            _hue += 1.0;
        }
        _sat = MIN(1.0, dist / _radius);
        [self updateUI];
        [self sendColor];
    } else if (CGRectContainsPoint(_brightnessSlider.frame, pt)) {
        CGFloat pct = (pt.x - 40) / (self.frame.size.width - 80);
        _brightness = MAX(0, MIN(1, pct));
        [self updateUI];
        [self sendColor];
    }
}

- (void)updateUI {
    _knob.center = CGPointMake(_brightness * _brightnessSlider.bounds.size.width, _brightnessSlider.bounds.size.height/2);
    
    UIColor *c = [UIColor colorWithHue:_hue saturation:_sat brightness:_brightness alpha:1.0];
    _preview.backgroundColor = c;
    
    UIColor *pureHue = [UIColor colorWithHue:_hue saturation:_sat brightness:1.0 alpha:1.0];
    _gradientLayer.colors = @[(id)[UIColor blackColor].CGColor, (id)pureHue.CGColor];
}

- (void)sendColor {
    if (self.onColorSelected) {
        self.onColorSelected([UIColor colorWithHue:_hue saturation:_sat brightness:_brightness alpha:1.0]);
    }
}

@end

@interface ESPView : UIView
@property (nonatomic, strong) NSMutableArray<NSValue*>* boxes;
@property (nonatomic, strong) NSMutableArray<NSString*>* labels;
@property (nonatomic, strong) NSMutableArray<NSNumber*>* hps;
@property (nonatomic, strong) NSMutableArray<NSNumber*>* armors;
@property (nonatomic, strong) NSMutableArray<NSValue*>* skeletonLines;
@property (nonatomic, strong) NSMutableArray<NSValue*>* nameTexts;
@property (nonatomic, strong) NSMutableArray<NSString*>* names;
@property (nonatomic, strong) NSMutableArray<NSValue*>* tracers;
@property (nonatomic, strong) NSMutableArray<NSValue*>* oofDirs;
@property (nonatomic, strong) NSMutableArray<NSValue*>* weaponBoxes;
@property (nonatomic, strong) NSMutableArray<NSString*>* weaponLabels;
@property (nonatomic, strong) NSMutableArray<NSValue*>* headDots;
@property (nonatomic, strong) NSMutableArray<NSValue*>* snapLines;
@property (nonatomic, strong) NSMutableArray<UIColor*>* boxColors;
@property (nonatomic, strong) NSMutableArray<NSString*>* healthTexts;
@end

@implementation ESPView

- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.opaque = NO;
        self.clearsContextBeforeDrawing = NO;
        
        _boxes = [NSMutableArray arrayWithCapacity:32];
        _labels = [NSMutableArray arrayWithCapacity:32];
        _hps = [NSMutableArray arrayWithCapacity:32];
        _armors = [NSMutableArray arrayWithCapacity:32];
        _skeletonLines = [NSMutableArray arrayWithCapacity:64];
        _nameTexts = [NSMutableArray arrayWithCapacity:32];
        _names = [NSMutableArray arrayWithCapacity:32];
        _tracers = [NSMutableArray arrayWithCapacity:32];
        _oofDirs = [NSMutableArray arrayWithCapacity:32];
        _weaponBoxes = [NSMutableArray arrayWithCapacity:32];
        _weaponLabels = [NSMutableArray arrayWithCapacity:32];
        _headDots = [NSMutableArray arrayWithCapacity:32];
        _snapLines = [NSMutableArray arrayWithCapacity:32];
        _boxColors = [NSMutableArray arrayWithCapacity:32];
        _healthTexts = [NSMutableArray arrayWithCapacity:32];
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        return;
    }
    
    static UIFont *fontBold11 = nil;
    static UIFont *fontBold9 = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fontBold11 = [UIFont boldSystemFontOfSize:11];
        fontBold9 = [UIFont boldSystemFontOfSize:9];
    });
    
    NSDictionary *a = @{
        NSFontAttributeName: fontBold11 ?: [UIFont boldSystemFontOfSize:11],
        NSForegroundColorAttributeName: gNameColor ?: [UIColor whiteColor]
    };
    
    NSDictionary *fa = @{
        NSFontAttributeName: fontBold9 ?: [UIFont boldSystemFontOfSize:9],
        NSForegroundColorAttributeName: [UIColor whiteColor]
    };
    
    if (gTracersEnabled && self.tracers.count > 0) {
        CGContextSetLineWidth(ctx, 1.0);
        CGContextSetStrokeColorWithColor(ctx, (gTracerColor ?: [UIColor whiteColor]).CGColor);
        
        CGFloat cx = rect.size.width / 2.0f;
        CGFloat cy = rect.size.height / 2.0f;
        
        for (NSValue *v in self.tracers) {
            CGPoint endPt = [v CGPointValue];
            CGContextMoveToPoint(ctx, cx, cy);
            CGContextAddLineToPoint(ctx, endPt.x, endPt.y);
        }
        CGContextStrokePath(ctx);
    }
    
    if (gEspEnabled || gHotEspEnabled) {
        CGContextSetLineWidth(ctx, 1.0);
        
        for (NSUInteger i = 0; i < self.boxes.count; i++) {
            CGRect r = [self.boxes[i] CGRectValue];
            UIColor *bc = (i < self.boxColors.count) ? self.boxColors[i] : gBoxColor;
            CGContextSetStrokeColorWithColor(ctx, (bc ?: [UIColor redColor]).CGColor);
            
            int boxStyle = gBoxStyle.load();
            if (boxStyle == 1) {
                CGFloat cl = MIN(r.size.width, r.size.height) * 0.28f;
                CGContextSetLineWidth(ctx, 1.5);
                CGContextMoveToPoint(ctx, r.origin.x, r.origin.y + cl);
                CGContextAddLineToPoint(ctx, r.origin.x, r.origin.y);
                CGContextAddLineToPoint(ctx, r.origin.x + cl, r.origin.y);
                CGContextMoveToPoint(ctx, r.origin.x + r.size.width - cl, r.origin.y);
                CGContextAddLineToPoint(ctx, r.origin.x + r.size.width, r.origin.y);
                CGContextAddLineToPoint(ctx, r.origin.x + r.size.width, r.origin.y + cl);
                CGContextMoveToPoint(ctx, r.origin.x + r.size.width, r.origin.y + r.size.height - cl);
                CGContextAddLineToPoint(ctx, r.origin.x + r.size.width, r.origin.y + r.size.height);
                CGContextAddLineToPoint(ctx, r.origin.x + r.size.width - cl, r.origin.y + r.size.height);
                CGContextMoveToPoint(ctx, r.origin.x + cl, r.origin.y + r.size.height);
                CGContextAddLineToPoint(ctx, r.origin.x, r.origin.y + r.size.height);
                CGContextAddLineToPoint(ctx, r.origin.x, r.origin.y + r.size.height - cl);
                CGContextStrokePath(ctx);
            } else {
                CGContextStrokeRect(ctx, r);
            }
            
            if (gNameEnabled && i < self.names.count && i < self.nameTexts.count) {
                NSString *name = SafeStr(self.names[i]);
                CGPoint pt = [self.nameTexts[i] CGPointValue];
                CGSize size = [name sizeWithAttributes:a];
                [name drawAtPoint:CGPointMake(pt.x - size.width/2, pt.y) withAttributes:a];
            }
            
            if (i < self.labels.count) {
                NSString *lbl = SafeStr(self.labels[i]);
                CGSize size = [lbl sizeWithAttributes:fa];
                [lbl drawAtPoint:CGPointMake(r.origin.x + r.size.width + 2, r.origin.y + r.size.height/2 - size.height/2) withAttributes:fa];
            }
            
            if (gHealthTextEnabled && i < self.healthTexts.count) {
                NSString *hp = SafeStr(self.healthTexts[i]);
                CGSize hsz = [hp sizeWithAttributes:fa];
                [hp drawAtPoint:CGPointMake(r.origin.x + r.size.width/2 - hsz.width/2, r.origin.y + r.size.height + 2) withAttributes:fa];
            }
            
            if (gHealthBarEnabled && i < self.hps.count) {
                float h = [self.hps[i] floatValue];
                float aa = (i < self.armors.count) ? [self.armors[i] floatValue] : 0.0f;
                float ht = r.size.height;
                float pct = Math::Clamp(h / 100.0f, 0.0f, 1.0f);
                
                CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.1 alpha:0.8].CGColor);
                CGContextFillRect(ctx, CGRectMake(r.origin.x - 5, r.origin.y, 2, ht));
                
                CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:(1-pct) green:pct blue:0 alpha:1].CGColor);
                CGContextFillRect(ctx, CGRectMake(r.origin.x - 5, r.origin.y + ht*(1-pct), 2, ht*pct));
                
                if (aa > 0) {
                    float apct = Math::Clamp(aa / 100.0f, 0.0f, 1.0f);
                    
                    CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.2 green:0.5 blue:1 alpha:0.5].CGColor);
                    CGContextFillRect(ctx, CGRectMake(r.origin.x - 8, r.origin.y, 2, ht));
                    
                    CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.4 green:0.8 blue:1 alpha:1].CGColor);
                    CGContextFillRect(ctx, CGRectMake(r.origin.x - 8, r.origin.y + ht*(1-apct), 2, ht*apct));
                }
            }
        }
    }
    
    if (gWeaponEspEnabled && self.weaponBoxes.count > 0) {
        CGContextSetLineWidth(ctx, 1.0);
        CGContextSetStrokeColorWithColor(ctx, (gWeaponColor ?: [UIColor yellowColor]).CGColor);
        
        for (NSUInteger i = 0; i < self.weaponBoxes.count; i++) {
            CGRect r = [self.weaponBoxes[i] CGRectValue];
            CGContextStrokeRect(ctx, r);
            
            if (i < self.weaponLabels.count) {
                NSString *lbl = SafeStr(self.weaponLabels[i]);
                CGSize size = [lbl sizeWithAttributes:fa];
                [lbl drawAtPoint:CGPointMake(r.origin.x + r.size.width/2 - size.width/2, r.origin.y - size.height - 2) withAttributes:fa];
            }
        }
    }
    
    if (gSkeletonEnabled && self.skeletonLines.count > 0) {
        CGContextSetStrokeColorWithColor(ctx, (gSkelColor ?: [UIColor greenColor]).CGColor);
        CGContextSetLineWidth(ctx, gSkelThickness.load());
        
        for (NSValue *v in self.skeletonLines) {
            CGRect r = [v CGRectValue];
            CGContextMoveToPoint(ctx, r.origin.x, r.origin.y);
            CGContextAddLineToPoint(ctx, r.size.width, r.size.height);
        }
        CGContextStrokePath(ctx);
    }
    
    if (gHeadDotEnabled && self.headDots.count > 0) {
        for (NSUInteger i = 0; i < self.headDots.count; i++) {
            CGPoint p = [self.headDots[i] CGPointValue];
            UIColor *hc = (i < self.boxColors.count) ? self.boxColors[i] : (gBoxColor ?: [UIColor redColor]);
            CGContextSetFillColorWithColor(ctx, (hc ?: [UIColor redColor]).CGColor);
            CGContextFillEllipseInRect(ctx, CGRectMake(p.x - 2.5, p.y - 2.5, 5.0, 5.0));
        }
    }
    
    if (gSnapBottomEnabled && self.snapLines.count > 0) {
        CGContextSetLineWidth(ctx, 1.0);
        CGContextSetStrokeColorWithColor(ctx, (gTracerColor ?: [UIColor whiteColor]).CGColor);
        CGFloat bx = rect.size.width / 2.0f;
        CGFloat by = rect.size.height;
        for (NSValue *v in self.snapLines) {
            CGPoint p = [v CGPointValue];
            CGContextMoveToPoint(ctx, bx, by);
            CGContextAddLineToPoint(ctx, p.x, p.y);
        }
        CGContextStrokePath(ctx);
    }
    
    if (gOofEnabled && self.oofDirs.count > 0) {
        CGContextSetLineWidth(ctx, 2.0);
        CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
        
        CGFloat cx = rect.size.width / 2.0f;
        CGFloat cy = rect.size.height / 2.0f;
        CGFloat R = MIN(rect.size.width, rect.size.height) / 2.0f - 40.0f;
        
        for (NSValue *v in self.oofDirs) {
            CGPoint dir = [v CGPointValue];
            CGFloat ex = cx + dir.x * R;
            CGFloat ey = cy + dir.y * R;
            CGFloat ang = atan2(dir.y, dir.x);
            
            CGFloat ax1 = ex + cosf(ang + 2.5f) * 12;
            CGFloat ay1 = ey + sinf(ang + 2.5f) * 12;
            CGFloat ax2 = ex + cosf(ang - 2.5f) * 12;
            CGFloat ay2 = ey + sinf(ang - 2.5f) * 12;
            
            CGContextMoveToPoint(ctx, ax1, ay1);
            CGContextAddLineToPoint(ctx, ex, ey);
            CGContextAddLineToPoint(ctx, ax2, ay2);
            CGContextStrokePath(ctx);
        }
    }
    
    if (gAimbotEnabled || gAimOnFireEnabled) {
        float fov = (float)gAimbotFovPx;
        if (fov > 0) {
            CGContextSetStrokeColorWithColor(ctx, [UIColor whiteColor].CGColor);
            CGContextSetLineWidth(ctx, 1.0);
            CGContextStrokeEllipseInRect(ctx, CGRectMake(rect.size.width/2 - fov, rect.size.height/2 - fov, fov*2, fov*2));
        }
    }
}

@end

@interface MenuView : UIView
- (void)togglePlayerChamsMenu:(UIButton*)sender;
- (void)toggleWeaponChamsMenu:(UIButton*)sender;
- (void)selectPlayerChamsMat:(UIButton*)sender;
- (void)selectWeaponChamsMat:(UIButton*)sender;
- (void)skyPresetTap:(UIButton*)sender;
@end

@interface HotZoneView : UIView
@end

@class HotkeyView;

static ESPView* gEspView = nil;
static MenuView* gMenuView = nil;
static HotZoneView* gHotZone = nil;
static WatermarkView* gWatermark = nil;
static ColorPickerView* gColorPicker = nil;
static UIWindow* gMainWin = nil;
static UIView* gOverlayContainer = nil;
static UITextField* gSecureField = nil;
static HotkeyView* gHotkeyView = nil;
static void RefreshHotkeyView(void);

@interface PassthroughView : UIView
@end

@implementation PassthroughView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return v == self ? nil : v;
}

@end

@interface SecureTextField : UITextField
@end

@implementation SecureTextField

- (BOOL)canBecomeFirstResponder {
    return NO;
}

- (BOOL)becomeFirstResponder {
    return NO;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self || !v) ? nil : v;
}

@end

static void UpdateStreamMode(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (!gOverlayContainer || !gMainWin) {
                return;
            }
            RefreshHotkeyView();
            
            if (gStreamMode) {
                RestoreAllChams();
                gWatermark.hidden = YES;
                gHotkeyView.hidden = YES;
                
                if (!gSecureField) {
                    gSecureField = [[SecureTextField alloc] initWithFrame:gMainWin.bounds];
                    gSecureField.secureTextEntry = YES;
                    gSecureField.backgroundColor = [UIColor clearColor];
                    gSecureField.userInteractionEnabled = YES;
                    gSecureField.text = @" ";
                }
                
                if (gSecureField.superview != gMainWin) {
                    [gMainWin addSubview:gSecureField];
                }
                [gMainWin bringSubviewToFront:gSecureField];
                
                UIView *canvas = nil;
                for (UIView *sub in gSecureField.subviews) {
                    if ([NSStringFromClass([sub class]) containsString:@"Canvas"] || [NSStringFromClass([sub class]) containsString:@"ContentView"]) {
                        canvas = sub;
                        break;
                    }
                }
                
                if (!canvas && gSecureField.subviews.count > 0) {
                    canvas = gSecureField.subviews[0];
                }
                
                [gOverlayContainer removeFromSuperview];
                if (canvas) {
                    canvas.userInteractionEnabled = YES;
                    [canvas addSubview:gOverlayContainer];
                } else {
                    [gSecureField addSubview:gOverlayContainer];
                }
            } else {
                gWatermark.hidden = NO;
                gHotkeyView.hidden = gMenuOpen;
                [gOverlayContainer removeFromSuperview];
                [gMainWin addSubview:gOverlayContainer];
                
                if (gSecureField) {
                    [gSecureField removeFromSuperview];
                }
            }
        } @catch (NSException* e) {
        }
    });
}

@implementation HotZoneView

- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapAction)];
        t.numberOfTapsRequired = 3;
        [self addGestureRecognizer:t];
    }
    return self;
}

- (void)tapAction {
    @try {
        bool open = !gMenuOpen;
        gMenuOpen = open;
        
        if (open) {
            gHotZone.hidden = YES;
            gEspView.hidden = YES;
            gWatermark.hidden = YES;
            gHotkeyView.hidden = YES;
            gMenuView.hidden = NO;
            gMenuView.alpha = 0;
            gMenuView.transform = CGAffineTransformMakeScale(0.95, 0.95);
            
            [gOverlayContainer bringSubviewToFront:gMenuView];
            
            [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
                gMenuView.alpha = 1.0;
                gMenuView.transform = CGAffineTransformIdentity;
            } completion:nil];
        } else {
            gMenuOpen = false;
            [UIView animateWithDuration:0.25 animations:^{
                gMenuView.transform = CGAffineTransformMakeScale(0.95, 0.95);
                gMenuView.alpha = 0.0;
            } completion:^(BOOL finished) {
                gMenuView.hidden = YES;
                gMenuView.transform = CGAffineTransformIdentity;
                gMenuView.alpha = 1.0;
                gHotZone.hidden = NO;
                gEspView.hidden = NO;
                RefreshHotkeyView();
                gHotkeyView.hidden = gStreamMode;
                if (!gStreamMode) {
                    gWatermark.hidden = NO;
                }
            }];
        }
    } @catch (NSException* e) {
    }
}

@end

@implementation MenuView {
    UIVisualEffectView *_blurView;
    UIView *_topBar;
    UIView *_content;
    UIScrollView *_scrollView;
    NSMutableArray *_tabs;
    int _currentTab;
    BOOL _isMinimized;
    CGRect _origFrame;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _origFrame = frame;
        self.layer.cornerRadius = 12;
        self.clipsToBounds = YES;
        self.userInteractionEnabled = YES;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:0.8].CGColor;
        
        _blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_blurView];
        
        UIView *darkOverlay = [[UIView alloc] initWithFrame:self.bounds];
        darkOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.3];
        darkOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:darkOverlay];
        
        _topBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, 35)];
        _topBar.backgroundColor = [UIColor clearColor];
        _topBar.layer.borderWidth = 0.5;
        _topBar.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:0.8].CGColor;
        _topBar.userInteractionEnabled = YES;
        
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panAction:)];
        [_topBar addGestureRecognizer:pan];
        [self addSubview:_topBar];
        
        UIImageView *logoImg = [[UIImageView alloc] initWithImage:CreateFlopDLCFLogo(CGSizeMake(16, 16))];
        logoImg.frame = CGRectMake(15, 9, 16, 16);
        [_topBar addSubview:logoImg];
        
        UILabel *logoText = [[UILabel alloc] initWithFrame:CGRectMake(35, 0, 100, 35)];
        logoText.text = @"FlopDLC";
        logoText.textColor = [UIColor whiteColor];
        logoText.font = [UIFont systemFontOfSize:16 weight:UIFontWeightHeavy];
        [_topBar addSubview:logoText];
        
        _tabs = [NSMutableArray array];
        [self addTab:@"AIMBOT" x:120];
        [self addTab:@"VISUALS" x:185];
        [self addTab:@"WORLD" x:250];
        [self addTab:@"PLAYER" x:315];
        [self addTab:@"MISC" x:380];
        [self addTab:@"SETTINGS" x:445];
        
        UIButton *mb = [UIButton buttonWithType:UIButtonTypeCustom];
        mb.frame = CGRectMake(frame.size.width - 60, 10, 15, 15);
        [mb setImage:[UIImage systemImageNamed:@"minus"] forState:UIControlStateNormal];
        mb.tintColor = [UIColor lightGrayColor];
        [mb addTarget:self action:@selector(minimizeAction) forControlEvents:UIControlEventTouchUpInside];
        [_topBar addSubview:mb];
        
        UIButton *cb = [UIButton buttonWithType:UIButtonTypeCustom];
        cb.frame = CGRectMake(frame.size.width - 30, 10, 15, 15);
        [cb setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
        cb.tintColor = [UIColor lightGrayColor];
        [cb addTarget:self action:@selector(closeAction) forControlEvents:UIControlEventTouchUpInside];
        [_topBar addSubview:cb];
        
        _content = [[UIView alloc] initWithFrame:CGRectMake(0, 35, frame.size.width, frame.size.height - 35)];
        [self addSubview:_content];
        
        _scrollView = [[UIScrollView alloc] initWithFrame:_content.bounds];
        _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _scrollView.showsVerticalScrollIndicator = NO;
        _scrollView.contentSize = CGSizeMake(frame.size.width, 1200);
        [_content addSubview:_scrollView];
        
        [self switchToTab:0];
    }
    return self;
}

- (void)showColorPickerForSwatch:(NLColorSwatch*)swatch currentColor:(UIColor*)color saveKey:(NSString*)key {
    @try {
        if (gColorPicker) {
            [gColorPicker removeFromSuperview];
        }
        if (!swatch || !key) {
            return;
        }
        
        gColorPicker = [[ColorPickerView alloc] initWithFrame:CGRectMake((self.bounds.size.width - 300)/2, (self.bounds.size.height - 400)/2, 300, 400) currentColor:color ?: [UIColor whiteColor]];
        
        __weak NLColorSwatch *weakSwatch = swatch;
        __weak NSString *weakKey = key;
        
        gColorPicker.onColorSelected = ^(UIColor *newColor) {
            if (!newColor || !weakSwatch || !weakKey) {
                return;
            }
            
            weakSwatch.color = newColor;
            
            if ([weakKey isEqualToString:@"c_b"]) {
                gBoxColor = newColor;
            } else if ([weakKey isEqualToString:@"c_s"]) {
                gSkelColor = newColor;
            } else if ([weakKey isEqualToString:@"c_n"]) {
                gNameColor = newColor;
            } else if ([weakKey isEqualToString:@"c_t"]) {
                gTracerColor = newColor;
            } else if ([weakKey isEqualToString:@"v_sky_c"]) {
                CGFloat r, g, b, a;
                [newColor getRed:&r green:&g blue:&b alpha:&a];
                uint32_t hex = ((int)(r*255) << 24) | ((int)(g*255) << 16) | ((int)(b*255) << 8) | (int)(a*255);
                gSkyboxColorHex = hex;
                gSkyboxDirty = true;
                [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)hex forKey:weakKey];
                [[NSUserDefaults standardUserDefaults] synchronize];
                return;
            } else if ([weakKey isEqualToString:@"v_chams_pl_c"]) {
                CGFloat r, g, b, a;
                [newColor getRed:&r green:&g blue:&b alpha:&a];
                uint32_t hex = ((int)(r*255) << 24) | ((int)(g*255) << 16) | ((int)(b*255) << 8) | (int)(a*255);
                gChamsPlayerColor = hex;
                gChamsPlayerColorDirty = true;
                [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)hex forKey:weakKey];
                [[NSUserDefaults standardUserDefaults] synchronize];
                return;
            } else if ([weakKey isEqualToString:@"v_chams_wep_c"]) {
                CGFloat r, g, b, a;
                [newColor getRed:&r green:&g blue:&b alpha:&a];
                uint32_t hex = ((int)(r*255) << 24) | ((int)(g*255) << 16) | ((int)(b*255) << 8) | (int)(a*255);
                gChamsWeaponColor = hex;
                gChamsWeaponColorDirty = true;
                [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)hex forKey:weakKey];
                [[NSUserDefaults standardUserDefaults] synchronize];
                return;
            } else if ([weakKey isEqualToString:@"wv_amb_c"]) {
                CGFloat r, g, b, a;
                [newColor getRed:&r green:&g blue:&b alpha:&a];
                uint32_t hex = ((int)(r*255) << 24) | ((int)(g*255) << 16) | ((int)(b*255) << 8) | (int)(a*255);
                gAmbientColorHex = hex;
                [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)hex forKey:weakKey];
                [[NSUserDefaults standardUserDefaults] synchronize];
                return;
            }
            
            else if ([weakKey isEqualToString:@"c_team"]) {
                gTeamColor = newColor;
            } else if ([weakKey isEqualToString:@"c_vis"]) {
                gVisibleColor = newColor;
            } else if ([weakKey isEqualToString:@"c_hid"]) {
                gHiddenColor = newColor;
            } else if ([weakKey isEqualToString:@"c_hm"]) {
                gHitMarkerColor = newColor;
            } else if ([weakKey isEqualToString:@"c_radar"]) {
                gRadarColor = newColor;
            } else if ([weakKey isEqualToString:@"c_cross"]) {
                gCrosshairColor = newColor;
            }
            
            [ConfigManager saveColor:newColor forKey:weakKey];
        };
        
        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(gColorPicker.bounds.size.width - 40, 10, 30, 30);
        [closeBtn setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
        closeBtn.tintColor = [UIColor whiteColor];
        [closeBtn addTarget:self action:@selector(closeColorPicker) forControlEvents:UIControlEventTouchUpInside];
        [gColorPicker addSubview:closeBtn];
        
        [self addSubview:gColorPicker];
        
        gColorPicker.transform = CGAffineTransformMakeScale(0.8, 0.8);
        gColorPicker.alpha = 0;
        
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
            gColorPicker.transform = CGAffineTransformIdentity;
            gColorPicker.alpha = 1;
        } completion:nil];
    } @catch (NSException* e) {
    }
}

- (void)closeColorPicker {
    if (!gColorPicker) {
        return;
    }
    [UIView animateWithDuration:0.2 animations:^{
        gColorPicker.alpha = 0;
        gColorPicker.transform = CGAffineTransformMakeScale(0.8, 0.8);
    } completion:^(BOOL finished) {
        [gColorPicker removeFromSuperview];
        gColorPicker = nil;
    }];
}

- (void)addTab:(NSString*)title x:(CGFloat)x {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, 0, 62, 35);
    [b setTitle:SafeStr(title) forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    [b setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
    [b addTarget:self action:@selector(tabTap:) forControlEvents:UIControlEventTouchUpInside];
    [_topBar addSubview:b];
    [_tabs addObject:b];
}

- (void)tabTap:(UIButton*)sender {
    NSUInteger idx = [_tabs indexOfObject:sender];
    if (idx != NSNotFound) {
        [self switchToTab:(int)idx];
    }
}

- (void)switchToTab:(int)tabIndex {
    _currentTab = tabIndex;
    
    for (int i = 0; i < (int)_tabs.count; i++) {
        UIButton *b = _tabs[i];
        if (i == tabIndex) {
            [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        } else {
            [b setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
        }
    }
    
    [self buildContent];
}

- (void)buildContent {
    @try {
        __weak MenuView* weakSelf = self;
        
        for (UIView *v in _scrollView.subviews) {
            [v removeFromSuperview];
        }
        
        CGFloat colW = (_scrollView.bounds.size.width - 45) / 2;
        CGFloat yBase = 20;
        
        UIView *c1 = [[UIView alloc] initWithFrame:CGRectMake(15, yBase, colW, 1100)];
        UIView *c2 = [[UIView alloc] initWithFrame:CGRectMake(15 + colW + 15, yBase, colW, 1100)];
        [_scrollView addSubview:c1];
        [_scrollView addSubview:c2];
        
        if (_currentTab == 0) {
            NLGroupBox *gAuto = [[NLGroupBox alloc] initWithTitle:@"Auto" frame:CGRectMake(0, 0, colW, 350)];
            [c1 addSubview:gAuto];
            CGFloat y = 30;
            
            NLCheckbox *cbAim = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbAim.isOn = gAimbotEnabled;
            cbAim.onToggle = ^(BOOL v) {
                gAimbotEnabled = v;
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"Aimbot" y:y control:cbAim swatch:nil]];
            y += 30;

            NLCheckbox *cbAimOnFire = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbAimOnFire.isOn = gAimOnFireEnabled;
            cbAimOnFire.onToggle = ^(BOOL v) {
                gAimOnFireEnabled = v;
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"Aim On Fire" y:y control:cbAimOnFire swatch:nil]];
            y += 30;
            
            NLButton *bBone = [[NLButton alloc] initWithTitle:@"Head"];
            __weak NLButton *weakBone = bBone;
            if (gAimBone == 10) [bBone.titleLabel setText:@"Head"];
            else if (gAimBone == 8) [bBone.titleLabel setText:@"Chest"];
            else [bBone.titleLabel setText:@"Hips"];
            
            bBone.onTap = ^{
                int cur = gAimBone;
                if (cur == 10) cur = 8;
                else if (cur == 8) cur = 0;
                else cur = 10;
                gAimBone = cur;
                
                if (cur == 10) [weakBone.titleLabel setText:@"Head"];
                else if (cur == 8) [weakBone.titleLabel setText:@"Chest"];
                else [weakBone.titleLabel setText:@"Hips"];
                
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"Target Bone" y:y control:bBone swatch:nil]];
            y += 30;
            
            NLCheckbox *cbSA = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSA.isOn = gSilentAimEnabled;
            cbSA.isDisabled = YES;
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"Silent Aim (Not Work)" y:y control:cbSA swatch:nil]];
            y += 30;
            
            NLCheckbox *cbVO = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbVO.isOn = gAimbotVisibleOnly;
            cbVO.onToggle = ^(BOOL v) {
                gAimbotVisibleOnly = v;
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"Visible Only" y:y control:cbVO swatch:nil]];
            y += 30;
            
            NLCheckbox *cbNT = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbNT.isOn = gAimbotNoTeam;
            cbNT.onToggle = ^(BOOL v) {
                gAimbotNoTeam = v;
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"No Team" y:y control:cbNT swatch:nil]];
            y += 30;
            
            NLSlider *s1 = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,110,18) suffix:@"px"];
            s1.min = 50;
            s1.max = 800;
            s1.value = gAimbotFovPx;
            s1.onChange = ^(float v) {
                gAimbotFovPx = (int)v;
            };
            s1.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"FOV" y:y control:s1 swatch:nil]];
            y += 30;
            
            NLSlider *s2 = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,110,18) suffix:@""];
            s2.min = 0.0f;
            s2.max = 1.0f;
            s2.value = gAimbotSmooth;
            s2.onChange = ^(float v) {
                gAimbotSmooth = v;
            };
            s2.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"Smooth" y:y control:s2 swatch:nil]];
            y += 30;

            NLSlider *s3 = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,110,18) suffix:@""];
            s3.min = 0.0f;
            s3.max = 1.0f;
            s3.value = gAimOnFireSmooth;
            s3.onChange = ^(float v) {
                gAimOnFireSmooth = v;
            };
            s3.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gAuto addSubview:[[NLRow alloc] initWithTitle:@"Aim On Fire Smooth" y:y control:s3 swatch:nil]];
            y += 30;
            
        } else if (_currentTab == 1) {
            NLGroupBox *gEsp = [[NLGroupBox alloc] initWithTitle:@"Players" frame:CGRectMake(0, 0, colW, 340)];
            [c1 addSubview:gEsp];
            CGFloat y = 30;
            
            NLCheckbox *cbE = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbE.isOn = gEspEnabled;
            cbE.onToggle = ^(BOOL v) {
                gEspEnabled = v;
                [ConfigManager save];
            };
            [gEsp addSubview:[[NLRow alloc] initWithTitle:@"Enable ESP" y:y control:cbE swatch:nil]];
            y += 30;
            
            NLColorSwatch *swBox = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swBox.color = gBoxColor;
            __weak NLColorSwatch *weakSwBox = swBox;
            swBox.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwBox currentColor:weakSwBox.color saveKey:@"c_b"];
            };
            
            NLCheckbox *cbH = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbH.isOn = gHealthBarEnabled;
            cbH.onToggle = ^(BOOL v) {
                gHealthBarEnabled = v;
                [ConfigManager save];
            };
            [gEsp addSubview:[[NLRow alloc] initWithTitle:@"Boxes & HP" y:y control:cbH swatch:swBox]];
            y += 30;
            
            NLColorSwatch *swName = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swName.color = gNameColor;
            __weak NLColorSwatch *weakSwName = swName;
            swName.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwName currentColor:weakSwName.color saveKey:@"c_n"];
            };
            
            NLCheckbox *cbN = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbN.isOn = gNameEnabled;
            cbN.onToggle = ^(BOOL v) {
                gNameEnabled = v;
                [ConfigManager save];
            };
            [gEsp addSubview:[[NLRow alloc] initWithTitle:@"Names" y:y control:cbN swatch:swName]];
            y += 30;
            
            NLColorSwatch *swSkel = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swSkel.color = gSkelColor;
            __weak NLColorSwatch *weakSwSkel = swSkel;
            swSkel.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwSkel currentColor:weakSwSkel.color saveKey:@"c_s"];
            };
            
            NLCheckbox *cbS = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbS.isOn = gSkeletonEnabled;
            cbS.onToggle = ^(BOOL v) {
                gSkeletonEnabled = v;
                [ConfigManager save];
            };
            [gEsp addSubview:[[NLRow alloc] initWithTitle:@"Skeleton" y:y control:cbS swatch:swSkel]];
            y += 30;
            
            NLColorSwatch *swTracer = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swTracer.color = gTracerColor;
            __weak NLColorSwatch *weakSwTracer = swTracer;
            swTracer.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwTracer currentColor:weakSwTracer.color saveKey:@"c_t"];
            };
            
            NLCheckbox *cbTr = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbTr.isOn = gTracersEnabled;
            cbTr.onToggle = ^(BOOL v) {
                gTracersEnabled = v;
                [ConfigManager save];
            };
            [gEsp addSubview:[[NLRow alloc] initWithTitle:@"Snaplines" y:y control:cbTr swatch:swTracer]];
            y += 30;

            NLGroupBox *gWorld = [[NLGroupBox alloc] initWithTitle:@"World" frame:CGRectMake(0, 0, colW, 210)];
            [c2 addSubview:gWorld];
            y = 30;
            
            NLCheckbox *cbKS = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbKS.isOn = gKillSoundEnabled;
            cbKS.onToggle = ^(BOOL v) {
                gKillSoundEnabled = v;
                [ConfigManager save];
            };
            [gWorld addSubview:[[NLRow alloc] initWithTitle:@"Kill Sound" y:y control:cbKS swatch:nil]];
            y += 30;
            
            NLGroupBox *gChams = [[NLGroupBox alloc] initWithTitle:@"Chams" frame:CGRectMake(0, 140, colW, 280)];
            [c2 addSubview:gChams];
            CGFloat cy = 30;
            
            NLCheckbox *cbChamsPl = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbChamsPl.isOn = gChamsPlayerEnabled;
            cbChamsPl.onToggle = ^(BOOL v) {
                gChamsPlayerEnabled = v;
                [ConfigManager save];
            };
            
            NLColorSwatch *swChamsPl = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            uint32_t hPl = gChamsPlayerColor.load();
            swChamsPl.color = [UIColor colorWithRed:((hPl>>24)&0xFF)/255.0 green:((hPl>>16)&0xFF)/255.0 blue:((hPl>>8)&0xFF)/255.0 alpha:(hPl&0xFF)/255.0];
            __weak NLColorSwatch *weakSwChamsPl = swChamsPl;
            swChamsPl.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwChamsPl currentColor:weakSwChamsPl.color saveKey:@"v_chams_pl_c"];
            };
            
            [gChams addSubview:[[NLRow alloc] initWithTitle:@"Players" y:cy control:cbChamsPl swatch:swChamsPl]];
            
            UIButton *chevPl = [UIButton buttonWithType:UIButtonTypeSystem];
            chevPl.frame = CGRectMake(colW - 32, cy + 3, 18, 16);
            [chevPl setTitle:@"^" forState:UIControlStateNormal];
            [chevPl setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            chevPl.titleLabel.font = [UIFont systemFontOfSize:12];
            chevPl.tag = 100;
            [chevPl addTarget:weakSelf action:@selector(togglePlayerChamsMenu:) forControlEvents:UIControlEventTouchUpInside];
            [gChams addSubview:chevPl];
            cy += 30;
            
            UIView *matSelPl = [[UIView alloc] initWithFrame:CGRectMake(15, cy, colW - 30, 22)];
            matSelPl.tag = 200;
            matSelPl.hidden = YES;
            
            NSArray *matNames = @[@"Normal", @"Glass", @"Glow", @"X-Ray"];
            CGFloat bw = (colW - 30 - 9) / 4.0;
            
            for (int i = 0; i < 4; i++) {
                UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
                b.frame = CGRectMake(i * (bw + 3), 0, bw, 20);
                b.backgroundColor = ((int)gChamsPlayerMatType == i) ? [UIColor colorWithWhite:0.4 alpha:1.0] : [UIColor colorWithWhite:0.15 alpha:1.0];
                [b setTitle:matNames[i] forState:UIControlStateNormal];
                [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                b.titleLabel.font = [UIFont systemFontOfSize:9];
                b.layer.cornerRadius = 3;
                b.tag = 1000 + i;
                [b addTarget:weakSelf action:@selector(selectPlayerChamsMat:) forControlEvents:UIControlEventTouchUpInside];
                [matSelPl addSubview:b];
            }
            
            [gChams addSubview:matSelPl];
            cy += 30;
            
            NLCheckbox *cbChamsWep = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbChamsWep.isOn = gChamsWeaponEnabled;
            cbChamsWep.onToggle = ^(BOOL v) {
                gChamsWeaponEnabled = v;
                [ConfigManager save];
            };
            
            NLColorSwatch *swChamsWep = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            uint32_t hWep = gChamsWeaponColor.load();
            swChamsWep.color = [UIColor colorWithRed:((hWep>>24)&0xFF)/255.0 green:((hWep>>16)&0xFF)/255.0 blue:((hWep>>8)&0xFF)/255.0 alpha:(hWep&0xFF)/255.0];
            __weak NLColorSwatch *weakSwChamsWep = swChamsWep;
            swChamsWep.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwChamsWep currentColor:weakSwChamsWep.color saveKey:@"v_chams_wep_c"];
            };
            
            [gChams addSubview:[[NLRow alloc] initWithTitle:@"Weapons" y:cy control:cbChamsWep swatch:swChamsWep]];
            
            UIButton *chevWep = [UIButton buttonWithType:UIButtonTypeSystem];
            chevWep.frame = CGRectMake(colW - 32, cy + 3, 18, 16);
            [chevWep setTitle:@"^" forState:UIControlStateNormal];
            [chevWep setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            chevWep.titleLabel.font = [UIFont systemFontOfSize:12];
            chevWep.tag = 101;
            [chevWep addTarget:weakSelf action:@selector(toggleWeaponChamsMenu:) forControlEvents:UIControlEventTouchUpInside];
            [gChams addSubview:chevWep];
            cy += 30;
            
            UIView *matSelWep = [[UIView alloc] initWithFrame:CGRectMake(15, cy, colW - 30, 22)];
            matSelWep.tag = 201;
            matSelWep.hidden = YES;
            
            for (int i = 0; i < 4; i++) {
                UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
                b.frame = CGRectMake(i * (bw + 3), 0, bw, 20);
                b.backgroundColor = ((int)gChamsWeaponMatType == i) ? [UIColor colorWithWhite:0.4 alpha:1.0] : [UIColor colorWithWhite:0.15 alpha:1.0];
                [b setTitle:matNames[i] forState:UIControlStateNormal];
                [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                b.titleLabel.font = [UIFont systemFontOfSize:9];
                b.layer.cornerRadius = 3;
                b.tag = 1010 + i;
                [b addTarget:weakSelf action:@selector(selectWeaponChamsMat:) forControlEvents:UIControlEventTouchUpInside];
                [matSelWep addSubview:b];
            }
            
            [gChams addSubview:matSelWep];
            cy += 30;
            
            NLGroupBox *gHud = [[NLGroupBox alloc] initWithTitle:@"HUD & Extras" frame:CGRectMake(0, 430, colW, 620)];
            [c2 addSubview:gHud];
            CGFloat hy = 30;
            
            NLCheckbox *cbHD = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHD.isOn = gHeadDotEnabled;
            cbHD.onToggle = ^(BOOL v) {
                gHeadDotEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Head Dot" y:hy control:cbHD swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbDist = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbDist.isOn = gDistanceEnabled;
            cbDist.onToggle = ^(BOOL v) {
                gDistanceEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Distance" y:hy control:cbDist swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbHP = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHP.isOn = gHealthTextEnabled;
            cbHP.onToggle = ^(BOOL v) {
                gHealthTextEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Health Text" y:hy control:cbHP swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbHM = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHM.isOn = gHitMarkerEnabled;
            cbHM.onToggle = ^(BOOL v) {
                gHitMarkerEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Hit Marker" y:hy control:cbHM swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbDN = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbDN.isOn = gDamageNumbersEnabled;
            cbDN.onToggle = ^(BOOL v) {
                gDamageNumbersEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Damage Numbers" y:hy control:cbDN swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbRadar = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbRadar.isOn = gRadarEnabled;
            cbRadar.onToggle = ^(BOOL v) {
                gRadarEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Radar" y:hy control:cbRadar swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbCross = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbCross.isOn = gCrosshairEnabled;
            cbCross.onToggle = ^(BOOL v) {
                gCrosshairEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Dynamic Crosshair" y:hy control:cbCross swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbScope = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbScope.isOn = gScopeOverlayEnabled;
            cbScope.onToggle = ^(BOOL v) {
                gScopeOverlayEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Scope Overlay" y:hy control:cbScope swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbAL = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbAL.isOn = gAimLineEnabled;
            cbAL.onToggle = ^(BOOL v) {
                gAimLineEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Aim Line" y:hy control:cbAL swatch:nil]];
            hy += 30;
            
            NLColorSwatch *swTeam = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swTeam.color = gTeamColor;
            __weak NLColorSwatch *weakSwTeam = swTeam;
            swTeam.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwTeam currentColor:weakSwTeam.color saveKey:@"c_team"];
            };
            
            NLCheckbox *cbTC = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbTC.isOn = gTeamColorEnabled;
            cbTC.onToggle = ^(BOOL v) {
                gTeamColorEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Team Colors" y:hy control:cbTC swatch:swTeam]];
            hy += 30;
            
            NLColorSwatch *swVis = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swVis.color = gVisibleColor;
            __weak NLColorSwatch *weakSwVis = swVis;
            swVis.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwVis currentColor:weakSwVis.color saveKey:@"c_vis"];
            };
            
            NLCheckbox *cbVC = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbVC.isOn = gVisibleColorEnabled;
            cbVC.onToggle = ^(BOOL v) {
                gVisibleColorEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Visible Colors" y:hy control:cbVC swatch:swVis]];
            hy += 30;
            
            NLCheckbox *cbSB = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSB.isOn = gSnapBottomEnabled;
            cbSB.onToggle = ^(BOOL v) {
                gSnapBottomEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Snap From Bottom" y:hy control:cbSB swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbKF = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbKF.isOn = gKillFeedEnabled;
            cbKF.onToggle = ^(BOOL v) {
                gKillFeedEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Kill Feed" y:hy control:cbKF swatch:nil]];
            hy += 30;
            
            NLButton *bBoxStyle = [[NLButton alloc] initWithTitle:(gBoxStyle == 0 ? @"Full" : @"Corner")];
            __weak NLButton *weakBoxStyle = bBoxStyle;
            bBoxStyle.onTap = ^{
                int s = gBoxStyle;
                s = (s == 0) ? 1 : 0;
                gBoxStyle = s;
                [weakBoxStyle.titleLabel setText:(s == 0 ? @"Full" : @"Corner")];
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Box Style" y:hy control:bBoxStyle swatch:nil]];
            hy += 30;
            
            NLSlider *sSkel = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sSkel.min = 0.5f;
            sSkel.max = 4.0f;
            sSkel.value = gSkelThickness;
            sSkel.onChange = ^(float v) {
                gSkelThickness = v;
            };
            sSkel.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Skeleton Width" y:hy control:sSkel swatch:nil]];
            hy += 30;
            
            NLSlider *sRadarRange = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"m"];
            sRadarRange.min = 20.0f;
            sRadarRange.max = 150.0f;
            sRadarRange.value = (float)gRadarRange;
            sRadarRange.onChange = ^(float v) {
                gRadarRange = (int)v;
            };
            sRadarRange.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Radar Range" y:hy control:sRadarRange swatch:nil]];
            hy += 30;
            
            NLSlider *sRadarSize = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"px"];
            sRadarSize.min = 70.0f;
            sRadarSize.max = 220.0f;
            sRadarSize.value = gRadarSize;
            sRadarSize.onChange = ^(float v) {
                gRadarSize = v;
            };
            sRadarSize.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Radar Size" y:hy control:sRadarSize swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbRR = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbRR.isOn = gRadarRotate;
            cbRR.onToggle = ^(BOOL v) {
                gRadarRotate = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"Radar Rotate" y:hy control:cbRR swatch:nil]];
            hy += 30;
            
            NLCheckbox *cbFps = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbFps.isOn = gFpsEnabled;
            cbFps.onToggle = ^(BOOL v) {
                gFpsEnabled = v;
                [ConfigManager save];
            };
            [gHud addSubview:[[NLRow alloc] initWithTitle:@"FPS Graph" y:hy control:cbFps swatch:nil]];
            hy += 30;
            
        } else if (_currentTab == 2) {
            NLGroupBox *gWV = [[NLGroupBox alloc] initWithTitle:@"World View" frame:CGRectMake(0, 0, colW, 240)];
            [c1 addSubview:gWV];
            CGFloat y = 30;
            
            NLCheckbox *cbFB = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbFB.isOn = gFullbrightEnabled;
            cbFB.onToggle = ^(BOOL v) {
                gFullbrightEnabled = v;
                [ConfigManager save];
            };
            [gWV addSubview:[[NLRow alloc] initWithTitle:@"Fullbright" y:y control:cbFB swatch:nil]];
            y += 30;
            
            NLSlider *sFB = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"x"];
            sFB.min = 1.0f;
            sFB.max = 5.0f;
            sFB.value = gFullbrightMul;
            sFB.onChange = ^(float v) {
                gFullbrightMul = v;
            };
            sFB.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gWV addSubview:[[NLRow alloc] initWithTitle:@"Brightness" y:y control:sFB swatch:nil]];
            y += 30;
            
            NLCheckbox *cbNF = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbNF.isOn = gNoFogEnabled;
            cbNF.onToggle = ^(BOOL v) {
                gNoFogEnabled = v;
                [ConfigManager save];
            };
            [gWV addSubview:[[NLRow alloc] initWithTitle:@"No Fog" y:y control:cbNF swatch:nil]];
            y += 30;
            
            NLCheckbox *cbWE = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbWE.isOn = gWeaponEspEnabled;
            cbWE.onToggle = ^(BOOL v) {
                gWeaponEspEnabled = v;
                [ConfigManager save];
            };
            [gWV addSubview:[[NLRow alloc] initWithTitle:@"Weapon ESP" y:y control:cbWE swatch:nil]];
            y += 30;
            
            NLCheckbox *cbAmb = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbAmb.isOn = gAmbientTintEnabled;
            cbAmb.onToggle = ^(BOOL v) {
                gAmbientTintEnabled = v;
                [ConfigManager save];
            };
            
            NLColorSwatch *swAmb = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            uint32_t hAmb = gAmbientColorHex.load();
            swAmb.color = [UIColor colorWithRed:((hAmb >> 24) & 0xFF)/255.0 green:((hAmb >> 16) & 0xFF)/255.0 blue:((hAmb >> 8) & 0xFF)/255.0 alpha:((hAmb & 0xFF) & 0xFF)/255.0];
            __weak NLColorSwatch *weakSwAmb = swAmb;
            swAmb.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwAmb currentColor:weakSwAmb.color saveKey:@"wv_amb_c"];
            };
            
            [gWV addSubview:[[NLRow alloc] initWithTitle:@"Ambient Tint" y:y control:cbAmb swatch:swAmb]];
            y += 30;
            
            NLSlider *sSharp = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sSharp.min = 0.0f;
            sSharp.max = 1.0f;
            sSharp.value = gSharpenVal;
            sSharp.onChange = ^(float v) {
                gSharpenVal = v;
            };
            sSharp.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gWV addSubview:[[NLRow alloc] initWithTitle:@"Sharpen" y:y control:sSharp swatch:nil]];
            y += 30;
            
            NLSlider *sBloom = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sBloom.min = 0.0f;
            sBloom.max = 10.0f;
            sBloom.value = gBloomVal;
            sBloom.onChange = ^(float v) {
                gBloomVal = v;
                gGradingDirty = true;
            };
            sBloom.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gWV addSubview:[[NLRow alloc] initWithTitle:@"Bloom" y:y control:sBloom swatch:nil]];
            y += 30;
            
            NLGroupBox *gSky = [[NLGroupBox alloc] initWithTitle:@"Skybox Presets" frame:CGRectMake(0, 250, colW, 120)];
            [c1 addSubview:gSky];
            y = 30;
            
            NLColorSwatch *swSky = [[NLColorSwatch alloc] initWithFrame:CGRectMake(0,0,16,16)];
            swSky.color = [UIColor colorWithRed:((gSkyboxColorHex >> 24) & 0xFF)/255.0 green:((gSkyboxColorHex >> 16) & 0xFF)/255.0 blue:((gSkyboxColorHex >> 8) & 0xFF)/255.0 alpha:(gSkyboxColorHex & 0xFF)/255.0];
            __weak NLColorSwatch *weakSwSky = swSky;
            swSky.onTap = ^{
                [weakSelf showColorPickerForSwatch:weakSwSky currentColor:weakSwSky.color saveKey:@"v_sky_c"];
            };
            
            NLCheckbox *cbSky = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSky.isOn = gSkyboxEnabled;
            cbSky.onToggle = ^(BOOL v) {
                gSkyboxEnabled = v;
                gSkyboxDirty = true;
                [ConfigManager save];
            };
            [gSky addSubview:[[NLRow alloc] initWithTitle:@"Sky Color" y:y control:cbSky swatch:swSky]];
            y += 30;
            
            NSArray *presetNames = @[@"Sunset", @"Night", @"Neon", @"Haze", @"Blue"];
            CGFloat pw = (colW - 30 - 12) / 5.0;
            for (int i = 0; i < 5; i++) {
                UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
                b.frame = CGRectMake(15 + i * (pw + 3), y, pw, 20);
                b.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
                [b setTitle:presetNames[i] forState:UIControlStateNormal];
                [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                b.titleLabel.font = [UIFont systemFontOfSize:9];
                b.layer.cornerRadius = 3;
                b.tag = 2000 + i;
                [b addTarget:weakSelf action:@selector(skyPresetTap:) forControlEvents:UIControlEventTouchUpInside];
                [gSky addSubview:b];
            }
            
            NLGroupBox *gCG = [[NLGroupBox alloc] initWithTitle:@"Color Grading" frame:CGRectMake(0, 0, colW, 150)];
            [c2 addSubview:gCG];
            y = 30;
            
            NLSlider *sSat = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sSat.min = -100.0f;
            sSat.max = 100.0f;
            sSat.value = gSaturationVal;
            sSat.onChange = ^(float v) {
                gSaturationVal = v;
                gGradingDirty = true;
            };
            sSat.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gCG addSubview:[[NLRow alloc] initWithTitle:@"Saturation" y:y control:sSat swatch:nil]];
            y += 30;
            
            NLSlider *sCon = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sCon.min = -100.0f;
            sCon.max = 100.0f;
            sCon.value = gContrastVal;
            sCon.onChange = ^(float v) {
                gContrastVal = v;
                gGradingDirty = true;
            };
            sCon.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gCG addSubview:[[NLRow alloc] initWithTitle:@"Contrast" y:y control:sCon swatch:nil]];
            y += 30;
            
            NLSlider *sGam = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"EV"];
            sGam.min = -3.0f;
            sGam.max = 3.0f;
            sGam.value = gGammaVal;
            sGam.onChange = ^(float v) {
                gGammaVal = v;
                gGradingDirty = true;
            };
            sGam.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gCG addSubview:[[NLRow alloc] initWithTitle:@"Gamma" y:y control:sGam swatch:nil]];
            y += 30;
            
        } else if (_currentTab == 3) {
            NLGroupBox *gMove = [[NLGroupBox alloc] initWithTitle:@"Movement" frame:CGRectMake(0, 0, colW, 280)];
            [c1 addSubview:gMove];
            CGFloat y = 30;
            
            NLCheckbox *cbSH = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSH.isOn = gSpeedHackEnabled;
            cbSH.onToggle = ^(BOOL v) {
                gSpeedHackEnabled = v;
                [ConfigManager save];
            };
            [gMove addSubview:[[NLRow alloc] initWithTitle:@"Speed Hack" y:y control:cbSH swatch:nil]];
            y += 30;
            
            NLSlider *sSpd = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"x"];
            sSpd.min = 1.0f;
            sSpd.max = 5.0f;
            sSpd.value = gSpeedHackVal;
            sSpd.onChange = ^(float v) {
                gSpeedHackVal = v;
            };
            sSpd.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gMove addSubview:[[NLRow alloc] initWithTitle:@"Speed Multi" y:y control:sSpd swatch:nil]];
            y += 30;
            
            NLCheckbox *cbJH = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbJH.isOn = gJumpHackEnabled;
            cbJH.onToggle = ^(BOOL v) {
                gJumpHackEnabled = v;
                [ConfigManager save];
            };
            [gMove addSubview:[[NLRow alloc] initWithTitle:@"Jump Height" y:y control:cbJH swatch:nil]];
            y += 30;
            
            NLSlider *sJmp = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"x"];
            sJmp.min = 1.0f;
            sJmp.max = 5.0f;
            sJmp.value = gJumpHackVal;
            sJmp.onChange = ^(float v) {
                gJumpHackVal = v;
            };
            sJmp.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gMove addSubview:[[NLRow alloc] initWithTitle:@"Jump Multi" y:y control:sJmp swatch:nil]];
            y += 30;
            
            NLGroupBox *gWeapon = [[NLGroupBox alloc] initWithTitle:@"Weapon" frame:CGRectMake(0, 0, colW, 480)];
            [c2 addSubview:gWeapon];
            y = 30;
            
            NLCheckbox *cbRF = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbRF.isOn = gRapidFireEnabled;
            cbRF.onToggle = ^(BOOL v) {
                gRapidFireEnabled = v;
                [ConfigManager save];
            };
            [gWeapon addSubview:[[NLRow alloc] initWithTitle:@"Rapid Fire" y:y control:cbRF swatch:nil]];
            y += 30;
            
            NLCheckbox *cbIR = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbIR.isOn = gInstantReloadEnabled;
            cbIR.onToggle = ^(BOOL v) {
                gInstantReloadEnabled = v;
                [ConfigManager save];
            };
            [gWeapon addSubview:[[NLRow alloc] initWithTitle:@"Instant Reload" y:y control:cbIR swatch:nil]];
            y += 30;
            
            NLCheckbox *cbUA = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbUA.isOn = gUnlimAmmoEnabled;
            cbUA.onToggle = ^(BOOL v) {
                gUnlimAmmoEnabled = v;
                [ConfigManager save];
            };
            [gWeapon addSubview:[[NLRow alloc] initWithTitle:@"Unlim Ammo" y:y control:cbUA swatch:nil]];
            y += 30;
            
            NLCheckbox *cbNS = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbNS.isOn = gNoSpreadEnabled;
            cbNS.onToggle = ^(BOOL v) {
                gNoSpreadEnabled = v;
                [ConfigManager save];
            };
            [gWeapon addSubview:[[NLRow alloc] initWithTitle:@"No Spread" y:y control:cbNS swatch:nil]];
            y += 30;
            
            NLCheckbox *cbNR = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbNR.isOn = gNoRecoilEnabled;
            cbNR.onToggle = ^(BOOL v) {
                gNoRecoilEnabled = v;
                [ConfigManager save];
            };
            [gWeapon addSubview:[[NLRow alloc] initWithTitle:@"No Recoil" y:y control:cbNR swatch:nil]];
            y += 30;
            
            NLCheckbox *cbANS = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbANS.isOn = gAutoNoSpread;
            cbANS.onToggle = ^(BOOL v) {
                gAutoNoSpread = v;
                [ConfigManager save];
            };
            [gWeapon addSubview:[[NLRow alloc] initWithTitle:@"No Spread (Aimbot)" y:y control:cbANS swatch:nil]];
            y += 30;
            
            NLCheckbox *cbANR = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbANR.isOn = gAutoNoRecoil;
            cbANR.onToggle = ^(BOOL v) {
                gAutoNoRecoil = v;
                [ConfigManager save];
            };
            [gWeapon addSubview:[[NLRow alloc] initWithTitle:@"No Recoil (Aimbot)" y:y control:cbANR swatch:nil]];
            y += 30;
            
            NLCheckbox *cbSFE = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSFE.isOn = gSpreadFloorEnabled;
            cbSFE.onToggle = ^(BOOL v) {
                gSpreadFloorEnabled = v;
                [ConfigManager save];
            };
            [gWeapon addSubview:[[NLRow alloc] initWithTitle:@"Spread Floor" y:y control:cbSFE swatch:nil]];
            y += 30;
            
            NLSlider *sFloor = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sFloor.min = 0.0f;
            sFloor.max = 0.02f;
            sFloor.value = gSpreadFloor;
            sFloor.onChange = ^(float v) {
                gSpreadFloor = v;
            };
            sFloor.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gWeapon addSubview:[[NLRow alloc] initWithTitle:@"Floor Value" y:y control:sFloor swatch:nil]];
            y += 30;
            
            NLCheckbox *cbBD = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbBD.isOn = gBallisticsDebug;
            cbBD.onToggle = ^(BOOL v) {
                gBallisticsDebug = v;
                [ConfigManager save];
            };
            [gWeapon addSubview:[[NLRow alloc] initWithTitle:@"Ballistics Debug" y:y control:cbBD swatch:nil]];
            y += 30;
            
        } else if (_currentTab == 4) {
            NLGroupBox *gVis = [[NLGroupBox alloc] initWithTitle:@"World & View" frame:CGRectMake(0, 0, colW, 450)];
            [c1 addSubview:gVis];
            CGFloat y = 30;
            
            NLCheckbox *cbFOV = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbFOV.isOn = gCamFovEnabled;
            cbFOV.onToggle = ^(BOOL v) {
                gCamFovEnabled = v;
                [ConfigManager save];
            };
            [gVis addSubview:[[NLRow alloc] initWithTitle:@"Custom FOV" y:y control:cbFOV swatch:nil]];
            y += 30;
            
            NLSlider *sFov = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"°"];
            sFov.min = 60;
            sFov.max = 140;
            sFov.value = gCamFovVal;
            sFov.onChange = ^(float v) {
                gCamFovVal = v;
            };
            sFov.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gVis addSubview:[[NLRow alloc] initWithTitle:@"FOV Size" y:y control:sFov swatch:nil]];
            y += 30;
            
            NLCheckbox *cbVMFOV = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbVMFOV.isOn = gViewmodelFovEnabled;
            cbVMFOV.onToggle = ^(BOOL v) {
                gViewmodelFovEnabled = v;
                [ConfigManager save];
            };
            [gVis addSubview:[[NLRow alloc] initWithTitle:@"Hands FOV" y:y control:cbVMFOV swatch:nil]];
            y += 30;
            
            NLSlider *sVMFov = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@"°"];
            sVMFov.min = 30;
            sVMFov.max = 140;
            sVMFov.value = gViewmodelFovVal;
            sVMFov.onChange = ^(float v) {
                gViewmodelFovVal = v;
            };
            sVMFov.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gVis addSubview:[[NLRow alloc] initWithTitle:@"Hands FOV Size" y:y control:sVMFov swatch:nil]];
            y += 30;
            
            NLCheckbox *cbAsp = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbAsp.isOn = gAspectEnabled;
            cbAsp.onToggle = ^(BOOL v) {
                gAspectEnabled = v;
                [ConfigManager save];
            };
            [gVis addSubview:[[NLRow alloc] initWithTitle:@"Aspect Ratio" y:y control:cbAsp swatch:nil]];
            y += 30;
            
            NLSlider *sAsp = [[NLSlider alloc] initWithFrame:CGRectMake(0,0,120,18) suffix:@""];
            sAsp.min = 0.5f;
            sAsp.max = 2.5f;
            sAsp.value = gAspectVal;
            sAsp.onChange = ^(float v) {
                gAspectVal = v;
            };
            sAsp.onRelease = ^(float v) {
                [ConfigManager save];
            };
            [gVis addSubview:[[NLRow alloc] initWithTitle:@"Aspect Size" y:y control:sAsp swatch:nil]];
            y += 30;
            
            NLCheckbox *cbNM = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbNM.isOn = gNightModeEnabled;
            cbNM.onToggle = ^(BOOL v) {
                gNightModeEnabled = v;
                [ConfigManager save];
            };
            [gVis addSubview:[[NLRow alloc] initWithTitle:@"Nightmode" y:y control:cbNM swatch:nil]];
            y += 30;
            
        } else if (_currentTab == 5) {
            NLGroupBox *gSet = [[NLGroupBox alloc] initWithTitle:@"Settings" frame:CGRectMake(0, 0, colW, 270)];
            [c1 addSubview:gSet];
            CGFloat y = 30;
            
            NLCheckbox *cbSM = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbSM.isOn = gStreamMode;
            cbSM.onToggle = ^(BOOL v) {
                gStreamMode = v;
                UpdateStreamMode();
            };
            [gSet addSubview:[[NLRow alloc] initWithTitle:@"Stream Mode" y:y control:cbSM swatch:nil]];
            y += 30;
            
            NLCheckbox *cbHS = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHS.isOn = gHitSoundEnabled;
            cbHS.onToggle = ^(BOOL v) {
                gHitSoundEnabled = v;
                [ConfigManager save];
            };
            [gSet addSubview:[[NLRow alloc] initWithTitle:@"Hit Sound" y:y control:cbHS swatch:nil]];
            y += 30;
            
            NLButton *bSaveCfg = [[NLButton alloc] initWithTitle:@"Save Config"];
            bSaveCfg.onTap = ^{
                [ConfigManager save];
            };
            [gSet addSubview:[[NLRow alloc] initWithTitle:@"Config" y:y control:bSaveCfg swatch:nil]];
            y += 30;
            
            NLButton *bLoadCfg = [[NLButton alloc] initWithTitle:@"Load Config"];
            bLoadCfg.onTap = ^{
                [ConfigManager load];
                [weakSelf buildContent];
            };
            [gSet addSubview:[[NLRow alloc] initWithTitle:@"" y:y control:bLoadCfg swatch:nil]];
            y += 30;
            
            NLCheckbox *cbHA = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHA.isOn = gHotAimbotEnabled;
            cbHA.onToggle = ^(BOOL v) {
                gHotAimbotEnabled = v;
                [ConfigManager save];
            };
            [gSet addSubview:[[NLRow alloc] initWithTitle:@"Hotkey: Aimbot" y:y control:cbHA swatch:nil]];
            y += 30;
            
            NLCheckbox *cbHAF = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHAF.isOn = gHotAimOnFireEnabled;
            cbHAF.onToggle = ^(BOOL v) {
                gHotAimOnFireEnabled = v;
                [ConfigManager save];
            };
            [gSet addSubview:[[NLRow alloc] initWithTitle:@"Hotkey: Aim On Fire" y:y control:cbHAF swatch:nil]];
            y += 30;
            
            NLCheckbox *cbHES = [[NLCheckbox alloc] initWithFrame:CGRectMake(0,0,18,18)];
            cbHES.isOn = gHotEspEnabled;
            cbHES.onToggle = ^(BOOL v) {
                gHotEspEnabled = v;
                [ConfigManager save];
            };
            [gSet addSubview:[[NLRow alloc] initWithTitle:@"Hotkey: ESP" y:y control:cbHES swatch:nil]];
            y += 30;
        }
    } @catch (NSException* e) {
    }
}

- (void)togglePlayerChamsMenu:(UIButton*)sender {
    UIView *parent = sender.superview;
    UIView *sub = [parent viewWithTag:200];
    if (!sub) {
        return;
    }
    
    sub.hidden = !sub.hidden;
    [sender setTitle:(sub.hidden ? @"^" : @"v") forState:UIControlStateNormal];
}

- (void)toggleWeaponChamsMenu:(UIButton*)sender {
    UIView *parent = sender.superview;
    UIView *sub = [parent viewWithTag:201];
    if (!sub) {
        return;
    }
    
    sub.hidden = !sub.hidden;
    [sender setTitle:(sub.hidden ? @"^" : @"v") forState:UIControlStateNormal];
}

- (void)selectPlayerChamsMat:(UIButton*)sender {
    int idx = (int)sender.tag - 1000;
    if (idx < 0 || idx > 3) {
        return;
    }
    
    gChamsPlayerMatType = idx;
    [ConfigManager save];
    
    UIView *sub = sender.superview;
    for (UIView *v in sub.subviews) {
        if ([v isKindOfClass:[UIButton class]]) {
            UIButton *b = (UIButton*)v;
            int bidx = (int)b.tag - 1000;
            b.backgroundColor = (bidx == idx) ? [UIColor colorWithWhite:0.4 alpha:1.0] : [UIColor colorWithWhite:0.15 alpha:1.0];
        }
    }
    
    UIView *par = sub.superview;
    UIButton *chev = (UIButton*)[par viewWithTag:100];
    if (chev) {
        [chev setTitle:@"^" forState:UIControlStateNormal];
    }
    sub.hidden = YES;
}

- (void)selectWeaponChamsMat:(UIButton*)sender {
    int idx = (int)sender.tag - 1010;
    if (idx < 0 || idx > 3) {
        return;
    }
    
    gChamsWeaponMatType = idx;
    [ConfigManager save];
    
    UIView *sub = sender.superview;
    for (UIView *v in sub.subviews) {
        if ([v isKindOfClass:[UIButton class]]) {
            UIButton *b = (UIButton*)v;
            int bidx = (int)b.tag - 1010;
            b.backgroundColor = (bidx == idx) ? [UIColor colorWithWhite:0.4 alpha:1.0] : [UIColor colorWithWhite:0.15 alpha:1.0];
        }
    }
    
    UIView *par = sub.superview;
    UIButton *chev = (UIButton*)[par viewWithTag:101];
    if (chev) {
        [chev setTitle:@"^" forState:UIControlStateNormal];
    }
    sub.hidden = YES;
}

- (void)skyPresetTap:(UIButton*)sender {
    static const uint32_t kPresets[] = {0xFF8C42FF, 0x101828FF, 0xE040FBFF, 0x7B2FBEFF, 0x4A90D9FF};
    int idx = (int)sender.tag - 2000;
    if (idx < 0 || idx > 4) {
        return;
    }
    
    gSkyboxColorHex = kPresets[idx];
    gSkyboxEnabled = true;
    gSkyboxDirty = true;
    [ConfigManager save];
}

- (void)panAction:(UIPanGestureRecognizer*)p {
    CGPoint translation = [p translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [p setTranslation:CGPointZero inView:self.superview];
}

- (void)minimizeAction {
    _isMinimized = !_isMinimized;
    
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        if (self->_isMinimized) {
            self.frame = CGRectMake(self.frame.origin.x, self.frame.origin.y, self->_origFrame.size.width, 35);
            self->_content.hidden = YES;
        } else {
            self.frame = self->_origFrame;
            self->_content.hidden = NO;
        }
    } completion:nil];
}

- (void)closeAction {
    gMenuOpen = false;
    
    [UIView animateWithDuration:0.25 animations:^{
        self.transform = CGAffineTransformMakeScale(0.95, 0.95);
        self.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.hidden = YES;
        self.transform = CGAffineTransformIdentity;
        self.alpha = 1.0;
        gHotZone.hidden = NO;
        gEspView.hidden = NO;
        RefreshHotkeyView();
        gHotkeyView.hidden = gStreamMode;
        if (!gStreamMode) {
            gWatermark.hidden = NO;
        }
    }];
}

@end

// WORLD VIEW
static void SetVolParam(void* param, float v) {
    if (!SANE_PTR(param) || !alive(param) || !p_runtime_invoke) {
        return;
    }
    
    void* k = *(void**)param;
    void* mi = (k == gClampedFCls) ? p_cfaValMI : (k == gMinFCls) ? p_mfaValMI : (k == gFloatPCls) ? p_fpaValMI : nullptr;
    if (!mi) {
        return;
    }
    
    float val = v;
    void* args[1] = { &val };
    void* exc = nullptr;
    p_runtime_invoke(mi, param, args, &exc);
    
    if (!exc) {
        *(bool*)((uintptr_t)param + 0x10) = true; // m_OverrideState
    }
}

static void ForEachVolumeComponent(void* wantCls, void (*fn)(void*, void*), void* ctx) {
    if (!wantCls || !fn || !gVolumeTypeHandle || !p_runtime_invoke || !p_gchandle_get_target) {
        return;
    }
    
    void* to = p_gchandle_get_target(gVolumeTypeHandle);
    if (!SANE_PTR(to)) {
        return;
    }
    
    void* a[1] = {to};
    void* exc = nullptr;
    void* arr = p_runtime_invoke(p_findPlayerMI, nullptr, a, &exc);
    if (exc || !SANE_PTR(arr)) {
        return;
    }
    
    int len = *(int*)((uintptr_t)arr + 0x18);
    for (int i = 0; i < len && i < 64; i++) {
        void* v = *(void**)((uintptr_t)arr + 0x20 + i*8);
        if (!alive(v)) {
            continue;
        }
        
        void* profile = *(void**)((uintptr_t)v + 0x30); // sharedProfile
        if (!alive(profile)) {
            profile = *(void**)((uintptr_t)v + 0x48); // m_InternalProfile
        }
        if (!alive(profile)) {
            continue;
        }
        
        void* list = *(void**)((uintptr_t)profile + 0x18); // components
        if (!SANE_PTR(list)) {
            continue;
        }
        
        void* items = *(void**)((uintptr_t)list + 0x10); // _items
        if (!SANE_PTR(items)) {
            continue;
        }
        
        int n = *(int*)((uintptr_t)items + 0x18); // _size
        for (int j = 0; j < n && j < 32; j++) {
            void* comp = *(void**)((uintptr_t)items + 0x20 + j*8);
            if (alive(comp) && *(void**)comp == wantCls) {
                fn(comp, ctx);
            }
        }
    }
}

static void ApplyGradingToComponent(void* comp, void* ctx) {
    SetVolParam(*(void**)((uintptr_t)comp + 0x58), gSaturationVal.load()); // saturation
    SetVolParam(*(void**)((uintptr_t)comp + 0x40), gContrastVal.load());   // contrast
    SetVolParam(*(void**)((uintptr_t)comp + 0x38), gGammaVal.load());      // postExposure (EV100)
}

static void ApplyBloomToComponent(void* comp, void* ctx) {
    SetVolParam(*(void**)((uintptr_t)comp + 0x48), gBloomVal.load()); // intensity
}

static void ApplyWorldView(void) {
    @try {
        bool fb = gFullbrightEnabled.load();
        bool amb = gAmbientTintEnabled.load();
        bool needLights = fb || amb || s_fbWas || s_ambWas;
        
        if (needLights && gLightTypeHandle && p_lightGetIntensity && p_lightSetIntensity && p_lightGetColor && p_lightSetColor) {
            void* to = p_gchandle_get_target(gLightTypeHandle);
            if (SANE_PTR(to)) {
                void* a[1] = {to};
                void* exc = nullptr;
                void* arr = p_runtime_invoke(p_findPlayerMI, nullptr, a, &exc);
                if (!exc && SANE_PTR(arr)) {
                    int len = *(int*)((uintptr_t)arr + 0x18);
                    float mul = gFullbrightMul.load();
                    uint32_t hex = gAmbientColorHex.load();
                    UnityColor tc(((hex >> 24) & 0xFF) / 255.0f, ((hex >> 16) & 0xFF) / 255.0f, ((hex >> 8) & 0xFF) / 255.0f, 1.0f);
                    
                    for (int i = 0; i < len && i < 128; i++) {
                        void* l = *(void**)((uintptr_t)arr + 0x20 + i*8);
                        if (!alive(l)) {
                            continue;
                        }
                        
                        auto it = gLightOrig.find(l);
                        if (it == gLightOrig.end()) {
                            SavedLight sl;
                            sl.i = p_lightGetIntensity(l, p_lightGetIntensityMI);
                            sl.c = p_lightGetColor(l, p_lightGetColorMI);
                            gLightOrig[l] = sl;
                            it = gLightOrig.find(l);
                        }
                        
                        float wantI = it->second.i;
                        UnityColor wantC = it->second.c;
                        if (fb) {
                            wantI = it->second.i * mul;
                        }
                        if (amb) {
                            wantC = tc;
                        }
                        
                        float curI = p_lightGetIntensity(l, p_lightGetIntensityMI);
                        if (std::isfinite(wantI) && std::isfinite(curI) && fabsf(curI - wantI) > 0.05f) {
                            p_lightSetIntensity(l, wantI, p_lightSetIntensityMI);
                        }
                        
                        UnityColor curC = p_lightGetColor(l, p_lightGetColorMI);
                        if (fabsf(curC.r - wantC.r) > 0.02f || fabsf(curC.g - wantC.g) > 0.02f || fabsf(curC.b - wantC.b) > 0.02f) {
                            p_lightSetColor(l, wantC, p_lightSetColorMI);
                        }
                    }
                }
            }
        }
        s_fbWas = fb;
        s_ambWas = amb;
        
        if (!fb && !amb && !s_fbWas && !s_ambWas && p_renderSetAmbientLight && s_origAmbientInit) {
            p_renderSetAmbientLight(gSkyboxCls, s_origAmbient, p_renderGetAmbientLightMI);
        }
        
        bool nf = gNoFogEnabled.load();
        if (nf != s_nfWas && p_setFogMI && p_getFogMI) {
            if (!s_fogOrigInit) {
                s_fogOrig = p_getFog(p_getFogMI);
                s_fogOrigInit = true;
            }
            p_setFog(nf ? false : s_fogOrig, p_setFogMI);
            s_nfWas = nf;
        }
        
        if (amb && p_renderSetAmbientLight) {
            if (!s_origAmbientInit && p_renderGetAmbientLight) {
                s_origAmbient = p_renderGetAmbientLight(gSkyboxCls);
                s_origAmbientInit = true;
            }
            uint32_t hex = gAmbientColorHex.load();
            UnityColor tc(((hex >> 24) & 0xFF) / 255.0f, ((hex >> 16) & 0xFF) / 255.0f, ((hex >> 8) & 0xFF) / 255.0f, 1.0f);
            p_renderSetAmbientLight(gSkyboxCls, tc, p_renderGetAmbientLightMI);
        } else if (fb && p_renderSetAmbientLight) {
            if (!s_origAmbientInit && p_renderGetAmbientLight) {
                s_origAmbient = p_renderGetAmbientLight(gSkyboxCls);
                s_origAmbientInit = true;
            }
            UnityColor tc(1.0f, 1.0f, 1.0f, 1.0f);
            p_renderSetAmbientLight(gSkyboxCls, tc, p_renderGetAmbientLightMI);
        } else if (!amb && !fb && s_origAmbientInit && p_renderSetAmbientLight) {
            p_renderSetAmbientLight(gSkyboxCls, s_origAmbient, p_renderGetAmbientLightMI);
        }
        
        if (gGradingDirty.load()) {
            gGradingDirty = false;
            ForEachVolumeComponent(gColorAdjCls, ApplyGradingToComponent, nullptr);
            ForEachVolumeComponent(gBloomCls, ApplyBloomToComponent, nullptr);
        }
        
        float sharp = gSharpenVal.load();
        if (sharp > 0.01f && SANE_PTR(g_localCamera) && alive(g_localCamera) && gCamDataCls && gCamDataTypeHandle && p_getCompsInChildrenMI) {
            void* go = p_getGameObject ? p_getGameObject(g_localCamera, p_getGameObjectMI) : nullptr;
            if (alive(go)) {
                void* to = p_gchandle_get_target(gCamDataTypeHandle);
                if (SANE_PTR(to)) {
                    bool incInactive = false;
                    void* args[2] = { to, &incInactive };
                    void* exc = nullptr;
                    void* rArr = p_runtime_invoke(p_getCompsInChildrenMI, go, args, &exc);
                    if (!exc && SANE_PTR(rArr)) {
                        int n = *(int*)((uintptr_t)rArr + 0x18);
                        if (n > 0) {
                            void* cd = *(void**)((uintptr_t)rArr + 0x20);
                            if (alive(cd)) {
                                if (*(int*)((uintptr_t)cd + 0x50) == 0) { // m_Antialiasing: None -> TAA
                                    *(int*)((uintptr_t)cd + 0x50) = 3;
                                }
                                *(float*)((uintptr_t)cd + 0xB4) = sharp; // m_TaaSettings.m_ContrastAdaptiveSharpening
                            }
                        }
                    }
                }
            }
        }
    } @catch (NSException* e) {
    }
}

static void ApplyNightMode(void) {
    @try {
        if (!p_findVolumeMI || !gVolumeTypeHandle) {
            return;
        }
        
        void* to = p_gchandle_get_target(gVolumeTypeHandle);
        if (!to) {
            return;
        }
        
        void* a[1] = {to};
        void* exc = nullptr;
        void* arr = p_runtime_invoke(p_findVolumeMI, nullptr, a, &exc);
        
        if (exc || !arr) {
            return;
        }
        
        int len = *(int*)((uintptr_t)arr + 0x18);
        if (len <= 0) {
            return;
        }
        
        float targetWeight = gNightModeEnabled ? 0.0f : 1.0f;
        
        for (int i = 0; i < len && i < 64; i++) {
            void* v = *(void**)((uintptr_t)arr + 0x20 + i*8);
            if (!alive(v)) {
                continue;
            }
            
            float* w = (float*)((uintptr_t)v + off::kVolumeWeight);
            *w = targetWeight;
        }
    } @catch (NSException* e) {
    }
}

static void espTick(void) {
    @autoreleasepool {
        uint64_t curTime = mach_absolute_time();
        if (gLastFrameTime > 0) {
            uint64_t delta = curTime - gLastFrameTime;
            float dt = (float)delta / 1000000000.0f;
            if (dt > 0.0f) {
                float instantFps = 1.0f / dt;
                gCurrentFps = gCurrentFps * 0.9f + instantFps * 0.1f;
            }
        }
        gLastFrameTime = curTime;
        
        if (gWatermark) {
            [gWatermark updateFps:gCurrentFps];
        }
        
        if (!gAttached || !p_runtime_invoke || !p_findPlayerMI) {
            return;
        }
        
        uint64_t tMs = curTime / 1000000ULL;
        if (tMs - gLastNight > 500) {
            gLastNight = tMs;
            ApplyNightMode();
        }
        
        if (tMs - gLastWorld > 500) {
            gLastWorld = tMs;
            ApplyWorldView();
        }
        
        if (tMs - gLastP > 500) {
            gLastP = tMs;
            void* to = p_gchandle_get_target(gPlayerTypeHandle);
            if (to) {
                void* a[1] = {to};
                void* exc = nullptr;
                void* arr = p_runtime_invoke(p_findPlayerMI, nullptr, a, &exc);
                if (!exc && arr) {
                    int len = *(int*)((uintptr_t)arr + 0x18);
                    if (len > 0) {
                        gCached.clear();
                        gLocal = nullptr;
                        gTeam = 0;
                        for (int i = 0; i < len && i < 500; i++) {
                            void* p = *(void**)((uintptr_t)arr + 0x20 + i*8);
                            if (!alive(p)) {
                                continue;
                            }
                            gCached.push_back(p);
                            void* ni = *(void**)((uintptr_t)p + 0x38);
                            if (alive(ni) && *(bool*)((uintptr_t)ni + 0x22)) {
                                gLocal = p;
                                gTeam = *(int*)((uintptr_t)p + off::kPlayerTeam);
                            }
                        }
                        
                        for (auto it = gLastEnemyHealth.begin(); it != gLastEnemyHealth.end(); ) {
                            bool found = false;
                            for (void* q : gCached) {
                                if (q == it->first) {
                                    found = true;
                                    break;
                                }
                            }
                            if (!found) {
                                it = gLastEnemyHealth.erase(it);
                            } else {
                                ++it;
                            }
                        }
                    }
                }
            }
        }
        
        if (!alive(gLocal)) {
            return;
        }
        
        void* cam = nullptr;
        void* slc = nullptr;
        void* lcLocal = nullptr;
        void* lch = *(void**)((uintptr_t)gLocal + off::kPlayerCharacter);
        g_localChar = lch;
        
        if (alive(lch)) {
            lcLocal = *(void**)((uintptr_t)lch + off::kCharController);
            if (alive(lcLocal)) {
                slc = *(void**)((uintptr_t)lcLocal + off::kLocalCamera);
                if (alive(slc)) {
                    cam = *(void**)((uintptr_t)slc + off::kCamComponent);
                }
            }
        }
        
        if (!alive(cam)) {
            return;
        }
        
        g_localSceneChar = slc;
        g_localCamera = cam;
        
        if (alive(lch)) {
            void* ctrl = *(void**)((uintptr_t)lch + off::kCharController);
            if (alive(ctrl)) {
                g_localCC = *(void**)((uintptr_t)ctrl + off::kCtrlCC);
                g_localWeapon = *(void**)((uintptr_t)ctrl + off::kCtrlEquip);
            }
            void* mc = *(void**)((uintptr_t)lch + off::kCharModelContainer);
            if (alive(mc) && p_getTransform) {
                g_localTransform = p_getTransform(mc, p_getTransformMI);
            }
        }
        
        g_localEye = Vec3{0,0,0};
        if (alive(cam) && p_getTransform) {
            g_localCamTransform = p_getTransform(cam, p_getTransformMI);
            if (alive(g_localCamTransform)) {
                getPosFast(g_localCamTransform, g_localEye);
            }
        }
        
        if (gSkyboxDirty && gSkyboxEnabled && p_getSkybox && p_matSetColor && p_string_new) {
            void* skyMat = p_getSkybox(p_getSkyboxMI);
            if (alive(skyMat)) {
                uint32_t hex = gSkyboxColorHex.load();
                float r = ((hex >> 24) & 0xFF) / 255.0f;
                float g = ((hex >> 16) & 0xFF) / 255.0f;
                float b = ((hex >> 8) & 0xFF) / 255.0f;
                float a = (hex & 0xFF) / 255.0f;
                
                UnityColor col(r, g, b, a);
                void* strTint = p_string_new("_Tint");
                void* strColor = p_string_new("_Color");
                void* strBaseColor = p_string_new("_BaseColor");
                void* strSkyColor = p_string_new("_SkyColor");
                
                if (strTint) p_matSetColor(skyMat, strTint, col, p_matSetColorMI);
                if (strColor) p_matSetColor(skyMat, strColor, col, p_matSetColorMI);
                if (strBaseColor) p_matSetColor(skyMat, strBaseColor, col, p_matSetColorMI);
                if (strSkyColor) p_matSetColor(skyMat, strSkyColor, col, p_matSetColorMI);
            }
            gSkyboxDirty = false;
        }
        
        float cw = 0, ch = 0;
        if (p_camGetPixelWidth) cw = (float)p_camGetPixelWidth(cam, p_camGetPixelWidthMI);
        if (p_camGetPixelHeight) ch = (float)p_camGetPixelHeight(cam, p_camGetPixelHeightMI);
        
        float sX = 1.0f, sY = 1.0f;
        if (cw > 0 && ch > 0) {
            sX = (gScreenPts.width * gScreenScale) / cw;
            sY = (gScreenPts.height * gScreenScale) / ch;
        }
        
        [gEspView.boxes removeAllObjects];
        [gEspView.labels removeAllObjects];
        [gEspView.hps removeAllObjects];
        [gEspView.armors removeAllObjects];
        [gEspView.skeletonLines removeAllObjects];
        [gEspView.nameTexts removeAllObjects];
        [gEspView.names removeAllObjects];
        [gEspView.tracers removeAllObjects];
        [gEspView.oofDirs removeAllObjects];
        [gEspView.weaponBoxes removeAllObjects];
        [gEspView.weaponLabels removeAllObjects];
        [gEspView.headDots removeAllObjects];
        [gEspView.snapLines removeAllObjects];
        [gEspView.boxColors removeAllObjects];
        [gEspView.healthTexts removeAllObjects];
        
        HudBeginFrame();
        
        float localYaw = 0.0f;
        if (alive(g_localCamTransform) && p_tfGetEuler) {
            Vec3 le = p_tfGetEuler(g_localCamTransform, p_tfGetEulerMI);
            if (Math::Finite(le)) {
                localYaw = le.y;
            }
        }
        
        void* best = nullptr;
        float bestScore = 99999.0f;
        Vec3 bestAimPos = {0,0,0};
        
        CGFloat screenCx = gScreenPts.width / 2.0f;
        CGFloat screenCy = gScreenPts.height / 2.0f;
        
        uint64_t nowMs = NowMs();
        
        if (alive(g_localWeapon)) {
            int ammo = *(int*)((uintptr_t)g_localWeapon + off::kWepAmmo);
            if (gLastLocalAmmo != -1 && ammo < gLastLocalAmmo) {
                g_lastLocalShotMs = nowMs;
            }
            gLastLocalAmmo = ammo;
        } else {
            gLastLocalAmmo = -1;
        }

        uint64_t sinceShot = nowMs - g_lastLocalShotMs.load();
        bool recentShot = sinceShot < 500;
        
        for (void* p : gCached) {
            if (!alive(p) || p == gLocal) {
                continue;
            }
            if (*(bool*)((uintptr_t)p + off::kPlayerIsDead)) {
                continue;
            }
            
            int tm = *(int*)((uintptr_t)p + off::kPlayerTeam);
            bool enemyTeam = !(gAimbotNoTeam && tm == gTeam && gTeam >= 0);
            
            void* c = *(void**)((uintptr_t)p + off::kPlayerCharacter);
            if (!alive(c)) {
                continue;
            }
            
            if (gRadarEnabled) {
                void* rmc = *(void**)((uintptr_t)c + off::kCharModelContainer);
                if (alive(rmc)) {
                    Vec3 rfp;
                    if (getPosFast(rmc, rfp)) {
                        float rdx = rfp.x - g_localEye.x;
                        float rdz = rfp.z - g_localEye.z;
                        float yawRad = gRadarRotate ? (-localYaw * Math::DEG2RAD) : 0.0f;
                        float rx = rdx * cosf(yawRad) - rdz * sinf(yawRad);
                        float rz = rdx * sinf(yawRad) + rdz * cosf(yawRad);
                        HudAddRadar(rx, rz, tm, *(bool*)((uintptr_t)p + off::kPlayerIsDead));
                    }
                }
            }
            
            int damageDelta = 0;
            if (enemyTeam) {
                int curH = *(int*)((uintptr_t)c + off::kCharHealth);
                auto it = gLastEnemyHealth.find(p);
                if (it != gLastEnemyHealth.end()) {
                    int prevH = it->second;
                    
                    if (prevH > 0 && curH < prevH && recentShot) {
                        damageDelta = prevH - curH;
                        gHudHitMarkerUntil = nowMs + 220;
                        gHudHitMarkerDamage = damageDelta;
                        
                        if (curH == 0) {
                            if (gKillSoundEnabled) {
                                PlayKillSound();
                            }
                            
                            void* nickObj = *(void**)((uintptr_t)p + off::kPlayerNickName);
                            NSString* nick = getIL2CPPString(nickObj);
                            if (nick && nick.length > 0 && gKillFeedEnabled) {
                                HudAddKill([nick UTF8String], nowMs + 6000);
                            }
                        } else if (gHitSoundEnabled) {
                            if (nowMs - g_lastHitSoundTime > 100) {
                                g_lastHitSoundTime = nowMs;
                                PlayHitSound();
                            }
                        }
                    }
                }
                gLastEnemyHealth[p] = curH;
            }
            
            if (*(bool*)((uintptr_t)c + off::kCharIsDead)) {
                continue;
            }
            int health = *(int*)((uintptr_t)c + off::kCharHealth);
            if (health <= 0) {
                continue;
            }
            
            if (gAimbotNoTeam && tm == gTeam && gTeam >= 0) {
                continue;
            }
            
            void* mc = *(void**)((uintptr_t)c + off::kCharModelContainer);
            if (!alive(mc)) {
                continue;
            }
            
            Vec3 fp;
            if (!getPosFast(mc, fp)) {
                continue;
            }
            
            Vec3 hpv = fp;
            void* model = nullptr;
            void* ct = *(void**)((uintptr_t)c + off::kCharController);
            
            if (alive(ct)) {
                void* rv = *(void**)((uintptr_t)ct + off::kOtherRemoteVis);
                if (alive(rv)) {
                    model = *(void**)((uintptr_t)rv + off::kRvModel);
                    if (alive(model)) {
                        void* ht = *(void**)((uintptr_t)model + off::kModelHead);
                        if (alive(ht)) {
                            Vec3 h;
                            if (getPosFast(ht, h)) {
                                hpv = h;
                            }
                        }
                    }
                }
            }
            
            if (hpv.y <= fp.y) {
                hpv.y = fp.y + 1.6f;
            }
            
            Vec3 aimPos = hpv;
            if (alive(model) && p_getBoneTransform) {
                void* animator = *(void**)((uintptr_t)model + off::kModelAnimator);
                if (alive(animator)) {
                    int aimBone = gAimBone.load();
                    void* aimTransform = p_getBoneTransform(animator, aimBone, p_getBoneTransformMI);
                    if (alive(aimTransform)) {
                        Vec3 selectedBonePos;
                        if (getPosFast(aimTransform, selectedBonePos) && Math::Finite(selectedBonePos)) {
                            aimPos = selectedBonePos;
                        }
                    }
                }
            }

            float dx = fp.x - g_localEye.x;
            float dy = fp.y - g_localEye.y;
            float dz = fp.z - g_localEye.z;
            float realDist = sqrtf(dx*dx + dy*dy + dz*dz);
            
            if (!std::isfinite(realDist) || realDist > 300.0f) {
                continue;
            }
            
            bool isVisible = true;
            bool needVisCheck = gAimbotVisibleOnly ||
                                (gVisibleColorEnabled && (gEspEnabled || gHotEspEnabled));
            if (needVisCheck && p_CheckSeen && g_localSceneChar) {
                if (!p_CheckSeen(g_localSceneChar, aimPos, p_checkSeenMI)) {
                    isVisible = false;
                }
            }
            
            bool espVisible = false;
            if (gEspEnabled || gHotEspEnabled) {
                Vec3 sf, sh;
                if (w2sFast(cam, fp, sf) && w2sFast(cam, hpv, sh) && sf.z > 0.05f && sh.z > 0.05f) {
                    float xh = (sh.x * sX) / gScreenScale;
                    float yh = gScreenPts.height - ((sh.y * sY) / gScreenScale);
                    float yf = gScreenPts.height - ((sf.y * sY) / gScreenScale);
                    
                    float tp = fminf(yh, yf);
                    float bt2 = fmaxf(yh, yf);
                    float bh = bt2 - tp;
                    float bw = bh * 0.55f;
                    float xx = xh - bw/2;
                    float yy = tp;
                    
                    if (bh > 10 && xx >= -100 && xx <= gScreenPts.width + 100 && yy >= -100 && yy <= gScreenPts.height + 100) {
                        espVisible = true;
                        int hh = *(int*)((uintptr_t)c + off::kCharHealth);
                        int aa = *(int*)((uintptr_t)c + off::kCharArmor);
                        
                        UIColor* boxColor = gBoxColor;
                        if (gTeamColorEnabled) {
                            boxColor = gTeamColor;
                        }
                        if (gVisibleColorEnabled) {
                            boxColor = isVisible ? gVisibleColor : gHiddenColor;
                        }
                        
                        [gEspView.boxes addObject:[NSValue valueWithCGRect:CGRectMake(xx, yy, bw, bh)]];
                        [gEspView.labels addObject:SafeFmt(@"%.0fm", realDist)];
                        [gEspView.hps addObject:@(hh > 0 ? hh : 0)];
                        [gEspView.armors addObject:@(aa > 0 ? aa : 0)];
                        [gEspView.boxColors addObject:(boxColor ?: [UIColor redColor])];
                        [gEspView.headDots addObject:[NSValue valueWithCGPoint:CGPointMake(xh, yh)]];
                        
                        if (gSnapBottomEnabled) {
                            [gEspView.snapLines addObject:[NSValue valueWithCGPoint:CGPointMake(xh, yh)]];
                        }
                        
                        if (gHealthTextEnabled) {
                            [gEspView.healthTexts addObject:SafeFmt(@"%d", hh > 0 ? hh : 0)];
                        }
                        
                        HudPlayerInfo hpi;
                        hpi.box = CGRectMake(xx, yy, bw, bh);
                        hpi.head = CGPointMake(xh, yh);
                        hpi.feet = CGPointMake(xh, yf);
                        hpi.health = hh > 0 ? hh : 0;
                        hpi.armor = aa > 0 ? aa : 0;
                        hpi.team = tm;
                        hpi.visible = isVisible;
                        hpi.distance = realDist;
                        HudAddPlayer(hpi);
                        
                        if (damageDelta > 0 && gDamageNumbersEnabled) {
                            HudAddDamage(CGPointMake(xh, yh - 12.0f), damageDelta, nowMs + 900);
                        }
                        
                        if (gNameEnabled) {
                            void* nickObj = *(void**)((uintptr_t)p + off::kPlayerNickName);
                            NSString* nick = getIL2CPPString(nickObj);
                            if (nick && nick.length > 0) {
                                [gEspView.names addObject:nick];
                                [gEspView.nameTexts addObject:[NSValue valueWithCGPoint:CGPointMake(xx + bw/2, yy - 14)]];
                            }
                        }
                        
                        if (gTracersEnabled) {
                            [gEspView.tracers addObject:[NSValue valueWithCGPoint:CGPointMake(xh, yh)]];
                        }
                    }
                }
            }
            
            if (gOofEnabled && !espVisible) {
                Vec3 sf;
                if (w2sFast(cam, fp, sf)) {
                    CGFloat sx = (sf.x * sX) / gScreenScale;
                    CGFloat sy = gScreenPts.height - ((sf.y * sY) / gScreenScale);
                    CGFloat ddx = sx - screenCx;
                    CGFloat ddy = sy - screenCy;
                    float len = sqrtf(ddx*ddx + ddy*ddy);
                    if (len > 1) {
                        [gEspView.oofDirs addObject:[NSValue valueWithCGPoint:CGPointMake(ddx/len, ddy/len)]];
                    }
                }
            }
            
            if (gSkeletonEnabled && alive(model)) {
                void* an = *(void**)((uintptr_t)model + off::kModelAnimator);
                if (alive(an) && p_getBoneTransform) {
                    int bn[] = {0,7,8,9,10,11,12,13,14,15,16,17,18,1,2,3,4,5,6};
                    CGPoint sb[19];
                    bool vb[19];
                    
                    for (int i = 0; i < 19; i++) {
                        vb[i] = false;
                        void* bt = p_getBoneTransform(an, bn[i], p_getBoneTransformMI);
                        if (alive(bt)) {
                            Vec3 wp;
                            if (getPosFast(bt, wp)) {
                                Vec3 sp;
                                if (w2sFast(cam, wp, sp) && sp.z > 0.05f) {
                                    sb[i] = CGPointMake((sp.x * sX) / gScreenScale, gScreenPts.height - ((sp.y * sY) / gScreenScale));
                                    vb[i] = true;
                                }
                            }
                        }
                    }
                    
                    int cn[][2] = {{4,3},{3,2},{2,1},{1,0},{1,5},{5,7},{7,9},{9,11},{1,6},{6,8},{8,10},{10,12},{0,13},{13,15},{15,17},{0,14},{14,16},{16,18}};
                    for (int i = 0; i < 18; i++) {
                        int a = cn[i][0];
                        int b = cn[i][1];
                        if (vb[a] && vb[b]) {
                            [gEspView.skeletonLines addObject:[NSValue valueWithCGRect:CGRectMake(sb[a].x, sb[a].y, sb[b].x, sb[b].y)]];
                        }
                    }
                }
            }
            
            if (gWeaponEspEnabled && alive(c)) {
                void* ctrl = *(void**)((uintptr_t)c + off::kCharController);
                if (alive(ctrl)) {
                    void* rv = *(void**)((uintptr_t)ctrl + off::kOtherRemoteVis);
                    if (alive(rv)) {
                        void* itemView = *(void**)((uintptr_t)rv + off::kRvItemView);
                        if (alive(itemView)) {
                            void* itemModel = *(void**)((uintptr_t)itemView + 0x38);
                            if (alive(itemModel)) {
                                void* weaponGO = *(void**)((uintptr_t)itemModel + 0x28);
                                if (alive(weaponGO) && p_getTransform) {
                                    void* wt = p_getTransform(weaponGO, p_getTransformMI);
                                    if (alive(wt)) {
                                        Vec3 wp;
                                        if (getPosFast(wt, wp)) {
                                            Vec3 sp;
                                            if (w2sFast(cam, wp, sp) && sp.z > 0.05f) {
                                                float sx = (sp.x * sX) / gScreenScale;
                                                float sy = gScreenPts.height - ((sp.y * sY) / gScreenScale);
                                                float sz = 10.0f;
                                                [gEspView.weaponBoxes addObject:[NSValue valueWithCGRect:CGRectMake(sx - sz/2, sy - sz/2, sz, sz)]];
                                                [gEspView.weaponLabels addObject:@"Weapon"];
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            if (gAimbotEnabled || gAimOnFireEnabled || gSilentAimEnabled) {
                if (gAimbotVisibleOnly && !isVisible) {
                    continue;
                }
                
                Vec3 sa;
                if (w2sFast(cam, aimPos, sa) && sa.z > 0.05f) {
                    float sx = (sa.x * sX) / gScreenScale;
                    float sy = gScreenPts.height - ((sa.y * sY) / gScreenScale);
                    float screenDist = sqrtf((sx - screenCx) * (sx - screenCx) + (sy - screenCy) * (sy - screenCy));
                    
                    if (screenDist < (float)gAimbotFovPx && screenDist < bestScore) {
                        bestScore = screenDist;
                        best = c;
                        bestAimPos = aimPos;
                    }
                }
            }
        }
        
        if ((gAimbotEnabled || gAimOnFireEnabled || gSilentAimEnabled) && best && alive(slc) && alive(lcLocal)) {
            g_silentAimTarget = bestAimPos;
            g_silentAimActive = true;
            g_targetHead = bestAimPos;
            g_haveTarget = true;
        } else {
            g_silentAimActive = false;
            g_haveTarget = false;
        }
        
        if (gAimLineEnabled && g_haveTarget) {
            Vec3 sa;
            if (w2sFast(cam, bestAimPos, sa) && sa.z > 0.05f) {
                CGFloat ax = (sa.x * sX) / gScreenScale;
                CGFloat ay = gScreenPts.height - ((sa.y * sY) / gScreenScale);
                HudSetAimLine(true, CGPointMake(ax, ay));
            } else {
                HudSetAimLine(false, CGPointMake(0, 0));
            }
        } else {
            HudSetAimLine(false, CGPointMake(0, 0));
        }
        
        bool localAiming = false;
        float localSpread = 0.0f;
        if (alive(g_localWeapon) && IsRangeWeapon(g_localWeapon)) {
            localAiming = *(bool*)((uintptr_t)g_localWeapon + off::kWepIsAiming);
            Vec2 sp = *(Vec2*)((uintptr_t)g_localWeapon + off::kWepSpread);
            if (Math::Finite(sp.x) && Math::Finite(sp.y)) {
                localSpread = sqrtf(sp.x * sp.x + sp.y * sp.y);
            }
        }
        HudSetCrosshair(6.0f + localSpread * 160.0f, gCrosshairEnabled);
        HudSetScope(localAiming && gScopeOverlayEnabled);
        HudTick();
        
        [gEspView setNeedsDisplay];
    }
}

@interface ESPDriver : NSObject
@end

@implementation ESPDriver

- (void)tick:(CADisplayLink*)link {
    @try {
        espTick();
    } @catch (NSException* e) {
        LOG(@"espTick: %@", SafeStr([e reason]));
    }
}

@end

static ESPDriver* gDriver = nil;
static CADisplayLink* gLink = nil;

@interface HotkeyView : UIView
@property (nonatomic, strong) UIButton *hkbAimbot;
@property (nonatomic, strong) UIButton *hkbAimFire;
@property (nonatomic, strong) UIButton *hkbEsp;
@property (nonatomic, strong) UILabel *dragHandle;
- (void)updateTitles;
@end

@implementation HotkeyView {
    CGPoint _panStartOrigin;
}

- (instancetype)initWithFrame:(CGRect)f {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"hk_x"] && [defaults objectForKey:@"hk_y"]) {
        f.origin = CGPointMake([defaults doubleForKey:@"hk_x"], [defaults doubleForKey:@"hk_y"]);
    }

    self = [super initWithFrame:f];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        
        CGFloat btnW = 54, btnH = 20, gap = 5;
        CGFloat startX = 8, startY = 14;
        self.dragHandle = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, 12)];
        self.dragHandle.text = @"MOVE";
        self.dragHandle.textAlignment = NSTextAlignmentCenter;
        self.dragHandle.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
        self.dragHandle.font = [UIFont boldSystemFontOfSize:7];
        self.dragHandle.userInteractionEnabled = YES;
        [self addSubview:self.dragHandle];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panAction:)];
        [self.dragHandle addGestureRecognizer:pan];
        
        self.hkbAimbot = [UIButton buttonWithType:UIButtonTypeSystem];
        self.hkbAimbot.frame = CGRectMake(startX, startY, btnW, btnH);
        self.hkbAimbot.titleLabel.font = [UIFont boldSystemFontOfSize:8];
        self.hkbAimbot.layer.cornerRadius = 3;
        [self.hkbAimbot setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.hkbAimbot addTarget:self action:@selector(tapAimbot) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.hkbAimbot];
        
        self.hkbAimFire = [UIButton buttonWithType:UIButtonTypeSystem];
        self.hkbAimFire.frame = CGRectMake(startX, startY + btnH + gap, btnW, btnH);
        self.hkbAimFire.titleLabel.font = [UIFont boldSystemFontOfSize:8];
        self.hkbAimFire.layer.cornerRadius = 3;
        [self.hkbAimFire setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.hkbAimFire addTarget:self action:@selector(tapAimFire) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.hkbAimFire];
        
        self.hkbEsp = [UIButton buttonWithType:UIButtonTypeSystem];
        self.hkbEsp.frame = CGRectMake(startX, startY + (btnH + gap) * 2, btnW, btnH);
        self.hkbEsp.titleLabel.font = [UIFont boldSystemFontOfSize:8];
        self.hkbEsp.layer.cornerRadius = 3;
        [self.hkbEsp setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [self.hkbEsp addTarget:self action:@selector(tapEsp) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:self.hkbEsp];
        
        [self updateTitles];
    }
    return self;
}

- (CGPoint)clampedOrigin:(CGPoint)origin {
    if (!self.superview) {
        return origin;
    }

    CGRect bounds = self.superview.bounds;
    CGFloat maxX = MAX(CGRectGetMinX(bounds), CGRectGetMaxX(bounds) - self.bounds.size.width);
    CGFloat maxY = MAX(CGRectGetMinY(bounds), CGRectGetMaxY(bounds) - self.bounds.size.height);
    origin.x = MIN(MAX(origin.x, CGRectGetMinX(bounds)), maxX);
    origin.y = MIN(MAX(origin.y, CGRectGetMinY(bounds)), maxY);
    return origin;
}

- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    if (self.superview) {
        CGPoint origin = [self clampedOrigin:self.frame.origin];
        self.frame = CGRectMake(origin.x, origin.y, self.bounds.size.width, self.bounds.size.height);
    }
}

- (void)panAction:(UIPanGestureRecognizer*)pan {
    if (pan.state == UIGestureRecognizerStateBegan) {
        _panStartOrigin = self.frame.origin;
    } else if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [pan translationInView:self.superview];
        CGPoint origin = CGPointMake(_panStartOrigin.x + translation.x, _panStartOrigin.y + translation.y);
        origin = [self clampedOrigin:origin];
        self.frame = CGRectMake(origin.x, origin.y, self.bounds.size.width, self.bounds.size.height);
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setDouble:self.frame.origin.x forKey:@"hk_x"];
        [defaults setDouble:self.frame.origin.y forKey:@"hk_y"];
    }
}

- (void)updateTitles {
    [self.hkbAimbot setTitle:gHotAimbotEnabled ? @"AIM:ON" : @"AIM:OFF" forState:UIControlStateNormal];
    [self.hkbAimFire setTitle:gHotAimOnFireEnabled ? @"FIRE:ON" : @"FIRE:OFF" forState:UIControlStateNormal];
    [self.hkbEsp setTitle:gHotEspEnabled ? @"ESP:ON" : @"ESP:OFF" forState:UIControlStateNormal];
    
    self.hkbAimbot.backgroundColor = gHotAimbotEnabled ? [UIColor greenColor] : [UIColor redColor];
    self.hkbAimFire.backgroundColor = gHotAimOnFireEnabled ? [UIColor greenColor] : [UIColor redColor];
    self.hkbEsp.backgroundColor = gHotEspEnabled ? [UIColor greenColor] : [UIColor redColor];
}

- (void)tapAimbot {
    gHotAimbotEnabled = !gHotAimbotEnabled;
    [ConfigManager save];
    [self updateTitles];
}

- (void)tapAimFire {
    gHotAimOnFireEnabled = !gHotAimOnFireEnabled;
    [ConfigManager save];
    [self updateTitles];
}

- (void)tapEsp {
    gHotEspEnabled = !gHotEspEnabled;
    [ConfigManager save];
    [self updateTitles];
}

@end

static void RefreshHotkeyView(void) {
    [gHotkeyView updateTitles];
}

static void startMainUI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            gWatermark = [[WatermarkView alloc] initWithFrame:CGRectMake(20, 60, 620, 34)];
            [gOverlayContainer addSubview:gWatermark];
            
            gEspView = [[ESPView alloc] initWithFrame:gMainWin.bounds];
            gEspView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [gOverlayContainer addSubview:gEspView];
            
            SetupHudView();
            
            gHotZone = [[HotZoneView alloc] initWithFrame:CGRectMake((gMainWin.bounds.size.width - 60)/2, (gMainWin.bounds.size.height - 60)/2, 60, 60)];
            [gOverlayContainer addSubview:gHotZone];
            
            gMenuView = [[MenuView alloc] initWithFrame:CGRectMake((gMainWin.bounds.size.width - 620)/2, (gMainWin.bounds.size.height - 440)/2, 620, 440)];
            gMenuView.hidden = YES;
            [gOverlayContainer addSubview:gMenuView];
            
            gHotkeyView = [[HotkeyView alloc] initWithFrame:CGRectMake(8, MAX(0, gOverlayContainer.bounds.size.height - 92), 70, 84)];
            gHotkeyView.hidden = YES;
            [gOverlayContainer addSubview:gHotkeyView];
            
            gAttached = true;
            LOG(@"Attached v%s", kEspVersion);
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                @try {
                    gHotZone.hidden = YES;
                    gEspView.hidden = YES;
                    gWatermark.hidden = YES;
                    gMenuOpen = true;
                    gMenuView.hidden = NO;
                    gMenuView.alpha = 0;
                    gMenuView.transform = CGAffineTransformMakeScale(0.95, 0.95);
                    
                    [gOverlayContainer bringSubviewToFront:gMenuView];
                    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
                        gMenuView.alpha = 1.0;
                        gMenuView.transform = CGAffineTransformIdentity;
                    } completion:nil];
                } @catch (NSException* e) {
                }
            });
        } @catch (NSException* e) {
            LOG(@"startMainUI: %@", SafeStr([e reason]));
        }
    });
}

static void startOverlay(void) {
    @try {
        UIWindow *mw = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if (![s isKindOfClass:[UIWindowScene class]]) {
                    continue;
                }
                
                UIWindowScene *ws = (UIWindowScene*)s;
                if (ws.activationState != UISceneActivationStateForegroundActive) {
                    continue;
                }
                
                for (UIWindow *w in ws.windows) {
                    if (w.isKeyWindow) {
                        mw = w;
                        break;
                    }
                }
                if (mw) {
                    break;
                }
            }
        }
        
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (!mw) {
            mw = UIApplication.sharedApplication.keyWindow;
        }
#pragma clang diagnostic pop
        
        if (!mw) {
            return;
        }
        
        gMainWin = mw;
        gScreenPts = mw.bounds.size;
        gScreenScale = [UIScreen mainScreen].scale;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                gOverlayContainer = [[PassthroughView alloc] initWithFrame:gMainWin.bounds];
                gOverlayContainer.backgroundColor = [UIColor clearColor];
                gOverlayContainer.userInteractionEnabled = YES;
                [gMainWin addSubview:gOverlayContainer];
                
                BOOL isAuthed = [[NSUserDefaults standardUserDefaults] boolForKey:@"flop_authed"];
                
                if (isAuthed) {
                    startMainUI();
                } else {
                    KeySystemView *keyView = [[KeySystemView alloc] initWithFrame:gMainWin.bounds];
                    keyView.onSuccess = ^{
                        startMainUI();
                    };
                    [gOverlayContainer addSubview:keyView];
                }
            } @catch (NSException* e) {
                LOG(@"startOverlay: %@", SafeStr([e reason]));
            }
        });
    } @catch (NSException* e) {
    }
}

static void bootstrap(void) {
    @autoreleasepool {
        InstallCrashHandler();
        
        gHitPlayer = MakeTonePlayer(3000.0f, 0.08f, 0.8f);
        gKillPlayer = MakeTonePlayer(1500.0f, 0.2f, 1.0f);
        
        void *dget = nullptr;
        for (int i = 0; i < 300; i++) {
            dget = dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
            if (dget) {
                break;
            }
            usleep(100000);
        }
        
        if (!dget) {
            return;
        }
        sleep(8);
        
        gDomain = ((void*(*)())dget)();
        p_thread_attach = (fn_thread_attach)dlsym(RTLD_DEFAULT, "il2cpp_thread_attach");
        if (p_thread_attach && gDomain) {
            p_thread_attach(gDomain);
        }
        
        #define RES(f, n) do { f = (decltype(f))dlsym(RTLD_DEFAULT, n); if (!f) { LOG(@"Missing %s", n); return; } } while (0)
        RES(p_domain_get, "il2cpp_domain_get");
        RES(p_domain_get_assemblies, "il2cpp_domain_get_assemblies");
        RES(p_assembly_get_image, "il2cpp_assembly_get_image");
        RES(p_class_from_name, "il2cpp_class_from_name");
        RES(p_class_get_method_from_name, "il2cpp_class_get_method_from_name");
        RES(p_class_get_type, "il2cpp_class_get_type");
        RES(p_type_get_object, "il2cpp_type_get_object");
        RES(p_runtime_invoke, "il2cpp_runtime_invoke");
        RES(p_gchandle_new, "il2cpp_gchandle_new");
        RES(p_gchandle_get_target, "il2cpp_gchandle_get_target");
        RES(p_string_new, "il2cpp_string_new");
        #undef RES
        
        p_object_new = (fn_object_new)dlsym(RTLD_DEFAULT, "il2cpp_object_new");
        p_array_new = (fn_array_new)dlsym(RTLD_DEFAULT, "il2cpp_array_new");
        p_gchandle_free = (fn_gchandle_free)dlsym(RTLD_DEFAULT, "il2cpp_gchandle_free");
        p_class_get_methods = (fn_class_get_methods)dlsym(RTLD_DEFAULT, "il2cpp_class_get_methods");
        p_method_get_name = (fn_method_get_name)dlsym(RTLD_DEFAULT, "il2cpp_method_get_name");
        p_method_get_param_count = (fn_method_get_param_count)dlsym(RTLD_DEFAULT, "il2cpp_method_get_param_count");
        p_method_get_param = (fn_method_get_param)dlsym(RTLD_DEFAULT, "il2cpp_method_get_param");
        p_type_get_name = (fn_type_get_name)dlsym(RTLD_DEFAULT, "il2cpp_type_get_name");
        
        gObjCls = findClass("UnityEngine", "Object");
        gGOCls = findClass("UnityEngine", "GameObject");
        void *camCls = findClass("UnityEngine", "Camera");
        gTransformCls = findClass("UnityEngine", "Transform");
        gAnimatorCls = findClass("UnityEngine", "Animator");
        gCharCls = findClass("", "SceneLevelCharacter");
        gVolumeCls = findClass("UnityEngine.Rendering", "Volume");
        if (!gVolumeCls) {
            gVolumeCls = findClass("", "Volume");
        }
        gMatCls = findClass("UnityEngine", "Material");
        gSkyboxCls = findClass("UnityEngine", "RenderSettings");
        gRendererCls = findClass("UnityEngine", "Renderer");
        gLightCls = findClass("UnityEngine", "Light");
        gColorAdjCls = findClass("UnityEngine.Rendering.Universal", "ColorAdjustments");
        if (!gColorAdjCls) {
            gColorAdjCls = findClass("", "ColorAdjustments");
        }
        gBloomCls = findClass("UnityEngine.Rendering.Universal", "Bloom");
        if (!gBloomCls) {
            gBloomCls = findClass("", "Bloom");
        }
        gClampedFCls = findClass("UnityEngine.Rendering", "ClampedFloatParameter");
        if (!gClampedFCls) {
            gClampedFCls = findClass("", "ClampedFloatParameter");
        }
        gMinFCls = findClass("UnityEngine.Rendering", "MinFloatParameter");
        if (!gMinFCls) {
            gMinFCls = findClass("", "MinFloatParameter");
        }
        gFloatPCls = findClass("UnityEngine.Rendering", "FloatParameter");
        if (!gFloatPCls) {
            gFloatPCls = findClass("", "FloatParameter");
        }
        gCamDataCls = findClass("UnityEngine.Rendering.Universal", "UniversalAdditionalCameraData");
        if (!gCamDataCls) {
            gCamDataCls = findClass("", "UniversalAdditionalCameraData");
        }
        
        void* playerCls = findClass("", "SceneLevelPlayer");
        
        if (!gObjCls || !camCls || !gTransformCls || !playerCls) {
            LOG(@"Failed core");
            return;
        }
        
        gPlayerTypeHandle = p_gchandle_new(p_type_get_object(p_class_get_type(playerCls)), true);
        if (gVolumeCls) {
            gVolumeTypeHandle = p_gchandle_new(p_type_get_object(p_class_get_type(gVolumeCls)), true);
        }
        if (gLightCls) {
            gLightTypeHandle = p_gchandle_new(p_type_get_object(p_class_get_type(gLightCls)), true);
        }
        if (gCamDataCls) {
            gCamDataTypeHandle = p_gchandle_new(p_type_get_object(p_class_get_type(gCamDataCls)), true);
        }
        
        if (gMatCls) {
            EnsureMaterialCtorMI();
            p_matSetTextureMI = p_class_get_method_from_name(gMatCls, "SetTexture", 2);
            if (p_matSetTextureMI) {
                p_matSetTexture = (fn_matSetTexture)methodPtr(p_matSetTextureMI);
            }
        }
        
        if (gGOCls) {
            p_getCompsInChildrenMI = p_class_get_method_from_name(gGOCls, "GetComponentsInChildren", 1);
            void* mi2 = p_class_get_method_from_name(gGOCls, "GetComponentsInChildren", 2);
            if (mi2) {
                p_getCompsInChildrenMI = mi2;
            }
        }
        
        p_findPlayerMI = p_class_get_method_from_name(gObjCls, "FindObjectsOfType", 1);
        if (gVolumeCls) {
            p_findVolumeMI = p_class_get_method_from_name(gObjCls, "FindObjectsOfType", 1);
        }
        
        if (gLightCls) {
            p_lightGetIntensityMI = p_class_get_method_from_name(gLightCls, "get_intensity", 0);
            p_lightSetIntensityMI = p_class_get_method_from_name(gLightCls, "set_intensity", 1);
            p_lightGetColorMI = p_class_get_method_from_name(gLightCls, "get_color", 0);
            p_lightSetColorMI = p_class_get_method_from_name(gLightCls, "set_color", 1);
            if (p_lightGetIntensityMI) {
                p_lightGetIntensity = (fn_lightGetIntensity)methodPtr(p_lightGetIntensityMI);
            }
            if (p_lightSetIntensityMI) {
                p_lightSetIntensity = (fn_lightSetIntensity)methodPtr(p_lightSetIntensityMI);
            }
            if (p_lightGetColorMI) {
                p_lightGetColor = (fn_lightGetColor)methodPtr(p_lightGetColorMI);
            }
            if (p_lightSetColorMI) {
                p_lightSetColor = (fn_lightSetColor)methodPtr(p_lightSetColorMI);
            }
        }
        
        if (gSkyboxCls) {
            p_setFogMI = p_class_get_method_from_name(gSkyboxCls, "set_fog", 1);
            p_getFogMI = p_class_get_method_from_name(gSkyboxCls, "get_fog", 0);
            p_renderSetAmbientLightMI = p_class_get_method_from_name(gSkyboxCls, "set_ambientLight", 1);
            p_renderGetAmbientLightMI = p_class_get_method_from_name(gSkyboxCls, "get_ambientLight", 0);
            if (p_setFogMI) {
                p_setFog = (fn_setFog)methodPtr(p_setFogMI);
            }
            if (p_getFogMI) {
                p_getFog = (fn_getFog)methodPtr(p_getFogMI);
            }
            if (p_renderSetAmbientLightMI) {
                p_renderSetAmbientLight = (fn_renderSetAmbientLight)methodPtr(p_renderSetAmbientLightMI);
            }
            if (p_renderGetAmbientLightMI) {
                p_renderGetAmbientLight = (fn_renderGetAmbientLight)methodPtr(p_renderGetAmbientLightMI);
            }
        }
        
        if (gClampedFCls) {
            p_cfaValMI = p_class_get_method_from_name(gClampedFCls, "set_value", 1);
        }
        if (gMinFCls) {
            p_mfaValMI = p_class_get_method_from_name(gMinFCls, "set_value", 1);
        }
        if (gFloatPCls) {
            p_fpaValMI = p_class_get_method_from_name(gFloatPCls, "set_value", 1);
        }
        p_camW2SMI = p_class_get_method_from_name(camCls, "WorldToScreenPoint", 1);
        p_tfGetPosMI = p_class_get_method_from_name(gTransformCls, "get_position", 0);
        p_tfSetPosMI = p_class_get_method_from_name(gTransformCls, "set_position", 1);
        p_tfGetLocalScaleMI = p_class_get_method_from_name(gTransformCls, "get_localScale", 0);
        p_tfSetLocalScaleMI = p_class_get_method_from_name(gTransformCls, "set_localScale", 1);
        p_tfGetEulerMI = p_class_get_method_from_name(gTransformCls, "get_eulerAngles", 0);
        
        if (p_tfGetLocalScaleMI) {
            p_tfGetLocalScale = (fn_tfGetLocalScale)methodPtr(p_tfGetLocalScaleMI);
        }
        if (p_tfSetLocalScaleMI) {
            p_tfSetLocalScale = (fn_tfSetLocalScale)methodPtr(p_tfSetLocalScaleMI);
        }
        if (p_tfGetEulerMI) {
            p_tfGetEuler = (fn_tfGetEuler)methodPtr(p_tfGetEulerMI);
        }
        
        if (gAnimatorCls) {
            p_getBoneTransformMI = p_class_get_method_from_name(gAnimatorCls, "GetBoneTransform", 1);
            if (p_getBoneTransformMI) {
                p_getBoneTransform = (fn_getBoneTransform)methodPtr(p_getBoneTransformMI);
            }
        }
        
        p_camGetPixelWidthMI = p_class_get_method_from_name(camCls, "get_pixelWidth", 0);
        p_camGetPixelHeightMI = p_class_get_method_from_name(camCls, "get_pixelHeight", 0);
        p_camGetFovMI = p_class_get_method_from_name(camCls, "get_fieldOfView", 0);
        if (p_camGetFovMI) {
            p_camGetFov = (fn_camGetFov)methodPtr(p_camGetFovMI);
        }
        p_camSetAspectMI = p_class_get_method_from_name(camCls, "set_aspect", 1);
        if (p_camSetAspectMI) {
            p_camSetAspect = (fn_camSetAspect)methodPtr(p_camSetAspectMI);
        }
        p_camSetFovMI = p_class_get_method_from_name(camCls, "set_fieldOfView", 1);
        if (p_camSetFovMI) {
            p_camSetFov = (fn_camSetFov)methodPtr(p_camSetFovMI);
        }
        
        if (gSkyboxCls) {
            p_getSkyboxMI = p_class_get_method_from_name(gSkyboxCls, "get_skybox", 0);
            if (p_getSkyboxMI) {
                p_getSkybox = (fn_getSkybox)methodPtr(p_getSkyboxMI);
            }
        }
        
        if (gMatCls) {
            p_matSetColorMI = p_class_get_method_from_name(gMatCls, "SetColor", 2);
            if (p_matSetColorMI) {
                p_matSetColor = (fn_matSetColor)methodPtr(p_matSetColorMI);
            }
            p_matSetFloatMI = p_class_get_method_from_name(gMatCls, "SetFloat", 2);
            if (p_matSetFloatMI) {
                p_matSetFloat = (fn_matSetFloat)methodPtr(p_matSetFloatMI);
            }
            p_matSetIntMI = p_class_get_method_from_name(gMatCls, "SetInt", 2);
            if (p_matSetIntMI) {
                p_matSetInt = (fn_matSetInt)methodPtr(p_matSetIntMI);
            }
            p_matEnableKeywordMI = p_class_get_method_from_name(gMatCls, "EnableKeyword", 1);
            if (p_matEnableKeywordMI) {
                p_matEnableKeyword = (fn_matEnableKeyword)methodPtr(p_matEnableKeywordMI);
            }
            p_matSetRQMI = p_class_get_method_from_name(gMatCls, "set_renderQueue", 1);
            if (p_matSetRQMI) {
                p_matSetRQ = (fn_matSetRenderQueue)methodPtr(p_matSetRQMI);
            }
        }
        
        if (gRendererCls) {
            p_rendGetSharedMatsMI = p_class_get_method_from_name(gRendererCls, "get_sharedMaterials", 0);
            if (p_rendGetSharedMatsMI) {
                p_rendGetSharedMats = (fn_rendGetSharedMats)methodPtr(p_rendGetSharedMatsMI);
            }
            p_rendSetSharedMatsMI = p_class_get_method_from_name(gRendererCls, "set_sharedMaterials", 1);
            if (p_rendSetSharedMatsMI) {
                p_rendSetSharedMats = (fn_rendSetSharedMats)methodPtr(p_rendSetSharedMatsMI);
            }
        }
        
        void* componentCls = findClass("UnityEngine", "Component");
        if (componentCls) {
            p_getTransformMI = p_class_get_method_from_name(componentCls, "get_transform", 0);
            if (p_getTransformMI) {
                p_getTransform = (fn_getTransform)methodPtr(p_getTransformMI);
            }
            p_getGameObjectMI = p_class_get_method_from_name(componentCls, "get_gameObject", 0);
            if (p_getGameObjectMI) {
                p_getGameObject = (fn_getGameObject)methodPtr(p_getGameObjectMI);
            }
        }
        
        if (p_camW2SMI) {
            p_camW2S = (fn_camW2S)methodPtr(p_camW2SMI);
        }
        if (p_camGetPixelWidthMI) {
            p_camGetPixelWidth = (fn_camGetPixelWidth)methodPtr(p_camGetPixelWidthMI);
        }
        if (p_camGetPixelHeightMI) {
            p_camGetPixelHeight = (fn_camGetPixelHeight)methodPtr(p_camGetPixelHeightMI);
        }
        if (p_tfGetPosMI) {
            p_tfGetPos = (fn_tfGetPos)methodPtr(p_tfGetPosMI);
        }
        if (p_tfSetPosMI) {
            p_tfSetPos = (fn_tfSetPos)methodPtr(p_tfSetPosMI);
        }
        
        void* sceneCamCls = findClass("", "SceneLevelCamera");
        if (sceneCamCls) {
            p_sceneSetFovMI = p_class_get_method_from_name(sceneCamCls, "SetFieldOfView", 1);
            if (p_sceneSetFovMI) {
                p_sceneSetFov = (fn_sceneSetFov)methodPtr(p_sceneSetFovMI);
            }

            p_lookAtTargetMI = p_class_get_method_from_name(sceneCamCls, "LookAtTarget", 1);
            if (p_lookAtTargetMI) {
                p_lookAtTarget = (fn_LookAtTarget)methodPtr(p_lookAtTargetMI);
            }
        }
        
        if (gCharCls) {
            p_checkSeenMI = p_class_get_method_from_name(gCharCls, "CheckSeen", 1);
            if (p_checkSeenMI) {
                p_CheckSeen = (fn_CheckSeen)methodPtr(p_checkSeenMI);
            }
        }
        
        InstallAllHooks();
        [ConfigManager load];
        
        dispatch_queue_t q = dispatch_get_main_queue();
        gChamsTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(gChamsTimer, DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gChamsTimer, ^{
            @try {
                ChamsTick();
            } @catch (NSException* e) {
            }
        });
        dispatch_resume(gChamsTimer);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if (p_thread_attach && gDomain) {
                    p_thread_attach(gDomain);
                }
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSURL *tgUrl = [NSURL URLWithString:@"tg://resolve?domain=FlopDLC"];
                    if ([[UIApplication sharedApplication] canOpenURL:tgUrl]) {
                        [[UIApplication sharedApplication] openURL:tgUrl options:@{} completionHandler:nil];
                    } else {
                        NSURL *webUrl = [NSURL URLWithString:@"https://t.me/FlopDLC"];
                        [[UIApplication sharedApplication] openURL:webUrl options:@{} completionHandler:nil];
                    }
                });
                
                startOverlay();
                
                gDriver = [ESPDriver new];
                gLink = [CADisplayLink displayLinkWithTarget:gDriver selector:@selector(tick:)];
                gLink.preferredFramesPerSecond = 30;
                [gLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
                
                LOG(@"Bootstrap complete");
            } @catch (NSException* e) {
            }
        });
    }
}

__attribute__((constructor, used))
static void ctor(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        bootstrap();
    });
}

// =========================================================================================
// BALLISTICS CORE — WORKING NO SPREAD / NO RECOIL
// =========================================================================================
// Layers, in order of strength:
//   1. WeaponDataRange asset neutralization (ShootOffset / SpreadMove / RecoilPatternScale /
//      StandingBallisticMul / UnscopedRecoilMul / _fireBackOffset). This is the data the
//      weapon reads when it builds the shot direction, so zeroing it removes the source.
//   2. Runtime state neutralization (<Spread>, <Recoil>, Offset, jyw, jzc) every tick and
//      immediately around UseProcess / Update / camera LateUpdate.
//   3. Method-slot hooks for GetSpreadMultiplier and UseProcess. They cover reflection and
//      runtime-invoke paths and return an exact zero multiplier when the feature is active.
//   4. UnityEngine.Random.insideUnitCircle / insideUnitSphere hooks. If the shot code uses
//      the standard Unity random circle for pellet/cone jitter, this kills that jitter too.
//   5. Camera snapshot around the fire button. Recoil that is applied to the view inside the
//      shot call is rolled back immediately, so the crosshair does not climb.
// =========================================================================================

struct RangeSnapshot {
    void* klass;
    Vec2 shootOffset;
    Vec2 spreadMove;
    float offsetCool;
    float standingMul;
    float patternScale;
    float unscopedMul;
    Vec3 fireBackOffset;
    float fireBackTime;
};

static std::unordered_map<void*, RangeSnapshot> gRangeSnapshots;
static std::atomic<bool> gRangeApplied{false};
static void* gRangeClassPtr = nullptr;
static void* gShotgunClassPtr = nullptr;
static std::atomic<uint64_t> gLastBallisticsLog{0};
static std::atomic<uint64_t> gSpreadWindowUntil{0};

static inline float SpreadFloorValue(void) {
    if (!gSpreadFloorEnabled.load()) {
        return 0.0f;
    }
    float v = gSpreadFloor.load();
    if (!std::isfinite(v) || v < 0.0f) {
        return 0.0f;
    }
    return Math::Clamp(v, 0.0f, 0.02f);
}

static bool NoSpreadActive(void) {
    if (gNoSpreadEnabled.load()) {
        return true;
    }
    if (!gAutoNoSpread.load()) {
        return false;
    }
    return gAimbotEnabled.load() || gHotAimbotEnabled.load() ||
           gAimOnFireEnabled.load() || gHotAimOnFireEnabled.load();
}

static bool NoRecoilActive(void) {
    if (gNoRecoilEnabled.load()) {
        return true;
    }
    if (!gAutoNoRecoil.load()) {
        return false;
    }
    return gAimbotEnabled.load() || gHotAimbotEnabled.load() ||
           gAimOnFireEnabled.load() || gHotAimOnFireEnabled.load();
}

// ItemEquipWeaponRange and ItemEquipWeaponRangeShotgun are the only classes that own the
// spread/recoil fields. Grenade and melee items share the ItemEquipWeapon base and are
// much smaller, so writing range offsets into them would corrupt the heap. Never touch a
// weapon unless its il2cpp class pointer matches one of the two range classes.
static bool IsRangeWeapon(void* weapon) {
    if (!SANE_PTR(weapon)) {
        return false;
    }
    if (!gRangeClassPtr && !gShotgunClassPtr) {
        return false;
    }
    void* klass = *(void**)weapon;
    if (!SANE_PTR(klass)) {
        return false;
    }
    return klass == gRangeClassPtr || (gShotgunClassPtr && klass == gShotgunClassPtr);
}

static void CaptureRangeData(void* data) {
    if (!SANE_PTR(data)) {
        return;
    }
    if (gRangeSnapshots.find(data) != gRangeSnapshots.end()) {
        return;
    }
    
    RangeSnapshot snap;
    snap.klass = *(void**)data;
    snap.shootOffset = *(Vec2*)((uintptr_t)data + off::kRangeShootOffset);
    snap.spreadMove = *(Vec2*)((uintptr_t)data + off::kRangeSpreadMove);
    snap.offsetCool = *(float*)((uintptr_t)data + off::kRangeOffsetCool);
    snap.standingMul = *(float*)((uintptr_t)data + off::kRangeStandingBallisticMul);
    snap.patternScale = *(float*)((uintptr_t)data + off::kRangeRecoilPatternScale);
    snap.unscopedMul = *(float*)((uintptr_t)data + off::kRangeUnscopedRecoilMul);
    snap.fireBackOffset = *(Vec3*)((uintptr_t)data + off::kDataFireBackOffset);
    snap.fireBackTime = *(float*)((uintptr_t)data + off::kDataFireBackTime);
    gRangeSnapshots[data] = snap;
}

static void ApplyRangeData(void* data) {
    if (!SANE_PTR(data)) {
        return;
    }
    CaptureRangeData(data);
    
    float floorValue = SpreadFloorValue();
    Vec2 offset(floorValue, floorValue);
    
    *(Vec2*)((uintptr_t)data + off::kRangeShootOffset) = offset;
    *(Vec2*)((uintptr_t)data + off::kRangeSpreadMove) = Vec2(0.0f, 0.0f);
    *(float*)((uintptr_t)data + off::kRangeOffsetCool) = 0.0f;
    *(float*)((uintptr_t)data + off::kRangeStandingBallisticMul) = 0.0f;
    *(float*)((uintptr_t)data + off::kRangeRecoilPatternScale) = 0.0f;
    *(float*)((uintptr_t)data + off::kRangeUnscopedRecoilMul) = 0.0f;
    *(Vec3*)((uintptr_t)data + off::kDataFireBackOffset) = Vec3(0.0f, 0.0f, 0.0f);
    *(float*)((uintptr_t)data + off::kDataFireBackTime) = 0.0f;
}

static void RestoreRangeData(void) {
    if (!gRangeApplied.load() && gRangeSnapshots.empty()) {
        return;
    }
    
    for (auto& kv : gRangeSnapshots) {
        void* data = kv.first;
        RangeSnapshot& snap = kv.second;
        if (!SANE_PTR(data)) {
            continue;
        }
        // Guard against a recycled address: only restore if the object still has the
        // same il2cpp class pointer that it had when the snapshot was taken.
        if (!SANE_PTR(snap.klass) || *(void**)data != snap.klass) {
            continue;
        }
        
        *(Vec2*)((uintptr_t)data + off::kRangeShootOffset) = snap.shootOffset;
        *(Vec2*)((uintptr_t)data + off::kRangeSpreadMove) = snap.spreadMove;
        *(float*)((uintptr_t)data + off::kRangeOffsetCool) = snap.offsetCool;
        *(float*)((uintptr_t)data + off::kRangeStandingBallisticMul) = snap.standingMul;
        *(float*)((uintptr_t)data + off::kRangeRecoilPatternScale) = snap.patternScale;
        *(float*)((uintptr_t)data + off::kRangeUnscopedRecoilMul) = snap.unscopedMul;
        *(Vec3*)((uintptr_t)data + off::kDataFireBackOffset) = snap.fireBackOffset;
        *(float*)((uintptr_t)data + off::kDataFireBackTime) = snap.fireBackTime;
    }
    
    gRangeSnapshots.clear();
    gRangeApplied = false;
}

static void PatchWeaponRangeData(void* weapon) {
    if (!IsRangeWeapon(weapon)) {
        return;
    }
    void* data = *(void**)((uintptr_t)weapon + off::kWepRangeData);
    if (!SANE_PTR(data)) {
        return;
    }
    ApplyRangeData(data);
    gRangeApplied = true;
}

static void ZeroSpreadRuntime(void* weapon) {
    if (!IsRangeWeapon(weapon)) {
        return;
    }
    float floorValue = SpreadFloorValue();
    *(Vec2*)((uintptr_t)weapon + off::kWepSpread) = Vec2(floorValue, floorValue);
}

static void ZeroRecoilRuntime(void* weapon) {
    if (!IsRangeWeapon(weapon)) {
        return;
    }
    *(Vec3*)((uintptr_t)weapon + off::kWepRecoil) = Vec3(0.0f, 0.0f, 0.0f);
    *(Vec3*)((uintptr_t)weapon + off::kWepOffset) = Vec3(0.0f, 0.0f, 0.0f);
    *(Vec3*)((uintptr_t)weapon + off::kWepJyw) = Vec3(0.0f, 0.0f, 0.0f);
    *(Vec3*)((uintptr_t)weapon + off::kWepJzc) = Vec3(0.0f, 0.0f, 0.0f);
}

static void BallisticsWeaponTick(void* weapon) {
    if (!IsRangeWeapon(weapon)) {
        return;
    }
    
    bool noSpread = NoSpreadActive();
    bool noRecoil = NoRecoilActive();
    if (!noSpread && !noRecoil) {
        return;
    }
    
    if (noSpread) {
        PatchWeaponRangeData(weapon);
        ZeroSpreadRuntime(weapon);
    }
    if (noRecoil) {
        ZeroRecoilRuntime(weapon);
    }
}

static void BallisticsCameraPre(void* camera) {
    if (!SANE_PTR(camera)) {
        return;
    }
    
    if (NoRecoilActive()) {
        *(Vec2*)((uintptr_t)camera + off::kCamAdditionalRot) = Vec2(0.0f, 0.0f);
    }
    if (alive(g_localWeapon)) {
        BallisticsWeaponTick(g_localWeapon);
    }
}

static void BallisticsCameraPost(void* camera) {
    if (!SANE_PTR(camera)) {
        return;
    }
    
    if (NoRecoilActive()) {
        *(Vec2*)((uintptr_t)camera + off::kCamAdditionalRot) = Vec2(0.0f, 0.0f);
    }
}

static unsigned char gFireCamSnapshot[off::kCamStateSize];
static bool gFireCamSnapshotValid = false;

static void BallisticsFirePre(void) {
    gFireCamSnapshotValid = false;
    if (NoSpreadActive()) {
        gSpreadWindowUntil = NowMs() + 300;
    }
    
    if (!NoRecoilActive()) {
        return;
    }
    if (!SANE_PTR(g_localSceneChar)) {
        return;
    }
    
    memcpy(gFireCamSnapshot,
           (void*)((uintptr_t)g_localSceneChar + off::kCamStateBegin),
           off::kCamStateSize);
    gFireCamSnapshotValid = true;
    
    if (alive(g_localWeapon)) {
        BallisticsWeaponTick(g_localWeapon);
    }
}

static void BallisticsFirePost(void) {
    if (!gFireCamSnapshotValid) {
        return;
    }
    gFireCamSnapshotValid = false;
    
    if (!SANE_PTR(g_localSceneChar)) {
        return;
    }
    
    memcpy((void*)((uintptr_t)g_localSceneChar + off::kCamStateBegin),
           gFireCamSnapshot,
           off::kCamStateSize);
    
    if (alive(g_localWeapon)) {
        BallisticsWeaponTick(g_localWeapon);
    }
}

static void BallisticsTick(void) {
    bool noSpread = NoSpreadActive();
    bool noRecoil = NoRecoilActive();
    
    if (!noSpread && !noRecoil) {
        if (gRangeApplied.load()) {
            RestoreRangeData();
        }
        return;
    }
    
    if (alive(g_localWeapon)) {
        if (noSpread) {
            PatchWeaponRangeData(g_localWeapon);
        }
        if (noSpread) {
            ZeroSpreadRuntime(g_localWeapon);
        }
        if (noRecoil) {
            ZeroRecoilRuntime(g_localWeapon);
        }
    }
    
    // SceneLevelCamera owns rot (0x30) and additionalRot (0x38); recoil kick lands in
    // additionalRot. The Unity Camera component is a separate object (0x48), so the
    // write has to target the SceneLevelCamera instance itself.
    if (noRecoil && SANE_PTR(g_localSceneChar)) {
        *(Vec2*)((uintptr_t)g_localSceneChar + off::kCamAdditionalRot) = Vec2(0.0f, 0.0f);
    }
    
    uint64_t now = NowMs();
    if (gBallisticsDebug.load() && now - gLastBallisticsLog.load() > 2000) {
        gLastBallisticsLog = now;
        if (IsRangeWeapon(g_localWeapon)) {
            void* data = *(void**)((uintptr_t)g_localWeapon + off::kWepRangeData);
            Vec2 sp = *(Vec2*)((uintptr_t)g_localWeapon + off::kWepSpread);
            Vec3 rc = *(Vec3*)((uintptr_t)g_localWeapon + off::kWepRecoil);
            LOG(@"[BALL] spread=(%.4f,%.4f) recoil=(%.4f,%.4f,%.4f) data=%p shoot=(%.4f,%.4f) scale=%.4f",
                sp.x, sp.y, rc.x, rc.y, rc.z, data,
                SANE_PTR(data) ? ((Vec2*)((uintptr_t)data + off::kRangeShootOffset))->x : 0.0f,
                SANE_PTR(data) ? ((Vec2*)((uintptr_t)data + off::kRangeShootOffset))->y : 0.0f,
                SANE_PTR(data) ? *(float*)((uintptr_t)data + off::kRangeRecoilPatternScale) : 0.0f);
        }
    }
}

// =========================================================================================
// BALLISTICS HOOKS
// =========================================================================================

typedef Vec2 (*fn_GetSpreadMultiplier)(void*, void*, void*);
static fn_GetSpreadMultiplier orig_GetSpreadMultiplier = nullptr;

static Vec2 hook_GetSpreadMultiplier(void* self, void* info, void* mi) {
    if (NoSpreadActive()) {
        return Vec2(SpreadFloorValue(), SpreadFloorValue());
    }
    if (orig_GetSpreadMultiplier) {
        return orig_GetSpreadMultiplier(self, info, mi);
    }
    return Vec2(0.0f, 0.0f);
}

typedef void (*fn_UseProcess)(void*, void*, void*);
static fn_UseProcess orig_UseProcess = nullptr;

static void hook_UseProcess(void* self, void* info, void* mi) {
    BallisticsFirePre();
    if (NoSpreadActive()) {
        BallisticsWeaponTick(self);
    }
    
    if (orig_UseProcess) {
        orig_UseProcess(self, info, mi);
    }
    
    if (NoSpreadActive() || NoRecoilActive()) {
        BallisticsWeaponTick(self);
    }
    BallisticsFirePost();
}

typedef Vec2 (*fn_GetInsideUnitCircle)(void*);
static fn_GetInsideUnitCircle orig_GetInsideUnitCircle = nullptr;

static Vec2 hook_GetInsideUnitCircle(void* mi) {
    // Only suppress during the fire window: Unity.Random is shared with VFX, grenade
    // physics and UI, so a permanent zero would visibly break unrelated systems.
    if (NoSpreadActive() && NowMs() < gSpreadWindowUntil.load()) {
        return Vec2(0.0f, 0.0f);
    }
    if (orig_GetInsideUnitCircle) {
        return orig_GetInsideUnitCircle(mi);
    }
    return Vec2(0.0f, 0.0f);
}

typedef Vec3 (*fn_GetInsideUnitSphere)(void*);
static fn_GetInsideUnitSphere orig_GetInsideUnitSphere = nullptr;

static Vec3 hook_GetInsideUnitSphere(void* mi) {
    if (NoSpreadActive() && NowMs() < gSpreadWindowUntil.load()) {
        return Vec3(0.0f, 0.0f, 0.0f);
    }
    if (orig_GetInsideUnitSphere) {
        return orig_GetInsideUnitSphere(mi);
    }
    return Vec3(0.0f, 0.0f, 0.0f);
}

static void InstallBallisticsHooks(void) {
    @try {
        void* rangeCls = findClass("", "ItemEquipWeaponRange");
        gRangeClassPtr = rangeCls;
        gShotgunClassPtr = findClass("", "ItemEquipWeaponRangeShotgun");
        if (rangeCls) {
            void* miSpread = p_class_get_method_from_name(rangeCls, "GetSpreadMultiplier", 1);
            if (miSpread) {
                hook_install(miSpread, (void*)hook_GetSpreadMultiplier, (void**)&orig_GetSpreadMultiplier);
                LOG(@"[BALL] GetSpreadMultiplier hook installed");
            }
            
            void* miUse = p_class_get_method_from_name(rangeCls, "UseProcess", 1);
            if (miUse) {
                hook_install(miUse, (void*)hook_UseProcess, (void**)&orig_UseProcess);
                LOG(@"[BALL] UseProcess hook installed");
            }
        }
        
        void* randomCls = findClass("UnityEngine", "Random");
        if (randomCls) {
            void* miCircle = p_class_get_method_from_name(randomCls, "get_insideUnitCircle", 0);
            if (miCircle) {
                hook_install(miCircle, (void*)hook_GetInsideUnitCircle, (void**)&orig_GetInsideUnitCircle);
                LOG(@"[BALL] insideUnitCircle hook installed");
            }
            void* miSphere = p_class_get_method_from_name(randomCls, "get_insideUnitSphere", 0);
            if (miSphere) {
                hook_install(miSphere, (void*)hook_GetInsideUnitSphere, (void**)&orig_GetInsideUnitSphere);
                LOG(@"[BALL] insideUnitSphere hook installed");
            }
        }
    } @catch (NSException* e) {
        LOG(@"[BALL] hooks: %@", SafeStr([e reason]));
    }
}

// =========================================================================================
// HUD MODEL
// =========================================================================================

static void HudBeginFrame(void) {
    gHudPlayers.clear();
    gHudRadar.clear();
    gHudAimLineActive = false;
    gHudCrosshairVisible = false;
    gHudScopeActive = false;
    
    uint64_t now = NowMs();
    for (auto it = gHudDamage.begin(); it != gHudDamage.end(); ) {
        if (it->until <= now) {
            it = gHudDamage.erase(it);
        } else {
            ++it;
        }
    }
    for (auto it = gHudKills.begin(); it != gHudKills.end(); ) {
        if (it->until <= now) {
            it = gHudKills.erase(it);
        } else {
            ++it;
        }
    }
}

static void HudAddPlayer(const HudPlayerInfo& info) {
    if (gHudPlayers.size() < 128) {
        gHudPlayers.push_back(info);
    }
}

static void HudAddDamage(CGPoint pos, int amount, uint64_t until) {
    if (!gDamageNumbersEnabled.load()) {
        return;
    }
    if (gHudDamage.size() >= 48) {
        gHudDamage.erase(gHudDamage.begin());
    }
    HudDamageInfo d;
    d.pos = pos;
    d.amount = amount;
    d.until = until;
    gHudDamage.push_back(d);
}

static void HudAddKill(const char* name, uint64_t until) {
    if (!gKillFeedEnabled.load() || !name) {
        return;
    }
    if (gHudKills.size() >= 8) {
        gHudKills.erase(gHudKills.begin());
    }
    HudKillInfo k;
    memset(k.name, 0, sizeof(k.name));
    strncpy(k.name, name, sizeof(k.name) - 1);
    k.until = until;
    gHudKills.push_back(k);
}

static void HudAddRadar(float x, float y, int team, bool dead) {
    if (!gRadarEnabled.load()) {
        return;
    }
    if (gHudRadar.size() >= 128) {
        gHudRadar.erase(gHudRadar.begin());
    }
    HudRadarBlip b;
    b.x = x;
    b.y = y;
    b.team = team;
    b.dead = dead;
    gHudRadar.push_back(b);
}

static void HudSetAimLine(bool active, CGPoint target) {
    gHudAimLineActive = active;
    gHudAimLineTarget = target;
}

static void HudSetCrosshair(float gap, bool visible) {
    gHudCrosshairGap = Math::Clamp(gap, 2.0f, 80.0f);
    gHudCrosshairVisible = visible;
}

static void HudSetScope(bool active) {
    gHudScopeActive = active;
}

// =========================================================================================
// HUD VIEW
// =========================================================================================

@class HudView;

static HudView* gHudView = nil;

static void HudSampleFrame(void) {
    uint64_t now = NowMs();
    if (gFpsLastSample == 0) {
        gFpsLastSample = now;
        gFpsFrames = 0;
        return;
    }
    
    gFpsFrames++;
    uint64_t elapsed = now - gFpsLastSample;
    if (elapsed < 500) {
        return;
    }
    
    float fps = (float)gFpsFrames * 1000.0f / (float)elapsed;
    if (fps < 0.0f) {
        fps = 0.0f;
    }
    if (fps > 999.0f) {
        fps = 999.0f;
    }
    
    gFpsValue = (int)(fps + 0.5f);
    gFrameMs = (float)elapsed / (float)gFpsFrames;
    
    if (gFpsHistory.size() >= 120) {
        gFpsHistory.erase(gFpsHistory.begin());
    }
    gFpsHistory.push_back(fps);
    
    gFpsFrames = 0;
    gFpsLastSample = now;
}

static void HudTick(void) {
    HudSampleFrame();
    if (gHudView) {
        [gHudView setNeedsDisplay];
    }
}

@interface HudView : UIView
@end

@implementation HudView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.opaque = NO;
        self.clearsContextBeforeDrawing = NO;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    }
    return self;
}

- (void)drawScopeOverlay:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gHudScopeActive || !gScopeOverlayEnabled) {
        return;
    }
    
    CGFloat w = rect.size.width;
    CGFloat h = rect.size.height;
    CGFloat radius = MIN(w, h) * 0.42f;
    CGRect hole = CGRectMake(w/2 - radius, h/2 - radius, radius * 2, radius * 2);
    
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRect(path, NULL, rect);
    CGPathAddEllipseInRect(path, NULL, hole);
    
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.88].CGColor);
    CGContextAddPath(ctx, path);
    CGContextEOFillPath(ctx);
    CGPathRelease(path);
    
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.95].CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextStrokeEllipseInRect(ctx, hole);
}

- (void)drawRadar:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gRadarEnabled) {
        return;
    }
    
    CGFloat size = Math::Clamp(gRadarSize.load(), 70.0f, 220.0f);
    CGFloat margin = 24.0f;
    CGFloat cx = rect.size.width - margin - size / 2.0f;
    CGFloat cy = rect.size.height - margin - size / 2.0f;
    CGFloat radius = size / 2.0f;
    
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.38].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - radius, cy - radius, size, size));
    
    CGContextSetStrokeColorWithColor(ctx, (gRadarColor ?: [UIColor greenColor]).CGColor);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - radius, cy - radius, size, size));
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - radius * 0.66f, cy - radius * 0.66f, radius * 1.32f, radius * 1.32f));
    CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - radius * 0.33f, cy - radius * 0.33f, radius * 0.66f, radius * 0.66f));
    
    CGContextMoveToPoint(ctx, cx - radius, cy);
    CGContextAddLineToPoint(ctx, cx + radius, cy);
    CGContextMoveToPoint(ctx, cx, cy - radius);
    CGContextAddLineToPoint(ctx, cx, cy + radius);
    CGContextStrokePath(ctx);
    
    float range = (float)Math::Clamp((float)gRadarRange.load(), 20.0f, 150.0f);
    float scale = radius / range;
    
    for (const HudRadarBlip& b : gHudRadar) {
        float px = cx + b.x * scale;
        float py = cy + b.y * scale;
        float dx = px - cx;
        float dy = py - cy;
        float len = sqrtf(dx * dx + dy * dy);
        if (len > radius) {
            px = cx + dx / len * radius;
            py = cy + dy / len * radius;
        }
        
        UIColor* color = (b.team == gTeam && gTeam >= 0) ? [UIColor cyanColor] : [UIColor redColor];
        if (b.dead) {
            color = [UIColor grayColor];
        }
        
        CGContextSetFillColorWithColor(ctx, color.CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(px - 2.5f, py - 2.5f, 5.0f, 5.0f));
    }
    
    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - 2.0f, cy - 2.0f, 4.0f, 4.0f));
}

- (void)drawCrosshair:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gHudCrosshairVisible || !gCrosshairEnabled) {
        return;
    }
    
    CGFloat cx = rect.size.width / 2.0f;
    CGFloat cy = rect.size.height / 2.0f;
    CGFloat gap = gHudCrosshairGap;
    CGFloat len = 9.0f;
    
    CGContextSetStrokeColorWithColor(ctx, (gCrosshairColor ?: [UIColor whiteColor]).CGColor);
    CGContextSetLineWidth(ctx, 1.4);
    
    CGContextMoveToPoint(ctx, cx - gap - len, cy);
    CGContextAddLineToPoint(ctx, cx - gap, cy);
    CGContextMoveToPoint(ctx, cx + gap, cy);
    CGContextAddLineToPoint(ctx, cx + gap + len, cy);
    CGContextMoveToPoint(ctx, cx, cy - gap - len);
    CGContextAddLineToPoint(ctx, cx, cy - gap);
    CGContextMoveToPoint(ctx, cx, cy + gap);
    CGContextAddLineToPoint(ctx, cx, cy + gap + len);
    CGContextStrokePath(ctx);
    
    CGContextSetFillColorWithColor(ctx, (gCrosshairColor ?: [UIColor whiteColor]).CGColor);
    CGContextFillEllipseInRect(ctx, CGRectMake(cx - 1.5f, cy - 1.5f, 3.0f, 3.0f));
}

- (void)drawHitMarker:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gHitMarkerEnabled) {
        return;
    }
    
    uint64_t now = NowMs();
    if (now >= gHudHitMarkerUntil) {
        return;
    }
    
    float remain = (float)(gHudHitMarkerUntil - now) / 220.0f;
    remain = Math::Clamp(remain, 0.0f, 1.0f);
    
    CGFloat cx = rect.size.width / 2.0f;
    CGFloat cy = rect.size.height / 2.0f;
    CGFloat s = 9.0f + (1.0f - remain) * 5.0f;
    
    UIColor* color = gHitMarkerColor ?: [UIColor whiteColor];
    CGContextSetStrokeColorWithColor(ctx, [color colorWithAlphaComponent:remain].CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    
    CGContextMoveToPoint(ctx, cx - s, cy - s);
    CGContextAddLineToPoint(ctx, cx - 3, cy - 3);
    CGContextMoveToPoint(ctx, cx + s, cy - s);
    CGContextAddLineToPoint(ctx, cx + 3, cy - 3);
    CGContextMoveToPoint(ctx, cx - s, cy + s);
    CGContextAddLineToPoint(ctx, cx - 3, cy + 3);
    CGContextMoveToPoint(ctx, cx + s, cy + s);
    CGContextAddLineToPoint(ctx, cx + 3, cy + 3);
    CGContextStrokePath(ctx);
}

- (void)drawDamageNumbers:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gDamageNumbersEnabled) {
        return;
    }
    
    static UIFont* dmgFont = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dmgFont = [UIFont boldSystemFontOfSize:13];
    });
    
    uint64_t now = NowMs();
    for (const HudDamageInfo& d : gHudDamage) {
        if (d.until <= now) {
            continue;
        }
        float remain = (float)(d.until - now) / 900.0f;
        remain = Math::Clamp(remain, 0.0f, 1.0f);
        NSString* text = SafeFmt(@"-%d", d.amount);
        NSDictionary* attrs = @{
            NSFontAttributeName: dmgFont ?: [UIFont boldSystemFontOfSize:13],
            NSForegroundColorAttributeName: [[UIColor colorWithRed:1.0 green:0.75 blue:0.1 alpha:remain] copy]
        };
        CGSize sz = [text sizeWithAttributes:attrs];
        [text drawAtPoint:CGPointMake(d.pos.x - sz.width/2, d.pos.y - (1.0f - remain) * 24.0f) withAttributes:attrs];
    }
}

- (void)drawKillFeed:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gKillFeedEnabled) {
        return;
    }
    
    static UIFont* kfFont = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kfFont = [UIFont boldSystemFontOfSize:11];
    });
    
    CGFloat x = rect.size.width - 12.0f;
    CGFloat y = 90.0f;
    uint64_t now = NowMs();
    
    for (const HudKillInfo& k : gHudKills) {
        if (k.until <= now) {
            continue;
        }
        float remain = (float)(k.until - now) / 6000.0f;
        remain = Math::Clamp(remain, 0.0f, 1.0f);
        NSString* text = SafeFmt(@"[FlopDLC] %s", k.name);
        NSDictionary* attrs = @{
            NSFontAttributeName: kfFont ?: [UIFont boldSystemFontOfSize:11],
            NSForegroundColorAttributeName: [[UIColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:remain] copy]
        };
        CGSize sz = [text sizeWithAttributes:attrs];
        [text drawAtPoint:CGPointMake(x - sz.width, y) withAttributes:attrs];
        y += sz.height + 3.0f;
    }
}

- (void)drawAimLine:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gAimLineEnabled || !gHudAimLineActive) {
        return;
    }
    
    CGFloat cx = rect.size.width / 2.0f;
    CGFloat cy = rect.size.height / 2.0f;
    
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.9 green:0.2 blue:0.9 alpha:0.8].CGColor);
    CGContextSetLineWidth(ctx, 1.2);
    CGFloat dash[] = {5.0, 4.0};
    CGContextSetLineDash(ctx, 0.0, dash, 2);
    CGContextMoveToPoint(ctx, cx, cy);
    CGContextAddLineToPoint(ctx, gHudAimLineTarget.x, gHudAimLineTarget.y);
    CGContextStrokePath(ctx);
    CGContextSetLineDash(ctx, 0.0, NULL, 0);
}

- (void)drawFpsGraph:(CGContextRef)ctx rect:(CGRect)rect {
    if (!gFpsEnabled) {
        return;
    }
    
    static UIFont* fpsFont = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fpsFont = [UIFont boldSystemFontOfSize:10];
    });
    
    CGFloat w = 132.0f;
    CGFloat h = 46.0f;
    CGFloat x = 10.0f;
    CGFloat y = 10.0f;
    
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.0 alpha:0.45].CGColor);
    CGContextFillRect(ctx, CGRectMake(x, y, w, h));
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.5 alpha:0.6].CGColor);
    CGContextSetLineWidth(ctx, 0.8);
    CGContextStrokeRect(ctx, CGRectMake(x, y, w, h));
    
    int fps = gFpsValue.load();
    float ms = gFrameMs.load();
    UIColor* fpsColor = [UIColor greenColor];
    if (fps < 50) {
        fpsColor = [UIColor yellowColor];
    }
    if (fps < 30) {
        fpsColor = [UIColor redColor];
    }
    
    NSString* line = SafeFmt(@"%d FPS  %.1f ms", fps, ms);
    NSDictionary* attrs = @{
        NSFontAttributeName: fpsFont ?: [UIFont boldSystemFontOfSize:10],
        NSForegroundColorAttributeName: fpsColor
    };
    [line drawAtPoint:CGPointMake(x + 6.0f, y + 3.0f) withAttributes:attrs];
    
    CGFloat graphY = y + 18.0f;
    CGFloat graphH = h - 22.0f;
    CGFloat graphW = w - 12.0f;
    CGFloat stepX = graphW / 119.0f;
    
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:0.25 alpha:0.7].CGColor);
    CGContextSetLineWidth(ctx, 0.5);
    CGContextMoveToPoint(ctx, x + 6.0f, graphY + graphH / 2.0f);
    CGContextAddLineToPoint(ctx, x + 6.0f + graphW, graphY + graphH / 2.0f);
    CGContextStrokePath(ctx);
    
    if (gFpsHistory.size() >= 2) {
        CGContextSetStrokeColorWithColor(ctx, fpsColor.CGColor);
        CGContextSetLineWidth(ctx, 1.2);
        
        CGFloat baseX = x + 6.0f + graphW - ((CGFloat)(gFpsHistory.size() - 1) * stepX);
        bool started = false;
        for (NSUInteger i = 0; i < gFpsHistory.size(); i++) {
            float v = gFpsHistory[i];
            v = Math::Clamp(v, 0.0f, 120.0f);
            CGFloat px = baseX + (CGFloat)i * stepX;
            CGFloat py = graphY + graphH - (v / 120.0f) * graphH;
            if (!started) {
                CGContextMoveToPoint(ctx, px, py);
                started = true;
            } else {
                CGContextAddLineToPoint(ctx, px, py);
            }
        }
        CGContextStrokePath(ctx);
    }
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        return;
    }
    
    [self drawFpsGraph:ctx rect:rect];
    [self drawScopeOverlay:ctx rect:rect];
    [self drawRadar:ctx rect:rect];
    [self drawAimLine:ctx rect:rect];
    [self drawCrosshair:ctx rect:rect];
    [self drawHitMarker:ctx rect:rect];
    [self drawDamageNumbers:ctx rect:rect];
    [self drawKillFeed:ctx rect:rect];
}

@end

static void SetupHudView(void) {
    if (gHudView || !gEspView) {
        return;
    }
    gHudView = [[HudView alloc] initWithFrame:gEspView.bounds];
    gHudView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [gEspView addSubview:gHudView];
}

