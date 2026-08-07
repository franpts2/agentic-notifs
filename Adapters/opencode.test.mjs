import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"

const deliveries = []
globalThis.Bun = {
  spawn: (arguments_) => {
    deliveries.push(arguments_.slice(1))
    return { exited: Promise.resolve(0) }
  },
}

const source = await readFile(new URL("./opencode.js", import.meta.url), "utf8")
const moduleURL = `data:text/javascript;base64,${Buffer.from(source).toString("base64")}`
const { AgenticNotifsPlugin } = await import(moduleURL)
const hooks = await AgenticNotifsPlugin({ directory: "/tmp/project" })

const option = (delivery, name) => {
  const index = delivery.indexOf(`--${name}`)
  return index === -1 ? undefined : delivery[index + 1]
}
const event = (value) => hooks.event({ event: value })

await event({
  type: "session.created",
  properties: { info: { id: "top", title: "Initial title" } },
})
await event({
  type: "session.status",
  properties: { sessionID: "top", status: { type: "busy" } },
})
assert.equal(option(deliveries.at(-1), "event"), "running")
assert.equal(option(deliveries.at(-1), "session-name"), "Initial title")

await event({
  type: "session.updated",
  properties: { info: { id: "top", title: "Renamed session" } },
})
assert.equal(option(deliveries.at(-1), "event"), "metadata")
assert.equal(option(deliveries.at(-1), "session-name"), "Renamed session")

await event({
  type: "session.created",
  properties: { info: { id: "child", title: "Child", parentID: "top" } },
})
const deliveriesBeforeFilteredEvent = deliveries.length
await event({
  type: "session.status",
  properties: { sessionID: "child", status: { type: "busy" } },
})
assert.equal(deliveries.length, deliveriesBeforeFilteredEvent)

await hooks.dispose()
assert.equal(option(deliveries.at(-2), "event"), "stopped")
assert.equal(option(deliveries.at(-2), "session-id"), "top")
assert.equal(option(deliveries.at(-1), "event"), "stopped")
assert.equal(option(deliveries.at(-1), "session-id"), undefined)

const deliveriesAfterDispose = deliveries.length
await hooks.dispose()
assert.equal(deliveries.length, deliveriesAfterDispose)

console.log("OpenCode adapter tests passed.")
