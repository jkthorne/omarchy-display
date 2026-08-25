const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

test("brightness is clamped to 1..100", () => {
  assert.equal(Model.clampBrightness(0), 1)
  assert.equal(Model.clampBrightness(150), 100)
  assert.equal(Model.clampBrightness("42"), 42)
  assert.equal(Model.clampBrightness("nope"), 1)
})

test("scale helpers round and pick whole-pixel values", () => {
  assert.equal(Model.normalizeScale("1.2500"), "1.25")
  assert.equal(Model.cleanScale(1.25, 2880, 1800), "1.25")
  assert.deepEqual(Model.availableScales(["1", "1.25", "1.6", "2"], 2880, 1800).length > 0, true)
  assert.equal(Model.matchingScaleIndex(["1", "1.25", "2"], "1.25", 2880, 1800), 1)
})

test("parseDisplays counts enabled outputs and survives bad JSON", () => {
  const parsed = Model.parseDisplays('[{"name":"eDP-1","enabled":true},{"name":"DP-1","enabled":false}]')
  assert.equal(parsed.displays.length, 2)
  assert.equal(parsed.enabledDisplayCount, 1)
  assert.deepEqual(Model.parseDisplays("nope"), { displays: [], enabledDisplayCount: 0 })
})

test("brightness names follow the mood bands", () => {
  assert.equal(Model.brightnessName(100), "Sun blast")
  assert.equal(Model.brightnessName(50), "Even day")
  assert.equal(Model.brightnessName(1), "Night owl")
})
