'use strict';

const FIRE_METHOD_RVA = 0x19D8624;

function CalculateVector(start, end) {
    const x = end.x - start.x;
    const y = end.y - start.y;
    const z = end.z - start.z;
    const length = Math.sqrt(x * x + y * y + z * z);

    if (!Number.isFinite(length) || length === 0) {
        return { x: 0, y: 0, z: 0 };
    }

    return { x: x / length, y: y / length, z: z / length };
}

globalThis.CalculateVector = CalculateVector;

function moduleForGameCode() {
    const modules = Process.enumerateModules();
    const module = modules.find(function (item) {
        return /UnityFramework|GameAssembly|il2cpp/i.test(item.name);
    });

    if (module === undefined) {
        throw new Error('Could not find UnityFramework, GameAssembly, or an il2cpp module');
    }

    return module;
}

function readSimdFloat(context, registerIndex) {
    const scalarRegister = context['s' + registerIndex];
    if (typeof scalarRegister === 'number') {
        return scalarRegister;
    }

    const vectorRegister = context['q' + Math.floor(registerIndex / 4)];
    const byteOffset = (registerIndex % 4) * 4;

    if (vectorRegister !== undefined && typeof vectorRegister.readFloat === 'function') {
        return vectorRegister.add(byteOffset).readFloat();
    }

    if (vectorRegister instanceof ArrayBuffer) {
        return new DataView(vectorRegister).getFloat32(byteOffset, true);
    }

    if (ArrayBuffer.isView(vectorRegister)) {
        return new DataView(
            vectorRegister.buffer,
            vectorRegister.byteOffset,
            vectorRegister.byteLength
        ).getFloat32(byteOffset, true);
    }

    throw new Error('SIMD float register ' + registerIndex + ' is not exposed by this Frida runtime');
}

function readVector(context, firstRegister) {
    return {
        x: readSimdFloat(context, firstRegister),
        y: readSimdFloat(context, firstRegister + 1),
        z: readSimdFloat(context, firstRegister + 2)
    };
}

function install() {
    if (Process.arch !== 'arm64') {
        throw new Error('This logger expects an iOS arm64 target');
    }

    const module = moduleForGameCode();
    const fireMethod = module.base.add(FIRE_METHOD_RVA);

    console.log('[logger] module=' + module.name + ' base=' + module.base);
    console.log('[logger] attaching to ItemEquipWeaponRange.fke at ' + fireMethod);

    Interceptor.attach(fireMethod, {
        onEnter: function () {
            try {
                // fke(Vector3 from, Vector3 to, List<LocalHit> hitsLocal, bool grounded)
                // uses the arm64 homogeneous-float aggregate registers for the two Vector3 values.
                const from = readVector(this.context, 0);
                const to = readVector(this.context, 3);
                const direction = CalculateVector(from, to);

                console.log('[shot] ' + JSON.stringify({
                    origin: from,
                    endpoint: to,
                    direction: direction
                }));
            } catch (error) {
                console.log('[logger] could not decode shot vectors: ' + error.message);
            }
        }
    });
}

setImmediate(install);
