#!/usr/bin/env python3
"""FlopDLC / RAPIRA skin catalog extractor.

Reads Unity serialized files (.assets / levelN) from an .ipa or a Data folder,
resolves MonoBehaviour script classes through the MonoScript table in
globalgamemanagers.assets, and decodes the ItemData / ItemSkin / ItemWeaponSkin
serialized layout by hand (IL2CPP builds ship without MonoBehaviour typetrees).

Usage:
    pip install UnityPy
    python3 out/parse_skins.py <ipa-or-Data-dir> --json out/skins.json

Serialized layout (verified against AK47Skin0 in resources.assets):
    header: PPtr m_GameObject (12), u8 m_Enabled, pad, PPtr m_Script (12),
            string m_Name
    ItemData: bool IsDisabled, int Type, int CostT, int Rarity, int Category,
              int Cost, int Slot, bool DontShowInInventory, bool DontShowInMarket,
              bool DontAllowedToTrade, bool IsExclusive, string ItemModelPathPrefix,
              bool Hidden, string Collection, List Animations, List Audio,
              List Flags
    ItemSkin: int _suiteTeam, PPtr _targetItem
    ItemWeaponSkin: bool HasGradientPatterns, Texture2D[] GradientPatterns,
                    bool OverrideInspectPreviewEuler, Vector3 InspectPreviewEuler,
                    bool FlipInspectBladeDir, bool FlipInspectEdgeRoll
    ItemCharacterSkin: int _suiteTeam, PPtr _model, bool _isDefault
    ItemHelmetSkin: bool _isDefault, int _suiteTeam
"""

import argparse
import json
import os
import struct
import sys
import tempfile
import zipfile

try:
    import UnityPy
except ImportError:
    sys.exit("UnityPy is missing: pip install UnityPy")

SKIN_CLASSES = {"ItemSkin", "ItemWeaponSkin", "ItemCharacterSkin", "ItemHelmetSkin"}
DATA_CLASSES = {"ItemData", "ItemLevelData"}


class Cursor:
    def __init__(self, buf, pos):
        self.buf = buf
        self.pos = pos

    def align(self, n=4):
        self.pos = (self.pos + n - 1) & ~(n - 1)

    def u8(self):
        # Unity aligns every serialized field to 4 bytes, including bools.
        self.align()
        v = self.buf[self.pos]
        self.pos += 1
        return v

    def i32(self):
        self.align()
        v = struct.unpack_from("<i", self.buf, self.pos)[0]
        self.pos += 4
        return v

    def f32(self):
        self.align()
        v = struct.unpack_from("<f", self.buf, self.pos)[0]
        self.pos += 4
        return v

    def string(self):
        self.align()
        n = struct.unpack_from("<i", self.buf, self.pos)[0]
        self.pos += 4
        if n < 0 or n > 4096:
            return None
        s = self.buf[self.pos:self.pos + n].decode("utf-8", "replace")
        self.pos += n
        self.align()
        return s

    def pptr(self):
        self.align()
        file_id = struct.unpack_from("<i", self.buf, self.pos)[0]
        path_id = struct.unpack_from("<q", self.buf, self.pos + 4)[0]
        self.pos += 12
        return file_id, path_id

    def skip_list(self):
        self.align()
        n = struct.unpack_from("<i", self.buf, self.pos)[0]
        self.pos += 4
        return n


def header(raw):
    """Return (script_path_id, name, cursor_after_name)."""
    script_path_id = struct.unpack_from("<q", raw, 0x14)[0]
    n = struct.unpack_from("<i", raw, 0x1C)[0]
    if n < 0 or n > 4096 or 0x20 + n > len(raw):
        return script_path_id, None, None
    name = raw[0x20:0x20 + n].decode("utf-8", "replace")
    cur = Cursor(raw, 0x20 + n)
    cur.align()
    return script_path_id, name, cur


def parse_item_data(cur):
    out = {}
    out["is_disabled"] = cur.u8()
    out["type"] = cur.i32()
    out["cost_type"] = cur.i32()
    out["rarity"] = cur.i32()
    out["category"] = cur.i32()
    out["cost"] = cur.i32()
    out["slot"] = cur.i32()
    out["dont_show_inventory"] = cur.u8()
    out["dont_show_market"] = cur.u8()
    out["dont_allow_trade"] = cur.u8()
    out["is_exclusive"] = cur.u8()
    out["model_prefix"] = cur.string()
    out["hidden"] = cur.u8()
    out["collection"] = cur.string()
    out["animations"] = cur.skip_list()
    out["audio"] = cur.skip_list()
    out["flags"] = cur.skip_list()
    return out


