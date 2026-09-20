import { describe, expect } from "bun:test"
import { Effect, Layer } from "effect"
import { Agent } from "../../src/agent/agent"
import { Command } from "../../src/command"
import * as CrossSpawnSpawner from "../../src/effect/cross-spawn-spawner"
import { provideTmpdirInstance } from "../fixture/fixture"
import { testEffect } from "../lib/effect"

const it = testEffect(
  Layer.mergeAll(Agent.defaultLayer, Command.defaultLayer, CrossSpawnSpawner.defaultLayer),
)

// /review runs as a subtask, so the dispatcher has to name an agent that can
// actually be spawned. Leaving `agent` unset made it fall back to the session's
// current agent — build or plan, both primary — which the actor tool's
// model-facing `subagent_type` enum rejects. The subtask then died with
// "Invalid option: expected one of explore|general" and reviewed nothing.
describe("/review command", () => {
  it.live("dispatches to a spawnable subagent", () =>
    provideTmpdirInstance(() =>
      Effect.gen(function* () {
        const commands = yield* Command.Service
        const agents = yield* Agent.Service

        const review = yield* commands.get(Command.Default.REVIEW)
        expect(review?.subtask).toBe(true)

        // Naming an agent that is not actually spawnable would fail the same way
        // an unset one did, so pin the name and its spawnability together.
        expect(review?.agent).toBeTruthy()
        const target = (yield* agents.list()).find((agent) => agent.name === review?.agent)
        expect(target?.mode).toBe("subagent")
        expect(target?.hidden).not.toBe(true)
      }),
    ),
  )
})
