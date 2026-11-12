import { Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import { describe, expect, it, onTestFinished, vi } from 'vitest'
import type { SettingsNamespaceView } from '@deepseek-ai/dsh-api-remotes/client'
import { TestRemote } from '@deepseek-ai/dsh-client-test-runtime'
import { apply, inject } from '../src/client/index.ts'
import { SettingsSchemaService } from '../src/client/schema.ts'
import { ConfigForms } from '../src/client/config-form.ts'

const schema = z.object({ preference: z.string().required() }).toJSON()

function described(preference: string, revision: number) {
  const namespace: SettingsNamespaceView = {
    ns: 'ui-test',
    schema: JSON.parse(JSON.stringify(schema)) as SettingsNamespaceView['schema'],
    value: { preference },
    autoGenerate: true,
    applies: 'live',
    secrets: [],
    revision,
  }
  return { ok: true as const, value: { writable: true, hasDocument: true, namespaces: [namespace] } }
}

function bench() {
  const describeCall = vi.fn().mockResolvedValue(described('light', 0))

/** Page global the serving deployment injects to set served-page settings persistence. */
interface SettingsPersistenceGlobal {
  __DSH_SETTINGS_REMOTE_PERSISTENCE__?: 'host' | 'memory'
}

/** Page conditions the persistence resolution reads: Host loopback plus the boot global. */
interface Page {
  isLoopback?: boolean
  remotePersistence?: 'host' | 'memory'
}

function bench(page: Page = {}) {
  const describeCall = vi.fn().mockResolvedValue(described('light', 0))
  const ctx = new Context()
  onTestFinished(() => ctx.fiber.dispose())
  const remote = new TestRemote(ctx, { settings: { describe: describeCall } })
  remote.$host = { home: undefined, isLoopback: page.isLoopback ?? true }
  const globals = globalThis as SettingsPersistenceGlobal
  const prior = globals.__DSH_SETTINGS_REMOTE_PERSISTENCE__
  if (page.remotePersistence === undefined) delete globals.__DSH_SETTINGS_REMOTE_PERSISTENCE__
  else globals.__DSH_SETTINGS_REMOTE_PERSISTENCE__ = page.remotePersistence
  const restoreGlobal = (): void => {
    if (prior === undefined) delete globals.__DSH_SETTINGS_REMOTE_PERSISTENCE__
    else globals.__DSH_SETTINGS_REMOTE_PERSISTENCE__ = prior
  }
  return { ctx, describeCall, remote, restoreGlobal, fiber: ctx.plugin({ inject: [...inject], apply }) }
}

describe('settings domain base plugin', () => {
  it('mounts the scope service under configForms and reads once eagerly', async () => {
    const { ctx, describeCall, fiber } = bench()
    await fiber.await()
    expect(ctx.get('configForms')).toBeInstanceOf(ConfigForms)
    expect(ctx.get('settingsSchema')).toBeInstanceOf(SettingsSchemaService)
    await vi.waitFor(() => { expect(describeCall).toHaveBeenCalledTimes(1) })
  })

  it('refreshes remote ConfigForm values and revisions on document commits and connection resets', async () => {
    const { ctx, describeCall, remote, fiber } = bench()
    await fiber.await()
    await ctx.configForms.describe().ensure()
    const scope = ctx.configForms.get<{ preference: string }>('ui-test')
    expect(scope.getSnapshot()).toMatchObject({
      status: 'ready', value: { preference: 'light' }, revision: 0, writable: true,
    })
    describeCall.mockResolvedValue(described('dark', 1))
    remote.emit('settings/document-updated', ['ui-test', 1])
    await vi.waitFor(() => {
      expect(scope.getSnapshot()).toMatchObject({ value: { preference: 'dark' }, revision: 1 })
    })
    describeCall.mockResolvedValue(described('system', 2))
    ctx.emit('connection/reset')
    await vi.waitFor(() => {
      expect(scope.getSnapshot()).toMatchObject({ value: { preference: 'system' }, revision: 2 })
    })
  })

  it('fiber disposal retires the service and its invalidation subscriptions', async () => {
    const { ctx, describeCall, remote, fiber } = bench()
    await fiber.await()
    await vi.waitFor(() => { expect(describeCall).toHaveBeenCalledTimes(1) })
    await fiber.dispose()
    expect(ctx.get('configForms')).toBeUndefined()
    expect(ctx.get('settingsSchema')).toBeUndefined()
    remote.emit('settings/document-updated', ['ui-test', 0])
    ctx.emit('connection/reset')
    await Promise.resolve()
    expect(describeCall).toHaveBeenCalledTimes(1)
  })

  it('persists host-side on a non-loopback page when the deployment opts in', async () => {
    const { describeCall, restoreGlobal, fiber } = bench({ isLoopback: false, remotePersistence: 'host' })
    try {
      await fiber.await()
      await vi.waitFor(() => { expect(describeCall).toHaveBeenCalledTimes(1) })
    } finally {
      restoreGlobal()
    }
  })

  it('keeps a non-loopback page process-local without the deployment global', async () => {
    const { ctx, describeCall, restoreGlobal, fiber } = bench({ isLoopback: false })
    try {
      await fiber.await()
      expect(ctx.get('configForms')).toBeInstanceOf(ConfigForms)
      await new Promise(resolve => setTimeout(resolve, 0))
      expect(describeCall).not.toHaveBeenCalled()
    } finally {
      restoreGlobal()
    }
  })
})
