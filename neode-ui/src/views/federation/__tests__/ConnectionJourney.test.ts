import { flushPromises, shallowMount } from '@vue/test-utils'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { createMemoryHistory, createRouter } from 'vue-router'
import Federation from '../../Federation.vue'
import { rpcClient } from '@/api/rpc-client'

const fixtures = vi.hoisted(() => ({ nodes: [] as Record<string, string>[] }))

vi.mock('@/stores/transport', () => ({ useTransportStore: () => ({ fetchPeers: vi.fn() }) }))
vi.mock('@/stores/app', () => ({ useAppStore: () => ({ serverName: 'Fixture' }) }))
vi.mock('@/stores/sync', () => ({ useSyncStore: () => ({ serverInfo: null }) }))
vi.mock('@/api/rpc-client', () => ({ rpcClient: {
  call: vi.fn().mockResolvedValue({}), getNodeDid: vi.fn().mockResolvedValue({ did: 'did:key:self' }),
  nostrDiscoveryStatus: vi.fn().mockResolvedValue({ enabled: false }),
  federationListPendingRequests: vi.fn().mockResolvedValue({ requests: [] }),
} }))
vi.mock('@/composables/useCachedResource', async () => {
  const { ref } = await import('vue')
  return { useCachedResource: (options: { key: string }) => ({ data: ref(options.key === 'federation.nodes' ? fixtures.nodes : []), loadState: ref('ready'), error: ref(null), refresh: vi.fn() }) }
})
afterEach(() => { fixtures.nodes = []; vi.useRealTimers() })

describe('connection journey navigation', () => {
  it('renders all tabs with zero peers, accepts deep links and reacts to navigation', async () => {
    const router = createRouter({ history: createMemoryHistory(), routes: [{ path: '/', component: Federation }] })
    await router.push('/?view=requests')
    await router.isReady()
    const wrapper = shallowMount(Federation, { global: { plugins: [router] } })
    await flushPromises()
    const selected = () => wrapper.get('[role="tab"][aria-selected="true"]').text()
    expect(selected()).toBe('Requests')
    expect(wrapper.findAll('[role="tab"]').map(t => t.text())).toEqual(['Discover', 'Requests', 'Connected', 'Network Map'])
    expect(wrapper.findComponent({ name: 'PendingRequestsPanel' }).props('showEmpty')).toBe(true)
    await wrapper.findAll('[role="tab"]')[2]!.trigger('click')
    await flushPromises()
    expect(router.currentRoute.value.query.view).toBe('connected')
    await router.push('/?view=discover')
    await flushPromises()
    expect(selected()).toBe('Discover')
    await router.push('/?view=list')
    await flushPromises()
    expect(selected()).toBe('Connected')
    wrapper.unmount()
  })
})

it('does not start a poll timer after navigating away during initial identity loading', async () => {
  let resolve!: (value: Awaited<ReturnType<typeof rpcClient.getNodeDid>>) => void
  vi.mocked(rpcClient.getNodeDid).mockReturnValueOnce(new Promise(done => { resolve = done }))
  const router = createRouter({ history: createMemoryHistory(), routes: [{ path: '/', component: Federation }] })
  await router.push('/')
  // Spy on BOTH halves and assert the invariant that actually matters: an
  // interval scheduled after the component went away must be cleared, not left
  // running. Asserting "setInterval was never called anywhere" is a global
  // claim in a suite that mounts other pollers (useElectrsSync, useBitcoinSync,
  // useMessageToast all own timers), so an unrelated one starting between the
  // spy and the assertion fails this test for no reason — which is how it
  // flaked in CI while passing in isolation and as a full local run.
  const started = vi.spyOn(globalThis, 'setInterval')
  const stopped = vi.spyOn(globalThis, 'clearInterval')
  const wrapper = shallowMount(Federation, { global: { plugins: [router] } })
  wrapper.unmount()
  resolve({ did: 'did:key:late', pubkey: 'fixture' })
  await flushPromises()
  const leaked = started.mock.calls.length - stopped.mock.calls.length
  expect(leaked, `an interval was started and never cleared after unmount (${started.mock.calls.length} started, ${stopped.mock.calls.length} cleared)`).toBeLessThanOrEqual(0)
  started.mockRestore()
  stopped.mockRestore()
})

it('opens an existing peer deep link and clears it when the detail closes', async () => {
  fixtures.nodes = [{ did: 'did:key:peer', pubkey: 'key', onion: 'fixture.onion', trust_level: 'observer', added_at: new Date().toISOString() }]
  const router = createRouter({ history: createMemoryHistory(), routes: [{ path: '/', component: Federation }] })
  await router.push('/?node=fixture.onion&from=cloud&tab=peers')
  const wrapper = shallowMount(Federation, { global: { plugins: [router] } })
  await flushPromises()
  expect(wrapper.get('[role="tab"][aria-selected="true"]').text()).toBe('Connected')
  const detail = wrapper.findComponent({ name: 'NodeDetailModal' })
  expect(detail.props('node')?.did).toBe('did:key:peer')
  detail.vm.$emit('close')
  await flushPromises()
  expect(router.currentRoute.value.query.node).toBeUndefined()
  expect(router.currentRoute.value.query.from).toBe('cloud')
  expect(detail.props('node')).toBeNull()
  await router.push('/#connection-requests')
  await flushPromises()
  expect(wrapper.get('[role="tab"][aria-selected="true"]').text()).toBe('Requests')
  wrapper.unmount()
})
