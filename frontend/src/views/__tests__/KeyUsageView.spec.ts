import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { ref } from 'vue'
import KeyUsageView from '../KeyUsageView.vue'

const showSuccess = vi.fn()
const showError = vi.fn()
const showInfo = vi.fn()
const fetchPublicSettings = vi.fn()
let rafTime = 0

vi.mock('@/stores', () => ({
  useAppStore: () => ({
    cachedPublicSettings: null,
    siteName: 'Sub2API',
    siteLogo: '',
    docUrl: '',
    publicSettingsLoaded: true,
    fetchPublicSettings,
    showSuccess,
    showError,
    showInfo
  })
}))

vi.mock('vue-i18n', async () => {
  const actual = await vi.importActual<typeof import('vue-i18n')>('vue-i18n')
  return {
    ...actual,
    useI18n: () => ({
      t: (key: string) => key,
      locale: ref('en')
    })
  }
})

describe('KeyUsageView', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-03-11T12:00:00Z'))
    vi.clearAllMocks()
    rafTime = 0

    vi.stubGlobal('fetch', vi.fn())
    vi.stubGlobal('requestAnimationFrame', (cb: FrameRequestCallback) => {
      rafTime += 16
      return window.setTimeout(() => cb(rafTime), 16)
    })
    Object.defineProperty(window, 'matchMedia', {
      writable: true,
      value: vi.fn().mockReturnValue({
        matches: false,
        media: '',
        onchange: null,
        addListener: vi.fn(),
        removeListener: vi.fn(),
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
        dispatchEvent: vi.fn()
      })
    })
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
  })

  it('queries usage and renders reset countdown for quota-limited keys', async () => {
    vi.mocked(fetch).mockResolvedValue({
      ok: true,
      json: async () => ({
        mode: 'quota_limited',
        isValid: true,
        status: 'active',
        quota: {
          used: 1,
          limit: 10,
          remaining: 9
        },
        rate_limits: [
          {
            window: '5h',
            used: 2,
            limit: 10,
            reset_at: '2026-03-11T13:30:00Z'
          }
        ],
        usage: null,
        model_stats: []
      })
    } as Response)

    const wrapper = mount(KeyUsageView, {
      global: {
        stubs: {
          'router-link': {
            template: '<a><slot /></a>'
          },
          LocaleSwitcher: true,
          Icon: true
        }
      }
    })

    await wrapper.get('input[placeholder="keyUsage.placeholder"]').setValue('sk-test-key')
    await wrapper.get('input[placeholder="keyUsage.placeholder"]').trigger('keydown.enter')
    await flushPromises()
    await vi.advanceTimersByTimeAsync(1000)

    expect(fetch).toHaveBeenCalledWith(
      '/v1/usage?start_date=2026-03-11&end_date=2026-03-11',
      expect.objectContaining({
        headers: { Authorization: 'Bearer sk-test-key' }
      })
    )
    expect(showSuccess).toHaveBeenCalledWith('keyUsage.querySuccess')
    expect(wrapper.text()).toContain('$2.00 / $10.00')
    expect(wrapper.text()).toContain('1h 30m')
  })
})
