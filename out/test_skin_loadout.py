"""Host-side regression test for the skin loadout resolver and respawn tick.
Runs extracted production C++ functions with fake weapon objects; no iOS SDK required.
"""
from pathlib import Path
import re
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1] / "FlopDLC 5.mm"
source = SOURCE.read_text()


def function(name):
    match = re.search(r"^static [^\n]*\b" + name + r"\([^\n]*\) \{", source, re.M)
    assert match, name
    cursor = source.index("{", match.start()) + 1
    depth = 1
    while depth:
        if source[cursor] == "{":
            depth += 1
        elif source[cursor] == "}":
            depth -= 1
        cursor += 1
    return source[match.start():cursor]


code = r'''
#include <string>
#include <vector>
#include <unordered_map>
#include <mutex>
#include <atomic>
#include <cstdint>
#include <cassert>
#define SANE_PTR(p) ((p) != nullptr)
struct SkinEntry { std::string id, target; void* obj; int rarity; };
struct WeaponEntry { std::string id, label; void* obj; int skinCount; };
std::vector<SkinEntry> gSkinCatalog;
std::vector<WeaponEntry> gWeaponList;
std::vector<int> gSkinFiltered;
int gSkinTargetIndex=0, gSkinIndex=0;
void* gSkinSelectedObj=nullptr;
std::string gSkinSelectedId, gSkinSelectedTarget;
std::unordered_map<std::string, std::string> gSkinAssignments;
std::mutex gSkinAssignmentsMutex;
std::atomic<bool> gSkinChangerEnabled{true};
std::string Il2CppStringToStd(void* p) {
    return p ? *static_cast<std::string*>(p) : std::string();
}
void* g_localWeapon=nullptr;
void* gSkinLastAppliedWeapon=nullptr;
uint64_t gSkinLastCheckMs=0, clockMs=10;
uint64_t NowMs() { return clockMs; }
struct Weapon { alignas(void*) unsigned char bytes[0x100]{}; };
'''
for name in ("SkinAssignedId", "SkinForWeapon", "SkinRebuildFilter", "SkinSelectCurrent", "SkinRestoreBrowser"):
    code += function(name) + "\n"
code += r'''
void SkinApplyEx(bool) {
    SkinEntry entry;
    if (SkinForWeapon(g_localWeapon, &entry)) {
        *(void**)((uintptr_t)g_localWeapon + 0xE8) = entry.obj;
        gSkinLastAppliedWeapon = g_localWeapon;
    }
}
'''
code += function("SkinChangerTick")
code += r'''
int main() {
    int a=1, b=2, c=3;
    std::string ak="Ak47", gl="Glock", kn="Knife";
    gSkinCatalog={{"myth",ak,&a,5},{"rare",gl,&b,1},{"legend",kn,&c,3}};
    gWeaponList={{ak,"AK",nullptr,1},{gl,"Glock",nullptr,1},{kn,"Knife",nullptr,1}};
    for (int i=0; i<3; ++i) {
        gSkinTargetIndex=i; gSkinIndex=0; SkinRebuildFilter(); SkinSelectCurrent();
    }
    assert(gSkinAssignments.size()==3);
    auto saved=gSkinAssignments;
    for (int i=0; i<3; ++i) {
        gSkinTargetIndex=i; SkinRebuildFilter(); SkinRestoreBrowser();
        assert(gSkinSelectedId==saved[gWeaponList[i].id]);
        assert(gSkinAssignments==saved);
    }
    Weapon wa,wb,wc;
    auto set=[](Weapon& w,std::string& id) { *(void**)(w.bytes+0xB0)=&id; };
    set(wa,ak); set(wb,gl); set(wc,kn);
    for (auto weapon : {&wa,&wb,&wc}) {
        g_localWeapon=weapon; SkinChangerTick(); SkinEntry entry;
        assert(SkinForWeapon(weapon,&entry));
        assert(*(void**)(weapon->bytes+0xE8)==entry.obj);
    }
    g_localWeapon=nullptr; SkinChangerTick(); assert(!gSkinLastAppliedWeapon);
    *(void**)(wa.bytes+0xE8)=nullptr; g_localWeapon=&wa; SkinChangerTick();
    assert(*(void**)(wa.bytes+0xE8)==&a);
    *(void**)(wa.bytes+0xE8)=nullptr; clockMs+=1001; SkinChangerTick();
    assert(*(void**)(wa.bytes+0xE8)==&a);
    gSkinAssignments.clear(); gSkinAssignments=saved;
    assert(SkinAssignedId(gl)=="rare" && SkinAssignedId(kn)=="legend");
    gSkinAssignments.erase(ak); SkinEntry entry;
    assert(!SkinForWeapon(&wa,&entry)); assert(SkinForWeapon(&wb,&entry));
    gSkinChangerEnabled=false; assert(!SkinForWeapon(&wb,&entry));
}
'''
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    (root / "test.cpp").write_text(code)
    subprocess.run(["c++", "-std=c++17", "-pthread", str(root / "test.cpp"), "-o", str(root / "test")], check=True)
    subprocess.run([str(root / "test")], check=True)
assert "mach_vm" not in source
assert len(source.splitlines()) >= 10000
assert "SkinSelectCurrent" not in function("SkinCatalogLoad")
print("PASS: independent selections, browsing, switching, death, round reset, reload, clear-one, disable")
print("PASS: source checks; lines:", len(source.splitlines()))
