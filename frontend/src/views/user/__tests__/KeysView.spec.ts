import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { defineComponent } from 'vue'
import KeysView from '../KeysView.vue'

const mocks = vi.hoisted(() => ({
  list: vi.fn(),
  getDashboardApiKeysUsage: vi.fn(),
  getAvailable: vi.fn(),
  getUserGroupRates: vi.fn(),
  getPublicSettings: vi.fn(),
  showError: vi.fn(),
  showSuccess: vi.fn()
}))

vi.mock('@/api', () => ({
  keysAPI: {
    list: mocks.list,
    toggleStatus: vi.fn(),
    update: vi.fn(),
    create: vi.fn(),
    delete: vi.fn()
  },
  usageAPI: {
    getDashboardApiKeysUsage: mocks.getDashboardApiKeysUsage
  },
  userGroupsAPI: {
    getAvailable: mocks.getAvailable,
    getUserGroupRates: mocks.getUserGroupRates
  },
  authAPI: {
    getPublicSettings: mocks.getPublicSettings
  }
}))

vi.mock('@/stores/app', () => ({
  useAppStore: () => ({
    showError: mocks.showError,
    showSuccess: mocks.showSuccess
  })
}))

vi.mock('@/stores/onboarding', () => ({
  useOnboardingStore: () => ({
    isCurrentStep: () => false,
    nextStep: vi.fn()
  })
}))

vi.mock('@/composables/useClipboard', () => ({
  useClipboard: () => ({
    copyToClipboard: vi.fn().mockResolvedValue(true)
  })
}))

vi.mock('vue-i18n', async () => {
  const actual = await vi.importActual<typeof import('vue-i18n')>('vue-i18n')
  return {
    ...actual,
    useI18n: () => ({
      t: (key: string) => key
    })
  }
})

const AppLayoutStub = defineComponent({
  template: '<div><slot /></div>'
})

const TablePageLayoutStub = defineComponent({
  template: `
    <div>
      <slot name="filters" />
      <slot name="actions" />
      <slot name="table" />
      <slot name="pagination" />
    </div>
  `
})

const DataTableStub = defineComponent({
  props: {
    columns: { type: Array, required: true },
    data: { type: Array, required: true },
    loading: { type: Boolean, default: false }
  },
  template: `
    <div class="data-table-stub">
      <div v-for="row in data" :key="row.id" class="row">
        <div v-for="col in columns" :key="col.key" class="cell">
          <slot :name="'cell-' + col.key" :value="row[col.key]" :row="row">
            {{ row[col.key] }}
          </slot>
        </div>
      </div>
      <slot v-if="!data.length" name="empty" />
    </div>
  `
})

describe('KeysView', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-03-11T12:00:00Z'))
    vi.clearAllMocks()

    mocks.list.mockResolvedValue({
      items: [
        {
          id: 1,
          user_id: 99,
          key: 'sk-test-key-1234',
          name: 'Primary key',
          group_id: null,
          group: null,
          status: 'active',
          ip_whitelist: [],
          ip_blacklist: [],
          quota: 0,
          quota_used: 0,
          rate_limit_5h: 10,
          rate_limit_1d: 0,
          rate_limit_7d: 0,
          usage_5h: 2,
          usage_1d: 0,
          usage_7d: 0,
          reset_5h_at: '2026-03-11T13:30:00Z',
          reset_1d_at: null,
          reset_7d_at: null,
          expires_at: null,
          last_used_at: null,
          created_at: '2026-03-10T10:00:00Z',
          updated_at: '2026-03-10T10:00:00Z'
        }
      ],
      total: 1,
      pages: 1
    })
    mocks.getDashboardApiKeysUsage.mockResolvedValue({
      stats: {
        1: {
          today_actual_cost: 0.1,
          total_actual_cost: 0.2
        }
      }
    })
    mocks.getAvailable.mockResolvedValue([])
    mocks.getUserGroupRates.mockResolvedValue({})
    mocks.getPublicSettings.mockResolvedValue({})
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('renders API key rate-limit reset countdown from backend fields', async () => {
    const wrapper = mount(KeysView, {
      global: {
        stubs: {
          AppLayout: AppLayoutStub,
          TablePageLayout: TablePageLayoutStub,
          DataTable: DataTableStub,
          Pagination: true,
          BaseDialog: { template: '<div><slot /><slot name="footer" /></div>' },
          ConfirmDialog: true,
          EmptyState: true,
          Select: true,
          SearchInput: true,
          Icon: true,
          UseKeyModal: true,
          GroupBadge: true,
          GroupOptionItem: true
        }
      }
    })

    await flushPromises()
    await vi.advanceTimersByTimeAsync(1000)

    expect(mocks.list).toHaveBeenCalled()
    expect(mocks.getDashboardApiKeysUsage).toHaveBeenCalledWith([1], expect.any(Object))
    expect(wrapper.text()).toContain('$2.00/$10.00')
    expect(wrapper.text()).toContain('1h 30m')
  })
})
