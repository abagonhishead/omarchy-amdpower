.pragma library

// Decoding for the AMD SMU power metrics ("PM") table that the ryzen_smu
// kernel module exposes at /sys/kernel/ryzen_smu_drv/pm_table. The table is
// an array of little-endian float32 values whose layout depends on the
// firmware's table version, so every layout is keyed by that version and an
// unknown version decodes to nothing rather than to wrong numbers.
//
// Offsets come from RyzenAdj's lib/api.c (the get_* readers). Only layouts
// marked verified have been checked against `ryzenadj --info` on real
// hardware.

var GROUPS = ["power", "current", "temperature"]

// Per group: key is the group's headline reading, shown beside a collapsed
// section's header; setting is the settings key that turns the graph off.
var GRAPHS = {
  power: { key: "fast", setting: "graphPower" },
  current: { key: "tdcVdd", setting: "graphCurrent" },
  temperature: { key: "thmCore", setting: "graphTemperature" }
}

// Field metadata shared by every layout. key: i18n key stem; unit: shown
// after numbers; ryzenadj: the row name RyzenAdj prints, for
// cross-reference; optional: hide the row when its live value is 0
// (absent hardware, e.g. no discrete GPU).
var FIELD_META = {
  stapm: { group: "power", unit: "W", ryzenadj: "STAPM" },
  slow: { group: "power", unit: "W", ryzenadj: "PPT SLOW" },
  fast: { group: "power", unit: "W", ryzenadj: "PPT FAST" },
  tdcVdd: { group: "current", unit: "A", ryzenadj: "TDC VDD" },
  edcVdd: { group: "current", unit: "A", ryzenadj: "EDC VDD" },
  tdcSoc: { group: "current", unit: "A", ryzenadj: "TDC SOC" },
  edcSoc: { group: "current", unit: "A", ryzenadj: "EDC SOC" },
  thmCore: { group: "temperature", unit: "°C", ryzenadj: "THM CORE" },
  sttApu: { group: "temperature", unit: "°C", ryzenadj: "STT APU" },
  sttDgpu: { group: "temperature", unit: "°C", ryzenadj: "STT dGPU", optional: true }
}

function field(key, limit, value) {
  var meta = FIELD_META[key]
  return { key: key, group: meta.group, unit: meta.unit, ryzenadj: meta.ryzenadj,
           optional: meta.optional === true, limit: limit, value: value }
}

// Byte offsets of each reading's limit and live value, one set per distinct
// layout. Generated from RyzenAdj's lib/api.c get_* readers. Where RyzenAdj
// reads two readings from the same place, only one is kept.
var RAVEN_FIELDS = [
  field("stapm", 0x00, 0x04),
  field("slow", 0x10, 0x14),
  field("fast", 0x08, 0x0C),
  field("tdcVdd", 0x18, 0x1C),
  field("edcVdd", 0x28, 0x2C),
  field("tdcSoc", 0x20, 0x24),
  field("edcSoc", 0x34, 0x38),
  field("thmCore", 0x58, 0x5C)
]

var RENOIR_FIELDS = [
  field("stapm", 0x00, 0x04),
  field("slow", 0x10, 0x14),
  field("fast", 0x08, 0x0C),
  field("tdcVdd", 0x20, 0x24),
  field("edcVdd", 0x30, 0x34),
  field("tdcSoc", 0x28, 0x2C),
  field("edcSoc", 0x38, 0x3C),
  field("thmCore", 0x40, 0x44),
  field("sttApu", 0x58, 0x5C),
  field("sttDgpu", 0x60, 0x64)
]

var VAN_GOGH_FIELDS = [
  field("stapm", 0x00, 0x04),
  field("slow", 0x10, 0x14),
  field("fast", 0x08, 0x0C),
  field("thmCore", 0x40, 0x44),
  field("sttApu", 0x58, 0x5C)
]

var PHOENIX_FIELDS = [
  field("stapm", 0x00, 0x04),
  field("slow", 0x10, 0x14),
  field("fast", 0x08, 0x0C)
]

var DRAGON_RANGE_FIELDS = [
  field("stapm", 0x00, 0x04),
  field("slow", 0x10, 0x14),
  field("fast", 0x08, 0x0C),
  field("tdcVdd", 0x20, 0x24),
  field("thmCore", 0x28, 0x2C)
]

