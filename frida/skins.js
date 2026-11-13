'use strict';

// FlopDLC — skin catalog dumper + local visual skin override.
// frida -U -f <bundle-id> -l frida/skins.js --no-pause
//
// Dumps every ItemSkin asset from Data._items (id, target weapon, type, rarity, slot)
// and, when FORCE_SKIN_ID is set, swaps the local weapon model to that skin.
// Visual only: nothing is written to game memory and no equip request is sent.

const FORCE_SKIN_ID = ''; // e.g. 'ak_red'; empty = dump only
const DUMP_CATALOG = true;

// Item.<ItemSkinData>k__BackingField
const OFF_ITEM_SKIN_DATA = 0xE8;
// Item.DataId (SyncVar string)
const OFF_ITEM_DATA_ID = 0xB0;
// ItemSkin._targetItem
const OFF_ITEM_SKIN_TARGET = 0x70;
// ItemData fields
const OFF_ITEMDATA_TYPE = 0x1C;
const OFF_ITEMDATA_RARITY = 0x24;
const OFF_ITEMDATA_SLOT = 0x30;
// Data._items
const OFF_DATA_ITEMS = 0x58;
// List<T>
const OFF_LIST_ITEMS = 0x10;
const OFF_LIST_SIZE = 0x18;
// Il2CppArray
const OFF_ARRAY_LEN = 0x18;
const OFF_ARRAY_DATA = 0x20;
// Il2CppString
const OFF_STRING_LEN = 0x10;
const OFF_STRING_CHARS = 0x14;

let api = null;

function exportByName(name) {
    let p = null;
    if (Module.findGlobalExportByName) {
        p = Module.findGlobalExportByName(name);
    }
    if (p === null && Module.findExportByName) {
        p = Module.findExportByName(null, name);
    }
    return p;
}

function must(name) {
    const p = exportByName(name);
    if (p === null) {
        throw new Error('missing il2cpp export: ' + name);
    }
    return p;
}

function bindApi() {
    api = {
        domain_get: new NativeFunction(must('il2cpp_domain_get'), 'pointer', []),
        domain_get_assemblies: new NativeFunction(
            must('il2cpp_domain_get_assemblies'),
            'pointer',
            ['pointer', 'pointer']
        ),
        assembly_get_image: new NativeFunction(
            must('il2cpp_assembly_get_image'),
            'pointer',
            ['pointer']
        ),
        class_from_name: new NativeFunction(
            must('il2cpp_class_from_name'),
            'pointer',
            ['pointer', 'pointer', 'pointer']
        ),
        class_get_type: new NativeFunction(must('il2cpp_class_get_type'), 'pointer', ['pointer']),
        type_get_object: new NativeFunction(must('il2cpp_type_get_object'), 'pointer', ['pointer']),
        class_get_method_from_name: new NativeFunction(
            must('il2cpp_class_get_method_from_name'),
            'pointer',
            ['pointer', 'pointer', 'int']
        ),
        runtime_invoke: new NativeFunction(
            must('il2cpp_runtime_invoke'),
            'pointer',
            ['pointer', 'pointer', 'pointer', 'pointer']
        ),
        thread_attach: new NativeFunction(must('il2cpp_thread_attach'), 'pointer', ['pointer'])
    };
}

function readString(p) {
    if (p.isNull()) {
        return null;
    }
    const len = p.add(OFF_STRING_LEN).readS32();
    if (len <= 0) {
        return '';
    }
    return p.add(OFF_STRING_CHARS).readUtf16String(len);
}

function findClass(ns, name) {
    const domain = api.domain_get();
    const sizePtr = Memory.alloc(Process.pointerSize);
    const assemblies = api.domain_get_assemblies(domain, sizePtr);
    const count = sizePtr.readUInt();
    for (let i = 0; i < count; i++) {
        const asm = assemblies.add(i * Process.pointerSize).readPointer();
        const image = api.assembly_get_image(asm);
        const klass = api.class_from_name(image, ns, name);
        if (!klass.isNull()) {
            return klass;
        }
    }
    return null;
}

function invoke(method, obj, args) {
    let params = NULL;
    if (args && args.length > 0) {
        params = Memory.alloc(Process.pointerSize * args.length);
        for (let i = 0; i < args.length; i++) {
            params.add(i * Process.pointerSize).writePointer(args[i]);
        }
    }
    const exc = Memory.alloc(Process.pointerSize);
    exc.writePointer(NULL);
    const ret = api.runtime_invoke(method, obj, params, exc);
    if (!exc.readPointer().isNull()) {
        return null;
    }
    return ret;
}

function firstObjectOfType(klass) {
    const resourcesKlass = findClass('UnityEngine', 'Resources');
    if (resourcesKlass.isNull()) {
        return null;
    }
    const findMethod = api.class_get_method_from_name(resourcesKlass, 'FindObjectsOfTypeAll', 1);
    if (findMethod.isNull()) {
        return null;
    }
    const typeObject = api.type_get_object(api.class_get_type(klass));
    const arr = invoke(findMethod, NULL, [typeObject]);
    if (arr === null || arr.isNull()) {
        return null;
    }
    const len = arr.add(OFF_ARRAY_LEN).readUInt();
    if (len === 0) {
        return null;
    }
    return arr.add(OFF_ARRAY_DATA).readPointer();
}