def parse_skin(cls, cur):
    out = parse_item_data(cur)
    if cls == "ItemSkin":
        out["suite_team"] = cur.i32()
        out["target"] = cur.pptr()[1]
    elif cls == "ItemWeaponSkin":
        out["suite_team"] = cur.i32()
        out["target"] = cur.pptr()[1]
        out["has_gradient"] = cur.u8()
        out["gradient_count"] = cur.skip_list()
        out["override_inspect"] = cur.u8()
        out["inspect_euler"] = (cur.f32(), cur.f32(), cur.f32())
        out["flip_blade"] = cur.u8()
        out["flip_edge"] = cur.u8()
    elif cls == "ItemCharacterSkin":
        out["suite_team"] = cur.i32()
        out["model"] = cur.pptr()[1]
        out["is_default"] = cur.u8()
    elif cls == "ItemHelmetSkin":
        out["is_default"] = cur.u8()
        out["suite_team"] = cur.i32()
    return out


def iter_files(root):
    if os.path.isfile(root) and root.lower().endswith(".ipa"):
        tmp = tempfile.mkdtemp(prefix="flopdlc_ipa_")
        with zipfile.ZipFile(root) as zf:
            zf.extractall(tmp)
        root = tmp
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            if name.endswith(".assets") or name.startswith("level") or name.startswith("globalgamemanagers"):
                yield os.path.join(dirpath, name)


def load_script_map(root):
    """path_id -> class name, from the MonoScript table."""
    mapping = {}
    for path in iter_files(root):
        if not os.path.basename(path).startswith("globalgamemanagers"):
            continue
        try:
            env = UnityPy.load(path)
        except Exception:
            continue
        for obj in env.objects:
            if obj.type.name != "MonoScript":
                continue
            try:
                data = obj.read()
            except Exception:
                continue
            mapping[obj.path_id] = getattr(data, "m_ClassName", None)
    return mapping


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", help="directory with Data files, or an .ipa")
    parser.add_argument("--json", default="out/skins.json")
    args = parser.parse_args()

    scripts = load_script_map(args.root)
    print(f"[scan] monoscripts={len(scripts)}", file=sys.stderr)

    names = {}
    rows = []
    for path in iter_files(args.root):
        try:
            env = UnityPy.load(path)
        except Exception as exc:
            print(f"[skip] {path}: {exc}", file=sys.stderr)
            continue
        for obj in env.objects:
            if obj.type.name != "MonoBehaviour":
                continue
            raw = obj.get_raw_data()
            if len(raw) < 0x20:
                continue
            script_id, name, cur = header(raw)
            if name is None:
                continue
            cls = scripts.get(script_id)
            if cls is None:
                continue
            # Every MonoBehaviour carries its asset name at 0x1C; keep them all so
            # skin targets (WeaponDataRange, ItemLevelData, ...) resolve too.
            names[obj.path_id] = name
            if cls in DATA_CLASSES:
                continue
            if cls not in SKIN_CLASSES:
                continue
            try:
                fields = parse_skin(cls, cur)
            except Exception as exc:
                print(f"[warn] {name}: {exc}", file=sys.stderr)
                continue
            fields["id"] = name
            fields["class"] = cls
            fields["path_id"] = obj.path_id
            fields["file"] = os.path.basename(path)
            rows.append(fields)

    for row in rows:
        target = row.get("target")
        row["target_name"] = names.get(target) if target else None

    rows.sort(key=lambda r: (r["class"], r["id"]))
    os.makedirs(os.path.dirname(args.json) or ".", exist_ok=True)
    with open(args.json, "w", encoding="utf-8") as fh:
        json.dump(rows, fh, ensure_ascii=False, indent=2)

    by_class = {}
    for row in rows:
        by_class[row["class"]] = by_class.get(row["class"], 0) + 1
    print(f"[scan] skins={len(rows)} {by_class}", file=sys.stderr)
    print(f"[scan] wrote {args.json}", file=sys.stderr)

    for row in rows:
        if row["class"] in ("ItemWeaponSkin", "ItemSkin"):
            print(json.dumps({
                "id": row["id"],
                "target": row.get("target_name"),
                "rarity": row.get("rarity"),
                "slot": row.get("slot"),
                "model_prefix": row.get("model_prefix"),
            }, ensure_ascii=False))


if __name__ == "__main__":
    main()
