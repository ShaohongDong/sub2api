import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { defineComponent } from 'vue'
import KeysView from '../KeysView.vue'

const list = vi.fn()
const getDashboardApiKeysUsage = vi.fn()
const getAvailable = vi.fn()
const getUserGroupRates = vi.fn()
const getPublicSettings = vi.fn()
const showError = vi.fn()
const showSuccess = vi.fn()

vi.mock('@/api', () => ({
  keysAPI: {
    list,
    toggleStatus: vi.fn(),
    update: vi.fn(),
    create: vi.fn(),
    delete: vi.fn()
  },
  usageAPI: {
    getDashboardApiKeysUsage
  },
  userGroupsAPI: {
    getAvailable,
    getUserGroupRates
  },
  authAPI: {
    getPublicSettings
  }
}))

vi.mock('@/stores/app', () => ({
  useAppStore: () => ({
    showError,
    showSuccess
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

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key: string) => key
  })
}))

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
      <div v-for="row in data" :key="(row as any).id" class="row">
        <div v-for="col in columns" :key="(col as any).key" class="cell">
          <slot :name="'cell-' + (col as any).key" :value="(row as any)[(col as any).key]" :row="row">
            {{ (row as any)[(col as any).key] }}
          </slot>
        </div>
      </div>
      <slot v-if="!(data as any[]).length" name="empty" />
    </div>
  `
})

describe('KeysView', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-03-11T12:00:00Z'))
    vi.clearAllMocks()

    list.mockResolvedValue({
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
    getDashboardApiKeysUsage.mockResolvedValue({
      stats: {
        1: {
          today_actual_cost: 0.1,
          total_actual_cost: 0.2
        }
      }
    })
    getAvailable.mockResolvedValue([])
    getUserGroupRates.mockResolvedValue({})
    getPublicSettings.mockResolvedValue({})
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
    await vi.runAllTimersAsync()

    expect(list).toHaveBeenCalled()
    expect(getDashboardApiKeysUsage).toHaveBeenCalledWith([1], expect.any(Object))
    expect(wrapper.text()).toContain('$2.00/$10.00')
    expect(wrapper.text()).toContain('1h 30m')
  })
})