function collectSkins(skinKlasses, itemDataKlass, dataObject) {
    const list = dataObject.add(OFF_DATA_ITEMS).readPointer();
    if (list.isNull()) {
        return [];
    }
    const items = list.add(OFF_LIST_ITEMS).readPointer();
    const size = list.add(OFF_LIST_SIZE).readS32();
    if (items.isNull() || size <= 0) {
        return [];
    }
    const getId = api.class_get_method_from_name(itemDataKlass, 'get_Id', 0);
    const out = [];
    for (let i = 0; i < size; i++) {
        const obj = items.add(OFF_ARRAY_DATA + i * Process.pointerSize).readPointer();
        if (obj.isNull()) {
            continue;
        }
        const klass = obj.readPointer();
        let matched = false;
        for (let k = 0; k < skinKlasses.length; k++) {
            if (!skinKlasses[k].isNull() && klass.compare(skinKlasses[k]) === 0) {
                matched = true;
                break;
            }
        }
        if (!matched) {
            continue;
        }
        const id = getId.isNull() ? null : readString(invoke(getId, obj, null));
        const target = obj.add(OFF_ITEM_SKIN_TARGET).readPointer();
        const targetId = getId.isNull() || target.isNull()
            ? null
            : readString(invoke(getId, target, null));
        out.push({
            id: id,
            target: targetId,
            type: obj.add(OFF_ITEMDATA_TYPE).readS32(),
            rarity: obj.add(OFF_ITEMDATA_RARITY).readS32(),
            slot: obj.add(OFF_ITEMDATA_SLOT).readS32(),
            object: obj
        });
    }
    return out;
}

function installForceHook(itemKlass, chosenSkin, targetId) {
    const mi = api.class_get_method_from_name(itemKlass, 'get_ItemSkinData', 0);
    if (mi.isNull()) {
        console.log('[skins] Item.get_ItemSkinData not found');
        return;
    }
    const fn = mi.readPointer();
    Interceptor.attach(fn, {
        onEnter: function () {
            this.self = this.context.x0;
        },
        onLeave: function (retval) {
            try {
                const dataId = readString(this.self.add(OFF_ITEM_DATA_ID).readPointer());
                if (dataId === targetId) {
                    retval.replace(chosenSkin);
                }
            } catch (error) {
                // ignore malformed items
            }
        }
    });
    console.log('[skins] force hook installed: ' + FORCE_SKIN_ID + ' -> ' + targetId);
}

function boot(attempt) {
    try {
        if (api === null) {
            bindApi();
        }
        const domain = api.domain_get();
        if (domain.isNull()) {
            throw new Error('il2cpp domain not ready');
        }
        api.thread_attach(domain);

        const gmKlass = findClass('', 'GameManager');
        const dataKlass = findClass('Assets.Common.Scripts.Data', 'Data');
        const skinKlasses = [
            findClass('Assets.Common.Scripts.Data.Global', 'ItemWeaponSkin'),
            findClass('Assets.Common.Scripts.Data.Global', 'ItemSkin'),
            findClass('Assets.Common.Scripts.Data.Global', 'ItemCharacterSkin'),
            findClass('Assets.Common.Scripts.Data.Global', 'ItemHelmetSkin')
        ];
        const itemDataKlass = findClass('Assets.Common.Scripts.Data.Level', 'ItemData');
        const itemKlass = findClass('Assets', 'Item');

        if (gmKlass.isNull() || dataKlass.isNull() || itemDataKlass.isNull() ||
            skinKlasses.every(function (k) { return k.isNull(); })) {
            throw new Error('core classes not resolved yet');
        }

        const gm = firstObjectOfType(gmKlass);
        if (gm === null) {
            throw new Error('GameManager instance not found');
        }
        const getData = api.class_get_method_from_name(gmKlass, 'get_Data', 0);
        const dataObject = invoke(getData, gm, null);
        if (dataObject === null || dataObject.isNull()) {
            throw new Error('Data asset not resolved');
        }

        const skins = collectSkins(skinKlasses, itemDataKlass, dataObject);
        console.log('[skins] catalog size=' + skins.length);

        if (DUMP_CATALOG) {
            for (let i = 0; i < skins.length; i++) {
                const s = skins[i];
                console.log('[skin] ' + JSON.stringify({
                    id: s.id,
                    target: s.target,
                    type: s.type,
                    rarity: s.rarity,
                    slot: s.slot
                }));
            }
        }

        if (FORCE_SKIN_ID !== '') {
            let chosen = null;
            for (let i = 0; i < skins.length; i++) {
                if (skins[i].id === FORCE_SKIN_ID) {
                    chosen = skins[i];
                    break;
                }
            }
            if (chosen === null) {
                console.log('[skins] id not found in catalog: ' + FORCE_SKIN_ID);
            } else if (itemKlass.isNull()) {
                console.log('[skins] Item class not found');
            } else {
                installForceHook(itemKlass, chosen.object, chosen.target);
            }
        }
    } catch (error) {
        if (attempt < 40) {
            setTimeout(function () {
                boot(attempt + 1);
            }, 1000);
        } else {
            console.log('[skins] failed: ' + error.message);
        }
    }
}

setImmediate(function () {
    boot(0);
});
