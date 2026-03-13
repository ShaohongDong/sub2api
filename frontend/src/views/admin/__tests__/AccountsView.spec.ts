import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { defineComponent } from 'vue'

const mockAccountsList = vi.fn()
const mockGetBatchTodayStats = vi.fn()
const mockProxiesGetAll = vi.fn()
const mockGroupsGetAll = vi.fn()

vi.mock('@/api/admin', () => ({
  adminAPI: {
    accounts: {
      list: (...args: any[]) => mockAccountsList(...args),
      getBatchTodayStats: (...args: any[]) => mockGetBatchTodayStats(...args),
      listWithEtag: vi.fn(),
      delete: vi.fn(),
      bulkUpdate: vi.fn(),
      exportData: vi.fn(),
      getAvailableModels: vi.fn(),
      refreshCredentials: vi.fn(),
      clearError: vi.fn(),
      clearRateLimit: vi.fn(),
      resetAccountQuota: vi.fn(),
      setSchedulable: vi.fn(),
    },
    proxies: {
      getAll: (...args: any[]) => mockProxiesGetAll(...args),
    },
    groups: {
      getAll: (...args: any[]) => mockGroupsGetAll(...args),
    },
  },
}))

vi.mock('@/stores/app', () => ({
  useAppStore: () => ({
    showSuccess: vi.fn(),
    showError: vi.fn(),
  }),
}))

vi.mock('@/stores/auth', () => ({
  useAuthStore: () => ({
    isSimpleMode: false,
  }),
}))

vi.mock('vue-i18n', async () => {
  const actual = await vi.importActual<typeof import('vue-i18n')>('vue-i18n')
  return {
    ...actual,
    useI18n: () => ({
      t: (key: string) => key,
    }),
  }
})

const SimpleStub = defineComponent({
  template: '<div><slot /></div>',
})

const TablePageLayoutStub = defineComponent({
  template: `
    <div>
      <slot name="filters" />
      <slot name="table" />
      <slot name="pagination" />
    </div>
  `,
})

const DataTableStub = defineComponent({
  props: {
    data: {
      type: Array,
      default: () => [],
    },
  },
  template: `
    <div>
      <div v-for="row in data" :key="row.id" class="row">
        <slot name="cell-platform_type" :row="row" :value="row.platform" />
      </div>
    </div>
  `,
})

const PaginationStub = defineComponent({
  props: {
    pageSizeOptions: {
      type: Array,
      default: () => [],
    },
  },
  template: '<div class="pagination-stub">{{ JSON.stringify(pageSizeOptions) }}</div>',
})

import AccountsView from '../AccountsView.vue'

describe('AccountsView', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    localStorage.clear()

    mockAccountsList.mockResolvedValue({
      items: [
        {
          id: 101,
          name: 'OpenAI OAuth Account',
          notes: null,
          platform: 'openai',
          type: 'oauth',
          credentials: {
            plan_type: 'chatgptpro',
          },
          extra: {},
          concurrency: 1,
          priority: 10,
          rate_multiplier: 1,
          status: 'active',
          error_message: '',
          last_used_at: null,
          expires_at: null,
          auto_pause_on_expired: false,
          created_at: '2026-03-10T00:00:00Z',
          updated_at: '2026-03-10T00:00:00Z',
          schedulable: true,
          groups: [],
        },
      ],
      total: 1,
      page: 1,
      page_size: 20,
      pages: 1,
    })
    mockGetBatchTodayStats.mockResolvedValue({ stats: {} })
    mockProxiesGetAll.mockResolvedValue([])
    mockGroupsGetAll.mockResolvedValue([])
  })

  it('renders the normalized OpenAI plan type badge in account rows', async () => {
    const wrapper = mount(AccountsView, {
      global: {
        stubs: {
          AppLayout: SimpleStub,
          TablePageLayout: TablePageLayoutStub,
          AccountTableFilters: true,
          AccountTableActions: SimpleStub,
          AccountBulkActionsBar: true,
          DataTable: DataTableStub,
          Pagination: PaginationStub,
          CreateAccountModal: true,
          EditAccountModal: true,
          ReAuthAccountModal: true,
          AccountTestModal: true,
          AccountStatsModal: true,
          ScheduledTestsPanel: true,
          AccountActionMenu: true,
          SyncFromCrsModal: true,
          ImportDataModal: true,
          BulkEditAccountModal: true,
          TempUnschedStatusModal: true,
          ConfirmDialog: true,
          ErrorPassthroughRulesModal: true,
          AccountStatusIndicator: true,
          AccountUsageCell: true,
          AccountTodayStatsCell: true,
          AccountGroupsCell: true,
          AccountCapacityCell: true,
          PlatformIcon: true,
          Icon: true,
        },
      },
    })

    await flushPromises()
    await flushPromises()

    expect(mockAccountsList).toHaveBeenCalledTimes(1)
    expect(wrapper.text()).toContain('OpenAI')
    expect(wrapper.text()).toContain('OAuth')
    expect(wrapper.text()).toContain('Pro')
    expect(wrapper.find('.pagination-stub').text()).toContain('[5,10,20,50,100]')
  })
})
