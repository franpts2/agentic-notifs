const directKinds = {
  "session.idle": "done",
  "session.deleted": "stopped",
  "permission.asked": "permission",
  "permission.v2.asked": "permission",
  "permission.replied": "running",
  "permission.v2.replied": "running",
  "question.asked": "input",
  "question.v2.asked": "input",
  "question.replied": "running",
  "question.v2.replied": "running",
  "session.error": "error",
}

const eventKind = (event) => {
  if (event.type === "session.status") {
    const status = event.properties?.status?.type
    if (status === "busy" || status === "retry") return "running"
  }
  return directKinds[event.type]
}

const sessionIDFor = (event) =>
  event.properties?.sessionID
  ?? event.properties?.session_id
  ?? event.properties?.info?.id

export const AgenticNotifsPlugin = async ({ directory }) => {
  const activeSessions = new Set()
  const subagentSessions = new Set()
  const sessionNames = new Map()
  const sessionStates = new Map()
  let disposed = false
  let delivery = Promise.resolve()

  const send = async (kind, sessionID) => {
    const executable = `${process.env.HOME}/.local/bin/agentic-notify`
    const args = [
      "emit",
      "--agent", "opencode",
      "--event", kind,
      "--project-path", directory,
    ]
    if (sessionID) args.push("--session-id", sessionID)
    const sessionName = sessionID ? sessionNames.get(sessionID) : undefined
    if (sessionName) args.push("--session-name", sessionName)

    try {
      const processHandle = Bun.spawn([executable, ...args], {
        stdout: "ignore",
        stderr: "inherit",
      })
      const exitCode = await processHandle.exited
      if (exitCode !== 0) {
        console.error(`Agentic Notifs exited with status ${exitCode}`)
      }
    } catch (error) {
      console.error("Agentic Notifs could not send an event", error)
    }
  }

  const cleanup = async () => {
    if (disposed) return
    disposed = true
    for (const sessionID of activeSessions) await send("stopped", sessionID)
    await send("stopped")
    activeSessions.clear()
    subagentSessions.clear()
    sessionNames.clear()
    sessionStates.clear()
  }

  const handle = async (event) => {
    if (event.type === "global.disposed" || event.type === "server.instance.disposed") {
      await cleanup()
      return
    }

    const sessionID = sessionIDFor(event)
    const sessionInfo = event.properties?.info
    if (event.type === "session.created" || event.type === "session.updated") {
      if (sessionInfo?.parentID && sessionID) {
        const wasActive = activeSessions.delete(sessionID)
        subagentSessions.add(sessionID)
        if (wasActive) await send("stopped", sessionID)
        sessionNames.delete(sessionID)
        sessionStates.delete(sessionID)
      } else if (sessionID && sessionInfo?.title) {
        const previousName = sessionNames.get(sessionID)
        sessionNames.set(sessionID, sessionInfo.title)
        const state = sessionStates.get(sessionID)
        if (state && previousName !== sessionInfo.title) await send("metadata", sessionID)
      }
      return
    }
    if (sessionInfo?.parentID || (sessionID && subagentSessions.has(sessionID))) {
      if (event.type === "session.deleted") {
        subagentSessions.delete(sessionID)
        sessionNames.delete(sessionID)
        sessionStates.delete(sessionID)
      }
      return
    }

    const kind = eventKind(event)
    if (!kind) return

    if (sessionID && kind !== "stopped") {
      activeSessions.add(sessionID)
      sessionStates.set(sessionID, kind)
    }
    await send(kind, sessionID)
    if (sessionID && kind === "stopped") {
      activeSessions.delete(sessionID)
      sessionNames.delete(sessionID)
      sessionStates.delete(sessionID)
    }
  }

  return {
    event: ({ event }) => {
      delivery = delivery.then(() => handle(event))
      return delivery
    },
    dispose: () => {
      delivery = delivery.then(() => cleanup())
      return delivery
    },
  }
}