var STRIX_POINT_FIELDS = [
  field("stapm", 0x00, 0x04),
  field("slow", 0x10, 0x14),
  field("fast", 0x08, 0x0C),
  field("tdcVdd", 0x30, 0x34),
  field("tdcSoc", 0x38, 0x3C),
  field("thmCore", 0x40, 0x44),
  field("sttApu", 0x58, 0x5C),
  field("sttDgpu", 0x68, 0x6C)
]

var STRIX_HALO_FIELDS = [
  field("stapm", 0x00, 0x04),
  field("slow", 0x10, 0x14),
  field("fast", 0x08, 0x0C),
  field("sttApu", 0x58, 0x5C),
  field("sttDgpu", 0x60, 0x64)
]

var KRACKAN_POINT_FIELDS = [
  field("stapm", 0x00, 0x04),
  field("slow", 0x10, 0x14),
  field("fast", 0x08, 0x0C),
  field("tdcVdd", 0x30, 0x34),
  field("tdcSoc", 0x38, 0x3C),
  field("thmCore", 0x40, 0x44)
]

// verified: checked against `ryzenadj --info` on real hardware. Every other
// layout is ported from RyzenAdj untested, and the popup says so.
var LAYOUTS = {
  0x001E0001: { family: "Raven / Picasso / Dali", fields: RAVEN_FIELDS },
  0x001E0002: { family: "Raven / Picasso / Dali", fields: RAVEN_FIELDS },
  0x001E0003: { family: "Raven / Picasso / Dali", fields: RAVEN_FIELDS },
  0x001E0004: { family: "Raven / Picasso / Dali", fields: RAVEN_FIELDS },
  0x001E0005: { family: "Raven / Picasso / Dali", fields: RAVEN_FIELDS },
  0x001E000A: { family: "Raven / Picasso / Dali", fields: RAVEN_FIELDS },
  0x001E0101: { family: "Raven / Picasso / Dali", fields: RAVEN_FIELDS },
  0x00370000: { family: "Renoir / Lucienne", fields: RENOIR_FIELDS },
  0x00370001: { family: "Renoir / Lucienne", fields: RENOIR_FIELDS },
  0x00370002: { family: "Renoir / Lucienne", fields: RENOIR_FIELDS },
  0x00370003: { family: "Renoir / Lucienne", fields: RENOIR_FIELDS },
  0x00370004: { family: "Renoir / Lucienne", fields: RENOIR_FIELDS },
  0x00370005: { family: "Renoir / Lucienne", fields: RENOIR_FIELDS },
  0x003F0000: { family: "Van Gogh", fields: VAN_GOGH_FIELDS },
  0x00400001: { family: "Cezanne", fields: RENOIR_FIELDS },
  0x00400002: { family: "Cezanne", fields: RENOIR_FIELDS },
  0x00400003: { family: "Cezanne", fields: RENOIR_FIELDS },
  0x00400004: { family: "Cezanne", fields: RENOIR_FIELDS },
  0x00400005: { family: "Cezanne", fields: RENOIR_FIELDS },
  0x00450004: { family: "Rembrandt", fields: RENOIR_FIELDS },
  0x00450005: { family: "Rembrandt", fields: RENOIR_FIELDS },
  0x004C0003: { family: "Phoenix / Hawk Point", fields: PHOENIX_FIELDS },
  0x004C0004: { family: "Phoenix / Hawk Point", fields: PHOENIX_FIELDS },
  0x004C0005: { family: "Phoenix / Hawk Point", fields: PHOENIX_FIELDS },
  0x004C0006: { family: "Phoenix / Hawk Point", fields: RENOIR_FIELDS },
  0x004C0007: { family: "Phoenix / Hawk Point", fields: RENOIR_FIELDS },
  0x004C0008: { family: "Phoenix / Hawk Point", fields: RENOIR_FIELDS },
  0x004C0009: { family: "Phoenix / Hawk Point", fields: RENOIR_FIELDS, verified: true },  // Verified on a Ryzen 9 7940HS
  0x00540208: { family: "Dragon Range / Raphael", fields: DRAGON_RANGE_FIELDS },
  0x005D0008: { family: "Strix Point", fields: STRIX_POINT_FIELDS },
  0x005D0009: { family: "Strix Point", fields: STRIX_POINT_FIELDS },
  0x005D000B: { family: "Strix Point", fields: STRIX_POINT_FIELDS },
  0x0064020C: { family: "Strix Halo", fields: STRIX_HALO_FIELDS },
  0x00650005: { family: "Krackan Point", fields: KRACKAN_POINT_FIELDS }
}

// The bytes a layout needs: just past its furthest offset. ryzen_smu reports
// the table's real size, so this is checked rather than RyzenAdj's sizes.
for (var sizedVersion in LAYOUTS) {
  var sized = LAYOUTS[sizedVersion]
  sized.minBytes = 0
  for (var sf = 0; sf < sized.fields.length; sf++) {
    sized.minBytes = Math.max(sized.minBytes, sized.fields[sf].limit + 4, sized.fields[sf].value + 4)
  }
}

// Each layout's row keys per group, built once so callers always get the same
// array back. Views use these as stable models: their rows then update in
// place on every refresh instead of being destroyed and rebuilt.
for (var layoutVersion in LAYOUTS) {
  var layoutEntry = LAYOUTS[layoutVersion]
  layoutEntry.groupKeys = {}
  for (var g = 0; g < GROUPS.length; g++) {
    layoutEntry.groupKeys[GROUPS[g]] = []
  }
  for (var f = 0; f < layoutEntry.fields.length; f++) {
    layoutEntry.groupKeys[layoutEntry.fields[f].group].push(layoutEntry.fields[f].key)
  }
}

var NO_KEYS = []

function groupKeys(version, group) {
  var layout = layoutFor(version)
  if (!layout || !layout.groupKeys.hasOwnProperty(group)) {
    return NO_KEYS
  }
  return layout.groupKeys[group]
}

function versionLabel(version) {
  if (typeof version !== "number" || !isFinite(version)) {
    return ""
  }
  return "0x" + (version >>> 0).toString(16)
}

function layoutFor(version) {
  return LAYOUTS.hasOwnProperty(version) ? LAYOUTS[version] : null
}

// pm_table_version holds the version as a little-endian uint32.
function readVersion(buffer) {
  if (!buffer || buffer.byteLength < 4) {
    return NaN
  }
  return new DataView(buffer).getUint32(0, true)
}

function readFloat(view, offset) {
  if (offset + 4 > view.byteLength) {
    return NaN
  }
  return view.getFloat32(offset, true)
}

// Returns { ok, reason, family, rows } where rows carry the decoded numbers.
// reason is one of "unsupported" or "short" when ok is false.
function decode(version, buffer) {
  var layout = layoutFor(version)
  if (!layout) {
    return { ok: false, reason: "unsupported", family: "", rows: [] }
  }
  if (!buffer || buffer.byteLength < layout.minBytes) {
    return { ok: false, reason: "short", family: layout.family, rows: [] }
  }

  var view = new DataView(buffer)
  var rows = []
  for (var i = 0; i < layout.fields.length; i++) {
    var field = layout.fields[i]
    var limit = readFloat(view, field.limit)
    var value = readFloat(view, field.value)
    if (!isFinite(limit) || !isFinite(value)) {
      continue
    }
    if (field.optional && value === 0) {
      continue
    }
    rows.push({
      key: field.key,
      group: field.group,
      unit: field.unit,
      ryzenadj: field.ryzenadj,
      limit: limit,
      value: value,
      fraction: limit > 0 ? Math.max(0, Math.min(1, value / limit)) : 0
    })
  }
  return { ok: true, reason: "", family: layout.family, verified: layout.verified === true, rows: rows }
}

function rowsInGroup(rows, group) {
  var out = []
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].group === group) {
      out.push(rows[i])
    }
  }
  return out
}

function findRow(rows, key) {
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].key === key) {
      return rows[i]
    }
  }
  return null
}

// Numbers under 10 keep one decimal so small readings stay meaningful.
function formatNumber(value, formatter) {
  var decimals = Math.abs(value) < 10 ? 1 : 0
  return formatter ? formatter(value, decimals) : value.toFixed(decimals)
}
